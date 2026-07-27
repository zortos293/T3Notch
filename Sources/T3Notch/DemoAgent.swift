import AppKit
import SwiftUI
import T3NotchCore

/// A pretend agent, for the welcome window to point at.
///
/// Explaining the notch in prose is hopeless: everything worth knowing about it
/// is a thing it does when an agent is working. So the welcome runs one. The
/// fake thread, its plan, its commands and its questions go into the same store
/// the real ones do, which means the panel showing them is the real panel with
/// no demonstration mode of its own — and the question it asks is answered
/// through the same buttons that answer a real one.
///
/// `AgentStore.beginDemo()` holds the poller's snapshots back while this runs, so
/// live agents cannot appear halfway through the tour.
@MainActor
final class DemoAgent {
    /// Chapters, driven by the window rather than by a timer, so nobody is
    /// hurried through and nothing happens off screen.
    enum Chapter {
        case working
        case asking
        case landing
        case crowd
    }

    private let store: AgentStore
    private var script: Task<Void, Never>?
    private var startedAt = Date()

    /// Called when the reader answers the demo's question in the notch.
    var onAnswered: (() -> Void)?
    /// Called when the reader presses another agent's card.
    var onSwitched: (() -> Void)?

    init(store: AgentStore) {
        self.store = store
    }

    var isRunning: Bool { store.isDemoRunning }

    // MARK: - Chapters

    func start() {
        guard !store.isDemoRunning else { return }
        startedAt = Date()
        store.beginDemo(
            onAnswer: { [weak self] in self?.answered() },
            onFocus: { [weak self] id in self?.focused(id) }
        )
        install(phase: .running)
        store.stage(.demo)
        play {
            // Rows land a beat apart: the feed is meant to be watched filling
            // up, which is what it does when an agent is actually working.
            for (index, event) in Self.activity.enumerated() {
                try await Task.sleep(for: .milliseconds(index == 0 ? 350 : 900))
                self.append(event)
                self.completeStep(at: index - 1)
            }
        }
    }

    func ask() {
        guard store.isDemoRunning else { return }
        cancelScript()
        store.demoPrompt(Self.questions, on: Self.threadId)
        store.stage(.asking)
        store.playAttentionSound()
    }

    func land() {
        guard store.isDemoRunning else { return }
        cancelScript()
        store.demoPrompt(nil, on: Self.threadId)
        play {
            self.completeAllSteps()
            self.append(
                ActivityEvent(
                    id: "demo-final",
                    kind: .command,
                    label: "Ran command",
                    detail: "git commit -m \"Teach the notch to explain itself\"",
                    isRunning: false,
                    createdAt: ISO8601Parsing.nowString()
                )
            )
            self.store.stage(.landed)
            self.store.celebrate(.tasksComplete(count: Self.plan.count))
            try await Task.sleep(for: .seconds(2.6))
            // The second milestone is the one worth waiting for: a branch
            // landing is the moment the notch exists for.
            self.store.celebrate(.branchMerged(branch: "t3notch/welcome", into: "main"))
        }
    }

    /// Fills the deck. Two more pretend agents move in, one of them in another
    /// project and one of them wanting an answer, because a single card says
    /// nothing about what an afternoon with several chats running looks like.
    func crowd() {
        guard store.isDemoRunning else { return }
        cancelScript()
        store.demoPrompt(nil, on: Self.threadId)
        // The merge banner belongs to the page before this one, and the cards
        // need the room more than a celebration that has been read.
        store.dismissCelebration()
        if understudies.isEmpty { understudies = Self.makeUnderstudies() }
        install(phase: .running)
        store.stage(.crowd(switched: false))
    }

    /// Hands the panel back to the real agents.
    func stop() {
        cancelScript()
        guard store.isDemoRunning else { return }
        store.endDemo()
    }

    // MARK: - Script plumbing

    private func play(_ body: @escaping () async throws -> Void) {
        cancelScript()
        script = Task { [weak self] in
            do { try await body() } catch {}
            _ = self
        }
    }

    private func cancelScript() {
        script?.cancel()
        script = nil
    }

    private func answered() {
        // The thread goes back to working the moment the question is answered,
        // exactly as a real one does.
        install(phase: .running)
        onAnswered?()
    }

    /// A card was pressed. Real threads have a detail stream to swap to; these
    /// carry their plan and activity around with them instead.
    private func focused(_ id: String) {
        if let understudy = understudies.first(where: { $0.thread.id == id }) {
            store.demoDetail(
                plan: understudy.plan,
                activity: understudy.activity,
                context: understudy.context
            )
            store.stage(.crowd(switched: true))
            onSwitched?()
        } else {
            store.demoDetail(
                plan: currentPlan,
                activity: Array(Self.activity.suffix(max(3, store.settingsValues.activityRows))),
                context: Self.mainContext
            )
        }
    }

