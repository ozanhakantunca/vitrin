// Pure auto-sizing math (`SwitcherSize.auto`). Foundation/CoreGraphics only, so it is unit-testable.
//
// Goal: the largest cell for which *all* windows still fit on the screen without scrolling.
// It searches over the column count: for `c` columns there are `r = ceil(n / c)` rows, and the cell
// width is bounded both by the width budget (`c` cells + gaps) and by the height budget (`r` cells + gaps).
// The best `c` is the one that allows the widest cell; near-ties (within 2 %) go to the grid whose aspect
// ratio is closest to the screen's.
//
// Search stability (live search re-layout): `bestThumbnailWidth` is continuous, but the panel uses
// `steppedThumbnailWidth`, which snaps the result *down* to a fixed ladder of widths (`Bounds.ladder`).
// While the user types, the item count changes on every keystroke; with the ladder the cell size only
// changes when the count crosses a threshold (a few times over the whole 1…60 range), so most keystrokes
// just drop cells and shrink the panel — the thumbnails don't resize (and aren't re-captured).
import CoreGraphics
import Foundation

enum AutoSizer {
    /// Allowed range and the snapping ladder for one kind of cell.
    struct Bounds: Equatable {
        var min: CGFloat
        var max: CGFloat
        /// Ascending. `stepped` snaps to the largest value <= the candidate (and >= `min`).
        var ladder: [CGFloat]

        /// Window thumbnails (thumbnails style): 120 … 420 pt.
        static let thumbnails = Bounds(min: 120, max: 420, ladder: [120, 140, 160, 180, 200, 220, 250, 280, 320, 360, 420])
        /// App icon side (appIcons style): 64 … 192 pt.
        static let icons = Bounds(min: 64, max: 192, ladder: [64, 80, 96, 112, 128, 144, 160, 176, 192])
        /// Task view thumbnails: 220 … `max` (cap chosen by the profile's size setting, up to 480).
        static func taskView(max: CGFloat = 480) -> Bounds {
            let ladder: [CGFloat] = [220, 250, 280, 320, 360, 400, 440, 480]
            let cap = Swift.max(220, Swift.min(max, 480))
            return Bounds(min: 220, max: cap, ladder: ladder.filter { $0 <= cap })
        }

        /// The default bounds for a cell shape.
        static func forShape(_ shape: CellMetrics.Shape) -> Bounds {
            shape == .icon ? .icons : .thumbnails
        }
    }

    /// Result of the search.
    struct Fit: Equatable {
        var columns: Int
        var rows: Int
        /// Thumbnail width (icon side for `.icon` cells), whole points, within `Bounds`.
        var width: CGFloat
    }

    /// Fraction of the screen the content may use (same as `GridLayout`).
    static var defaultScreenFraction: CGFloat { GridLayout.maxScreenFraction }

    /// Best thumbnail width (icon side for `.icon`) so that `count` cells fit on `screenSize` without
    /// scrolling, as large as possible within `bounds`. If even `bounds.min` doesn't fit, returns `min`
    /// (the grid then shrinks no further and scrolls).
    ///
    /// - Parameters:
    ///   - metrics: cell template (inset, caption, aspect, spacing, panel padding, shape). `.row` returns
    ///     `metrics.thumbnailWidth` unchanged.
    ///   - reservedHeight: chrome outside the grid (search bar, footer) that the grid can't use.
    ///   - screenFraction: share of the screen the whole panel may take (0.9 for the HUD, 1 for task view).
    static func bestThumbnailWidth(
        count: Int, screenSize: CGSize, metrics: CellMetrics,
        reservedHeight: CGFloat = 0, screenFraction: CGFloat? = nil, bounds: Bounds? = nil
    ) -> CGFloat {
        bestFit(count: count, screenSize: screenSize, metrics: metrics,
                reservedHeight: reservedHeight, screenFraction: screenFraction, bounds: bounds).width
    }

