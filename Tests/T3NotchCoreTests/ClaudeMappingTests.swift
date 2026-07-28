import Foundation
import Testing
@testable import T3NotchCore

@Suite("Claude mapping")
struct ClaudeMappingTests {
    @Test func mapsTranscriptRecordsToActivities() throws {
        var mapper = ClaudeTranscriptMapper(root: "/Users/dev/project")
        for line in try transcriptLines() { mapper.ingest(line: line) }

        #expect(mapper.branch == "feature/claude-transport")
        #expect(mapper.model == "claude-opus-5[1m]")

        let started = try #require(mapper.activities.first { $0.id == "start-toolu_bash" })
        let completed = try #require(mapper.activities.first { $0.id == "done-toolu_bash" })
        #expect(started.kind == "tool.started")
        #expect(completed.kind == "tool.completed")
        #expect(started.tone == "tool")
        #expect(started.summary == "Ran command")
        // Both halves carry the same detail so the pair folds into one row.
        #expect(started.summary == completed.summary)
        #expect(started.payload == completed.payload)
        #expect(started.payload?["itemType"]?.stringValue == "command_execution")
        #expect(started.payload?["detail"]?.stringValue == "swift build && swift test")

        let edit = try #require(mapper.activities.first { $0.id == "start-toolu_edit" })
        #expect(edit.summary == "Changed file")
        #expect(edit.payload?["itemType"]?.stringValue == "file_change")
        #expect(edit.payload?["detail"]?.stringValue == "Sources/App/Main.swift")

        // Subagent records land in the same file but are not this thread's work.
        #expect(!mapper.activities.contains { $0.id.contains("toolu_side") })

        // TaskCreate/TaskUpdate never produce a tool row.
        #expect(!mapper.activities.contains { $0.id.contains("toolu_task") })
        // AskUserQuestion produces no activity at all.
        #expect(!mapper.activities.contains { $0.id.contains("toolu_ask") })

        let events = deriveRecentActivity(from: mapper.activities, relativeTo: "/Users/dev/project")
        #expect(events.count == 2)
        #expect(events.map(\.kind) == [.command, .fileChange])
        #expect(events.allSatisfy { !$0.isRunning })
    }

    @Test func mapsTasksToPlanAndUsageToContext() throws {
        var mapper = ClaudeTranscriptMapper(root: "/Users/dev/project")
        for line in try transcriptLines() { mapper.ingest(line: line) }

        let plan = try #require(
            deriveActivePlanState(from: mapper.activities, latestTurnId: mapper.latestTurn?.turnId)
        )
        #expect(plan.steps.map(\.step) == ["Wire the transport", "Write mapping tests"])
        #expect(plan.steps[0].status == .inProgress)
        #expect(plan.steps[1].status == .pending)

