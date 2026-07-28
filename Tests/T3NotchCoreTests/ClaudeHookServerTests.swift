import Foundation
import os
import Testing
@testable import T3NotchCore

/// Callback sink usable from the server's `@Sendable` handlers.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<Value?>(initialState: nil)

    var value: Value? { storage.withLock { $0 } }

    func set(_ value: Value) { storage.withLock { $0 = value } }
}

@Suite("Claude hook server")
struct ClaudeHookServerTests {
    @Test func resolvesAHeldPermissionRequest() async throws {
        let server = ClaudeHookServer(port: 0, approvalTimeout: 30)
        let request = Box<ClaudeHookServer.PendingApprovalContext>()
        server.onApprovalRequest = { request.set($0) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)
        #expect(port != 0)

        let response = Task { try await post(permissionRequestBody(), port: port) }
        let context = try #require(await waitFor { request.value })
        #expect(context.requestId == "req-1")
        #expect(context.sessionId == "sess-abc")
        #expect(context.requestKind == "command")
        #expect(context.detail == "rm -rf /tmp/scratch")

        #expect(server.resolve(requestId: "req-1", decision: .accept))
        let answer = try await response.value
        #expect(try behavior(in: answer) == "allow")
        // `permissionDecision` is the PreToolUse field; Claude Code ignores it
        // for PermissionRequest, so answering with it would be a silent no-op.
        let output = try #require(try hookSpecificOutput(in: answer))
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect(output["permissionDecision"] == nil)
        // The request is gone once answered.
        #expect(!server.resolve(requestId: "req-1", decision: .decline))
    }

    @Test func declineDeniesAndCancelAsks() async throws {
        let server = ClaudeHookServer(port: 0, approvalTimeout: 30)
        let request = Box<ClaudeHookServer.PendingApprovalContext>()
        server.onApprovalRequest = { request.set($0) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let denied = Task { try await post(permissionRequestBody(), port: port) }
        _ = try #require(await waitFor { request.value })
        #expect(server.resolve(requestId: "req-1", decision: .decline))
        #expect(try await behavior(in: denied.value) == "deny")

        let asked = Task {
            try await post(permissionRequestBody(requestId: "req-2"), port: port)
        }
        _ = try #require(await waitFor { request.value?.requestId == "req-2" ? true : nil })
        #expect(server.resolve(requestId: "req-2", decision: .cancel))
        // Handing the prompt back means saying nothing at all: an empty or
        // partial `decision` would fail Claude Code's schema check.
        let askedBody = try await asked.value
        #expect(try hookSpecificOutput(in: askedBody) == nil)
        #expect(String(decoding: askedBody, as: UTF8.self) == "{}")
    }

    /// Nobody answers in the notch, so the terminal prompt must take over.
    @Test func timeoutAnswersAsk() async throws {
        let server = ClaudeHookServer(port: 0, approvalTimeout: 0.4)
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let body = try await post(permissionRequestBody(), port: port)
        #expect(try hookSpecificOutput(in: body) == nil)
    }

    @Test func stopFlushesPendingApprovalsAsAsk() async throws {
        let server = ClaudeHookServer(port: 0, approvalTimeout: 60)
        let request = Box<ClaudeHookServer.PendingApprovalContext>()
        let resolved = Box<String>()
        server.onApprovalRequest = { request.set($0) }
        server.onApprovalResolved = { requestId, _ in resolved.set(requestId) }
        try await server.start()
        let port = try #require(server.boundPort)

        let response = Task { try await post(permissionRequestBody(), port: port) }
        _ = try #require(await waitFor { request.value })
        server.stop()

        #expect(try await hookSpecificOutput(in: response.value) == nil)
        #expect(resolved.value == "req-1")
    }

    @Test func otherEventsAnswerImmediately() async throws {
        let server = ClaudeHookServer(port: 0)
        let event = Box<ClaudeHookServer.Event>()
        server.onEvent = { event.set($0) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)

        let body = try await post(
            ["hook_event_name": "PostToolUse", "session_id": "sess-abc"],
            port: port
        )
        #expect(String(decoding: body, as: UTF8.self) == "{}")
        let received = try #require(await waitFor { event.value })
        #expect(received.name == "PostToolUse")
        #expect(received.sessionId == "sess-abc")
    }

    @Test func unknownRouteIs404() async throws {
        let server = ClaudeHookServer(port: 0)
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/nope")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    /// Anything on the machine can post here, and a negative length used to trap
    /// in `prefix(_:)` — taking the whole app down with the listener.
    @Test func aNegativeContentLengthIsNotFatal() throws {
        let raw = Data("POST /t3notch/hook HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        let request = try #require(HTTPRequest(raw))
        #expect(request.body.isEmpty)
    }

    @Test func classifiesRequestKindByTool() {
        #expect(ClaudeHookServer.requestKind(forTool: "Bash") == "command")
        #expect(ClaudeHookServer.requestKind(forTool: "Read") == "file-read")
        #expect(ClaudeHookServer.requestKind(forTool: "MultiEdit") == "file-change")
        #expect(ClaudeHookServer.requestKind(forTool: "mcp__thing__do") == "command")
    }
}

// MARK: - Helpers

private func permissionRequestBody(requestId: String = "req-1") -> [String: Any] {
    [
        "hook_event_name": "PermissionRequest",
        "session_id": "sess-abc",
        "request_id": requestId,
        "tool_name": "Bash",
        "tool_input": ["command": "rm -rf /tmp/scratch"],
    ]
}

private func post(_ body: [String: Any], port: UInt16) async throws -> Data {
    let url = URL(string: "http://127.0.0.1:\(port)\(ClaudeHookServer.hookPath)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    let (data, _) = try await URLSession.shared.data(for: request)
    return data
}

private func hookSpecificOutput(in data: Data) throws -> [String: Any]? {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return json?["hookSpecificOutput"] as? [String: Any]
}

/// Claude Code reads the answer from `hookSpecificOutput.decision.behavior`.
private func behavior(in data: Data) throws -> String? {
    let decision = try hookSpecificOutput(in: data)?["decision"] as? [String: Any]
    return decision?["behavior"] as? String
}

private func waitFor<Value: Sendable>(
    timeout: TimeInterval = 5,
    _ probe: @Sendable () -> Value?
) async -> Value? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let value = probe() { return value }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return probe()
}
