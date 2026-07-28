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

                AgentSourcesCard(store: store, settings: settings)

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

/// Which agent runtimes the notch watches, what each of them is doing right
/// now, and the Claude Code hooks that make its permission prompts answerable
/// from up there.
private struct AgentSourcesCard: View {
    let store: AgentStore
    @Bindable var settings: SettingsStore

    @State private var hookStatus: ClaudeHookStatus = .notInstalled
    @State private var portText = ""
    @State private var showsTokenSheet = false
    @FocusState private var portFocused: Bool

    var body: some View {
        SettingsCard("Agent sources") {
            SettingsToggle(
                "Watch T3 Code",
                detail: detail(for: .t3),
                isOn: settings.binding(\.watchT3),
                detailIsProblem: isProblem(.t3)
            )
            if settings.values.watchT3, store.sourceProblems[.t3] != nil {
                SettingsDivider()
                SettingsRow("T3 Code token", detail: "Paste a fresh session token.") {
                    PillButton("Fix…") { showsTokenSheet = true }
                }
            }
            SettingsDivider()
            SettingsToggle(
                "Watch Claude Code",
                detail: detail(for: .claude),
                isOn: settings.binding(\.watchClaude),
                detailIsProblem: isProblem(.claude)
            )
            SettingsDivider()
            SettingsToggle(
                "Watch Codex",
                detail: detail(for: .codex),
                isOn: settings.binding(\.watchCodex),
                detailIsProblem: isProblem(.codex)
            )

            SettingsDivider()
            SettingsRow(
                "Claude Code hooks",
                detail: hookDetail,
                detailIsProblem: hookDetailIsProblem
            ) {
                HStack(spacing: 6) {
                    PillButton(installLabel) {
                        store.installClaudeHooks()
                        hookStatus = store.claudeHookStatus()
                    }
                    if hookStatus != .notInstalled {
                        PillButton("Remove") {
                            store.removeClaudeHooks()
                            hookStatus = store.claudeHookStatus()
                        }
                    }
                }
            }
            .disabled(!settings.values.watchClaude)

            SettingsDivider()
            SettingsToggle(
                "Answer permission prompts in the notch",
                detail: listenerDetail,
                isOn: settings.binding(\.claudeHookListener),
                detailIsProblem: store.claudeHookProblem != nil
            )
            .disabled(!settings.values.watchClaude)

            SettingsDivider()
            SettingsRow(
                "Hook port",
                detail: "Reinstall the hooks after changing this — they carry the port."
            ) {
                TextField("", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 72)
                    .focused($portFocused)
                    .onSubmit { commitPort() }
                    // Clicking away is as much a commit as pressing return, and
                    // an uncommitted port would not match the installed hooks.
                    .onChange(of: portFocused) { _, focused in
                        if !focused { commitPort() }
                    }
                    .accessibilityLabel("Claude Code hook port")
            }
            .disabled(!settings.values.watchClaude)
        }
        .onAppear {
            hookStatus = store.claudeHookStatus()
            portText = String(settings.values.claudeHookPort)
        }
        .sheet(isPresented: $showsTokenSheet) {
            T3TokenSheet(store: store)
        }
    }

    // MARK: - Status lines

    private func detail(for source: AgentSource) -> String {
        guard isWatched(source) else { return "Not watched." }
        if let problem = store.sourceProblems[source]?
            .split(separator: "\n").first.map(String.init)
        {
            return problem
        }
        switch store.sourceStatuses[source] ?? .connecting {
        case .connected:
            let count = store.localSessionCount(for: source)
            return count == 0
                ? "Connected · nothing running right now"
                : "Connected · \(count) \(count == 1 ? "session" : "sessions")"
        case .connecting:
            return "Connecting…"
        case .disconnected:
            return notRunningDetail(source)
        case .unauthorized:
            return "Not authorised — paste a token."
        }
    }

    private func notRunningDetail(_ source: AgentSource) -> String {
        switch source {
        case .t3: "T3 Code is not running."
        case .claude: "No ~/.claude sessions to read."
        case .codex: "No ~/.codex sessions to read."
        }
    }

    private func isWatched(_ source: AgentSource) -> Bool {
        switch source {
        case .t3: settings.values.watchT3
        case .claude: settings.values.watchClaude
        case .codex: settings.values.watchCodex
        }
    }

    private func isProblem(_ source: AgentSource) -> Bool {
        isWatched(source) && store.sourceProblems[source] != nil
    }

    private var installLabel: String {
        hookStatus == .notInstalled ? "Install hooks" : "Reinstall"
    }

    private var hookDetail: String {
        if let message = store.claudeHookMessage { return message }
        switch hookStatus {
        case let .installed(port):
            return "Installed on port \(port). Running sessions pick them up right away."
        case .notInstalled:
            return "Not installed — approvals stay in the terminal. "
                + "Installing only appends to ~/.claude/settings.json."
        case let .partial(missing):
            return missing.isEmpty
                ? "Installed on more than one port. Install them again."
                : "Missing \(missing.joined(separator: ", ")). Install them again."
        case let .unreadable(reason):
            return "Could not read ~/.claude/settings.json: \(reason)"
        }
    }

    private var hookDetailIsProblem: Bool {
        if store.claudeHookMessage != nil { return true }
        switch hookStatus {
        case .installed, .notInstalled: return false
        case .partial, .unreadable: return true
        }
    }

    private var listenerDetail: String {
        if let problem = store.claudeHookProblem { return problem }
        return "Listening on 127.0.0.1:\(settings.values.claudeHookPort)."
    }

    private func commitPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              SettingsStore.portRange.contains(port)
        else {
            portText = String(settings.values.claudeHookPort)
            return
        }
        settings.set(\.claudeHookPort, to: port)
    }
}

/// The token form, for when T3 Code is the only source that is down and the
/// notch's own onboarding panel therefore never appears.
private struct T3TokenSheet: View {
    let store: AgentStore
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""

    private let tokenCommand = "npx -y t3@latest auth session issue --token-only"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect T3 Code")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(store.sourceProblems[.t3] ?? "Paste a bearer token to connect.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Bearer token", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            HStack {
                PillButton("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tokenCommand, forType: .string)
                }
                Spacer()
                PillButton("Cancel") { dismiss() }
                Button {
                    store.submitManualToken(token)
                    dismiss()
                } label: {
                    Text("Connect")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.21, green: 0.44, blue: 0.98)))
                }
                .buttonStyle(.plain)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
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
