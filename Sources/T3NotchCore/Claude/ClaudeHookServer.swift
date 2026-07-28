import Foundation
import Network
import os

public enum ClaudeHookServerError: Error, Sendable {
    case portUnavailable(UInt16)
}

/// Loopback listener for Claude Code's `command` hooks.
///
/// Every hook posts its JSON payload to `POST /t3notch/hook`. Most events are
/// answered immediately and only nudge the transcript tailer; `PermissionRequest`
/// is different — its HTTP response *is* the approval decision, so the connection
/// is held open until `resolve(requestId:decision:)` or the timeout fires. The
/// timeout answers `ask`, which hands the prompt back to the terminal.
public final class ClaudeHookServer: @unchecked Sendable {
    public struct Event: Sendable {
        public let name: String
        public let sessionId: String?
        public let body: JSONValue

        public init(name: String, sessionId: String?, body: JSONValue) {
            self.name = name
            self.sessionId = sessionId
            self.body = body
        }
    }

    public struct PendingApprovalContext: Sendable {
        public let requestId: String
        public let sessionId: String?
        public let toolName: String?
        /// `command` | `file-read` | `file-change`, as `derivePendingApprovals` expects.
        public let requestKind: String
        public let detail: String?
        public let createdAt: String
    }

    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var pending: [String: NWConnection] = [:]
        var boundPort: UInt16?
        var stopped = false
        var onEvent: (@Sendable (Event) -> Void)?
        var onApprovalRequest: (@Sendable (PendingApprovalContext) -> Void)?
        var onApprovalResolved: (@Sendable (String, ApprovalDecision?) -> Void)?
    }

    public static let hookPath = "/t3notch/hook"
    /// A listener we just cancelled releases the port asynchronously, so an
    /// immediate rebind on the same fixed port reports "address already in use".
    private static let bindAttempts = 5
    private static let bindRetryDelay: UInt64 = 120_000_000

    private let requestedPort: UInt16
    private let approvalTimeout: TimeInterval
    private let queue = DispatchQueue(label: "gg.t3tools.t3notch.claude-hooks")
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// The listener serves on its own queue from the moment it is started, and
    /// these are assigned afterwards from whichever thread wired it up, so all
    /// three live under the lock.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { state.withLock(\.onEvent) }
        set { state.withLock { $0.onEvent = newValue } }
    }

    public var onApprovalRequest: (@Sendable (PendingApprovalContext) -> Void)? {
        get { state.withLock(\.onApprovalRequest) }
        set { state.withLock { $0.onApprovalRequest = newValue } }
    }

    /// Fires for every terminal outcome — dispatch, timeout, or dropped hook
    /// connection — so the transport can clear its pending-approval state.
    public var onApprovalResolved: (@Sendable (String, ApprovalDecision?) -> Void)? {
        get { state.withLock(\.onApprovalResolved) }
        set { state.withLock { $0.onApprovalResolved = newValue } }
    }

    /// `port` 0 binds an ephemeral port (tests); the app passes its fixed port.
    public init(port: UInt16, approvalTimeout: TimeInterval = 110) {
        self.requestedPort = port
        self.approvalTimeout = approvalTimeout
    }

    deinit {
        stop()
    }

    public var boundPort: UInt16? { state.withLock(\.boundPort) }

    /// Async so the caller — the main actor, on launch and on every settings
    /// change — is never blocked waiting for the listener to settle.
    public func start() async throws {
        for attempt in 1...Self.bindAttempts {
            do {
                try await bind()
                return
            } catch ClaudeHookServerError.portUnavailable(let port) {
                guard attempt < Self.bindAttempts else {
                    throw ClaudeHookServerError.portUnavailable(port)
                }
                try? await Task.sleep(nanoseconds: Self.bindRetryDelay)
            }
        }
    }

    private func bind() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ClaudeHookServerError.portUnavailable(requestedPort)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let port = requestedPort
        do {
            try await withCheckedThrowingContinuation { continuation in
                // `.ready` can be followed by later state changes, and a failed
                // listener reports once; either way the continuation resumes once.
                let resumed = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { newState in
                    let outcome: Result<Void, any Error>
                    switch newState {
                    case .ready:
                        outcome = .success(())
                    // `.waiting` means the port is taken; there is no fallback
                    // port because the installed hook URLs name a fixed one.
                    case .failed, .waiting:
                        outcome = .failure(ClaudeHookServerError.portUnavailable(port))
                    default:
                        return
                    }
                    let first = resumed.withLock { resumed -> Bool in
                        guard !resumed else { return false }
                        resumed = true
                        return true
                    }
                    if first { continuation.resume(with: outcome) }
                }
                state.withLock { $0.listener = listener }
                listener.start(queue: queue)
            }
        } catch {
            listener.stateUpdateHandler = nil
            listener.cancel()
            state.withLock { state in
                if state.listener === listener { state.listener = nil }
            }
            throw error
        }
        state.withLock { $0.boundPort = listener.port?.rawValue }
    }

    public func stop() {
        let (listener, connections, pending, resolved) = state.withLock { state -> (NWListener?, [NWConnection], [String: NWConnection], (@Sendable (String, ApprovalDecision?) -> Void)?) in
            state.stopped = true
            let listener = state.listener
            let connections = Array(state.connections.values)
            let pending = state.pending
            state.listener = nil
            state.connections.removeAll()
            state.pending.removeAll()
            state.boundPort = nil
            return (listener, connections, pending, state.onApprovalResolved)
        }

        // A pending approval whose listener goes away must not leave the terminal
        // waiting on curl: answer `ask` so Claude prompts locally.
        let held = Set(pending.values.map(ObjectIdentifier.init))
        for (requestId, connection) in pending {
            send(decision: nil, on: connection)
            resolved?(requestId, nil)
        }
        // Held connections close themselves once that answer is written.
        for connection in connections where !held.contains(ObjectIdentifier(connection)) {
            connection.cancel()
        }
        listener?.cancel()
    }

    /// Answers a held `PermissionRequest`. Returns false when the request is
    /// already gone (resolved, timed out, or the hook hung up).
    @discardableResult
    public func resolve(requestId: String, decision: ApprovalDecision) -> Bool {
        guard let connection = takePending(requestId) else { return false }
        send(decision: decision, on: connection)
        state.withLock(\.onApprovalResolved)?(requestId, decision)
        return true
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.connections[key] = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .cancelled, .failed:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let (orphaned, resolved) = state.withLock { state -> ([String], (@Sendable (String, ApprovalDecision?) -> Void)?) in
            state.connections.removeValue(forKey: key)
            let ids = state.pending.filter { ObjectIdentifier($0.value) == key }.map(\.key)
            for id in ids { state.pending.removeValue(forKey: id) }
            return (ids, state.onApprovalResolved)
        }
        for id in orphaned { resolved?(id, nil) }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                route(request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(on: connection, buffer: buffer)
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.method == "POST", request.path == Self.hookPath else {
            send(status: "404 Not Found", body: Data("{}".utf8), on: connection)
            return
        }
        let body = (try? JSONDecoder().decode(JSONValue.self, from: request.body)) ?? .object([:])
        let name = body["hook_event_name"]?.stringValue ?? ""
        let sessionId = body["session_id"]?.stringValue

        guard name == "PermissionRequest" else {
            send(status: "200 OK", body: Data("{}".utf8), on: connection)
            state.withLock(\.onEvent)?(Event(name: name, sessionId: sessionId, body: body))
            return
        }
        hold(approval: body, sessionId: sessionId, on: connection)
    }

    private func hold(approval body: JSONValue, sessionId: String?, on connection: NWConnection) {
        let requestId = body["request_id"]?.stringValue
            ?? body["permission_request_id"]?.stringValue
            ?? UUID().uuidString
        let toolName = body["tool_name"]?.stringValue
        let registered = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.pending[requestId] = connection
            return true
        }
        guard registered else {
            send(decision: nil, on: connection)
            return
        }
        // No cancellation needed: a resolved request is gone from `pending`, so
        // the timer finds nothing to answer.
        queue.asyncAfter(deadline: .now() + approvalTimeout) { [weak self] in
            guard let self, let connection = takePending(requestId) else { return }
            send(decision: nil, on: connection)
            state.withLock(\.onApprovalResolved)?(requestId, nil)
        }

        state.withLock(\.onApprovalRequest)?(
            PendingApprovalContext(
                requestId: requestId,
                sessionId: sessionId,
                toolName: toolName,
                requestKind: Self.requestKind(forTool: toolName),
                detail: Self.detail(forTool: toolName, input: body["tool_input"]),
                createdAt: ClaudeTimestamp.now()
            )
        )
    }

    private func takePending(_ requestId: String) -> NWConnection? {
        state.withLock { $0.pending.removeValue(forKey: requestId) }
    }

    // MARK: - Responses

    /// Claude Code reads a `PermissionRequest` answer from
    /// `hookSpecificOutput.decision.behavior` — `permissionDecision` is the
    /// *PreToolUse* field and is ignored here. Omitting `decision` entirely is
    /// how the hook says "I have no answer", which hands the prompt back to the
    /// terminal; that is what a `nil` decision (timeout, shutdown) must send.
    private func send(decision: ApprovalDecision?, on connection: NWConnection) {
        let behavior: String? = switch decision {
        case .accept, .acceptForSession: "allow"
        case .decline: "deny"
        case .cancel, nil: nil
        }
        var payload: [String: Any] = [:]
        if let behavior {
            payload["hookSpecificOutput"] = [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": behavior],
            ] as [String: Any]
        }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        send(status: "200 OK", body: body, on: connection)
    }

    private func send(status: String, body: Data, on connection: NWConnection) {
        var response = Data(
            """
            HTTP/1.1 \(status)\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """.utf8
        )
        response.append(body)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Payload classification

    static func requestKind(forTool tool: String?) -> String {
        switch tool {
        case "Read", "NotebookRead": "file-read"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "file-change"
        default: "command"
        }
    }

    static func detail(forTool tool: String?, input: JSONValue?) -> String? {
        if let command = input?["command"]?.stringValue { return command }
        if let path = input?["file_path"]?.stringValue { return path }
        if let url = input?["url"]?.stringValue { return url }
        return tool
    }
}

/// Minimal HTTP/1.1 request; `init` returns nil until the buffer holds a whole
/// request (headers plus the declared body).
struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    init?(_ buffer: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0]
        path = requestLine[1].split(separator: "?").first.map(String.init) ?? requestLine[1]

        var contentLength = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            // A negative length would pass the "enough bytes" check below and
            // then trap in `prefix(_:)`, killing the whole app.
            contentLength = max(0, Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0)
        }

        let available = buffer[range.upperBound...]
        guard available.count >= contentLength else { return nil }
        body = Data(available.prefix(contentLength))
    }
}
