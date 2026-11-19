// The `taskView` style: a calm, full-screen overview (Windows "Task View"-like).
// - `TaskViewLayout` (TaskViewLayout.swift): pure layout math for a grid centered in the screen.
// - `TaskViewRenderer`: the cell renderer (large thumbnail, icon bottom-left, centered title below).
// - `TaskViewDimView`: the ~60 % black dim over the blurred backdrop.
// `SwitcherPanel` switches into task-view "mode" (full visible-frame window, dim, no HUD frame) when the
// profile's style is `.taskView`; the other styles never touch this code.
import AppKit
import VitrinCore

// MARK: - Renderer

/// Large window thumbnail, app icon at its bottom-left corner, centered title underneath. Same hover
/// buttons / badges as the thumbnails style. Always auto-fitted (min 220 pt); the profile's size only caps
/// the maximum (`SwitcherSizing.taskViewMaxWidth`).
@MainActor
struct TaskViewRenderer: SwitcherCellRenderer {
    var usesThumbnails: Bool { true }
    var footerHeight: CGFloat { 0 }

    func metrics(baseThumbnailWidth: CGFloat, screenSize: CGSize) -> CellMetrics {
        var m = CellMetrics(thumbnailWidth: baseThumbnailWidth)
        m.inset = 10
        m.captionHeight = 36   // 14 gap + 18 title line + 4
        m.spacing = 24
        m.panelPadding = 48
        m.minThumbnailWidth = AutoSizer.Bounds.taskView().min
        return m
    }

    func metrics(for size: SwitcherSize, itemCount: Int, screenSize: CGSize, reservedHeight: CGFloat) -> CellMetrics {
        let bounds = AutoSizer.Bounds.taskView(max: SwitcherSizing.taskViewMaxWidth(for: size))
        let template = metrics(baseThumbnailWidth: bounds.max, screenSize: screenSize)
        // The whole screen minus `panelPadding` is usable (fraction 1): the panel *is* the screen.
        let width = AutoSizer.steppedThumbnailWidth(
            count: itemCount, screenSize: screenSize, metrics: template,
            reservedHeight: reservedHeight, screenFraction: 1, bounds: bounds
        )
        return template.withThumbnailWidth(width)
    }

    func layoutContents(of cell: SwitcherCellView) {
        ThumbnailsRenderer.layoutThumbnailCell(of: cell, style: ThumbnailsRenderer.CellStyle(
            iconSide: 36, iconInsetX: 8, iconOverhang: 10, titleGap: 14, titleHeight: 18,
            titleFont: .systemFont(ofSize: 13, weight: .medium), titleAlignment: .center
        ))
    }
}

// MARK: - Dim backdrop

/// Black dim over the blurred effect view (task view). Never intercepts the mouse.
@MainActor
final class TaskViewDimView: NSView {
    static let dimAlpha: CGFloat = 0.60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Click catcher

/// The panel's visual effect view; reports clicks that no cell / button handled (the empty dim
/// background in task view). The location is in window coordinates.
@MainActor
final class SwitcherBackdropView: NSVisualEffectView {
    var onBackgroundMouseDown: ((NSPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?(event.locationInWindow)
    }
}
