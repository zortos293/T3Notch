import SwiftUI
import T3NotchCore

private let notchSpring = Animation.spring(response: 0.34, dampingFraction: 0.78)

struct NotchRootView: View {
    @Bindable var store: AgentStore

    private var metrics: NotchMetrics { store.notchMetrics }

    private var isExpanded: Bool {
        store.needsOnboarding
            || store.presentation == .expanded
            || store.presentation == .attention
    }

    private var bodyWidth: CGFloat {
        isExpanded
            ? NotchGeometry.expandedBodyWidth(
                metrics,
                agentCount: store.activeThreads.count
            )
            : NotchGeometry.collapsedBodyWidth(metrics)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top strip sits level with the physical notch, so its content has to
            // flank the notch rather than render behind the cutout.
            TopStrip(store: store, metrics: metrics, isExpanded: isExpanded)
                .frame(height: metrics.notchHeight)

            if isExpanded {
                ExpandedBody(store: store)
                    .padding(.horizontal, NotchGeometry.bodyPadding)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: bodyWidth)
        .padding(.horizontal, NotchGeometry.wing)
        .background {
            NotchShape(
                topRadius: NotchGeometry.wing,
                bottomRadius: isExpanded ? 26 : 14
            )
            .fill(.black)
            .shadow(color: .black.opacity(isExpanded ? 0.45 : 0), radius: 20, y: 10)
        }
        .overlay {
            if store.presentation == .attention {
                NotchShape(
                    topRadius: NotchGeometry.wing,
                    bottomRadius: isExpanded ? 26 : 14
                )
                .stroke(Color.orange.opacity(0.75), lineWidth: 1.5)
            }
        }
        // Measured before the fill-the-window frame below, so this is the size of
        // the drawn panel and not of the whole transparent window.
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    store.panelSize = size
                }
            }
        )
        .opacity(store.presentation == .hidden && !store.needsOnboarding ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(notchSpring, value: isExpanded)
        .animation(notchSpring, value: store.presentation)
        .animation(notchSpring, value: bodyWidth)
    }
}

private struct TopStrip: View {
    let store: AgentStore
    let metrics: NotchMetrics
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ProviderLogo(brand: store.providerBrand, size: 13)
                    .overlay(alignment: .bottomTrailing) {
                        if store.focusedPhase == .running || store.focusedPhase == .starting {
                            WorkingPulse()
                                .frame(width: 5, height: 5)
                                .offset(x: 2, y: 1)
                        }
                    }

