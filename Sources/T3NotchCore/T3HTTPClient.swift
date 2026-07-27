import Foundation

public enum T3HTTPError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case httpStatus(Int, String)
    case decoding(Error)
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .unauthorized:
            return "Unauthorized — mint a new bearer token"
        case let .httpStatus(code, body):
            return "HTTP \(code): \(body.prefix(200))"
        case let .decoding(error):
            return "Decode failed: \(error.localizedDescription)"
        case let .transport(error):
            return error.localizedDescription
        }
    }
}

public actor T3HTTPClient {
    public private(set) var endpoint: ServerEndpoint
    public private(set) var token: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        endpoint: ServerEndpoint,
        token: String,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    public func update(endpoint: ServerEndpoint, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    public func fetchEnvironment() async throws -> EnvironmentDescriptor {
        try await get(path: "/.well-known/t3/environment")
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

    private func get<T: Decodable>(path: String) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", body: nil as Data?)
        return try await perform(request)
    }

    private func post<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        let data = try encoder.encode(body)
        let request = try makeRequest(path: path, method: "POST", body: data)
        return try await perform(request)
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else {
            throw T3HTTPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
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
        // Empty success bodies (rare).
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
