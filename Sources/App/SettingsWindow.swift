import AppKit
import SwiftUI
import VitrinCore

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: SettingsStore) {
        window = NSWindow(contentViewController: NSHostingController(rootView: VitrinSettingsView(store: store)))
        window.title = String(localized: "Vitrin Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 520))
        window.contentMinSize = NSSize(width: 700, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private struct VitrinSettingsView: View {
    @ObservedObject var store: SettingsStore

    private var colorScheme: ColorScheme? {
        switch store.settings.appearance.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.isReadOnly || store.lastError != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if store.isReadOnly {
                        SettingsWarning(message: String(localized: "This config was created by a newer Vitrin. Changes cannot be saved."))
                    }
                    if let error = store.lastError {
                        SettingsWarning(message: String(localized: "Config error: \(error)"))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            TabView {
                GeneralSettingsView(store: store)
                    .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                ShortcutsSettingsView(store: store)
                    .tabItem { Label(String(localized: "Shortcuts"), systemImage: "keyboard") }
                ExceptionsSettingsView(store: store)
                    .tabItem { Label(String(localized: "Exceptions"), systemImage: "app.badge") }
                AboutSettingsView()
                    .tabItem { Label(String(localized: "About"), systemImage: "info.circle") }
            }
            .padding(12)
        }
        .preferredColorScheme(colorScheme)
        .frame(minWidth: 700, minHeight: 460)
    }
}

@MainActor
private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? VitrinCore.version
    }

    var body: some View {
        Form {
            Section {
                Label(String(localized: "Vitrin"), systemImage: "rectangle.on.rectangle")
                    .font(.largeTitle)
                Text(String(localized: "Version \(version)"))
                Text(String(localized: "A free, open-source macOS window switcher. All features and unlimited shortcut profiles are free."))
            }
            Section(String(localized: "License and credits")) {
                Text(String(localized: "Licensed under the GNU General Public License v3.0 only (GPL-3.0-only)."))
                Text(String(localized: "Inspired by AltTab. Vitrin is an independent project and is not affiliated with AltTab."))
                Link(String(localized: "Vitrin on GitHub"), destination: URL(string: "https://github.com/ozanhakantunca/vitrin")!)
            }
        }
        .formStyle(.grouped)
    }
}
