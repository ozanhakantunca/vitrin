// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Optional ⌘⇥ takeover: the Dock consumes ⌘⇥ / ⌘⇧⇥ in the WindowServer's symbolic-hotkey layer before any
// event tap sees it, so a profile bound to ⌘⇥ only works while those symbolic hotkeys are disabled.
// AltTab does the same (`setNativeCommandTabEnabled`, github.com/lwouis/alt-tab-macos, GPL-3.0).
//
// Disabling persists in the WindowServer after Vitrin exits, so restoring is guaranteed in layers:
// 1. `apply(profiles:)` restores as soon as no enabled profile needs ⌘⇥ any more;
// 2. `restoreAll()` from `applicationWillTerminate` (normal quit);
// 3. SIGTERM / SIGINT handlers (installed when something is first disabled) restore, then re-raise;
// 4. the set of hotkeys *Vitrin* disabled is written to UserDefaults **before** disabling and cleared only
//    after a successful restore, so `recoverFromPreviousRun()` at the next launch repairs a crash / SIGKILL.
// Only hotkeys that were enabled when Vitrin disabled them are ever re-enabled: a ⌘⇥ the user had turned off
// themselves stays off.

import Darwin
import Dispatch
import Foundation
import VitrinCore
import VitrinPrivate

/// The symbolic-hotkey layer, injectable so tests never touch the real system.
public protocol SymbolicHotKeyBackend: Sendable {
    /// `nil` if the state can't be queried.
    func isEnabled(_ hotKey: SymbolicHotKey) -> Bool?
    /// Returns false if unavailable or if any call failed.
    func setEnabled(_ enabled: Bool, _ hotKeys: [SymbolicHotKey]) -> Bool
}

/// The real backend (private CGS calls via `SymbolicHotKeys`). **Changes persistent system state.**
public struct SystemSymbolicHotKeyBackend: SymbolicHotKeyBackend {
    public init() {}
    public func isEnabled(_ hotKey: SymbolicHotKey) -> Bool? { SymbolicHotKeys.isEnabled(hotKey) }
    public func setEnabled(_ enabled: Bool, _ hotKeys: [SymbolicHotKey]) -> Bool {
        SymbolicHotKeys.setEnabled(enabled, hotKeys)
    }
}

@MainActor
public final class HotkeyTakeover {
    /// UserDefaults key holding the raw ids of the symbolic hotkeys Vitrin disabled and has not restored yet.
    public nonisolated static let defaultsKey = "DisabledSymbolicHotKeys"

    private let backend: SymbolicHotKeyBackend
    private let defaults: UserDefaults
    private let handlesTerminationSignals: Bool
    private var signalSources: [DispatchSourceSignal] = []

    /// - Parameters:
    ///   - handlesTerminationSignals: install SIGTERM/SIGINT handlers the first time a hotkey is disabled.
    ///     Tests pass `false`.
    public init(
        backend: SymbolicHotKeyBackend = SystemSymbolicHotKeyBackend(),
        defaults: UserDefaults = .standard,
        handlesTerminationSignals: Bool = true
    ) {
        self.backend = backend
        self.defaults = defaults
        self.handlesTerminationSignals = handlesTerminationSignals
    }

    /// Symbolic hotkeys currently disabled by Vitrin (persisted, so this includes a crashed previous run
    /// that `recoverFromPreviousRun()` hasn't repaired).
    public var disabledHotKeys: Set<SymbolicHotKey> {
        Self.recorded(in: defaults)
    }

    /// Whether any enabled profile is triggered by ⌘⇥ (or ⌘⇧⇥).
    public nonisolated static func needsTakeover(_ profiles: [ShortcutProfile]) -> Bool {
        profiles.contains { profile in
            guard profile.isEnabled, let trigger = profile.trigger else { return false }
            return trigger.modifiers.subtracting(.shift) == .command
                && trigger.key.possibleKeyCodes.contains(KeyCode.tab)
        }
    }

    /// Disables the native app switcher while an enabled profile needs ⌘⇥; restores it otherwise.
    public func apply(profiles: [ShortcutProfile]) {
        guard Self.needsTakeover(profiles) else {
            restoreAll()
            return
        }
        let held = disabledHotKeys
        // Only take what is currently enabled: a hotkey the user disabled is not ours to restore later.
        let toDisable = SymbolicHotKey.nativeAppSwitcher.filter { hotKey in
            !held.contains(hotKey) && backend.isEnabled(hotKey) == true
        }
        guard !toDisable.isEmpty else { return }
        // Record first: if we crash between the two steps, the next launch restores them.
        Self.record(held.union(toDisable), in: defaults)
        installSignalHandlersIfNeeded()
        _ = backend.setEnabled(false, toDisable)
        // Forget any hotkey whose disable demonstrably didn't take, so we never "restore" it later.
        let stillEnabled = toDisable.filter { backend.isEnabled($0) == true }
        if !stillEnabled.isEmpty {
            Self.record(disabledHotKeys.subtracting(stillEnabled), in: defaults)
        }
    }

    /// Re-enables every symbolic hotkey Vitrin disabled. Idempotent. Returns false if the system call failed;
    /// the record is then kept so the next launch retries.
    @discardableResult
    public func restoreAll() -> Bool {
        Self.restore(backend: backend, defaults: defaults)
    }

    /// Call once at launch, before the first `apply`: repairs hotkeys left disabled by a run that crashed
    /// or was killed. Returns false if a restore was needed and failed.
    @discardableResult
    public static func recoverFromPreviousRun(
        backend: SymbolicHotKeyBackend = SystemSymbolicHotKeyBackend(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        restore(backend: backend, defaults: defaults)
    }

    // MARK: - Private

    private nonisolated static func restore(backend: SymbolicHotKeyBackend, defaults: UserDefaults) -> Bool {
        let held = recorded(in: defaults)
        guard !held.isEmpty else { return true }
        let ordered = held.sorted { $0.rawValue < $1.rawValue }
        guard backend.setEnabled(true, ordered) else { return false }
        defaults.removeObject(forKey: defaultsKey)
        return true
    }

    private nonisolated static func recorded(in defaults: UserDefaults) -> Set<SymbolicHotKey> {
        let raw = defaults.array(forKey: defaultsKey) as? [NSNumber] ?? []
        return Set(raw.map { SymbolicHotKey(rawValue: $0.int32Value) })
    }

    private nonisolated static func record(_ hotKeys: Set<SymbolicHotKey>, in defaults: UserDefaults) {
        if hotKeys.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(hotKeys.map { Int($0.rawValue) }.sorted(), forKey: defaultsKey)
        }
        // Survive an immediate crash / SIGKILL right after disabling.
        defaults.synchronize()
    }

    /// SIGTERM (logout, `kill`, `launchctl`) and SIGINT (Ctrl-C when run from a terminal) skip
    /// `applicationWillTerminate`. The handler runs on a private queue, not the main thread, so it works even if
    /// the main thread is busy; it restores and then re-raises with the default action so the exit status is
    /// unchanged.
    private func installSignalHandlersIfNeeded() {
        guard handlesTerminationSignals, signalSources.isEmpty else { return }
        let backend = backend
        nonisolated(unsafe) let defaults = defaults
        let queue = DispatchQueue(label: "io.github.ozanhakantunca.vitrin.hotkey-takeover.signals")
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN) // let the dispatch source receive it instead of the default action
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler {
                _ = HotkeyTakeover.restore(backend: backend, defaults: defaults)
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
