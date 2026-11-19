import AppKit
import VitrinCore

/// Style-specific cell rendering. `SwitcherPanel` only talks to this protocol (for sizing) and to
/// `SwitcherCellView` (which delegates its sub-view layout here), so a new style is a renderer plus a
/// `case` below — no panel changes.
@MainActor
protocol SwitcherCellRenderer {
    /// Cell geometry for a given base thumbnail width (see `SwitcherSizing`) on a screen with `screenSize`
    /// usable points.
    func metrics(baseThumbnailWidth: CGFloat, screenSize: CGSize) -> CellMetrics
    /// Cell geometry for a profile's `SwitcherSize`. `reservedHeight` is all chrome outside the grid
    /// (search bar + footer) — only `.auto` needs it. Default: fixed sizes via `SwitcherSizing`, `.auto` via
    /// `autoMetrics`.
    func metrics(for size: SwitcherSize, itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics
    /// `.auto`: the largest cells that fit `itemCount` windows (see `AutoSizer`). Default: medium.
    func autoMetrics(itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics
    /// Positions/shows/hides the cell's sub-views — every renderer sets the visibility of *all* shared
    /// sub-views, because cells are recycled between styles. Depends only on `cell.metrics`,
    /// `cell.thumbnailAspect`, the cell's visible badges and its label texts — never on `cell.bounds` —
    /// so it can run before the frame is set.
    func layoutContents(of cell: SwitcherCellView)
    /// Whether the style draws window thumbnails (otherwise the controller's captures are ignored).
    var usesThumbnails: Bool { get }
    /// Height reserved under the grid for the selected window's title (0 = none).
    var footerHeight: CGFloat { get }
}

extension SwitcherCellRenderer {
    func metrics(for size: SwitcherSize, itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics {
        if size == .auto {
            return autoMetrics(itemCount: itemCount, screenSize: screenSize, reservedHeight: reservedHeight)
        }
        let base = SwitcherSizing.baseThumbnailWidth(for: size, screenSize: screenSize, itemCount: itemCount)
        return metrics(baseThumbnailWidth: base, screenSize: screenSize)
    }

    func autoMetrics(itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics {
        metrics(baseThumbnailWidth: SwitcherSizing.medium, screenSize: screenSize)
    }
}

@MainActor
enum SwitcherCellRenderers {
    /// Exhaustive on purpose: adding a `SwitcherStyle` case breaks the build until it is handled here.
    static func renderer(for style: SwitcherStyle) -> SwitcherCellRenderer {
        switch style {
        case .thumbnails: return thumbnails
        case .appIcons: return appIcons
        case .titles: return titles
        case .taskView: return taskView
        }
    }

    private static let thumbnails = ThumbnailsRenderer()
    private static let appIcons = AppIconsRenderer()
    private static let titles = TitlesRenderer()
    private static let taskView = TaskViewRenderer()
}

/// Window thumbnail + overlapping app icon + one-line title + status badges + hover buttons.
@MainActor
struct ThumbnailsRenderer: SwitcherCellRenderer {
    static let badgeDiameter: CGFloat = 18
    static let buttonDiameter: CGFloat = 16
    static let overlayMargin: CGFloat = 6

    var usesThumbnails: Bool { true }
    var footerHeight: CGFloat { 0 }

    func metrics(baseThumbnailWidth: CGFloat, screenSize: CGSize) -> CellMetrics {
        CellMetrics(thumbnailWidth: baseThumbnailWidth)
    }

    func autoMetrics(itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics {
        let template = metrics(baseThumbnailWidth: SwitcherSizing.medium, screenSize: screenSize)
        let width = AutoSizer.steppedThumbnailWidth(
            count: itemCount, screenSize: screenSize, metrics: template, reservedHeight: reservedHeight
        )
        return template.withThumbnailWidth(width)
    }

    func layoutContents(of cell: SwitcherCellView) {
        Self.layoutThumbnailCell(of: cell, style: CellStyle(
            iconSide: cell.metrics.thumbnailWidth < 180 ? 24 : 28,
            iconInsetX: 6, iconOverhang: 8, titleGap: 10, titleHeight: 16,
            titleFont: .systemFont(ofSize: 12, weight: .medium), titleAlignment: .left
        ))
    }

    /// The few numbers that differ between the thumbnails style and the task view cell.
    struct CellStyle {
        /// Side of the app icon at the bottom-left of the thumbnail.
        var iconSide: CGFloat
        var iconInsetX: CGFloat
        /// How far the icon hangs below the thumbnail's bottom edge.
        var iconOverhang: CGFloat
        /// Gap between the thumbnail area and the title line, and the title line's height.
        var titleGap: CGFloat
        var titleHeight: CGFloat
        var titleFont: NSFont
        var titleAlignment: NSTextAlignment
    }

    /// Shared cell layout of the thumbnails style and the task view: thumbnail (or placeholder icon),
    /// overlapping app icon, one-line title below, hover buttons top-left, badges top-right.
    static func layoutThumbnailCell(of cell: SwitcherCellView, style: CellStyle) {
        let m = cell.metrics
        cell.appIconView.isHidden = false
        cell.titleLabel.isHidden = false
        cell.appNameLabel.isHidden = true
        cell.setIconShadow(true)
        cell.titleLabel.font = style.titleFont
        cell.titleLabel.alignment = style.titleAlignment
        cell.titleLabel.textColor = .labelColor
        let thumb = m.thumbnailSize
        let area = CGRect(x: m.inset, y: m.inset, width: thumb.width, height: thumb.height)

        // Thumbnail (aspect-fit) or large centered app icon placeholder.
        let anchor: CGRect
        if let aspect = cell.thumbnailAspect, aspect > 0 {
            let fitted = Self.aspectFit(aspect: aspect, in: area)
            cell.thumbnailView.frame = fitted
            cell.thumbnailView.isHidden = false
            cell.placeholderIconView.isHidden = true
            anchor = fitted
        } else {
            let side = (min(area.width, area.height) * 0.6).rounded()
            cell.placeholderIconView.frame = CGRect(
                x: (area.midX - side / 2).rounded(), y: (area.midY - side / 2).rounded(), width: side, height: side
            )
            cell.placeholderIconView.isHidden = false
            cell.thumbnailView.isHidden = true
            anchor = area
        }

        // Small app icon overlapping the bottom-left corner of the thumbnail.
        let iconSide = style.iconSide
        cell.appIconView.frame = CGRect(
            x: anchor.minX + style.iconInsetX, y: anchor.maxY + style.iconOverhang - iconSide,
            width: iconSide, height: iconSide
        )

        // Title, one line, middle-truncated.
        cell.titleLabel.frame = CGRect(x: m.inset, y: area.maxY + style.titleGap, width: thumb.width, height: style.titleHeight)

        // Hover buttons, top-left of the cell (over the thumbnail).
        let d = Self.buttonDiameter
        for (i, entry) in cell.actionButtons.enumerated() {
            entry.view.frame = CGRect(
                x: m.inset + Self.overlayMargin + CGFloat(i) * (d + 6), y: m.inset + Self.overlayMargin, width: d, height: d
            )
        }

        // Status badges, top-right, right-to-left.
        let b = Self.badgeDiameter
        var x = area.maxX - Self.overlayMargin - b
        for badge in CellBadges.displayOrder {
            guard let view = cell.badgeView(for: badge), !view.isHidden else { continue }
            view.frame = CGRect(x: x, y: m.inset + Self.overlayMargin, width: b, height: b)
            x -= b + 4
        }
    }

    /// Largest rect with the given aspect (w/h) that fits in `area`, centered, pixel-aligned.
    static func aspectFit(aspect: CGFloat, in area: CGRect) -> CGRect {
        let areaAspect = area.width / max(area.height, 1)
        var w = area.width
        var h = area.height
        if aspect > areaAspect {
            h = w / aspect
        } else {
            w = h * aspect
        }
        w = max(1, w.rounded())
        h = max(1, h.rounded())
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }
}

/// Windows-classic style: one square cell per window with a big app icon; the selected window's title
/// is shown by the panel in a label under the grid (`footerHeight`).
@MainActor
struct AppIconsRenderer: SwitcherCellRenderer {
    static let minIconSide: CGFloat = 64
    static let badgeDiameter: CGFloat = 18

    var usesThumbnails: Bool { false }
    var footerHeight: CGFloat { 34 }

    func metrics(baseThumbnailWidth: CGFloat, screenSize: CGSize) -> CellMetrics {
        var m = CellMetrics(thumbnailWidth: SwitcherSizing.iconSide(forBaseThumbnailWidth: baseThumbnailWidth))
        m.shape = .icon
        m.inset = 12
        m.spacing = 6
        m.minThumbnailWidth = Self.minIconSide
        return m
    }

    /// Icon side 64…192 pt, as large as fits all windows (stepped, see `AutoSizer`).
    func autoMetrics(itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics {
        let template = metrics(baseThumbnailWidth: SwitcherSizing.medium, screenSize: screenSize)
        let side = AutoSizer.steppedThumbnailWidth(
            count: itemCount, screenSize: screenSize, metrics: template, reservedHeight: reservedHeight
        )
        return template.withThumbnailWidth(side)
    }

    func layoutContents(of cell: SwitcherCellView) {
        let m = cell.metrics
        cell.thumbnailView.isHidden = true
        cell.placeholderIconView.isHidden = true
        cell.titleLabel.isHidden = true
        cell.appNameLabel.isHidden = true
        cell.appIconView.isHidden = false
        cell.setIconShadow(true)

        let side = m.thumbnailSize.width
        cell.appIconView.frame = CGRect(x: m.inset, y: m.inset, width: side, height: side)

        // Hover buttons: top-left, over the icon.
        let d = ThumbnailsRenderer.buttonDiameter
        for (i, entry) in cell.actionButtons.enumerated() {
            entry.view.frame = CGRect(x: 4 + CGFloat(i) * (d + 4), y: 4, width: d, height: d)
        }

        // Status badges: bottom-right of the icon, right-to-left.
        let b = Self.badgeDiameter
        var x = m.inset + side - b
        for badge in CellBadges.displayOrder {
            guard let view = cell.badgeView(for: badge), !view.isHidden else { continue }
            view.frame = CGRect(x: x, y: m.inset + side - b, width: b, height: b)
            x -= b + 2
        }
    }
}

/// Vertical list: app icon, bold window title, secondary app name, hover buttons and badges on the right.
@MainActor
struct TitlesRenderer: SwitcherCellRenderer {
    var usesThumbnails: Bool { false }
    var footerHeight: CGFloat { 0 }

    func metrics(baseThumbnailWidth: CGFloat, screenSize: CGSize) -> CellMetrics {
        var m = CellMetrics(thumbnailWidth: baseThumbnailWidth)
        m.shape = .row
        m.inset = 0
        m.captionHeight = 0
        m.spacing = 2
        m.panelPadding = 16
        m.minThumbnailWidth = baseThumbnailWidth // never shrinks; long lists scroll
        m.rowWidth = ListSizing.rowWidth(screenWidth: screenSize.width, panelPadding: m.panelPadding)
        m.rowHeight = ListSizing.rowHeight(forBaseThumbnailWidth: baseThumbnailWidth)
        m.forcedColumns = 1
        return m
    }

    func layoutContents(of cell: SwitcherCellView) {
        let m = cell.metrics
        cell.thumbnailView.isHidden = true
        cell.placeholderIconView.isHidden = true
        cell.appIconView.isHidden = false
        cell.titleLabel.isHidden = false
        cell.setIconShadow(false)

        cell.titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        cell.titleLabel.alignment = .left
        cell.titleLabel.textColor = .labelColor
        cell.appNameLabel.font = .systemFont(ofSize: 12)
        cell.appNameLabel.textColor = .secondaryLabelColor

        let visibleBadges = CellBadges.displayOrder.compactMap { badge in
            cell.badgeView(for: badge).flatMap { $0.isHidden ? nil : $0 }
        }
        let row = ListRowLayout.compute(
            rowWidth: m.rowWidth, rowHeight: m.rowHeight, badgeCount: visibleBadges.count,
            // Measure the string itself: a reused, truncating label reports its old (narrow) frame
            // as intrinsic width, which made list rows truncate to "Ch…PT".
            titleTextWidth: ceil(cell.titleLabel.attributedStringValue.size().width) + 4,
            appNameTextWidth: cell.appNameLabel.stringValue.isEmpty
                ? 0 : ceil(cell.appNameLabel.attributedStringValue.size().width) + 4
        )
        cell.appIconView.frame = row.icon
        cell.titleLabel.frame = row.title
        if let appName = row.appName {
            cell.appNameLabel.frame = appName
            cell.appNameLabel.isHidden = false
        } else {
            cell.appNameLabel.isHidden = true
        }
        for (entry, frame) in zip(cell.actionButtons, row.buttons) { entry.view.frame = frame }
        for (view, frame) in zip(visibleBadges, row.badges) { view.frame = frame }
    }
}
