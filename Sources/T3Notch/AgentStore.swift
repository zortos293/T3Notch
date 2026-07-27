import AppKit
import Foundation
import Observation
import T3NotchCore

@MainActor
@Observable
final class AgentStore {
    enum NotchPresentation: Equatable {
        case hidden
        case pill
        case expanded
        case attention
    }

    var connectionState: ConnectionState = .connecting
    var projects: [ProjectShell] = []
    var threads: [ThreadShell] = []
    var focusedThreadId: String?
    var threadDetail: ThreadDetail?
    var pendingApprovals: [PendingApproval] = []
    var pendingUserInputs: [PendingUserInput] = []
    var plan: ActivePlanState?
    var contextWindow: ContextWindowSnapshot?
    var recentActivity: [ActivityEvent] = []
    var presentation: NotchPresentation = .hidden
    var notchMetrics: NotchMetrics = .fallback
    /// Size of the panel actually drawn inside the oversized transparent window.
    var panelSize: CGSize = CGSize(
        width: NotchGeometry.virtualNotchWidth,
        height: NotchGeometry.virtualNotchHeight
    )
    /// Drives the elapsed clocks. SwiftUI re-renders on observable changes, not
    /// on wall-clock time, so reading `Date()` in a label froze it until
    /// something else happened to change — which, when not hovering, was nothing.
    var clock = Date()
    var isHovering = false
    /// Counts completions per step. Only ever increases, so the task list can
    /// use it as an animation trigger without a flag to clear afterwards.
    var taskCompletionTicks: [String: Int] = [:]
    var celebration: Celebration?
    /// Set while the quick start window is open, so the notch has something to
    /// show even with no agents running.
    private(set) var walkthrough: Walkthrough?
    private var isWalkthroughOpen = false
    var needsOnboarding = false
    var onboardingMessage: String?
    var answeredRequestIds: Set<String> = []
    var environment: EnvironmentDescriptor?

    private var transport: (any T3Transport)?
    private(set) var endpoint = ServerEndpoint()
    private var shellTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var subscribedThreadId: String?
    private var clockTimer: Timer?
    private var celebrationTask: Task<Void, Never>?
    private var celebrationToken = 0
    private var milestoneQueue: [Milestone] = []
    private var isCheckingMerges = false
    private var previousAttentionKeys: Set<String> = []
    private var attentionSound: NSSound?
    private let reviewStore = ReviewedCompletionStore()
    private let settings: SettingsStore
    private var mergeWatcher: MergeWatcher
    private var mergeTimer: Timer?
    /// Which forge setting `mergeWatcher` was built for, so it is only rebuilt
    /// when that actually changes — rebuilding resets what it has seen.
    private var watcherUsesForge: Bool
    private var hasReviewBaseline = false

    init(settings: SettingsStore) {
        let usesForge = settings.values.askForgeForMerges
        self.settings = settings
        watcherUsesForge = usesForge
        mergeWatcher = MergeWatcher(forge: usesForge ? .gh : .disabled)
    }

    var focusedThread: ThreadShell? {
        guard let focusedThreadId else { return activeThreads.first }
        return threads.first(where: { $0.id == focusedThreadId }) ?? activeThreads.first
    }

    var activeThreads: [ThreadShell] {
        threads.compactMap { thread -> (ThreadShell, AgentAwarenessPhase)? in
            guard let phase = resolveThreadAwarenessPhase(thread) else { return nil }
            switch phase {
            case .running, .starting, .waitingForApproval, .waitingForInput, .failed:
                return (thread, phase)
            case .completed:
                // A finished agent stays pinned until it has been reviewed in
                // T3 Code, so a result can't slip past while you look away.
                return awaitsReview(thread) ? (thread, phase) : nil
            case .stale:
                return nil
            }
        }
        .sorted { lhs, rhs in
            priority(lhs.1) > priority(rhs.1)
        }
        .map(\.0)
    }