    // MARK: - Fake world

    private func install(phase: DemoPhase) {
        let turn = LatestTurn(
            turnId: "demo-turn",
            state: phase == .completed ? "completed" : "running",
            requestedAt: startedAt.formatted(.iso8601),
            startedAt: startedAt.formatted(.iso8601),
            completedAt: phase == .completed ? ISO8601Parsing.nowString() : nil
        )
        let thread = ThreadShell(
            id: Self.threadId,
            projectId: Self.projectId,
            title: "Teach the notch to explain itself",
            modelSelection: ModelSelection(instanceId: "codex", model: "gpt-5.6-sol"),
            branch: "t3notch/welcome",
            worktreePath: "/Users/you/Projects/t3notch",
            latestTurn: turn,
            updatedAt: ISO8601Parsing.nowString(),
            hasPendingApprovals: false,
            hasPendingUserInput: phase == .asking
        )
        var projects = [ProjectShell(id: Self.projectId, title: "T3Notch")]
        var threads = [thread]
        for understudy in understudies {
            threads.append(understudy.thread)
            if !projects.contains(where: { $0.id == understudy.project.id }) {
                projects.append(understudy.project)
            }
        }

        store.demoWorld(
            projects: projects,
            threads: threads,
            plan: currentPlan,
            context: Self.mainContext,
            focus: thread.id
        )
    }

    private enum DemoPhase {
        case running
        case asking
        case completed
    }

    /// A pretend agent with no story of its own: it exists to be a second card,
    /// so it carries the panel's whole lower half around with it.
    private struct Understudy {
        let project: ProjectShell
        let thread: ThreadShell
        let plan: ActivePlanState
        let activity: [ActivityEvent]
        let context: ContextWindowSnapshot
    }

    /// Built when the deck fills rather than up front, so their clocks read as
    /// having been running for a while by the time they are on screen.
    private var understudies: [Understudy] = []

    private static func makeUnderstudies() -> [Understudy] {
        let now = ISO8601Parsing.nowString()
        let t3notch = ProjectShell(id: projectId, title: "T3Notch")
        let opennow = ProjectShell(id: "demo-project-2", title: "opennow")

        return [
            Understudy(
                project: t3notch,
                thread: ThreadShell(
                    id: "demo-thread-2",
                    projectId: t3notch.id,
                    title: "Trim the settings panel",
                    modelSelection: ModelSelection(
                        instanceId: "claude",
                        model: "claude-opus-5"
                    ),
                    branch: "t3notch/settings-trim",
                    worktreePath: "/Users/you/Projects/t3notch",
                    latestTurn: turn(startedMinutesAgo: 7),
                    updatedAt: now,
                    hasPendingApprovals: false,
                    hasPendingUserInput: false
                ),
                plan: plan(
                    ["Measure the cards", "Cut the padding", "Re-render the docs"],
                    completed: 1
                ),
                activity: [
                    ActivityEvent(
                        id: "demo-2-1",
                        kind: .fileChange,
                        label: "Read file",
                        detail: "Sources/T3Notch/SettingsView.swift",
                        isRunning: false,
                        createdAt: now
                    ),
                    ActivityEvent(
                        id: "demo-2-2",
                        kind: .command,
                        label: "Ran command",
                        detail: "swift build",
                        isRunning: true,
                        createdAt: now
                    ),
                ],
                context: ContextWindowSnapshot(
                    usedTokens: 87_000,
                    maxTokens: 272_000,
                    usedPercentage: 32,
                    updatedAt: now
                )
            ),
            Understudy(
                project: opennow,
                thread: ThreadShell(
                    id: "demo-thread-3",
                    projectId: opennow.id,
                    title: "Fix the switch reconnect lag",
                    modelSelection: ModelSelection(
                        instanceId: "cursor",
                        model: "composer-2.5"
                    ),
                    branch: "opennow/reconnect",
                    worktreePath: "/Users/you/Projects/opennow",
                    latestTurn: turn(startedMinutesAgo: 21),
                    updatedAt: now,
                    hasPendingApprovals: false,
                    // The orange card is the point of this one: an agent in
                    // another project can want you while you read about this one.
                    hasPendingUserInput: true
                ),
                plan: plan(
                    ["Reproduce the drop", "Instrument the socket", "Pick a backoff"],
                    completed: 2
                ),
                activity: [
                    ActivityEvent(
                        id: "demo-3-1",
                        kind: .search,
                        label: "Searched",
                        detail: "reconnectAttempts",
                        isRunning: false,
                        createdAt: now
                    ),
                    ActivityEvent(
                        id: "demo-3-2",
                        kind: .fileChange,
                        label: "Edited file",
                        detail: "src/net/socket.ts",
                        isRunning: false,
                        createdAt: now
                    ),
                    ActivityEvent(
                        id: "demo-3-3",
                        kind: .command,
                        label: "Ran command",
                        detail: "npm run test:net",
                        isRunning: false,
                        createdAt: now
                    ),
                ],
                context: ContextWindowSnapshot(
                    usedTokens: 139_000,
                    maxTokens: 272_000,
                    usedPercentage: 51,
                    updatedAt: now
                )
            ),
        ]
    }

