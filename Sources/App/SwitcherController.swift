import AppKit
import VitrinCore
import VitrinSystem

/// Glues hotkeys, window tracking, thumbnails and the panel together.
/// Owns the switcher session state (items, selection, open profile).
@MainActor
final class SwitcherController {
    private let tracker: WindowTracking
    private let actor: WindowActing
    private var hotkeys: HotkeyHandling
    private let thumbnails: ThumbnailProviding
    var panel: SwitcherPresentingF2

    private(set) var settings: AppSettings
    var items: [SwitcherItem] = []
    /// Unfiltered items of the session; `items` is `allItems` filtered by `query`.
    var allItems: [SwitcherItem] = []
    private(set) var query = ""
    private var sessionScreen: NSScreen?
    var selectedIndex = 0
    var openProfile: ShortcutProfile?
    private var thumbnailTask: Task<Void, Never>?

    var isOpen: Bool { openProfile != nil }
    /// True while the current session was opened by the trackpad gesture.
    private(set) var openedByGesture = false

    /// Trackpad three-finger swipe → switcher events (`GestureEvent` from VitrinSystem).
    func handleGesture(_ event: GestureEvent) {
        switch event {
        case let .open(reverse):
            if isOpen { return move(by: reverse ? -1 : 1) }
            guard !isPaused, let profile = settings.activeProfiles.first else { return }
            openedByGesture = true // set first: opening can deliver modifiersReleased synchronously
            open(profileID: profile.id, reverse: reverse)
            if !isOpen { openedByGesture = false }
        case .next: if isOpen { move(by: 1) }
        case .previous: if isOpen { move(by: -1) }
        case .end: if openedByGesture { commit() }
        }
    }

    init(
        settings: AppSettings,
        tracker: WindowTracking,
        actor: WindowActing,
        hotkeys: HotkeyHandling,
        thumbnails: ThumbnailProviding,
        panel: SwitcherPresentingF2
    ) {
        self.settings = settings
        self.tracker = tracker
        self.actor = actor
        self.hotkeys = hotkeys
        self.thumbnails = thumbnails
        self.panel = panel
        wireCallbacks()
    }

    // MARK: - Lifecycle

    /// Starts tracking and installs the event tap. Returns false if the tap could not be installed
    /// (Accessibility not granted yet); call again after the permission is granted.
    @discardableResult
    func start() -> Bool {
        tracker.start()
        hotkeys.update(exceptions: settings.appExceptions)
        let ok = hotkeys.start(profiles: isPaused ? [] : settings.activeProfiles)
        Log.app.info("Switcher start: event tap \(ok ? "installed" : "unavailable", privacy: .public)")
        return ok
    }

    func stop() {
        close()
        hotkeys.stop()
        tracker.stop()
    }

    func apply(settings: AppSettings) {
        self.settings = settings
        hotkeys.update(exceptions: settings.appExceptions)
        hotkeys.update(profiles: isPaused ? [] : settings.activeProfiles)
        if isOpen { close() }
    }

