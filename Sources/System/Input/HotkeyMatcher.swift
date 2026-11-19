import CoreGraphics
import VitrinCore

/// Pure keyboard state machine. No event taps, run loops, keyboard-layout queries, or callbacks.
struct HotkeyMatcher {
    enum EventType {
        case keyDown, keyUp, flagsChanged
    }

    struct Input {
        var type: EventType
        var keyCode: UInt16 = 0
        var flags: CGEventFlags = []
        var isAutorepeat = false
        /// Unicode supplied by the event, rather than inferred from an ANSI key-code table.
        var text: String? = nil
    }

    struct Output: Equatable {
        var swallow: Bool
        var event: HotkeyEvent? = nil
    }

    struct State {
        var isSwitcherOpen = false
        var openProfileID: String?
        /// Cached by the manager from NSWorkspace activation notifications (never queried per event).
        var frontmostBundleID: String?
        fileprivate var observedProfileID: String?
        fileprivate var modifiers: ModifierSet = []
        fileprivate var session: Session?
        // Keep key ownership through a synchronous close in onEvent, until the physical keyUp.
        fileprivate var swallowedKeys: Set<UInt16> = []
    }

    fileprivate struct Session {
        var profileID: String
        var keyCode: UInt16
        var holdModifiers: ModifierSet
        var releaseObserved = false
        var releaseDelivered = false
    }

    struct Trigger {
        var profileID: String
        var combo: KeyCombo
    }

    let triggers: [Trigger]
    /// Apps that get Vitrin's triggers passed through untouched while frontmost (VMs, remote desktops, games).
    let passthroughBundleIDs: Set<String>
    var isISOKeyboard: Bool

    init(profiles: [ShortcutProfile] = [], exceptions: [AppException] = [], isISOKeyboard: Bool = false) {
        triggers = profiles.compactMap { profile in
            guard profile.isEnabled, let combo = profile.trigger else { return nil }
            return Trigger(profileID: profile.id, combo: combo)
        }
        passthroughBundleIDs = Set(exceptions.filter(\.ignoreShortcutsWhenFrontmost).map(\.bundleIdentifier))
        self.isISOKeyboard = isISOKeyboard
    }

    /// Whether a trigger pressed now must be left to the frontmost app.
    func isPassthrough(_ state: State) -> Bool {
        guard let bundleID = state.frontmostBundleID else { return false }
        return passthroughBundleIDs.contains(bundleID)
    }

    /// Also detects overlap caused by the optional reverse Shift and ignored fn modifiers.
    /// Resolution remains ordered at match time, including when the keyboard type changes.
    var overlappingTriggers: [(first: String, later: String)] {
        var result: [(first: String, later: String)] = []
        for (index, later) in triggers.enumerated() {
            if let first = triggers[..<index].first(where: { first in
                !first.combo.key.possibleKeyCodes.isDisjoint(with: later.combo.key.possibleKeyCodes)
                    && (UInt8(0)..<32).contains { raw in
                        Self.matches(ModifierSet(rawValue: raw), required: first.combo.modifiers)
                            && Self.matches(ModifierSet(rawValue: raw), required: later.combo.modifiers)
                    }
            }) {
                result.append((first.profileID, later.profileID))
            }
        }
        return result
    }

    func handle(_ input: Input, state: inout State) -> Output {
        state.modifiers = Self.modifiers(from: input.flags)
        let release = synchronize(state: &state)

        switch input.type {
        case .flagsChanged:
            return Output(swallow: false, event: release)
        case .keyUp:
            let owned = state.swallowedKeys.remove(input.keyCode) != nil
            return Output(swallow: state.isSwitcherOpen || owned, event: release)
        case .keyDown:
            if state.isSwitcherOpen {
                state.swallowedKeys.insert(input.keyCode)
                return Output(swallow: true, event: release ?? eventWhileOpen(input, state: state))
            }

            // A repeat arriving after confirm/cancel/release must not leak or reopen the panel.
            if input.isAutorepeat && state.swallowedKeys.contains(input.keyCode) {
                return Output(swallow: true)
            }
            // Only opening is suppressed: a switcher that is already open keeps owning its keys.
            guard !isPassthrough(state), let trigger = triggers.first(where: {
                $0.combo.key.keyCode(isISOKeyboard: isISOKeyboard) == input.keyCode
                    && Self.matches(state.modifiers, required: $0.combo.modifiers)
            }) else {
                return Output(swallow: false)
            }
            state.swallowedKeys.insert(input.keyCode)
            state.session = session(for: trigger)
            return Output(
                swallow: true,
                event: .open(profileID: trigger.profileID, reverse: state.modifiers.contains(.shift))
            )
        }
    }

