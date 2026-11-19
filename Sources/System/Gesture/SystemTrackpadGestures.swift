// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Reads the user's system trackpad gesture settings to detect gestures that fight Vitrin's three-finger
// swipe. MultitouchSupport only *observes* contact frames, it cannot swallow them: if macOS also uses a
// three-finger horizontal swipe, both fire (Vitrin opens the switcher while the Dock slides to the next
// Space / full-screen app). AltTab documents the same limitation. The fix is on the user's side:
//
//     System Settings → Trackpad → More Gestures →
//       "Swipe between full-screen applications": Swipe Left or Right with Four Fingers
//       "Swipe between pages": Scroll Left or Right with Two Fingers (or Off)
//
// and, if enabled, turn off Accessibility → Pointer Control → Trackpad Options → "Use trackpad for
// dragging: Three Finger Drag" (it turns every three-finger move into a drag).

import CoreFoundation

/// The relevant keys of `com.apple.AppleMultitouchTrackpad` (built-in trackpad) and
/// `com.apple.driver.AppleBluetoothMultitouch.trackpad` (Magic Trackpad). System Settings writes both.
public struct SystemTrackpadGestures: Sendable, Hashable {
    public static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]
    public static let horizontalSwipeKey = "TrackpadThreeFingerHorizSwipeGesture"
    public static let threeFingerDragKey = "TrackpadThreeFingerDrag"

    /// `TrackpadThreeFingerHorizSwipeGesture`.
    public enum HorizontalSwipe: Int, Sendable, Hashable {
        /// No three-finger horizontal system gesture.
        case off = 0
        /// Three-finger swipe between pages (back / forward in browsers, Finder, …).
        case pages = 1
        /// Three-finger swipe between full-screen apps / Spaces. macOS's default.
        case spaces = 2
    }

    /// The most conflicting horizontal-swipe setting across the domains (`nil` if no domain has the key).
    public var horizontalSwipe: HorizontalSwipe?
    /// Three Finger Drag is on in any domain.
    public var threeFingerDrag: Bool

    public init(horizontalSwipe: HorizontalSwipe?, threeFingerDrag: Bool) {
        self.horizontalSwipe = horizontalSwipe
        self.threeFingerDrag = threeFingerDrag
    }

    /// Builds the settings from a preference reader `(key, domain) -> Int?` (injectable for tests).
    public init(reading value: (_ key: String, _ domain: String) -> Int?) {
        let swipes = Self.domains.compactMap { value(Self.horizontalSwipeKey, $0) }
        horizontalSwipe = swipes.compactMap(HorizontalSwipe.init(rawValue:)).max { $0.rawValue < $1.rawValue }
            ?? (swipes.isEmpty ? nil : .off)
        threeFingerDrag = Self.domains.contains { (value(Self.threeFingerDragKey, $0) ?? 0) != 0 }
    }

    /// The user's current settings, read through CFPreferences (no sandbox, so other apps' domains are readable).
    public static func current() -> SystemTrackpadGestures {
        SystemTrackpadGestures { key, domain in
            CFPreferencesAppSynchronize(domain as CFString)
            guard let raw = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
            if CFGetTypeID(raw) == CFNumberGetTypeID() {
                var number = 0
                return CFNumberGetValue((raw as! CFNumber), .nsIntegerType, &number) ? number : nil
            }
            if CFGetTypeID(raw) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((raw as! CFBoolean)) ? 1 : 0
            }
            return nil
        }
    }

    /// Whether a system gesture also reacts to three fingers moving horizontally.
    /// `nil` horizontal setting = key never written = macOS default, which is `.spaces`.
    public var conflictsWithThreeFingerSwipe: Bool {
        threeFingerDrag || (horizontalSwipe ?? .spaces) != .off
    }
}
