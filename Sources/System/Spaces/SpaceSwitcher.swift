// Lists Mission Control Spaces and switches between them.
import AppKit
import CoreGraphics
import VitrinCore
import VitrinPrivate

@MainActor
public final class SpaceSwitcher: SpaceSwitching {
    // The controller and debug commands share the same restore timers.
    private static let temporaryHotKeys: TemporarySpaceHotKeys = {
        let hotKeys = TemporarySpaceHotKeys(backend: SystemSymbolicHotKeyBackend(), defaults: .standard)
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { hotKeys.restoreAll() }
        }
        return hotKeys
    }()

    public init() {
        _ = Self.temporaryHotKeys
    }

    public func desktops(onDisplay displayIdentifier: String) -> [Desktop] {
        guard let displays = SkyLight.managedDisplays(),
              let display = Self.sharedDisplay(in: displays)
                ?? displays.first(where: { $0.identifier == displayIdentifier }) else { return [] }
        return Self.desktops(in: display)
    }

    public func spacesDisplayIdentifier(for displayID: CGDirectDisplayID) -> String? {
        guard let displays = SkyLight.managedDisplays() else { return nil }
        if let shared = Self.sharedDisplay(in: displays) { return shared.identifier }
        guard let identifier = SkyLight.displayIdentifier(for: displayID),
              displays.contains(where: { $0.identifier == identifier }) else { return nil }
        return identifier
    }

    /// SkyLight identifier of the display with keyboard focus.
    public var activeSpacesDisplayIdentifier: String? {
        guard let displays = SkyLight.managedDisplays() else { return nil }
        if let shared = Self.sharedDisplay(in: displays) { return shared.identifier }
        guard let active = SkyLight.activeMenuBarDisplayIdentifier(),
              displays.contains(where: { $0.identifier == active }) else { return nil }
        return active
    }

    @discardableResult
    public func switchTo(_ desktop: Desktop) -> Bool {
        guard let displays = SkyLight.managedDisplays(),
              let display = displays.first(where: { $0.identifier == desktop.displayIdentifier }) else { return false }

        let plans = DesktopSwitchPlan.candidates(
            to: desktop.id,
            in: Self.desktops(in: display),
            managedDisplayCount: displays.count,
            activeDisplayIdentifier: SkyLight.activeMenuBarDisplayIdentifier()
        ) { shortcut in
            Self.binding(for: shortcut) != nil
        }
        guard !plans.isEmpty, CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState) else { return false }

        return plans.contains { plan in
            guard let binding = Self.binding(for: plan.shortcut),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: binding.value.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: binding.value.keyCode, keyDown: false)
            else { return false }

            down.flags = binding.value.modifiers
            up.flags = binding.value.modifiers
            return Self.temporaryHotKeys.post(whileEnabled: binding.hotKey) {
                for _ in 0..<plan.pressCount {
                    down.timestamp = DispatchTime.now().uptimeNanoseconds
                    down.post(tap: .cghidEventTap)
                    up.timestamp = DispatchTime.now().uptimeNanoseconds
                    up.post(tap: .cghidEventTap)
                }
            }
        }
    }

    private static func sharedDisplay(in displays: [SkyLight.ManagedDisplay]) -> SkyLight.ManagedDisplay? {
        guard displays.count == 1, let display = displays.first, display.identifier == "Main" else { return nil }
        return display
    }

    static func desktops(in display: SkyLight.ManagedDisplay) -> [Desktop] {
        var desktops: [Desktop] = []
        var number = 0
        for space in display.spaces {
            let kind: Desktop.Kind
            switch space.type {
            case .user:
                number += 1
                kind = .desktop(number: number)
            case .fullscreen:
                kind = .fullscreen
            case .system, .other:
                continue
            }
            desktops.append(Desktop(
                id: space.id, kind: kind, displayIdentifier: display.identifier,
                isCurrent: space.id == display.currentSpaceID, index: desktops.count
            ))
        }
        return desktops
    }

    private static func binding(
        for shortcut: DesktopSwitchPlan.Shortcut
    ) -> (hotKey: SymbolicHotKey, value: SymbolicHotKeys.Value)? {
        let hotKey: SymbolicHotKey
        switch shortcut {
        case .desktop(let number): hotKey = SymbolicHotKey.switchToDesktop[number - 1]
        case .moveLeft: hotKey = .moveLeftASpace
        case .moveRight: hotKey = .moveRightASpace
        }
        guard let value = SymbolicHotKeys.value(of: hotKey), value.keyCode != 0xFFFF,
              value.keyCode != 0 || value.keyEquivalent != 0xFFFF || !value.modifiers.isEmpty
        else { return nil }
        return (hotKey, value)
    }
}
