import Foundation

/// One switcher configuration bound to one shortcut. Vitrin supports any number of profiles.
public struct ShortcutProfile: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier. Built-in profiles use readable slugs; profiles created in the UI use UUIDs.
    public var id: String
    public var name: String
    public var isEnabled: Bool
    /// `nil` = no shortcut assigned yet (profile can't be triggered).
    public var trigger: KeyCombo?
    public var filters: WindowFilters
    public var style: SwitcherStyle
    public var size: SwitcherSize
    public var releaseBehavior: ReleaseBehavior

    public init(
        id: String = UUID().uuidString,
        name: String,
        isEnabled: Bool = true,
        trigger: KeyCombo?,
        filters: WindowFilters = WindowFilters(),
        style: SwitcherStyle = .thumbnails,
        size: SwitcherSize = .auto,
        releaseBehavior: ReleaseBehavior = .focusSelection
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.filters = filters
        self.style = style
        self.size = size
        self.releaseBehavior = releaseBehavior
    }

    enum CodingKeys: String, CodingKey {
        case id, name, trigger, filters, style, size
        case isEnabled = "enabled"
        case releaseBehavior = "onModifierRelease"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ShortcutProfile(name: "Untitled", trigger: nil)
        var id = c.decode(.id, or: fallback.id, decoder)
        if id.isEmpty { id = fallback.id }
        self.init(
            id: id,
            name: c.decode(.name, or: fallback.name, decoder),
            isEnabled: c.decode(.isEnabled, or: fallback.isEnabled, decoder),
            trigger: c.decode(.trigger, or: fallback.trigger, decoder),
            filters: c.decode(.filters, or: fallback.filters, decoder),
            style: c.decode(.style, or: fallback.style, decoder),
            size: c.decode(.size, or: fallback.size, decoder),
            releaseBehavior: c.decode(.releaseBehavior, or: fallback.releaseBehavior, decoder)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        // Explicit null keeps "no shortcut" visible in the file instead of a silently missing key.
        try c.encode(trigger, forKey: .trigger)
        try c.encode(filters, forKey: .filters)
        try c.encode(style, forKey: .style)
        try c.encode(size, forKey: .size)
        try c.encode(releaseBehavior, forKey: .releaseBehavior)
    }
}

/// Which windows a profile shows.
public struct WindowFilters: Sendable, Hashable, Codable {
    public var apps: AppScope
    public var spaces: SpaceScope
    public var screens: ScreenScope
    public var includeMinimized: Bool
    public var includeHidden: Bool
    public var includeFullscreen: Bool

    public init(
        apps: AppScope = .all,
        spaces: SpaceScope = .all,
        screens: ScreenScope = .all,
        includeMinimized: Bool = true,
        includeHidden: Bool = true,
        includeFullscreen: Bool = true
    ) {
        self.apps = apps
        self.spaces = spaces
        self.screens = screens
        self.includeMinimized = includeMinimized
        self.includeHidden = includeHidden
        self.includeFullscreen = includeFullscreen
    }

    enum CodingKeys: String, CodingKey {
        case apps, spaces, screens, includeMinimized, includeHidden, includeFullscreen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowFilters()
        self.init(
            apps: c.decode(.apps, or: d.apps, decoder),
            spaces: c.decode(.spaces, or: d.spaces, decoder),
            screens: c.decode(.screens, or: d.screens, decoder),
            includeMinimized: c.decode(.includeMinimized, or: d.includeMinimized, decoder),
            includeHidden: c.decode(.includeHidden, or: d.includeHidden, decoder),
            includeFullscreen: c.decode(.includeFullscreen, or: d.includeFullscreen, decoder)
        )
    }
}

public enum AppScope: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    /// Only windows of the frontmost application.
    case activeApp
}

public enum SpaceScope: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    /// Only windows on a currently visible Space (one per display when displays have separate Spaces).
    case current
}

public enum ScreenScope: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    /// The display holding the focused window / active menu bar.
    case active
    /// The display under the mouse pointer.
    case withMouse
}

public enum SwitcherStyle: String, Sendable, Hashable, Codable, CaseIterable {
    case thumbnails
    case appIcons
    case titles
    /// Large grid of every window (Windows "Task View"-like).
    case taskView
}

public enum SwitcherSize: String, Sendable, Hashable, Codable, CaseIterable {
    case small, medium, large
    /// Fit the content to the screen.
    case auto
}

public enum ReleaseBehavior: String, Sendable, Hashable, Codable, CaseIterable {
    /// Releasing the held modifiers focuses the selected window (classic Alt+Tab).
    case focusSelection
    /// The switcher stays open after release; choose with click / Return, dismiss with Escape.
    case keepOpen
}

extension ShortcutProfile {
    /// Built-in profile identifiers.
    public enum BuiltinID {
        public static let allWindows = "all-windows"
        public static let currentApp = "current-app"
        public static let taskView = "task-view"
    }

    public static let defaultProfiles: [ShortcutProfile] = [
        ShortcutProfile(
            id: BuiltinID.allWindows,
            name: "All windows",
            trigger: KeyCombo(modifiers: .option, key: .tab),
            style: .thumbnails
        ),
        ShortcutProfile(
            id: BuiltinID.currentApp,
            name: "Current app",
            trigger: KeyCombo(modifiers: .option, key: .keyAboveTab),
            filters: WindowFilters(apps: .activeApp),
            style: .thumbnails
        ),
        ShortcutProfile(
            id: BuiltinID.taskView,
            name: "Task view",
            isEnabled: false,
            trigger: KeyCombo(modifiers: .command, key: .tab),
            style: .taskView,
            size: .large,
            releaseBehavior: .keepOpen
        ),
    ]
}
