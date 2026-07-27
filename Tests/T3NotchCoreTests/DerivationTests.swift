import Foundation
import Testing
@testable import T3NotchCore

@Suite("Derivations")
struct DerivationTests {
    @Test func decodesShellSnapshotAndPhases() throws {
        let snapshot: ShellSnapshot = try loadFixture("shell_snapshot")
        #expect(snapshot.threads.count == 2)

        let running = snapshot.threads.first { $0.id == "thr_running" }!
        #expect(resolveThreadAwarenessPhase(running) == .running)

        let approval = snapshot.threads.first { $0.id == "thr_approval" }!
        #expect(resolveThreadAwarenessPhase(approval) == .waitingForApproval)
    }

    @Test func derivesApprovalsQuestionsPlanAndContext() throws {
        let detail: ThreadDetailSnapshot = try loadFixture("thread_detail")
        let activities = detail.thread.activities

        let approvals = derivePendingApprovals(from: activities)
        #expect(approvals.count == 1)
        #expect(approvals[0].requestId == "req_1")
        #expect(approvals[0].requestKind == "command")
        #expect(approvals[0].detail == "ls -la /tmp")

        let inputs = derivePendingUserInputs(from: activities)
        #expect(inputs.count == 1)
        #expect(inputs[0].questions.count == 1)
        #expect(inputs[0].questions[0].options.count == 2)

        let plan = deriveActivePlanState(from: activities, latestTurnId: "turn_2")
        #expect(plan?.steps.count == 3)
        #expect(plan?.steps[1].status == .inProgress)

        let context = deriveLatestContextWindowSnapshot(from: activities)
        #expect(context?.usedTokens == 42000)
        #expect(context?.maxTokens == 200000)
        #expect(context?.usedPercentage == 21)

        let recent = deriveRecentActivity(from: activities)
        #expect(recent.count == 1)
        #expect(recent[0].label == "Running shell: ls")
        #expect(recent[0].isRunning)
    }

    @Test func recentActivityFoldsStartedAndCompletedIntoOneRow() {
        let activities = [
            toolActivity(id: "1", kind: "tool.started", summary: "Ran command started", at: 0),
            toolActivity(id: "2", kind: "tool.completed", summary: "Ran command", at: 1),
            toolActivity(
                id: "3",
                kind: "tool.started",
                summary: "Ran command started",
                command: "npm test",
                at: 2
            ),
        ]

        let events = deriveRecentActivity(from: activities)
        #expect(events.count == 2)
        // Lifecycle suffix stripped, shell wrapper unwrapped.
        #expect(events[0].label == "Ran command")
        #expect(events[0].detail == "git status --short")
        #expect(events[0].isRunning == false)
        #expect(events[0].kind == .command)
        // Still-running work stays flagged.
        #expect(events[1].detail == "npm test")
        #expect(events[1].isRunning)
    }

    @Test func recentActivityKeepsNewestAndNamesChangedFiles() {
        var activities = (0..<7).map { index in
            toolActivity(
                id: "c\(index)",
                kind: "tool.completed",
                summary: "Ran command",
                command: "step \(index)",
                at: index
            )
        }
        // A file change reports its paths in the completion data, not `detail`.
        activities.append(
            ThreadActivity(
                id: "f1",
                tone: "tool",
                kind: "tool.completed",
                summary: "File change",
                payload: .object([
                    "itemType": .string("file_change"),
                    "data": .object([
                        "item": .object([
                            "changes": .array([
                                .object(["path": .string("/work/tree/app/src/Main.swift")]),
                                .object(["path": .string("/work/tree/app/src/Other.swift")]),
                            ])
                        ])
                    ]),
                ]),
                createdAt: timestamp(8)
            )
        )

        let events = deriveRecentActivity(from: activities, relativeTo: "/work/tree")
        #expect(events.count == 5)
        #expect(events.first?.detail == "step 3")
        #expect(events.last?.kind == .fileChange)
        #expect(events.last?.detail == "app/src/Main.swift +1")
    }