    private static func turn(startedMinutesAgo minutes: Int) -> LatestTurn {
        let started = Date().addingTimeInterval(-Double(minutes) * 60)
        return LatestTurn(
            turnId: "demo-turn-\(minutes)",
            state: "running",
            requestedAt: started.formatted(.iso8601),
            startedAt: started.formatted(.iso8601),
            completedAt: nil
        )
    }

    private static func plan(_ steps: [String], completed: Int) -> ActivePlanState {
        ActivePlanState(
            steps: steps.enumerated().map { index, step in
                PlanStep(
                    step: step,
                    status: index < completed
                        ? .completed : (index == completed ? .inProgress : .pending)
                )
            },
            updatedAt: ISO8601Parsing.nowString()
        )
    }

    private static var mainContext: ContextWindowSnapshot {
        ContextWindowSnapshot(
            usedTokens: 41_000,
            maxTokens: 272_000,
            usedPercentage: 15,
            updatedAt: ISO8601Parsing.nowString()
        )
    }

    private var completedSteps = 0

    private var currentPlan: ActivePlanState {
        ActivePlanState(
            steps: Self.plan.enumerated().map { index, step in
                PlanStep(
                    step: step,
                    status: index < completedSteps
                        ? .completed : (index == completedSteps ? .inProgress : .pending)
                )
            },
            updatedAt: ISO8601Parsing.nowString()
        )
    }

    private func append(_ event: ActivityEvent) {
        var events = store.recentActivity
        // Whatever was running has finished by the time the next thing starts.
        events = events.map { row in
            var row = row
            row.isRunning = false
            return row
        }
        events.append(event)
        let limit = max(3, store.settingsValues.activityRows)
        store.demoActivity(Array(events.suffix(limit)))
    }

    private func completeStep(at index: Int) {
        guard index >= 0, index < Self.plan.count else { return }
        completedSteps = max(completedSteps, index + 1)
        store.demoPlan(currentPlan, finishedStep: Self.plan[index])
    }

    private func completeAllSteps() {
        completedSteps = Self.plan.count
        store.demoPlan(
            ActivePlanState(
                steps: Self.plan.map { PlanStep(step: $0, status: .completed) },
                updatedAt: ISO8601Parsing.nowString()
            ),
            finishedStep: Self.plan.last
        )
    }

    // MARK: - Script

    private static let threadId = "demo-thread"
    private static let projectId = "demo-project"

    private static let plan = [
        "Read how the notch is drawn",
        "Add the welcome walkthrough",
        "Ask which fruit to demo with",
        "Run the tests",
    ]

    private static let activity: [ActivityEvent] = [
        ActivityEvent(
            id: "demo-1",
            kind: .search,
            label: "Searched",
            detail: "NotchShape",
            isRunning: false,
            createdAt: ISO8601Parsing.nowString()
        ),
        ActivityEvent(
            id: "demo-2",
            kind: .fileChange,
            label: "Edited file",
            detail: "Sources/T3Notch/QuickStartView.swift",
            isRunning: false,
            createdAt: ISO8601Parsing.nowString()
        ),
        ActivityEvent(
            id: "demo-3",
            kind: .command,
            label: "Ran command",
            detail: "swift build",
            isRunning: true,
            createdAt: ISO8601Parsing.nowString()
        ),
        ActivityEvent(
            id: "demo-4",
            kind: .fileChange,
            label: "Created file",
            detail: "Sources/T3Notch/DemoAgent.swift",
            isRunning: false,
            createdAt: ISO8601Parsing.nowString()
        ),
    ]

    private static let questions = PendingUserInput(
        requestId: "demo-request",
        createdAt: ISO8601Parsing.nowString(),
        questions: [
            UserInputQuestion(
                id: "demo-fruit",
                header: "Demo",
                question: "Pick a fruit for the demo — either is fine.",
                options: [
                    UserInputOption(
                        label: "Apple",
                        description: "The answer goes nowhere. Nothing is running."
                    ),
                    UserInputOption(
                        label: "Mango",
                        description: "A real question would reach the agent instead."
                    ),
                ],
                multiSelect: false
            ),
            UserInputQuestion(
                id: "demo-second",
                header: "Demo",
                question: "One more, to show how a second question slides in.",
                options: [
                    UserInputOption(
                        label: "Got it",
                        description: "Questions arrive one at a time, never in a wall."
                    ),
                    UserInputOption(
                        label: "Show me again",
                        description: "The window will not mind either way."
                    ),
                ],
                multiSelect: false
            ),
        ]
    )
}
