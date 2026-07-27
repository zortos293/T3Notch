import AppKit
import SwiftUI
import T3NotchCore

/// The control panel. Styled like the notch it configures rather than like a
/// stock macOS settings window: dark, rounded cards, the brand blue for controls.
struct SettingsView: View {
    let store: AgentStore
    @Bindable var settings: SettingsStore
    let updater: Updater
    /// Reopens the first-launch quick start.
    var onShowQuickStart: () -> Void = {}

    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var loginItemProblem: String?

    private static let brand = Color(red: 0.21, green: 0.44, blue: 0.98)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                SettingsCard("Attention") {
                    SettingsToggle(
                        "Open on questions",
                        detail: "Expand the notch by itself when an agent needs an answer.",
                        isOn: settings.binding(\.expandOnAttention)
                    )
                    SettingsDivider()
                    SettingsToggle(
                        "Play a sound",
                        detail: "A single Tink when a new approval or question arrives.",
                        isOn: settings.binding(\.soundOnAttention)
                    )
                    SettingsDivider()
                    SettingsToggle(
                        "Keep finished agents pinned",
                        detail:
                            "A Done card stays until you open it in T3 Code or dismiss it. Off hides finished agents right away.",
                        isOn: settings.binding(\.keepFinishedUntilReviewed)
                    )
                }

                SettingsCard("Milestones") {
                    SettingsToggle(
                        "Celebrate finished tasks and merges",
                        detail: "Banner, tick animation, and the panel opening for a few seconds.",
                        isOn: settings.binding(\.celebrateMilestones)
                    )
                    SettingsDivider()
                    SettingsToggle(
                        "Confetti on merges",
                        detail: "Only on landed branches, never on ordinary task completion.",
                        isOn: settings.binding(\.confetti)
                    )
                    .disabled(!settings.values.celebrateMilestones)
                    SettingsDivider()
                    SettingsRow(
                        "Preview",
                        detail: "See both animations without waiting for the real thing."
                    ) {
                        HStack(spacing: 6) {
                            PillButton("Tasks") {
                                store.celebrate(.tasksComplete(count: 4))
                            }
                            PillButton("Merge") {
                                store.celebrate(
                                    .branchMerged(branch: "t3code/preview", into: "main")
                                )
                            }
                        }
                    }
                    .disabled(!settings.values.celebrateMilestones)
                }

                SettingsCard("Landed branches") {
                    SettingsToggle(
                        "Watch branches for merges",
                        detail: "Checks each agent's branch every 15s, and keeps watching for 12h "
                            + "after the thread leaves the notch.",
                        isOn: settings.binding(\.watchMerges)
                    )
                    SettingsDivider()
                    SettingsToggle(
                        "Ask GitHub about pull requests",
                        detail: forgeDetail,
                        isOn: settings.binding(\.askForgeForMerges)
                    )
                    .disabled(!settings.values.watchMerges)
                }

