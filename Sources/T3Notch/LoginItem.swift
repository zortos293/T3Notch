import Foundation
import ServiceManagement

/// Launch-at-login, reported honestly.
///
/// `SMAppService` refuses bundles it does not trust, and this app is ad-hoc
/// signed, so registration can genuinely fail. The failure is surfaced instead of
/// leaving a switch that looks on and does nothing.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns nil on success, or a message to show the user.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            let action = enabled ? "enable" : "disable"
            return "Could not \(action) launch at login: \(error.localizedDescription)"
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
