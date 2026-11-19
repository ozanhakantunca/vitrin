// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Window actions (focus, close, minimize, fullscreen, hide/quit app).
//
// `perform` returns immediately: preconditions are checked on the main actor (no AX), and every AX /
// SkyLight call runs on a background serial queue, so a hung target app cannot stall the switcher UI.
// The tracker learns the outcome from the usual AX / NSWorkspace notifications (focus history moves when
// the OS reports the focus, not when it is requested — as in AltTab #6055).

import AppKit
import ApplicationServices
import CoreGraphics
import VitrinCore
import VitrinPrivate

@MainActor
public final class WindowActor: WindowActing {
    private let tracker: WindowTracking
    private let queue = DispatchQueue(label: "io.github.ozanhakantunca.vitrin.window-actions", qos: .userInteractive)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init(tracker: WindowTracking) {
        self.tracker = tracker
    }

    /// Returns `false` when the action cannot be attempted (dead app, Vitrin's own window, unknown AX element
    /// for an AX-only action, missing private API). `true` means it was dispatched.
    @discardableResult
    public func perform(_ action: WindowAction, on window: WindowInfo) -> Bool {
        guard window.pid != ownPID,
              let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return false }
        let element = tracker.axElement(for: window.id).map(ElementBox.init)
        switch action {
        case .focus:
            return focus(window, app: app, element: element)
        case .close:
            guard let element else { return false }
            queue.async {
                var button: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element.element, kAXCloseButtonAttribute as CFString, &button) == .success,
                      let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
            return true
        case .minimize:
            guard let element else { return false }
            let minimize = !window.isMinimized
            queue.async {
                AXUIElementSetAttributeValue(element.element, kAXMinimizedAttribute as CFString, minimize as CFBoolean)
            }
            return true
        case .toggleFullscreen:
            guard let element else { return false }
            let fullscreen = !window.isFullscreen
            let wasMinimized = window.isMinimized
            queue.async {
                if wasMinimized {
                    AXUIElementSetAttributeValue(element.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                AXUIElementSetAttributeValue(element.element, Tracking.fullScreenAttribute as CFString, fullscreen as CFBoolean)
            }
            return true
        case .hideApp:
            return app.hide()
        case .quitApp:
            return app.terminate()
        }
    }

    /// Un-minimize / unhide if needed, then front process → key window → AXRaise (`WindowFocus.focus`).
    /// For a window on another Space, `_SLPSSetFrontProcessWithOptions` makes macOS switch Space, and also
    /// overwrites the origin Space's front app; that is repaired with `SLSSpaceSetFrontPSN` (AltTab #4507).
    private func focus(_ window: WindowInfo, app: NSRunningApplication, element: ElementBox?) -> Bool {
        guard WindowFocus.processSerialNumber(for: window.pid) != nil else { return false }
        if app.isHidden { app.unhide() }
        let originSpace = SkyLight.activeSpace()
        let originFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let plan = Self.focusPlan(window: window, originSpace: originSpace, originFrontPID: originFrontPID, ownPID: ownPID)
        let windowID = window.id
        let pid = window.pid
        queue.async {
            if window.isMinimized, let element {
                AXUIElementSetAttributeValue(element.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            WindowFocus.focus(windowID: windowID, pid: pid, element: element?.element)
            if let restore = plan.restoreOriginFront {
                WindowFocus.setSpaceFrontProcess(space: restore.space, pid: restore.pid)
            }
        }
        return true
    }

    /// AX elements are immutable CF references usable from any thread; the SDK just doesn't mark them Sendable.
    private struct ElementBox: @unchecked Sendable {
        let element: AXUIElement
    }

    struct FocusPlan: Equatable {
        /// After a cross-Space focus: give the origin Space its previous front app back.
        var restoreOriginFront: (space: SpaceID, pid: pid_t)?

        static func == (lhs: FocusPlan, rhs: FocusPlan) -> Bool {
            lhs.restoreOriginFront?.space == rhs.restoreOriginFront?.space
                && lhs.restoreOriginFront?.pid == rhs.restoreOriginFront?.pid
        }
    }

    /// Pure part of focusing. Only repair the origin Space when the target is *known* to be elsewhere: empty
    /// `spaceIDs` means unknown, and repairing the current Space would re-front the previous app (AltTab #5586).
    nonisolated static func focusPlan(window: WindowInfo, originSpace: SpaceID?, originFrontPID: pid_t?,
                                      ownPID: pid_t) -> FocusPlan {
        guard let originSpace, let originFrontPID, originFrontPID != window.pid, originFrontPID != ownPID,
              !window.spaceIDs.isEmpty, !window.spaceIDs.contains(originSpace) else { return FocusPlan() }
        return FocusPlan(restoreOriginFront: (originSpace, originFrontPID))
    }
}
