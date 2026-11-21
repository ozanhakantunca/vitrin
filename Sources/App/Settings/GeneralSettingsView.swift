import AppKit
import ServiceManagement
import SwiftUI
import VitrinSystem
import VitrinCore

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmReset = false
    @State private var actionError: String?

    var body: some View {
        Form {
            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at login"), isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                .disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text(String(localized: "Launch at login is available when running from Vitrin.app."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if LoginItem.requiresApproval {
                    SettingsWarning(message: String(localized: "Approve Vitrin in System Settings → General → Login Items."))
                    Button(String(localized: "Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle(String(localized: "Show menu bar icon"), isOn: $store.settings.showMenuBarIcon)
                Toggle(String(localized: "Preview the selected window"), isOn: $store.settings.appearance.showPreview)
                Toggle(String(localized: "Three-finger swipe opens the switcher"), isOn: $store.settings.trackpadGesture)
                    .disabled(!TrackpadGestureRecognizer.isSupported)
                if store.settings.trackpadGesture && TrackpadGestureRecognizer.systemThreeFingerSwipeConflicts {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(String(localized: "macOS also uses three-finger swipes. In System Settings → Trackpad → More Gestures, set “Swipe between full-screen applications” to four fingers and “Swipe between pages” to two fingers or off."), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button(String(localized: "Open Trackpad Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Toggle(String(localized: "Check for updates automatically"), isOn: $store.settings.checkForUpdates)
            }
            Section(String(localized: "Appearance")) {
                SettingsPicker(title: String(localized: "Theme"), selection: $store.settings.appearance.theme)
                SettingsPicker(title: String(localized: "Show switcher on"), selection: $store.settings.appearance.showOnScreen)
            }
            Section(String(localized: "Config file")) {
                Text(store.configURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(String(localized: "Config file path"))
                    .accessibilityValue(store.configURL.path)
                HStack {
                    Button(String(localized: "Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                    }
                    Button(String(localized: "Open in Editor")) {
                        if !NSWorkspace.shared.open(store.configURL) {
                            actionError = String(localized: "The config file could not be opened. Choose an application for JSON files in Finder.")
                        }
                    }
                    Button(String(localized: "Reload")) { store.reloadFromDisk() }
                }
                if let actionError { SettingsWarning(message: actionError) }
            }
            Section {
                Button(String(localized: "Reset to defaults…"), role: .destructive) { confirmReset = true }
                    .disabled(store.isReadOnly)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
        .alert(String(localized: "Reset all settings?"), isPresented: $confirmReset) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Reset to defaults"), role: .destructive) {
                setLaunchAtLogin(false)
                store.resetToDefaults()
                refreshLoginItem()
            }
        } message: {
            Text(String(localized: "This replaces all shortcut profiles, exceptions, and preferences with the defaults."))
        }
    }

    private func refreshLoginItem() {
        guard LoginItem.isAvailable else { return }
        store.settings.launchAtLogin = LoginItem.isRequested
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard LoginItem.isAvailable else { return }
        actionError = nil
        LoginItem.setEnabled(enabled)
        refreshLoginItem()
        if store.settings.launchAtLogin != enabled && actionError == nil {
            actionError = String(localized: "Launch at login could not be changed. Check Login Items in System Settings.")
        }
    }
}
