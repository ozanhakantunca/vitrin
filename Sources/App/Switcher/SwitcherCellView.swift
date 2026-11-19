import AppKit
import UniformTypeIdentifiers
import VitrinCore
import VitrinSystem

// MARK: - Badges

/// Status badges shown on a cell. Minimized / hidden / fullscreen are derived from `WindowInfo`;
/// `.otherSpace` / `.otherScreen` are supplied by the controller via `SwitcherPanel.setBadges(_:)`
/// (`SwitcherBadges`, converted with `init(_: SwitcherBadges)`).
struct CellBadges: OptionSet, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let minimized = CellBadges(rawValue: 1 << 0)
    static let hidden = CellBadges(rawValue: 1 << 1)
    static let fullscreen = CellBadges(rawValue: 1 << 2)
    static let otherSpace = CellBadges(rawValue: 1 << 3)
    static let otherScreen = CellBadges(rawValue: 1 << 4)

    /// Right-to-left display order.
    static let displayOrder: [CellBadges] = [.otherScreen, .otherSpace, .fullscreen, .hidden, .minimized]

    var symbolName: String {
        switch self {
        case .minimized: return "minus"
        case .hidden: return "eye.slash"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .otherScreen: return "display"
        default: return "square.on.square.dashed" // .otherSpace
        }
    }

    var title: String {
        switch self {
        case .minimized: return "Minimized"
        case .hidden: return "Hidden"
        case .fullscreen: return "Full screen"
        case .otherScreen: return "On another display"
        default: return "On another Space"
        }
    }

    init(window: WindowInfo) {
        var badges: CellBadges = []
        if window.isMinimized { badges.insert(.minimized) }
        if window.isAppHidden { badges.insert(.hidden) }
        if window.isFullscreen { badges.insert(.fullscreen) }
        self = badges
    }

    init(_ external: SwitcherBadges) {
        var badges: CellBadges = []
        if external.contains(.otherSpace) { badges.insert(.otherSpace) }
        if external.contains(.otherScreen) { badges.insert(.otherScreen) }
        self = badges
    }
}

// MARK: - Small helper views

