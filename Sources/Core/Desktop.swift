import Foundation

/// One Mission Control Space on a display, as shown in Task View's desktop strip.
public struct Desktop: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A normal desktop. `number` is 1-based and counts only normal desktops on this display,
        /// matching the "Desktop N" labels in Mission Control.
        case desktop(number: Int)
        /// A full-screen app's Space (or a split view). Labeled with the app's name in the UI.
        case fullscreen
    }

    public var id: SpaceID
    public var kind: Kind
    /// SkyLight display identifier (a display UUID, or "Main" when displays don't have separate Spaces).
    public var displayIdentifier: String
    /// The Space currently visible on its display.
    public var isCurrent: Bool
    /// Position in Mission Control order on its display (0-based, all kinds counted).
    public var index: Int

    public init(id: SpaceID, kind: Kind, displayIdentifier: String, isCurrent: Bool, index: Int) {
        self.id = id
        self.kind = kind
        self.displayIdentifier = displayIdentifier
        self.isCurrent = isCurrent
        self.index = index
    }
}
