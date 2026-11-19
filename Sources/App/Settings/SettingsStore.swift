import Combine
import Foundation
import VitrinCore

/// Single source of truth for `AppSettings` at runtime. The Settings UI edits `settings`;
/// every change is validated, saved to `~/.config/vitrin/config.json` and broadcast.
/// External edits to the file (dotfiles, text editor) arrive via `reloadFromDisk()`.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue, !isApplyingDiskState else { return }
            persist()
            onChange?(settings)
        }
    }
    /// Problems found by `AppSettings.validate()` for the current settings (shown in the UI).
    @Published private(set) var issues: [ValidationIssue] = []
    /// Last load/save error, if any (shown in the UI).
    @Published private(set) var lastError: String?
    /// True when the file was written by a newer Vitrin: never auto-save over it.
    @Published private(set) var isReadOnly = false

    /// Called after every effective change (UI edit or disk reload).
    var onChange: ((AppSettings) -> Void)?

    let store: ConfigStore
    private var isApplyingDiskState = false

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
        let result = store.load()
        settings = result.settings
        apply(result, initial: true)
    }

    var configURL: URL { store.url }

    /// Re-reads the config file (called by the file watcher or "Reload" in the UI).
    func reloadFromDisk() {
        let result = store.load()
        guard result.settings != settings || result.error != nil else { return }
        isApplyingDiskState = true
        settings = result.settings
        isApplyingDiskState = false
        apply(result, initial: false)
        onChange?(settings)
    }

    func resetToDefaults() {
        settings = .defaults
    }

    private func apply(_ result: ConfigLoadResult, initial: Bool) {
        isReadOnly = result.isFromNewerVersion
        lastError = result.error.map { String(describing: $0) }
        issues = result.settings.validate()
        for warning in result.warnings { Log.app.warning("Config: \(warning, privacy: .public)") }
        if let lastError { Log.app.error("Config error: \(lastError, privacy: .public)") }
        // Write a starter config so users can find and edit it.
        if initial, result.origin == .defaultsNoFile, !result.isFromNewerVersion { persist() }
    }

    private func persist() {
        issues = settings.validate()
        guard !isReadOnly else {
            lastError = "config.json was written by a newer Vitrin; changes are not saved."
            return
        }
        do {
            try store.save(settings)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Could not save config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