    /// Completed threads the user has not dealt with yet. `settledAt` is T3 Code's
    /// own "handled" marker, so settling there clears the notch too.
    func awaitsReview(_ thread: ThreadShell) -> Bool {
        guard settings.values.keepFinishedUntilReviewed else { return false }
        guard resolveThreadAwarenessPhase(thread) == .completed else { return false }
        guard thread.settledAt == nil else { return false }
        return !reviewStore.contains(completionKey(for: thread))
    }

    var threadsAwaitingReview: [ThreadShell] {
        threads.filter { awaitsReview($0) }
    }

    /// Identifies one completion, so a fresh run after a review surfaces again
    /// while a mere `updatedAt` bump does not. Keyed on the turn id rather than
    /// `completedAt`, whose second granularity can collide across turns.
    private func completionKey(for thread: ThreadShell) -> String {
        let turn = thread.latestTurn
        let marker = turn?.turnId ?? turn?.completedAt ?? "idle"
        return "\(thread.id):\(marker)"
    }

    /// Marks a finished agent as seen and drops it from the notch.
    func markReviewed(_ thread: ThreadShell) {
        // Acting on the thread means the banner has served its purpose.
        dismissCelebration()
        reviewStore.insert(completionKey(for: thread))
        if focusedThreadId == thread.id {
            replaceFocusedThread(
                with: activeThreads.first { $0.id != thread.id }?.id
            )
        }
        recomputePresentation(userInitiated: true)
    }

    /// Starts mirroring the quick start window in the notch. The window owns this
    /// session, not the view inside it: a hosted view outlives a window that is
    /// closed rather than released, and a connection test finishing afterwards
    /// would otherwise switch the notch back on with no window to explain it.
    func beginWalkthrough() {
        isWalkthroughOpen = true
        applyWalkthrough(Walkthrough())
    }

    /// Hands the panel back to whatever the agents are doing.
    func endWalkthrough() {
        isWalkthroughOpen = false
        applyWalkthrough(nil)
    }

    /// Ignored unless a window is currently open.
    func updateWalkthrough(_ walkthrough: Walkthrough) {
        guard isWalkthroughOpen else { return }
        applyWalkthrough(walkthrough)
    }

    func stage(_ stage: Walkthrough.Stage) {
        updateWalkthrough(Walkthrough(stage: stage))
    }

    // MARK: - Demo

    /// While a demo is running the poller's snapshots are dropped on the floor,
    /// so a real agent cannot walk into the middle of the welcome tour, and the
    /// panel keeps showing the pretend one until the window is done with it.
    private(set) var isDemoRunning = false
    private var demoAnswerHandler: (() -> Void)?
    private var demoFocusHandler: ((String) -> Void)?

    func beginDemo(onAnswer: @escaping () -> Void, onFocus: @escaping (String) -> Void) {
        guard !isDemoRunning else { return }
        isDemoRunning = true
        demoAnswerHandler = onAnswer
        demoFocusHandler = onFocus
        // Real agents step aside rather than share the panel with a fake one.
        threads = []
        projects = []
        pendingApprovals = []
        pendingUserInputs = []
        plan = nil
        recentActivity = []
        contextWindow = nil
        focusedThreadId = nil
    }

    /// Clears the pretend world. The next snapshot, at most a second away, puts
    /// the real one back.
    func endDemo() {
        guard isDemoRunning else { return }
        isDemoRunning = false
        demoAnswerHandler = nil
        demoFocusHandler = nil
        dismissCelebration()
        threads = []
        projects = []
        pendingApprovals = []
        pendingUserInputs = []
        plan = nil
        recentActivity = []
        contextWindow = nil
        taskCompletionTicks = [:]
        focusedThreadId = nil
        recomputePresentation(userInitiated: false)
    }

    func demoWorld(
        projects: [ProjectShell],
        threads: [ThreadShell],
        plan: ActivePlanState?,
        context: ContextWindowSnapshot?,
        focus: String? = nil
    ) {
        guard isDemoRunning else { return }
        self.projects = projects
        self.threads = threads
        self.plan = plan
        contextWindow = context
        focusedThreadId = focus ?? threads.first?.id
        recomputePresentation(userInitiated: false)
    }

    func demoActivity(_ events: [ActivityEvent]) {
        guard isDemoRunning else { return }
        recentActivity = events
    }