    /// `bestThumbnailWidth` snapped down to `bounds.ladder` — what the panel uses.
    static func steppedThumbnailWidth(
        count: Int, screenSize: CGSize, metrics: CellMetrics,
        reservedHeight: CGFloat = 0, screenFraction: CGFloat? = nil, bounds: Bounds? = nil
    ) -> CGFloat {
        let resolved = bounds ?? .forShape(metrics.shape)
        let best = bestThumbnailWidth(
            count: count, screenSize: screenSize, metrics: metrics,
            reservedHeight: reservedHeight, screenFraction: screenFraction, bounds: resolved
        )
        return stepped(best, ladder: resolved.ladder)
    }

    /// Largest ladder value <= `width` (the first rung if `width` is below the ladder).
    static func stepped(_ width: CGFloat, ladder: [CGFloat]) -> CGFloat {
        guard let first = ladder.first else { return width }
        return ladder.last(where: { $0 <= width }) ?? first
    }

    static func bestFit(
        count: Int, screenSize: CGSize, metrics: CellMetrics,
        reservedHeight: CGFloat = 0, screenFraction: CGFloat? = nil, bounds: Bounds? = nil
    ) -> Fit {
        let resolved = bounds ?? .forShape(metrics.shape)
        guard metrics.shape != .row else {
            return Fit(columns: 1, rows: max(count, 0), width: metrics.thumbnailWidth)
        }
        // Zero results ("No matching windows") sizes like one item, so the cells don't jump to the cap.
        let n = max(count, 1)
        let fraction = screenFraction ?? defaultScreenFraction
        let pad = metrics.panelPadding
        let spacing = metrics.spacing
        let availableWidth = (screenSize.width * fraction).rounded(.down) - 2 * pad
        let availableHeight = (screenSize.height * fraction).rounded(.down) - reservedHeight - 2 * pad

        // Cell height = heightFactor * width + heightConstant (thumbnail: width / aspect + caption + 2 inset;
        // icon: width + 2 inset). Cell width = width + 2 inset.
        let heightFactor: CGFloat = metrics.shape == .icon ? 1 : 1 / max(metrics.thumbnailAspect, 0.1)
        let heightConstant: CGFloat = (metrics.shape == .icon ? 0 : metrics.captionHeight) + 2 * metrics.inset
        let widthConstant = 2 * metrics.inset
        let screenAspect = screenSize.height > 0 ? screenSize.width / screenSize.height : 1.6

        struct Candidate { var columns: Int; var rows: Int; var width: CGFloat; var aspectError: CGFloat }
        var candidates: [Candidate] = []
        for c in 1...n {
            let r = (n + c - 1) / c
            guard (n + r - 1) / r == c else { continue } // same grid as a smaller c (balanced rows)
            let byWidth = (availableWidth - CGFloat(c - 1) * spacing) / CGFloat(c) - widthConstant
            let byHeight = ((availableHeight - CGFloat(r - 1) * spacing) / CGFloat(r) - heightConstant) / heightFactor
            let width = min(max(min(byWidth, byHeight).rounded(.down), resolved.min), resolved.max)
            let cellWidth = width + widthConstant
            let cellHeight = (heightFactor * width).rounded(.down) + heightConstant
            let gridWidth = CGFloat(c) * cellWidth + CGFloat(c - 1) * spacing
            let gridHeight = CGFloat(r) * cellHeight + CGFloat(r - 1) * spacing
            let error = abs(log(max(gridWidth, 1) / max(gridHeight, 1) / screenAspect))
            candidates.append(Candidate(columns: c, rows: r, width: width, aspectError: error))
        }

        let widest = candidates.map(\.width).max() ?? resolved.min
        let best = candidates
            .filter { $0.width >= widest * 0.98 }
            .min { $0.aspectError < $1.aspectError } ?? Candidate(columns: 1, rows: n, width: resolved.min, aspectError: 0)
        return Fit(columns: best.columns, rows: best.rows, width: best.width)
    }
}
