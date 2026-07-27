import AppKit
import SwiftUI

/// The first-launch welcome: one thing per screen, and a pretend agent running
/// in the notch the whole way through.
///
/// Every chapter has something happening above the window rather than a
/// screenshot inside it — including a question the reader answers in the notch
/// itself before the tour will move on. The last chapter is the only one that
/// talks to anything real: the connection test makes its requests for real and
/// says what came back.
struct QuickStartView: View {
    let store: AgentStore
    let demo: DemoAgent
    let onFinish: () -> Void

    @State private var chapter: Chapter = .welcome
    @State private var answeredTheDemo = false
    @State private var check = ConnectionCheck()

    private static let brand = Color(red: 0.21, green: 0.44, blue: 0.98)
    private static let move = Animation.spring(response: 0.42, dampingFraction: 0.86)

    enum Chapter: Int, CaseIterable, Comparable {
        case welcome
        case working
        case answering
        case landing
        case connection

        static func < (lhs: Chapter, rhs: Chapter) -> Bool { lhs.rawValue < rhs.rawValue }

        var next: Chapter? { Chapter(rawValue: rawValue + 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .background(background)
        .task {
            demo.onAnswered = { answeredTheDemo = true }
        }
        .onChange(of: answeredTheDemo) { _, answered in
            guard answered, chapter == .answering else { return }
            // A beat to read the confirmation, then on with it.
            Task {
                try? await Task.sleep(for: .milliseconds(1600))
                if chapter == .answering { advance() }
            }
        }
        .onChange(of: testStage) { _, stage in
            if let stage { store.stage(stage) }
        }
    }

    // MARK: - Chapters

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .frame(height: 108)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            Text(subtitle)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.top, 7)

            chapterBody
                .padding(.top, 20)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        // Clears the floating traffic lights.
        .padding(.top, 40)
        .id(chapter)
        .transition(
            .asymmetric(
                insertion: .offset(y: 14).combined(with: .opacity),
                removal: .offset(y: -10).combined(with: .opacity)
            )
        )
    }

