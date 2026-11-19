// Protocols between the app and the system layer. Implementations live in Tracking/, Input/, Capture/.
import AppKit
import ApplicationServices
import CoreGraphics
import VitrinCore

// MARK: - Window tracking

/// Keeps a live inventory of every window (all apps, all Spaces, minimized/hidden included)
/// plus the MRU focus history. Main-actor only; driven by NSWorkspace + AXObserver events.
@MainActor
public protocol WindowTracking: AnyObject {
    /// Starts observing. Safe to call once Accessibility is granted; no-op if already started.
    func start()
    func stop()
    /// Current snapshot (unordered). Each window carries `lastFocusSequence` stamped from `focusHistory`.
    var windows: [WindowInfo] { get }
    var focusHistory: FocusHistory { get }
    /// Context for profile filtering at the moment the switcher opens.
    func currentContext() -> SwitcherContext
    /// Called on the main actor whenever `windows` or `focusHistory` change (coalesced).
    var onChange: (() -> Void)? { get set }
    /// AX element of a tracked window (for focus / actions), if known.
    func axElement(for windowID: CGWindowID) -> AXUIElement?
    /// Forces a full rescan (e.g. after Accessibility was just granted).
    func refreshAll()
}

// MARK: - Window actions

public enum WindowAction: Sendable, Hashable {
    case focus
    case close
    case minimize
    case toggleFullscreen
    case hideApp
    case quitApp
}

@MainActor
public protocol WindowActing: AnyObject {
    /// Performs the action; returns false if it could not be performed.
    @discardableResult
    func perform(_ action: WindowAction, on window: WindowInfo) -> Bool
}

// MARK: - Global hotkeys

/// Semantic input while the switcher is open (or the event that opens it).
public enum HotkeyEvent: Sendable, Hashable {
    /// The trigger of `profileID` was pressed while the switcher was closed. `reverse` = Shift held.
    case open(profileID: String, reverse: Bool)
    /// Trigger key pressed again while open (Shift held → `.previous`).
    case next
    case previous
    case moveLeft, moveRight, moveUp, moveDown
    /// The profile's hold-modifiers were released (commit if the profile focuses on release).
    case modifiersReleased
    /// Return / Space.
    case confirm
    /// Escape.
    case cancel
    /// Action keys while open: W close, M minimize, F fullscreen, H hide app, Q quit app.
    case action(WindowAction)
    /// Any printable text typed while open (for F2 search). Not emitted in F1.
    case text(String)
    case backspace
}

/// CGEventTap-based global hotkey listener. While the switcher is open it swallows the keys it uses.
@MainActor
public protocol HotkeyHandling: AnyObject {
    /// Installs the event tap. Returns false if it could not (no Accessibility / Input Monitoring).
    @discardableResult
    func start(profiles: [ShortcutProfile]) -> Bool
    func stop()
    /// Replace the active trigger set (enabled profiles with a trigger).
    func update(profiles: [ShortcutProfile])
    /// Apps whose `ignoreShortcutsWhenFrontmost` makes triggers pass through untouched.
    func update(exceptions: [AppException])
    /// Set by the controller; while true, navigation/action keys are interpreted and swallowed.
    var isSwitcherOpen: Bool { get set }
    /// The profile currently open (determines which hold-modifiers to watch for release).
    var openProfileID: String? { get set }
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
}

// MARK: - Thumbnails

/// Window thumbnails via ScreenCaptureKit. Thread-safe; results cached per window.
public protocol ThumbnailProviding: AnyObject, Sendable {
    /// Whether Screen Recording permission is currently granted.
    var isAvailable: Bool { get }
    /// Returns a cached image immediately if present (may be stale).
    func cachedThumbnail(for windowID: CGWindowID) -> CGImage?
    /// Captures a fresh image scaled to fit `maxPixelSize`. nil if unavailable / window gone.
    func thumbnail(for windowID: CGWindowID, maxPixelSize: CGSize) async -> CGImage?
    func invalidate(windowID: CGWindowID)
    func removeAll()
}
