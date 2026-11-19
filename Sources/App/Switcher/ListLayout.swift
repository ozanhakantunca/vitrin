// Pure layout math for the `titles` list style, the `appIcons` sizing and the preview window frame.
// Foundation/CoreGraphics only, so an App test target can compile this file in isolation.
import CoreGraphics
import Foundation

/// Width / height decisions for the `titles` style (vertical list).
enum ListSizing {
    /// The list panel is ~45 % of the screen's usable width, clamped so it stays readable on small
    /// screens and doesn't become absurdly wide on big ones.
    static let widthFraction: CGFloat = 0.45
    static let minPanelWidth: CGFloat = 420
    static let maxPanelWidth: CGFloat = 1100

    /// Row width (= cell width) for a list on a screen `screenWidth` points wide whose panel has
    /// `panelPadding` on each side. The panel never exceeds 90 % of the screen (`GridLayout`'s clamp).
    static func rowWidth(screenWidth: CGFloat, panelPadding: CGFloat) -> CGFloat {
        let ninety = (screenWidth * GridLayout.maxScreenFraction).rounded(.down)
        let panel = min(max(screenWidth * widthFraction, minPanelWidth), min(maxPanelWidth, ninety))
        return max(1, (panel - 2 * panelPadding).rounded(.down))
    }

    /// Row height by thumbnail base width (the size setting is expressed as a base width, see `SwitcherSizing`).
    static func rowHeight(forBaseThumbnailWidth base: CGFloat) -> CGFloat {
        if base <= SwitcherSizing.small { return 34 }
        if base <= SwitcherSizing.medium { return 40 }
        return 48
    }
}

/// Frames (cell-local, top-left origin) of every element of one `titles` row.
///
/// ```
/// | icon | Title (bold)  App name (secondary) …          [✕][–][⤢]  (badges) |
/// ```
/// The three hover buttons always reserve their space (so the text doesn't jump when hovering);
/// badges sit at the far right.
struct ListRowLayout: Equatable {
    var icon: CGRect
    var title: CGRect
    /// `nil` when there is no room / no app name to show.
    var appName: CGRect?
    /// Left to right: close, minimize, fullscreen.
    var buttons: [CGRect]
    /// Right to left, in the order of the visible badges passed in.
    var badges: [CGRect]

    static let horizontalPadding: CGFloat = 12
    static let iconSide: CGFloat = 20
    static let iconGap: CGFloat = 10
    static let textGap: CGFloat = 8
    static let textHeight: CGFloat = 16
    static let badgeDiameter: CGFloat = 18
    static let badgeSpacing: CGFloat = 4
    static let buttonDiameter: CGFloat = 16
    static let buttonSpacing: CGFloat = 6
    static let buttonCount = 3
    static let clusterGap: CGFloat = 10
    /// The app name never takes more than this share of the text area (the title has priority).
    static let appNameMaxShare: CGFloat = 0.35

    static var buttonClusterWidth: CGFloat {
        CGFloat(buttonCount) * buttonDiameter + CGFloat(buttonCount - 1) * buttonSpacing
    }

    /// - Parameters:
    ///   - titleTextWidth / appNameTextWidth: natural (unwrapped) text widths; `0` hides the app name.
    static func compute(
        rowWidth: CGFloat, rowHeight: CGFloat, badgeCount: Int,
        titleTextWidth: CGFloat, appNameTextWidth: CGFloat
    ) -> ListRowLayout {
        let centerY = { (height: CGFloat) in ((rowHeight - height) / 2).rounded() }
        let icon = CGRect(x: horizontalPadding, y: centerY(iconSide), width: iconSide, height: iconSide)

        // Right side, from the edge inwards: badges, then the (always reserved) button cluster.
        var right = rowWidth - horizontalPadding
        var badges: [CGRect] = []
        for _ in 0..<max(0, badgeCount) {
            let x = right - badgeDiameter
            badges.append(CGRect(x: x, y: centerY(badgeDiameter), width: badgeDiameter, height: badgeDiameter))
            right = x - badgeSpacing
        }
        if badgeCount > 0 { right += badgeSpacing - clusterGap }

        let buttonsLeft = right - buttonClusterWidth
        let buttons = (0..<buttonCount).map { i in
            CGRect(
                x: buttonsLeft + CGFloat(i) * (buttonDiameter + buttonSpacing), y: centerY(buttonDiameter),
                width: buttonDiameter, height: buttonDiameter
            )
        }

        // Text area between icon and the right cluster: title first, app name after it.
        let textLeft = icon.maxX + iconGap
        let available = max(0, buttonsLeft - clusterGap - textLeft)
        let appWidth = appNameTextWidth > 0 ? min(appNameTextWidth, (available * appNameMaxShare).rounded(.down)) : 0
        let gap = appWidth >= 1 ? textGap : 0
        let titleWidth = min(titleTextWidth, max(0, available - appWidth - gap)).rounded(.up)
        let title = CGRect(x: textLeft, y: centerY(textHeight), width: titleWidth, height: textHeight)
        let appName = appWidth >= 1
            ? CGRect(x: title.maxX + gap, y: centerY(textHeight), width: appWidth.rounded(.down), height: textHeight)
            : nil
        return ListRowLayout(icon: icon, title: title, appName: appName, buttons: buttons, badges: badges)
    }
}

/// Conversion between the tracker's global top-left-origin frames and Cocoa's bottom-left origin.
enum PreviewGeometry {
    /// `primaryScreenHeight` is `NSScreen.screens[0].frame.height`: Cocoa's global origin is the
    /// bottom-left of the primary screen, while CGWindowList/AX frames use its top-left.
    static func cocoaFrame(fromGlobalTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