    @ViewBuilder private var chapterBody: some View {
        switch chapter {
        case .welcome:
            PointerList(
                items: [
                    .init(symbol: "eye", text: "What each agent is doing, while you work elsewhere"),
                    .init(symbol: "bubble.left.and.text.bubble.right", text: "Its questions, answered without switching windows"),
                    .init(symbol: "party.popper", text: "A moment when a plan finishes or a branch lands"),
                ]
            )
        case .working:
            PointerList(
                items: [
                    .init(symbol: "cpu", text: "The provider, the model, and the machine it runs on"),
                    .init(symbol: "terminal", text: "Commands and file changes as they happen"),
                    .init(symbol: "checklist", text: "Its plan, ticking off step by step"),
                ]
            )
        case .answering:
            AnswerPrompt(answered: answeredTheDemo)
        case .landing:
            PointerList(
                items: [
                    .init(symbol: "pin", text: "Finished agents stay pinned until you have looked"),
                    .init(symbol: "arrow.triangle.merge", text: "Merged branches are noticed, even squashed ones"),
                    .init(symbol: "slider.horizontal.3", text: "All of it adjustable later, with ⌘, "),
                ]
            )
        case .connection:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(check.steps) { step in
                    CheckRow(step: step)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder private var hero: some View {
        switch chapter {
        case .welcome: NotchHero()
        case .working: LookUpHero(tint: .cyan, symbol: "wand.and.sparkles")
        case .answering:
            LookUpHero(
                tint: answeredTheDemo ? .green : .orange,
                symbol: answeredTheDemo ? "checkmark.circle.fill" : "questionmark.bubble.fill"
            )
        case .landing: LookUpHero(tint: .green, symbol: "party.popper.fill")
        case .connection: ConnectionHero(outcome: check.isRunning ? nil : check.failure == nil)
        }
    }

    private var title: String {
        switch chapter {
        case .welcome: return "Your agents, under the notch"
        case .working: return "Look up — an agent is working"
        case .answering:
            return answeredTheDemo ? "That is all there is to it" : "Now it needs an answer"
        case .landing: return "You will know when it lands"
        case .connection:
            if check.isRunning { return "Checking the connection" }
            return check.failure == nil ? "Everything answered" : "T3 Code is not answering"
        }
    }

    private var subtitle: String {
        switch chapter {
        case .welcome:
            return "T3Notch watches the agents running in T3 Code and puts them where you are "
                + "already looking. Here is a minute-long tour, with a pretend agent."
        case .working:
            return "The agent in your notch is not real, but everything it does up there is "
                + "exactly what a real one shows."
        case .answering:
            return answeredTheDemo
                ? "Your answer went nowhere — that agent is pretend. A real one would have "
                    + "carried on with it."
                : "Approvals and questions arrive in the notch. Answer one and the next slides "
                    + "in. Go on: pick either option up there."
        case .landing:
            return "A finished plan gets a banner, a landed branch gets confetti, and the "
                + "panel opens itself — these moments never happen while you are watching."
        case .connection:
            if check.isRunning { return "Making the real requests, one at a time." }
            if let failure = check.failure {
                return "\(failure) failed. T3Notch will keep trying; start T3 Code and it "
                    + "will connect by itself."
            }
            return check.summary ?? "T3 Code is running and the notch can see it."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            ChapterDots(current: chapter)

            Spacer()

            if chapter != .connection {
                TextButton("Skip") { finish() }
            } else if !check.isRunning {
                TextButton("Test again") { runCheck() }
            }

            if let label = primaryLabel {
                PrimaryButton(label) {
                    if chapter == .connection { finish() } else { advance() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)
        }
    }

    /// The answering chapter withholds its button: the point of it is that the
    /// reader touches the notch, and a Continue sitting there invites a click on
    /// the wrong thing. Skip is still in the footer for anyone who would rather not.
    private var primaryLabel: String? {
        switch chapter {
        case .welcome: "Show me"
        case .working: "Next"
        case .answering: answeredTheDemo ? "Next" : nil
        case .landing: "Nearly done"
        case .connection: "Start using T3Notch"
        }
    }

    // MARK: - Flow

    private func advance() {
        guard let next = chapter.next else { return }
        withAnimation(Self.move) { chapter = next }
        enter(next)
    }

    private func enter(_ chapter: Chapter) {
        switch chapter {
        case .welcome:
            break
        case .working:
            demo.start()
        case .answering:
            demo.ask()
        case .landing:
            demo.land()
        case .connection:
            // The pretend agent bows out before anything real is measured.
            demo.stop()
            store.stage(.testing(.running))
            runCheck()
        }
    }

    private func runCheck() {
        Task { await check.run() }
    }

    private func finish() {
        demo.stop()
        onFinish()
    }

    /// The notch echoes the connection test, so the last chapter demonstrates
    /// something too.
    private var testStage: Walkthrough.Stage? {
        guard chapter == .connection else { return nil }
        if check.isRunning { return .testing(.running) }
        if let failure = check.failure { return .testing(.failed("\(failure) failed")) }
        if let summary = check.summary { return .testing(.passed(summary)) }
        return nil
    }

    private var background: some View {
        ZStack {
            Color(red: 0.05, green: 0.055, blue: 0.07)
            RadialGradient(
                colors: [Self.brand.opacity(0.28), .clear],
                center: .init(x: 0.15, y: -0.1),
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Heroes

/// The app's own silhouette, breathing the way the panel does when it opens.
private struct NotchHero: View {
    @State private var open = false

    var body: some View {
        NotchShape(topRadius: 7, bottomRadius: open ? 16 : 11)
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.95), .white.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: open ? 108 : 84, height: open ? 46 : 34)
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Circle().fill(.cyan).frame(width: 5, height: 5)
                    if open {
                        Capsule()
                            .fill(.black.opacity(0.35))
                            .frame(width: 26, height: 4)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 8)
            }
            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
            .frame(height: 60, alignment: .center)
            .task {
                // Opening and closing on a loop, because that is the one gesture
                // the whole app is built around.
                while !Task.isCancelled {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { open = true }
                    try? await Task.sleep(for: .milliseconds(1500))
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { open = false }
                    try? await Task.sleep(for: .milliseconds(1100))
                }
            }
    }
}

/// An arrow pointing at the notch, since that is where the chapter is happening.
private struct LookUpHero: View {
    let tint: Color
    let symbol: String

    @State private var lifted = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().stroke(tint.opacity(0.3), lineWidth: 1))
                .contentTransition(.symbolEffect(.replace))

            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint.opacity(0.75))
                .offset(y: lifted ? -6 : 2)
                .animation(
                    .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                    value: lifted
                )

            Text("the notch")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(height: 60, alignment: .center)
        .onAppear { lifted = true }
    }
}

private struct ConnectionHero: View {
    /// Nil while the test is still running.
    let outcome: Bool?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(Circle().fill(tint.opacity(0.14)))
            .overlay(Circle().stroke(tint.opacity(0.3), lineWidth: 1))
            .symbolEffect(.variableColor.iterative, isActive: outcome == nil)
            .contentTransition(.symbolEffect(.replace))
            .frame(height: 60, alignment: .center)
    }

    private var symbol: String {
        switch outcome {
        case nil: "antenna.radiowaves.left.and.right"
        case true?: "checkmark.circle.fill"
        case false?: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case nil: .cyan
        case true?: .green
        case false?: .orange
        }
    }
}

// MARK: - Pieces

/// Three short lines, arriving one after another so the eye has somewhere to go.
private struct PointerList: View {
    struct Item: Identifiable {
        let symbol: String
        let text: String
        var id: String { text }
    }

    let items: [Item]
    @State private var shown = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 11) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                    Text(item.text)
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .opacity(index < shown ? 1 : 0)
                .offset(y: index < shown ? 0 : 6)
            }
        }
        .task {
            for index in items.indices {
                try? await Task.sleep(for: .milliseconds(index == 0 ? 120 : 110))
                withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { shown = index + 1 }
            }
        }
    }
}