    @Test func recentActivityFoldsPairsLoggedInTheSameMillisecond() {
        // Fast commands log both events on the same timestamp, and the server
        // sends no sequence number, so lifecycle order is the only tiebreak.
        let completed = toolActivity(
            id: "zzz-completed-sorts-first-by-id",
            kind: "tool.completed",
            summary: "Ran command",
            at: 5
        )
        let started = toolActivity(
            id: "aaa-started",
            kind: "tool.started",
            summary: "Ran command started",
            at: 5
        )

        let events = deriveRecentActivity(from: [completed, started])
        #expect(events.count == 1)
        #expect(events[0].isRunning == false)
    }

    @Test func recentActivitySkipsToolUpdatedNoise() {
        let activities = [
            toolActivity(id: "1", kind: "tool.started", summary: "Ran command started", at: 0),
            toolActivity(id: "2", kind: "tool.updated", summary: "Tool updated", at: 1),
        ]
        let events = deriveRecentActivity(from: activities)
        #expect(events.count == 1)
        #expect(events[0].label == "Ran command")
    }

    @Test func unwrapsOnlyRealShellInvocations() {
        #expect(unwrappedShellCommand(#"/bin/zsh -lc "git log --oneline""#) == "git log --oneline")
        #expect(unwrappedShellCommand("bash -c 'ls -la'") == "ls -la")
        #expect(unwrappedShellCommand(#"/bin/zsh -lc "echo \"hi\"""#) == #"echo "hi""#)
        // Long details arrive truncated, so the closing quote never shows up.
        #expect(unwrappedShellCommand(#"/bin/zsh -lc "git log --oneline && du -a"#) == "git log --oneline && du -a")
        // Not a shell wrapper: leave it exactly as it came.
        #expect(unwrappedShellCommand("git commit -m wip") == "git commit -m wip")
        #expect(unwrappedShellCommand("zsh script.sh arg") == "zsh script.sh arg")
    }

    @Test func completedInterruptedWithCompletedAtIsDone() {
        let thread = ThreadShell(
            id: "t",
            projectId: "p",
            title: "x",
            modelSelection: ModelSelection(model: "m"),
            latestTurn: LatestTurn(
                turnId: "turn",
                state: "interrupted",
                completedAt: "2026-07-26T15:00:00.000Z"
            ),
            updatedAt: "2026-07-26T15:00:00.000Z",
            session: Session(status: "stopped"),
            hasPendingApprovals: false,
            hasPendingUserInput: false
        )
        #expect(resolveThreadAwarenessPhase(thread) == .completed)
    }

    @Test func resolvesApprovalWhenActivityResolved() {
        let activities = [
            ThreadActivity(
                id: "1",
                kind: "approval.requested",
                summary: "ask",
                payload: .object([
                    "requestId": .string("r1"),
                    "requestKind": .string("command"),
                ]),
                sequence: 1,
                createdAt: "2026-07-26T15:00:00.000Z"
            ),
            ThreadActivity(
                id: "2",
                kind: "approval.resolved",
                summary: "done",
                payload: .object([
                    "requestId": .string("r1"),
                ]),
                sequence: 2,
                createdAt: "2026-07-26T15:00:01.000Z"
            ),
        ]
        #expect(derivePendingApprovals(from: activities).isEmpty)
    }
}

/// Tool lifecycle activity shaped like the server's: commands carry their shell
/// wrapper in `payload.detail`.
private func toolActivity(
    id: String,
    kind: String,
    summary: String,
    command: String = "git status --short",
    at second: Int
) -> ThreadActivity {
    ThreadActivity(
        id: id,
        tone: "tool",
        kind: kind,
        summary: summary,
        payload: .object([
            "itemType": .string("command_execution"),
            "detail": .string("/bin/zsh -lc \"\(command)\""),
        ]),
        createdAt: timestamp(second)
    )
}

private func timestamp(_ second: Int) -> String {
    String(format: "2026-07-26T15:00:%02d.000Z", second)
}

private func loadFixture<T: Decodable>(_ name: String) throws -> T {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: name, withExtension: "json")
    guard let url else {
        throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(name).json"])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}
