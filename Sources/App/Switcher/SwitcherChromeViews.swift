import AppKit

// Views that make up the panel's "chrome": the opacity tint over the vibrancy, the display-only
// search field, and the full-size preview window.

// MARK: - Tint

/// A rounded, appearance-aware tint layer drawn over the visual effect view. `.hudWindow` alone is very
/// transparent on busy backgrounds; this darkens (dark appearance) or lightens (light appearance) it
/// so thumbnails and titles stay readable, similar to Windows / AltTab. Never intercepts the mouse.
@MainActor
final class PanelTintView: NSView {
    static let darkTint = NSColor(white: 0.07, alpha: 0.62)
    static let lightTint = NSColor(white: 0.97, alpha: 0.66)

    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer.backgroundColor = (isDark ? Self.darkTint : Self.lightTint).cgColor
            layer.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Search field

/// Display-only search field: magnifier + the typed text (or a "Type to search" hint). Keystrokes
/// arrive through the controller; this view is never editable, never first responder and lets all
/// mouse events fall through.
@MainActor
final class SwitcherSearchBar: NSView {
    static let hint = String(localized: "Type to search")
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var query = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingHead // keep the end of a long query visible
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setQuery("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setQuery(_ newQuery: String) {
        query = newQuery
        if newQuery.isEmpty {
            label.stringValue = Self.hint
            label.textColor = .tertiaryLabelColor
            setAccessibilityLabel("Search")
            setAccessibilityValue(nil)
        } else {
            label.stringValue = newQuery
            label.textColor = .labelColor
            setAccessibilityLabel("Search")
            setAccessibilityValue(newQuery)
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = CGRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        let labelHeight: CGFloat = 18
        label.frame = CGRect(x: 32, y: ((h - labelHeight) / 2).rounded(), width: max(0, bounds.width - 32 - 12), height: labelHeight)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            layer.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            layer.borderWidth = 0.5
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Preview window

/// Content of the preview window: the window image aspect-fit, over a dim backdrop, with a hairline border.
@MainActor
final class SwitcherPreviewView: NSView {
    private let imageLayer = CALayer()
    private let dimLayer = CALayer()

    var image: CGImage? {
        didSet {
            imageLayer.contents = image
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        layer.cornerRadius = 8
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        layer.addSublayer(imageLayer)
        layer.addSublayer(dimLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        dimLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}

/// Borderless, non-activating, click-through window that sits just below the switcher panel and shows
/// the selected window at its real position. Like the panel it never becomes key and joins every
/// Space (including full-screen ones).
@MainActor
final class SwitcherPreviewWindow: NSPanel {
    private let previewView = SwitcherPreviewView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        // Just below the panel (`.popUpMenu`), above regular and floating windows.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = true
        contentView = previewView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `image` filling `cocoaFrame` (global Cocoa coordinates).
    func present(image: CGImage, cocoaFrame: CGRect) {
        previewView.image = image
        if frame != cocoaFrame { setFrame(cocoaFrame, display: false) }
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
        previewView.image = nil // drop the (possibly large) image
    }
}