/// The one place the tour waits for the reader instead of a button.
private struct AnswerPrompt: View {
    let answered: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                if answered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: answered)
                } else {
                    WorkingPulse()
                        .frame(width: 9, height: 9)
                }
            }
            .frame(width: 18)

            Text(
                answered
                    ? "Answered in the notch."
                    : "Waiting for your answer in the notch…"
            )
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(answered ? 0.85 : 0.6))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((answered ? Color.green : Color.orange).opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((answered ? Color.green : Color.orange).opacity(0.28), lineWidth: 1)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: answered)
    }
}

private struct ChapterDots: View {
    let current: QuickStartView.Chapter

    var body: some View {
        HStack(spacing: 5) {
            ForEach(QuickStartView.Chapter.allCases, id: \.rawValue) { chapter in
                Capsule()
                    .fill(fill(for: chapter))
                    .frame(width: chapter == current ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
    }

    private func fill(for chapter: QuickStartView.Chapter) -> Color {
        if chapter == current { return .white.opacity(0.85) }
        return chapter < current ? .white.opacity(0.4) : .white.opacity(0.15)
    }
}

/// One diagnostic line: state glyph, what was tried, and what came back.
private struct CheckRow: View {
    let step: ConnectionCheck.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            glyph
                .frame(width: 14, height: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(color.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: step.outcome)
    }

    private var detail: String? {
        switch step.outcome {
        case .waiting: nil
        case .running: "checking…"
        case let .passed(message): message
        case let .failed(message): message
        }
    }

    private var color: Color {
        switch step.outcome {
        case .waiting: .white.opacity(0.3)
        case .running: .cyan
        case .passed: .green
        case .failed: .orange
        }
    }

    @ViewBuilder private var glyph: some View {
        switch step.outcome {
        case .waiting:
            Circle().stroke(.white.opacity(0.2), lineWidth: 1.5)
        case .running:
            Circle().stroke(Color.cyan.opacity(0.6), lineWidth: 1.5)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    private static let brand = Color(red: 0.21, green: 0.44, blue: 0.98)

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Self.brand.opacity(hovering ? 1 : 0.88))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