                SettingsCard("Layout") {
                    SettingsStepperRow(
                        "Activity rows",
                        detail: "Recent commands and file changes shown at once.",
                        value: settings.binding(\.activityRows),
                        range: SettingsStore.rowRange
                    )
                    SettingsDivider()
                    SettingsStepperRow(
                        "Task rows",
                        detail: "Plan steps shown before the list turns into “+N more”.",
                        value: settings.binding(\.taskRows),
                        range: SettingsStore.rowRange
                    )
                    SettingsDivider()
                    SettingsRow("Display", detail: "Which screen's notch to live under.") {
                        Picker("", selection: settings.binding(\.displayName)) {
                            Text("Automatic").tag(String?.none)
                            ForEach(settings.availableDisplays, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 190)
                    }
                }

                SettingsCard("System") {
                    SettingsToggle(
                        "Launch at login",
                        detail: loginItemProblem
                            ?? (LoginItem.requiresApproval
                                ? "Waiting for approval in System Settings › Login Items."
                                : "Start T3Notch when you log in."),
                        isOn: Binding(
                            get: { loginItemEnabled },
                            set: { wanted in
                                loginItemProblem = LoginItem.setEnabled(wanted)
                                loginItemEnabled = LoginItem.isEnabled
                            }
                        ),
                        detailIsProblem: loginItemProblem != nil
                    )
                    if LoginItem.requiresApproval || loginItemProblem != nil {
                        SettingsDivider()
                        SettingsRow("Login Items", detail: "Approve or inspect it yourself.") {
                            PillButton("Open System Settings") {
                                LoginItem.openSystemSettings()
                            }
                        }
                    }
                }

                SettingsCard("Opening threads") {
                    SettingsToggle(
                        "Open in the T3 Code app",
                        detail: desktopAppDetail,
                        isOn: settings.binding(\.openInDesktopApp)
                    )
                }

                SettingsCard("Updates") {
                    SettingsRow(
                        "T3Notch \(updater.versionLabel)",
                        detail: updater.status.summary,
                        detailIsProblem: updater.status.isProblem
                    ) {
                        UpdateControls(updater: updater)
                    }
                    if updater.canUpdate {
                        SettingsDivider()
                        SettingsToggle(
                            "Check automatically",
                            detail: "Shortly after launch, then every six hours.",
                            isOn: settings.binding(\.automaticUpdates)
                        )
                        SettingsDivider()
                        SettingsToggle(
                            "Download in the background",
                            detail:
                                "Fetch the new build as soon as it appears. Installing still waits "
                                + "for you, since it restarts the app.",
                            isOn: settings.binding(\.automaticDownload)
                        )
                        .disabled(!settings.values.automaticUpdates)
                        SettingsDivider()
                        SettingsToggle(
                            "Include pre-releases",
                            detail:
                                "Also take releases marked pre-release, the way T3 Code's nightly "
                                + "channel does.",
                            isOn: prereleaseChannel
                        )
                    }
                }

                MachineSettingsCard(store: store, onShowQuickStart: onShowQuickStart)

                HStack {
                    Spacer()
                    PillButton("Reset to defaults") {
                        settings.resetToDefaults()
                    }
                }
                .padding(.top, 2)
            }
            // Top inset clears the floating traffic lights.
            .padding(.top, 36)
            .padding([.horizontal, .bottom], 18)
        }
        .background(background)
        .tint(Self.brand)
        .onAppear {
            loginItemEnabled = LoginItem.isEnabled
        }
    }

    private var prereleaseChannel: Binding<Bool> {
        Binding(
            get: { settings.values.updateChannel == .prerelease },
            set: { settings.set(\.updateChannel, to: $0 ? .prerelease : .stable) }
        )
    }

    private var forgeDetail: String {
        "A squash merge rewrites commits, so asking gh is the only way to see it. "
            + "Off means only real merge commits and fast-forwards are noticed."
    }

    private var desktopAppDetail: String {
        let base =
            "“Open in T3 Code” brings the desktop app forward instead of opening a browser tab. "
            + "T3 Code has no deep link to a single thread, so it lands on whatever it was showing."
        return T3CodeApp.isRunning ? base : base + " Not running right now, so the browser is used."
    }

    private var connectionTitle: String {
        switch store.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .unauthorized: "Not authorised"
        case .disconnected: "Disconnected"
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            NotchShape(topRadius: 5, bottomRadius: 9)
                .fill(
                    LinearGradient(
                        colors: [Self.brand.opacity(0.95), Self.brand.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 44, height: 22)
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(.cyan)
                        .frame(width: 5, height: 5)
                        .padding(.bottom, 4)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("T3Notch")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Control panel")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.075)
            LinearGradient(
                colors: [Self.brand.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

/// Whatever the update state calls for: a check, a download, or a restart.
private struct UpdateControls: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 6) {
            switch updater.status {
            case .unsupported:
                PillButton("Releases") {
                    NSWorkspace.shared.open(updater.releasesPageURL)
                }
            case let .available(release):
                notesButton(release)
                PillButton("Download") { updater.download(release) }
            case let .downloading(_, fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 78)
                PillButton("Cancel") { updater.cancel() }
            case let .readyToInstall(release, _):
                notesButton(release)
                PillButton("Install and relaunch") { updater.install() }
            case .installing:
                ProgressView().controlSize(.small)
            default:
                PillButton(updater.status == .checking ? "Checking…" : "Check now") {
                    Task { await updater.check() }
                }
                .disabled(updater.isBusy)
            }
        }
    }

    private func notesButton(_ release: UpdateRelease) -> some View {
        PillButton("What's new") {
            NSWorkspace.shared.open(release.pageURL)
        }
    }
}

/// A titled group of rows on a rounded card.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.35))

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(height: 1)
            .padding(.vertical, 9)
    }
}

/// Label, explanation, and whatever control the row needs on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    var detailIsProblem = false
    @ViewBuilder let control: Control

    init(
        _ title: String,
        detail: String? = nil,
        detailIsProblem: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.detailIsProblem = detailIsProblem
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(
                            detailIsProblem ? Color.orange.opacity(0.9) : .white.opacity(0.4)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            control
                .padding(.top, 1)
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    var detailIsProblem = false

    init(
        _ title: String,
        detail: String? = nil,
        isOn: Binding<Bool>,
        detailIsProblem: Bool = false
    ) {
        self.title = title
        self.detail = detail
        _isOn = isOn
        self.detailIsProblem = detailIsProblem
    }

    var body: some View {
        SettingsRow(title, detail: detail, detailIsProblem: detailIsProblem) {
            Toggle("", isOn: $isOn)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
        }
    }
}

/// The panel's own switch: a stock macOS one would fight the dark rounded cards,
/// and this dims itself when the row is disabled.
struct NotchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    private static let on = Color(red: 0.21, green: 0.44, blue: 0.98)

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Self.on : Color.white.opacity(0.13))
                .overlay(
                    Capsule().stroke(.white.opacity(configuration.isOn ? 0.18 : 0.09), lineWidth: 1)
                )
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .padding(2.5)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                }
                .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Minus/value/plus, so a count does not need a stock macOS stepper.
private struct SettingsStepperRow: View {
    let title: String
    let detail: String?
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(
        _ title: String,
        detail: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) {
        self.title = title
        self.detail = detail
        _value = value
        self.range = range
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            HStack(spacing: 0) {
                stepButton("minus", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                }
                Text("\(value)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 26)
                    .contentTransition(.numericText())
                stepButton("plus", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + 1)
                }
            }
            .background(
                Capsule().fill(.white.opacity(0.08))
            )
        }
    }

    private func stepButton(
        _ symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct PillButton: View {
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
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(.white.opacity(hovering ? 0.16 : 0.09))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
