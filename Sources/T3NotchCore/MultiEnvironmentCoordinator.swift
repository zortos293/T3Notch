import Foundation
import os

public final class MultiEnvironmentCoordinator: @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        private struct Data {
            var profile: EnvironmentProfile
            var descriptor: EnvironmentDescriptor?
            var state: EnvironmentConnectionState = .connecting
            var shell: ShellSnapshot?
            var shellTask: Task<Void, Never>?
        }

        private let data: OSAllocatedUnfairLock<Data>
        let transport: PollingTransport

        init(
            profile: EnvironmentProfile,
            descriptor: EnvironmentDescriptor?,
            transport: PollingTransport
        ) {
            data = OSAllocatedUnfairLock(initialState: Data(
                profile: profile,
                descriptor: descriptor
            ))
            self.transport = transport
        }

        var source: EnvironmentSource {
            data.withLock { $0.profile.source }
        }

        func updateProfile(_ profile: EnvironmentProfile) {
            data.withLock { $0.profile = profile }
        }

        func updateState(_ state: EnvironmentConnectionState) {
            data.withLock { $0.state = state }
        }

        func updateShell(_ shell: ShellSnapshot) {
            data.withLock {
                $0.shell = shell
                $0.state = .connected
            }
        }

        func installShellTask(_ task: Task<Void, Never>) {
            let previous = data.withLock { data -> Task<Void, Never>? in
                let previous = data.shellTask
                data.shellTask = task
                return previous
            }
            previous?.cancel()
        }

        func cancelShellTask() {
            data.withLock { data -> Task<Void, Never>? in
                defer { data.shellTask = nil }
                return data.shellTask
            }?.cancel()
        }

        func snapshot() -> EnvironmentSnapshot {
            data.withLock {
                EnvironmentSnapshot(
                    profile: $0.profile,
                    descriptor: $0.descriptor,
                    connectionState: $0.state,
                    activeAccessPath: $0.profile.source,
                    shell: $0.shell
                )
            }
        }
    }

    private struct State {
        var sessions: [EnvironmentID: Session] = [:]
        var focused: ScopedThreadID?
        var expanded = false
        var detailTask: Task<Void, Never>?
        var detailGeneration = 0
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
        let client = T3HTTPClient(endpoint: endpoint, authorizer: authorizer)
        let transport = PollingTransport(
            client: client,
            configuration: profile.source == .local ? PollingConfiguration() : .remote
        )
        let session = Session(
            profile: profile,
            descriptor: descriptor,
            transport: transport
        )
        transport.onConnectionStateChange = { [weak self, weak session] state in
            guard let self, let session else { return }
            let environmentState: EnvironmentConnectionState = switch state {
            case .connecting: .connecting
            case .connected: .connected
            case .disconnected: .offline(nil)
            case .unauthorized:
                session.source == .direct ? .needsPairing : .unauthorized
            }
            session.updateState(environmentState)
            self.emit(session)
        }
        transport.onRepeatedFailure = { [weak self, weak session] in
            guard let self, let session else { return }
            self.emit(session)
        }
        let (previous, focused) = state.withLock {
            state -> (Session?, ScopedThreadID?) in
            let previous = state.sessions.updateValue(session, forKey: profile.environmentID)
            session.transport.setExpanded(state.expanded)
            if state.focused?.environmentID == profile.environmentID {
                session.transport.setFocusedThread(state.focused?.threadID)
            }
            return (previous, state.focused)
        }
        previous?.transport.stop()
        previous?.cancelShellTask()
        emit(session)
        let shellTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            for await shell in transport.shell {
                session.updateShell(shell)
                self.emit(session)
            }
        }
        session.installShellTask(shellTask)
        if focused?.environmentID == profile.environmentID {
            setFocusedThread(focused)
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
        let detailSource: (PollingTransport, ScopedThreadID, Int)? = state.withLock { state in
            state.detailTask?.cancel()
            state.detailTask = nil
            state.detailGeneration &+= 1
            state.focused = focused
            for (environmentID, session) in state.sessions {
                session.transport.setFocusedThread(
                    environmentID == focused?.environmentID ? focused?.threadID : nil
                )
            }
            guard let focused, let session = state.sessions[focused.environmentID] else {
                return nil
            }
            return (session.transport, focused, state.detailGeneration)
        }
        guard let (transport, focused, generation) = detailSource else { return }
        let task = Task { [weak self] in
            for await detail in transport.threadDetail(focused.threadID) {
                self?.continuation.yield(.detail(focused, detail))
            }
        }
        let accepted = state.withLock { state -> Bool in
            guard state.focused == focused,
                  state.detailGeneration == generation
            else {
                return false
            }
            state.detailTask = task
            return true
        }
        if !accepted {
            task.cancel()
        }
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
        let sessions = state.withLock { state -> [Session] in
            var changed: [Session] = []
            for (id, session) in state.sessions where environmentID == nil || environmentID == id {
                session.updateState(.connecting)
                session.transport.requestImmediatePoll()
                changed.append(session)
            }
            return changed
        }
        for session in sessions {
            emit(session)
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
            session.updateProfile(profile)
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
            session.cancelShellTask()
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
        removed?.cancelShellTask()
        removed?.transport.stop()
        if emitEvent, removed != nil {
            continuation.yield(.removed(environmentID))
        }
    }

    private func emit(_ session: Session) {
        continuation.yield(.snapshot(makeSnapshot(session)))
    }

    private func makeSnapshot(_ session: Session) -> EnvironmentSnapshot {
        session.snapshot()
    }

    private func sourcePriority(_ source: EnvironmentSource) -> Int {
        switch source {
        case .local: 0
        case .direct: 1
        case .t3Connect: 2
        }
    }
}
