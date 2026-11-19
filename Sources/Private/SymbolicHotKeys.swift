// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// System ("symbolic") hotkeys. Used to optionally disable the native ⌘⇥ app switcher so a profile can
// take over ⌘⇥: the Dock matches ⌘⇥ / ⌘⇧⇥ in the WindowServer's symbolic-hotkey layer, before any
// app's Carbon hotkey sees it.
//
// ⚠️ Enabling/disabling persists after the app quits. The app layer must re-enable on quit / crash
// recovery (e.g. remember the disabled ids and restore them at next launch).

import CoreGraphics
import VitrinPrivateC

/// A symbolic hotkey id. Ids can be discovered with `SymbolicHotKeys.value(of:)` on 0…~300.
public struct SymbolicHotKey: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// ⌘⇥ — native app switcher.
    public static let commandTab = SymbolicHotKey(rawValue: 1)
    /// ⌘⇧⇥ — native app switcher, reverse.
    public static let commandShiftTab = SymbolicHotKey(rawValue: 2)
    /// ⌘` — "Move focus to next window". Delivered to the frontmost app (not consumed by the system), so
    /// it does not need disabling for Vitrin's hotkey to win. (Id 6 is ⌘⌥⇧⎋ force-quit, not ⌘`.)
    public static let moveFocusToNextWindow = SymbolicHotKey(rawValue: 27)
    /// ⌃↑ — Mission Control.
    public static let missionControl = SymbolicHotKey(rawValue: 32)
    /// ⌃↓ — Application windows.
    public static let applicationWindows = SymbolicHotKey(rawValue: 33)

    /// ⌃← — Move left a space.
    public static let moveLeftASpace = SymbolicHotKey(rawValue: 79)
    /// ⌃→ — Move right a space.
    public static let moveRightASpace = SymbolicHotKey(rawValue: 81)
    /// Switch to Desktop 1 through 16, in order.
    public static let switchToDesktop = (118...133).map(SymbolicHotKey.init(rawValue:))

    /// The hotkeys to disable for a profile that uses ⌘⇥.
    public static let nativeAppSwitcher: [SymbolicHotKey] = [.commandTab, .commandShiftTab]

    public var description: String { "SymbolicHotKey(\(rawValue))" }
}

public enum SymbolicHotKeys {
    /// The key a symbolic hotkey is bound to.
    public struct Value: Sendable, Hashable {
        /// Character, or 0xFFFF when the binding uses a non-character key.
        public let keyEquivalent: UInt16
        public let keyCode: UInt16
        /// `CGEventFlags` raw bits (e.g. `maskCommand`).
        public let modifierFlags: UInt64

        public var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierFlags) }
    }

    /// `nil` if the query is unavailable.
    public static func isEnabled(_ hotKey: SymbolicHotKey) -> Bool? {
        guard let fn = PrivateAPI.function(.isSymbolicHotKeyEnabled, as: VPIsSymbolicHotKeyEnabledFn.self) else { return nil }
        return fn(hotKey.rawValue)
    }

    /// The key binding of `hotKey`, or `nil` if unavailable / unknown id.
    public static func value(of hotKey: SymbolicHotKey) -> Value? {
        guard let fn = PrivateAPI.function(.getSymbolicHotKeyValue, as: VPGetSymbolicHotKeyValueFn.self) else { return nil }
        var keyEquivalent: UInt16 = 0
        var keyCode: UInt16 = 0
        var modifiers: UInt64 = 0
        guard fn(hotKey.rawValue, &keyEquivalent, &keyCode, &modifiers) == .success else { return nil }
        return Value(keyEquivalent: keyEquivalent, keyCode: keyCode, modifierFlags: modifiers)
    }

    /// Enables or disables system hotkeys. **Changes system state and persists after quit.**
    /// Returns `false` if unavailable or if any call failed.
    @discardableResult
    public static func setEnabled(_ enabled: Bool, _ hotKeys: [SymbolicHotKey]) -> Bool {
        guard let fn = PrivateAPI.function(.setSymbolicHotKeyEnabled, as: VPSetSymbolicHotKeyEnabledFn.self) else { return false }
        var ok = true
        for hotKey in hotKeys where fn(hotKey.rawValue, enabled) != .success {
            ok = false
        }
        return ok
    }
}
