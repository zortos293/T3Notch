import Foundation

public struct ServerEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String = "127.0.0.1", port: Int = 3773) {
        self.host = host
        self.port = port
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
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
