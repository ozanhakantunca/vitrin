import CoreGraphics
import Foundation

/// A Mission Control Space identifier (`CGSSpaceID` in the private API layer).
public typealias SpaceID = UInt64

/// A snapshot of one on-screen (or minimized / hidden / other-Space) window.
///
/// `WindowInfo` is a plain value: the app layer builds it from CGWindowList + AX + SkyLight and the
/// pure logic in this module (filters, MRU ordering) consumes it.
///
/// Identity: `id` is the `CGWindowID`, stable for the lifetime of the window. Hashing uses only `id`
/// (cheap, and consistent with `==`, which compares every field so that changed titles/frames are
/// still observable as "different snapshots of the same window").
public struct WindowInfo: Sendable, Identifiable, Hashable {
    public var id: CGWindowID
    public var pid: pid_t
    public var bundleIdentifier: String?
    public var appName: String
    public var title: String
    /// Frame in global (top-left origin) screen coordinates, as reported by CGWindowList / AX.
    public var frame: CGRect
    public var isMinimized: Bool
    /// The owning application is hidden (⌘H).
    public var isAppHidden: Bool
    public var isFullscreen: Bool
    /// A regular window of its app: AX subrole `AXStandardWindow` and minimizable (unless it is minimized or
    /// fullscreen). Dialogs, open/save panels, About and settings windows are not. Minimized windows and
    /// windows of hidden apps may briefly report a dialog subrole.
    public var isStandardWindow: Bool
    /// Spaces the window is on. Empty = unknown; more than one = window is on several / all Spaces.
    public var spaceIDs: [SpaceID]
    /// The display the window is (mostly) on. `nil` = unknown.
    public var displayID: CGDirectDisplayID?
    /// Monotonic focus stamp: higher = focused more recently, `nil` = never seen focused.
    /// Assigned by `FocusHistory.stamp(_:)`; consumed by MRU ordering.
    public var lastFocusSequence: UInt64?

    public init(
        id: CGWindowID,
        pid: pid_t,
        bundleIdentifier: String? = nil,
        appName: String = "",
        title: String = "",
        frame: CGRect = .zero,
        isMinimized: Bool = false,
        isAppHidden: Bool = false,
        isFullscreen: Bool = false,
        isStandardWindow: Bool = true,
        spaceIDs: [SpaceID] = [],
        displayID: CGDirectDisplayID? = nil,
        lastFocusSequence: UInt64? = nil
    ) {
        self.id = id
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.isFullscreen = isFullscreen
        self.isStandardWindow = isStandardWindow
        self.spaceIDs = spaceIDs
        self.displayID = displayID
        self.lastFocusSequence = lastFocusSequence
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
