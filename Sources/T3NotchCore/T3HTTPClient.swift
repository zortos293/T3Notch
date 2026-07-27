import Foundation

public enum T3HTTPError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case httpStatus(Int, String)
    case decoding(Error)
    case transport(Error)
    case authorization(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .unauthorized:
            return "The environment rejected this session."
        case let .httpStatus(code, body):
            return "HTTP \(code): \(body.prefix(200))"
        case let .decoding(error):
            return "Decode failed: \(error.localizedDescription)"
        case let .transport(error), let .authorization(error):
            return error.localizedDescription
        }
    }
}

public protocol HTTPAuthorizer: Sendable {
    func authorize(_ request: URLRequest) async throws -> URLRequest
}

public struct NoHTTPAuthorizer: HTTPAuthorizer {
    public init() {}
    public func authorize(_ request: URLRequest) async throws -> URLRequest { request }
}

public struct BearerHTTPAuthorizer: HTTPAuthorizer {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

public actor DPoPHTTPAuthorizer: HTTPAuthorizer {
    private var accessToken: String
    private let signer: DPoPSigner

    public init(accessToken: String, signer: DPoPSigner) {
        self.accessToken = accessToken
        self.signer = signer
    }

    public func update(accessToken: String) {
        self.accessToken = accessToken
    }

    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        guard let url = request.url else { throw T3HTTPError.invalidURL }
        var request = request
        let proof = try await signer.createProof(
            method: request.httpMethod ?? "GET",
            url: url,
            accessToken: accessToken
        )
        request.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        return request
    }
}

public actor T3HTTPClient {
    public private(set) var endpoint: ServerEndpoint
    private var authorizer: any HTTPAuthorizer
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        endpoint: ServerEndpoint,
        authorizer: any HTTPAuthorizer,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.authorizer = authorizer
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Compatibility initializer for the local auto-minted bearer session.
    public init(
        endpoint: ServerEndpoint,
        token: String,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.authorizer = BearerHTTPAuthorizer(token: token)
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func update(endpoint: ServerEndpoint, authorizer: any HTTPAuthorizer) {
        self.endpoint = endpoint
        self.authorizer = authorizer
    }

    public func update(endpoint: ServerEndpoint, token: String) {
        self.endpoint = endpoint
        self.authorizer = BearerHTTPAuthorizer(token: token)
    }

    public func fetchEnvironment() async throws -> EnvironmentDescriptor {
        try await get(path: "/.well-known/t3/environment")
    }

    /// Checks the credential at the endpoint that actually enforces session
    /// authorization. The descriptor is intentionally public and is therefore
    /// not sufficient verification after a one-time pairing exchange.
    public func verifySession() async throws {
        let request = try await makeRequest(
            path: "/api/auth/session",
            method: "GET",
            body: nil as Data?
        )
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw T3HTTPError.httpStatus(-1, "No HTTP response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw T3HTTPError.unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                // Do not attach the session response body to an error.
                throw T3HTTPError.httpStatus(http.statusCode, "")
            }
        } catch let error as T3HTTPError {
            throw error
        } catch {
            throw T3HTTPError.transport(error)
        }
    }

    public func fetchShell() async throws -> ShellSnapshot {
        try await get(path: "/api/orchestration/shell")
    }

    public func fetchThreadDetail(_ threadId: String) async throws -> ThreadDetailSnapshot {
        let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? threadId
        return try await get(path: "/api/orchestration/threads/\(encoded)")
    }

    public func dispatch(_ command: DispatchCommand) async throws -> DispatchResult {
        try await post(path: "/api/orchestration/dispatch", body: command)
    }

    public func get<T: Decodable>(path: String) async throws -> T {
        let request = try await makeRequest(path: path, method: "GET", body: nil as Data?)
        return try await perform(request)
    }

    public func post<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        let data = try encoder.encode(body)
        let request = try await makeRequest(path: path, method: "POST", body: data)
        return try await perform(request)
    }

    private func makeRequest(path: String, method: String, body: Data?) async throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else {
            throw T3HTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            return try await authorizer.authorize(request)
        } catch {
            throw T3HTTPError.authorization(error)
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw T3HTTPError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw T3HTTPError.httpStatus(-1, "No HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw T3HTTPError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw T3HTTPError.httpStatus(http.statusCode, body)
        }
        if data.isEmpty, T.self == DispatchResult.self {
            return DispatchResult(ok: true) as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw T3HTTPError.decoding(error)
        }
    }
}
