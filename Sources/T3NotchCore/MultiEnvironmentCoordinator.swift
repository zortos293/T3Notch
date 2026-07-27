import Foundation
import os

public final class MultiEnvironmentCoordinator: @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        var profile: EnvironmentProfile
        var descriptor: EnvironmentDescriptor?
        var endpoint: ServerEndpoint
        var state: EnvironmentConnectionState = .connecting
        var shell: ShellSnapshot?
        let transport: PollingTransport
        var shellTask: Task<Void, Never>?

        init(
            profile: EnvironmentProfile,
            descriptor: EnvironmentDescriptor?,
            endpoint: ServerEndpoint,
            transport: PollingTransport
        ) {
            self.profile = profile
            self.descriptor = descriptor
            self.endpoint = endpoint
            self.transport = transport
        }
    }

    private struct State {
        var sessions: [EnvironmentID: Session] = [:]
        var focused: ScopedThreadID?
        var expanded = false
        var detailTask: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: AsyncStream<EnvironmentEvent>.Continuation
    public let events: AsyncStream<EnvironmentEvent>

    public init() {
        let pair = AsyncStream<EnvironmentEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        stop()
    }

    public func register(
        profile: EnvironmentProfile,
        descriptor: EnvironmentDescriptor?,
        endpoint: ServerEndpoint,
        authorizer: any HTTPAuthorizer
    ) {
        remove(profile.environmentID, emitEvent: false)
        let client = T3HTTPClient(endpoint: endpoint, authorizer: authorizer)
        let transport = PollingTransport(
            client: client,
            configuration: profile.source == .local ? PollingConfiguration() : .remote
        )
        let session = Session(
            profile: profile,
            descriptor: descriptor,
            endpoint: endpoint,
            transport: transport
        )
        transport.onConnectionStateChange = { [weak self, weak session] state in
            guard let self, let session else { return }
            session.state = switch state {
            case .connecting: .connecting
            case .connected: .connected
            case .disconnected: .offline(nil)
            case .unauthorized:
                session.profile.source == .direct ? .needsPairing : .unauthorized
            }
            self.emit(session)
        }
        transport.onRepeatedFailure = { [weak self, weak session] in
            guard let self, let session else { return }
            self.emit(session)
        }
        let previous = state.withLock { state -> Session? in
            let previous = state.sessions.updateValue(session, forKey: profile.environmentID)
            session.transport.setExpanded(state.expanded)
            if state.focused?.environmentID == profile.environmentID {
                session.transport.setFocusedThread(state.focused?.threadID)
            }
            return previous
        }
        previous?.transport.stop()
        previous?.shellTask?.cancel()
        emit(session)
        session.shellTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            for await shell in transport.shell {
                session.shell = shell
                session.state = .connected
                self.emit(session)
            }
        }
    }

    public func snapshots() -> [EnvironmentSnapshot] {
        state.withLock { state in
            state.sessions.values.map(makeSnapshot).sorted {
                sourcePriority($0.activeAccessPath) < sourcePriority($1.activeAccessPath)
            }
        }
    }

    public func setFocusedThread(_ focused: ScopedThreadID?) {
        let detailSource: (PollingTransport, ScopedThreadID)? = state.withLock { state in
            state.detailTask?.cancel()
            state.detailTask = nil
            state.focused = focused
            for (environmentID, session) in state.sessions {
                session.transport.setFocusedThread(
                    environmentID == focused?.environmentID ? focused?.threadID : nil
                )
            }
            guard let focused, let session = state.sessions[focused.environmentID] else {
                return nil
            }
            return (session.transport, focused)
        }
        guard let (transport, focused) = detailSource else { return }
        let task = Task { [weak self] in
            for await detail in transport.threadDetail(focused.threadID) {
                self?.continuation.yield(.detail(focused, detail))
            }
        }
        state.withLock { $0.detailTask = task }
    }

    public func setExpanded(_ expanded: Bool) {
        state.withLock { state in
            state.expanded = expanded
            for session in state.sessions.values {
                session.transport.setExpanded(expanded)
            }
        }
    }

    public func reconnect(_ environmentID: EnvironmentID? = nil) {
        state.withLock { state in
            for (id, session) in state.sessions where environmentID == nil || environmentID == id {
                session.state = .connecting
                session.transport.requestImmediatePoll()
                emit(session)
            }
        }
    }

    public func dispatch(_ command: DispatchCommand, to environmentID: EnvironmentID) async throws {
        let transport = state.withLock { $0.sessions[environmentID]?.transport }
        guard let transport else {
            throw T3HTTPError.transport(
                NSError(
                    domain: "T3Notch.MultiEnvironmentCoordinator",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The machine is not connected."]
                )
            )
        }
        try await transport.dispatch(command)
    }

    public func updateProfile(_ profile: EnvironmentProfile) {
        let session = state.withLock { state -> Session? in
            guard let session = state.sessions[profile.environmentID] else { return nil }
            session.profile = profile
            return session
        }
        if let session { emit(session) }
    }

    public func remove(_ environmentID: EnvironmentID) {
        remove(environmentID, emitEvent: true)
    }

    /// Stops polling while a profile remains in the presentation layer (for
    /// example, a disabled or credential-locked machine in Settings).
    public func suspend(_ environmentID: EnvironmentID) {
        remove(environmentID, emitEvent: false)
    }

    public func stop() {
        let sessions = state.withLock { state -> [Session] in
            state.detailTask?.cancel()
            state.detailTask = nil
            let values = Array(state.sessions.values)
            state.sessions = [:]
            return values
        }
        for session in sessions {
            session.shellTask?.cancel()
            session.transport.stop()
        }
        continuation.finish()
    }

    private func remove(_ environmentID: EnvironmentID, emitEvent: Bool) {
        let removed = state.withLock { state -> Session? in
            if state.focused?.environmentID == environmentID {
                state.focused = nil
                state.detailTask?.cancel()
                state.detailTask = nil
            }
            return state.sessions.removeValue(forKey: environmentID)
        }
        removed?.shellTask?.cancel()
        removed?.transport.stop()
        if emitEvent, removed != nil {
            continuation.yield(.removed(environmentID))
        }
    }

    private func emit(_ session: Session) {
        continuation.yield(.snapshot(makeSnapshot(session)))
    }

    private func makeSnapshot(_ session: Session) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            profile: session.profile,
            descriptor: session.descriptor,
            connectionState: session.state,
            activeAccessPath: session.profile.source,
            shell: session.shell
        )
    }

    private func sourcePriority(_ source: EnvironmentSource) -> Int {
        switch source {
        case .local: 0
        case .direct: 1
        case .t3Connect: 2
        }
    }
}
