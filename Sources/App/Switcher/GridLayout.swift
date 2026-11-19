// Pure layout math for the switcher grid. Foundation/CoreGraphics only so it can be unit-tested
// without AppKit (an App test target can compile this file in isolation).
import CoreGraphics
import Foundation

/// Geometry of one switcher cell. Three shapes:
/// - `.thumbnail`: `inset` padding, a thumbnail area, a caption strip (`captionHeight`: gap + one-line
///   title), `inset` padding. The selection highlight fills the whole cell.
/// - `.icon` (appIcons style): a square, `thumbnailWidth` is the icon side; no caption (the selected
///   title is shown by the panel under the grid).
/// - `.row` (titles style): a `rowWidth` x `rowHeight` list row; the grid is forced to one column.
struct CellMetrics: Equatable {
    enum Shape: Equatable { case thumbnail, icon, row }

    var shape: Shape = .thumbnail
    /// Width of the thumbnail area (the "160 / 220 / 300 pt" of the spec); the icon side for `.icon`.
    var thumbnailWidth: CGFloat
    /// Width / height of the thumbnail area (16:10, like most displays).
    var thumbnailAspect: CGFloat = 16.0 / 10.0
    /// Padding between the cell edge and its content (also the highlight margin).
    var inset: CGFloat = 10
    /// Space under the thumbnail area reserved for the title (10 pt gap + 16 pt text line).
    var captionHeight: CGFloat = 26
    /// Gap between neighbouring cells.
    var spacing: CGFloat = 8
    /// Padding between the panel edge and the grid.
    var panelPadding: CGFloat = 20
    /// Smallest thumbnail width the grid may shrink to before it starts scrolling.
    var minThumbnailWidth: CGFloat = 120
    /// `.row` only.
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 40
    /// When set the grid always has exactly this many columns (1 for the list).
    var forcedColumns: Int?

    var thumbnailSize: CGSize {
        switch shape {
        case .thumbnail:
            return CGSize(width: thumbnailWidth, height: (thumbnailWidth / thumbnailAspect).rounded(.down))
        case .icon:
            return CGSize(width: thumbnailWidth, height: thumbnailWidth)
        case .row:
            return .zero
        }
    }

    var cellSize: CGSize {
        let thumb = thumbnailSize
        switch shape {
        case .thumbnail:
            return CGSize(width: thumb.width + 2 * inset, height: thumb.height + captionHeight + 2 * inset)
        case .icon:
            return CGSize(width: thumb.width + 2 * inset, height: thumb.height + 2 * inset)
        case .row:
            return CGSize(width: rowWidth, height: rowHeight)
        }
    }

    func withThumbnailWidth(_ width: CGFloat) -> CellMetrics {
        var copy = self
        copy.thumbnailWidth = width
        return copy
    }
}

/// Result of laying `count` cells out on a screen.
struct GridLayout: Equatable {
    /// Number of columns in a full row (always >= 1, so arrow-key math never divides by zero).
    /// Truthful for the controller's up/down mapping (`index ± columns`), also when the last row is centered.
    var columns: Int
    var rows: Int
    var count: Int
    /// Metrics after any shrinking.
    var metrics: CellMetrics
    var cellSize: CGSize { metrics.cellSize }
    var thumbnailSize: CGSize { metrics.thumbnailSize }
    /// Width of the cell block (`columns` cells + spacing), without padding.
    var gridWidth: CGFloat
    /// Full size of the grid including panel padding (the scroll view's document size).
    var contentSize: CGSize
    /// Panel chrome (search bar, footer label) that sits outside the scroll area, included in `panelSize`.
    var reservedHeight: CGFloat
    /// Size of the panel window: `contentSize` + `reservedHeight`, clamped to the screen fraction.
    var panelSize: CGSize
    /// `true` when the grid is taller than the panel and must scroll vertically.
    var scrolls: Bool
    /// Centers a shorter last row horizontally (4+4+3 → the 3 sit in the middle).
    var centersLastRow: Bool
    /// Extra space above the first row (task view centers a short grid vertically). 0 for the HUD.
    var verticalOffset: CGFloat = 0

    /// The panel never exceeds this fraction of the screen's visible frame in either dimension.
    static let maxScreenFraction: CGFloat = 0.9
    /// How much the thumbnail width shrinks per iteration while searching for a fit.
    static let shrinkStep: CGFloat = 4
    /// Height of the (padding-less) grid area when there are no cells ("No matching windows").
    static let emptyStateHeight: CGFloat = 28

    /// Size of the scroll view (the panel minus the reserved chrome).
    var scrollAreaHeight: CGFloat { panelSize.height - reservedHeight }

