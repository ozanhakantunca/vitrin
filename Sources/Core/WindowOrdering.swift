import CoreGraphics
import Foundation

/// Most-recently-used window history.
///
/// Each focus event stamps the window with an increasing sequence number; ordering by that number
/// (descending) gives MRU order. Windows that were never seen focused keep their input order
/// (typically CGWindowList z-order) and come after every focused window.
public struct FocusHistory: Sendable, Hashable {
    private var sequenceByWindow: [CGWindowID: UInt64] = [:]
    private var counter: UInt64 = 0

    public init() {}

    /// Seeds the history from a front-to-back list (e.g. initial z-order at launch): `ids[0]` is the most recent.
    public init(mostRecentFirst ids: [CGWindowID]) {
        for id in ids.reversed() { recordFocus(id) }
    }

    /// Moves `id` to the front.
    public mutating func recordFocus(_ id: CGWindowID) {
        counter += 1
        sequenceByWindow[id] = counter
    }

    /// Forgets a closed window.
    public mutating func remove(_ id: CGWindowID) {
        sequenceByWindow[id] = nil
    }

    /// Forgets every window not in `liveIDs` (prunes closed windows in bulk).
    public mutating func retainOnly<S: Sequence>(_ liveIDs: S) where S.Element == CGWindowID {
        let live = Set(liveIDs)
        sequenceByWindow = sequenceByWindow.filter { live.contains($0.key) }
    }

    public func sequence(for id: CGWindowID) -> UInt64? {
        sequenceByWindow[id]
    }

    /// Known windows, most recent first.
    public var mostRecentFirst: [CGWindowID] {
        sequenceByWindow.sorted { $0.value > $1.value }.map(\.key)
    }

    public var isEmpty: Bool { sequenceByWindow.isEmpty }

    /// Copies each window's focus sequence into `WindowInfo.lastFocusSequence`.
    public func stamp(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.map { window in
            var window = window
            window.lastFocusSequence = sequenceByWindow[window.id]
            return window
        }
    }

    /// Stamps and sorts `windows` into MRU order.
    public func ordered(_ windows: [WindowInfo]) -> [WindowInfo] {
        WindowInfo.mruSorted(stamp(windows))
    }
}

extension WindowInfo {
    /// Sorts by `lastFocusSequence` (most recent first). Unstamped windows follow, in input order.
    public static func mruSorted(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastFocusSequence, rhs.element.lastFocusSequence) {
            case let (l?, r?): return l != r ? l > r : lhs.offset < rhs.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

/// The live state a profile's filters are evaluated against.
public struct SwitcherContext: Sendable, Hashable {
    /// The frontmost application's pid.
    public var activePID: pid_t?
    /// The visible Space of each display (several when "Displays have separate Spaces" is on).
    public var currentSpaceIDs: Set<SpaceID>
    /// The display holding the focused window / active menu bar.
    public var activeDisplayID: CGDirectDisplayID?
    /// The display under the mouse pointer.
    public var mouseDisplayID: CGDirectDisplayID?

    public init(
        activePID: pid_t? = nil,
        currentSpaceIDs: Set<SpaceID> = [],
        activeDisplayID: CGDirectDisplayID? = nil,
        mouseDisplayID: CGDirectDisplayID? = nil
    ) {
        self.activePID = activePID
        self.currentSpaceIDs = currentSpaceIDs
        self.activeDisplayID = activeDisplayID
        self.mouseDisplayID = mouseDisplayID
    }
}

extension WindowFilters {
    /// Whether `window` passes these filters.
    ///
    /// Unknown data is permissive: a window with unknown Spaces / display, or a context with an unknown
    /// current Space / display, is not filtered out by that criterion (better to show a window than to
    /// lose it). The one exception is `apps == .activeApp` with no known frontmost app, which matches nothing.
    public func matches(_ window: WindowInfo, in context: SwitcherContext) -> Bool {
        if !includeMinimized && window.isMinimized { return false }
        if !includeHidden && window.isAppHidden { return false }
        if !includeFullscreen && window.isFullscreen { return false }

        switch apps {
        case .all: break
        case .activeApp:
            guard let pid = context.activePID, window.pid == pid else { return false }
        }

        switch spaces {
        case .all: break
        case .current:
            if !window.spaceIDs.isEmpty && !context.currentSpaceIDs.isEmpty
                && context.currentSpaceIDs.isDisjoint(with: window.spaceIDs) {
                return false
            }
        }

        let requiredDisplay: CGDirectDisplayID?
        switch screens {
        case .all: requiredDisplay = nil
        case .active: requiredDisplay = context.activeDisplayID
        case .withMouse: requiredDisplay = context.mouseDisplayID
        }
        if let requiredDisplay, let display = window.displayID, display != requiredDisplay {
            return false
        }
        return true
    }
}

extension ShortcutProfile {
    /// The windows this profile shows, in MRU order.
    ///
    /// - Parameters:
    ///   - windows: all known windows, ideally in z-order (front to back) so never-focused windows sort sensibly.
    ///   - history: focus history used for ordering. Pass `nil` if `windows` are already stamped.
    ///   - exceptions: windows of apps with `hide == .always` are removed.
    public func windows(
        from windows: [WindowInfo],
        history: FocusHistory? = nil,
        exceptions: [AppException] = [],
        context: SwitcherContext
    ) -> [WindowInfo] {
        let hiddenBundles = Set(exceptions.filter { $0.hide == .always }.map(\.bundleIdentifier))
        let kept = windows.filter { window in
            if let bundle = window.bundleIdentifier, hiddenBundles.contains(bundle) { return false }
            return filters.matches(window, in: context)
        }
        return history.map { $0.ordered(kept) } ?? WindowInfo.mruSorted(kept)
    }
}