    /// Everything the panel shows below the cards, for whichever pretend agent the
    /// reader just pressed.
    func demoDetail(
        plan: ActivePlanState?,
        activity: [ActivityEvent],
        context: ContextWindowSnapshot?
    ) {
        guard isDemoRunning else { return }
        self.plan = plan
        recentActivity = activity
        contextWindow = context
        taskCompletionTicks = [:]
    }

    /// Bumping the tick is what makes the finished row animate, the same way a
    /// real plan update does through `noteFinishedTasks`.
    func demoPlan(_ plan: ActivePlanState, finishedStep: String?) {
        guard isDemoRunning else { return }
        self.plan = plan
        if let finishedStep {
            taskCompletionTicks[finishedStep, default: 0] += 1
        }
    }

    /// Puts the pretend thread back to work once its question is answered.
    private func finishDemoPrompt() {
        threads = threads.map { thread in
            var thread = thread
            thread.hasPendingUserInput = false
            thread.hasPendingApprovals = false
            return thread
        }
        recomputePresentation(userInitiated: true)
        demoAnswerHandler?()
    }

    func demoPrompt(_ input: PendingUserInput?, on threadId: String) {
        guard isDemoRunning else { return }
        pendingUserInputs = input.map { [$0] } ?? []
        answeredRequestIds = []
        threads = threads.map { thread in
            guard thread.id == threadId else { return thread }
            var thread = thread
            thread.hasPendingUserInput = input != nil
            return thread
        }
        recomputePresentation(forceAttention: input != nil)
    }

    private func applyWalkthrough(_ walkthrough: Walkthrough?) {
        guard self.walkthrough != walkthrough else { return }
        self.walkthrough = walkthrough
        recomputePresentation(userInitiated: false)
    }

    /// Opens the thread in T3 Code's own UI, which is what "reviewed" means here.
    ///
    /// The desktop app is preferred when it is already running: T3 Code registers
    /// `t3code://` but only ever reveals its window on a second instance, so there
    /// is no deep link to a single thread. Bringing it forward beats opening a
    /// duplicate of the same thread in a browser tab.
    func openInT3Code(_ thread: ThreadShell) {
        if settings.values.openInDesktopApp, T3CodeApp.activate() {
            markReviewed(thread)
            return
        }
        if let environmentId = environment?.environmentId,
           let url = URL(
               string: "/threads/\(environmentId)/\(thread.id)",
               relativeTo: endpoint.baseURL
           ) {
            NSWorkspace.shared.open(url)
        }
        markReviewed(thread)
    }

    var focusedPhase: AgentAwarenessPhase? {
        guard let thread = focusedThread else { return nil }
        return resolveThreadAwarenessPhase(thread)
    }

    var projectTitle: String {
        guard let thread = focusedThread else { return "T3" }
        return projectTitle(for: thread)
    }

    func projectTitle(for thread: ThreadShell) -> String {
        projects.first(where: { $0.id == thread.projectId })?.title ?? "Project"
    }

    /// Active threads grouped by project, so the switcher can show one card
    /// stack per project. Projects keep the priority order of their best thread.
    var activeThreadsByProject: [(project: ProjectShell, threads: [ThreadShell])] {
        var order: [String] = []
        var grouped: [String: [ThreadShell]] = [:]
        for thread in activeThreads {
            if grouped[thread.projectId] == nil { order.append(thread.projectId) }
            grouped[thread.projectId, default: []].append(thread)
        }
        return order.compactMap { projectId in
            guard let threads = grouped[projectId] else { return nil }
            let project = projects.first { $0.id == projectId }
                ?? ProjectShell(id: projectId, title: "Project")
            return (project, threads)
        }
    }

    var elapsedLabel: String? {
        focusedThread.flatMap { elapsedLabel(for: $0) }
    }

