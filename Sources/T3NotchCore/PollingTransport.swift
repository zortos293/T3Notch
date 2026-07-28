import Foundation
import os

public struct PollingConfiguration: Sendable {
    public var activeShellNanoseconds: UInt64
    public var idleShellNanoseconds: UInt64
    public var focusedDetailNanoseconds: UInt64
    public var idleDetailNanoseconds: UInt64
    public var maximumBackoffNanoseconds: UInt64
    public var sleep: @Sendable (UInt64) async -> Void
    public var jitter: @Sendable (UInt64) -> UInt64
    public var onBackoff: @Sendable (UInt64) -> Void

    public init(
        activeShellNanoseconds: UInt64 = 800_000_000,
        idleShellNanoseconds: UInt64 = 3_000_000_000,
        focusedDetailNanoseconds: UInt64 = 400_000_000,
        idleDetailNanoseconds: UInt64 = 2_000_000_000,
        maximumBackoffNanoseconds: UInt64 = 30_000_000_000,
        sleep: @escaping @Sendable (UInt64) async -> Void = {
            try? await Task.sleep(nanoseconds: $0)
        },
        jitter: @escaping @Sendable (UInt64) -> UInt64 = { value in
            guard value > 10 else { return value }
            let spread = value / 10
            return UInt64.random(in: (value - spread)...(value + spread))
        },
        onBackoff: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.activeShellNanoseconds = activeShellNanoseconds
        self.idleShellNanoseconds = idleShellNanoseconds
        self.focusedDetailNanoseconds = focusedDetailNanoseconds
        self.idleDetailNanoseconds = idleDetailNanoseconds
        self.maximumBackoffNanoseconds = maximumBackoffNanoseconds
        self.sleep = sleep
        self.jitter = jitter
        self.onBackoff = onBackoff
    }

    public static var remote: PollingConfiguration {
        PollingConfiguration(idleShellNanoseconds: 5_000_000_000)
    }
}

/// Adaptive HTTP polling transport over t3code's public orchestration API.
public final class PollingTransport: AgentTransport, @unchecked Sendable {
    private struct State {
        var lastShellSequence: Int?
        var focusedThreadId: String?
        var isExpanded = false
        var hasActiveWork = false
        var forcePoll = false
        var connectionState: ConnectionState = .connecting
        var detailTasks: [String: Task<Void, Never>] = [:]
        var detailContinuations: [String: AsyncStream<ThreadDetailSnapshot>.Continuation] = [:]
        var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?
        var onRepeatedFailure: (@Sendable () -> Void)?
    }

    private let client: T3HTTPClient
    private let configuration: PollingConfiguration
    private let shellContinuation: AsyncStream<ShellSnapshot>.Continuation
    public let shell: AsyncStream<ShellSnapshot>
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var shellTask: Task<Void, Never>?

    public var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? {
        get { state.withLock(\.onConnectionStateChange) }
        set { state.withLock { $0.onConnectionStateChange = newValue } }
    }
    /// Called after a second and subsequent consecutive failure. Coordinators
    /// use this signal to apply path-failover thresholds without making the
    /// public connection state chatter on every backoff attempt.
    public var onRepeatedFailure: (@Sendable () -> Void)? {
        get { state.withLock(\.onRepeatedFailure) }
        set { state.withLock { $0.onRepeatedFailure = newValue } }
    }

    public var connectionState: ConnectionState {
        state.withLock(\.connectionState)
    }

    public init(
        client: T3HTTPClient,
        configuration: PollingConfiguration = PollingConfiguration()
    ) {
        self.client = client
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<ShellSnapshot>.makeStream()
        self.shell = stream
        self.shellContinuation = continuation
        startShellLoop()
    }

    deinit {
        stop()
    }

    public func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot> {
        let (stream, continuation) = AsyncStream<ThreadDetailSnapshot>.makeStream()

        let previous: Task<Void, Never>? = state.withLock { state in
            let oldTask = state.detailTasks[id]
            state.detailContinuations[id]?.finish()
            state.detailContinuations[id] = continuation
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runDetailLoop(threadId: id, continuation: continuation)
            }
            state.detailTasks[id] = task
            return oldTask
        }
        previous?.cancel()

