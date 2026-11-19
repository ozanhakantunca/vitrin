// Pure layout math for the task view (full-screen grid). Foundation/CoreGraphics only, so it is unit-testable.
import CoreGraphics
import Foundation

enum TaskViewLayout {
    /// Search bar: top-center, `searchTopMargin` below the top of the visible frame.
    static let searchTopMargin: CGFloat = 28
    static let searchHeight: CGFloat = 36
    static let searchWidth: CGFloat = 440
    /// Space between the search bar and the grid area.
    static let searchGap: CGFloat = 20
    /// Chrome above the grid; the grid is centered in what is left.
    static var reservedHeight: CGFloat { searchTopMargin + searchHeight + searchGap }

    /// Centered desktop tiles in panel coordinates (origin at bottom-left).
    struct DesktopStrip {
        static let captionHeight: CGFloat = 24
        let frame: CGRect
        let tileWidth: CGFloat
        let spacing: CGFloat

        init(count: Int, screenWidth: CGFloat) {
            guard count > 1 else {
                frame = .zero
                tileWidth = 0
                spacing = 0
                return
            }
            let naturalWidth = CGFloat(count) * 160 + CGFloat(count - 1) * 12
            let scale = min(1, max(0, screenWidth - 48) / naturalWidth)
            tileWidth = 160 * scale
            spacing = 12 * scale
            let width = naturalWidth * scale
            frame = CGRect(x: (screenWidth - width) / 2, y: 24,
                           width: width, height: 96 * scale + Self.captionHeight)
        }

        var reservedHeight: CGFloat { frame.maxY }

        func tileFrame(at index: Int) -> CGRect {
            CGRect(x: CGFloat(index) * (tileWidth + spacing), y: 0, width: tileWidth, height: frame.height)
        }
    }

    /// Lays `count` cells out in a full-screen panel: balanced rows, centered horizontally and (when it
    /// fits) vertically. Shrinks the thumbnail in `GridLayout.shrinkStep` steps down to
    /// `cell.minThumbnailWidth`, then scrolls vertically. Reuses `GridLayout` as the result type
    /// (`panelSize` == `screenSize`, `contentSize` fills the scroll area, `verticalOffset` centers a short grid).
    static func compute(count: Int, screenSize: CGSize, cell: CellMetrics, stripHeight: CGFloat = 0) -> GridLayout {
        let n = max(count, 0)
        let pad = cell.panelPadding
        let spacing = cell.spacing
        let reserved = reservedHeight + stripHeight
        let availableWidth = screenSize.width - 2 * pad
        let availableHeight = screenSize.height - reserved - 2 * pad
        let minWidth = min(cell.minThumbnailWidth, cell.thumbnailWidth)

        var metrics = cell
        var columns = 1
        var rows = 0
        while true {
            let size = metrics.cellSize
            let fit = max(1, Int(((availableWidth + spacing) / (size.width + spacing)).rounded(.down)))
            (columns, rows) = GridLayout.arrange(count: n, maxColumns: fit)
            let height = n == 0 ? GridLayout.emptyStateHeight : extent(rows, size.height, spacing)
            if height <= availableHeight || metrics.thumbnailWidth <= minWidth { break }
            metrics = metrics.withThumbnailWidth(max(minWidth, metrics.thumbnailWidth - GridLayout.shrinkStep))
        }

        let size = metrics.cellSize
        let gridWidth = extent(n == 0 ? 0 : columns, size.width, spacing)
        let gridHeight = n == 0 ? GridLayout.emptyStateHeight : extent(rows, size.height, spacing)
        let scrollArea = max(0, screenSize.height - reserved)
        let contentHeight = 2 * pad + gridHeight
        let scrolls = contentHeight > scrollArea
        return GridLayout(
            columns: columns,
            rows: rows,
            count: n,
            metrics: metrics,
            gridWidth: gridWidth,
            contentSize: CGSize(width: screenSize.width, height: max(contentHeight, scrollArea)),
            reservedHeight: reserved,
            panelSize: screenSize,
            scrolls: scrolls,
            centersLastRow: true,
            verticalOffset: scrolls ? 0 : ((scrollArea - contentHeight) / 2).rounded(.down)
        )
    }

    private static func extent(_ number: Int, _ cellExtent: CGFloat, _ spacing: CGFloat) -> CGFloat {
        guard number > 0 else { return 0 }
        return CGFloat(number) * cellExtent + CGFloat(number - 1) * spacing
    }
}