    /// Number of cells in the last row (== `columns` when it is full).
    var lastRowCount: Int {
        guard count > 0, rows > 0 else { return 0 }
        return count - (rows - 1) * columns
    }

    /// Top-left origin of the cell at `index` inside the document view (flipped coordinates).
    ///
    /// Centered last row: the cells of a short last row are shifted right by half the missing cells, but
    /// keep their index-space column (`index % columns`). So up/down (`index ∓ columns`) still lands on
    /// the cell directly above/below in *index* space; visually it can be up to half a cell off.
    func cellOrigin(at index: Int) -> CGPoint {
        let column = index % columns
        let row = index / columns
        let pad = metrics.panelPadding
        let step = cellSize.width + metrics.spacing
        // Slack when the panel is wider than the grid (minimum panel width): center the block.
        var x = pad + max(0, contentSize.width - 2 * pad - gridWidth) / 2 + CGFloat(column) * step
        if centersLastRow, rows > 1, row == rows - 1, lastRowCount < columns {
            x += CGFloat(columns - lastRowCount) * step / 2
        }
        return CGPoint(x: x.rounded(), y: pad + verticalOffset + CGFloat(row) * (cellSize.height + metrics.spacing))
    }

    /// Lays out `count` cells of base size `cell` on a screen whose usable area is `screenSize`.
    ///
    /// 1. Columns are as many as fit in 90 % of the width (or `cell.forcedColumns`); rows are then
    ///    balanced (`columns = ceil(count / rows)`) so 11 windows become 4+4+3, not 5+5+1.
    /// 2. If the grid is too tall (90 % of the height, minus `reservedHeight`) the thumbnail shrinks in
    ///    `shrinkStep` steps down to `cell.minThumbnailWidth`, re-flowing each time.
    /// 3. If it still doesn't fit, the panel is clamped to 90 % of the height and `scrolls` is set.
    static func compute(
        count: Int, screenSize: CGSize, cell: CellMetrics,
        reservedHeight: CGFloat = 0, minPanelWidth: CGFloat = 0, centersLastRow: Bool = true
    ) -> GridLayout {
        let n = max(count, 0)
        let maxWidth = (screenSize.width * maxScreenFraction).rounded(.down)
        let maxHeight = (screenSize.height * maxScreenFraction).rounded(.down)
        let pad = cell.panelPadding
        let spacing = cell.spacing
        let availableWidth = maxWidth - 2 * pad
        let availableHeight = maxHeight - reservedHeight - 2 * pad
        let minWidth = min(cell.minThumbnailWidth, cell.thumbnailWidth)

        var metrics = cell
        var columns = 1
        var rows = 0
        while true {
            let size = metrics.cellSize
            let fit = max(1, cell.forcedColumns
                ?? Int(((availableWidth + spacing) / (size.width + spacing)).rounded(.down)))
            (columns, rows) = arrange(count: n, maxColumns: fit)
            let height = n == 0 ? emptyStateHeight : gridExtent(rows, size.height, spacing)
            if height <= availableHeight || metrics.thumbnailWidth <= minWidth { break }
            metrics = metrics.withThumbnailWidth(max(minWidth, metrics.thumbnailWidth - shrinkStep))
        }

        let size = metrics.cellSize
        let gridWidth = gridExtent(n == 0 ? 0 : columns, size.width, spacing)
        let gridHeight = n == 0 ? emptyStateHeight : gridExtent(rows, size.height, spacing)
        let contentWidth = max(2 * pad + gridWidth, minPanelWidth)
        let contentHeight = 2 * pad + gridHeight
        let panelSize = CGSize(
            width: min(contentWidth, maxWidth),
            height: min(contentHeight + reservedHeight, maxHeight)
        )
        return GridLayout(
            columns: columns,
            rows: rows,
            count: n,
            metrics: metrics,
            gridWidth: gridWidth,
            contentSize: CGSize(width: contentWidth, height: contentHeight),
            reservedHeight: reservedHeight,
            panelSize: panelSize,
            scrolls: contentHeight + reservedHeight > maxHeight,
            centersLastRow: centersLastRow
        )
    }

    /// Balanced (columns, rows) for `count` items given at most `maxColumns` columns.
    static func arrange(count: Int, maxColumns: Int) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (1, 0) }
        let rows = (count + maxColumns - 1) / maxColumns
        let columns = (count + rows - 1) / rows
        return (columns, rows)
    }

    private static func gridExtent(_ number: Int, _ cellExtent: CGFloat, _ spacing: CGFloat) -> CGFloat {
        guard number > 0 else { return 0 }
        return CGFloat(number) * cellExtent + CGFloat(number - 1) * spacing
    }
}
