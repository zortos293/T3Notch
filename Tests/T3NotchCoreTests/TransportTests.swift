import Foundation
import Testing
@testable import T3NotchCore

private actor StreamWatcher {
    private(set) var ended = false
    func markEnded() { ended = true }
}

@Suite("Transport")
struct TransportTests {
    /// Focus is re-asserted on every shell snapshot (~800ms while an agent
    /// works). If that reopened the detail stream it would end the one the UI is
    /// iterating, and the notch would sit there with no activity, tasks, or
    /// context for the rest of the session.
    @Test func focusChangeDoesNotEndAnOpenDetailStream() async throws {
        let transport = PollingTransport(
            client: T3HTTPClient(endpoint: ServerEndpoint(), token: "test")
        )
        defer { transport.stop() }

        let watcher = StreamWatcher()
        let stream = transport.threadDetail("thread-1")
        let consumer = Task {
            for await _ in stream {}
            await watcher.markEnded()
        }

        for _ in 0..<5 {
            transport.setFocusedThread("thread-1")
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(await watcher.ended == false)
        consumer.cancel()
    }
}
