import AppKit

/// Desktop tiles sit outside the scrolling window grid.
@MainActor
final class DesktopStripView: NSView {
    var onClick: ((Int) -> Void)?
    private var tiles: [DesktopTileView] = []
    var count: Int { tiles.count }

    func setItems(_ items: [DesktopItem]) {
        for tile in tiles { tile.removeFromSuperview() }
        tiles = items.enumerated().map { index, item in
            let tile = DesktopTileView(item: item)
            tile.onClick = { [weak self] in self?.onClick?(index) }
            addSubview(tile)
            return tile
        }
    }

    func place(using layout: TaskViewLayout.DesktopStrip) {
        frame = layout.frame
        isHidden = frame.isEmpty
        for (index, tile) in tiles.enumerated() { tile.frame = layout.tileFrame(at: index) }
    }

    func select(_ index: Int?) {
        for (i, tile) in tiles.enumerated() { tile.isSelected = i == index }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
private final class DesktopTileView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            setAccessibilitySelected(isSelected)
            needsDisplay = true
        }
    }
    private let isCurrent: Bool
    private let card = NSView()
    private let title: NSTextField
    private let icons: [NSImageView]
    private var hovered = false { didSet { needsDisplay = true } }

    init(item: DesktopItem) {
        isCurrent = item.desktop.isCurrent
        title = NSTextField(labelWithString: item.title)
        icons = item.appIcons.map { NSImageView(image: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        addSubview(card)
        for icon in icons {
            icon.imageScaling = .scaleProportionallyUpOrDown
            card.addSubview(icon)
        }
        title.font = .systemFont(ofSize: 13, weight: isCurrent ? .bold : .medium)
        title.textColor = isCurrent ? .controlAccentColor : .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.usesSingleLineMode = true
        addSubview(title)
        toolTip = item.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let caption = TaskViewLayout.DesktopStrip.captionHeight
        title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 18)
        card.frame = CGRect(x: 0, y: caption, width: bounds.width, height: max(0, bounds.height - caption))
        let scale = bounds.width / 160
        let side = 28 * scale
        let gap = 4 * scale
        let width = CGFloat(icons.count) * (side + gap) - gap
        for (i, icon) in icons.enumerated() {
            let x = (bounds.width - width) / 2 + CGFloat(i) * (side + gap)
            icon.frame = CGRect(x: x, y: (card.bounds.height - side) / 2, width: side, height: side)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            let fill = isSelected ? accent.withAlphaComponent(0.30) : NSColor.white.withAlphaComponent(hovered ? 0.20 : 0.10)
            card.layer?.backgroundColor = fill.cgColor
            card.layer?.borderColor = (isCurrent || isSelected ? accent : NSColor.white.withAlphaComponent(0.24)).cgColor
            card.layer?.borderWidth = isCurrent || isSelected ? 2 : 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
