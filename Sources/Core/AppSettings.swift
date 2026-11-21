import Foundation

/// Everything persisted in `~/.config/vitrin/config.json`.
public struct AppSettings: Sendable, Hashable, Codable {
    /// Bump when the on-disk format changes incompatibly, and add a step to `ConfigMigrator.standard`.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profiles: [ShortcutProfile]
    public var appExceptions: [AppException]
    public var appearance: Appearance
    public var launchAtLogin: Bool
    public var showMenuBarIcon: Bool
    public var showDesktopsInTaskView: Bool
    /// Three-finger horizontal swipe opens the switcher (uses the private MultitouchSupport framework).
    public var trackpadGesture: Bool
    /// Periodically check GitHub Releases for a newer Vitrin.
    public var checkForUpdates: Bool

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        profiles: [ShortcutProfile] = ShortcutProfile.defaultProfiles,
        appExceptions: [AppException] = [],
        appearance: Appearance = Appearance(),
        launchAtLogin: Bool = true,
        showMenuBarIcon: Bool = true,
        trackpadGesture: Bool = false,
        checkForUpdates: Bool = true,
        showDesktopsInTaskView: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.appExceptions = appExceptions
        self.appearance = appearance
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.showDesktopsInTaskView = showDesktopsInTaskView
        self.trackpadGesture = trackpadGesture
        self.checkForUpdates = checkForUpdates
    }

    /// Built-in defaults. Unlike `AppSettings()`, these include `AppException.builtInDefaults`.
    public static let defaults = AppSettings(appExceptions: AppException.builtInDefaults)

    enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles, appExceptions, appearance, launchAtLogin, showMenuBarIcon
        case trackpadGesture, checkForUpdates, showDesktopsInTaskView
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        self.init(
            schemaVersion: c.decode(.schemaVersion, or: d.schemaVersion, decoder),
            // A missing key means "use defaults"; an explicit `[]` is respected.
            profiles: c.decodeLossyArray(.profiles, or: d.profiles, decoder),
            appExceptions: c.decodeLossyArray(.appExceptions, or: d.appExceptions, decoder),
            appearance: c.decode(.appearance, or: d.appearance, decoder),
            launchAtLogin: c.decode(.launchAtLogin, or: d.launchAtLogin, decoder),
            showMenuBarIcon: c.decode(.showMenuBarIcon, or: d.showMenuBarIcon, decoder),
            trackpadGesture: c.decode(.trackpadGesture, or: d.trackpadGesture, decoder),
            checkForUpdates: c.decode(.checkForUpdates, or: d.checkForUpdates, decoder),
            showDesktopsInTaskView: c.decode(.showDesktopsInTaskView, or: d.showDesktopsInTaskView, decoder)
        )
    }

    /// Profiles that are enabled and have a shortcut.
    public var activeProfiles: [ShortcutProfile] {
        profiles.filter { $0.isEnabled && $0.trigger != nil }
    }

    public func exception(forBundleIdentifier bundleID: String?) -> AppException? {
        guard let bundleID else { return nil }
        return appExceptions.first { $0.bundleIdentifier == bundleID }
    }
}

/// Per-application overrides (e.g. VMs and remote-desktop clients that need the shortcut themselves).
public struct AppException: Sendable, Hashable, Codable {
    public var bundleIdentifier: String
    public var hide: HideRule
    /// While this app is frontmost, Vitrin's shortcuts are passed through to it.
    public var ignoreShortcutsWhenFrontmost: Bool

    public enum HideRule: String, Sendable, Hashable, Codable, CaseIterable {
        case never
        case always
        /// Hide the app's (windowless) entry only when it has no open windows.
        ///
        /// Currently equivalent to `.never`, and intentionally not filtered in Core: the tracker models
        /// windows only, so an app with zero windows never produces a switcher entry in the first place.
        /// The rule becomes meaningful only if windowless-app entries are added (see docs/BACKLOG.md).
        case whenNoOpenWindows
    }

    public init(bundleIdentifier: String, hide: HideRule = .never, ignoreShortcutsWhenFrontmost: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.hide = hide
        self.ignoreShortcutsWhenFrontmost = ignoreShortcutsWhenFrontmost
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier, hide, ignoreShortcutsWhenFrontmost
    }

