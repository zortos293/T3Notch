import Foundation

public protocol AgentTransport: AnyObject, Sendable {
    var shell: AsyncStream<ShellSnapshot> { get }
    var connectionState: ConnectionState { get }
    var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? { get set }
    func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot>
    func dispatch(_ command: DispatchCommand) async throws
    func requestImmediatePoll()
    func setFocusedThread(_ id: String?)
    func setExpanded(_ expanded: Bool)
    func stop()
}

@available(*, deprecated, renamed: "AgentTransport")
public typealias T3Transport = AgentTransport

/// Raised by local (non-HTTP) transports; `PollingTransport` keeps throwing
/// `T3HTTPError`.
public enum AgentTransportError: Error, Sendable {
    /// Command kind this transport cannot serve.
    case unsupported(String)
    case threadNotFound(String)
    /// Approval already resolved, or the hook connection holding it is gone.
    case requestExpired(String)
}

public enum ConnectionState: String, Sendable, Equatable {
    case connecting
    case connected
    case disconnected
    case unauthorized
}