    /// Called after either controller-owned property changes as well as on every input event.
    /// A release is latched from the opening keyDown onward, even before the panel is open.
    func synchronize(state: inout State) -> HotkeyEvent? {
        let profileChanged = state.openProfileID != state.observedProfileID
        state.observedProfileID = state.openProfileID
        if state.isSwitcherOpen,
           let profileID = state.openProfileID,
           (state.session == nil || (profileChanged && state.session?.profileID != profileID)),
           let trigger = triggers.first(where: { $0.profileID == profileID }) {
            state.session = session(for: trigger)
        }
        guard var session = state.session else { return nil }
        if !state.modifiers.isSuperset(of: session.holdModifiers) {
            session.releaseObserved = true
        }
        let deliver = state.isSwitcherOpen && session.releaseObserved && !session.releaseDelivered
        if deliver { session.releaseDelivered = true }
        state.session = session
        return deliver ? .modifiersReleased : nil
    }

    func close(state: inout State) {
        state.session = nil
    }

    private func session(for trigger: Trigger) -> Session {
        Session(
            profileID: trigger.profileID,
            keyCode: trigger.combo.key.keyCode(isISOKeyboard: isISOKeyboard),
            holdModifiers: trigger.combo.modifiers
        )
    }

    private func eventWhileOpen(_ input: Input, state: State) -> HotkeyEvent? {
        if input.keyCode == state.session?.keyCode {
            return state.modifiers.contains(.shift) ? .previous : .next
        }
        switch input.keyCode {
        case 0x7B: return .moveLeft
        case 0x7C: return .moveRight
        case 0x7E: return .moveUp
        case 0x7D: return .moveDown
        case 0x24, 0x4C: return .confirm // Return, keypad Enter
        case KeyCode.space: return .text(" ") // controller: confirm when the search is empty, else a word separator
        case KeyCode.escape: return .cancel
        // Window actions use ⌘ + the macOS mnemonic, so plain letters stay free for search.
        // ⌃ is accepted too for Windows keyboards (Ctrl+W/Ctrl+Q habits; reachable while Alt is held).
        case 0x0D where hasActionModifier(state): return .action(.close)
        case 0x2E where hasActionModifier(state): return .action(.minimize)
        case 0x03 where hasActionModifier(state): return .action(.toggleFullscreen)
        case 0x04 where hasActionModifier(state): return .action(.hideApp)
        case 0x0C where hasActionModifier(state): return .action(.quitApp)
        case 0x75: return .action(.close) // forward Delete closes the selection, as in Windows' Alt+Tab
        case 0x33: return .backspace
        default:
            guard let text = input.text, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({
                      $0.properties.generalCategory != .control
                          && $0.properties.generalCategory != .lineSeparator
                          && $0.properties.generalCategory != .paragraphSeparator
                          && !(0xF700...0xF8FF).contains($0.value) // AppKit function-key characters
                  }) else { return nil }
            return .text(text)
        }
    }

    private func hasActionModifier(_ state: State) -> Bool {
        state.modifiers.contains(.command) || state.modifiers.contains(.control)
    }

    private static func matches(_ actual: ModifierSet, required: ModifierSet) -> Bool {
        var compared = actual
        if !required.contains(.shift) { compared.remove(.shift) }
        if !required.contains(.function) { compared.remove(.function) }
        return compared == required
    }

    private static func modifiers(from flags: CGEventFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }
}