    func elapsedLabel(for thread: ThreadShell) -> String? {
        guard let start = turnStart(of: thread) else { return nil }
        // A finished turn's duration is fixed; only a live one counts up.
        let end = thread.latestTurn?.completedAt.flatMap(ISO8601Parsing.date(from:)) ?? clock
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let m = seconds / 60
        let s = seconds % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Machine + model + timing detail

    /// Which provider is driving the focused thread, for the brand logo.
    var providerBrand: ProviderBrand {
        guard let focusedThread else { return .unknown }
        return providerBrand(for: focusedThread)
    }

    func providerBrand(for thread: ThreadShell) -> ProviderBrand {
        ProviderBrand.resolve(
            instanceId: thread.modelSelection.instanceId ?? thread.session?.providerInstanceId,
            providerName: thread.modelSelection.provider ?? thread.session?.providerName
        )
    }

    var modelLabel: String? {
        focusedThread.flatMap { modelLabel(for: $0) }
    }

    func modelLabel(for thread: ThreadShell) -> String? {
        thread.modelSelection.model.nilIfBlank
    }

    /// Machine the work is happening on, as reported by the server environment.
    var machineLabel: String? {
        environment?.label?.nilIfBlank
    }

    var platformLabel: String? {
        environment?.platform?.displayName
    }

    var serverVersionLabel: String? {
        environment?.serverVersion?.nilIfBlank
    }

    /// Branch or worktree the agent is editing.
    var workspaceLabel: String? {
        if let branch = focusedThread?.branch?.nilIfBlank { return branch }
        guard let path = focusedThread?.worktreePath?.nilIfBlank else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func turnStart(of thread: ThreadShell) -> Date? {
        guard let raw = thread.latestTurn?.startedAt ?? thread.latestTurn?.requestedAt
        else { return nil }
        return ISO8601Parsing.date(from: raw)
    }

    private var turnStart: Date? {
        focusedThread.flatMap { turnStart(of: $0) }
    }

    /// Wall-clock time the current turn began, e.g. "18:12".
    var startedAtLabel: String? {
        turnStart?.formatted(date: .omitted, time: .shortened)
    }

    /// One-line answer to "what is it doing and for how long".
    var workingSinceLabel: String? {
        guard let startedAtLabel else { return nil }
        guard let phase = focusedPhase else { return "Last active \(startedAtLabel)" }
        let duration = elapsedLabel.map { " · \($0)" } ?? ""
        switch phase {
        case .running, .starting:
            return "Working since \(startedAtLabel)\(duration)"
        case .waitingForApproval, .waitingForInput:
            return "Waiting since \(startedAtLabel)\(duration)"
        case .failed:
            return "Failed after \(elapsedLabel ?? "—")"
        case .completed:
            return "Finished at \(startedAtLabel)\(duration)"
        case .stale:
            return "Idle since \(startedAtLabel)"
        }
    }

    func bootstrap() {
        Task { await start() }
    }

    func start() async {
        let endpoint = await ServerDiscovery.resolveEndpoint()
        self.endpoint = endpoint
        var token = KeychainStore.loadToken()

        if token == nil {
            do {
                let minted = try await TokenMinting.mintToken()
                try KeychainStore.saveToken(minted)
                token = minted
            } catch {
                needsOnboarding = true
                onboardingMessage =
                    "Could not mint a token automatically.\n\nRun:\n  npx -y t3@latest auth session issue --token-only\n\nand paste it here.\n\n\(error.localizedDescription)"
                connectionState = .unauthorized
                return
            }
        }

        guard let token else { return }

        do {
            _ = try await TokenMinting.verifyToken(token: token, endpoint: endpoint)
        } catch {
            needsOnboarding = true
            onboardingMessage =
                "Saved token was rejected. Paste a fresh token from:\n  npx -y t3@latest auth session issue --token-only\n\n\(error.localizedDescription)"
            connectionState = .unauthorized
            return
        }

        needsOnboarding = false
        let client = T3HTTPClient(endpoint: endpoint, token: token)
        environment = try? await client.fetchEnvironment()
        let polling = PollingTransport(client: client)
        polling.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
                if state == .unauthorized {
                    self?.needsOnboarding = true
                    self?.onboardingMessage = "Session expired. Paste a new bearer token."
                }
            }
        }
        transport = polling
        connectionState = .connecting

        shellTask?.cancel()
        shellTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in polling.shell {
                await self.applyShell(snapshot)
            }
        }

