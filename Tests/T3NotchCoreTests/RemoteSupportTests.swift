import CryptoKit
import Foundation
import Testing
@testable import T3NotchCore

private final class MockRemoteURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
            captured.httpBodyStream = nil
        }
        lock.withLock { storage.append(captured) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}

private final class UIntLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []

    func append(_ value: UInt64) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [UInt64] { lock.withLock { values } }
}

private final class MemoryCredentialStore: RemoteCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteCredentialDocument

    init(_ value: RemoteCredentialDocument = RemoteCredentialDocument()) {
        self.value = value
    }

    func document() throws -> RemoteCredentialDocument {
        lock.withLock { value }
    }

    func update(
        _ transform: (inout RemoteCredentialDocument) throws -> Void
    ) throws {
        try lock.withLock {
            try transform(&value)
        }
    }

    func forgetT3Connect() throws {
        lock.withLock {
            value.importedT3Connect = nil
            value.relayAccessTokens = [:]
            value.connectEnvironmentCredentials = [:]
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}

private final class BooleanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool { lock.withLock { value } }
}

@Suite("Remote support", .serialized)
struct RemoteSupportTests {
    @Test func canonicalizesHTTPAndDerivesWebSocketEndpoint() throws {
        let endpoint = try ServerEndpoint(
            httpBaseURL: #require(URL(string: "HTTPS://mini.example.com:8443/pair?q=secret#token"))
        )
        #expect(endpoint.httpBaseURL.absoluteString == "https://mini.example.com:8443/")
        #expect(endpoint.webSocketBaseURL.absoluteString == "wss://mini.example.com:8443/")
        #expect(endpoint.port == 8443)
        #expect(!endpoint.isLoopback)
        #expect(ServerEndpoint(host: "::1", port: 3773).isLoopback)
        #expect(throws: ServerEndpointError.self) {
            try ServerEndpoint(
                httpBaseURL: #require(URL(string: "https://user:secret@mini.example"))
            )
        }
    }

    @Test func connectConfigurationRejectsNonHostnameClerkFrontends() throws {
        let invalidHosts = [
            "attacker.example?x=$",
            "user@attacker.example$",
            "-invalid.example$",
            "invalid..example$",
        ]
        for host in invalidHosts {
            let encoded = Data(host.utf8).base64URLEncodedString()
            #expect(throws: T3ConnectError.self) {
                try T3ConnectConfiguration(
                    clerkPublishableKey: "pk_test_\(encoded)",
                    clerkJWTTemplate: "t3-relay",
                    relayURL: #require(URL(string: "https://relay.example/"))
                )
            }
        }
    }

    @Test func parsesAndSanitizesDirectAndHostedPairingLinks() throws {
        let direct = try RemotePairingTarget(
            pairingURL: "http://192.168.1.8:3773/pair?token=query-secret"
        )
        #expect(direct.credential == "query-secret")
        #expect(direct.endpoint.httpBaseURL.absoluteString == "http://192.168.1.8:3773/")
        #expect(!direct.endpoint.httpBaseURL.absoluteString.contains("secret"))

        let hosted = try RemotePairingTarget(
            pairingURL:
                "https://app.t3.codes/pair?host=https%3A%2F%2Fmini.tailnet.ts.net"
                + "#token=fragment-secret"
        )
        #expect(hosted.credential == "fragment-secret")
        #expect(hosted.endpoint.httpBaseURL.absoluteString == "https://mini.tailnet.ts.net/")
        #expect(!hosted.endpoint.httpBaseURL.absoluteString.contains("token"))
        #expect(!hosted.endpoint.httpBaseURL.absoluteString.contains("secret"))
    }

    @Test func parsesAdvancedIPv4IPv6AndDNSHosts() throws {
        let ipv4 = try RemotePairingTarget(host: "10.0.0.4:3773", pairingCode: "one")
        let ipv6 = try RemotePairingTarget(host: "http://[2001:db8::1]:3773", pairingCode: "two")
        let dns = try RemotePairingTarget(
            host: "mini.example.test",
            pairingCode: "three"
        )
        #expect(ipv4.endpoint.httpBaseURL.absoluteString == "https://10.0.0.4:3773/")
        #expect(ipv6.endpoint.host == "2001:db8::1")
        #expect(dns.endpoint.httpBaseURL.absoluteString == "https://mini.example.test/")
    }

    @Test func rejectsNonLoopbackHTTPWithoutExplicitAcknowledgement() async throws {
        let signer = try DPoPSigner()
        let target = try RemotePairingTarget(
            host: "http://192.168.1.9:3773",
            pairingCode: "do-not-retain"
        )
        do {
            _ = try await RemotePairingClient(signer: signer).pair(target: target)
            Issue.record("Expected insecure HTTP to be rejected")
        } catch {
            guard case RemotePairingError.insecureHTTPNeedsConfirmation = error else {
                Issue.record("Expected the explicit insecure HTTP error")
                return
            }
            #expect(!error.localizedDescription.contains("do-not-retain"))
        }
    }

    @Test func dpopProofNormalizesHTUAndUsesRawES256Signature() async throws {
        let signer = try DPoPSigner()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = "access-token"
        let proof = try await signer.createProof(
            method: "post",
            url: #require(URL(string: "https://MINI.example:443/oauth/token?q=secret#fragment")),
            accessToken: token,
            now: now,
            jti: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        )
        let parts = proof.split(separator: ".")
        #expect(parts.count == 3)
        let header = try jsonObject(String(parts[0]))
        let payload = try jsonObject(String(parts[1]))
        #expect(header["typ"] as? String == "dpop+jwt")
        #expect(header["alg"] as? String == "ES256")
        #expect((header["jwk"] as? [String: Any])?["crv"] as? String == "P-256")
        #expect(payload["htm"] as? String == "POST")
        #expect(payload["htu"] as? String == "https://mini.example/oauth/token")
        #expect(payload["iat"] as? Int == 1_800_000_000)
        #expect(payload["jti"] as? String == "11111111-2222-3333-4444-555555555555")
        let ath = Data(SHA256.hash(data: Data(token.utf8))).base64URLEncodedString()
        #expect(payload["ath"] as? String == ath)
        #expect(try decodeBase64URL(String(parts[2])).count == 64)
    }

    @Test func dpopUsesRFC7638ThumbprintsAndFreshJTIValues() async throws {
        let signer = try DPoPSigner()
        let jwk = try await signer.publicJWK()
        let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(jwk.x)","y":"\#(jwk.y)"}"#
        let expected = Data(SHA256.hash(data: Data(canonical.utf8)))
            .base64URLEncodedString()
        #expect(try await signer.thumbprint() == expected)

        let url = try #require(URL(string: "https://mini.example/api/orchestration/shell"))
        let first = try await signer.createProof(method: "GET", url: url)
        let second = try await signer.createProof(method: "GET", url: url)
        let firstPayload = try jsonObject(String(first.split(separator: ".")[1]))
        let secondPayload = try jsonObject(String(second.split(separator: ".")[1]))
        #expect(firstPayload["jti"] as? String != secondPayload["jti"] as? String)
    }

    @Test func authorizerAddsFreshDPoPAndNeverChangesTheURL() async throws {
        let signer = try DPoPSigner()
        let authorizer = DPoPHTTPAuthorizer(accessToken: "bound-token", signer: signer)
        let url = try #require(URL(string: "https://mini.example/api"))
        var original = URLRequest(url: url)
        original.httpMethod = "get"
        let first = try await authorizer.authorize(original)
        let second = try await authorizer.authorize(original)
        #expect(first.url == url)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "DPoP bound-token")
        #expect(first.value(forHTTPHeaderField: "DPoP") != second.value(forHTTPHeaderField: "DPoP"))
    }

    @Test func scopedIdentitiesPreventCrossMachineCollisions() {
        let first = ScopedThreadID(
            environmentID: EnvironmentID("mini-a"),
            threadID: "thread-1"
        )
        let second = ScopedThreadID(
            environmentID: EnvironmentID("mini-b"),
            threadID: "thread-1"
        )
        #expect(first != second)
        #expect(first.storageKey != second.storageKey)
        #expect(Set([first, second]).count == 2)
        #expect(
            ScopedRequestID(thread: first, requestID: "request")
                != ScopedRequestID(thread: second, requestID: "request")
        )
    }

    @Test func profileStorePersistsOnlyNonSecretConfiguration() throws {
        let suite = "RemoteSupportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EnvironmentProfileStore(defaults: defaults, key: "profiles")
        let profile = EnvironmentProfile(
            environmentID: EnvironmentID("mini"),
            label: "Build mini",
            directEndpoint: try ServerEndpoint(
                httpBaseURL: #require(URL(string: "https://mini.example"))
            ),
            source: .direct,
            enabled: false,
            allowsInsecureHTTP: true
        )
        try store.upsert(profile)
        #expect(store.load() == [profile])
        let bytes = try #require(defaults.data(forKey: "profiles"))
        let serialized = try #require(String(data: bytes, encoding: .utf8))
        #expect(!serialized.localizedCaseInsensitiveContains("token"))
        #expect(!serialized.localizedCaseInsensitiveContains("credential"))
        try store.remove(profile.environmentID)
        #expect(store.load().isEmpty)
    }

    @Test func credentialDocumentMigratesAndSeparatesDirectFromConnectTokens() throws {
        let legacy = Data(
            """
            {
              "version": 1,
              "environmentCredentials": {
                "mini": {
                  "accessToken": "direct",
                  "expiresAt": 800000000,
                  "source": "direct"
                }
              },
              "relayAccessTokens": {}
            }
            """.utf8
        )
        var document = try JSONDecoder().decode(RemoteCredentialDocument.self, from: legacy)
        #expect(document.environmentCredentials["mini"]?.accessToken == "direct")
        #expect(document.connectEnvironmentCredentials.isEmpty)
        document.connectEnvironmentCredentials["mini"] = RemoteAccessCredential(
            accessToken: "connect",
            expiresAt: .distantFuture,
            source: .t3Connect
        )
        #expect(document.environmentCredentials["mini"]?.accessToken == "direct")
        #expect(document.connectEnvironmentCredentials["mini"]?.accessToken == "connect")
        let roundTrip = try JSONDecoder().decode(
            RemoteCredentialDocument.self,
            from: JSONEncoder().encode(document)
        )
        #expect(roundTrip.version == RemoteCredentialDocument().version)
        #expect(roundTrip.environmentCredentials["mini"]?.accessToken == "direct")
        #expect(roundTrip.connectEnvironmentCredentials["mini"]?.accessToken == "connect")
    }

    @Test func electronV10FixtureDecryptsAndBadPaddingFailsClosed() throws {
        let ciphertext = try #require(
            Data(
                base64Encoded:
                    "qPuLJc1rfU5oMAZrXr+tZj73wg3t1E/d2w8h/hp8ODtm1jZymlm2llFkj9IzVEVl"
                    + "SaCOshwel9iUDTb9FiH0aKeOXl9xviZHzHPatsw3reQaU4PbaCkbO7cJhopF04+R"
            )
        )
        let decrypted = try ElectronSafeStorageImporter.decryptV10(
            ciphertext,
            password: Data("peanuts".utf8)
        )
        #expect(
            decrypted
                == "eyJhbGciOiJub25lIn0."
                + "eyJpc3MiOiJodHRwczovL2NsZXJrLmV4YW1wbGUiLCJzdWIiOiJ1c2VyIn0."
                + "signature"
        )
        var corrupted = ciphertext
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0xff
        #expect(throws: ElectronSafeStorageError.self) {
            try ElectronSafeStorageImporter.decryptV10(
                corrupted,
                password: Data("peanuts".utf8)
            )
        }
    }

    @Test func electronDetectionRejectsUnsafeFilesAndNeverDecrypts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T3Notch-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clerk-tokens.json")
        let json = #"{"__clerk_client_jwt":"enc:djEwY2lwaGVydGV4dA=="}"#
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: file.path
        )
        let importer = ElectronSafeStorageImporter(tokenFile: file)
        if case .signedIn(let fingerprint) = importer.detect() {
            #expect(!fingerprint.isEmpty)
        } else {
            Issue.record("A safe recognized record should be detected without Keychain access")
        }

        try Data(#"{"__clerk_client_jwt":"plaintext"}"#.utf8).write(to: file)
        if case .incompatible = importer.detect() {
            // expected
        } else {
            Issue.record("Unsupported token formats must be rejected during detection")
        }
        try Data(json.utf8).write(to: file)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o666))],
            ofItemAtPath: file.path
        )
        if case .unsafePermissions = importer.detect() {
            // expected
        } else {
            Issue.record("Group/world-writable token files must fail closed")
        }

        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        if case .incompatible = ElectronSafeStorageImporter(tokenFile: link).detect() {
            // expected
        } else {
            Issue.record("Symlink token files must fail closed")
        }
    }

    @Test func pairingExchangeUsesExactOAuthFieldsAndVerifiesSession() async throws {
        let log = RequestLog()
        let oauthLog = RequestLog()
        let session = mockSession { request in
            log.append(request)
            let path = request.url?.path ?? ""
            let data: Data
            if path == "/oauth/token" {
                data = Data(
                    """
                    {
                      "access_token": "issued-access-token",
                      "token_type": "DPoP",
                      "expires_in": 3600,
                      "scope": "orchestration:read orchestration:operate"
                    }
                    """.utf8
                )
            } else if path == "/api/auth/session" {
                data = Data(#"{"authenticated":true}"#.utf8)
            } else {
                data = Data(
                    """
                    {
                      "environmentId": "stable-mini",
                      "label": "Mac mini",
                      "platform": {"os": "darwin", "arch": "arm64"},
                      "serverVersion": "1.2.3"
                    }
                    """.utf8
                )
            }
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        defer { MockRemoteURLProtocol.handler = nil }
        let signer = try DPoPSigner()
        let result = try await RemotePairingClient(
            session: session,
            signer: signer,
            requestObserver: { oauthLog.append($0) }
        ).pair(
            target: try RemotePairingTarget(
                host: "https://mini.example",
                pairingCode: "single+use&secret"
            )
        )
        #expect(result.profile.environmentID == EnvironmentID("stable-mini"))
        #expect(result.credential.source == .direct)

        let requests = log.requests
        #expect(requests.map(\.url?.path) == [
            "/.well-known/t3/environment",
            "/oauth/token",
            "/api/auth/session",
            "/.well-known/t3/environment",
        ])
        let tokenRequest = try #require(oauthLog.requests.first)
        let fields = formFields(try #require(tokenRequest.httpBody))
        #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
        #expect(
            fields["subject_token_type"]
                == "urn:t3:params:oauth:token-type:environment-bootstrap"
        )
        #expect(fields["subject_token"] == "single+use&secret")
        #expect(fields["scope"] == "orchestration:read orchestration:operate")
        #expect(fields["client_label"] == "T3Notch")
        #expect(fields["client_device_type"] == "desktop")
        #expect(fields["client_os"] == "macOS")
        #expect(tokenRequest.value(forHTTPHeaderField: "DPoP") != nil)
        let verification = try #require(
            requests.first { $0.url?.path == "/api/auth/session" }
        )
        #expect(verification.value(forHTTPHeaderField: "Authorization") == "DPoP issued-access-token")
        #expect(verification.value(forHTTPHeaderField: "DPoP") != nil)
        for request in requests where request.url?.path != "/oauth/token" {
            #expect(!request.url!.absoluteString.contains("single-use-secret"))
        }
    }

    @Test func pollingBackoffUsesInjectedSleeperAndCapsFromHalfASecond() async throws {
        let session = mockSession { request in
            (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { MockRemoteURLProtocol.handler = nil }
        let backoffs = UIntLog()
        let configuration = PollingConfiguration(
            activeShellNanoseconds: 1,
            idleShellNanoseconds: 1,
            focusedDetailNanoseconds: 1,
            idleDetailNanoseconds: 1,
            maximumBackoffNanoseconds: 2_000_000_000,
            sleep: { _ in
                if backoffs.snapshot.count >= 3 {
                    try? await Task.sleep(for: .seconds(1))
                }
            },
            jitter: { $0 },
            onBackoff: { backoffs.append($0) }
        )
        let transport = PollingTransport(
            client: T3HTTPClient(
                endpoint: try ServerEndpoint(
                    httpBaseURL: #require(URL(string: "https://offline.example"))
                ),
                token: "token",
                session: session
            ),
            configuration: configuration
        )
        defer { transport.stop() }
        for _ in 0..<250 {
            if backoffs.snapshot.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            backoffs.snapshot.count >= 3,
            "Timed out waiting for three backoff samples"
        )
        #expect(Array(backoffs.snapshot.prefix(3)) == [
            500_000_000,
            1_000_000_000,
            2_000_000_000,
        ])
    }

    @Test func completeConnectChainSelectsSessionRotatesAndCachesTokens() async throws {
        let configuration = try connectConfiguration()
        var document = RemoteCredentialDocument()
        document.importedT3Connect = ImportedT3ConnectCredential(
            clerkClientJWT: clerkClientJWT(subject: "user"),
            ciphertextFingerprint: "fingerprint"
        )
        let store = MemoryCredentialStore(document)
        let observed = RequestLog()
        let network = RequestLog()
        let session = mockSession { request in
            network.append(request)
            let path = request.url?.path ?? ""
            let host = request.url?.host
            let body: String
            var headers = ["Content-Type": "application/json"]
            switch (host, path) {
            case ("clerk.example", "/v1/client"):
                body =
                    #"{"response":{"last_active_session_id":"session-1","sessions":[{"id":"session-1","status":"active"}]}}"#
                headers["Authorization"] = "Bearer \(clerkClientJWT(subject: "rotated"))"
            case ("clerk.example", "/v1/client/sessions/session-1/tokens/t3-relay"):
                body = #"{"jwt":"clerk-template-token"}"#
            case ("relay.example", "/v1/environments"):
                body =
                    #"{"environments":[{"environmentId":"mini-connect","label":"Relay mini","endpoint":{"httpBaseUrl":"https://remote.example/","wsBaseUrl":"wss://remote.example/","providerKind":"cloudflare_tunnel"},"linkedAt":"2026-07-27T00:00:00Z"}]}"#
            case ("relay.example", "/v1/client/dpop-token"):
                body =
                    #"{"access_token":"relay-access","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":3600,"scope":"environment:status environment:connect"}"#
            case ("relay.example", "/v1/environments/mini-connect/status"):
                body =
                    #"{"environmentId":"mini-connect","endpoint":{"httpBaseUrl":"https://remote.example/","wsBaseUrl":"wss://remote.example/","providerKind":"cloudflare_tunnel"},"status":"online","checkedAt":"2026-07-27T00:00:00Z"}"#
            case ("relay.example", "/v1/environments/mini-connect/connect"):
                body =
                    #"{"environmentId":"mini-connect","endpoint":{"httpBaseUrl":"https://remote.example/","wsBaseUrl":"wss://remote.example/","providerKind":"cloudflare_tunnel"},"credential":"environment-bootstrap","expiresAt":"2026-07-27T01:00:00Z"}"#
            case ("remote.example", "/oauth/token"):
                body =
                    #"{"access_token":"environment-access","token_type":"DPoP","expires_in":3600,"scope":"orchestration:read orchestration:operate"}"#
            case ("remote.example", "/api/auth/session"):
                body = #"{"authenticated":true}"#
            case ("remote.example", "/.well-known/t3/environment"):
                body =
                    #"{"environmentId":"mini-connect","label":"Relay mini","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"1.2.3"}"#
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )!,
                Data(body.utf8)
            )
        }
        defer { MockRemoteURLProtocol.handler = nil }
        let signer = try DPoPSigner()
        let client = T3ConnectClient(
            configuration: configuration,
            vault: store,
            signer: signer,
            session: session,
            requestObserver: { observed.append($0) }
        )
        let environments = try await client.listEnvironments()
        let environment = try #require(environments.first)
        let result = try await client.connect(environment)

        #expect(result.profile.environmentID == EnvironmentID("mini-connect"))
        #expect(result.profile.source == .t3Connect)
        #expect(result.profile.directEndpoint?.httpBaseURL.scheme == "https")
        let saved = try store.document()
        #expect(saved.importedT3Connect?.clerkClientJWT == clerkClientJWT(subject: "rotated"))
        #expect(
            saved.connectEnvironmentCredentials["mini-connect"]?.accessToken
                == "environment-access"
        )
        #expect(saved.relayAccessTokens.values.first?.accessToken == "relay-access")

        let relayExchange = try #require(
            observed.requests.first { $0.url?.path == "/v1/client/dpop-token" }
        )
        let relayFields = formFields(try #require(relayExchange.httpBody))
        #expect(relayFields["client_id"] == "t3-web")
        #expect(relayFields["scope"] == "environment:status environment:connect")
        #expect(relayFields["subject_token"] == "clerk-template-token")
        #expect(relayExchange.value(forHTTPHeaderField: "DPoP") != nil)
        let clerkClientRequest = try #require(
            network.requests.first { $0.url?.path == "/v1/client" }
        )
        let clerkClientURL = try #require(clerkClientRequest.url)
        let clerkQuery = try #require(
            URLComponents(
                url: clerkClientURL,
                resolvingAgainstBaseURL: false
            )
        ).queryItems ?? []
        let clerkQueryValues = Dictionary(
            uniqueKeysWithValues: clerkQuery.compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        // Pinned to the versions in T3 Code's current Clerk/Electron client contract.
        #expect(clerkQueryValues["__clerk_api_version"] == "2026-05-12")
        #expect(clerkQueryValues["_clerk_js_version"] == "6.25.7")
        #expect(clerkQueryValues["_is_native"] == "1")
        #expect(clerkQueryValues["_electron_sdk_version"] == "0.0.18")
        #expect(clerkClientRequest.value(forHTTPHeaderField: "Clerk-API-Version") == nil)
        let clerkTokenRequest = try #require(
            network.requests.first {
                $0.url?.path == "/v1/client/sessions/session-1/tokens/t3-relay"
            }
        )
        #expect(
            clerkTokenRequest.value(forHTTPHeaderField: "Content-Type")
                == "application/x-www-form-urlencoded"
        )
        let status = try #require(
            observed.requests.first {
                $0.url?.path == "/v1/environments/mini-connect/status"
            }
        )
        #expect(status.value(forHTTPHeaderField: "Authorization") == "DPoP relay-access")
        #expect(status.value(forHTTPHeaderField: "DPoP") != nil)
        let connect = try #require(
            observed.requests.first {
                $0.url?.path == "/v1/environments/mini-connect/connect"
            }
        )
        let connectBody = try #require(connect.httpBody)
        let connectObject = try JSONSerialization.jsonObject(with: connectBody)
        let connectJSON = try #require(connectObject as? [String: String])
        let thumbprint = try await signer.thumbprint()
        #expect(connectJSON["clientProofKeyThumbprint"] == thumbprint)
        #expect(
            network.requests.contains {
                $0.url?.path == "/api/auth/session"
                    && $0.value(forHTTPHeaderField: "Authorization")
                        == "DPoP environment-access"
            }
        )
    }

    @Test func connectRejectsInactiveClerkSessionAndPurgesOn401() async throws {
        let configuration = try connectConfiguration()
        var document = RemoteCredentialDocument()
        document.importedT3Connect = ImportedT3ConnectCredential(
            clerkClientJWT: clerkClientJWT(subject: "user"),
            ciphertextFingerprint: "fingerprint"
        )
        document.relayAccessTokens["old"] = RemoteAccessCredential(
            accessToken: "old",
            expiresAt: .distantFuture,
            source: .t3Connect
        )
        document.connectEnvironmentCredentials["mini"] = RemoteAccessCredential(
            accessToken: "old-env",
            expiresAt: .distantFuture,
            source: .t3Connect
        )
        let store = MemoryCredentialStore(document)
        let rejectClerkClient = BooleanFlag()
        let session = mockSession { request in
            guard request.url?.path == "/v1/client" else {
                throw URLError(.badURL)
            }
            let status = rejectClerkClient.isSet ? 401 : 200
            let body = rejectClerkClient.isSet
                ? #"{"code":"unauthorized"}"#
                : #"{"last_active_session_id":null,"sessions":[{"id":"session-1","status":"ended"}]}"#
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { MockRemoteURLProtocol.handler = nil }
        let client = T3ConnectClient(
            configuration: configuration,
            vault: store,
            signer: try DPoPSigner(),
            session: session
        )
        do {
            _ = try await client.listEnvironments()
            Issue.record("Inactive sessions must be refused")
        } catch T3ConnectError.invalidClerkSession {
            // expected
        }
        // Move the Clerk client endpoint into its 401 phase.
        rejectClerkClient.set()
        do {
            _ = try await client.listEnvironments()
            Issue.record("A Clerk 401 must require import again")
        } catch T3ConnectError.unauthorized {
            // expected
        }
        let purged = try store.document()
        #expect(purged.importedT3Connect == nil)
        #expect(purged.relayAccessTokens.isEmpty)
        #expect(purged.connectEnvironmentCredentials.isEmpty)
    }

    @Test func connectUsesSoleSignedInSessionWhenLastActiveSessionIsMissing() async throws {
        let configuration = try connectConfiguration()
        var document = RemoteCredentialDocument()
        document.importedT3Connect = ImportedT3ConnectCredential(
            clerkClientJWT: clerkClientJWT(subject: "user"),
            ciphertextFingerprint: "fingerprint"
        )
        let store = MemoryCredentialStore(document)
        let session = mockSession { request in
            let path = request.url?.path ?? ""
            let body: String
            switch path {
            case "/v1/client":
                body =
                    #"{"response":{"last_active_session_id":null,"sessions":[{"id":"session-1","status":"active"}]}}"#
            case "/v1/client/sessions/session-1/tokens/t3-relay":
                body = #"{"jwt":"clerk-template-token"}"#
            case "/v1/environments":
                body = #"{"environments":[]}"#
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { MockRemoteURLProtocol.handler = nil }
        let client = T3ConnectClient(
            configuration: configuration,
            vault: store,
            signer: try DPoPSigner(),
            session: session
        )

        #expect(try await client.listEnvironments().isEmpty)
    }

    @Test func rejectedRelayTokenIsInvalidatedAndRetriedExactlyOnce() async throws {
        let configuration = try connectConfiguration()
        var document = RemoteCredentialDocument()
        document.importedT3Connect = ImportedT3ConnectCredential(
            clerkClientJWT: clerkClientJWT(subject: "user"),
            ciphertextFingerprint: "fingerprint"
        )
        let store = MemoryCredentialStore(document)
        let exchanges = Counter()
        let statuses = Counter()
        let session = mockSession { request in
            let path = request.url?.path ?? ""
            let body: String
            let statusCode: Int
            switch path {
            case "/v1/client":
                body =
                    #"{"last_active_session_id":"session-1","sessions":[{"id":"session-1","status":"active"}]}"#
                statusCode = 200
            case "/v1/client/sessions/session-1/tokens/t3-relay":
                body = #"{"jwt":"clerk-template-token"}"#
                statusCode = 200
            case "/v1/client/dpop-token":
                let number = exchanges.increment()
                body =
                    #"{"access_token":"relay-\#(number)","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":3600,"scope":"environment:status environment:connect"}"#
                statusCode = 200
            case "/v1/environments/mini/status":
                let number = statuses.increment()
                statusCode = number == 1 ? 401 : 200
                body = number == 1
                    ? #"{"code":"auth_invalid"}"#
                    : #"{"environmentId":"mini","status":"online"}"#
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { MockRemoteURLProtocol.handler = nil }
        let client = T3ConnectClient(
            configuration: configuration,
            vault: store,
            signer: try DPoPSigner(),
            session: session
        )
        let environment = T3ConnectEnvironment(
            environmentID: EnvironmentID("mini"),
            label: "Mini",
            endpoint: nil,
            linkedAt: nil
        )
        #expect(try await client.status(environment))
        #expect(exchanges.count == 2)
        #expect(statuses.count == 2)
        #expect(try store.document().relayAccessTokens.values.first?.accessToken == "relay-2")
    }
}

private func mockSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockRemoteURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockRemoteURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func decodeBase64URL(_ value: String) throws -> Data {
    var encoded = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    return try #require(Data(base64Encoded: encoded))
}

private func jsonObject(_ encoded: String) throws -> [String: Any] {
    let data = try decodeBase64URL(encoded)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func formFields(_ data: Data) -> [String: String] {
    guard let body = String(data: data, encoding: .utf8) else { return [:] }
    return Dictionary(
        body.split(separator: "&").compactMap { field -> (String, String)? in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            func decode(_ value: Substring) -> String? {
                String(value)
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding
            }
            guard let name = decode(pair[0]), let value = decode(pair[1]) else {
                return nil
            }
            return (name, value)
        },
        uniquingKeysWith: { _, latest in latest }
    )
}

private func connectConfiguration() throws -> T3ConnectConfiguration {
    let frontend = Data("clerk.example$".utf8).base64URLEncodedString()
    return try T3ConnectConfiguration(
        clerkPublishableKey: "pk_test_\(frontend)",
        clerkJWTTemplate: "t3-relay",
        relayURL: try #require(URL(string: "https://relay.example/"))
    )
}

private func clerkClientJWT(subject: String) -> String {
    let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
    let payload = Data(
        #"{"iss":"https://clerk.example","sub":"\#(subject)"}"#.utf8
    ).base64URLEncodedString()
    return "\(header).\(payload).signature"
}
