import AppKit
import SwiftUI

/// First-launch quick start: what this thing is, the three things to know, and a
/// connection test that actually makes the requests rather than reporting cached
/// state.
struct QuickStartView: View {
    let store: AgentStore
    let onFinish: () -> Void

    @State private var check = ConnectionCheck()
    /// The step being pointed at, mirrored into the notch.
    @State private var pointedStep: Walkthrough.Step?

    private static let brand = Color(red: 0.21, green: 0.44, blue: 0.98)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                steps
                connectionTest

                HStack(spacing: 8) {
                    Spacer()
                    QuickStartButton("Test connection", prominent: false) {
                        Task { await check.run() }
                    }
                    .disabled(check.isRunning)
                    QuickStartButton("Start using it", prominent: true, action: onFinish)
                }
            }
            // Top inset clears the floating traffic lights.
            .padding(.top, 38)
            .padding([.horizontal, .bottom], 20)
        }
        .background(background)
        .task {
            // Bootstrap is still settling on first launch; a beat avoids reporting
            // a failure the app is about to fix by itself.
            try? await Task.sleep(for: .milliseconds(700))
            await check.run()
        }
        .onChange(of: pointedStep) { syncNotch() }
        .onChange(of: testStatus) { syncNotch() }
        .onDisappear { store.endWalkthrough() }
    }

    private func syncNotch() {
        store.updateWalkthrough(Walkthrough(step: pointedStep, status: testStatus))
    }

    private var testStatus: Walkthrough.Status {
        if check.isRunning { return .testing }
        if let summary = check.summary { return .passed(summary) }
        if let failure = check.failure { return .failed(failure) }
        return .idle
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                NotchShape(topRadius: 5, bottomRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [Self.brand, Self.brand.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 52, height: 26)
                    .overlay(alignment: .bottom) {
                        Circle()
                            .fill(.cyan)
                            .frame(width: 6, height: 6)
                            .padding(.bottom, 5)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("T3Notch")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Your agents, under the notch")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }

            Text(
                "T3Notch watches the agents running in T3 Code and shows what they are "
                    + "doing without you switching windows. Approvals and questions can be "
                    + "answered right in the notch."
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Walkthrough.steps) { step in
                if step.id != Walkthrough.steps.first?.id {
                    Rectangle()
                        .fill(.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.vertical, 11)
                }
                QuickStartStep(step: step, isPointed: pointedStep == step)
                    .onHover { hovering in
                        // Pointing at a step opens the notch showing that step, so
                        // the walkthrough demonstrates itself.
                        pointedStep = hovering ? step : (pointedStep == step ? nil : pointedStep)
                    }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text("CONNECTION")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.35))
                if check.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Spacer()
                if let summary = check.summary {
                    Text(summary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.green.opacity(0.8))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(check.steps) { step in
                    CheckRow(step: step)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.075)
            LinearGradient(
                colors: [Self.brand.opacity(0.22), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

private struct QuickStartStep: View {
    let step: Walkthrough.Step
    let isPointed: Bool

    private static let brand = Color(red: 0.21, green: 0.44, blue: 0.98)

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(step.id)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 20, height: 20)
                .background(Circle().fill(isPointed ? Self.brand : .white.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(step.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(isPointed ? 0.6 : 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        // Hover has to cover the whole row, including the gaps between text.
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isPointed)
    }
}

/// One diagnostic line: state glyph, what was tried, and what came back.
private struct CheckRow: View {
    let step: ConnectionCheck.Step

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            glyph
                .frame(width: 14, height: 14)

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
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }
}

private struct QuickStartButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private static let brand = Color(red: 0.21, green: 0.44, blue: 0.98)

    init(_ title: String, prominent: Bool, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(prominent ? 1 : 0.85))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(
                            prominent
                                ? Self.brand.opacity(hovering ? 1 : 0.85)
                                : Color.white.opacity(hovering ? 0.16 : 0.09)
                        )
                )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}