    /// While paused (e.g. the Settings shortcut recorder is listening) no trigger is intercepted.
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused { close() }
        hotkeys.update(profiles: paused ? [] : settings.activeProfiles)
    }

    // MARK: - Events

    private func wireCallbacks() {
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in
            self?.select(index)
            self?.commit()
        }
        panel.onAction = { [weak self] index, action in
            self?.select(index)
            self?.perform(action)
        }
    }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case let .open(profileID, reverse):
            if isOpen { move(by: reverse ? -1 : 1) } else { open(profileID: profileID, reverse: reverse) }
        case .next: move(by: 1)
        case .previous: move(by: -1)
        case .moveLeft: move(by: -1)
        case .moveRight: move(by: 1)
        case .moveUp: moveVertically(by: -1)
        case .moveDown: moveVertically(by: 1)
        case .modifiersReleased:
            // A gesture-opened switcher has no held modifiers; it ends with the gesture instead.
            if !openedByGesture, openProfile?.releaseBehavior == .focusSelection { commit() }
        case .confirm: commit()
        case .cancel: close()
        case let .action(action): perform(action)
        case let .text(text):
            guard isOpen else { return }
            if text == " " && query.isEmpty { return commit() } // Space confirms unless searching
            query += text
            applySearch()
        case .backspace:
            guard isOpen, !query.isEmpty else { return }
            query.removeLast()
            applySearch()
        }
    }

    // MARK: - Session

    func open(profileID: String, reverse: Bool) {
        guard let profile = settings.profiles.first(where: { $0.id == profileID && $0.isEnabled }) else { return }
        let context = tracker.currentContext()
        let windows = profile.windows(
            from: tracker.windows,
            history: tracker.focusHistory,
            exceptions: settings.appExceptions,
            context: context
        )
        guard !windows.isEmpty else {
            Log.app.info("Switcher: no windows for profile \(profileID, privacy: .public)")
            return
        }
        allItems = windows.map { SwitcherItem(window: $0, appIcon: Self.icon(for: $0.pid)) }
        items = allItems
        query = ""
        selectedIndex = Self.initialSelection(count: items.count, reverse: reverse)
        openProfile = profile
        hotkeys.openProfileID = profile.id
        // May synchronously deliver `.modifiersReleased` when the trigger was already released (a quick
        // tap): that commits and closes the session, so switch straight away without showing the panel.
        hotkeys.isSwitcherOpen = true
        guard isOpen else { return }
        let screen = screen(for: context)
        sessionScreen = screen
        panel.setTheme(settings.appearance.theme)
        panel.setBadges(Self.badges(for: windows, context: context, screen: screen))
        panel.setSearchQuery("")
        panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: screen)
        loadThumbnails()
        updatePreview()
    }

    func close() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        previewTask?.cancel()
        previewTask = nil
        panel.showPreview(of: nil, image: nil)
        if panel.isVisible { panel.hide() }
        hotkeys.isSwitcherOpen = false
        hotkeys.openProfileID = nil
        openProfile = nil
        openedByGesture = false
        items = []
        allItems = []
        query = ""
        sessionScreen = nil
    }

    private func commit() {
        guard isOpen, items.indices.contains(selectedIndex) else { return close() }
        let window = items[selectedIndex].window
        close()
        actor.perform(.focus, on: window)
    }

    private func perform(_ action: WindowAction) {
        guard isOpen, items.indices.contains(selectedIndex) else { return }
        if action == .focus { return commit() }
        let window = items[selectedIndex].window
        guard actor.perform(action, on: window) else { return }
        switch action {
        case .close:
            items.remove(at: selectedIndex)
            allItems.removeAll { $0.id == window.id }
        case .quitApp:
            items.removeAll { $0.window.pid == window.pid }
            allItems.removeAll { $0.window.pid == window.pid }
        case .minimize, .toggleFullscreen, .hideApp, .focus:
            return // the window stays in the list; its badges refresh on next open
        }
        guard !items.isEmpty, let profile = openProfile else { return close() }
        selectedIndex = min(selectedIndex, items.count - 1)
        panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: sessionScreen ?? screen(for: tracker.currentContext()))
        loadThumbnails()
    }

    // MARK: - Search

    private func applySearch() {
        guard let profile = openProfile else { return }
        let matches = WindowSearch.filter(allItems.map(\.window), query: query)
        let byID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        items = matches.compactMap { byID[$0.id] }
        selectedIndex = query.isEmpty ? Self.initialSelection(count: items.count, reverse: false) : 0
        panel.setSearchQuery(query)
        panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: sessionScreen ?? screen(for: tracker.currentContext()))
        loadThumbnails()
    }

    /// Windows on a Space that is not currently visible, or on a different display than the panel.
    static func badges(for windows: [WindowInfo], context: SwitcherContext, screen: NSScreen) -> [CGWindowID: SwitcherBadges] {
        var result: [CGWindowID: SwitcherBadges] = [:]
        let panelDisplay = screen.displayID
        for window in windows {
            var badges: SwitcherBadges = []
            if !window.spaceIDs.isEmpty, !context.currentSpaceIDs.isEmpty,
               context.currentSpaceIDs.isDisjoint(with: window.spaceIDs), !window.isMinimized {
                badges.insert(.otherSpace)
            }
            if let display = window.displayID, let panelDisplay, display != panelDisplay, NSScreen.screens.count > 1 {
                badges.insert(.otherScreen)
            }
            if !badges.isEmpty { result[window.id] = badges }
        }
        return result
    }

    // MARK: - Selection

    private func select(_ index: Int) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        panel.updateSelection(index)
        updatePreview()
    }

    private var previewTask: Task<Void, Never>?

    /// Full-size preview of the selection (opt-in: `appearance.showPreview`).
    private func updatePreview() {
        previewTask?.cancel()
        guard settings.appearance.showPreview, isOpen, items.indices.contains(selectedIndex) else {
            panel.showPreview(of: nil, image: nil)
            return
        }
        let window = items[selectedIndex].window
        guard !window.isMinimized, !window.isAppHidden else {
            panel.showPreview(of: nil, image: nil)
            return
        }
        panel.showPreview(of: window, image: thumbnails.cachedThumbnail(for: window.id))
        guard thumbnails.isAvailable else { return }
        let scale = NSScreen.screens.first { $0.displayID == window.displayID }?.backingScaleFactor ?? 2
        let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        let provider = thumbnails
        previewTask = Task { [weak self] in
            guard let image = await provider.thumbnail(for: window.id, maxPixelSize: size), !Task.isCancelled,
                  let self, self.isOpen, self.items.indices.contains(self.selectedIndex),
                  self.items[self.selectedIndex].id == window.id else { return }
            self.panel.showPreview(of: window, image: image)
        }
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        select(((selectedIndex + delta) % count + count) % count)
    }

    private func moveVertically(by rows: Int) {
        guard !items.isEmpty else { return }
        let target = selectedIndex + rows * max(panel.columns, 1)
        if items.indices.contains(target) { select(target) }
    }

    static func initialSelection(count: Int, reverse: Bool) -> Int {
        guard count > 1 else { return 0 }
        return reverse ? count - 1 : 1
    }

    // MARK: - Thumbnails

    func loadThumbnails() {
        thumbnailTask?.cancel()
        let cached = items.compactMap { item in thumbnails.cachedThumbnail(for: item.id).map { (item.id, $0) } }
        for (id, image) in cached { panel.updateThumbnail(windowID: id, image: image) }
        // App-icon and title styles don't use captures (the panel reports a token size).
        guard thumbnails.isAvailable, panel.thumbnailPixelSize.width > 32 else { return }

        // Selected window first, then the rest in display order.
        var ids = items.map(\.id)
        if ids.indices.contains(selectedIndex) { ids.insert(ids.remove(at: selectedIndex), at: 0) }
        let size = panel.thumbnailPixelSize
        let provider = thumbnails
        thumbnailTask = Task { [weak self] in
            for id in ids {
                if Task.isCancelled { return }
                guard let image = await provider.thumbnail(for: id, maxPixelSize: size) else { continue }
                if Task.isCancelled { return }
                self?.panel.updateThumbnail(windowID: id, image: image)
            }
        }
    }

    // MARK: - Helpers

    private func screen(for context: SwitcherContext) -> NSScreen {
        let screens = NSScreen.screens
        func screen(_ id: CGDirectDisplayID?) -> NSScreen? {
            guard let id else { return nil }
            return screens.first { $0.displayID == id }
        }
        let mouse = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        switch settings.appearance.showOnScreen {
        case .active: return screen(context.activeDisplayID) ?? mouse ?? NSScreen.main ?? screens[0]
        case .withMouse: return mouse ?? NSScreen.main ?? screens[0]
        case .main: return NSScreen.main ?? screens[0]
        }
    }

    private static var iconCache: [pid_t: NSImage] = [:]

    private static func icon(for pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        iconCache[pid] = icon
        return icon
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

extension SwitcherController {
    /// Debug only: opens the panel with the given windows, bypassing tracking and filtering
    /// (lets the UI be checked without Accessibility permission).
    func openDemo(windows: [WindowInfo], profileID: String = "all-windows") {
        guard let profile = settings.profiles.first(where: { $0.id == profileID }) ?? settings.profiles.first,
              !windows.isEmpty else { return }
        close()
        allItems = windows.map { SwitcherItem(window: $0, appIcon: NSRunningApplication(processIdentifier: $0.pid)?.icon) }
        items = allItems
        selectedIndex = Self.initialSelection(count: items.count, reverse: false)
        openProfile = profile
        panel.setTheme(settings.appearance.theme)
        panel.setSearchQuery("")
        panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: NSScreen.main ?? NSScreen.screens[0])
        loadThumbnails()
    }

    /// Debug only: opens a real session that ignores modifier release (no keys are held when it is
    /// opened from a script), so it stays open until `confirm` / `cancel`.
    func openFromScript(profileID: String) {
        guard !isOpen else { return }
        openedByGesture = true // set first: opening can deliver modifiersReleased synchronously
        open(profileID: profileID, reverse: false)
        if !isOpen { openedByGesture = false }
    }

    /// Human-readable session state (debug commands / diagnostics).
    var debugDescription: String {
        var lines = ["open=\(openProfile?.id ?? "-") selected=\(selectedIndex) items=\(items.count)"]
        for (index, item) in items.enumerated() {
            let w = item.window
            lines.append("\(index == selectedIndex ? ">" : " ") \(index) [\(w.id)] \(w.appName) — \(w.title)")
        }
        return lines.joined(separator: "\n")
    }
}
