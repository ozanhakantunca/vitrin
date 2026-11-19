import AppKit
import ServiceManagement

/// Launch-at-login through `SMAppService.mainApp`.
@MainActor
enum LoginItem {
    /// `SMAppService.mainApp` only works for a bundled app.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// On, or waiting for the user's approval in System Settings.
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return status == .enabled
    }

    static var requiresApproval: Bool { isAvailable && status == .requiresApproval }

    static func toggle() {
        guard isAvailable else { return }
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            Log.loginItem.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