        // One context row per session: the newest usage replaces the previous.
        #expect(mapper.activities.filter { $0.kind == "context-window.updated" }.count == 1)
        let context = try #require(deriveLatestContextWindowSnapshot(from: mapper.activities))
        #expect(context.usedTokens == 50508)
        #expect(context.maxTokens == 1_000_000)
    }

    @Test func turnOpensOnUserTextAndClosesOnTurnDuration() throws {
        var mapper = ClaudeTranscriptMapper(root: "/Users/dev/project")
        let lines = try transcriptLines()

        mapper.ingest(line: lines[0])
        #expect(mapper.latestTurn?.turnId == "u-1")
        #expect(mapper.latestTurn?.state == "running")
        // A tool_result is a `user` record too, and must not open a new turn.
        mapper.ingest(line: lines[1])
        mapper.ingest(line: lines[2])
        #expect(mapper.latestTurn?.turnId == "u-1")

        for line in lines.dropFirst(3) { mapper.ingest(line: line) }
        #expect(mapper.latestTurn?.state == "completed")
        #expect(mapper.latestTurn?.completedAt == "2026-07-28T10:00:42.000Z")
        #expect(resolveThreadAwarenessPhase(thread(from: mapper)) == .completed)
    }

    @Test func askUserQuestionOnlyRaisesTheWaitingFlag() throws {
        var mapper = ClaudeTranscriptMapper(root: "/Users/dev/project")
        var waitingSeen = false
        for line in try transcriptLines() {
            mapper.ingest(line: line)
            if mapper.hasPendingUserInput {
                waitingSeen = true
                #expect(resolveThreadAwarenessPhase(thread(from: mapper)) == .waitingForInput)
            }
        }
        #expect(waitingSeen)
        #expect(!mapper.hasPendingUserInput)
        // No answerable sheet: the question can only be answered in the terminal.
        #expect(derivePendingUserInputs(from: mapper.activities).isEmpty)
    }

    @Test func activityCapKeepsApprovalsPlanAndContext() throws {
        var mapper = ClaudeTranscriptMapper(root: "/Users/dev/project", activityCap: 4)
        for line in try transcriptLines() { mapper.ingest(line: line) }
        mapper.appendExternalActivity(
            id: "approval-requested-req-1",
            kind: "approval.requested",
            tone: nil,
            summary: "Approval requested",
            payload: .object(["requestId": .string("req-1"), "requestKind": .string("command")]),
            createdAt: "2026-07-28T10:00:43.000Z"
        )
        for index in 0..<20 {
            mapper.ingest(line: bashRecord(index: index))
        }

        #expect(mapper.activities.count == 4)
        #expect(mapper.activities.contains { $0.kind == "approval.requested" })
        #expect(mapper.activities.contains { $0.kind == "turn.plan.updated" })
        #expect(mapper.activities.contains { $0.kind == "context-window.updated" })
        #expect(derivePendingApprovals(from: mapper.activities).count == 1)
        // Sequences stay monotonic across evictions.
        let sequences = mapper.activities.compactMap(\.sequence)
        #expect(sequences == sequences.sorted())
    }

    @Test func registryEntryDecodesAndClassifies() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "claude_session_registry",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let entry = try JSONDecoder().decode(
            ClaudeSessionEntry.self,
            from: Data(contentsOf: url)
        )
        #expect(entry.pid == 4242)
        #expect(entry.sessionId == "sess-abc")
        #expect(entry.cwd == "/Users/dev/project")
        #expect(entry.isBusy)
        #expect(entry.isInteractive)

        var unknown = entry
        unknown.status = "compacting"
        #expect(!unknown.isBusy)
    }

    @Test func transportPublishesSessionsFromRegistryAndTranscript() async throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let transport = ClaudeCodeTransport(claudeHome: home, isProcessAlive: { _ in true })
        defer { transport.stop() }

        // The registry lands first; the transcript fills in the rest.
        let snapshot = try #require(
            await snapshot(from: transport.shell) { $0.threads.first?.branch != nil }
        )
        #expect(snapshot.projects.map(\.id) == ["/Users/dev/project"])
        let thread = try #require(snapshot.threads.first)
        #expect(thread.id == "sess-abc")
        #expect(thread.title == "project")
        #expect(thread.ownerPid == 4242)
        #expect(thread.modelSelection.provider == "claude")
        #expect(thread.modelSelection.model == "claude-opus-5[1m]")
        #expect(thread.branch == "feature/claude-transport")
        #expect(thread.session?.status == "running")
        #expect(thread.latestTurn?.state == "completed")
    }

    /// Focus is re-asserted on every shell snapshot; if that reopened the detail
    /// stream the notch would go blank for the rest of the session.
    @Test func focusChangeDoesNotEndAnOpenDetailStream() async throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let transport = ClaudeCodeTransport(claudeHome: home, isProcessAlive: { _ in true })
        defer { transport.stop() }

        let ended = Box<Bool>()
        let stream = transport.threadDetail("sess-abc")
        let consumer = Task {
            for await _ in stream {}
            ended.set(true)
        }

        for _ in 0..<5 {
            transport.setFocusedThread("sess-abc")
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(ended.value != true)
        consumer.cancel()
    }

    @Test func dispatchWithoutHooksIsUnsupported() async throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let transport = ClaudeCodeTransport(claudeHome: home, isProcessAlive: { _ in true })
        defer { transport.stop() }

        await #expect(throws: AgentTransportError.self) {
            try await transport.dispatch(
                .approvalRespond(
                    commandId: "c1",
                    threadId: "sess-abc",
                    requestId: "req-1",
                    decision: .accept,
                    createdAt: "2026-07-28T10:00:43.000Z"
                )
            )
        }
    }
}

// MARK: - Helpers

private func transcriptLines() throws -> [Data] {
    let url = try #require(
        Bundle.module.url(
            forResource: "claude_transcript",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )
    )
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { Data($0.utf8) }
}

/// A temp `~/.claude` holding the registry entry and its transcript. Tests never
/// touch the real one.
private func makeClaudeHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t3notch-claude-\(UUID().uuidString)")
    let sessions = home.appendingPathComponent("sessions")
    let project = home.appendingPathComponent("projects/-Users-dev-project")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let registry = try #require(
        Bundle.module.url(
            forResource: "claude_session_registry",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
    )
    try FileManager.default.copyItem(
        at: registry,
        to: sessions.appendingPathComponent("4242.json")
    )
    let transcript = try #require(
        Bundle.module.url(
            forResource: "claude_transcript",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )
    )
    try FileManager.default.copyItem(
        at: transcript,
        to: project.appendingPathComponent("sess-abc.jsonl")
    )
    return home
}

private func snapshot(
    from stream: AsyncStream<ShellSnapshot>,
    matching predicate: @escaping @Sendable (ShellSnapshot) -> Bool
) async -> ShellSnapshot? {
    await withTaskGroup(of: ShellSnapshot?.self) { group in
        group.addTask {
            for await snapshot in stream where predicate(snapshot) { return snapshot }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private func thread(from mapper: ClaudeTranscriptMapper) -> ThreadShell {
    ThreadShell(
        id: "sess-abc",
        projectId: "/Users/dev/project",
        title: "project",
        modelSelection: ModelSelection(model: mapper.model ?? "claude"),
        latestTurn: mapper.latestTurn,
        updatedAt: "2026-07-28T10:00:42.000Z",
        session: Session(status: "idle"),
        hasPendingUserInput: mapper.hasPendingUserInput
    )
}

private func bashRecord(index: Int) -> Data {
    Data(
        """
        {"isSidechain":false,"type":"assistant","uuid":"a-fill-\(index)",\
        "timestamp":"2026-07-28T10:01:\(String(format: "%02d", index)).000Z",\
        "message":{"role":"assistant","model":"claude-opus-5[1m]","content":\
        [{"type":"tool_use","id":"toolu_fill_\(index)","name":"Bash",\
        "input":{"command":"echo \(index)"}}]}}
        """.utf8
    )
}
