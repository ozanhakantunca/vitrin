// The interface between SwitcherController and the panel. The implementation lives next to this file.
import AppKit
import VitrinCore
import VitrinSystem

/// One cell of the switcher.
struct SwitcherItem: Identifiable, Hashable {
    let window: WindowInfo
    let appIcon: NSImage?
    var id: CGWindowID { window.id }
}

/// The on-screen switcher panel. Never activates Vitrin (non-activating panel), floats above
/// everything including full-screen Spaces, and only reflects state pushed by the controller.
@MainActor
protocol SwitcherPresenting: AnyObject {
    /// Shows (or re-lays out) the panel on `screen` with `items`, highlighting `selectedIndex`.
    func show(items: [SwitcherItem], selectedIndex: Int, profile: ShortcutProfile, on screen: NSScreen)
    func updateSelection(_ index: Int)
    func updateThumbnail(windowID: CGWindowID, image: CGImage)
    func hide()
    var isVisible: Bool { get }
    /// Grid geometry so the controller can map arrow keys: number of columns in the current layout.
    var columns: Int { get }
    /// Thumbnail pixel size the layout wants (controller requests captures at this size).
    var thumbnailPixelSize: CGSize { get }
    /// Mouse hover over an item (select) / click on an item (select + confirm).
    var onHover: ((Int) -> Void)? { get set }
    var onClick: ((Int) -> Void)? { get set }
    /// Hover-action buttons on a cell (close / minimize / fullscreen).
    var onAction: ((Int, WindowAction) -> Void)? { get set }
}

// MARK: - F2 additions (default no-ops so the build stays green until implemented)

/// Extra per-window status the panel can't compute itself (supplied by the controller).
struct SwitcherBadges: OptionSet, Hashable {
    let rawValue: Int
    static let otherSpace = SwitcherBadges(rawValue: 1 << 0)
    static let otherScreen = SwitcherBadges(rawValue: 1 << 1)
}

@MainActor
protocol SwitcherPresentingF2: SwitcherPresenting {
    /// Shows the current search query (empty string = hide the search field). Items are already filtered.
    func setSearchQuery(_ query: String)
    /// Controller-computed badges, keyed by window id. Applied on the next `show`.
    func setBadges(_ badges: [CGWindowID: SwitcherBadges])
    /// Full-size preview of the selected window at its on-screen frame (AltTab "preview"); nil hides it.
    func showPreview(of window: WindowInfo?, image: CGImage?)
    /// Applies the appearance theme (system / light / dark).
    func setTheme(_ theme: Appearance.Theme)
}

extension SwitcherPresentingF2 {
    func setSearchQuery(_ query: String) {}
    func setBadges(_ badges: [CGWindowID: SwitcherBadges]) {}
    func showPreview(of window: WindowInfo?, image: CGImage?) {}
    func setTheme(_ theme: Appearance.Theme) {}
}

// MARK: - Desktops (Task View only)

/// One tile of Task View's desktop strip.
struct DesktopItem: Identifiable, Hashable {
    let desktop: Desktop
    /// "Desktop 2" / "Masaüstü 2", or the full-screen app's name.
    let title: String
    /// Icons of the apps with windows on this desktop, most recent first (a handful at most).
    let appIcons: [NSImage]
    var id: SpaceID { desktop.id }
}

@MainActor
protocol SwitcherPresentingDesktops: AnyObject {
    /// Desktops for the strip at the bottom of Task View. An empty array (or a single desktop) hides
    /// the strip. Applied on the next `show`; ignored by the non-Task-View styles.
    func setDesktops(_ desktops: [DesktopItem])
    /// Keyboard focus inside the strip: the highlighted tile, or nil when the window grid has focus.
    func updateDesktopSelection(_ index: Int?)
    /// A desktop tile was clicked.
    var onDesktopClick: ((Int) -> Void)? { get set }
}

/// Remove once `SwitcherPanel` implements the F2 methods itself (kept here so the build stays green).
extension SwitcherPanel: SwitcherPresentingF2 {}
