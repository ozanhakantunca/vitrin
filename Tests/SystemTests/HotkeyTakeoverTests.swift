import Foundation
import Testing
import VitrinCore
import VitrinPrivate
@testable import VitrinSystem

/// In-memory symbolic hotkeys. Never touches the real WindowServer.
private final class FakeBackend: SymbolicHotKeyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [SymbolicHotKey: Bool]
    private(set) var setCalls: [(enabled: Bool, hotKeys: [SymbolicHotKey], recordedAtCall: Set<SymbolicHotKey>)] = []
    /// Make `setEnabled` report failure (and change nothing).
    var failsSet = false
    /// Make `setEnabled(false, …)` report success without effect (a disable that doesn't take).
    var ignoresDisable = false
    var defaults: UserDefaults?

    init(_ state: [SymbolicHotKey: Bool] = [.commandTab: true, .commandShiftTab: true]) {
        self.state = state
    }

    func isEnabled(_ hotKey: SymbolicHotKey) -> Bool? {
        lock.withLock { state[hotKey] }
    }

    func setEnabled(_ enabled: Bool, _ hotKeys: [SymbolicHotKey]) -> Bool {
        lock.withLock {
            let recorded = Set((defaults?.array(forKey: HotkeyTakeover.defaultsKey) as? [Int] ?? [])
                .map { SymbolicHotKey(rawValue: Int32($0)) })
            setCalls.append((enabled, hotKeys, recorded))
            if failsSet { return false }
            if !enabled && ignoresDisable { return true }
            for hotKey in hotKeys { state[hotKey] = enabled }
            return true
        }
    }
}

