import Foundation

public struct T3ConnectConfiguration: Sendable, Equatable {
    public let clerkPublishableKey: String
    public let clerkJWTTemplate: String
    public let relayURL: URL
    public let clerkFrontendURL: URL

    public init(
        clerkPublishableKey: String,
        clerkJWTTemplate: String,
        relayURL: URL
    ) throws {
        guard relayURL.scheme == "https", relayURL.host != nil else {
            throw T3ConnectError.invalidConfiguration
        }
        guard let frontend = Self.frontendURL(from: clerkPublishableKey) else {
            throw T3ConnectError.invalidConfiguration
        }
        self.clerkPublishableKey = clerkPublishableKey
        self.clerkJWTTemplate = clerkJWTTemplate
        self.relayURL = relayURL
        self.clerkFrontendURL = frontend
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> T3ConnectConfiguration? {
        let key = environment["T3CODE_CLERK_PUBLISHABLE_KEY"]
            ?? bundle.object(forInfoDictionaryKey: "T3ConnectClerkPublishableKey") as? String
        let template = environment["T3CODE_CLERK_JWT_TEMPLATE"]
            ?? bundle.object(forInfoDictionaryKey: "T3ConnectJWTTemplate") as? String
        let relay = environment["T3CODE_RELAY_URL"]
            ?? bundle.object(forInfoDictionaryKey: "T3ConnectRelayURL") as? String
        guard let key, let template, let relay, let relayURL = URL(string: relay) else {
            return nil
        }
        return try? T3ConnectConfiguration(
            clerkPublishableKey: key,
            clerkJWTTemplate: template,
            relayURL: relayURL
        )
    }

    private static func frontendURL(from publishableKey: String) -> URL? {
        let parts = publishableKey.split(separator: "_", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              var host = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "$")).lowercased()
        guard Self.isValidASCIIHostname(host) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/"
        guard let url = components.url, url.host?.lowercased() == host else {
            return nil
        }
        return url
    }

    private static func isValidASCIIHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host.last != "." else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  Self.isASCIIAlphanumeric(first),
                  Self.isASCIIAlphanumeric(last)
            else {
                return false
            }
            return label.utf8.allSatisfy {
                Self.isASCIIAlphanumeric($0) || $0 == 45
            }
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }
}

public struct T3ConnectEnvironment: Identifiable, Sendable, Equatable {
    public let environmentID: EnvironmentID
    public let label: String
    public let endpoint: ServerEndpoint?
    public let linkedAt: String?

    public var id: EnvironmentID { environmentID }

    public init(
        environmentID: EnvironmentID,
        label: String,
        endpoint: ServerEndpoint?,
        linkedAt: String?
    ) {
        self.environmentID = environmentID
        self.label = label
        self.endpoint = endpoint
        self.linkedAt = linkedAt
    }
}

public enum T3ConnectError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case notImported
    case invalidClerkSession
    case unauthorized
    case invalidResponse
    case environmentOffline
    case environmentMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "T3 Connect public configuration is unavailable."
        case .notImported: "Import the T3 Code sign-in first."
        case .invalidClerkSession: "T3 Code does not have an active compatible sign-in."
        case .unauthorized: "The imported T3 Connect sign-in expired. Import it again."
        case .invalidResponse: "T3 Connect returned an invalid response."
        case .environmentOffline: "The T3 Connect environment is offline."
        case .environmentMismatch: "T3 Connect returned a different environment identity."
        }
    }
}

