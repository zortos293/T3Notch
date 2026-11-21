import Foundation
import Testing
@testable import T3NotchCore

struct OrchestrationV2Tests {
    @Test func liveStatusAndPendingQuestionDecode() throws {
        let running = try decodeShell(status: "running", request: "null")
        let finished = try decodeShell(status: "completed", request: "null")
        let waiting = try decodeShell(
            status: "waiting",
            request: #"{"id":"question","kind":"user_input","createdAt":"2026-11-21T12:00:00Z"}"#
        )
        #expect(resolveThreadAwarenessPhase(running) == .running)
        #expect(resolveThreadAwarenessPhase(finished) == .completed)
        #expect(resolveThreadAwarenessPhase(waiting) == .waitingForInput)
    }

    @Test func completedParentStaysVisibleUntilItsSubagentsFinish() throws {
        func shell(backgroundTasks: String) throws -> ShellSnapshot {
            let data = Data("""
            {"snapshotSequence":1,"projects":[],"threads":[{
              \(thread),"status":"completed","latestRunId":"run",
              "latestRunCompletedAt":"2026-11-21T12:00:00Z","pendingBackgroundTasks":\(backgroundTasks)
            }]}
            """.utf8)
            return try JSONDecoder().decode(OrchestrationV2Shell.self, from: data).snapshot
        }

        let waiting = try shell(backgroundTasks: #"[{"kind":"subagent"}]"#)
        let finished = try shell(backgroundTasks: "[]")
        let unrelated = try shell(backgroundTasks: #"[{"kind":"command"}]"#)
        #expect(resolveThreadAwarenessPhase(try #require(waiting.threads.first)) == .waitingForSubagents)
        #expect(resolveThreadAwarenessPhase(try #require(unrelated.threads.first)) == .completed)
        #expect(newlyFinishedThreads(from: waiting, to: finished).map(\.id) == ["thread"])
    }

    @Test func regularRunsNotifyOnceIncludingRunsThatFinishBetweenPolls() throws {
        let running = try decodeShell(status: "running", request: "null")
        let completed = try decodeShell(status: "completed", request: "null")
        let interrupted = try decodeShell(status: "interrupted", request: "null")
        let nextRun = try decodeShell(status: "completed", request: "null", runID: "next-run")
        let earlier = ShellSnapshot(
            snapshotSequence: 1, projects: [], threads: [running], updatedAt: "2026-11-21T12:00:00Z"
        )
        let later = ShellSnapshot(
            snapshotSequence: 2, projects: [], threads: [completed], updatedAt: "2026-11-21T12:00:01Z"
        )
        #expect(newlyFinishedThreads(from: earlier, to: later).map(\.id) == ["thread"])
        #expect(newlyFinishedThreads(from: later, to: later).isEmpty)

        var betweenPolls = later
        betweenPolls.threads = [nextRun]
        #expect(newlyFinishedThreads(from: later, to: betweenPolls).map(\.id) == ["thread"])

        betweenPolls.threads = [interrupted]
        #expect(newlyFinishedThreads(from: earlier, to: betweenPolls).isEmpty)
    }

    @Test func aPreviouslyUnseenThreadMustHaveFinishedSinceThePreviousSnapshot() throws {
        let finished = try decodeShell(
            status: "completed", request: "null", completedAt: #""2026-11-21T12:00:00.125Z""#
        )
        var prior = ShellSnapshot(
            snapshotSequence: 1, projects: [], threads: [], updatedAt: "2026-11-21T12:00:00Z"
        )
        let current = ShellSnapshot(
            snapshotSequence: 2, projects: [], threads: [finished], updatedAt: "2026-11-21T12:00:01Z"
        )
        #expect(newlyFinishedThreads(from: prior, to: current).map(\.id) == ["thread"])
        prior.updatedAt = "2026-11-21T12:00:00.500Z"
        #expect(newlyFinishedThreads(from: prior, to: current).isEmpty)
    }

    @Test func T3CodeVisitAtOrAfterCompletionMarksTheResultSeen() throws {
        let completion = #""2026-11-21T12:00:00.125Z""#
        let read = try decodeShell(
            status: "completed", request: "null", completedAt: completion, lastVisitedAt: completion
        )
        let unread = try decodeShell(
            status: "completed", request: "null", completedAt: completion, lastVisitedAt: #""2026-11-21T12:00:00Z""#
        )
        let noVisit = try decodeShell(status: "completed", request: "null", completedAt: completion)
        #expect(read.hasSeenCompletion)
        #expect(!unread.hasSeenCompletion)
        #expect(!noVisit.hasSeenCompletion)
    }

    @Test func previouslyAcknowledgedWatermarkRequiresANewOpenToCountAgain() throws {
        let timestamp = #""2026-11-21T12:00:00.125Z""#
        let background = try decodeShell(
            status: "completed", request: "null", completedAt: timestamp, lastVisitedAt: timestamp
        )
        let opened = try decodeShell(
            status: "completed", request: "null", completedAt: timestamp, lastVisitedAt: timestamp,
            openedAt: "1795262401000"
        )
        let foregroundSince = Date(timeIntervalSince1970: 1_795_262_400.5)
        #expect(!background.hasNewForegroundCompletionVisit(
            since: nil, foregroundSince: foregroundSince, mostRecentOpenMilliseconds: 1_795_262_401_000
        ))
        #expect(!opened.hasNewForegroundCompletionVisit(
            since: background, foregroundSince: foregroundSince, mostRecentOpenMilliseconds: 1_795_262_402_000
        ))
        #expect(opened.hasNewForegroundCompletionVisit(
            since: background, foregroundSince: foregroundSince, mostRecentOpenMilliseconds: 1_795_262_401_000
        ))
        #expect(!opened.hasNewForegroundCompletionVisit(
            since: opened, foregroundSince: foregroundSince, mostRecentOpenMilliseconds: 1_795_262_401_000
        ))
    }

    @Test func legacyTeardownCanNotifyButAProtocolV2CancellationCannot() throws {
        let running = try decodeShell(status: "running", request: "null")
        let cancelled = try decodeShell(
            status: "cancelled", request: "null", completedAt: #""2026-11-21T12:00:01Z""#
        )
        var legacy = cancelled
        legacy.usesOrchestrationV2 = nil
        legacy.latestTurn?.state = "interrupted"
        legacy.latestTurn?.assistantMessageId = "finished-message"
        legacy.session = Session(status: "stopped")
        let prior = ShellSnapshot(
            snapshotSequence: 1, projects: [], threads: [running], updatedAt: "2026-11-21T12:00:00Z"
        )
        var current = ShellSnapshot(
            snapshotSequence: 2, projects: [], threads: [cancelled], updatedAt: "2026-11-21T12:00:01Z"
        )
        #expect(resolveThreadAwarenessPhase(cancelled) == nil)
        #expect(newlyFinishedThreads(from: prior, to: current).isEmpty)
        current.threads = [legacy]
        #expect(newlyFinishedThreads(from: prior, to: current).map(\.id) == ["thread"])
    }

    @Test func projectionSuppliesQuestionsAndActivity() throws {
        let data = Data("""
        {"snapshotSequence":1,"projection":{
          "thread":{\(thread)},
          "runs":[
            {"id":"run","ordinal":1,"status":"waiting","startedAt":"2026-11-21T12:01:00Z"},
            {"id":"already-ran","ordinal":2,"status":"completed","completedAt":"2026-11-21T11:59:00Z"},
            {"id":"next","ordinal":3,"status":"queued"}
          ],
          "runtimeRequests":[
            {"id":"question","kind":"user_input","status":"pending","createdAt":"2026-11-21T12:00:00Z"},
            {"id":"sign-in","kind":"auth_refresh","status":"pending","createdAt":"2026-11-21T12:01:00Z"},
            {"id":"old","kind":"command","status":"resolved","createdAt":"2026-11-21T11:00:00Z"}
          ],
          "messages":[],
          "turnItems":[
            {"id":"question-item","type":"user_input_request","requestId":"question",
             "questions":[{"id":"confirm","header":"Confirm","question":"Proceed?","options":[]}]},
            {"id":"running-tool","type":"command_execution","status":"waiting","input":"pwd",
             "updatedAt":"2026-11-21T11:58:00Z"},
            {"id":"tool","type":"command_execution","status":"completed","input":"pwd",
             "updatedAt":"2026-11-21T11:59:00Z"},
            {"id":"turn-item:runtime-request-delivery-failure:old","type":"error","runId":"run",
             "updatedAt":"2026-11-21T12:02:00Z"}
          ]
        }}
        """.utf8)
        let detail = try JSONDecoder().decode(OrchestrationV2Detail.self, from: data).projection.detail
        #expect(derivePendingUserInputs(from: detail.activities).first?.questions.first?.id == "confirm")
        #expect(derivePendingApprovals(from: detail.activities).isEmpty)
        let signIn = try #require(derivePendingUserInputs(from: detail.activities).first { $0.id == "sign-in" })
        #expect(signIn.questions.first?.header == "Sign-in required")
        #expect(signIn.questions.first?.options.isEmpty == true)
        let events = deriveRecentActivity(from: detail.activities)
        #expect(events.map(\.detail) == ["pwd", "pwd"])
        #expect(events.map(\.isRunning) == [true, false])
        let deliveryFailure = try #require(detail.activities.first { $0.kind == "prompt.delivery.failed" })
        #expect(detail.latestTurn?.turnId == "run")
        #expect(deliveryFailure.turnId == detail.latestTurn?.turnId)
    }

    @Test func completedRunsAreOrderedByTheCompletionTime() throws {
        let data = Data("""
        {"snapshotSequence":1,"projection":{
          "thread":{\(thread)},
          "runs":[
            {"id":"finished-last","ordinal":1,"status":"completed","completedAt":"2026-11-21T12:00:00.125Z"},
            {"id":"finished-first","ordinal":2,"status":"completed","completedAt":"2026-11-21T12:00:00Z"},
            {"id":"waiting","ordinal":3,"status":"queued"}
          ],
          "runtimeRequests":[],"messages":[],"turnItems":[]
        }}
        """.utf8)
        let detail = try JSONDecoder().decode(OrchestrationV2Detail.self, from: data).projection.detail
        #expect(detail.latestTurn?.turnId == "finished-last")
    }

    @Test func optionIdentityIncludesTheWireValue() {
        let first = UserInputOption(label: "Yes", description: "", value: "1")
        let second = UserInputOption(label: "Yes", description: "", value: "2")
        let legacy = UserInputOption(label: "Yes", description: "")
        #expect(first.id != second.id)
        #expect(legacy.id == UserInputOption(label: "Yes", description: "", value: "Yes").id)
    }

    @Test func answersUseTheRuntimeRequestCommand() throws {
        let response = try OrchestrationV2CommandFrame(command: .userInputRespond(
            commandId: "command", threadId: "thread", requestId: "question",
            answers: ["confirm": .string("yes")], createdAt: "2026-11-21T12:00:00Z"
        ))
        #expect(response.payload["type"] == .string("runtime-request.respond"))
        #expect(response.payload["requestId"] == .string("question"))
        #expect(response.payload["answers"]?["confirm"] == .string("yes"))
    }

    @Test func threadLinksUseTheEnvironmentAndThreadIDs() throws {
        let thread = ScopedThreadID(environmentID: EnvironmentID("environment"), threadID: "thread")
        #expect(thread.desktopURL.absoluteString == "t3code://threads/environment/thread")
        let baseURL = try #require(URL(string: "https://t3.example/"))
        #expect(thread.webURL(baseURL: baseURL).absoluteString == "https://t3.example/threads/environment/thread")
    }

    private var thread: String {
        """
        "id":"thread","projectId":"project","title":"Test","modelSelection":{"model":"test"},
        "updatedAt":"2026-11-21T12:00:00Z"
        """
    }

    private func decodeShell(
        status: String, request: String, runID: String = "run", completedAt: String = "null",
        lastVisitedAt: String = "null", openedAt: String = "null"
    ) throws -> ThreadShell {
        let data = Data("""
        {"snapshotSequence":1,"projects":[],"threads":[{
          \(thread),"latestRunId":"\(runID)","latestRunCompletedAt":\(completedAt),"lastVisitedAt":\(lastVisitedAt),"opens":{"openedAt":\(openedAt)},"status":"\(status)","pendingRuntimeRequest":\(request)
        }]}
        """.utf8)
        return try #require(JSONDecoder().decode(OrchestrationV2Shell.self, from: data).snapshot.threads.first)
    }
}
