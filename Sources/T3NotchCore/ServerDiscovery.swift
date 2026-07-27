import Foundation

public enum ServerEndpointError: Error, LocalizedError, Sendable {
    case unsupportedScheme
    case missingHost
    case credentialsNotAllowed

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme: "Only HTTP and HTTPS endpoints are supported."
        case .missingHost: "The endpoint is missing a host."
        case .credentialsNotAllowed: "Endpoint URLs cannot contain credentials."
        }
    }
}

public struct ServerEndpoint: Codable, Sendable, Equatable, Hashable {
    public let httpBaseURL: URL

    public init(httpBaseURL: URL) throws {
        guard let scheme = httpBaseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ServerEndpointError.unsupportedScheme
        }
        guard httpBaseURL.host != nil else {
            throw ServerEndpointError.missingHost
        }
        var components = URLComponents(url: httpBaseURL, resolvingAgainstBaseURL: false)
        guard components?.user == nil, components?.password == nil else {
            throw ServerEndpointError.credentialsNotAllowed
        }
        components?.scheme = scheme
        components?.path = "/"
        components?.query = nil
        components?.fragment = nil
        guard let canonical = components?.url else {
            throw ServerEndpointError.missingHost
        }
        self.httpBaseURL = canonical
    }

    public init(host: String = "127.0.0.1", port: Int = 3773) {
        if host.contains(":") {
            let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            self.httpBaseURL = URL(string: "http://[\(literal)]:\(port)/")!
            return
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        self.httpBaseURL = components.url!
    }

    public var host: String { httpBaseURL.host ?? "" }
    public var port: Int {
        httpBaseURL.port ?? (httpBaseURL.scheme == "https" ? 443 : 80)
    }

    public var baseURL: URL {
        httpBaseURL
    }

    public var webSocketBaseURL: URL {
        var components = URLComponents(url: httpBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = httpBaseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    public var isLoopback: Bool {
        host == "127.0.0.1" || host == "::1" || host.lowercased() == "localhost"
    }
}

public enum ServerDiscovery {
    public static let defaultPort = 3773

    /// Probe port 3773 first; fall back to `~/.t3/userdata/server-runtime.json`.
    public static func resolveEndpoint(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        session: URLSession = .shared
    ) async -> ServerEndpoint {
        let primary = ServerEndpoint(port: defaultPort)
        if await isReachable(primary, session: session) {
            return primary
        }
        if let fromFile = readRuntimePort(home: home) {
            let candidate = ServerEndpoint(port: fromFile)
            if await isReachable(candidate, session: session) {
                return candidate
            }
        }
        return primary
    }

    public static func isReachable(
        _ endpoint: ServerEndpoint,
        session: URLSession = .shared
    ) async -> Bool {
        let url = endpoint.baseURL.appendingPathComponent(".well-known/t3/environment")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    public static func readRuntimePort(home: URL) -> Int? {
        let path = home
            .appendingPathComponent(".t3")
            .appendingPathComponent("userdata")
            .appendingPathComponent("server-runtime.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let port = json["port"] as? Int {
            return port
        }
        if let port = json["port"] as? Double {
            return Int(port)
        }
        if let nested = json["server"] as? [String: Any], let port = nested["port"] as? Int {
            return port
        }
        return nil
    }
}
