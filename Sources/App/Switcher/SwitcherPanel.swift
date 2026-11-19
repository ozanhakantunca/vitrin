import AppKit
import VitrinCore
import VitrinSystem

/// Borderless, non-activating panel: never becomes key/main, so the frontmost app keeps focus.
@MainActor
private final class SwitcherWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        worksWhenModal = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The Alt-Tab style switcher window. Reflects state pushed by `SwitcherController`; owns no policy.
@MainActor
final class SwitcherPanel: SwitcherPresenting {
    // MARK: SwitcherPresenting

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onAction: ((Int, WindowAction) -> Void)?
    /// Task view only: a click on the empty dim background (not on a cell, button or the search bar).
    /// AppDelegate wires it to `controller.close()` (cancel). Not part of `SwitcherPresenting`.
    var onBackgroundClick: (() -> Void)?

    var isVisible: Bool { window.isVisible }
    private(set) var columns = 1

    /// Pixel size the controller should capture thumbnails at. Styles without thumbnails (`appIcons`,
    /// `titles`) return a token size: the captures are ignored by `updateThumbnail`.
    var thumbnailPixelSize: CGSize {
        guard renderer.usesThumbnails else { return Self.tokenThumbnailPixelSize }
        let size = layout?.thumbnailSize ?? Self.defaultThumbnailSize
        return CGSize(width: size.width * backingScale, height: size.height * backingScale)
    }

    // MARK: Extras for the controller (SwitcherPresentingF2)

    /// Light / dark / system override from `AppSettings.appearance.theme`.
    var theme: Appearance.Theme = .system {
        didSet { applyTheme() }
    }

    func setTheme(_ theme: Appearance.Theme) {
        self.theme = theme
    }

    /// Shows the typed query in the (display-only) search field. The field is always visible while the
    /// panel is open — empty shows the "Type to search" hint — so typing never resizes the panel.
    /// The query is cleared on `hide()`.
    func setSearchQuery(_ query: String) {
        searchQuery = query
        searchBar.setQuery(query)
    }

    /// Controller-computed badges (`.otherSpace`, `.otherScreen`), keyed by window id. Merged with the
    /// badges derived from `WindowInfo` (minimized / hidden / fullscreen); applied to live cells at once
    /// and to every later `show`.
    func setBadges(_ badges: [CGWindowID: SwitcherBadges]) {
        externalBadges = badges
        for cell in cells {
            guard let info = currentWindows[cell.windowID] else { continue }
            cell.applyBadges(CellBadges(window: info).union(CellBadges(badges[cell.windowID] ?? [])))
        }
    }

    /// Shows `image` at `window`'s on-screen frame in a click-through window just below the panel.
    /// `nil` window, `nil` image, an empty frame — or a hidden panel (a late async image must never leave
    /// a stray preview behind) — hide it.
    func showPreview(of window: WindowInfo?, image: CGImage?) {
        guard isVisible, let window, let image, !window.frame.isEmpty,
              let primary = NSScreen.screens.first else {
            previewWindow.dismiss()
            return
        }
        let frame = PreviewGeometry.cocoaFrame(fromGlobalTopLeft: window.frame, primaryScreenHeight: primary.frame.height)
        previewWindow.present(image: image, cocoaFrame: frame)
    }

    /// Thumbnail pixel size a `show` with these arguments would produce — lets the controller start
    /// captures before the panel is on screen.
    func thumbnailPixelSize(forItemCount count: Int, profile: ShortcutProfile, on screen: NSScreen) -> CGSize {
        let (layout, _, renderer) = Self.computeLayout(count: count, profile: profile, screen: screen)
        guard renderer.usesThumbnails else { return Self.tokenThumbnailPixelSize }
        let scale = screen.backingScaleFactor
        return CGSize(width: layout.thumbnailSize.width * scale, height: layout.thumbnailSize.height * scale)
    }

    // MARK: State

    private static let cornerRadius: CGFloat = 16
    private static let defaultThumbnailSize = ThumbnailsRenderer()
        .metrics(baseThumbnailWidth: SwitcherSizing.medium, screenSize: .zero).thumbnailSize
    private static let tokenThumbnailPixelSize = CGSize(width: 16, height: 16)

    // Chrome geometry (points). The search bar sits at the top, the selected-title footer (appIcons) at the bottom.
    private static let searchTopMargin: CGFloat = 14
    private static let searchBarHeight: CGFloat = 30
    private static let searchSideMargin: CGFloat = 20
    private static let searchChromeHeight = SwitcherSizing.hudChromeHeight // == searchTopMargin + searchBarHeight
    /// Keeps the search field usable with one or two small cells.
    private static let minPanelWidth: CGFloat = 280