                Text(leadingLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reserve the cutout itself.
            Spacer(minLength: 0)
                .frame(width: metrics.notchWidth)

            HStack(spacing: 7) {
                if store.connectionState != .connected {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                // A pretend agent has to say so somewhere, and a badge beside the
                // clock costs a strip that is already there — a banner over the
                // panel pushed everything worth reading further down.
                if let caption = store.walkthrough?.caption {
                    WalkthroughChip(caption: caption)
                }
                if store.activeThreads.count > 1 {
                    Text("\(store.activeThreads.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.9)))
                }
                if let elapsed = store.elapsedLabel {
                    Text(elapsed)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
    }

    private var leadingLabel: String {
        if store.needsOnboarding { return "Setup" }
        if let phase = store.focusedPhase { return headline(for: phase) }
        if store.walkthrough != nil { return "Quick start" }
        return "Idle"
    }
}

private struct ExpandedBody: View {
    @Bindable var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.needsOnboarding {
                OnboardingView(store: store)
            } else if let caption = store.walkthrough?.caption, store.activeThreads.isEmpty {
                // Nothing to demonstrate on, so the caption is all the panel has
                // to say — during the connection test, for instance.
                WalkthroughBanner(caption: caption)
                Text("No agents running yet.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                if let celebration = store.celebration {
                    CelebrationBanner(celebration: celebration)
                        .transition(
                            .asymmetric(
                                insertion: .push(from: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }

                if store.activeThreads.count > 1 {
                    ThreadCardDeck(store: store)
                    Divider().overlay(Color.white.opacity(0.08))
                }

                HeaderRow(store: store)
                MachineRow(store: store)

                if !store.recentActivity.isEmpty {
                    ActivityFeed(events: store.recentActivity)
                }

                if let plan = store.plan, !plan.steps.isEmpty {
                    TaskListView(
                        plan: plan,
                        completionTicks: store.taskCompletionTicks,
                        rowLimit: store.settingsValues.taskRows
                    )
                }

                if !store.pendingApprovals.isEmpty || !store.pendingUserInputs.isEmpty {
                    PromptCarousel(store: store)
                }

                // Last, not first: what the agent did is what you look up for, and
                // a review bar above it pushed all of it down a row.
                if let thread = store.focusedThread, store.awaitsReview(thread) {
                    ReviewBar(store: store, thread: thread)
                }
            }
        }
        .padding(.top, 10)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: store.celebration)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.walkthrough)
        .overlay {
            if let celebration = store.celebration,
                celebration.milestone.showsConfetti,
                store.settingsValues.confetti
            {
                ConfettiOverlay(tint: celebration.milestone.tint)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// One pressable card per running agent, grouped under its project, so several
/// chats can be watched at once and switched between.
private struct ThreadCardDeck: View {
    @Bindable var store: AgentStore

    private var groups: [(project: ProjectShell, threads: [ThreadShell])] {
        store.activeThreadsByProject
    }

    var body: some View {
        // No heading and no count: the strip above already says how many are
        // running, and the project names label the cards well enough.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.project.id) { group in
                VStack(alignment: .leading, spacing: 5) {
                    if groups.count > 1 {
                        Text(group.project.title.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .tracking(0.5)
                            .lineLimit(1)
                    }
                    // Wrapped rows instead of a scroller: every card stays
                    // visible and clickable without a scroll gesture.
                    ForEach(Array(rows(of: group.threads).enumerated()), id: \.offset) { row in
                        HStack(alignment: .top, spacing: NotchGeometry.cardSpacing) {
                            ForEach(row.element) { thread in
                                ThreadCard(
                                    store: store,
                                    thread: thread,
                                    isSelected: thread.id == store.focusedThread?.id
                                )
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func rows(of threads: [ThreadShell]) -> [[ThreadShell]] {
        stride(from: 0, to: threads.count, by: NotchGeometry.maxCardsPerRow).map { start in
            Array(threads[start..<min(start + NotchGeometry.maxCardsPerRow, threads.count)])
        }
    }
}

private struct ThreadCard: View {
    @Bindable var store: AgentStore
    let thread: ThreadShell
    let isSelected: Bool

    private var phase: AgentAwarenessPhase? {
        resolveThreadAwarenessPhase(thread)
    }

    private var needsAnswer: Bool {
        thread.hasPendingApprovals || thread.hasPendingUserInput
    }

    var body: some View {
        Button {
            store.selectThread(thread.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ProviderLogo(brand: store.providerBrand(for: thread), size: 11)
                    Text(store.modelLabel(for: thread) ?? store.providerBrand(for: thread).label)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if needsAnswer {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                    }
                }

                Text(thread.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if let phase {
                        Circle()
                            .fill(statusColor(phase))
                            .frame(width: 5, height: 5)
                        Text(headline(for: phase))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusColor(phase))
                            .lineLimit(1)
                    }
                    if let elapsed = store.elapsedLabel(for: thread) {
                        Text(elapsed)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .padding(8)
            .frame(
                width: NotchGeometry.cardWidth,
                height: NotchGeometry.cardHeight,
                alignment: .topLeading
            )
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        needsAnswer
                            ? Color.orange.opacity(isSelected ? 0.95 : 0.45)
                            : Color.white.opacity(isSelected ? 0.45 : 0.06),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ phase: AgentAwarenessPhase) -> Color {
        switch phase {
        case .waitingForApproval, .waitingForInput: .orange
        case .failed: .red
        case .completed: .green
        case .running, .starting: .cyan
        case .stale: .gray
        }
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .tracking(0.6)
    }
}

private struct HeaderRow: View {
    let store: AgentStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.projectTitle.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(0.6)
                Text(store.focusedThread?.title ?? "No active agent")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let context = store.contextWindow {
                ContextGauge(snapshot: context)
            }
            if let phase = store.focusedPhase {
                PhaseChip(phase: phase)
            }
        }
    }
}

/// Answers "which model, which machine, and since when is it working".
private struct MachineRow: View {
    let store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ProviderLogo(brand: store.providerBrand, size: 11)
                Text(store.modelLabel ?? store.providerBrand.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                if let machine = store.machineLabel {
                    Divider().frame(height: 9).overlay(Color.white.opacity(0.18))
                    Image(systemName: machineIcon)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(machine)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                if let platform = store.platformLabel {
                    Text(platform)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 5) {
                if let since = store.workingSinceLabel {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(since)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                if let workspace = store.workspaceLabel {
                    Divider().frame(height: 9).overlay(Color.white.opacity(0.18))
                    Image(systemName: "arrow.trianglehead.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(workspace)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
    }

    private var machineIcon: String {
        switch store.environment?.platform?.os {
        case "darwin": return "laptopcomputer"
        case "win32": return "pc"
        default: return "server.rack"
        }
    }
}

/// A finished agent stays pinned until it is reviewed, so this offers the two
/// ways out: open it in T3 Code, or acknowledge it here.
private struct ReviewBar: View {
    @Bindable var store: AgentStore
    let thread: ThreadShell

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            Text("Finished — not reviewed yet")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Open in T3 Code") { store.openInT3Code(thread) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(.black)
                .background(Capsule().fill(Color.white))

            Button("Dismiss") { store.markReviewed(thread) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(.white.opacity(0.85))
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.green.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Marks the panel as a demonstration from the top strip, next to the clock, so
/// the pretend agent below it reads exactly like a real one.
private struct WalkthroughChip: View {
    let caption: Walkthrough.Caption

    var body: some View {
        // The strip's shoulder is only as wide as the screen's notch leaves it, so
        // the word goes rather than being clipped to "De…".
        ViewThatFits(in: .horizontal) {
            chip(withLabel: true)
            chip(withLabel: false)
        }
        .animation(notchSpring, value: caption)
    }

    private func chip(withLabel: Bool) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: caption.symbol)
                .font(.system(size: 8.5, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
            if withLabel {
                Text(caption.chip)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .fixedSize()
            }
        }
        .foregroundStyle(caption.tint)
        .padding(.horizontal, withLabel ? 6 : 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(caption.tint.opacity(0.16)))
        .overlay(Capsule().stroke(caption.tint.opacity(0.4), lineWidth: 1))
    }
}

/// The notch's half of the welcome, for when there is no agent to point at: the
/// connection test, for instance, runs on an otherwise empty panel.
private struct WalkthroughBanner: View {
    let caption: Walkthrough.Caption

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: caption.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(caption.tint)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(caption.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(caption.detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            if caption.isBusy {
                WorkingPulse()
                    .frame(width: 6, height: 6)
                    .padding(.top, 3)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(caption.tint.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(caption.tint.opacity(0.28), lineWidth: 1)
        )
        .animation(notchSpring, value: caption)
    }
}

/// The agent's last few actions: which commands it ran, which files it touched.
/// Newest sits at the bottom, and whatever is still in flight is tinted.
private struct ActivityFeed: View {
    let events: [ActivityEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                SectionLabel("Activity")
                if events.contains(where: \.isRunning) {
                    StreamingCaret()
                }
            }
            ForEach(events) { event in
                ActivityRow(event: event)
            }
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                // Filled glyphs: at this size the outlined ones are all
                // indistinguishable little squares.
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(event.isRunning ? Color.cyan : .white.opacity(0.34))
                .frame(width: 13, alignment: .center)

            Text(event.label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(event.isRunning ? 0.9 : 0.55))
                // Never truncate the label, and hold a column so the details
                // line up; long tool names are free to overflow it.
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 76, alignment: .leading)

            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(event.isRunning ? 0.62 : 0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch event.kind {
        case .command: "terminal.fill"
        case .fileChange: "pencil"
        case .search: "magnifyingglass"
        case .tool: "puzzlepiece.extension.fill"
        case .image: "photo.fill"
        case .other: "wrench.and.screwdriver.fill"
        }
    }
}

private struct StreamingCaret: View {
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.cyan)
            .frame(width: 5, height: 9)
            .opacity(on ? 1 : 0.15)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Soft breathing dot shown while a turn is actively running.
struct WorkingPulse: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.cyan)
            .opacity(on ? 1 : 0.25)
            .scaleEffect(on ? 1 : 0.7)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct PhaseChip: View {
    let phase: AgentAwarenessPhase

    var body: some View {
        Text(headline(for: phase))
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private var color: Color {
        switch phase {
        case .waitingForApproval, .waitingForInput: return .orange
        case .failed: return .red
        case .completed: return .green
        case .running, .starting: return .cyan
        case .stale: return .gray
        }
    }
}

private struct ContextGauge: View {
    let snapshot: ContextWindowSnapshot

    var body: some View {
        HStack(spacing: 5) {
            ProgressRing(progress: (snapshot.usedPercentage ?? 0) / 100, phase: .running)
                .frame(width: 11, height: 11)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var label: String {
        if let pct = snapshot.usedPercentage {
            return String(format: "%.0f%%", pct)
        }
        return "\(Int(snapshot.usedTokens))"
    }
}

struct ProgressRing: View {
    let progress: Double
    let phase: AgentAwarenessPhase?

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(progress, 0.08), 1))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private var ringColor: Color {
        switch phase {
        case .waitingForApproval, .waitingForInput: return .orange
        case .failed: return .red
        case .completed: return .green
        default: return .cyan
        }
    }
}

private struct TaskListView: View {
    let plan: ActivePlanState
    /// Completion counts per step, used to trigger the finish animation.
    var completionTicks: [String: Int] = [:]
    var rowLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("Tasks")
            ForEach(plan.steps.prefix(rowLimit)) { step in
                TaskRow(step: step, completionTick: completionTicks[step.step] ?? 0)
            }
            if plan.steps.count > rowLimit {
                Text("+\(plan.steps.count - rowLimit) more")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        // Steps reordering or flipping state should slide rather than snap.
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: plan.steps)
    }

}

/// A task row. When its step finishes, the tick bounces and a ring radiates out
/// of it once — enough to catch the eye mid-glance without being a toy.
///
/// Both effects are driven by `completionTick`, which only ever increases, so
/// the animation runs exactly once per completion and cannot be left
/// half-applied if the row is rebuilt or goes away mid-flight.
private struct TaskRow: View {
    let step: PlanStep
    let completionTick: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.green, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .phaseAnimator(RingPhase.allCases, trigger: completionTick) { ring, phase in
                        ring
                            .scaleEffect(phase.scale)
                            .opacity(phase.opacity)
                    } animation: { phase in
                        switch phase {
                        // Snapping back to the resting phase is invisible: both
                        // it and the phase before it are fully transparent.
                        case .idle: nil
                        case .swell: .easeOut(duration: 0.16)
                        case .faded: .easeOut(duration: 0.5)
                        }
                    }

                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.bounce, options: .speed(1.3), value: completionTick)
            }
            .frame(width: 12)

            Text(step.step)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(
                    step.status == .completed
                        ? Color.white.opacity(0.45) : Color.white.opacity(0.9)
                )
                .strikethrough(step.status == .completed, color: .white.opacity(0.35))
                .lineLimit(1)
        }
    }

    /// Rests invisible, snaps out around the tick, then expands away and fades.
    private enum RingPhase: CaseIterable {
        case idle
        case swell
        case faded

        var scale: CGFloat {
            switch self {
            case .idle: 0.5
            case .swell: 1.3
            case .faded: 2.3
            }
        }

        var opacity: Double {
            switch self {
            case .idle: 0
            case .swell: 0.6
            case .faded: 0
            }
        }
    }

    private var icon: String {
        switch step.status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch step.status {
        case .pending: .white.opacity(0.35)
        case .inProgress: .cyan
        case .completed: .green
        }
    }
}

/// One pending thing to answer. Multi-question input requests are flattened so
/// each question gets its own slide, but their answers are submitted together.
private enum PromptSlide: Identifiable, Equatable {
    case approval(PendingApproval)
    case question(input: PendingUserInput, question: UserInputQuestion)

    var id: String {
        switch self {
        case let .approval(approval): "approval:\(approval.requestId)"
        case let .question(input, question): "question:\(input.requestId):\(question.id)"
        }
    }
}

/// Shows pending approvals and questions as a deck: answer one, it slides to
/// the next, and the deck disappears once everything is answered.
private struct PromptCarousel: View {
    @Bindable var store: AgentStore

    /// Slides already answered in this session, so the deck advances without
    /// waiting for the server round trip to drop the request.
    @State private var answered: Set<String> = []
    /// requestId -> questionId -> answer, accumulated until a request completes.
    @State private var drafts: [String: [String: JSONValue]] = [:]
    @State private var multiSelection: [String: Set<String>] = [:]

    private var slides: [PromptSlide] {
        store.pendingApprovals.map(PromptSlide.approval)
            + store.pendingUserInputs.flatMap { input in
                input.questions.map { PromptSlide.question(input: input, question: $0) }
            }
    }

    private var currentIndex: Int? {
        slides.firstIndex { !answered.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let index = currentIndex {
                let slide = slides[index]

                HStack(spacing: 6) {
                    Text("\(index + 1) of \(slides.count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(0.4)

                    SlideDots(total: slides.count, current: index)

                    Spacer(minLength: 0)

                    if index > 0 {
                        Button {
                            goBack(from: index)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Group {
                    switch slide {
                    case let .approval(approval):
                        ApprovalSlide(approval: approval) { decision in
                            store.respondToApproval(approval, decision: decision)
                            advance(past: slide)
                        }
                    case let .question(input, question):
                        QuestionSlide(
                            question: question,
                            selection: multiSelection[question.id] ?? [],
                            isLast: index == slides.count - 1,
                            onToggle: { label in toggle(question: question, label: label) },
                            onAnswer: { answer in
                                record(answer, for: question, in: input)
                                advance(past: slide)
                            }
                        )
                    }
                }
                .id(slide.id)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
                .animation(notchSpring, value: slide.id)
            }
        }
        .clipped()
        .onChange(of: slides.map(\.id)) { _, ids in
            // Drop bookkeeping for requests the server has resolved.
            let live = Set(ids)
            answered = answered.filter { live.contains($0) }
        }
    }

    private func toggle(question: UserInputQuestion, label: String) {
        var set = multiSelection[question.id] ?? []
        if set.contains(label) { set.remove(label) } else { set.insert(label) }
        multiSelection[question.id] = set
    }

    private func record(
        _ answer: JSONValue,
        for question: UserInputQuestion,
        in input: PendingUserInput
    ) {
        var requestAnswers = drafts[input.requestId] ?? [:]
        requestAnswers[question.id] = answer
        drafts[input.requestId] = requestAnswers

        // A request is only dispatched once every one of its questions is answered.
        let allAnswered = input.questions.allSatisfy { requestAnswers[$0.id] != nil }
        guard allAnswered else { return }
        store.respondToUserInput(input, answers: requestAnswers)
        drafts[input.requestId] = nil
    }

    private func advance(past slide: PromptSlide) {
        withAnimation(notchSpring) {
            _ = answered.insert(slide.id)
        }
    }

    private func goBack(from index: Int) {
        let previous = slides[index - 1]
        withAnimation(notchSpring) {
            _ = answered.remove(previous.id)
        }
        if case let .question(input, question) = previous {
            drafts[input.requestId]?[question.id] = nil
        }
    }
}

private struct SlideDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(fill(for: index))
                    .frame(width: index == current ? 10 : 4, height: 4)
            }
        }
        .animation(notchSpring, value: current)
    }

    private func fill(for index: Int) -> Color {
        if index == current { return .orange }
        return index < current ? .white.opacity(0.45) : .white.opacity(0.18)
    }
}

private struct ApprovalSlide: View {
    let approval: PendingApproval
    let onDecision: (ApprovalDecision) -> Void

    var body: some View {
        PromptCard {
            Text("Approval · \(approval.requestKind)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
            }
            HStack(spacing: 6) {
                button("Approve", .accept, emphasis: true)
                button("Always", .acceptForSession, emphasis: false)
                button("Decline", .decline, emphasis: false)
                button("Cancel", .cancel, emphasis: false)
            }
        }
    }

    private func button(
        _ title: String,
        _ decision: ApprovalDecision,
        emphasis: Bool
    ) -> some View {
        Button(title) { onDecision(decision) }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(emphasis ? Color.black : Color.white.opacity(0.9))
            .background(Capsule().fill(emphasis ? Color.white : Color.white.opacity(0.12)))
    }
}

private struct QuestionSlide: View {
    let question: UserInputQuestion
    let selection: Set<String>
    let isLast: Bool
    let onToggle: (String) -> Void
    let onAnswer: (JSONValue) -> Void

    var body: some View {
        PromptCard {
            Text(question.header)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            Text(question.question)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                let isOn = selection.contains(option.label)
                Button {
                    if question.multiSelect {
                        onToggle(option.label)
                    } else {
                        onAnswer(.string(option.label))
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(
                            systemName: isOn
                                ? (question.multiSelect
                                    ? "checkmark.square.fill" : "checkmark.circle.fill")
                                : (question.multiSelect ? "square" : "circle")
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(isOn ? Color.orange : Color.white.opacity(0.4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                            if !option.description.isEmpty {
                                Text(option.description)
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(2)
                            }
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }

            if question.multiSelect {
                Button(isLast ? "Submit" : "Next") {
                    onAnswer(.array(selection.sorted().map(JSONValue.string)))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selection.isEmpty ? Color.white.opacity(0.4) : .black)
                .background(
                    Capsule().fill(selection.isEmpty ? Color.white.opacity(0.12) : Color.white)
                )
                .disabled(selection.isEmpty)
            }
        }
    }
}

private struct PromptCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}

private struct OnboardingView: View {
    @Bindable var store: AgentStore
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to T3 Code")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(store.onboardingMessage ?? "Paste a bearer token to connect.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Bearer token", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
            Button("Connect") { store.submitManualToken(token) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(.black)
                .background(Capsule().fill(Color.white))
        }
    }
}
