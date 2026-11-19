import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VitrinCore

@MainActor
struct ExceptionsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedID: String?
    @State private var runningApps: [ExceptionApp] = []
    @State private var actionError: String?

    private var rows: [ExceptionApp] {
        // Invalid hand-edited configs can contain duplicate bundle IDs; render
        // one editable row and surface the validation warning below the table.
        var seen = Set<String>()
        return store.settings.appExceptions.compactMap {
            guard seen.insert($0.bundleIdentifier).inserted else { return nil }
            return ExceptionApp(bundleIdentifier: $0.bundleIdentifier)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Choose which apps appear in the switcher and which apps receive their own shortcuts."))
                .font(.callout).foregroundStyle(.secondary)
            Table(rows, selection: $selectedID) {
                TableColumn(String(localized: "Application")) { app in
                    HStack {
                        Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(app.name).lineLimit(1)
                            Text(app.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(app.id)
                }
                .width(min: 170, ideal: 230)
                TableColumn(String(localized: "Hide from switcher")) { app in
                    SettingsPicker(title: String(localized: "Hide \(app.name)"), selection: binding(app.id, \.hide, fallback: .never))
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "Hide \(app.name) from switcher"))
                }
                .width(min: 170, ideal: 210)
                TableColumn(String(localized: "Ignore shortcuts")) { app in
                    Toggle(String(localized: "Ignore shortcuts when \(app.name) is frontmost"), isOn: binding(app.id, \.ignoreShortcutsWhenFrontmost, fallback: false))
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .help(String(localized: "Ignore shortcuts when frontmost"))
                }
                .width(min: 120, ideal: 150)
            }
            .accessibilityLabel(String(localized: "App exceptions"))
            if rows.isEmpty {
                Text(String(localized: "No app exceptions. Add an app below."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(duplicateWarnings, id: \.self) { SettingsWarning(message: $0) }
            if let actionError { SettingsWarning(message: actionError) }
            HStack {
                Menu {
                    if runningApps.isEmpty {
                        Text(String(localized: "No running apps available"))
                    }
                    ForEach(runningApps) { app in
                        Button { add(app.id) } label: {
                            Label { Text(app.name) } icon: {
                                Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                            }
                        }
                        .disabled(store.settings.appExceptions.contains { $0.bundleIdentifier == app.id })
                    }
                } label: {
                    Label(String(localized: "Add running app"), systemImage: "plus")
                }
                .fixedSize()
                Button(String(localized: "Choose app…")) { chooseApp() }
                Spacer()
                Button(String(localized: "Remove"), role: .destructive) {
                    guard let selectedID else { return }
                    store.settings.appExceptions.removeAll { $0.bundleIdentifier == selectedID }
                    self.selectedID = nil
                }
                .disabled(selectedID == nil)
            }
        }
        .padding(16)
        .onAppear { refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
        .onChange(of: store.settings.appExceptions.map(\.bundleIdentifier)) { ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private func binding<Value>(_ bundleID: String, _ keyPath: WritableKeyPath<AppException, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            store.settings.appExceptions.first { $0.bundleIdentifier == bundleID }?[keyPath: keyPath] ?? fallback
        }, set: { value in
            guard let index = store.settings.appExceptions.firstIndex(where: { $0.bundleIdentifier == bundleID }) else { return }
            store.settings.appExceptions[index][keyPath: keyPath] = value
        })
    }

    private var duplicateWarnings: [String] {
        store.issues.compactMap {
            if case .duplicateAppException(let bundleID) = $0 {
                return String(localized: "The config contains multiple exceptions for \(bundleID). Remove the app and add it again to keep one entry.")
            }
            return nil
        }
    }

    private func refreshRunningApps() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.activationPolicy != .prohibited ? app.bundleIdentifier : nil
        })
        runningApps = ids.map { ExceptionApp(bundleIdentifier: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func add(_ bundleID: String) {
        actionError = nil
        if !store.settings.appExceptions.contains(where: { $0.bundleIdentifier == bundleID }) {
            store.settings.appExceptions.append(AppException(bundleIdentifier: bundleID))
        }
        selectedID = bundleID
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an app")
        panel.prompt = String(localized: "Add app")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
                actionError = String(localized: "This app has no bundle identifier and cannot be added.")
                return
            }
            add(bundleID)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

@MainActor
private struct ExceptionApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(bundleIdentifier: String) {
        id = bundleIdentifier
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            name = FileManager.default.displayName(atPath: url.path)
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleIdentifier
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 24, height: 24))
        }
    }
}
