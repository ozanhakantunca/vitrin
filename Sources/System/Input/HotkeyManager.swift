import AppKit
import Carbon
import CoreGraphics
import Foundation
import os
import VitrinCore

/// Main-run-loop event tap. Secure Event Input (`IsSecureEventInputEnabled()`) prevents
/// delivery to event taps; shortcuts cannot work until the application enabling it turns it off.
@MainActor
public final class HotkeyManager: HotkeyHandling {
    private static let logger = Logger(
        subsystem: "io.github.ozanhakantunca.vitrin", category: "hotkeys"
    )

    private var matcher = HotkeyMatcher()
    private var state = HotkeyMatcher.State()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var profiles: [ShortcutProfile] = []
    private var exceptions: [AppException] = []
    private var activationObserver: NSObjectProtocol?

    public var onEvent: ((HotkeyEvent) -> Void)?

    public var isSwitcherOpen: Bool {
        get { state.isSwitcherOpen }
        set {
            let wasOpen = state.isSwitcherOpen
            state.isSwitcherOpen = newValue
            if wasOpen && !newValue { matcher.close(state: &state) }
            deliver(matcher.synchronize(state: &state))
        }
    }

    public var openProfileID: String? {
        get { state.openProfileID }
        set {
            state.openProfileID = newValue
            deliver(matcher.synchronize(state: &state))
        }
    }

    public init() {}

    @discardableResult
    public func start(profiles: [ShortcutProfile]) -> Bool {
        update(profiles: profiles)
        observeFrontmostApplication()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // The source is installed only on CFRunLoopGetMain(), so delivery is synchronous
                // on the main actor. No Task hop: swallowing and open-state updates are immediate.
                return MainActor.assumeIsolated {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                    return manager.handle(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        eventTap = nil
        runLoopSource = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        state = HotkeyMatcher.State()
    }

    public func update(profiles: [ShortcutProfile]) {
        self.profiles = profiles
        rebuildMatcher()
        for overlap in matcher.overlappingTriggers {
            Self.logger.warning(
                "Overlapping hotkey profiles '\(overlap.first, privacy: .public)' and '\(overlap.later, privacy: .public)'; first match wins"
            )
        }
    }

    /// While the frontmost app has an exception with `ignoreShortcutsWhenFrontmost`, triggers pass
    /// through to it untouched (VMs, remote desktops, games). An already open switcher is unaffected.
    public func update(exceptions: [AppException]) {
        self.exceptions = exceptions
        rebuildMatcher()
    }

    /// The bundle id the passthrough decision currently uses (cached; updated on app activation).
    public var frontmostBundleID: String? { state.frontmostBundleID }

    private func rebuildMatcher() {
        matcher = HotkeyMatcher(profiles: profiles, exceptions: exceptions, isISOKeyboard: Self.isISOKeyboard)
    }

    private func observeFrontmostApplication() {
        guard activationObserver == nil else { return }
        let workspace = NSWorkspace.shared
        state.frontmostBundleID = workspace.frontmostApplication?.bundleIdentifier
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.state.frontmostBundleID = bundleID }
        }
    }

    deinit {
        // No retained self in the C callback. Invalidate its source before userInfo can dangle.
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private static var isISOKeyboard: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let inputType: HotkeyMatcher.EventType
        switch type {
        case .keyDown: inputType = .keyDown
        case .keyUp: inputType = .keyUp
        case .flagsChanged: inputType = .flagsChanged
        default: return Unmanaged.passUnretained(event)
        }
        // Lazy layout refresh on every possible open also covers input-source and hardware changes.
        if type == .keyDown && !state.isSwitcherOpen {
            matcher.isISOKeyboard = Self.isISOKeyboard
        }
        let input = HotkeyMatcher.Input(
            type: inputType,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            text: type == .keyDown && state.isSwitcherOpen ? Self.text(from: event) : nil
        )
        let result = matcher.handle(input, state: &state)
        deliver(result.event)
        return result.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func deliver(_ event: HotkeyEvent?) {
        if let event { onEvent?(event) }
    }

    private static func text(from event: CGEvent) -> String? {
        // Search text ignores the held switcher modifier (⌥W must search for "w", not "∑").
        // `charactersIgnoringModifiers` still honours Shift.
        if let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !characters.isEmpty {
            return characters
        }
        // The stack buffer covers CGEvent's Unicode payload without allocating an intermediate array.
        return withUnsafeTemporaryAllocation(of: UniChar.self, capacity: 64) { buffer -> String? in
            var count = 0
            event.keyboardGetUnicodeString(
                maxStringLength: buffer.count, actualStringLength: &count, unicodeString: buffer.baseAddress!
            )
            guard count > 0 else { return nil }
            return String(utf16CodeUnits: buffer.baseAddress!, count: min(count, buffer.count))
        }
    }
}
