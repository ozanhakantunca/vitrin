import AppKit
import ServiceManagement

/// Launch-at-login through `SMAppService.mainApp`.
@MainActor
enum LoginItem {
    /// Set once Vitrin has turned launch at login on by default, so a later "off" is never overridden.
    static let defaultAppliedKey = "didApplyLaunchAtLoginDefault"

    /// `SMAppService.mainApp` only works for a bundled app.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return status == .enabled
    }

    static var requiresApproval: Bool { isAvailable && status == .requiresApproval }

    /// On, or waiting for the user's approval in System Settings.
    static var isRequested: Bool { isEnabled || requiresApproval }

    /// First launch (of any version that has this): turn launch at login on, like AltTab does.
    static func applyDefaultOnce(defaults: UserDefaults = .standard) {
        guard LoginItemPolicy.shouldEnableByDefault(
            isAvailable: isAvailable,
            defaultApplied: defaults.bool(forKey: defaultAppliedKey),
            isRequested: isAvailable && isRequested
        ) else {
            if isAvailable { defaults.set(true, forKey: defaultAppliedKey) }
            return
        }
        defaults.set(true, forKey: defaultAppliedKey)
        do {
            try SMAppService.mainApp.register()
            Log.loginItem.info("Launch at login turned on by default")
        } catch {
            Log.loginItem.error("Could not turn on launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Turns launch at login on or off. Turning it on may need approval in System Settings, which is
    /// opened when `openSettingsIfNeeded`. Returns false if the change failed.
    @discardableResult
    static func setEnabled(_ enabled: Bool, openSettingsIfNeeded: Bool = true) -> Bool {
        guard isAvailable else { return false }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
                if service.status == .requiresApproval && openSettingsIfNeeded {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            return true
        } catch {
            Log.loginItem.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func toggle() {
        setEnabled(!isRequested)
    }
}

/// Pure decisions for launch at login (unit-tested).
enum LoginItemPolicy {
    static func shouldEnableByDefault(isAvailable: Bool, defaultApplied: Bool, isRequested: Bool) -> Bool {
        isAvailable && !defaultApplied && !isRequested
    }

    /// The system change a config edit asks for: `true` register, `false` unregister, `nil` nothing.
    /// Only an edit of `launchAtLogin` itself counts, so a stale value (the user changed it in System
    /// Settings) is never re-applied when some other setting changes.
    static func change(previousConfig: Bool, newConfig: Bool, isRequested: Bool) -> Bool? {
        guard newConfig != previousConfig, newConfig != isRequested else { return nil }
        return newConfig
    }
}
