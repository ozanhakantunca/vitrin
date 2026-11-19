import Foundation
import VitrinPrivate

/// Restores Mission Control shortcuts that Vitrin temporarily enabled.
@MainActor
final class TemporarySpaceHotKeys {
    static let defaultsKey = "TemporarilyEnabledSpaceHotKeys"

    private let backend: SymbolicHotKeyBackend
    private let defaults: UserDefaults
    private let restoreDelay: Duration
    private var restoreTasks: [SymbolicHotKey: Task<Void, Never>] = [:]

    init(backend: SymbolicHotKeyBackend, defaults: UserDefaults, restoreDelay: Duration = .milliseconds(750)) {
        self.backend = backend
        self.defaults = defaults
        self.restoreDelay = restoreDelay
        restoreAll()
    }

    func post(whileEnabled hotKey: SymbolicHotKey, _ postEvents: () -> Void) -> Bool {
        guard let enabled = backend.isEnabled(hotKey) else { return false }
        var recorded = recordedHotKeys
        if !enabled {
            recorded.insert(hotKey)
            // Persist before enabling so a crash between these calls is recoverable.
            guard record(recorded) else { return false }
            guard backend.setEnabled(true, [hotKey]) else {
                restore(hotKey)
                return false
            }
        }

        postEvents()
        if recorded.contains(hotKey) {
            restoreTasks[hotKey]?.cancel()
            // The WindowServer matches posted events asynchronously.
            restoreTasks[hotKey] = Task {
                do { try await Task.sleep(for: restoreDelay) } catch { return }
                restoreTasks.removeValue(forKey: hotKey)
                restore(hotKey)
            }
        }
        return true
    }

    func restoreAll() {
        for task in restoreTasks.values { task.cancel() }
        restoreTasks.removeAll()
        for hotKey in recordedHotKeys { restore(hotKey) }
    }

    private func restore(_ hotKey: SymbolicHotKey) {
        guard backend.isEnabled(hotKey) == false || backend.setEnabled(false, [hotKey]) else { return }
        record(recordedHotKeys.subtracting([hotKey]))
    }

    private var recordedHotKeys: Set<SymbolicHotKey> {
        let ids = defaults.array(forKey: Self.defaultsKey) as? [Int] ?? []
        let spaceHotKeys = SymbolicHotKey.switchToDesktop + [.moveLeftASpace, .moveRightASpace]
        return Set(spaceHotKeys.filter { ids.contains(Int($0.rawValue)) })
    }

    @discardableResult
    private func record(_ hotKeys: Set<SymbolicHotKey>) -> Bool {
        if hotKeys.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(hotKeys.map { Int($0.rawValue) }.sorted(), forKey: Self.defaultsKey)
        }
        return defaults.synchronize()
    }
}