    private let window = SwitcherWindow()
    private let effectView = SwitcherBackdropView()
    private let tintView = PanelTintView(cornerRadius: SwitcherPanel.cornerRadius)
    private let dimView = TaskViewDimView()
    /// `.taskView` profiles switch the panel into a full-screen mode (see `setMode`).
    private var isTaskViewMode = false
    private let searchBar = SwitcherSearchBar()
    private let selectedTitleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No matching windows"))
    private let previewWindow = SwitcherPreviewWindow()
    private var renderer: SwitcherCellRenderer = SwitcherCellRenderers.renderer(for: .thumbnails)
    private var searchQuery = ""
    private var externalBadges: [CGWindowID: SwitcherBadges] = [:]
    private let scrollView = NSScrollView()
    private let gridView = SwitcherFlippedView()

    private var layout: GridLayout?
    private var backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    private var cells: [SwitcherCellView] = []
    private var spareCells: [SwitcherCellView] = []
    private var cellsByWindowID: [CGWindowID: SwitcherCellView] = [:]
    private var currentWindows: [CGWindowID: WindowInfo] = [:]
    private var selectedIndex = -1
    private var hoveredIndex: Int?
    /// Screen position of the pointer when the panel was shown; hover reacts only after real movement.
    private var mouseBaseline = NSPoint.zero
    private var mouseHasMoved = false
    private var isHoverDrivenSelection = false

    init() {
        window.contentView = effectView
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active // stay vibrant although the panel never becomes key
        effectView.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        effectView.onBackgroundMouseDown = { [weak self] point in self?.backgroundMouseDown(atWindowPoint: point) }
        gridView.onBackgroundMouseDown = { [weak self] point in self?.backgroundMouseDown(atWindowPoint: point) }
        dimView.isHidden = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = gridView
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true

        selectedTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        selectedTitleLabel.textColor = .labelColor
        selectedTitleLabel.alignment = .center
        selectedTitleLabel.lineBreakMode = .byTruncatingTail
        selectedTitleLabel.maximumNumberOfLines = 1
        selectedTitleLabel.usesSingleLineMode = true
        selectedTitleLabel.isHidden = true

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // Back to front: tint, scrolling grid, then the fixed chrome on top.
        effectView.addSubview(tintView)
        effectView.addSubview(dimView)
        effectView.addSubview(scrollView)
        effectView.addSubview(emptyLabel)
        effectView.addSubview(selectedTitleLabel)
        effectView.addSubview(searchBar)
        searchBar.setQuery(searchQuery)
        applyTheme()
    }

    // MARK: show / hide

    func show(items: [SwitcherItem], selectedIndex: Int, profile: ShortcutProfile, on screen: NSScreen) {
        let (layout, metrics, renderer) = Self.computeLayout(count: items.count, profile: profile, screen: screen)
        let isTaskView = profile.style == .taskView
        setMode(taskView: isTaskView)
        self.renderer = renderer
        self.layout = layout
        columns = layout.columns
        backingScale = screen.backingScaleFactor

        currentWindows = Dictionary(items.map { ($0.window.id, $0.window) }, uniquingKeysWith: { first, _ in first })
        reconcileCells(items: items, layout: layout, metrics: metrics, renderer: renderer)

        // Geometry.
        let panelSize = layout.panelSize
        let visible = screen.visibleFrame
        if isTaskView {
            // Task view: the window *is* the target screen's visible frame (menu bar and Dock stay uncovered).
            window.setFrame(visible, display: false)
        } else {
            let origin = CGPoint(
                x: (visible.midX - panelSize.width / 2).rounded(),
                y: (visible.midY - panelSize.height / 2).rounded()
            )
            window.setFrame(CGRect(origin: origin, size: panelSize), display: false)
        }
        effectView.frame = CGRect(origin: .zero, size: panelSize)
        tintView.frame = effectView.bounds
        dimView.frame = effectView.bounds

        // Chrome (Cocoa coordinates, origin bottom-left): search bar on top, optional footer at the bottom.
        let footer = renderer.footerHeight
        if isTaskView {
            let width = min(TaskViewLayout.searchWidth, max(0, panelSize.width - 2 * Self.searchSideMargin))
            searchBar.frame = CGRect(
                x: ((panelSize.width - width) / 2).rounded(),
                y: panelSize.height - TaskViewLayout.searchTopMargin - TaskViewLayout.searchHeight,
                width: width,
                height: TaskViewLayout.searchHeight
            )
        } else {
            searchBar.frame = CGRect(
                x: Self.searchSideMargin,
                y: panelSize.height - Self.searchTopMargin - Self.searchBarHeight,
                width: max(0, panelSize.width - 2 * Self.searchSideMargin),
                height: Self.searchBarHeight
            )
        }
        // scrollAreaHeight = panel height - search chrome - footer.
        scrollView.frame = CGRect(x: 0, y: footer, width: panelSize.width, height: layout.scrollAreaHeight)
        selectedTitleLabel.isHidden = footer == 0
        selectedTitleLabel.frame = CGRect(x: 20, y: 10, width: max(0, panelSize.width - 40), height: 18)
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.frame = CGRect(
            x: 0, y: scrollView.frame.midY - 9, width: panelSize.width, height: 18
        )
        scrollView.hasVerticalScroller = layout.scrolls
        gridView.frame = CGRect(origin: .zero, size: layout.contentSize)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Hover starts disarmed: a stationary pointer under the new panel must not select anything.
        hoveredIndex = nil
        mouseBaseline = NSEvent.mouseLocation
        mouseHasMoved = false

        self.selectedIndex = -1
        applySelection(selectedIndex, scroll: true)

        // Same runloop turn, no animation, never activates the app.
        window.orderFrontRegardless()
    }

