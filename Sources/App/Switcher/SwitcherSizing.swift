import CoreGraphics
import VitrinCore

/// The single place that turns a profile's `SwitcherSize` into a thumbnail width.
/// `.auto` is resolved by `AutoSizer` (the screen and item count are passed in for that).
enum SwitcherSizing {
    static let small: CGFloat = 160
    static let medium: CGFloat = 220
    static let large: CGFloat = 300

    /// Height of the HUD's search chrome (14 pt top margin + 30 pt field); `GridLayout`'s `reservedHeight`.
    static let hudChromeHeight: CGFloat = 44

    /// Task view: the profile's size caps the auto-fit width (it is always auto-fitted, min 220 pt).
    static func taskViewMaxWidth(for size: SwitcherSize) -> CGFloat {
        switch size {
        case .small: return 280
        case .medium: return 360
        case .large, .auto: return 480
        }
    }

    static func baseThumbnailWidth(for size: SwitcherSize, screenSize: CGSize, itemCount: Int) -> CGFloat {
        switch size {
        case .small: return small
        case .medium: return medium
        case .large: return large
        case .auto:
            // Largest thumbnail that fits `itemCount` cells on the screen (thumbnails-style metrics; the
            // panel itself asks the renderer, which also covers icons / task view). Stepped, see `AutoSizer`.
            return AutoSizer.steppedThumbnailWidth(
                count: itemCount, screenSize: screenSize,
                metrics: CellMetrics(thumbnailWidth: medium), reservedHeight: hudChromeHeight
            )
        }
    }

    /// Icon side for the `appIcons` style: ~96 / 128 / 160 pt for small / medium / large.
    /// Thresholds (not equality) so F3's auto sizing can pass any base width.
    static func iconSide(forBaseThumbnailWidth base: CGFloat) -> CGFloat {
        if base <= small { return 96 }
        if base <= medium { return 128 }
        return 160
    }
}
