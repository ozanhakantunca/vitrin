import AppKit
import VitrinCore
import VitrinSystem

/// Glues hotkeys, window tracking, thumbnails and the panel together.
/// Owns the switcher session state (items, selection, open profile).
@MainActor
final class SwitcherController {
    private let tracker: WindowTracking
    private let spaces: SpaceSwitching?
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
    private var sessionSpacesDisplay: String?
    private var desktops: [DesktopItem] = []
    private var desktopIndex: Int?
    private var desktopPanel: SwitcherPresentingDesktops? { panel as? SwitcherPresentingDesktops }
    var selectedIndex = 0
    var openProfile: ShortcutProfile?
    private var thumbnailTask: Task<Void, Never>?
    private var trackedWindowIDs: Set<CGWindowID> = []
    /// Called after the tracker's windows changed (and the controller has caught up).
    var onWindowsChange: (() -> Void)?

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
        panel: SwitcherPresentingF2,
        spaces: SpaceSwitching? = nil
    ) {
        self.settings = settings
        self.tracker = tracker
        self.spaces = spaces
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
        forgetClosedWindows()
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
        tracker.onChange = { [weak self] in
            self?.forgetClosedWindows()
            self?.refreshDesktops()
            self?.onWindowsChange?()
        }
        desktopPanel?.onDesktopClick = { [weak self] index in self?.pickDesktop(at: index) }
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in
            self?.select(index)
            self?.commit()
        }
        panel.onAction = { [weak self] index, action in
            guard let self, self.desktopIndex == nil else { return }
            self.select(index)
            self.perform(action)
        }
    }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case let .open(profileID, reverse):
            if isOpen { move(by: reverse ? -1 : 1) } else { open(profileID: profileID, reverse: reverse) }
        case .next: move(by: 1)
        case .previous: move(by: -1)
        case .moveLeft: moveHorizontally(by: -1)
        case .moveRight: moveHorizontally(by: 1)
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
            setDesktopFocus(nil)
        case .backspace:
            guard isOpen else { return }
            if !query.isEmpty {
                query.removeLast()
                applySearch()
            }
            setDesktopFocus(nil)
        }
    }

    // MARK: - Session

    func open(profileID: String, reverse: Bool) {
        guard let profile = settings.profiles.first(where: { $0.id == profileID && $0.isEnabled }) else { return }
        forgetClosedWindows()
        Self.pruneIconCache(&Self.iconCache, keeping: tracker.windows)
        let context = tracker.currentContext()
        let windows = profile.windows(
            from: tracker.windows,
            history: tracker.focusHistory,
            exceptions: settings.appExceptions,
            context: context
        )
        let desktopScreen = showsDesktops(for: profile) ? screen(for: context) : nil
        let display = desktopScreen.flatMap(spacesDisplay(on:))
        let desktopItems = desktopItems(on: display)
        guard !windows.isEmpty || !desktopItems.isEmpty else {
            Log.app.info("Switcher: no windows for profile \(profileID, privacy: .public)")
            return
        }
        allItems = windows.map { SwitcherItem(window: $0, appIcon: Self.icon(for: $0)) }
        items = allItems
        query = ""
        selectedIndex = Self.initialSelection(count: items.count, reverse: reverse)
        openProfile = profile
        desktopIndex = nil
        hotkeys.openProfileID = profile.id
        // May synchronously deliver `.modifiersReleased` when the trigger was already released (a quick
        // tap): that commits and closes the session, so switch straight away without showing the panel.
        hotkeys.isSwitcherOpen = true
        guard isOpen else { return }
        let screen = desktopScreen ?? screen(for: context)
        sessionScreen = screen
        sessionSpacesDisplay = display
        desktops = desktopItems
        desktopPanel?.setDesktops(desktops)
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
        sessionSpacesDisplay = nil
        desktops = []
        desktopIndex = nil
    }

    private func commit() {
        if let desktopIndex { return pickDesktop(at: desktopIndex) }
        guard isOpen, items.indices.contains(selectedIndex) else { return close() }
        let window = items[selectedIndex].window
        close()
        actor.perform(.focus, on: window)
    }

    private func perform(_ action: WindowAction) {
        guard isOpen, desktopIndex == nil, items.indices.contains(selectedIndex) else { return }
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
        guard !items.isEmpty || !desktops.isEmpty, let profile = openProfile else { return close() }
        selectedIndex = max(0, min(selectedIndex, items.count - 1))
        panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: sessionScreen ?? screen(for: tracker.currentContext()))
        loadThumbnails()
    }

    /// Drops cached thumbnails of windows that are no longer tracked.
    private func forgetClosedWindows() {
        let current = Set(tracker.windows.map(\.id))
        for id in trackedWindowIDs.subtracting(current) { thumbnails.invalidate(windowID: id) }
        trackedWindowIDs = current
    }

    // MARK: - Task View desktops

    private var recentWindows: [WindowInfo] {
        let history = tracker.focusHistory
        return history.isEmpty ? WindowInfo.mruSorted(tracker.windows) : history.ordered(tracker.windows)
    }

    private func showsDesktops(for profile: ShortcutProfile) -> Bool {
        profile.style == .taskView && settings.showDesktopsInTaskView && spaces != nil && desktopPanel != nil
    }

    private func spacesDisplay(on screen: NSScreen) -> String? {
        guard let displayID = screen.displayID else { return nil }
        return spaces?.spacesDisplayIdentifier(for: displayID)
    }

    private func desktopItems(on display: String?) -> [DesktopItem] {
        guard let display, let spaces else { return [] }
        let desktops = spaces.desktops(onDisplay: display)
        guard desktops.count > 1 else { return [] }
        let windows = recentWindows
        return desktops.map { Self.desktopItem(for: $0, windows: windows, icon: Self.icon(for:)) }
    }

    /// The tracker inventory in MRU order, independent of the profile and its search query.
    static func desktopItem(for desktop: Desktop, windows: [WindowInfo], icon: (WindowInfo) -> NSImage?) -> DesktopItem {
        let members = windows.filter { $0.spaceIDs.contains(desktop.id) }
        let title: String
        switch desktop.kind {
        case let .desktop(number):
            title = String(format: String(localized: "Desktop %d"), number)
        case .fullscreen:
            let owner = members.first { $0.isFullscreen && !$0.appName.isEmpty }
                ?? members.first { $0.spaceIDs == [desktop.id] && !$0.appName.isEmpty }
            title = owner?.appName ?? String(localized: "Full Screen")
        }
        var apps = Set<String>()
        var icons: [NSImage] = []
        for window in members {
            let app = window.bundleIdentifier ?? String(window.pid)
            if apps.insert(app).inserted, let image = icon(window) { icons.append(image) }
            if icons.count == 4 { break }
        }
        return DesktopItem(desktop: desktop, title: title, appIcons: icons)
    }

    private func refreshDesktops() {
        guard let display = sessionSpacesDisplay, let profile = openProfile,
              let screen = sessionScreen, let desktopPanel else { return }
        let updated = desktopItems(on: display)
        guard updated != desktops else { return }
        let selectedID = desktopIndex.map { desktops[$0].id }
        let needsLayout = desktops.count != updated.count
        desktops = updated
        desktopIndex = selectedID.flatMap { id in updated.firstIndex { $0.id == id } }
        desktopPanel.setDesktops(updated)
        if needsLayout {
            panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: screen)
            loadThumbnails()
        }
        desktopPanel.updateDesktopSelection(desktopIndex)
        if selectedID != nil && desktopIndex == nil { updatePreview() }
    }

    private func pickDesktop(at index: Int) {
        guard isOpen, desktops.indices.contains(index) else { return }
        let desktop = desktops[index].desktop
        close()
        guard !desktop.isCurrent else { return }
        if let window = recentWindows.first(where: {
            $0.spaceIDs == [desktop.id] && !$0.isMinimized && !$0.isAppHidden
        }) {
            actor.perform(.focus, on: window)
        } else {
            spaces?.switchTo(desktop)
        }
    }

    private func setDesktopFocus(_ index: Int?) {
        guard desktopIndex != index else { return }
        desktopIndex = index
        desktopPanel?.updateDesktopSelection(index)
        updatePreview()
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
        guard items.indices.contains(index) else { return }
        setDesktopFocus(nil)
        guard index != selectedIndex else { return }
        selectedIndex = index
        panel.updateSelection(index)
        updatePreview()
    }

    private var previewTask: Task<Void, Never>?

    /// Full-size preview of the selection (opt-in: `appearance.showPreview`).
    private func updatePreview() {
        previewTask?.cancel()
        guard settings.appearance.showPreview, isOpen, desktopIndex == nil, items.indices.contains(selectedIndex) else {
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
        setDesktopFocus(nil)
        guard !items.isEmpty else { return }
        let count = items.count
        select(((selectedIndex + delta) % count + count) % count)
    }

    private func moveHorizontally(by delta: Int) {
        guard let desktopIndex else { return move(by: delta) }
        setDesktopFocus(min(max(0, desktopIndex + delta), desktops.count - 1))
    }

    private func moveVertically(by rows: Int) {
        if desktopIndex != nil {
            if rows < 0 { setDesktopFocus(nil) }
            return
        }
        let columns = max(panel.columns, 1)
        if rows > 0, !desktops.isEmpty {
            if items.isEmpty || selectedIndex / columns == (items.count - 1) / columns {
                setDesktopFocus(desktops.firstIndex { $0.desktop.isCurrent } ?? 0)
            } else {
                select(min(selectedIndex + columns, items.count - 1))
            }
            return
        }
        let target = selectedIndex + rows * columns
        if items.indices.contains(target) { select(target) }
    }

    static func initialSelection(count: Int, reverse: Bool) -> Int {
        guard count > 1 else { return 0 }
        return reverse ? count - 1 : 1
    }

    // MARK: - Thumbnails

    static let maxConcurrentCaptures = 4

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
            // At most `maxConcurrentCaptures` in flight, started in priority order; results land on the main actor.
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                var pending = ids.makeIterator()
                for _ in 0..<Self.maxConcurrentCaptures {
                    guard let id = pending.next() else { break }
                    group.addTask { (id, await provider.thumbnail(for: id, maxPixelSize: size)) }
                }
                while let (id, image) = await group.next() {
                    if Task.isCancelled { return }
                    if let image { self?.panel.updateThumbnail(windowID: id, image: image) }
                    if let next = pending.next() {
                        group.addTask { (next, await provider.thumbnail(for: next, maxPixelSize: size)) }
                    }
                }
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

    /// App identity: a pid alone can be reused by the OS for another app.
    struct IconKey: Hashable {
        var pid: pid_t
        var bundleIdentifier: String?
    }

    private static var iconCache: [IconKey: NSImage] = [:]

    /// Removes icons whose app is no longer behind any tracked window.
    static func pruneIconCache(_ cache: inout [IconKey: NSImage], keeping windows: [WindowInfo]) {
        let live = Set(windows.map { IconKey(pid: $0.pid, bundleIdentifier: $0.bundleIdentifier) })
        cache = cache.filter { live.contains($0.key) }
    }

    private static func icon(for window: WindowInfo) -> NSImage? {
        let key = IconKey(pid: window.pid, bundleIdentifier: window.bundleIdentifier)
        if let cached = iconCache[key] { return cached }
        let icon = NSRunningApplication(processIdentifier: window.pid)?.icon
        iconCache[key] = icon
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
        let screen = NSScreen.main ?? NSScreen.screens[0]
        sessionScreen = screen
        sessionSpacesDisplay = showsDesktops(for: profile) ? spacesDisplay(on: screen) : nil
        desktops = desktopItems(on: sessionSpacesDisplay)
        desktopPanel?.setDesktops(desktops)
        panel.setTheme(settings.appearance.theme)
        panel.setSearchQuery("")
        panel.show(items: items, selectedIndex: selectedIndex, profile: profile, on: screen)
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
