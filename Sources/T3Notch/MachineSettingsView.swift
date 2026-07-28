import SwiftUI
import T3NotchCore

struct MachineSettingsCard: View {
    private enum PresentedSheet: String, Identifiable {
        case pairing
        case connectImport
        case connectPermissionWarning

        var id: String { rawValue }
    }

    @Bindable var store: AgentStore
    let onShowQuickStart: () -> Void

    @State private var presentedSheet: PresentedSheet?
    @State private var removalTarget: EnvironmentSnapshot?
    @State private var copiedPermissionFix = false

    var body: some View {
        SettingsCard("Machines") {
            if let local = store.machines.first(where: { $0.profile.source == .local }) {
                machineRow(local, isLocal: true)
            } else {
                SettingsRow(
                    "This Mac",
                    detail: "T3 Code at " + store.endpoint.baseURL.absoluteString
                ) {
                    PillButton("Reconnect") { store.bootstrap() }
                }
            }

            ForEach(store.remoteMachines, id: \.profile.environmentID) { machine in
                SettingsDivider()
                machineRow(machine, isLocal: false)
            }

            SettingsDivider()
            SettingsRow(
                "Add a machine",
                detail: "Pair over HTTPS, Tailscale, or a trusted local network."
            ) {
                PillButton("Add…") { presentedSheet = .pairing }
            }

            if store.remoteVaultLocked {
                SettingsDivider()
                SettingsRow(
                    "Remote credentials locked",
                    detail: "Unlock once to reconnect saved machines.",
                    detailIsProblem: true
                ) {
                    PillButton("Unlock") {
                        Task { await store.unlockRemoteCredentials() }
                    }
                    .disabled(store.isRemoteOperationRunning)
                }
            }

            if store.showsT3Connect {
                SettingsDivider()
                t3ConnectRow
                if store.hasImportedT3Connect {
                    ForEach(unregisteredT3ConnectEnvironments) { environment in
                        SettingsDivider()
                        t3ConnectEnvironmentRow(environment)
                    }
                }
            }

            if let message = store.remoteOperationMessage?.nilIfBlank {
                SettingsDivider()
                Text(message)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Remote connection problem: \(message)")
            }

            SettingsDivider()
            SettingsRow(
                "Quick start",
                detail: "The first-launch walkthrough, with a connection test."
            ) {
                PillButton("Show", action: onShowQuickStart)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .pairing:
                RemotePairingSheet(store: store)
            case .connectImport:
                T3ConnectImportSheet(store: store)
            case .connectPermissionWarning:
                T3ConnectPermissionWarningSheet {
                    store.copyT3ConnectPermissionFix()
                    copiedPermissionFix = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedPermissionFix = false
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove this machine?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            ),
            presenting: removalTarget
        ) { machine in
            Button("Remove \(machine.profile.label)", role: .destructive) {
                store.removeMachine(machine.profile.environmentID)
                removalTarget = nil
            }
            Button("Cancel", role: .cancel) {
                removalTarget = nil
            }
        } message: { machine in
            Text(
                "T3Notch will forget its saved endpoint and session. "
                    + "Nothing is removed from \(machine.profile.label)."
            )
        }
        .onAppear {
            store.refreshT3ConnectDetection()
        }
    }

    @ViewBuilder
    private func machineRow(_ machine: EnvironmentSnapshot, isLocal: Bool) -> some View {
        SettingsRow(
            machine.descriptor?.label?.nilIfBlank ?? machine.profile.label,
            detail: machineDetail(machine),
            detailIsProblem: machine.connectionState.isProblem
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    AccessBadge(source: machine.activeAccessPath)
                    connectionBadge(machine.connectionState)
                }
                HStack(spacing: 6) {
                    if !isLocal {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { machine.profile.enabled },
                                set: {
                                    store.setMachineEnabled(
                                        machine.profile.environmentID,
                                        enabled: $0
                                    )
                                }
                            )
                        )
                        .toggleStyle(NotchToggleStyle())
                        .labelsHidden()
                        .accessibilityLabel(
                            machine.profile.enabled
                                ? "Disable \(machine.profile.label)"
                                : "Enable \(machine.profile.label)"
                        )
                    }
                    PillButton(actionTitle(machine.connectionState)) {
                        if isLocal {
                            store.bootstrap()
                        } else {
                            switch machine.connectionState {
                            case .needsPairing, .unauthorized:
                                presentedSheet = .pairing
                            case .credentialLocked:
                                Task { await store.unlockRemoteCredentials() }
                            default:
                                store.reconnectMachine(machine.profile.environmentID)
                            }
                        }
                    }
                    if !isLocal {
                        Button {
                            removalTarget = machine
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(machine.profile.label)")
                    }
                }
            }
        }
    }

    private var t3ConnectRow: some View {
        SettingsRow(
            "T3 Connect",
            detail: store.hasImportedT3Connect
                ? connectDetail
                : store.t3ConnectImportDetail,
            detailIsProblem: !store.hasImportedT3Connect
                && store.t3ConnectImportHasProblem
        ) {
            HStack(spacing: 6) {
                if store.hasImportedT3Connect {
                    if store.t3ConnectSessionUpdateAvailable {
                        PillButton("Import again…") {
                            presentedSheet = .connectImport
                        }
                        .disabled(store.isRemoteOperationRunning)
                    }
                    PillButton(store.isRemoteOperationRunning ? "Refreshing…" : "Refresh") {
                        Task { await store.refreshT3Connect() }
                    }
                    .disabled(store.isRemoteOperationRunning)
                    PillButton("Forget") {
                        Task { await store.forgetT3Connect() }
                    }
                    .disabled(store.isRemoteOperationRunning)
                } else if store.canImportT3Connect {
                    PillButton("Import…") {
                        presentedSheet = .connectImport
                    }
                    .disabled(store.isRemoteOperationRunning)
                } else if store.canRepairT3ConnectPermissions {
                    PillButton(copiedPermissionFix ? "Copied" : "Copy fix") {
                        presentedSheet = .connectPermissionWarning
                    }
                    .disabled(store.isRemoteOperationRunning)
                    PillButton("Refresh") {
                        store.refreshT3ConnectDetection()
                    }
                } else {
                    PillButton("Refresh") {
                        store.refreshT3ConnectDetection()
                    }
                }
            }
        }
    }

    private var unregisteredT3ConnectEnvironments: [T3ConnectEnvironment] {
        let registered = Set(store.machines.map(\.profile.environmentID))
        return store.t3ConnectEnvironments.filter {
            !registered.contains($0.environmentID)
        }
    }

    private func t3ConnectEnvironmentRow(
        _ environment: T3ConnectEnvironment
    ) -> some View {
        let existing = store.machines.first {
            $0.profile.environmentID == environment.environmentID
        }
        return SettingsRow(
            environment.label,
            detail: existing.map(machineDetail)
                ?? environment.endpoint?.baseURL.absoluteString
                ?? "Linked through T3 Connect."
        ) {
            HStack(spacing: 6) {
                AccessBadge(source: existing?.activeAccessPath ?? .t3Connect)
                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            store.isT3ConnectEnvironmentEnabled(
                                environment.environmentID
                            )
                        },
                        set: {
                            store.setT3ConnectEnvironmentEnabled(
                                environment,
                                enabled: $0
                            )
                        }
                    )
                )
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
                .accessibilityLabel(
                    "Enable \(environment.label) through T3 Connect"
                )
            }
        }
    }

    private var connectDetail: String {
        let count = store.t3ConnectEnvironments.count
        let detail = count == 0
            ? "Imported. No linked machines were returned yet."
            : "\(count) linked \(count == 1 ? "machine" : "machines")."
        return store.t3ConnectSessionUpdateAvailable
            ? detail + " New T3 Code session available."
            : detail
    }

    private func machineDetail(_ machine: EnvironmentSnapshot) -> String {
        let platform = machine.descriptor?.platform?.displayName
        let version = machine.descriptor?.serverVersion
        // Machines are T3 Code servers; the local Claude and Codex sources have
        // no endpoint and live in the Agent sources card instead.
        let endpoint = machine.profile.directEndpoint
            .map { "T3 Code at " + $0.baseURL.absoluteString }
        let summary = [platform, version, endpoint].compactMap { $0?.nilIfBlank }
        let suffix = summary.isEmpty ? "" : " · " + summary.joined(separator: " · ")
        return machine.connectionState.label + suffix
    }

    private func actionTitle(_ state: EnvironmentConnectionState) -> String {
        switch state {
        case .needsPairing, .unauthorized: "Re-pair"
        case .credentialLocked: "Unlock"
        default: "Reconnect"
        }
    }

    private func connectionBadge(_ state: EnvironmentConnectionState) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.color)
                .frame(width: 5, height: 5)
            Text(state.shortLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.64))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
    }
}

