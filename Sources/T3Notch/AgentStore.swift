import AppKit
import Foundation
import Observation
import os
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

    /// The settings that decide what the local aggregate is made of.
    private struct ConfiguredSources: Equatable {
        var watchT3: Bool
        var watchClaude: Bool
        var watchCodex: Bool
        var hookListener: Bool
        var hookPort: Int

        init(_ values: SettingsStore.Values) {
            watchT3 = values.watchT3
            watchClaude = values.watchClaude
            watchCodex = values.watchCodex
            hookListener = values.claudeHookListener
            hookPort = values.claudeHookPort
        }
    }

    private enum RemoteRestoreResult: Sendable {
        case register(
            EnvironmentProfile,
            EnvironmentDescriptor,
            ServerEndpoint,
            DPoPHTTPAuthorizer
        )
        case placeholder(EnvironmentProfile, EnvironmentConnectionState)
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
    var onboardingMessage: String?
    /// Per-source connection state and, when a source is down for a reason worth
    /// explaining (T3 auth), the message the settings row shows.
    var sourceStatuses: [AgentSource: ConnectionState] = [:]
    var sourceProblems: [AgentSource: String] = [:]
    /// Set when the hook listener could not take the configured port.
    var claudeHookProblem: String?
    /// Result of the last hook install or removal.
    var claudeHookMessage: String?
    var answeredRequestIds: Set<String> = []
    var environment: EnvironmentDescriptor?
    var machines: [EnvironmentSnapshot] = []
    var t3ConnectDetection: T3ConnectSessionDetection = .unavailable
    var t3ConnectEnvironments: [T3ConnectEnvironment] = []
    var t3ConnectSessionUpdateAvailable = false
    var remoteOperationMessage: String?
    var isRemoteOperationRunning = false
    var remoteVaultLocked = false

    private(set) var endpoint = ServerEndpoint()
    private let coordinator = MultiEnvironmentCoordinator()
    /// The local machine's transport: T3 plus whichever agent CLIs are watched.
    private var localSources: AggregatingTransport?
    private var hookServer: ClaudeHookServer?
    /// Which source configuration `localSources` was built for, so unrelated
    /// setting changes don't tear down running transports.
    private var configuredSources: ConfiguredSources?
    private let profileStore = EnvironmentProfileStore()
    private let remoteVault = RemoteCredentialVault()
    private let t3ConnectImporter = ElectronSafeStorageImporter()
    private var coordinatorTask: Task<Void, Never>?
    private var snapshotsByEnvironment: [EnvironmentID: EnvironmentSnapshot] = [:]
    /// Relay shells may stop returning a thread as soon as its turn finishes.
    /// Keep that last transition locally so remote results still get one review.
    private var retainedRemoteCompletions: [EnvironmentID: [String: ThreadShell]] = [:]
    private var knownProjectsByEnvironment: [EnvironmentID: [String: ProjectShell]] = [:]
    private var scopedThreads: [String: ScopedThreadID] = [:]
    private var scopedProjects: [String: ScopedProjectID] = [:]
    private var localEnvironmentID: EnvironmentID?
    private var dpopSigner: DPoPSigner?
    private var t3ConnectClient: T3ConnectClient?
    private var t3ConnectConfiguration: T3ConnectConfiguration?
    private var t3ConnectEnabledStates: [EnvironmentID: Bool] = [:]
    private var remoteRestoreInFlight = false
    /// Rebuilds suspend on discovery and token checks, so they are serialized:
    /// an overtaken rebuild would leave `configuredSources` describing a set of
    /// transports that was never built, and nothing would rebuild again.
    private var localRebuildInFlight = false
    /// Bumped on every local rebuild; a T3 attach that finishes after another
    /// rebuild started must throw its transport away instead of registering.
    private var t3AttachGeneration = 0
    private var localRebuildPending = false
    private var directFailureCounts: [EnvironmentID: Int] = [:]
    private var directProbeSuccesses: [EnvironmentID: Int] = [:]
    private var connectFallbacksInFlight: Set<EnvironmentID> = []
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
    private var reviewBaselines: Set<EnvironmentID> = []
    private var reviewRevision = 0

    init(settings: SettingsStore) {
        let usesForge = settings.values.askForgeForMerges
        self.settings = settings
        watcherUsesForge = usesForge
        mergeWatcher = MergeWatcher(forge: usesForge ? .gh : .disabled)
        observeCoordinator()
        Task { await refreshT3ConnectDetectionNow() }
    }

    var focusedThread: ThreadShell? {
        guard let focusedThreadId else { return activeThreads.first }
        return threads.first(where: { $0.id == focusedThreadId }) ?? activeThreads.first
    }

    var focusedScopedThread: ScopedThreadID? {
        focusedThreadId.flatMap { scopedThreads[$0] }
    }

    func environmentID(for thread: ThreadShell) -> EnvironmentID? {
        scopedThreads[thread.id]?.environmentID
    }

    func machineLabel(for thread: ThreadShell) -> String {
        guard let id = environmentID(for: thread) else { return "This Mac" }
        return snapshotsByEnvironment[id]?.descriptor?.label
            ?? snapshotsByEnvironment[id]?.profile.label
            ?? id.rawValue
    }

    var activeThreads: [ThreadShell] {
        _ = reviewRevision
        return threads.compactMap { thread -> (ThreadShell, AgentAwarenessPhase)? in
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
        _ = reviewRevision
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
        if let scoped = scopedThreads[thread.id] {
            retainedRemoteCompletions[scoped.environmentID]?[scoped.threadID] = nil
        }
        reviewRevision &+= 1
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

    /// The wording of the review button, which differs by where the thread came
    /// from: T3 Code has a UI to open, a local CLI session only has a terminal.
    func openLabel(for thread: ThreadShell) -> String {
        source(of: thread) == .t3 ? "Open in T3 Code" : "Show terminal"
    }

    func source(of thread: ThreadShell) -> AgentSource {
        guard let scoped = scopedThreads[thread.id] else { return .t3 }
        return AgentSource(threadId: scoped.threadID)
    }

    /// Shows the thread where its work actually lives, which is what "reviewed"
    /// means here.
    ///
    /// For T3 Code the desktop app is preferred when it is already running: it
    /// registers `t3code://` but only ever reveals its window on a second
    /// instance, so there is no deep link to a single thread. Bringing it forward
    /// beats opening a duplicate of the same thread in a browser tab. Locally
    /// watched CLI sessions have no UI at all, so the terminal hosting them is
    /// raised instead.
    func openThread(_ thread: ThreadShell) {
        guard source(of: thread) == .t3 else {
            if !TerminalApp.activate(forPid: thread.ownerPid) {
                TerminalApp.activateAnyTerminal()
            }
            markReviewed(thread)
            return
        }
        guard let scoped = scopedThreads[thread.id],
              let snapshot = snapshotsByEnvironment[scoped.environmentID]
        else {
            markReviewed(thread)
            return
        }
        if snapshot.activeAccessPath == .local,
           settings.values.openInDesktopApp,
           T3CodeApp.activate()
        {
            markReviewed(thread)
            return
        }
        let baseURL = snapshot.activeAccessPath == .t3Connect
            ? URL(string: "https://app.t3.codes/")!
            : snapshot.profile.directEndpoint?.baseURL ?? endpoint.baseURL
        if let environmentId = snapshot.descriptor?.environmentId,
           let url = URL(
               string: "/threads/\(environmentId)/\(scoped.threadID)",
               relativeTo: baseURL
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

    struct MachineThreadGroup: Identifiable {
        let environmentID: EnvironmentID
        let label: String
        let source: EnvironmentSource
        let projects: [(project: ProjectShell, threads: [ThreadShell])]
        var id: EnvironmentID { environmentID }
    }

    var activeThreadsByMachine: [MachineThreadGroup] {
        var machineOrder: [EnvironmentID] = []
        var byMachine: [EnvironmentID: [ThreadShell]] = [:]
        for thread in activeThreads {
            guard let environmentID = environmentID(for: thread) else { continue }
            if byMachine[environmentID] == nil { machineOrder.append(environmentID) }
            byMachine[environmentID, default: []].append(thread)
        }
        return machineOrder.compactMap { environmentID in
            guard let machineThreads = byMachine[environmentID] else { return nil }
            var projectOrder: [String] = []
            var byProject: [String: [ThreadShell]] = [:]
            for thread in machineThreads {
                if byProject[thread.projectId] == nil { projectOrder.append(thread.projectId) }
                byProject[thread.projectId, default: []].append(thread)
            }
            let groups = projectOrder.compactMap { projectID
                -> (project: ProjectShell, threads: [ThreadShell])? in
                guard let threads = byProject[projectID] else { return nil }
                let project = projects.first { $0.id == projectID }
                    ?? ProjectShell(id: projectID, title: "Project")
                return (project, threads)
            }
            let label = snapshotsByEnvironment[environmentID]?.descriptor?.label
                ?? snapshotsByEnvironment[environmentID]?.profile.label
                ?? environmentID.rawValue
            return MachineThreadGroup(
                environmentID: environmentID,
                label: label,
                source: snapshotsByEnvironment[environmentID]?.activeAccessPath ?? .local,
                projects: groups
            )
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
        guard let id = focusedScopedThread?.environmentID else {
            return environment?.label?.nilIfBlank
        }
        return snapshotsByEnvironment[id]?.descriptor?.label?.nilIfBlank
            ?? snapshotsByEnvironment[id]?.profile.label.nilIfBlank
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
        await rebuildLocalSources()
        startMergeWatch()
        await refreshT3ConnectDetectionNow()
        await restoreRemoteMachines()
    }

    /// Rebuilds the local machine's transport from the current source settings.
    /// Registering replaces the previous session, which stops the transport it
    /// was holding — without that, every reconnect stacked another poller.
    ///
    /// Only one rebuild runs at a time; a request arriving mid-flight is folded
    /// into one more pass afterwards, so the last settings always win.
    private func rebuildLocalSources() async {
        guard !localRebuildInFlight else {
            localRebuildPending = true
            return
        }
        localRebuildInFlight = true
        defer { localRebuildInFlight = false }
        repeat {
            localRebuildPending = false
            await performLocalRebuild()
        } while localRebuildPending
    }

    private func performLocalRebuild() async {
        let values = settings.values
        configuredSources = ConfiguredSources(values)
        if !values.watchT3 {
            sourceProblems[.t3] = nil
            sourceStatuses[.t3] = nil
        }

        // Claude/Codex need no auth and must never wait on T3: discovery plus
        // token minting can shell out to `npx` for over a minute, and an early
        // build of this method sat on exactly that while the notch showed
        // nothing. Register the local sources now; attach T3 when it answers.
        await registerLocalAggregate(t3: nil, values: values)

        guard values.watchT3 else { return }
        t3AttachGeneration &+= 1
        let generation = t3AttachGeneration
        Task { [weak self] in
            guard let self else { return }
            let localEndpoint = await ServerDiscovery.resolveEndpoint()
            guard self.t3AttachGeneration == generation else { return }
            self.endpoint = localEndpoint
            let t3 = await self.makeT3Source(endpoint: localEndpoint)
            guard let t3 else { return }
            guard self.t3AttachGeneration == generation,
                  self.configuredSources == ConfiguredSources(self.settings.values)
            else {
                t3.transport.stop()
                return
            }
            await self.registerLocalAggregate(t3: t3, values: self.settings.values)
        }
    }

    private func registerLocalAggregate(t3: T3Source?, values: SettingsStore.Values) async {

        let localDescriptor = t3?.descriptor
        environment = localDescriptor
        let localID = EnvironmentID(localDescriptor?.environmentId?.nilIfBlank ?? "local")
        // The id follows T3's environment, so watching T3 (or minting a token)
        // renames the local machine. Registering under the new key would leave
        // the old session polling and tailing forever beside the new one.
        if let previous = localEnvironmentID, previous != localID {
            coordinator.remove(previous)
        }
        localEnvironmentID = localID
        normalizeT3ConnectProfiles(localEnvironmentID: localID)

        let hookServer = await startHookServer()
        let aggregate = TransportFactory.makeAggregate(
            t3: t3?.transport,
            enableClaude: values.watchClaude,
            enableCodex: values.watchCodex,
            hookServer: hookServer
        )
        localSources = aggregate
        coordinator.register(
            profile: EnvironmentProfile(
                environmentID: localID,
                label: localDescriptor?.label?.nilIfBlank ?? "This Mac",
                directEndpoint: endpoint,
                source: .local
            ),
            descriptor: localDescriptor,
            transport: aggregate
        )
        connectionState = .connecting
        refreshSourceStatuses()
    }

    /// Called on quit. Stopping the hook listener answers every held permission
    /// prompt with "ask", so the terminal takes the question back instead of
    /// hanging until curl's timeout.
    func shutdown() {
        hookServer?.stop()
        hookServer = nil
        coordinator.stop()
    }

    private struct T3Source {
        let transport: PollingTransport
        let descriptor: EnvironmentDescriptor?
    }

    /// Builds the T3 child. A failure here records a source problem and returns
    /// nil; the other sources still run, so bad T3 auth no longer stops the app.
    private func makeT3Source(endpoint: ServerEndpoint) async -> T3Source? {
        var token = KeychainStore.loadToken()
        if token == nil {
            do {
                let minted = try await TokenMinting.mintToken()
                try KeychainStore.saveToken(minted)
                token = minted
            } catch {
                recordT3Failure(
                    "Could not mint a token automatically.\n\nRun:\n  npx -y t3@latest auth session issue --token-only\n\nand paste it here.\n\n\(error.localizedDescription)"
                )
                return nil
            }
        }
        guard let token else {
            recordT3Failure("No T3 Code token available.")
            return nil
        }
        do {
            _ = try await TokenMinting.verifyToken(token: token, endpoint: endpoint)
        } catch {
            recordT3Failure(
                "Saved token was rejected. Paste a fresh token from:\n  npx -y t3@latest auth session issue --token-only\n\n\(error.localizedDescription)"
            )
            return nil
        }

        sourceProblems[.t3] = nil
        onboardingMessage = nil
        let client = T3HTTPClient(endpoint: endpoint, token: token)
        return T3Source(
            transport: PollingTransport(client: client),
            descriptor: try? await client.fetchEnvironment()
        )
    }

    private func recordT3Failure(_ message: String) {
        sourceProblems[.t3] = message
        sourceStatuses[.t3] = .unauthorized
        onboardingMessage = message
    }

    /// Starts the hook listener the Claude transport answers approvals through.
    /// The port is fixed on purpose, so a collision is reported rather than
    /// worked around: the installed hook entries name that exact port.
    private func startHookServer() async -> ClaudeHookServer? {
        hookServer?.stop()
        hookServer = nil
        claudeHookProblem = nil
        let values = settings.values
        guard values.watchClaude, values.claudeHookListener else { return nil }
        let server = ClaudeHookServer(port: UInt16(clamping: values.claudeHookPort))
        do {
            // The listener we just cancelled hands the port back asynchronously;
            // `start()` retries the bind rather than reporting a false collision.
            try await server.start()
            hookServer = server
            return server
        } catch {
            claudeHookProblem =
                "Port \(values.claudeHookPort) is in use — change the port and reinstall hooks."
            return nil
        }
    }

    private func restoreRemoteMachines() async {
        // Remote machines ride T3 Connect credentials from the vault, another
        // Keychain item. All of T3 stays behind the one toggle.
        guard settings.values.watchT3 else { return }
        guard !remoteRestoreInFlight else { return }
        remoteRestoreInFlight = true
        defer { remoteRestoreInFlight = false }

        let profiles = profileStore.load()
        t3ConnectEnabledStates = Dictionary(
            profiles.map { ($0.environmentID, $0.enabled) },
            uniquingKeysWith: { _, latest in latest }
        )
        for profile in profiles where !profile.enabled {
            installPlaceholder(profile: profile, state: .offline("Disabled"))
        }
        let document: RemoteCredentialDocument
        do {
            document = try remoteVault.loadWithoutPrompt()
            remoteVaultLocked = false
        } catch RemoteCredentialVaultError.locked {
            remoteVaultLocked = true
            for profile in profiles where profile.enabled {
                installPlaceholder(profile: profile, state: .credentialLocked)
            }
            return
        } catch {
            remoteOperationMessage = error.localizedDescription
            return
        }
        do {
            let signer = try DPoPSigner(privateKeyRawRepresentation: document.dpopPrivateKey)
            dpopSigner = signer
            if document.dpopPrivateKey == nil {
                let raw = await signer.privateKeyRawRepresentation
                try remoteVault.update { $0.dpopPrivateKey = raw }
            }
        } catch {
            remoteOperationMessage = error.localizedDescription
            return
        }
        guard let signer = dpopSigner else { return }
        let configurationAvailable = t3ConnectConfiguration != nil
        let results = await withTaskGroup(
            of: RemoteRestoreResult?.self,
            returning: [RemoteRestoreResult].self
        ) { group in
            for profile in profiles where profile.enabled {
                group.addTask {
                    if profile.source == .t3Connect {
                        guard configurationAvailable else {
                            return .placeholder(
                                profile,
                                .incompatible("T3 Connect is not configured in this build.")
                            )
                        }
                        guard document.importedT3Connect != nil else {
                            return .placeholder(profile, .unauthorized)
                        }
                        guard let endpoint = profile.directEndpoint,
                              let credential = document.connectEnvironmentCredentials[
                                profile.environmentID.rawValue
                              ],
                              !credential.needsRefresh
                        else {
                            return .placeholder(profile, .connecting)
                        }
                        let authorizer = DPoPHTTPAuthorizer(
                            accessToken: credential.accessToken,
                            signer: signer
                        )
                        let client = T3HTTPClient(endpoint: endpoint, authorizer: authorizer)
                        guard let descriptor = try? await client.fetchEnvironment(),
                              descriptor.environmentId == profile.environmentID.rawValue,
                              (try? await client.verifySession()) != nil
                        else {
                            return .placeholder(profile, .connecting)
                        }
                        return .register(profile, descriptor, endpoint, authorizer)
                    }

                    guard profile.source == .direct else { return nil }
                    guard let endpoint = profile.directEndpoint,
                          let credential = document.environmentCredentials[
                            profile.environmentID.rawValue
                          ]
                    else {
                        return .placeholder(profile, .needsPairing)
                    }
                    guard !credential.needsRefresh else {
                        return .placeholder(profile, .needsPairing)
                    }
                    let authorizer = DPoPHTTPAuthorizer(
                        accessToken: credential.accessToken,
                        signer: signer
                    )
                    let descriptor = try? await T3HTTPClient(
                        endpoint: endpoint,
                        authorizer: authorizer
                    ).fetchEnvironment()
                    guard let descriptor,
                          descriptor.environmentId == profile.environmentID.rawValue
                    else {
                        return .placeholder(
                            profile,
                            .incompatible("The endpoint reports a different environment.")
                        )
                    }
                    return .register(profile, descriptor, endpoint, authorizer)
                }
            }

            var resolved: [RemoteRestoreResult] = []
            for await result in group {
                if let result { resolved.append(result) }
            }
            return resolved
        }

        for result in results {
            switch result {
            case let .register(profile, descriptor, endpoint, authorizer):
                coordinator.register(
                    profile: profile,
                    descriptor: descriptor,
                    endpoint: endpoint,
                    authorizer: authorizer
                )
            case let .placeholder(profile, state):
                installPlaceholder(profile: profile, state: state)
            }
        }
        configureT3Connect()
        for profile in profiles where profile.source == .direct && profile.enabled {
            guard snapshotsByEnvironment[profile.environmentID]?.connectionState
                == .needsPairing
            else {
                continue
            }
            Task { await attemptConnectFallback(profile.environmentID) }
        }
    }

    private func installPlaceholder(
        profile: EnvironmentProfile,
        state: EnvironmentConnectionState
    ) {
        coordinator.suspend(profile.environmentID)
        let snapshot = EnvironmentSnapshot(
            profile: profile,
            descriptor: nil,
            connectionState: state,
            activeAccessPath: profile.source,
            shell: nil
        )
        snapshotsByEnvironment[profile.environmentID] = snapshot
        rebuildFlattenedWorld()
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

        // Only a change to what the local machine watches justifies dropping the
        // running transports; every other setting is read where it is used.
        if configuredSources != ConfiguredSources(settings.values) {
            let t3TurnedOn = configuredSources?.watchT3 == false && settings.values.watchT3
            Task {
                await rebuildLocalSources()
                if t3TurnedOn {
                    await refreshT3ConnectDetectionNow()
                    await restoreRemoteMachines()
                }
            }
        }
        recomputePresentation(userInitiated: true)
    }

    /// Sources the user asked for. Ones switched off are not "down".
    var enabledSources: [AgentSource] {
        var sources: [AgentSource] = []
        if settings.values.watchT3 { sources.append(.t3) }
        if settings.values.watchClaude { sources.append(.claude) }
        if settings.values.watchCodex { sources.append(.codex) }
        return sources
    }

    /// The token panel only takes over the notch when there is nothing else to
    /// show: every source the user enabled is down, and no threads are known.
    /// A broken T3 token alone is a settings row, not a blocking screen.
    var needsOnboarding: Bool {
        guard !isDemoRunning, threads.isEmpty else { return false }
        let sources = enabledSources
        guard !sources.isEmpty else { return false }
        return sources.allSatisfy { source in
            switch sourceStatuses[source] ?? .connecting {
            case .disconnected, .unauthorized: true
            case .connected, .connecting: false
            }
        }
    }

    /// Live sessions the local machine's aggregate is showing for one source,
    /// for the settings status lines. Remote machines run T3 too, so they are
    /// left out: this counts what the local sources found.
    func localSessionCount(for source: AgentSource) -> Int {
        threads.filter { thread in
            guard let scoped = scopedThreads[thread.id],
                  scoped.environmentID == localEnvironmentID
            else { return false }
            return AgentSource(threadId: scoped.threadID) == source
        }
        .count
    }

    /// The token panel's way out: T3 Code is one source of three, and refusing
    /// to paste a token should not leave the panel stuck.
    func stopWatchingT3() {
        settings.set(\.watchT3, to: false)
    }

    // MARK: - Claude Code hooks

    func claudeHookStatus() -> ClaudeHookStatus {
        ClaudeHookInstaller().status()
    }

    /// Hooks hot-reload into running Claude Code sessions, so both of these take
    /// effect without restarting anything.
    func installClaudeHooks() {
        do {
            try ClaudeHookInstaller().install(
                port: UInt16(clamping: settings.values.claudeHookPort)
            )
            claudeHookMessage = nil
            // A hook that reaches nothing is worse than none, so a listener that
            // never started (source off at launch, port taken) is started now.
            if hookServer == nil {
                Task { await rebuildLocalSources() }
            }
        } catch {
            claudeHookMessage = "Could not update ~/.claude/settings.json: \(error)"
        }
    }

    func removeClaudeHooks() {
        do {
            try ClaudeHookInstaller().uninstall()
            claudeHookMessage = nil
        } catch {
            claudeHookMessage = "Could not update ~/.claude/settings.json: \(error)"
        }
    }

    /// Reads each child's state back out of the aggregate. Called whenever the
    /// local environment reports in, which is the only moment the combined state
    /// can have moved.
    func refreshSourceStatuses() {
        guard let localSources else { return }
        for source in AgentSource.allCases {
            guard enabledSources.contains(source) else {
                sourceStatuses[source] = nil
                continue
            }
            // A source that failed to build has no child to ask; its recorded
            // problem already says why it is down.
            guard sourceProblems[source] == nil else { continue }
            sourceStatuses[source] = localSources
                .connectionState(forNamespace: TransportFactory.namespace(for: source))
        }
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
                onboardingMessage = nil
                sourceProblems[.t3] = nil
                // Only the local machine's sources depend on the token; the
                // remote machines already restored are left alone.
                await rebuildLocalSources()
            } catch {
                onboardingMessage = "Token rejected: \(error.localizedDescription)"
            }
        }
    }

    var remoteMachines: [EnvironmentSnapshot] {
        machines.filter { $0.profile.source != .local }
    }

    var canImportT3Connect: Bool {
        t3ConnectConfiguration != nil
            && {
                if case .signedIn = t3ConnectDetection { return true }
                return false
            }()
    }

    var canRepairT3ConnectPermissions: Bool {
        if case .unsafePermissions = t3ConnectDetection { return true }
        return false
    }

    var t3ConnectImportHasProblem: Bool {
        switch t3ConnectDetection {
        case .unsafePermissions, .incompatible:
            true
        default:
            false
        }
    }

    var hasImportedT3Connect: Bool { t3ConnectClient != nil }

    var showsT3Connect: Bool {
        guard t3ConnectConfiguration != nil else { return hasImportedT3Connect }
        return switch t3ConnectDetection {
        case .signedIn, .unsafePermissions, .incompatible:
            true
        case .unavailable, .signedOut:
            hasImportedT3Connect
        }
    }

    var t3ConnectImportDetail: String {
        switch t3ConnectDetection {
        case .unsafePermissions:
            "T3 Code’s session file is writable by other local users. "
                + "Run chmod 600 ~/.t3/userdata/clerk-tokens.json, then refresh."
        case let .incompatible(reason):
            reason
        case .signedIn:
            "Use the account already signed in to T3 Code. Importing asks for Keychain access once."
        case .signedOut:
            "Sign in to T3 Code before importing its T3 Connect session."
        case .unavailable:
            "No compatible T3 Code session was found."
        }
    }

    func copyT3ConnectPermissionFix() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "chmod 600 ~/.t3/userdata/clerk-tokens.json",
            forType: .string
        )
    }

    func refreshT3ConnectDetection() {
        Task { await refreshT3ConnectDetectionNow() }
    }

    private func refreshT3ConnectDetectionNow() async {
        // Detection imports T3 Code's Electron credentials from the Keychain,
        // which prompts. With the T3 source off nothing may touch the Keychain.
        guard settings.values.watchT3 else {
            t3ConnectConfiguration = nil
            t3ConnectDetection = .unavailable
            return
        }
        let importer = t3ConnectImporter
        let vault = remoteVault
        let result = await Task.detached(priority: .utility) {
            let configuration = T3ConnectConfiguration.load()
            guard configuration != nil else {
                return (
                    configuration,
                    T3ConnectSessionDetection.unavailable,
                    Optional<ImportedT3ConnectCredential>.none
                )
            }
            let detection = importer.detect()
            let imported = try? vault.document().importedT3Connect
            return (configuration, detection, imported)
        }.value

        t3ConnectConfiguration = result.0
        guard result.0 != nil else {
            t3ConnectDetection = .unavailable
            return
        }
        t3ConnectDetection = result.1
        switch t3ConnectDetection {
        case let .signedIn(ciphertextFingerprint):
            if let imported = result.2 {
                t3ConnectSessionUpdateAvailable =
                    imported.ciphertextFingerprint != ciphertextFingerprint
            } else {
                t3ConnectSessionUpdateAvailable = false
            }
        case .signedOut, .unavailable:
            t3ConnectSessionUpdateAvailable = false
            if result.2 != nil {
                purgeImportedT3ConnectAfterLogout()
            }
        case .unsafePermissions, .incompatible:
            t3ConnectSessionUpdateAvailable = false
        }
    }

    func pairRemoteMachine(
        pairingURL: String?,
        host: String?,
        code: String?,
        allowsInsecureHTTP: Bool
    ) async throws {
        isRemoteOperationRunning = true
        remoteOperationMessage = nil
        defer { isRemoteOperationRunning = false }
        let target: RemotePairingTarget
        if let pairingURL = pairingURL?.nilIfBlank {
            target = try RemotePairingTarget(pairingURL: pairingURL)
        } else {
            target = try RemotePairingTarget(
                host: host ?? "",
                pairingCode: code ?? ""
            )
        }
        let signer = try await ensureDPoPSigner(allowsPrompt: false)
        let result = try await RemotePairingClient(signer: signer).pair(
            target: target,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        try profileStore.upsert(result.profile)
        t3ConnectEnabledStates[result.profile.environmentID] = result.profile.enabled
        try remoteVault.update {
            $0.environmentCredentials[result.profile.environmentID.rawValue] = result.credential
        }
        snapshotsByEnvironment.removeValue(forKey: result.profile.environmentID)
        coordinator.register(
            profile: result.profile,
            descriptor: result.descriptor,
            endpoint: target.endpoint,
            authorizer: DPoPHTTPAuthorizer(
                accessToken: result.credential.accessToken,
                signer: signer
            )
        )
    }

    func setMachineEnabled(_ environmentID: EnvironmentID, enabled: Bool) {
        guard var profile = profileStore.load()
            .first(where: { $0.environmentID == environmentID })
        else {
            return
        }
        profile.enabled = enabled
        do {
            try profileStore.upsert(profile)
            t3ConnectEnabledStates[environmentID] = enabled
            if enabled {
                Task { await restoreRemoteMachines() }
            } else {
                retainedRemoteCompletions.removeValue(forKey: environmentID)
                knownProjectsByEnvironment.removeValue(forKey: environmentID)
                installPlaceholder(profile: profile, state: .offline("Disabled"))
            }
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    func reconnectMachine(_ environmentID: EnvironmentID) {
        coordinator.reconnect(environmentID)
    }

    func removeMachine(_ environmentID: EnvironmentID) {
        do {
            let removedProfile = profileStore.load().first {
                $0.environmentID == environmentID
            }
            if var removedProfile, removedProfile.source == .t3Connect {
                removedProfile.enabled = false
                try profileStore.upsert(removedProfile)
                t3ConnectEnabledStates[environmentID] = false
                try remoteVault.removeEnvironment(environmentID)
                retainedRemoteCompletions.removeValue(forKey: environmentID)
                knownProjectsByEnvironment.removeValue(forKey: environmentID)
                installPlaceholder(
                    profile: removedProfile,
                    state: .offline("Disabled")
                )
                return
            }
            try profileStore.remove(environmentID)
            t3ConnectEnabledStates.removeValue(forKey: environmentID)
            try remoteVault.removeEnvironment(environmentID)
            coordinator.remove(environmentID)
            snapshotsByEnvironment.removeValue(forKey: environmentID)
            rebuildFlattenedWorld()
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    func unlockRemoteCredentials() async {
        guard !isRemoteOperationRunning else { return }
        isRemoteOperationRunning = true
        defer { isRemoteOperationRunning = false }
        do {
            _ = try remoteVault.unlock()
            remoteVaultLocked = false
            await restoreRemoteMachines()
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    func importT3Connect() async {
        isRemoteOperationRunning = true
        remoteOperationMessage = nil
        defer { isRemoteOperationRunning = false }
        do {
            let imported = try t3ConnectImporter.importSession()
            let signer = try await ensureDPoPSigner(allowsPrompt: true)
            guard let configuration = t3ConnectConfiguration else {
                throw T3ConnectError.invalidConfiguration
            }
            let client = T3ConnectClient(
                configuration: configuration,
                vault: remoteVault,
                signer: signer
            )
            try await client.importSession(imported)
            t3ConnectClient = client
            try await refreshT3ConnectEnvironments(connectEnabled: true)
            t3ConnectSessionUpdateAvailable = false
        } catch T3ConnectError.unauthorized {
            purgeImportedT3ConnectAfterLogout()
            remoteOperationMessage = T3ConnectError.unauthorized.localizedDescription
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    func refreshT3ConnectEnvironments(connectEnabled: Bool = false) async throws {
        guard let client = t3ConnectClient else {
            throw T3ConnectError.notImported
        }
        let inventory = try await client.listEnvironments()
        let legacyExclusionKey =
            "gg.t3tools.t3notch.excludedT3ConnectEnvironments.v1"
        let legacyExcludedIDs = Set(
            UserDefaults.standard.stringArray(forKey: legacyExclusionKey) ?? []
        )
        for environment in inventory
        where legacyExcludedIDs.contains(environment.environmentID.rawValue) {
            if !profileStore.load().contains(where: {
                $0.environmentID == environment.environmentID
            }) {
                try profileStore.upsert(
                    EnvironmentProfile(
                        environmentID: environment.environmentID,
                        label: environment.label,
                        directEndpoint: environment.endpoint,
                        source: .t3Connect,
                        enabled: false
                    )
                )
                t3ConnectEnabledStates[environment.environmentID] = false
            }
        }
        UserDefaults.standard.removeObject(forKey: legacyExclusionKey)
        let environments = inventory.filter { environment in
            environment.environmentID != localEnvironmentID
        }

        // Inventory discovery is read-only. A newly imported T3 Connect session
        // must never begin monitoring every linked machine automatically; save
        // each new remote environment as disabled until its toggle is enabled.
        var profiles = profileStore.load()
        for environment in environments where !profiles.contains(where: {
            $0.environmentID == environment.environmentID
        }) {
            let profile = EnvironmentProfile(
                environmentID: environment.environmentID,
                label: environment.label,
                directEndpoint: environment.endpoint,
                source: .t3Connect,
                enabled: false
            )
            try profileStore.upsert(profile)
            profiles.append(profile)
            t3ConnectEnabledStates[environment.environmentID] = false
        }

        t3ConnectEnvironments = environments
        if connectEnabled {
            for environment in environments {
                let existing = profiles.first {
                    $0.environmentID == environment.environmentID
                }
                if existing?.source == .direct || existing?.enabled == false {
                    continue
                }
                if let snapshot = snapshotsByEnvironment[environment.environmentID],
                   snapshot.activeAccessPath == .t3Connect,
                   snapshot.connectionState == .connected
                {
                    continue
                }
                do {
                    try await connectT3ConnectEnvironment(environment)
                    t3ConnectEnabledStates[environment.environmentID] = true
                } catch T3ConnectError.unauthorized {
                    throw T3ConnectError.unauthorized
                } catch {
                    remoteOperationMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshT3Connect() async {
        isRemoteOperationRunning = true
        remoteOperationMessage = nil
        defer { isRemoteOperationRunning = false }
        do {
            try await refreshT3ConnectEnvironments(connectEnabled: true)
        } catch T3ConnectError.unauthorized {
            purgeImportedT3ConnectAfterLogout()
            remoteOperationMessage = T3ConnectError.unauthorized.localizedDescription
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    func connectT3ConnectEnvironment(
        _ environment: T3ConnectEnvironment,
        replacingDirectPath: Bool = false
    ) async throws {
        guard let client = t3ConnectClient else { throw T3ConnectError.notImported }
        if !replacingDirectPath, profileStore.load().contains(where: {
            $0.environmentID == environment.environmentID && $0.source == .direct
        }) {
            return
        }
        let result = try await client.connect(environment)
        if !replacingDirectPath {
            try profileStore.upsert(result.profile)
            t3ConnectEnabledStates[result.profile.environmentID] = result.profile.enabled
        }
        guard let endpoint = result.profile.directEndpoint else {
            throw T3ConnectError.invalidResponse
        }
        coordinator.register(
            profile: result.profile,
            descriptor: result.descriptor,
            endpoint: endpoint,
            authorizer: DPoPHTTPAuthorizer(
                accessToken: result.credential.accessToken,
                signer: try await ensureDPoPSigner(allowsPrompt: false)
            )
        )
    }

    func forgetT3Connect() async {
        guard !isRemoteOperationRunning else { return }
        isRemoteOperationRunning = true
        defer { isRemoteOperationRunning = false }
        do {
            try await t3ConnectClient?.forget()
            t3ConnectClient = nil
            t3ConnectEnvironments = []
            for profile in profileStore.load() where profile.source == .t3Connect {
                try profileStore.remove(profile.environmentID)
                t3ConnectEnabledStates.removeValue(forKey: profile.environmentID)
                coordinator.remove(profile.environmentID)
                snapshotsByEnvironment.removeValue(forKey: profile.environmentID)
            }
            rebuildFlattenedWorld()
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    private func configureT3Connect() {
        refreshT3ConnectDetection()
        guard let configuration = t3ConnectConfiguration,
              let signer = dpopSigner,
              let document = try? remoteVault.document(),
              document.importedT3Connect != nil
        else {
            return
        }
        t3ConnectClient = T3ConnectClient(
            configuration: configuration,
            vault: remoteVault,
            signer: signer
        )
        Task { [weak self] in
            try? await self?.refreshT3ConnectEnvironments(connectEnabled: true)
        }
    }

    private func purgeImportedT3ConnectAfterLogout() {
        try? remoteVault.forgetT3Connect()
        t3ConnectClient = nil
        t3ConnectEnvironments = []
        t3ConnectSessionUpdateAvailable = false
        let profiles = profileStore.load()
        for profile in profiles where profile.source == .t3Connect {
            try? profileStore.remove(profile.environmentID)
            coordinator.remove(profile.environmentID)
            snapshotsByEnvironment.removeValue(forKey: profile.environmentID)
        }
        let connectSnapshots = snapshotsByEnvironment.values.filter {
            $0.activeAccessPath == .t3Connect
        }
        for snapshot in connectSnapshots {
            guard let direct = profiles.first(where: {
                $0.environmentID == snapshot.profile.environmentID && $0.source == .direct
            }) else {
                continue
            }
            installPlaceholder(profile: direct, state: .offline("T3 Connect signed out"))
        }
        rebuildFlattenedWorld()
        Task { await restoreRemoteMachines() }
    }

    private func updateAccessPathHealth(_ snapshot: EnvironmentSnapshot) async {
        let environmentID = snapshot.profile.environmentID
        guard snapshot.profile.source == .direct else {
            if snapshot.profile.source == .t3Connect {
                directFailureCounts[environmentID] = 0
            }
            return
        }
        switch snapshot.connectionState {
        case .connected, .connecting:
            directFailureCounts[environmentID] = 0
        case .offline:
            directFailureCounts[environmentID, default: 0] += 1
            if directFailureCounts[environmentID, default: 0] >= 2 {
                await attemptConnectFallback(environmentID)
            }
        case .needsPairing, .unauthorized:
            await attemptConnectFallback(environmentID)
        case .credentialLocked, .incompatible:
            break
        }
    }

    private func attemptConnectFallback(_ environmentID: EnvironmentID) async {
        await recoverT3ConnectEnvironment(
            environmentID,
            replacingDirectPath: true,
            resetPathCounters: true
        )
    }

    private func repairT3ConnectEnvironment(_ environmentID: EnvironmentID) async {
        let hasDirect = profileStore.load().contains {
            $0.environmentID == environmentID && $0.source == .direct
        }
        await recoverT3ConnectEnvironment(
            environmentID,
            replacingDirectPath: hasDirect,
            resetPathCounters: false
        )
    }

    private func recoverT3ConnectEnvironment(
        _ environmentID: EnvironmentID,
        replacingDirectPath: Bool,
        resetPathCounters: Bool
    ) async {
        guard t3ConnectClient != nil,
              !connectFallbacksInFlight.contains(environmentID)
        else {
            return
        }
        connectFallbacksInFlight.insert(environmentID)
        defer { connectFallbacksInFlight.remove(environmentID) }
        do {
            if !t3ConnectEnvironments.contains(where: { $0.environmentID == environmentID }) {
                try await refreshT3ConnectEnvironments(connectEnabled: false)
            }
            guard let environment = t3ConnectEnvironments.first(where: {
                $0.environmentID == environmentID
            }) else {
                return
            }
            try await connectT3ConnectEnvironment(
                environment,
                replacingDirectPath: replacingDirectPath
            )
            if resetPathCounters {
                directFailureCounts[environmentID] = 0
                directProbeSuccesses[environmentID] = 0
            }
        } catch T3ConnectError.unauthorized {
            purgeImportedT3ConnectAfterLogout()
        } catch {
            // The current path remains visible as offline. A future poll or
            // maintenance refresh retries without blocking local monitoring.
        }
    }

    private func probePreferredDirectPaths() async {
        guard let signer = dpopSigner,
              let document = try? remoteVault.document()
        else {
            return
        }
        let profiles = profileStore.load()
        for snapshot in snapshotsByEnvironment.values
            where snapshot.activeAccessPath == .t3Connect
        {
            let environmentID = snapshot.profile.environmentID
            guard let direct = profiles.first(where: {
                $0.environmentID == environmentID
                    && $0.source == .direct
                    && $0.enabled
            }),
                let endpoint = direct.directEndpoint,
                let credential = document.environmentCredentials[environmentID.rawValue],
                !credential.needsRefresh
            else {
                directProbeSuccesses[environmentID] = 0
                continue
            }
            let client = T3HTTPClient(
                endpoint: endpoint,
                authorizer: DPoPHTTPAuthorizer(
                    accessToken: credential.accessToken,
                    signer: signer
                )
            )
            do {
                try await client.verifySession()
                let descriptor = try await client.fetchEnvironment()
                guard descriptor.environmentId == environmentID.rawValue else {
                    directProbeSuccesses[environmentID] = 0
                    continue
                }
                directProbeSuccesses[environmentID, default: 0] += 1
                if directProbeSuccesses[environmentID, default: 0] >= 2 {
                    coordinator.register(
                        profile: direct,
                        descriptor: descriptor,
                        endpoint: endpoint,
                        authorizer: DPoPHTTPAuthorizer(
                            accessToken: credential.accessToken,
                            signer: signer
                        )
                    )
                    directProbeSuccesses[environmentID] = 0
                }
            } catch {
                directProbeSuccesses[environmentID] = 0
            }
        }
    }

    /// Called on wake, network restoration, and the menu-bar reconnect command.
    /// Local polling is independent, so a Connect outage cannot suppress this.
    func handleConnectivityAvailable() {
        if connectionState == .unauthorized || needsOnboarding {
            bootstrap()
        } else {
            handleConnectivityRestored()
        }
    }

    func handleConnectivityRestored() {
        coordinator.reconnect()
        Task { await performRemoteMaintenance() }
    }

    /// Refreshes Connect inventory and probes any direct path currently using a
    /// relay fallback. AppDelegate runs this every 60 seconds.
    func performRemoteMaintenance() async {
        await refreshT3ConnectDetectionNow()
        if t3ConnectClient != nil {
            do {
                try await refreshT3ConnectEnvironments(connectEnabled: true)
            } catch T3ConnectError.unauthorized {
                purgeImportedT3ConnectAfterLogout()
            } catch {
                // Periodic maintenance is deliberately quiet. The explicit
                // Refresh action surfaces its error in Settings.
            }
        }
        await probePreferredDirectPaths()
    }

    func isT3ConnectEnvironmentEnabled(_ environmentID: EnvironmentID) -> Bool {
        t3ConnectEnabledStates[environmentID] ?? false
    }

    func setT3ConnectEnvironmentEnabled(
        _ environment: T3ConnectEnvironment,
        enabled: Bool
    ) {
        if let existing = profileStore.load().first(where: {
            $0.environmentID == environment.environmentID
        }) {
            setMachineEnabled(existing.environmentID, enabled: enabled)
            return
        }
        let profile = EnvironmentProfile(
            environmentID: environment.environmentID,
            label: environment.label,
            directEndpoint: environment.endpoint,
            source: .t3Connect,
            enabled: enabled
        )
        do {
            try profileStore.upsert(profile)
            t3ConnectEnabledStates[environment.environmentID] = enabled
            if enabled {
                Task {
                    do {
                        try await connectT3ConnectEnvironment(environment)
                    } catch {
                        remoteOperationMessage = error.localizedDescription
                        installPlaceholder(profile: profile, state: .offline(nil))
                    }
                }
            } else {
                installPlaceholder(profile: profile, state: .offline("Disabled"))
            }
        } catch {
            remoteOperationMessage = error.localizedDescription
        }
    }

    /// Local loopback always wins over a relay copy of this Mac. Remote relay
    /// profiles keep their own persisted enable state.
    private func normalizeT3ConnectProfiles(localEnvironmentID: EnvironmentID) {
        for profile in profileStore.load() where profile.source == .t3Connect {
            guard profile.environmentID == localEnvironmentID else { continue }
            try? profileStore.remove(profile.environmentID)
            t3ConnectEnabledStates.removeValue(forKey: profile.environmentID)
            try? remoteVault.removeEnvironment(profile.environmentID)
            coordinator.remove(profile.environmentID)
            snapshotsByEnvironment.removeValue(forKey: profile.environmentID)
        }
    }

    private func ensureDPoPSigner(allowsPrompt: Bool) async throws -> DPoPSigner {
        if let dpopSigner { return dpopSigner }
        let document = allowsPrompt ? try remoteVault.unlock() : try remoteVault.loadWithoutPrompt()
        let signer = try DPoPSigner(privateKeyRawRepresentation: document.dpopPrivateKey)
        dpopSigner = signer
        if document.dpopPrivateKey == nil {
            let raw = await signer.privateKeyRawRepresentation
            try remoteVault.update { $0.dpopPrivateKey = raw }
        }
        return signer
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
        coordinator.setExpanded(true)
        syncClock()
    }

    func collapseIfIdle() {
        if presentation == .attention { return }
        if isHovering { return }
        recomputePresentation(userInitiated: false)
    }

    func respondToApproval(_ approval: PendingApproval, decision: ApprovalDecision) {
        guard let scoped = focusedScopedThread else { return }
        if isDemoRunning {
            pendingApprovals.removeAll { $0.requestId == approval.requestId }
            finishDemoPrompt()
            return
        }
        answeredRequestIds.insert(scopedRequestKey(approval.requestId, thread: scoped))
        pendingApprovals.removeAll { $0.requestId == approval.requestId }
        let command = DispatchCommand.approvalRespond(
            commandId: UUID().uuidString,
            threadId: scoped.threadID,
            requestId: approval.requestId,
            decision: decision,
            createdAt: ISO8601Parsing.nowString()
        )
        Task {
            try? await coordinator.dispatch(command, to: scoped.environmentID)
        }
    }

    func respondToUserInput(_ input: PendingUserInput, answers: [String: JSONValue]) {
        guard let scoped = focusedScopedThread else { return }
        if isDemoRunning {
            pendingUserInputs.removeAll { $0.requestId == input.requestId }
            finishDemoPrompt()
            return
        }
        answeredRequestIds.insert(scopedRequestKey(input.requestId, thread: scoped))
        pendingUserInputs.removeAll { $0.requestId == input.requestId }
        let command = DispatchCommand.userInputRespond(
            commandId: UUID().uuidString,
            threadId: scoped.threadID,
            requestId: input.requestId,
            answers: answers,
            createdAt: ISO8601Parsing.nowString()
        )
        Task {
            try? await coordinator.dispatch(command, to: scoped.environmentID)
        }
    }

    func interruptTurn() {
        guard let thread = focusedThread, let scoped = focusedScopedThread else { return }
        let command = DispatchCommand.turnInterrupt(
            commandId: UUID().uuidString,
            threadId: scoped.threadID,
            turnId: thread.latestTurn?.turnId,
            createdAt: ISO8601Parsing.nowString()
        )
        Task {
            try? await coordinator.dispatch(command, to: scoped.environmentID)
        }
    }

    // MARK: - Private

    private func observeCoordinator() {
        coordinatorTask?.cancel()
        coordinatorTask = Task { [weak self] in
            guard let self else { return }
            for await event in coordinator.events {
                await self.applyEnvironmentEvent(event)
                Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
                    .debug("store: applied event")
            }
            Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
                .debug("store: coordinator event loop ENDED")
        }
    }

    private func applyEnvironmentEvent(_ event: EnvironmentEvent) async {
        switch event {
        case let .snapshot(snapshot):
            Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
                .debug("store: snapshot \(snapshot.profile.environmentID.rawValue, privacy: .public) source=\(String(describing: snapshot.profile.source), privacy: .public) shellThreads=\(snapshot.shell?.threads.count ?? -1) state=\(String(describing: snapshot.connectionState), privacy: .public)")
            retainRemoteCompletionTransition(
                from: snapshotsByEnvironment[snapshot.profile.environmentID],
                to: snapshot
            )
            snapshotsByEnvironment[snapshot.profile.environmentID] = snapshot
            if snapshot.profile.source == .local {
                connectionState = legacyConnectionState(snapshot.connectionState)
                refreshSourceStatuses()
                if sourceStatuses[.t3] == .unauthorized, sourceProblems[.t3] == nil {
                    let message = "Session expired. Paste a new bearer token."
                    sourceProblems[.t3] = message
                    onboardingMessage = message
                }
            }
            Task { [weak self] in
                guard let self else { return }
                await updateAccessPathHealth(snapshot)
                if snapshot.profile.source == .t3Connect,
                   snapshot.connectionState == .unauthorized
                {
                    await repairT3ConnectEnvironment(snapshot.profile.environmentID)
                }
            }
            rebuildFlattenedWorld()
            await applyCombinedShell(changedEnvironment: snapshot.profile.environmentID)
        case let .detail(scoped, detail):
            await applyScopedDetail(detail, scoped: scoped)
        case let .removed(environmentID):
            snapshotsByEnvironment.removeValue(forKey: environmentID)
            retainedRemoteCompletions.removeValue(forKey: environmentID)
            knownProjectsByEnvironment.removeValue(forKey: environmentID)
            rebuildFlattenedWorld()
            await applyCombinedShell(changedEnvironment: environmentID)
        }
    }

    /// T3 Connect's active shell can jump directly from "running" to absent.
    /// Turn that disappearance into a stable, machine-scoped completion card.
    /// This only runs after the first real snapshot, so historical remote work
    /// never floods the notch when a machine first connects.
    private func retainRemoteCompletionTransition(
        from previous: EnvironmentSnapshot?,
        to incoming: EnvironmentSnapshot
    ) {
        let environmentID = incoming.profile.environmentID
        guard incoming.activeAccessPath != .local,
              reviewBaselines.contains(environmentID),
              let previousShell = previous?.shell,
              let incomingShell = incoming.shell
        else {
            return
        }

        var knownProjects = knownProjectsByEnvironment[environmentID] ?? [:]
        for project in previousShell.projects + incomingShell.projects {
            knownProjects[project.id] = project
        }
        knownProjectsByEnvironment[environmentID] = knownProjects

        var retained = retainedRemoteCompletions[environmentID] ?? [:]
        let previousByID = Dictionary(
            previousShell.threads.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let incomingByID = Dictionary(
            incomingShell.threads.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        // A new run in the same thread supersedes an older retained result.
        for thread in incomingShell.threads {
            switch resolveThreadAwarenessPhase(thread) {
            case .completed:
                if shouldRetainRemoteCompletion(thread, environmentID: environmentID) {
                    retained[thread.id] = thread
                } else {
                    retained[thread.id] = nil
                }
            case .running, .starting, .waitingForApproval, .waitingForInput:
                retained[thread.id] = nil
            default:
                if let prior = previousByID[thread.id],
                   isActiveWork(resolveThreadAwarenessPhase(prior))
                {
                    let completion = completedCopy(
                        of: thread,
                        at: incomingShell.updatedAt,
                        sequence: incomingShell.snapshotSequence
                    )
                    if shouldRetainRemoteCompletion(
                        completion,
                        environmentID: environmentID
                    ) {
                        retained[thread.id] = completion
                    }
                }
            }
        }

        for thread in previousShell.threads where incomingByID[thread.id] == nil {
            let completion: ThreadShell?
            switch resolveThreadAwarenessPhase(thread) {
            case .completed:
                completion = thread
            case .running, .starting, .waitingForApproval, .waitingForInput:
                completion = completedCopy(
                    of: thread,
                    at: incomingShell.updatedAt,
                    sequence: incomingShell.snapshotSequence
                )
            default:
                completion = nil
            }
            if let completion,
               shouldRetainRemoteCompletion(completion, environmentID: environmentID)
            {
                retained[thread.id] = completion
            }
        }

        retainedRemoteCompletions[environmentID] = retained
    }

    private func isActiveWork(_ phase: AgentAwarenessPhase?) -> Bool {
        switch phase {
        case .running, .starting, .waitingForApproval, .waitingForInput:
            true
        default:
            false
        }
    }

    private func completedCopy(
        of thread: ThreadShell,
        at completedAt: String,
        sequence: Int
    ) -> ThreadShell {
        var completion = thread
        if var turn = completion.latestTurn {
            turn.state = "completed"
            turn.completedAt = turn.completedAt ?? completedAt
            completion.latestTurn = turn
        } else {
            completion.latestTurn = LatestTurn(
                turnId: completion.session?.activeTurnId
                    ?? "remote-completion-\(sequence)-\(thread.id)",
                state: "completed",
                completedAt: completedAt
            )
        }
        if var session = completion.session {
            session.status = "idle"
            session.activeTurnId = nil
            session.updatedAt = completedAt
            completion.session = session
        }
        completion.updatedAt = completedAt
        completion.settledAt = nil
        completion.hasPendingApprovals = false
        completion.hasPendingUserInput = false
        return completion
    }

    private func shouldRetainRemoteCompletion(
        _ rawThread: ThreadShell,
        environmentID: EnvironmentID
    ) -> Bool {
        guard rawThread.archivedAt == nil else { return false }
        var scopedThread = rawThread
        scopedThread.id = ScopedThreadID(
            environmentID: environmentID,
            threadID: rawThread.id
        ).storageKey
        return !reviewStore.contains(completionKey(for: scopedThread))
    }

    private func applyCombinedShell(changedEnvironment: EnvironmentID) async {
        // The welcome tour owns the panel while it runs.
        guard !isDemoRunning else { return }

        // Everything already finished when the notch started counts as seen,
        // otherwise the first snapshot would pin every historical thread.
        // A connecting snapshot has no shell yet. Waiting for the first real
        // shell prevents a remote machine's historical completions from being
        // mistaken for brand-new Done notifications on the following event.
        if !reviewBaselines.contains(changedEnvironment),
           snapshotsByEnvironment[changedEnvironment]?.shell != nil
        {
            reviewBaselines.insert(changedEnvironment)
            for thread in threads
                where environmentID(for: thread) == changedEnvironment
                    && resolveThreadAwarenessPhase(thread) == .completed
            {
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
            coordinator.setFocusedThread(nil)
            clearFocusedDetail()
            syncFocusedEnvironment()
            return
        }

        guard threadId != focusedThreadId else {
            coordinator.setFocusedThread(scopedThreads[threadId])
            return
        }

        focusedThreadId = threadId
        // Detail arrives a poll later; drop the old thread's data so the card
        // never shows another agent's questions, plan, activity, or context.
        clearFocusedDetail()
        syncFocusedEnvironment()
        coordinator.setFocusedThread(scopedThreads[threadId])
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

    private func rebuildFlattenedWorld() {
        var nextProjects: [ProjectShell] = []
        var nextThreads: [ThreadShell] = []
        var nextScopedThreads: [String: ScopedThreadID] = [:]
        var nextScopedProjects: [String: ScopedProjectID] = [:]

        let ordered = snapshotsByEnvironment.values.sorted {
            let left = sourcePriority($0.activeAccessPath)
            let right = sourcePriority($1.activeAccessPath)
            if left != right { return left < right }
            return $0.profile.label.localizedStandardCompare($1.profile.label) == .orderedAscending
        }
        for snapshot in ordered {
            guard snapshot.profile.enabled,
                  snapshot.connectionState == .connected,
                  let shell = snapshot.shell
            else {
                continue
            }
            let environmentID = snapshot.profile.environmentID
            let retained = retainedRemoteCompletions[environmentID] ?? [:]
            let shellThreadIDs = Set(shell.threads.map(\.id))
            let retainedThreads = retained.values.filter {
                !shellThreadIDs.contains($0.id)
                    && shouldRetainRemoteCompletion($0, environmentID: environmentID)
            }
            let retainedProjectIDs = Set(retainedThreads.map(\.projectId))
            var rawProjects = shell.projects
            let shellProjectIDs = Set(rawProjects.map(\.id))
            for projectID in retainedProjectIDs where !shellProjectIDs.contains(projectID) {
                if let project = knownProjectsByEnvironment[environmentID]?[projectID] {
                    rawProjects.append(project)
                }
            }
            for rawProject in rawProjects {
                let scoped = ScopedProjectID(
                    environmentID: environmentID,
                    projectID: rawProject.id
                )
                var project = rawProject
                project.id = scoped.storageKey
                nextScopedProjects[project.id] = scoped
                nextProjects.append(project)
            }
            for shellThread in shell.threads where shellThread.archivedAt == nil {
                let rawThread: ThreadShell
                if resolveThreadAwarenessPhase(shellThread) == nil,
                   let retainedCompletion = retained[shellThread.id]
                {
                    rawThread = retainedCompletion
                } else {
                    rawThread = shellThread
                }
                let scoped = ScopedThreadID(
                    environmentID: environmentID,
                    threadID: rawThread.id
                )
                let project = ScopedProjectID(
                    environmentID: environmentID,
                    projectID: rawThread.projectId
                )
                var thread = rawThread
                thread.id = scoped.storageKey
                thread.projectId = project.storageKey
                nextScopedThreads[thread.id] = scoped
                nextThreads.append(thread)
            }
            for rawThread in retainedThreads {
                let scoped = ScopedThreadID(
                    environmentID: environmentID,
                    threadID: rawThread.id
                )
                let project = ScopedProjectID(
                    environmentID: environmentID,
                    projectID: rawThread.projectId
                )
                var thread = rawThread
                thread.id = scoped.storageKey
                thread.projectId = project.storageKey
                nextScopedThreads[thread.id] = scoped
                nextThreads.append(thread)
            }
        }
        projects = nextProjects
        threads = nextThreads
        scopedThreads = nextScopedThreads
        scopedProjects = nextScopedProjects
        machines = ordered
        syncFocusedEnvironment()
    }

    private func syncFocusedEnvironment() {
        if let environmentID = focusedThreadId.flatMap({ scopedThreads[$0]?.environmentID }) {
            environment = snapshotsByEnvironment[environmentID]?.descriptor
        } else if let localEnvironmentID {
            environment = snapshotsByEnvironment[localEnvironmentID]?.descriptor
        }
    }

    private func legacyConnectionState(
        _ state: EnvironmentConnectionState
    ) -> ConnectionState {
        switch state {
        case .connecting: .connecting
        case .connected: .connected
        case .offline, .credentialLocked, .incompatible: .disconnected
        case .unauthorized, .needsPairing: .unauthorized
        }
    }

    private func sourcePriority(_ source: EnvironmentSource) -> Int {
        switch source {
        case .local: 0
        case .direct: 1
        case .t3Connect: 2
        }
    }

    private func scopedRequestKey(_ requestID: String, thread: ScopedThreadID) -> String {
        "\(thread.storageKey):\(requestID)"
    }

    private func applyScopedDetail(
        _ snapshot: ThreadDetailSnapshot,
        scoped: ScopedThreadID
    ) async {
        var displaySnapshot = snapshot
        displaySnapshot.thread.id = scoped.storageKey
        displaySnapshot.thread.projectId = ScopedProjectID(
            environmentID: scoped.environmentID,
            projectID: snapshot.thread.projectId
        ).storageKey
        await applyDetail(displaySnapshot, scoped: scoped)
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
                guard environmentID(for: thread) == localEnvironmentID else { return nil }
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
        coordinator.setExpanded(true)
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

    private func applyDetail(
        _ snapshot: ThreadDetailSnapshot,
        scoped: ScopedThreadID? = nil
    ) async {
        guard !isDemoRunning else { return }
        guard snapshot.thread.id == focusedThreadId else { return }
        threadDetail = snapshot.thread
        let activities = snapshot.thread.activities
        pendingApprovals = derivePendingApprovals(from: activities)
            .filter {
                guard let scoped else { return !answeredRequestIds.contains($0.requestId) }
                return !answeredRequestIds.contains(
                    scopedRequestKey($0.requestId, thread: scoped)
                )
            }
        pendingUserInputs = derivePendingUserInputs(from: activities)
            .filter {
                guard let scoped else { return !answeredRequestIds.contains($0.requestId) }
                return !answeredRequestIds.contains(
                    scopedRequestKey($0.requestId, thread: scoped)
                )
            }
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
            coordinator.setExpanded(true)
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
            coordinator.setExpanded(true)
            return
        }

        if isHovering {
            presentation = active.isEmpty && walkthrough == nil ? .pill : .expanded
            coordinator.setExpanded(presentation == .expanded)
            return
        }

        // The quick start outranks an idle notch but not a waiting agent: it opens
        // the panel while a step is being read, and otherwise keeps the pill on
        // screen so the walkthrough is pointing at something.
        if let walkthrough {
            presentation = walkthrough.wantsPanel ? .expanded : .pill
            coordinator.setExpanded(presentation == .expanded)
            return
        }

        if presentation == .attention, needsAttention {
            return
        }

        if active.isEmpty {
            presentation = .hidden
            coordinator.setExpanded(false)
            return
        }

        if presentation == .expanded, userInitiated {
            return
        }

        presentation = .pill
        coordinator.setExpanded(false)
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