    /// VMs, remote-desktop and game-streaming clients: they need ⌥⇥ / ⌘⇥ for the remote/guest system.
    /// Bundle ids cross-checked against AltTab's `Preferences.defaultExceptions()` (GPL-3.0,
    /// github.com/lwouis/alt-tab-macos). Matching is exact, so Parallels lists its VM window process.
    public static let builtInDefaults: [AppException] = [
        "com.microsoft.rdc.macos",            // Microsoft Remote Desktop / Windows App
        "com.microsoft.rdc.mac",              // Microsoft Remote Desktop 8 (legacy)
        "com.apple.ScreenSharing",            // Screen Sharing
        "com.parallels.desktop.console",      // Parallels Desktop (VM windows)
        "com.vmware.fusion",                  // VMware Fusion
        "com.utmapp.UTM",                     // UTM
        "org.virtualbox.app.VirtualBoxVM",    // VirtualBox (VM windows)
        "com.teamviewer.TeamViewer",          // TeamViewer
        "com.philandro.anydesk",              // AnyDesk
        "tv.parsec.www",                      // Parsec
        "com.moonlight-stream.Moonlight",     // Moonlight
        "com.citrix.receiver.icaviewer.mac",  // Citrix Workspace (session viewer)
    ].map { AppException(bundleIdentifier: $0, ignoreShortcutsWhenFrontmost: true) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The bundle id is the only required field: an exception without it is meaningless.
        let bundleID = try c.decode(String.self, forKey: .bundleIdentifier)
        self.init(
            bundleIdentifier: bundleID,
            hide: c.decode(.hide, or: .never, decoder),
            ignoreShortcutsWhenFrontmost: c.decode(.ignoreShortcutsWhenFrontmost, or: false, decoder)
        )
    }
}

public struct Appearance: Sendable, Hashable, Codable {
    public var theme: Theme
    public var showOnScreen: ShowOnScreen
    /// Show the selected window full-size at its real position while switching.
    public var showPreview: Bool

    public enum Theme: String, Sendable, Hashable, Codable, CaseIterable {
        case system, light, dark
    }

    public enum ShowOnScreen: String, Sendable, Hashable, Codable, CaseIterable {
        /// The display holding the focused window / active menu bar.
        case active
        case withMouse
        /// The display with the menu bar in System Settings (`NSScreen.screens[0]`).
        case main
    }

    public init(theme: Theme = .system, showOnScreen: ShowOnScreen = .active, showPreview: Bool = false) {
        self.theme = theme
        self.showOnScreen = showOnScreen
        self.showPreview = showPreview
    }

    enum CodingKeys: String, CodingKey { case theme, showOnScreen, showPreview }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance()
        self.init(
            theme: c.decode(.theme, or: d.theme, decoder),
            showOnScreen: c.decode(.showOnScreen, or: d.showOnScreen, decoder),
            showPreview: c.decode(.showPreview, or: d.showPreview, decoder)
        )
    }
}

// MARK: - Validation

public enum ValidationIssue: Sendable, Hashable, CustomStringConvertible {
    /// Two enabled profiles could fire on the same keystroke.
    case conflictingTriggers(profileID: String, otherProfileID: String, trigger: KeyCombo)
    case duplicateProfileID(String)
    case duplicateAppException(bundleIdentifier: String)
    /// `profileID`'s trigger is `otherProfileID`'s trigger plus Shift. Shift held on a trigger means
    /// "open in reverse" for the other profile, so the two would fire on the same keystroke.
    case shiftReverseConflict(profileID: String, otherProfileID: String, trigger: KeyCombo)

    public var description: String {
        switch self {
        case let .conflictingTriggers(a, b, trigger):
            return "profiles \"\(a)\" and \"\(b)\" both use \(trigger.stringValue)"
        case let .duplicateProfileID(id):
            return "more than one profile has id \"\(id)\""
        case let .duplicateAppException(bundleID):
            return "more than one app exception for \(bundleID)"
        case let .shiftReverseConflict(a, b, trigger):
            return "profile \"\(a)\" uses \(trigger.stringValue), which is the reverse (Shift) of profile \"\(b)\""
        }
    }
}

extension AppSettings {
    /// Semantic problems a hand-edited config may contain. Never throws; the app decides how to surface them.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        var seenIDs = Set<String>()
        for profile in profiles where !seenIDs.insert(profile.id).inserted {
            issues.append(.duplicateProfileID(profile.id))
        }

        let active = activeProfiles
        for i in active.indices {
            for j in active.indices where j > i {
                guard let a = active[i].trigger, let b = active[j].trigger, a.conflicts(with: b) else { continue }
                issues.append(.conflictingTriggers(profileID: active[i].id, otherProfileID: active[j].id, trigger: a))
            }
        }

        // Shift reverses a trigger, so `X+shift` collides with another profile's `X`.
        // (A profile can't pair with itself: one side must have Shift and the other must not.)
        for shifted in active {
            for base in active {
                guard let s = shifted.trigger, let b = base.trigger,
                      s.modifiers.contains(.shift), !b.modifiers.contains(.shift),
                      s.modifiers == b.modifiers.union(.shift),
                      !s.key.possibleKeyCodes.isDisjoint(with: b.key.possibleKeyCodes)
                else { continue }
                issues.append(.shiftReverseConflict(profileID: shifted.id, otherProfileID: base.id, trigger: s))
            }
        }

        var seenBundles = Set<String>()
        for exception in appExceptions where !seenBundles.insert(exception.bundleIdentifier).inserted {
            issues.append(.duplicateAppException(bundleIdentifier: exception.bundleIdentifier))
        }
        return issues
    }
}