private struct AccessBadge: View {
    let source: EnvironmentSource

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.66))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
            .accessibilityLabel("Access: \(label)")
    }

    private var label: String {
        switch source {
        case .local: "Local"
        case .direct: "Direct"
        case .t3Connect: "T3 Connect"
        }
    }
}

private struct RemotePairingSheet: View {
    @Bindable var store: AgentStore
    @Environment(\.dismiss) private var dismiss

    @State private var pairingURL = ""
    @State private var host = ""
    @State private var pairingCode = ""
    @State private var advanced = false
    @State private var allowsInsecureHTTP = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a machine")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(
                    "Paste the pairing link created by T3 Code. "
                        + "The one-time credential is discarded after pairing."
                )
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
            }

            if advanced {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Backend URL")
                    TextField("https://mac-mini.example.ts.net", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Backend URL")
                    fieldLabel("Pairing code")
                    SecureField("One-time pairing code", text: $pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Pairing code")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Pairing link")
                    TextField("https://…/pair#token=…", text: $pairingURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("T3 Code pairing link")
                }
            }

            Toggle("Enter a backend URL and code instead", isOn: $advanced)
                .font(.system(size: 11.5, design: .rounded))
                .toggleStyle(.checkbox)

            Toggle(
                "Allow unencrypted HTTP outside this Mac",
                isOn: $allowsInsecureHTTP
            )
            .font(.system(size: 11.5, design: .rounded))
            .toggleStyle(.checkbox)

            Text(
                "Prefer HTTPS or Tailscale. Plain HTTP can expose agent details "
                    + "and responses to anyone able to observe the network."
            )
            .font(.system(size: 10.5, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.orange.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                PillButton("Cancel") { dismiss() }
                Button {
                    submit()
                } label: {
                    Text(isSubmitting ? "Pairing…" : "Add machine")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.21, green: 0.44, blue: 0.98)))
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear {
            pairingURL = ""
            pairingCode = ""
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await store.pairRemoteMachine(
                    pairingURL: advanced ? nil : pairingURL,
                    host: advanced ? host : nil,
                    code: advanced ? pairingCode : nil,
                    allowsInsecureHTTP: allowsInsecureHTTP
                )
                pairingURL = ""
                pairingCode = ""
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

private struct T3ConnectImportSheet: View {
    @Bindable var store: AgentStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var trustedMacConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import T3 Connect")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(
                "T3Notch will ask macOS for access to T3 Code’s Safe Storage key, "
                    + "then copy the active sign-in into its own Keychain. "
                    + "It never changes T3 Code’s files, account, or linked machines."
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))
            .fixedSize(horizontal: false, vertical: true)

            T3ConnectPrivateMacWarning(
                trustedMacConfirmed: $trustedMacConfirmed
            )

            Text(
                "This compatibility integration follows T3 Code’s current Electron "
                    + "and relay formats. A future T3 Code update may require importing again."
            )
            .font(.system(size: 10.5, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PillButton("Cancel") { dismiss() }
                Button {
                    importing = true
                    Task {
                        await store.importT3Connect()
                        importing = false
                        if store.hasImportedT3Connect { dismiss() }
                    }
                } label: {
                    Text(importing ? "Importing…" : "Import")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.21, green: 0.44, blue: 0.98)))
                }
                .buttonStyle(.plain)
                .disabled(importing || !trustedMacConfirmed)
                .opacity(trustedMacConfirmed ? 1 : 0.45)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(importing)
    }
}

