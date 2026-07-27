import Foundation

public enum RemotePairingError: Error, LocalizedError, Sendable {
    case invalidPairingURL
    case missingBackend
    case missingCredential
    case insecureHTTPNeedsConfirmation
    case environmentUnavailable
    case environmentIdentityMissing
    case environmentMismatch
    case tokenRejected
    case unexpectedTokenType
    case unexpectedScopes
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidPairingURL: "The pairing URL is invalid."
        case .missingBackend: "Enter a backend URL."
        case .missingCredential: "Enter a pairing code."
        case .insecureHTTPNeedsConfirmation:
            "This machine uses unencrypted HTTP. Confirm the insecure connection to continue."
        case .environmentUnavailable: "The remote T3 Code environment could not be reached."
        case .environmentIdentityMissing: "The remote environment did not report a stable identity."
        case .environmentMismatch: "The remote endpoint changed to a different environment."
        case .tokenRejected: "The pairing credential was rejected or expired."
        case .unexpectedTokenType: "The environment did not issue a DPoP-bound session."
        case .unexpectedScopes: "The environment granted different permissions than requested."
        case .malformedResponse: "The remote environment returned an invalid response."
        }
    }
}

public struct RemotePairingTarget: Sendable, Equatable {
    public let endpoint: ServerEndpoint
    public let credential: String

    public init(pairingURL raw: String) throws {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? "")
        else {
            throw RemotePairingError.invalidPairingURL
        }
        let hash = URLComponents(string: "?\(url.fragment ?? "")")?.queryItems ?? []
        let token = hash.first(where: { $0.name == "token" })?.value
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "token" })?.value
        guard let credential = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credential.isEmpty
        else {
            throw RemotePairingError.missingCredential
        }

        let backend: URL
        if url.host?.lowercased() == "app.t3.codes",
           let hostValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "host" })?.value
        {
            backend = try Self.normalizedURL(hostValue)
        } else {
            backend = try Self.normalizedURL(url.absoluteString)
        }
        self.endpoint = try ServerEndpoint(httpBaseURL: backend)
        self.credential = credential
    }

    public init(host rawHost: String, pairingCode: String) throws {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw RemotePairingError.missingCredential }
        self.endpoint = try ServerEndpoint(httpBaseURL: Self.normalizedURL(rawHost))
        self.credential = code
    }

    private static func normalizedURL(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RemotePairingError.missingBackend }
        value = value.replacingOccurrences(of: #"^/+"#, with: "", options: .regularExpression)
        if !value.contains("://") {
            value = "https://\(value)"
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              components.host != nil
        else {
            throw RemotePairingError.invalidPairingURL
        }
        components.scheme = switch scheme {
        case "ws": "http"
        case "wss": "https"
        default: scheme
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RemotePairingError.invalidPairingURL }
        return url
    }
}

public struct RemotePairingResult: Sendable {
    public let profile: EnvironmentProfile
    public let descriptor: EnvironmentDescriptor
    public let credential: RemoteAccessCredential

    public init(
        profile: EnvironmentProfile,
        descriptor: EnvironmentDescriptor,
        credential: RemoteAccessCredential
    ) {
        self.profile = profile
        self.descriptor = descriptor
        self.credential = credential
    }
}

public actor RemotePairingClient {
    public static let scopes = ["orchestration:read", "orchestration:operate"]

    private let session: URLSession
    private let signer: DPoPSigner
    private let requestObserver: (@Sendable (URLRequest) -> Void)?

    public init(session: URLSession = .shared, signer: DPoPSigner) {
        self.session = session
        self.signer = signer
        self.requestObserver = nil
    }

    init(
        session: URLSession,
        signer: DPoPSigner,
        requestObserver: @escaping @Sendable (URLRequest) -> Void
    ) {
        self.session = session
        self.signer = signer
        self.requestObserver = requestObserver
    }

    public func pair(
        target: RemotePairingTarget,
        allowsInsecureHTTP: Bool = false,
        source: EnvironmentSource = .direct,
        expectedEnvironmentID: EnvironmentID? = nil
    ) async throws -> RemotePairingResult {
        if target.endpoint.httpBaseURL.scheme == "http",
           !target.endpoint.isLoopback,
           !allowsInsecureHTTP
        {
            throw RemotePairingError.insecureHTTPNeedsConfirmation
        }

        let descriptor = try await fetchDescriptor(endpoint: target.endpoint)
        guard let rawEnvironmentID = descriptor.environmentId?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !rawEnvironmentID.isEmpty
        else {
            throw RemotePairingError.environmentIdentityMissing
        }
        let environmentID = EnvironmentID(rawEnvironmentID)
        if let expectedEnvironmentID, expectedEnvironmentID != environmentID {
            throw RemotePairingError.environmentMismatch
        }

        let tokenURL = target.endpoint.baseURL.appendingPathComponent("oauth/token")
        let proof = try await signer.createProof(method: "POST", url: tokenURL)
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.httpBody = Self.formEncoded([
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", target.credential),
            (
                "subject_token_type",
                "urn:t3:params:oauth:token-type:environment-bootstrap"
            ),
            (
                "requested_token_type",
                "urn:ietf:params:oauth:token-type:access_token"
            ),
            ("scope", Self.scopes.joined(separator: " ")),
            ("client_label", "T3Notch"),
            ("client_device_type", "desktop"),
            ("client_os", "macOS"),
        ])

        requestObserver?(request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemotePairingError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemotePairingError.tokenRejected
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard token.tokenType == "DPoP" else {
            throw RemotePairingError.unexpectedTokenType
        }
        guard Set(token.scope.split(separator: " ").map(String.init)) == Set(Self.scopes) else {
            throw RemotePairingError.unexpectedScopes
        }

        let authorizer = DPoPHTTPAuthorizer(accessToken: token.accessToken, signer: signer)
        let client = T3HTTPClient(
            endpoint: target.endpoint,
            authorizer: authorizer,
            session: session
        )
        try await client.verifySession()
        let verifiedDescriptor = try await client.fetchEnvironment()
        guard verifiedDescriptor.environmentId == rawEnvironmentID else {
            throw RemotePairingError.environmentMismatch
        }
        let profile = EnvironmentProfile(
            environmentID: environmentID,
            label: descriptor.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? rawEnvironmentID,
            directEndpoint: target.endpoint,
            source: source,
            enabled: true,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        return RemotePairingResult(
            profile: profile,
            descriptor: descriptor,
            credential: RemoteAccessCredential(
                accessToken: token.accessToken,
                expiresAt: Date().addingTimeInterval(token.expiresIn),
                source: source
            )
        )
    }

    private func fetchDescriptor(endpoint: ServerEndpoint) async throws -> EnvironmentDescriptor {
        let url = endpoint.baseURL
            .appendingPathComponent(".well-known/t3/environment")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw RemotePairingError.environmentUnavailable
            }
            return try JSONDecoder().decode(EnvironmentDescriptor.self, from: data)
        } catch let error as RemotePairingError {
            throw error
        } catch {
            throw RemotePairingError.environmentUnavailable
        }
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map(URLQueryItem.init)
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: TimeInterval
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}