    func updateSelection(_ index: Int) {
        applySelection(index, scroll: !isHoverDrivenSelection)
    }

    func updateThumbnail(windowID: CGWindowID, image: CGImage) {
        guard renderer.usesThumbnails else { return }
        cellsByWindowID[windowID]?.setThumbnail(image)
    }

    func hide() {
        window.orderOut(nil)
        previewWindow.dismiss()
        searchQuery = ""
        searchBar.setQuery("")
        selectedTitleLabel.stringValue = ""
        hoveredIndex = nil
        selectedIndex = -1
        // Drop thumbnails (they can be large) but keep the views for the next show.
        for cell in cells {
            cell.removeFromSuperview()
            cell.reset()
        }
        spareCells = Array((cells + spareCells).prefix(Self.maxSpareCells))
        cells = []
        cellsByWindowID = [:]
        currentWindows = [:]
    }

    // MARK: Cells

    private static let maxSpareCells = 80

    private func reconcileCells(items: [SwitcherItem], layout: GridLayout, metrics: CellMetrics, renderer: SwitcherCellRenderer) {
        // Active cells are reusable by window id; duplicates and spares are interchangeable.
        var reusable: [CGWindowID: SwitcherCellView] = [:]
        var spares = spareCells
        for cell in cells {
            if reusable[cell.windowID] == nil { reusable[cell.windowID] = cell } else { spares.append(cell) }
        }

        var newCells: [SwitcherCellView] = []
        newCells.reserveCapacity(items.count)
        var newIndex: [CGWindowID: SwitcherCellView] = [:]
        var used = Set<ObjectIdentifier>()

        for (i, item) in items.enumerated() {
            let cell: SwitcherCellView
            if let existing = reusable.removeValue(forKey: item.id) {
                cell = existing
            } else if let spare = spares.popLast() {
                cell = spare
            } else {
                cell = makeCell()
            }
            used.insert(ObjectIdentifier(cell))
            cell.configure(
                item: item, index: i, metrics: layout.metrics, renderer: renderer,
                extraBadges: CellBadges(externalBadges[item.id] ?? [])
            )
            cell.frame = CGRect(origin: layout.cellOrigin(at: i), size: layout.cellSize)
            if cell.superview !== gridView { gridView.addSubview(cell) }
            newCells.append(cell)
            if newIndex[item.id] == nil { newIndex[item.id] = cell }
        }

        // Cells that were not reused leave the view hierarchy and become spares.
        let leftovers = Array(reusable.values) + spares
        for cell in leftovers {
            cell.removeFromSuperview()
            cell.reset()
        }
        spareCells = Array(leftovers.prefix(Self.maxSpareCells))
        cells = newCells
        cellsByWindowID = newIndex
    }

    private func makeCell() -> SwitcherCellView {
        let cell = SwitcherCellView(frame: .zero)
        cell.onMouseMoved = { [weak self] cell in self?.cellMouseMoved(cell) }
        cell.onMouseExited = { [weak self] cell in self?.cellMouseExited(cell) }
        cell.onClick = { [weak self] cell in self?.onClick?(cell.index) }
        cell.onAction = { [weak self] cell, action in self?.onAction?(cell.index, action) }
        return cell
    }