/// Top-left-origin container, so cell and grid coordinates read like the layout math (y grows downward).
final class SwitcherFlippedView: NSView {
    /// Reports clicks on the empty part of the grid (cells and buttons handle their own); window coordinates.
    var onBackgroundMouseDown: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let onBackgroundMouseDown {
            onBackgroundMouseDown(event.locationInWindow)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// A round colored disc with an SF Symbol. With `onPress` it is a button (fires on mouse-up inside);
/// without, it is a passive badge.
@MainActor
final class SymbolDiscView: NSView {
    var onPress: (() -> Void)? {
        didSet { setAccessibilityElement(onPress != nil) }
    }
    private let fill: NSColor
    private let imageView = NSImageView()
    private var isPressed = false { didSet { alphaValue = isPressed ? 0.7 : 1 } }

    init(symbolName: String, accessibilityTitle: String, diameter: CGFloat, fill: NSColor, tint: NSColor) {
        self.fill = fill
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let config = NSImage.SymbolConfiguration(pointSize: diameter * 0.55, weight: .bold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityTitle)?
            .withSymbolConfiguration(config)
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        setAccessibilityLabel(accessibilityTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = bounds.width / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Passive badges let clicks fall through to the cell.
        onPress == nil ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onPress?() }
    }
}

/// Displays one `CGImage` through its layer, with rounded corners and a hairline border.
@MainActor
final class SwitcherThumbnailView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

// MARK: - Cell

/// One window in the grid. Owns its sub-views; their positions come from the style's
/// `SwitcherCellRenderer`. Mouse handling is per cell (tracking area + clicks), reported to the panel
/// through closures.
@MainActor
final class SwitcherCellView: NSView {
    // Identity / state
    var index = 0
    private(set) var windowID: CGWindowID = 0
    private(set) var metrics = CellMetrics(thumbnailWidth: SwitcherSizing.medium)
    private(set) var isSelected = false
    private(set) var isHovered = false
    private(set) var badges: CellBadges = []
    /// width / height of the current thumbnail image; `nil` while showing the app-icon placeholder.
    private(set) var thumbnailAspect: CGFloat?

    // Events (set once by the panel)
    var onMouseMoved: ((SwitcherCellView) -> Void)?
    var onMouseExited: ((SwitcherCellView) -> Void)?
    var onClick: ((SwitcherCellView) -> Void)?
    var onAction: ((SwitcherCellView, WindowAction) -> Void)?

    // Sub-views (laid out by the renderer)
    let thumbnailView = SwitcherThumbnailView()
    let placeholderIconView = NSImageView()
    let appIconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    /// Secondary app name (`titles` style only).
    let appNameLabel = NSTextField(labelWithString: "")
    private(set) var actionButtons: [(action: WindowAction, view: SymbolDiscView)] = []
    private var badgeViews: [CellBadges: SymbolDiscView] = [:]
    private var renderer: SwitcherCellRenderer?

    private static let fallbackIcon: NSImage = NSWorkspace.shared.icon(for: UTType.application)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        addSubview(placeholderIconView)
        addSubview(thumbnailView)
        addSubview(appIconView)
        addSubview(titleLabel)
        addSubview(appNameLabel)

        for iconView in [placeholderIconView, appIconView] {
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.isEditable = false
        }
        appIconView.wantsLayer = true
        setIconShadow(true)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true

        appNameLabel.font = .systemFont(ofSize: 12)
        appNameLabel.textColor = .secondaryLabelColor
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.maximumNumberOfLines = 1
        appNameLabel.usesSingleLineMode = true
        appNameLabel.isHidden = true

        let d = ThumbnailsRenderer.buttonDiameter
        let buttonSpecs: [(WindowAction, String, String, NSColor)] = [
            (.close, "xmark", "Close", .systemRed),
            (.minimize, "minus", "Minimize", .systemYellow),
            (.toggleFullscreen, "arrow.up.left.and.arrow.down.right", "Full screen", .systemGreen),
        ]
        for (action, symbol, title, color) in buttonSpecs {
            let button = SymbolDiscView(
                symbolName: symbol, accessibilityTitle: title, diameter: d,
                fill: color, tint: NSColor.black.withAlphaComponent(0.65)
            )
            button.isHidden = true
            button.onPress = { [weak self] in
                guard let self else { return }
                self.onAction?(self, action)
            }
            addSubview(button)
            actionButtons.append((action, button))
        }

        for badge in CellBadges.displayOrder {
            let view = SymbolDiscView(
                symbolName: badge.symbolName, accessibilityTitle: badge.title,
                diameter: ThumbnailsRenderer.badgeDiameter,
                fill: NSColor.black.withAlphaComponent(0.55), tint: .white
            )
            view.isHidden = true
            addSubview(view)
            badgeViews[badge] = view
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Configuration

    func configure(
        item: SwitcherItem, index: Int, metrics: CellMetrics,
        renderer: SwitcherCellRenderer, extraBadges: CellBadges
    ) {
        let window = item.window
        if windowID != window.id { setThumbnail(nil) }
        windowID = window.id
        self.index = index
        self.metrics = metrics
        self.renderer = renderer

        let icon = item.appIcon ?? Self.fallbackIcon
        appIconView.image = icon
        placeholderIconView.image = icon
        titleLabel.stringValue = window.title.isEmpty ? window.appName : window.title
        // The list shows the app name next to the title; without a title the title label already is the app name.
        appNameLabel.stringValue = window.title.isEmpty ? "" : window.appName
        setAccessibilityLabel(window.title.isEmpty ? window.appName : "\(window.title), \(window.appName)")

        applyBadges(CellBadges(window: window).union(extraBadges), relayout: false)
        setSelected(false)
        setHovered(false)
        renderer.layoutContents(of: self)
    }

    /// Resets everything that depends on a specific window (used when the panel hides).
    func reset() {
        setThumbnail(nil)
        setSelected(false)
        setHovered(false)
        windowID = 0
    }

    func applyBadges(_ newBadges: CellBadges, relayout: Bool = true) {
        badges = newBadges
        for (badge, view) in badgeViews { view.isHidden = !newBadges.contains(badge) }
        if relayout { renderer?.layoutContents(of: self) }
    }

    /// The app icon's drop shadow (wanted when it floats over a thumbnail or stands alone, not in list rows).
    func setIconShadow(_ enabled: Bool) {
        guard enabled != (appIconView.shadow != nil) else { return }
        if enabled {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            appIconView.shadow = shadow
        } else {
            appIconView.shadow = nil
        }
    }

    func badgeView(for badge: CellBadges) -> SymbolDiscView? { badgeViews[badge] }

    func setThumbnail(_ image: CGImage?) {
        thumbnailView.image = image
        if let image, image.height > 0 {
            thumbnailAspect = CGFloat(image.width) / CGFloat(image.height)
        } else {
            thumbnailAspect = nil
        }
        renderer?.layoutContents(of: self)
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        for entry in actionButtons { entry.view.isHidden = !hovered }
    }

    // MARK: Layer / appearance

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = metrics.shape == .row ? 8 : 10
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                let accent = NSColor.controlAccentColor
                layer.backgroundColor = accent.withAlphaComponent(0.30).cgColor
                layer.borderColor = accent.cgColor
                layer.borderWidth = 2
            } else {
                layer.backgroundColor = NSColor.clear.cgColor
                layer.borderColor = NSColor.clear.cgColor
                layer.borderWidth = 0
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates. Only the hover buttons are interactive children;
        // everything else belongs to the cell so labels / images never swallow clicks.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if isHovered {
            for entry in actionButtons where !entry.view.isHidden && entry.view.frame.contains(local) {
                return entry.view
            }
        }
        return self
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?(self) }
    override func mouseExited(with event: NSEvent) { onMouseExited?(self) }
    override func mouseDown(with event: NSEvent) { onClick?(self) }
}