public actor T3ConnectClient {
    private static let relayScopes = ["environment:status", "environment:connect"]
    // Keep these aligned with the Clerk packages bundled by supported T3 Code builds.
    private static let clerkAPIVersion = "2026-05-12"
    private static let clerkJSVersion = "6.25.7"
    private static let clerkElectronVersion = "0.0.18"

    private let configuration: T3ConnectConfiguration
    private let vault: any RemoteCredentialStoring
    private let signer: DPoPSigner
    private let session: URLSession
    private let requestObserver: (@Sendable (URLRequest) -> Void)?

    public init(
        configuration: T3ConnectConfiguration,
        vault: any RemoteCredentialStoring,
        signer: DPoPSigner,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.vault = vault
        self.signer = signer
        self.session = session
        self.requestObserver = nil
    }

    init(
        configuration: T3ConnectConfiguration,
        vault: any RemoteCredentialStoring,
        signer: DPoPSigner,
        session: URLSession,
        requestObserver: @escaping @Sendable (URLRequest) -> Void
    ) {
        self.configuration = configuration
        self.vault = vault
        self.signer = signer
        self.session = session
        self.requestObserver = requestObserver
    }

    public func importSession(_ imported: ImportedElectronSession) throws {
        try vault.update { document in
            document.importedT3Connect = ImportedT3ConnectCredential(
                clerkClientJWT: imported.clientJWT,
                ciphertextFingerprint: imported.ciphertextFingerprint
            )
        }
    }

    public func forget() throws {
        try vault.forgetT3Connect()
    }

    public func listEnvironments() async throws -> [T3ConnectEnvironment] {
        do {
            let clerkToken = try await clerkTemplateToken()
            var request = URLRequest(
                url: configuration.relayURL.appendingPathComponent("v1/environments")
            )
            request.timeoutInterval = 12
            request.setValue("Bearer \(clerkToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await perform(request)
            let response = try JSONDecoder().decode(RelayEnvironmentList.self, from: data)
            return response.environments.map { record in
                let endpoint = URL(string: record.endpoint.httpBaseURL)
                    .flatMap { try? ServerEndpoint(httpBaseURL: $0) }
                return T3ConnectEnvironment(
                    environmentID: EnvironmentID(record.environmentID),
                    label: record.label,
                    endpoint: endpoint,
                    linkedAt: record.linkedAt
                )
            }
        } catch T3ConnectError.unauthorized {
            try? vault.forgetT3Connect()
            throw T3ConnectError.unauthorized
        }
    }

    public func status(_ environment: T3ConnectEnvironment) async throws -> Bool {
        let url = configuration.relayURL
            .appendingPathComponent("v1/environments")
            .appendingPathComponent(environment.environmentID.rawValue)
            .appendingPathComponent("status")
        let data = try await authorizedRelayRequest(url: url, method: "POST", body: nil)
        let response = try JSONDecoder().decode(RelayStatusResponse.self, from: data)
        guard response.environmentID == environment.environmentID.rawValue else {
            throw T3ConnectError.environmentMismatch
        }
        return response.status == "online"
    }

    public func connect(_ environment: T3ConnectEnvironment) async throws -> RemotePairingResult {
        guard try await status(environment) else {
            throw T3ConnectError.environmentOffline
        }
        let url = configuration.relayURL
            .appendingPathComponent("v1/environments")
            .appendingPathComponent(environment.environmentID.rawValue)
            .appendingPathComponent("connect")
        let thumbprint = try await signer.thumbprint()
        let payload = try JSONEncoder().encode(
            RelayConnectRequest(
                deviceID: Host.current().localizedName,
                clientProofKeyThumbprint: thumbprint
            )
        )
        let data = try await authorizedRelayRequest(url: url, method: "POST", body: payload)
        let bootstrap = try JSONDecoder().decode(RelayConnectResponse.self, from: data)
        guard bootstrap.environmentID == environment.environmentID.rawValue,
              let endpointURL = URL(string: bootstrap.endpoint.httpBaseURL),
              endpointURL.scheme == "https"
        else {
            throw T3ConnectError.environmentMismatch
        }
        let target = try RemotePairingTarget(
            host: endpointURL.absoluteString,
            pairingCode: bootstrap.credential
        )
        let result = try await RemotePairingClient(session: session, signer: signer).pair(
            target: target,
            allowsInsecureHTTP: false,
            source: .t3Connect,
            expectedEnvironmentID: environment.environmentID
        )
        try vault.update { document in
            document.connectEnvironmentCredentials[environment.environmentID.rawValue] =
                result.credential
        }
        return result
    }

    private func authorizedRelayRequest(
        url: URL,
        method: String,
        body: Data?,
        canRetry: Bool = true
    ) async throws -> Data {
        let token = try await relayAccessToken(forceRefresh: false)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DPoP \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try await signer.createProof(method: method, url: url, accessToken: token.accessToken),
            forHTTPHeaderField: "DPoP"
        )
        do {
            return try await perform(request)
        } catch T3ConnectError.unauthorized where canRetry {
            try vault.update { $0.relayAccessTokens.removeAll() }
            _ = try await relayAccessToken(forceRefresh: true)
            return try await authorizedRelayRequest(
                url: url,
                method: method,
                body: body,
                canRetry: false
            )
        }
    }

    private func relayAccessToken(forceRefresh: Bool) async throws -> RemoteAccessCredential {
        let cacheKey = Self.relayScopes.joined(separator: " ")
        if !forceRefresh,
           let cached = try vault.document().relayAccessTokens[cacheKey],
           !cached.needsRefresh
        {
            return cached
        }
        let clerkToken = try await clerkTemplateToken()
        let url = configuration.relayURL.appendingPathComponent("v1/client/dpop-token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            try await signer.createProof(method: "POST", url: url),
            forHTTPHeaderField: "DPoP"
        )
        request.httpBody = Self.formEncoded([
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", clerkToken),
            ("subject_token_type", "urn:ietf:params:oauth:token-type:jwt"),
            (
                "requested_token_type",
                "urn:ietf:params:oauth:token-type:access_token"
            ),
            ("resource", configuration.relayURL.absoluteString),
            ("scope", cacheKey),
            ("client_id", "t3-web"),
        ])
        let data = try await perform(request)
        let response = try JSONDecoder().decode(RelayTokenResponse.self, from: data)
        guard response.tokenType == "DPoP",
              response.issuedTokenType
                == "urn:ietf:params:oauth:token-type:access_token",
              Set(response.scope.split(separator: " ").map(String.init)) == Set(Self.relayScopes)
        else {
            throw T3ConnectError.invalidResponse
        }
        let credential = RemoteAccessCredential(
            accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            source: .t3Connect
        )
        try vault.update { $0.relayAccessTokens[cacheKey] = credential }
        return credential
    }

    private func clerkTemplateToken() async throws -> String {
        guard let imported = try vault.document().importedT3Connect else {
            throw T3ConnectError.notImported
        }
        try validateClerkClientJWT(imported.clerkClientJWT)
        let clientURL = configuration.clerkFrontendURL.appendingPathComponent("v1/client")
        var clientRequest = clerkRequest(url: clientURL, jwt: imported.clerkClientJWT)
        clientRequest.httpMethod = "GET"
        let (clientData, clientResponse) = try await performWithResponse(clientRequest)
        let clientPayload = try JSONDecoder().decode(
            ClerkResponseEnvelope<ClerkClient>.self,
            from: clientData
        )
        let client = clientPayload.response ?? clientPayload.value
        guard let client else {
            throw T3ConnectError.invalidResponse
        }
        let signedInSessions = client.sessions.filter {
            ["active", "pending"].contains($0.status)
        }
        let lastActiveSession = client.lastActiveSessionID.flatMap { sessionID in
            signedInSessions.first { $0.id == sessionID }
        }
        let selectedSession = lastActiveSession
            ?? (signedInSessions.count == 1 ? signedInSessions[0] : nil)
        guard let sessionID = selectedSession?.id else {
            throw T3ConnectError.invalidClerkSession
        }
        let tokenURL = configuration.clerkFrontendURL
            .appendingPathComponent("v1/client/sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("tokens")
            .appendingPathComponent(configuration.clerkJWTTemplate)
        let currentClientJWT = rotatedJWT(
            from: clientResponse,
            fallback: imported.clerkClientJWT
        )
        var tokenRequest = clerkRequest(url: tokenURL, jwt: currentClientJWT)
        tokenRequest.httpMethod = "POST"
        tokenRequest.httpBody = Data()
        tokenRequest.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        let (tokenData, tokenResponse) = try await performWithResponse(tokenRequest)
        let tokenPayload = try JSONDecoder().decode(
            ClerkResponseEnvelope<ClerkToken>.self,
            from: tokenData
        )
        guard let token = tokenPayload.response ?? tokenPayload.value else {
            throw T3ConnectError.invalidResponse
        }
        let rotated = rotatedJWT(from: tokenResponse, fallback: currentClientJWT)
        try vault.update { document in
            document.importedT3Connect?.clerkClientJWT = rotated
        }
        guard !token.jwt.isEmpty else { throw T3ConnectError.invalidResponse }
        return token.jwt
    }

    private func clerkRequest(url: URL, jwt: String) -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URLRequest(url: url)
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "__clerk_api_version", value: Self.clerkAPIVersion),
            URLQueryItem(name: "_clerk_js_version", value: Self.clerkJSVersion),
            URLQueryItem(name: "_is_native", value: "1"),
            URLQueryItem(
                name: "_electron_sdk_version",
                value: Self.clerkElectronVersion
            ),
        ])
        components.queryItems = queryItems
        var request = URLRequest(url: components.url ?? url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The Clerk Frontend API is the authority for whether a restored client JWT
    /// belongs to this instance. Clerk client JWT issuers are not guaranteed to
    /// equal a custom Frontend API hostname, so host equality here would reject
    /// sessions that the official Electron SDK accepts.
    private func validateClerkClientJWT(_ jwt: String) throws {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payload = Self.decodeBase64URL(String(parts[1])),
              (try JSONSerialization.jsonObject(with: payload)) is [String: Any]
        else {
            throw T3ConnectError.invalidClerkSession
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await performWithResponse(request).0
    }

    private func performWithResponse(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requestObserver?(request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw T3ConnectError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw T3ConnectError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw T3ConnectError.invalidResponse
        }
        return (data, http)
    }

    private func rotatedJWT(from response: HTTPURLResponse, fallback: String) -> String {
        guard let header = response.value(forHTTPHeaderField: "Authorization")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !header.isEmpty
        else {
            return fallback
        }
        return header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : header
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        FormURLEncoding.data(fields)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }
}

private struct ClerkResponseEnvelope<Value: Decodable>: Decodable {
    let response: Value?
    let value: Value?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.response)
        {
            response = try container.decodeIfPresent(Value.self, forKey: .response)
            value = nil
        } else {
            response = nil
            value = try Value(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case response
    }
}

private struct ClerkClient: Decodable {
    struct Session: Decodable {
        let id: String
        let status: String
    }

    let lastActiveSessionID: String?
    let sessions: [Session]

    enum CodingKeys: String, CodingKey {
        case lastActiveSessionID = "last_active_session_id"
        case sessions
    }
}

private struct ClerkToken: Decodable {
    let jwt: String
}

private struct RelayEnvironmentList: Decodable {
    let environments: [RelayEnvironmentRecord]
}

private struct RelayEnvironmentRecord: Decodable {
    let environmentID: String
    let label: String
    let endpoint: RelayEndpoint
    let linkedAt: String?

    enum CodingKeys: String, CodingKey {
        case environmentID = "environmentId"
        case label
        case endpoint
        case linkedAt
    }
}

private struct RelayEndpoint: Codable {
    let httpBaseURL: String
    let wsBaseURL: String?
    let providerKind: String?

    enum CodingKeys: String, CodingKey {
        case httpBaseURL = "httpBaseUrl"
        case wsBaseURL = "wsBaseUrl"
        case providerKind
    }
}

private struct RelayTokenResponse: Decodable {
    let accessToken: String
    let issuedTokenType: String
    let tokenType: String
    let expiresIn: TimeInterval
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case issuedTokenType = "issued_token_type"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct RelayStatusResponse: Decodable {
    let environmentID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case environmentID = "environmentId"
        case status
    }
}

private struct RelayConnectRequest: Encodable {
    let deviceID: String?
    let clientProofKeyThumbprint: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case clientProofKeyThumbprint
    }
}

private struct RelayConnectResponse: Decodable {
    let environmentID: String
    let endpoint: RelayEndpoint
    let credential: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case environmentID = "environmentId"
        case endpoint
        case credential
        case expiresAt
    }
}