private struct T3ConnectPermissionWarningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trustedMacConfirmed = false
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    Text("Before changing permissions")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Text(
                    "The copied chmod 600 command restricts T3 Code’s session file "
                        + "to your current macOS account. It does not make a public "
                        + "or shared Mac safe."
                )
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            }

            T3ConnectPrivateMacWarning(
                trustedMacConfirmed: $trustedMacConfirmed
            )

            Text(
                "T3Notch only copies the command. You choose whether to run it "
                    + "in Terminal, then return here and press Refresh."
            )
            .font(.system(size: 10.5, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PillButton("Cancel") { dismiss() }
                Button {
                    onCopy()
                    dismiss()
                } label: {
                    Text("Copy command")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                Color(red: 0.21, green: 0.44, blue: 0.98)
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!trustedMacConfirmed)
                .opacity(trustedMacConfirmed ? 1 : 0.45)
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("T3 Connect security warning")
    }
}

private struct T3ConnectPrivateMacWarning: View {
    @Binding var trustedMacConfirmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Private, trusted Macs only")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.95))

            Text(
                "Do not continue on a public, shared, borrowed, or otherwise "
                    + "untrusted Mac. Anyone who can use this macOS account may "
                    + "be able to access your T3 Connect session and linked agents."
            )
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "This is a private Mac I control.",
                isOn: $trustedMacConfirmed
            )
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .toggleStyle(.checkbox)
            .accessibilityHint(
                "Required before copying the permission command or importing T3 Connect."
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

private extension EnvironmentConnectionState {
    var label: String {
        switch self {
        case .connecting: "Connecting."
        case .connected: "Connected."
        case let .offline(reason): reason.map { "Offline: \($0)" } ?? "Offline."
        case .unauthorized: "Session expired."
        case .needsPairing: "Pairing required."
        case .credentialLocked: "Credentials locked."
        case let .incompatible(reason): "Incompatible: \(reason)"
        }
    }

    var shortLabel: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Online"
        case .offline: "Offline"
        case .unauthorized, .needsPairing: "Re-pair"
        case .credentialLocked: "Locked"
        case .incompatible: "Problem"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .offline: .white.opacity(0.3)
        case .unauthorized, .needsPairing, .credentialLocked, .incompatible: .orange
        }
    }

    var isProblem: Bool {
        switch self {
        case .unauthorized, .needsPairing, .credentialLocked, .incompatible: true
        default: false
        }
    }
}