        startMergeWatch()
    }

    /// Settings the views need. Reading them through the store keeps the panel's
    /// SwiftUI tree from having to be handed a second observable object.
    var settingsValues: SettingsStore.Values { settings.values }

    /// Re-reads settings after the control panel changes one.
    func applySettings() {
        // Rebuilding the watcher forgets which branches were outstanding, so it
        // only happens when the forge setting genuinely flipped.
        if watcherUsesForge != settings.values.askForgeForMerges {
            watcherUsesForge = settings.values.askForgeForMerges
            mergeWatcher = MergeWatcher(forge: watcherUsesForge ? .gh : .disabled)
        }
        startMergeWatch()

        if !settings.values.celebrateMilestones {
            dismissCelebration()
        }
        recomputePresentation(userInitiated: true)
    }

    /// Merges are a human action minutes or hours after a turn ends, so this
    /// polls slowly and independently of the agent's own activity.
    private func startMergeWatch() {
        mergeTimer?.invalidate()
        mergeTimer = nil
        guard settings.values.watchMerges else { return }
        mergeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForMerges()
            }
        }
        Task { await checkForMerges() }
    }

    func submitManualToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        Task {
            let endpoint = await ServerDiscovery.resolveEndpoint()
            do {
                _ = try await TokenMinting.verifyToken(token: token, endpoint: endpoint)
                try KeychainStore.saveToken(token)
                needsOnboarding = false
                await start()
            } catch {
                onboardingMessage = "Token rejected: \(error.localizedDescription)"
            }
        }
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        recomputePresentation(userInitiated: true)
    }

    func selectThread(_ id: String) {
        guard id != focusedThreadId else { return }
        // A pretend agent has no detail stream to swap to, so the demo hands over
        // the card's plan and activity itself.
        if isDemoRunning {
            focusedThreadId = id
            demoFocusHandler?(id)
            recomputePresentation(userInitiated: true)
            return
        }
        replaceFocusedThread(with: id)
        recomputePresentation(userInitiated: true)
    }

    func expand() {
        presentation = .expanded
        transport?.setExpanded(true)
        if let id = focusedThread?.id {
            subscribeDetail(id)
        }
        syncClock()
    }

    func collapseIfIdle() {
        if presentation == .attention { return }
        if isHovering { return }
        recomputePresentation(userInitiated: false)
    }

    func respondToApproval(_ approval: PendingApproval, decision: ApprovalDecision) {
        guard let threadId = focusedThread?.id else { return }
        if isDemoRunning {
            pendingApprovals.removeAll { $0.requestId == approval.requestId }
            finishDemoPrompt()
            return
        }
        answeredRequestIds.insert(approval.requestId)
        pendingApprovals.removeAll { $0.requestId == approval.requestId }
        let command = DispatchCommand.approvalRespond(
            commandId: UUID().uuidString,
            threadId: threadId,
            requestId: approval.requestId,
            decision: decision,
            createdAt: ISO8601Parsing.nowString()
        )
        Task {
            try? await transport?.dispatch(command)
        }
    }

    func respondToUserInput(_ input: PendingUserInput, answers: [String: JSONValue]) {
        guard let threadId = focusedThread?.id else { return }
        if isDemoRunning {
            pendingUserInputs.removeAll { $0.requestId == input.requestId }
            finishDemoPrompt()
            return
        }
        answeredRequestIds.insert(input.requestId)
        pendingUserInputs.removeAll { $0.requestId == input.requestId }
        let command = DispatchCommand.userInputRespond(
            commandId: UUID().uuidString,
            threadId: threadId,
            requestId: input.requestId,
            answers: answers,
            createdAt: ISO8601Parsing.nowString()
        )
        Task {
            try? await transport?.dispatch(command)
        }
    }

    func interruptTurn() {
        guard let thread = focusedThread else { return }
        let command = DispatchCommand.turnInterrupt(
            commandId: UUID().uuidString,
            threadId: thread.id,
            turnId: thread.latestTurn?.turnId,
            createdAt: ISO8601Parsing.nowString()
        )
        Task {
            try? await transport?.dispatch(command)
        }
    }

    // MARK: - Private

    private func applyShell(_ snapshot: ShellSnapshot) async {
        // The welcome tour owns the panel while it runs.
        guard !isDemoRunning else { return }
        projects = snapshot.projects
        threads = snapshot.threads.filter { $0.archivedAt == nil }

        // Everything already finished when the notch started counts as seen,
        // otherwise the first snapshot would pin every historical thread.
        if !hasReviewBaseline {
            hasReviewBaseline = true
            for thread in threads where resolveThreadAwarenessPhase(thread) == .completed {
                reviewStore.insert(completionKey(for: thread))
            }
        }

        let attentionThreads = threads.filter {
            $0.hasPendingApprovals || $0.hasPendingUserInput
        }
        let attentionKeys = Set(
            attentionThreads.map { "\($0.id):\($0.hasPendingApprovals):\($0.hasPendingUserInput)" }
        )
        let newAttention = !attentionKeys.isSubset(of: previousAttentionKeys)
            && !attentionKeys.isEmpty
        previousAttentionKeys = attentionKeys

        let activeIds = activeThreads.map(\.id)
        let preferredFocus = preferredFocusedThreadId(
            current: focusedThreadId,
            activeThreadIds: activeIds
        )
        replaceFocusedThread(with: preferredFocus)

        recomputePresentation(forceAttention: newAttention)

        if newAttention {
            playAttentionSound()
            if let first = attentionThreads.first {
                replaceFocusedThread(with: first.id)
            }
        }
    }

    /// Switches the card and its detail stream as one operation. Shell snapshots
    /// can leave completed threads in history with no awareness phase; retaining
    /// one as the focused card made the notch say Idle while another agent ran.
    private func replaceFocusedThread(with threadId: String?) {
        guard let threadId else {
            focusedThreadId = nil
            transport?.setFocusedThread(nil)
            detailTask?.cancel()
            detailTask = nil
            subscribedThreadId = nil
            clearFocusedDetail()
            return
        }

        guard threadId != focusedThreadId else {
            transport?.setFocusedThread(threadId)
            // Snapshots land every 800ms while an agent works; subscribing is
            // idempotent so the detail stream survives them.
            subscribeDetail(threadId)
            return
        }

        focusedThreadId = threadId
        // Detail arrives a poll later; drop the old thread's data so the card
        // never shows another agent's questions, plan, activity, or context.
        clearFocusedDetail()

        transport?.setFocusedThread(threadId)
        subscribeDetail(threadId)
    }

    private func clearFocusedDetail() {
        threadDetail = nil
        pendingApprovals = []
        pendingUserInputs = []
        plan = nil
        taskCompletionTicks = [:]
        contextWindow = nil
        recentActivity = []
    }

    /// Follows one thread's detail stream. Asking for the thread already being
    /// followed is a no-op: `threadDetail(_:)` hands out a fresh stream and ends
    /// the previous one, so re-subscribing on a timer would keep killing the
    /// stream before any detail arrived.
    private func subscribeDetail(_ threadId: String) {
        guard let transport else { return }
        guard threadId != subscribedThreadId else { return }
        detailTask?.cancel()
        subscribedThreadId = threadId
        detailTask = Task { [weak self] in
            guard let self else { return }
            for await detail in transport.threadDetail(threadId) {
                await self.applyDetail(detail)
            }
            // The stream ended (transport stopped or replaced); let the next
            // snapshot re-subscribe instead of going quiet for good.
            self.detailStreamEnded(threadId)
        }
    }

    private func detailStreamEnded(_ threadId: String) {
        guard subscribedThreadId == threadId else { return }
        subscribedThreadId = nil
    }

    // MARK: - Milestones

    /// Bumps the tick for steps that just flipped to completed, so the task list
    /// animates a finish once instead of on every poll.
    private func noteFinishedTasks(from previous: ActivePlanState?, to current: ActivePlanState?) {
        guard let current else { return }
        // A plan arriving for the first time is not a burst of completions —
        // opening the panel on finished work should sit still.
        guard let previous else { return }

        let wasCompleted = Set(
            previous.steps.filter { $0.status == .completed }.map(\.step)
        )
        let finished = current.steps
            .filter { $0.status == .completed && !wasCompleted.contains($0.step) }
            .map(\.step)
        guard !finished.isEmpty else { return }

        for step in finished {
            taskCompletionTicks[step, default: 0] += 1
        }

        if current.steps.allSatisfy({ $0.status == .completed }) {
            celebrate(.tasksComplete(count: current.steps.count))
        }
    }

    /// Branches worth watching: anything with a branch and a repo to look in.
    /// Finished threads stay on the list because a merge usually happens after
    /// the agent has stopped.
    private func mergeTargets() -> [MergeWatcher.Target] {
        threads
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(12)
            .compactMap { thread in
                guard let branch = thread.branch?.nilIfBlank else { return nil }
                // The project checkout is preferred over the worktree here: refs
                // are shared, so one root per project keeps the git calls down.
                let root = projects.first { $0.id == thread.projectId }?
                    .workspaceRoot?.nilIfBlank ?? thread.worktreePath?.nilIfBlank
                guard let root else { return nil }
                return MergeWatcher.Target(
                    threadId: thread.id,
                    branch: branch,
                    repositoryRoot: root
                )
            }
    }

    private func checkForMerges() async {
        // A forge round-trip can outlast the poll interval; overlapping checks
        // would only queue up behind each other on the watcher.
        guard !isCheckingMerges else { return }
        isCheckingMerges = true
        defer { isCheckingMerges = false }

        // Branches stay watched inside MergeWatcher after their thread stops
        // being listed, so an empty target list is still worth a poll.
        for merged in await mergeWatcher.newlyMerged(among: mergeTargets()) {
            celebrate(.branchMerged(branch: merged.branch, into: merged.baseBranch))
        }
    }

    func dismissCelebration() {
        celebrationTask?.cancel()
        celebrationTask = nil
        milestoneQueue = []
        celebration = nil
    }

    /// Shows a milestone banner, queueing behind one already on screen so a batch
    /// of merges each get their moment instead of the last one winning.
    func celebrate(_ milestone: Milestone) {
        guard settings.values.celebrateMilestones else { return }
        guard celebration == nil else {
            guard milestoneQueue.count < 4 else { return }
            milestoneQueue.append(milestone)
            return
        }
        show(milestone)
    }

    /// The token makes repeats of the same milestone re-trigger the animation
    /// instead of being swallowed as "no change".
    private func show(_ milestone: Milestone) {
        celebrationToken += 1
        celebration = Celebration(id: celebrationToken, milestone: milestone)
        celebrationTask?.cancel()
        let token = celebrationToken
        // Milestones land when the panel is idle in the notch, so open it —
        // otherwise the one moment worth seeing happens off-screen.
        presentation = .expanded
        transport?.setExpanded(true)
        syncClock()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(milestone.duration))
            guard let self, self.celebrationToken == token else { return }
            self.celebration = nil
            guard !self.milestoneQueue.isEmpty else {
                self.recomputePresentation(userInitiated: false)
                return
            }
            // A beat of empty panel, so the next banner reads as a new event.
            try? await Task.sleep(for: .milliseconds(280))
            guard self.celebrationToken == token else { return }
            self.show(self.milestoneQueue.removeFirst())
        }
    }

    private func applyDetail(_ snapshot: ThreadDetailSnapshot) async {
        guard !isDemoRunning else { return }
        guard snapshot.thread.id == focusedThreadId else { return }
        threadDetail = snapshot.thread
        let activities = snapshot.thread.activities
        pendingApprovals = derivePendingApprovals(from: activities)
            .filter { !answeredRequestIds.contains($0.requestId) }
        pendingUserInputs = derivePendingUserInputs(from: activities)
            .filter { !answeredRequestIds.contains($0.requestId) }
        let previousPlan = plan
        plan = deriveActivePlanState(
            from: activities,
            latestTurnId: snapshot.thread.latestTurn?.turnId
        )
        noteFinishedTasks(from: previousPlan, to: plan)
        contextWindow = deriveLatestContextWindowSnapshot(from: activities)
        recentActivity = deriveRecentActivity(
            from: activities,
            limit: settings.values.activityRows,
            relativeTo: workspaceRoot(for: snapshot.thread)
        )
        recomputePresentation(userInitiated: false)
    }

    /// Root that changed files are reported relative to. A thread on a worktree
    /// writes there, not into the project checkout.
    private func workspaceRoot(for thread: ThreadDetail) -> String? {
        thread.worktreePath?.nilIfEmpty
            ?? projects.first { $0.id == thread.projectId }?.workspaceRoot?.nilIfEmpty
    }

    private func recomputePresentation(forceAttention: Bool = false, userInitiated: Bool = false) {
        updatePresentation(forceAttention: forceAttention, userInitiated: userInitiated)
        syncClock()
    }

    /// Ticks the elapsed clocks while something visible is still running. A
    /// hidden panel or an all-finished deck has nothing to count.
    private func syncClock() {
        let needsClock = presentation != .hidden
            && activeThreads.contains { thread in
                // A thread that has never taken a turn has no clock to run.
                guard let turn = thread.latestTurn else { return false }
                return turn.completedAt == nil
            }
        guard needsClock else {
            clockTimer?.invalidate()
            clockTimer = nil
            return
        }
        guard clockTimer == nil else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clock = Date()
            }
        }
    }

    private func updatePresentation(forceAttention: Bool, userInitiated: Bool) {
        // A celebration holds the panel open for its few seconds, even once every
        // thread has gone quiet. Hover is deliberately ignored here: the moment a
        // turn lands or a branch merges is exactly when nobody is hovering.
        if celebration != nil {
            presentation = .expanded
            transport?.setExpanded(true)
            return
        }

        let active = activeThreads
        let needsAttention = active.contains {
            $0.hasPendingApprovals || $0.hasPendingUserInput
        }

        let mayExpandForAttention = settings.values.expandOnAttention
        if mayExpandForAttention,
            forceAttention || (needsAttention && presentation != .expanded && !userInitiated)
        {
            presentation = .attention
            transport?.setExpanded(true)
            return
        }

        if isHovering {
            presentation = active.isEmpty && walkthrough == nil ? .pill : .expanded
            transport?.setExpanded(presentation == .expanded)
            return
        }

        // The quick start outranks an idle notch but not a waiting agent: it opens
        // the panel while a step is being read, and otherwise keeps the pill on
        // screen so the walkthrough is pointing at something.
        if let walkthrough {
            presentation = walkthrough.wantsPanel ? .expanded : .pill
            transport?.setExpanded(presentation == .expanded)
            return
        }

        if presentation == .attention, needsAttention {
            return
        }

        if active.isEmpty {
            presentation = .hidden
            transport?.setExpanded(false)
            return
        }

        if presentation == .expanded, userInitiated {
            return
        }

        presentation = .pill
        transport?.setExpanded(false)
    }

    func playAttentionSound() {
        guard settings.values.soundOnAttention else { return }
        if attentionSound == nil {
            attentionSound = NSSound(named: "Tink")
        }
        attentionSound?.stop()
        attentionSound?.play()
    }

    private func priority(_ phase: AgentAwarenessPhase) -> Int {
        switch phase {
        case .waitingForApproval: return 50
        case .waitingForInput: return 40
        case .failed: return 30
        case .running: return 20
        case .starting: return 10
        case .completed: return 5
        case .stale: return 0
        }
    }
}

/// Remembers which finished turns have been reviewed, so relaunching the notch
/// does not resurrect results the user already dealt with.
final class ReviewedCompletionStore {
    private let key = "reviewedCompletionKeys"
    private let limit = 400
    private let defaults: UserDefaults
    private var keys: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: key) ?? []
    }

    func contains(_ completionKey: String) -> Bool {
        keys.contains(completionKey)
    }

    func insert(_ completionKey: String) {
        guard !keys.contains(completionKey) else { return }
        keys.append(completionKey)
        if keys.count > limit {
            keys.removeFirst(keys.count - limit)
        }
        defaults.set(keys, forKey: key)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ISO8601Parsing {
    static func date(from string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }

    static func nowString() -> String {
        Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }
}