    // MARK: Selection / hover

    private func applySelection(_ requested: Int, scroll: Bool) {
        guard !cells.isEmpty else { selectedIndex = -1; return }
        let index = min(max(requested, 0), cells.count - 1)
        if selectedIndex >= 0, selectedIndex < cells.count, selectedIndex != index {
            cells[selectedIndex].setSelected(false)
        }
        selectedIndex = index
        cells[index].setSelected(true)

        // Keyboard / controller selection hides hover buttons on any other cell.
        if let hovered = hoveredIndex, hovered != index {
            if hovered < cells.count { cells[hovered].setHovered(false) }
            hoveredIndex = nil
        }

        updateSelectedTitle()

        if scroll, layout?.scrolls == true {
            let margin = layout?.metrics.panelPadding ?? 0
            gridView.scrollToVisible(cells[index].frame.insetBy(dx: 0, dy: -margin))
        }
    }

    /// appIcons style: the selected window's title under the grid.
    private func updateSelectedTitle() {
        guard renderer.footerHeight > 0, cells.indices.contains(selectedIndex),
              let info = currentWindows[cells[selectedIndex].windowID] else {
            selectedTitleLabel.stringValue = ""
            return
        }
        selectedTitleLabel.stringValue = info.title.isEmpty ? info.appName : info.title
    }

    private func cellMouseMoved(_ cell: SwitcherCellView) {
        if !mouseHasMoved {
            let location = NSEvent.mouseLocation
            guard hypot(location.x - mouseBaseline.x, location.y - mouseBaseline.y) >= 1 else { return }
            mouseHasMoved = true
        }
        guard hoveredIndex != cell.index else { return }
        if let previous = hoveredIndex, previous < cells.count { cells[previous].setHovered(false) }
        hoveredIndex = cell.index
        cell.setHovered(true)

        isHoverDrivenSelection = true
        defer { isHoverDrivenSelection = false }
        onHover?(cell.index)
    }

    private func cellMouseExited(_ cell: SwitcherCellView) {
        cell.setHovered(false)
        if hoveredIndex == cell.index { hoveredIndex = nil }
    }

    // MARK: Helpers

    /// Switches between the centered HUD and the full-screen task view: blur mask / tint vs. dim layer,
    /// and the appearance (the dim is always dark, so task view forces the dark appearance).
    private func setMode(taskView: Bool) {
        guard taskView != isTaskViewMode else { return }
        isTaskViewMode = taskView
        effectView.maskImage = taskView ? nil : Self.roundedMask(radius: Self.cornerRadius)
        tintView.isHidden = taskView
        dimView.isHidden = !taskView
        applyTheme()
    }

    /// Mouse-down on the dim background (or any uncovered part of the grid) in task view cancels, unless
    /// it landed on the search bar. Ignored in HUD mode.
    private func backgroundMouseDown(atWindowPoint point: NSPoint) {
        guard isTaskViewMode else { return }
        let local = effectView.convert(point, from: nil)
        guard !searchBar.frame.contains(local) else { return }
        onBackgroundClick?()
    }

    private func applyTheme() {
        if isTaskViewMode {
            window.appearance = NSAppearance(named: .darkAqua)
            return
        }
        switch theme {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private static func computeLayout(
        count: Int, profile: ShortcutProfile, screen: NSScreen
    ) -> (layout: GridLayout, metrics: CellMetrics, renderer: SwitcherCellRenderer) {
        let visibleSize = screen.visibleFrame.size
        let renderer = SwitcherCellRenderers.renderer(for: profile.style)
        let isTaskView = profile.style == .taskView
        let chrome = isTaskView ? TaskViewLayout.reservedHeight : searchChromeHeight
        // Fixed sizes map through `SwitcherSizing`; `.auto` (and task view) fit the item count to the screen.
        let metrics = renderer.metrics(
            for: profile.size, itemCount: count, screenSize: visibleSize,
            reservedHeight: chrome + renderer.footerHeight
        )
        let layout = isTaskView
            ? TaskViewLayout.compute(count: count, screenSize: visibleSize, cell: metrics)
            : GridLayout.compute(
                count: count, screenSize: visibleSize, cell: metrics,
                reservedHeight: chrome + renderer.footerHeight,
                minPanelWidth: minPanelWidth
            )
        return (layout, metrics, renderer)
    }

    /// Stretchable rounded-rect mask for the visual effect view (the only reliable way to round vibrancy).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
