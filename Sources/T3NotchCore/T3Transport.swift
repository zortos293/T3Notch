import Foundation
import os

public protocol T3Transport: AnyObject, Sendable {
    var shell: AsyncStream<ShellSnapshot> { get }
    func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot>
    func dispatch(_ command: DispatchCommand) async throws
    func requestImmediatePoll()
    func setFocusedThread(_ id: String?)
    func setExpanded(_ expanded: Bool)
    func stop()
}

public enum ConnectionState: String, Sendable, Equatable {
    case connecting
    case connected
    case disconnected
    case unauthorized
}

/// Adaptive HTTP polling transport over t3code's public orchestration API.
public final class PollingTransport: T3Transport, @unchecked Sendable {
    private struct State {
        var lastShellSequence: Int?
        var focusedThreadId: String?
        var isExpanded = false
        var hasActiveWork = false
        var forcePoll = false
        var connectionState: ConnectionState = .connecting
        var detailTasks: [String: Task<Void, Never>] = [:]
        var detailContinuations: [String: AsyncStream<ThreadDetailSnapshot>.Continuation] = [:]
    }

    private let client: T3HTTPClient
    private let shellContinuation: AsyncStream<ShellSnapshot>.Continuation
    public let shell: AsyncStream<ShellSnapshot>
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var shellTask: Task<Void, Never>?

    public var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?

    public var connectionState: ConnectionState {
        state.withLock(\.connectionState)
    }

    public init(client: T3HTTPClient) {
        self.client = client
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

                let interval: UInt64 = active ? 800_000_000 : 3_000_000_000
                await sleepInterruptible(nanoseconds: interval)
            } catch let error as T3HTTPError {
                if case .unauthorized = error {
                    setConnectionState(.unauthorized)
                } else {
                    setConnectionState(.disconnected)
                }
                backoffNanos = min(max(backoffNanos * 2, 500_000_000), 10_000_000_000)
                try? await Task.sleep(nanoseconds: backoffNanos)
            } catch {
                setConnectionState(.disconnected)
                backoffNanos = min(max(backoffNanos * 2, 500_000_000), 10_000_000_000)
                try? await Task.sleep(nanoseconds: backoffNanos)
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
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            do {
                let detail = try await client.fetchThreadDetail(threadId)
                if lastSequence != detail.snapshotSequence {
                    lastSequence = detail.snapshotSequence
                    continuation.yield(detail)
                }
                let interval: UInt64 = (expanded || active) ? 400_000_000 : 2_000_000_000
                await sleepInterruptible(nanoseconds: interval)
            } catch {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        continuation.finish()
    }

    private func setConnectionState(_ newState: ConnectionState) {
        let changed = state.withLock { state -> Bool in
            let changed = state.connectionState != newState
            state.connectionState = newState
            return changed
        }
        if changed {
            onConnectionStateChange?(newState)
        }
    }

    private func sleepInterruptible(nanoseconds: UInt64) async {
        let slice: UInt64 = 100_000_000
        var remaining = nanoseconds
        while remaining > 0 {
            if Task.isCancelled { return }
            if state.withLock(\.forcePoll) { return }
            let step = min(slice, remaining)
            try? await Task.sleep(nanoseconds: step)
            remaining -= step
        }
    }
}
