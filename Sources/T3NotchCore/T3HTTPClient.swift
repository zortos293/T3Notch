import Foundation

public enum T3HTTPError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case dispatchRejected
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
        case .dispatchRejected:
            return "T3 Code could not complete the action."
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
        let token = accessToken
        let proof = try await signer.createProof(
            method: request.httpMethod ?? "GET",
            url: url,
            accessToken: token
        )
        request.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
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
    private var endpointGeneration = 0
    private var usesOrchestrationV2: Bool?

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
        endpointGeneration += 1
        usesOrchestrationV2 = nil
    }

    public func update(endpoint: ServerEndpoint, token: String) {
        update(endpoint: endpoint, authorizer: BearerHTTPAuthorizer(token: token))
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
        let generation = endpointGeneration
        let endpointIsLocal = endpoint.isLoopback
        var observedAt = Date.now
        let request = try await makeRequest(path: "/api/orchestration/shell", method: "GET", body: nil)
        let response: ShellResponse = try await perform(request) { http in
            guard !endpointIsLocal, let header = http.value(forHTTPHeaderField: "Date") else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            observedAt = formatter.date(from: header) ?? observedAt
        }
        guard generation == endpointGeneration else { throw CancellationError() }
        usesOrchestrationV2 = response.isV2
        var snapshot = response.snapshot
        snapshot.observedAt = observedAt
        return snapshot
    }

    public func fetchThreadDetail(_ threadId: String) async throws -> ThreadDetailSnapshot {
        let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? threadId
        let response: DetailResponse = try await get(path: "/api/orchestration/threads/\(encoded)")
        return response.snapshot
    }

    public func dispatch(_ command: DispatchCommand) async throws -> DispatchResult {
        let generation = endpointGeneration
        if usesOrchestrationV2 == nil {
            _ = try await fetchShell()
        }
        guard generation == endpointGeneration else { throw CancellationError() }
        if usesOrchestrationV2 == true {
            return try await dispatchV2(command, generation: generation)
        }
        let request = try await makeRequest(
            path: "/api/orchestration/dispatch", method: "POST", body: encoder.encode(command)
        )
        guard generation == endpointGeneration else { throw CancellationError() }
        let result: DispatchResult = try await perform(request)
        guard result.accepted != false, result.ok != false else { throw T3HTTPError.dispatchRejected }
        return result
    }

    private func dispatchV2(_ command: DispatchCommand, generation: Int) async throws -> DispatchResult {
        struct Ticket: Decodable { let ticket: String }
        let frame = try OrchestrationV2CommandFrame(command: command)
        let endpointURL = endpoint.baseURL
        let request = try await makeRequest(path: "/api/auth/websocket-ticket", method: "POST", body: nil)
        let ticket: Ticket = try await perform(request)
        guard generation == endpointGeneration else { throw CancellationError() }
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: true) else {
            throw T3HTTPError.invalidURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "orchestrationProtocol", value: "2"),
            URLQueryItem(name: "wsTicket", value: ticket.ticket),
        ]
        guard let url = components.url else { throw T3HTTPError.invalidURL }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(8))
                socket.cancel()
            } catch {}
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        do {
            let outgoing = String(decoding: try encoder.encode(frame), as: UTF8.self)
            try await socket.send(.string(outgoing))
            while true {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                let reply = try decoder.decode(JSONValue.self, from: data)
                switch reply["_tag"]?.stringValue {
                case "Ping":
                    try await socket.send(.string(#"{"_tag":"Pong"}"#))
                case "Exit":
                    guard reply["requestId"]?.numberValue == 1 || reply["requestId"]?.stringValue == "1" else {
                        continue
                    }
                    guard reply["exit"]?["_tag"]?.stringValue == "Success",
                          let sequence = reply["exit"]?["value"]?["sequence"]?.numberValue.flatMap(Int.init(exactly:))
                    else { throw T3HTTPError.dispatchRejected }
                    return DispatchResult(sequence: sequence)
                default:
                    continue
                }
            }
        } catch {
            // Transport errors can include the one-time ticket in the URL.
            throw T3HTTPError.dispatchRejected
        }
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
        if path.hasPrefix("/api/orchestration/") {
            request.setValue("2", forHTTPHeaderField: "X-T3-Orchestration-Protocol")
        }
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

    private func perform<T: Decodable>(
        _ request: URLRequest, inspectResponse: ((HTTPURLResponse) -> Void)? = nil
    ) async throws -> T {
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
        inspectResponse?(http)
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

private struct ShellResponse: Decodable {
    let snapshot: ShellSnapshot
    let isV2: Bool

    init(from decoder: Decoder) throws {
        if let legacy = try? ShellSnapshot(from: decoder) {
            snapshot = legacy
            isV2 = false
        } else {
            snapshot = try OrchestrationV2Shell(from: decoder).snapshot
            isV2 = true
        }
    }
}

private struct DetailResponse: Decodable {
    let snapshot: ThreadDetailSnapshot

    init(from decoder: Decoder) throws {
        if let legacy = try? ThreadDetailSnapshot(from: decoder) {
            snapshot = legacy
        } else {
            let response = try OrchestrationV2Detail(from: decoder)
            snapshot = ThreadDetailSnapshot(
                snapshotSequence: response.snapshotSequence,
                thread: response.projection.detail
            )
        }
    }
}