        return stream
    }

    public func dispatch(_ command: DispatchCommand) async throws {
        _ = try await client.dispatch(command)
        requestImmediatePoll()
    }

    public func requestImmediatePoll() {
        state.withLock { $0.forcePoll = true }
    }

    /// Records which thread's detail should poll fast. It deliberately does not
    /// open the detail stream: `threadDetail(_:)` replaces the consumer's stream,
    /// so calling it from here would tear down whoever is already listening.
    public func setFocusedThread(_ id: String?) {
        state.withLock { $0.focusedThreadId = id }
    }

    public func setExpanded(_ expanded: Bool) {
        state.withLock { $0.isExpanded = expanded }
    }

    public func stop() {
        shellTask?.cancel()
        shellTask = nil
        let tasks: [Task<Void, Never>] = state.withLock { state in
            let tasks = Array(state.detailTasks.values)
            for continuation in state.detailContinuations.values {
                continuation.finish()
            }
            state.detailTasks.removeAll()
            state.detailContinuations.removeAll()
            return tasks
        }
        for task in tasks { task.cancel() }
        shellContinuation.finish()
    }

    private func startShellLoop() {
        shellTask = Task { [weak self] in
            await self?.runShellLoop()
        }
    }

    private func runShellLoop() async {
        var backoffNanos: UInt64 = 0
        while !Task.isCancelled {
            let shouldForce = state.withLock { state -> Bool in
                let value = state.forcePoll
                state.forcePoll = false
                return value
            }

            do {
                let snapshot = try await client.fetchShell()
                setConnectionState(.connected)
                backoffNanos = 0

                let active = snapshot.threads.contains { thread in
                    let phase = resolveThreadAwarenessPhase(thread)
                    return phase == .running
                        || phase == .starting
                        || phase == .waitingForApproval
                        || phase == .waitingForInput
                }

                let changed = state.withLock { state -> Bool in
                    state.hasActiveWork = active
                    let changed = state.lastShellSequence != snapshot.snapshotSequence
                    if changed {
                        state.lastShellSequence = snapshot.snapshotSequence
                    }
                    return changed
                }

                if changed || shouldForce {
                    shellContinuation.yield(snapshot)
                }

                let interval = active
                    ? configuration.activeShellNanoseconds
                    : configuration.idleShellNanoseconds
                await sleepInterruptible(nanoseconds: interval)
            } catch let error as T3HTTPError {
                if case .unauthorized = error {
                    setConnectionState(.unauthorized)
                } else {
                    if !setConnectionState(.disconnected) {
                        state.withLock(\.onRepeatedFailure)?()
                    }
                }
                await applyBackoff(&backoffNanos)
            } catch {
                if !setConnectionState(.disconnected) {
                    state.withLock(\.onRepeatedFailure)?()
                }
                await applyBackoff(&backoffNanos)
            }
        }
    }

    private func runDetailLoop(
        threadId: String,
        continuation: AsyncStream<ThreadDetailSnapshot>.Continuation
    ) async {
        var lastSequence: Int?
        while !Task.isCancelled {
            let (expanded, focused, active) = state.withLock { state in
                (state.isExpanded, state.focusedThreadId, state.hasActiveWork)
            }

            // Only the focused thread's detail is ever displayed, so other
            // subscriptions idle instead of polling alongside it.
            if focused != threadId {
                await sleepInterruptible(
                    nanoseconds: configuration.idleDetailNanoseconds
                )
                continue
            }

            do {
                let detail = try await client.fetchThreadDetail(threadId)
                if lastSequence != detail.snapshotSequence {
                    lastSequence = detail.snapshotSequence
                    continuation.yield(detail)
                }
                let interval = (expanded || active)
                    ? configuration.focusedDetailNanoseconds
                    : configuration.idleDetailNanoseconds
                await sleepInterruptible(nanoseconds: interval)
            } catch {
                await sleepInterruptible(
                    nanoseconds: configuration.idleDetailNanoseconds
                )
            }
        }
        continuation.finish()
    }

    @discardableResult
    private func setConnectionState(_ newState: ConnectionState) -> Bool {
        let (changed, callback) = state.withLock { state
            -> (Bool, (@Sendable (ConnectionState) -> Void)?) in
            let changed = state.connectionState != newState
            state.connectionState = newState
            return (changed, state.onConnectionStateChange)
        }
        if changed {
            callback?(newState)
        }
        return changed
    }

    private func sleepInterruptible(nanoseconds: UInt64) async {
        let slice: UInt64 = 100_000_000
        var remaining = nanoseconds
        while remaining > 0 {
            if Task.isCancelled { return }
            if state.withLock(\.forcePoll) { return }
            let step = min(slice, remaining)
            await configuration.sleep(step)
            remaining -= step
        }
    }

    private func applyBackoff(_ backoffNanos: inout UInt64) async {
        backoffNanos = min(
            max(backoffNanos * 2, 500_000_000),
            configuration.maximumBackoffNanoseconds
        )
        let delay = configuration.jitter(backoffNanos)
        configuration.onBackoff(delay)
        await sleepInterruptible(nanoseconds: delay)
    }
}