@MainActor
struct HotkeyTakeoverTests {
    private let defaults: UserDefaults
    private let suiteName = "vitrin.tests.takeover.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func profile(_ trigger: String?, enabled: Bool = true, id: String = UUID().uuidString) -> ShortcutProfile {
        ShortcutProfile(id: id, name: id, isEnabled: enabled, trigger: trigger.flatMap(KeyCombo.init(string:)))
    }

    private func makeTakeover(_ backend: FakeBackend) -> HotkeyTakeover {
        backend.defaults = defaults
        return HotkeyTakeover(backend: backend, defaults: defaults, handlesTerminationSignals: false)
    }

    @Test func onlyEnabledCommandTabTriggersNeedTakeover() {
        #expect(HotkeyTakeover.needsTakeover([profile("command+tab")]))
        #expect(HotkeyTakeover.needsTakeover([profile("command+shift+tab")]))
        #expect(HotkeyTakeover.needsTakeover([profile("option+tab"), profile("cmd+tab")]))
        #expect(!HotkeyTakeover.needsTakeover([profile("command+tab", enabled: false)]))
        #expect(!HotkeyTakeover.needsTakeover([profile("option+tab"), profile(nil)]))
        #expect(!HotkeyTakeover.needsTakeover([profile("command+option+tab")]))
        #expect(!HotkeyTakeover.needsTakeover([profile("command+keyAboveTab")]))
        #expect(!HotkeyTakeover.needsTakeover(AppSettings.defaults.profiles)) // task-view (⌘⇥) ships disabled
    }

    @Test func disablesNativeSwitcherAndRecordsBeforeDisabling() {
        defer { cleanUp() }
        let backend = FakeBackend()
        let takeover = makeTakeover(backend)
        takeover.apply(profiles: [profile("command+tab")])

        #expect(backend.isEnabled(.commandTab) == false)
        #expect(backend.isEnabled(.commandShiftTab) == false)
        #expect(takeover.disabledHotKeys == [.commandTab, .commandShiftTab])
        #expect(backend.setCalls.count == 1)
        // Crash safety: the record already existed when the system call was made.
        #expect(backend.setCalls[0].recordedAtCall == [.commandTab, .commandShiftTab])

        // Re-applying is a no-op.
        takeover.apply(profiles: [profile("command+tab")])
        #expect(backend.setCalls.count == 1)
    }

    @Test func restoresWhenNoProfileNeedsItAndOnQuit() {
        defer { cleanUp() }
        let backend = FakeBackend()
        let takeover = makeTakeover(backend)
        takeover.apply(profiles: [profile("command+tab")])
        takeover.apply(profiles: [profile("option+tab")])
        #expect(backend.isEnabled(.commandTab) == true && backend.isEnabled(.commandShiftTab) == true)
        #expect(takeover.disabledHotKeys.isEmpty)
        #expect(defaults.object(forKey: HotkeyTakeover.defaultsKey) == nil)

        takeover.apply(profiles: [profile("command+shift+tab")])
        #expect(takeover.restoreAll())
        #expect(backend.isEnabled(.commandTab) == true && backend.isEnabled(.commandShiftTab) == true)
        let calls = backend.setCalls.count
        #expect(takeover.restoreAll()) // idempotent, no further system calls
        #expect(backend.setCalls.count == calls)
    }

    @Test func aHotkeyTheUserDisabledStaysDisabled() {
        defer { cleanUp() }
        let backend = FakeBackend([.commandTab: false, .commandShiftTab: true])
        let takeover = makeTakeover(backend)
        takeover.apply(profiles: [profile("command+tab")])
        #expect(takeover.disabledHotKeys == [.commandShiftTab])
        #expect(backend.setCalls.map(\.hotKeys) == [[.commandShiftTab]])

        takeover.restoreAll()
        #expect(backend.isEnabled(.commandTab) == false)
        #expect(backend.isEnabled(.commandShiftTab) == true)
    }

    @Test func nothingIsTakenWhenStateCannotBeQueried() {
        defer { cleanUp() }
        let backend = FakeBackend([:]) // isEnabled → nil
        let takeover = makeTakeover(backend)
        takeover.apply(profiles: [profile("command+tab")])
        #expect(backend.setCalls.isEmpty)
        #expect(takeover.disabledHotKeys.isEmpty)
    }

    @Test func aDisableThatDidNotTakeIsForgotten() {
        defer { cleanUp() }
        let backend = FakeBackend()
        backend.ignoresDisable = true
        let takeover = makeTakeover(backend)
        takeover.apply(profiles: [profile("command+tab")])
        #expect(takeover.disabledHotKeys.isEmpty)
    }

    @Test func crashedRunIsRepairedAtNextLaunch() {
        defer { cleanUp() }
        let backend = FakeBackend()
        do {
            // Previous run: disables, then "crashes" (no restore).
            let previous = makeTakeover(backend)
            previous.apply(profiles: [profile("command+tab")])
        }
        #expect(backend.isEnabled(.commandTab) == false)

        #expect(HotkeyTakeover.recoverFromPreviousRun(backend: backend, defaults: defaults))
        #expect(backend.isEnabled(.commandTab) == true && backend.isEnabled(.commandShiftTab) == true)
        #expect(defaults.object(forKey: HotkeyTakeover.defaultsKey) == nil)

        // Nothing recorded → recovery makes no system calls.
        let calls = backend.setCalls.count
        #expect(HotkeyTakeover.recoverFromPreviousRun(backend: backend, defaults: defaults))
        #expect(backend.setCalls.count == calls)
    }

    @Test func aNewInstanceStillOwnsWhatACrashedRunDisabled() {
        defer { cleanUp() }
        let backend = FakeBackend()
        makeTakeover(backend).apply(profiles: [profile("command+tab")])

        // Even if the app forgot `recoverFromPreviousRun`, the next instance restores them.
        let next = makeTakeover(backend)
        next.apply(profiles: [profile("command+tab")])
        #expect(backend.setCalls.count == 1) // already held: not re-queried as "user-disabled"
        next.apply(profiles: [])
        #expect(backend.isEnabled(.commandTab) == true && backend.isEnabled(.commandShiftTab) == true)
    }

    @Test func failedRestoreKeepsTheRecordForTheNextLaunch() {
        defer { cleanUp() }
        let backend = FakeBackend()
        let takeover = makeTakeover(backend)
        takeover.apply(profiles: [profile("command+tab")])
        backend.failsSet = true
        #expect(!takeover.restoreAll())
        #expect(takeover.disabledHotKeys == [.commandTab, .commandShiftTab])

        backend.failsSet = false
        #expect(HotkeyTakeover.recoverFromPreviousRun(backend: backend, defaults: defaults))
        #expect(backend.isEnabled(.commandTab) == true)
        #expect(takeover.disabledHotKeys.isEmpty)
    }
}
