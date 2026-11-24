import AppKit
import ApplicationServices
import Testing
import VitrinCore
import VitrinSystem
@testable import Vitrin

@MainActor private final class FakeTracker: WindowTracking {
    var windows: [WindowInfo] = []
    var focusHistory = FocusHistory()
    var onChange: (() -> Void)?
    func start() {} ; func stop() {} ; func refreshAll() {}
    func currentContext() -> SwitcherContext { SwitcherContext(activePID: 1, currentSpaceIDs: [1]) }
    func axElement(for windowID: CGWindowID) -> AXUIElement? { nil }
}
@MainActor private final class FakeActor: WindowActing {
    var actions: [(WindowAction, WindowInfo)] = []
    var onPerform: (() -> Void)?
    func perform(_ action: WindowAction, on window: WindowInfo) -> Bool {
        onPerform?()
        actions.append((action, window))
        return true
    }
}
@MainActor private final class FakeHotkeys: HotkeyHandling {
    var profiles: [[ShortcutProfile]] = []
    var exceptions: [[AppException]] = []
    /// Simulates a quick tap: the trigger is already released when the switcher opens, so the real
    /// manager delivers `.modifiersReleased` synchronously from the `isSwitcherOpen` setter.
    var releasedOnOpen = false
    var isSwitcherOpen = false {
        didSet { if releasedOnOpen, isSwitcherOpen, !oldValue { onEvent?(.modifiersReleased) } }
    }
    var openProfileID: String?
    var onEvent: ((HotkeyEvent) -> Void)?
    func start(profiles: [ShortcutProfile]) -> Bool { true }
    func stop() {}
    func update(profiles: [ShortcutProfile]) { self.profiles.append(profiles) }
    func update(exceptions: [AppException]) { self.exceptions.append(exceptions) }
}
private final class FakeThumbnails: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _invalidated: [CGWindowID] = []
    private var _requested: [CGWindowID] = []
    private var running = 0
    private var _maxRunning = 0
    /// Non-zero makes captures take this long and return an image.
    var captureDelay: UInt64 = 0
    var isAvailable: Bool { captureDelay > 0 }
    var invalidated: [CGWindowID] { lock.withLock { _invalidated } }
    var requested: [CGWindowID] { lock.withLock { _requested } }
    var maxRunning: Int { lock.withLock { _maxRunning } }
    func cachedThumbnail(for windowID: CGWindowID) -> CGImage? { nil }
    func thumbnail(for windowID: CGWindowID, maxPixelSize: CGSize) async -> CGImage? {
        guard captureDelay > 0 else { return nil }
        lock.withLock { _requested.append(windowID); running += 1; _maxRunning = max(_maxRunning, running) }
        try? await Task.sleep(nanoseconds: captureDelay)
        lock.withLock { running -= 1 }
        return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    func invalidate(windowID: CGWindowID) { lock.withLock { _invalidated.append(windowID) } }
    func removeAll() {}
}
@MainActor private final class FakeSpaceSwitcher: SpaceSwitching {
    var desktops: [Desktop] = [
        Desktop(id: 10, kind: .desktop(number: 1), displayIdentifier: "test", isCurrent: false, index: 0),
        Desktop(id: 1, kind: .desktop(number: 2), displayIdentifier: "test", isCurrent: true, index: 1),
        Desktop(id: 30, kind: .fullscreen, displayIdentifier: "test", isCurrent: false, index: 2),
    ]
    var displays: [CGDirectDisplayID] = []
    var requests: [String] = []
    var switches: [Desktop] = []
    var onSwitch: (() -> Void)?
    func spacesDisplayIdentifier(for displayID: CGDirectDisplayID) -> String? {
        displays.append(displayID)
        return "test"
    }
    func desktops(onDisplay identifier: String) -> [Desktop] {
        requests.append(identifier)
        return desktops
    }
    func switchTo(_ desktop: Desktop) -> Bool {
        onSwitch?()
        switches.append(desktop)
        return true
    }
}
@MainActor private final class FakePanel: SwitcherPresentingF2, SwitcherPresentingDesktops {
    var desktops: [DesktopItem] = []
    var desktopSelection: Int?
    var onDesktopClick: ((Int) -> Void)?
    func setDesktops(_ desktops: [DesktopItem]) { self.desktops = desktops }
    func updateDesktopSelection(_ index: Int?) { desktopSelection = index }
    var isVisible = false
    let columns = 3
    var thumbnailPixelSize = CGSize.zero
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onAction: ((Int, WindowAction) -> Void)?
    var items: [SwitcherItem] = []
    var selection = 0
    var query = ""
    var badges: [CGWindowID: SwitcherBadges] = [:]
    func show(items: [SwitcherItem], selectedIndex: Int, profile: ShortcutProfile, on screen: NSScreen) { self.items = items; selection = selectedIndex; isVisible = true }
    func updateSelection(_ index: Int) { selection = index }
    var thumbnailUpdates: [CGWindowID] = []
    func updateThumbnail(windowID: CGWindowID, image: CGImage) { thumbnailUpdates.append(windowID) }
    func hide() { isVisible = false; desktopSelection = nil; desktops = [] }
    func setSearchQuery(_ query: String) { self.query = query }
    func setBadges(_ badges: [CGWindowID: SwitcherBadges]) { self.badges = badges }
}
@MainActor private func fixture(
    _ count: Int, settings: AppSettings = .defaults, spaces: SpaceSwitching? = nil, thumbnails: FakeThumbnails = FakeThumbnails()
) -> (SwitcherController, FakeTracker, FakeActor, FakeHotkeys, FakePanel) {
    let tracker = FakeTracker(); let actor = FakeActor(); let hotkeys = FakeHotkeys(); let panel = FakePanel()
    tracker.windows = (0..<count).map { (index: Int) -> WindowInfo in
        let pid: pid_t = index < 2 ? 1 : 2
        let appName: String = index == 0 ? "Chrome" : "App"
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        return WindowInfo(id: CGWindowID(index + 1), pid: pid, appName: appName, title: "Window \(index)", frame: frame)
    }
    let controller = SwitcherController(settings: settings, tracker: tracker, actor: actor, hotkeys: hotkeys,
                                        thumbnails: thumbnails, panel: panel, spaces: spaces)
    return (controller, tracker, actor, hotkeys, panel)
}
@MainActor @Test func controllerOpeningAndNavigation() {
    guard NSScreen.main != nil else { return }
    let (c, _, _, h, p) = fixture(5)
    c.handle(.open(profileID: "all-windows", reverse: false))
    #expect(p.selection == 1 && h.isSwitcherOpen && h.openProfileID == "all-windows")
    c.handle(.moveDown); #expect(p.selection == 4)
    c.handle(.moveDown); #expect(p.selection == 4)
    c.handle(.next); #expect(p.selection == 0)
    c.handle(.previous); #expect(p.selection == 4)
    c.handle(.moveUp); #expect(p.selection == 1)
    c.handle(.cancel); #expect(!p.isVisible && !h.isSwitcherOpen && h.openProfileID == nil)
    c.handle(.open(profileID: "all-windows", reverse: true)); #expect(p.selection == 4)
    let (one, _, _, _, single) = fixture(1); one.handle(.open(profileID: "all-windows", reverse: false)); #expect(single.selection == 0)
    let (empty, _, _, _, none) = fixture(0); empty.handle(.open(profileID: "all-windows", reverse: false)); #expect(!none.isVisible)
}
@MainActor @Test func controllerSearchAndCommit() {
    guard NSScreen.main != nil else { return }
    let (c, _, actor, _, panel) = fixture(3)
    c.handle(.open(profileID: "all-windows", reverse: false))
    c.handle(.text("chr")); #expect(panel.items.count == 1 && panel.selection == 0)
    c.handle(.text(" ")); #expect(panel.query == "chr " && actor.actions.isEmpty)
    c.handle(.backspace); c.handle(.backspace); c.handle(.backspace); c.handle(.backspace)
    #expect(panel.items.count == 3)
    c.handle(.text(" ")); #expect(actor.actions.last?.0 == .focus && !panel.isVisible)
    c.handle(.open(profileID: "all-windows", reverse: false)); c.handle(.modifiersReleased)
    #expect(actor.actions.count == 2 && !panel.isVisible)
    c.handle(.open(profileID: "all-windows", reverse: false)); c.handle(.cancel); #expect(actor.actions.count == 2)
}
@MainActor @Test func controllerActionsAndSettings() {
    guard NSScreen.main != nil else { return }
    let (c, _, _, hotkeys, panel) = fixture(3)
    c.handle(.open(profileID: "all-windows", reverse: false)); c.handle(.action(.quitApp))
    #expect(panel.items.count == 1 && panel.selection == 0)
    c.handle(.action(.close)); #expect(!panel.isVisible)
    c.apply(settings: .defaults); #expect(hotkeys.profiles.last == AppSettings.defaults.activeProfiles && hotkeys.exceptions.count == 1)
    c.handle(.open(profileID: "all-windows", reverse: false)); c.setPaused(true)
    #expect(hotkeys.profiles.last?.isEmpty == true && !panel.isVisible)
    c.setPaused(false); #expect(hotkeys.profiles.last == AppSettings.defaults.activeProfiles)
}
@MainActor @Test func controllerSpaceBadges() {
    // Headless test environments may have no screen.
    guard let screen = NSScreen.main else { return }
    let windows = [WindowInfo(id: 1, pid: 1, spaceIDs: [2]), WindowInfo(id: 2, pid: 1, isMinimized: true, spaceIDs: [2])]
    let badges = SwitcherController.badges(for: windows, context: SwitcherContext(currentSpaceIDs: [1]), screen: screen)
    #expect(badges[1]?.contains(.otherSpace) == true && badges[2] == nil)
}

@MainActor @Test func gestureOpenedSwitcherIgnoresModifierReleaseAndCommitsOnEnd() {
    guard NSScreen.main != nil else { return }
    let (c, _, actor, _, panel) = fixture(4)
    c.handleGesture(.open(reverse: false))
    #expect(panel.isVisible && c.openedByGesture)
    c.handle(.modifiersReleased) // no modifiers are held during a swipe
    #expect(panel.isVisible && actor.actions.isEmpty)
    c.handleGesture(.next)
    #expect(panel.selection == 2)
    c.handleGesture(.end)
    #expect(!panel.isVisible && actor.actions.last?.0 == .focus && !c.openedByGesture)
    c.handle(.open(profileID: "all-windows", reverse: false))
    c.handleGesture(.end) // keyboard session: the gesture's end must not commit it
    #expect(panel.isVisible)
}

@MainActor @Test func quickTapSwitchesWithoutLeavingAPanel() {
    guard NSScreen.main != nil else { return }
    let (c, _, actor, h, p) = fixture(3)
    h.releasedOnOpen = true
    c.handle(.open(profileID: "all-windows", reverse: false))
    #expect(!c.isOpen && !p.isVisible && !h.isSwitcherOpen)
    #expect(actor.actions.count == 1 && actor.actions.first?.0 == .focus && actor.actions.first?.1.id == 2)
}
@MainActor @Test func gestureSessionSurvivesModifierRelease() {
    guard NSScreen.main != nil else { return }
    let (c, _, actor, h, p) = fixture(3)
    h.releasedOnOpen = true
    c.handleGesture(.open(reverse: false))
    #expect(c.isOpen && p.isVisible && actor.actions.isEmpty)
    c.handleGesture(.end)
    #expect(!c.isOpen && actor.actions.count == 1)
}

private func taskSettings() -> AppSettings {
    var settings = AppSettings.defaults
    settings.profiles[2].isEnabled = true
    settings.appearance.showOnScreen = .main
    return settings
}

@MainActor @Test func desktopStripUsesSessionDisplayAndTaskViewSetting() {
    guard let screen = NSScreen.main else { return }
    let spaces = FakeSpaceSwitcher()
    let (c, _, _, _, p) = fixture(2, settings: taskSettings(), spaces: spaces)
    c.open(profileID: "all-windows", reverse: false)
    #expect(p.desktops.isEmpty && spaces.displays.isEmpty)
    c.close()
    c.open(profileID: "task-view", reverse: false)
    #expect(spaces.displays.first == screen.displayID && spaces.requests == ["test"])
    #expect(p.desktops.map(\.id) == [10, 1, 30])
    c.close()

    var settings = taskSettings()
    settings.showDesktopsInTaskView = false
    c.apply(settings: settings)
    c.open(profileID: "task-view", reverse: false)
    #expect(p.desktops.isEmpty && spaces.requests.count == 1)
    c.close()
    c.apply(settings: taskSettings())
    spaces.desktops = [spaces.desktops[1]]
    c.open(profileID: "task-view", reverse: false)
    c.handle(.moveDown)
    #expect(p.isVisible && p.desktops.isEmpty && p.desktopSelection == nil)
}

@MainActor @Test func desktopArrowsRestoreWindowFocusAndIgnoreActions() {
    guard NSScreen.main != nil else { return }
    let (c, _, actor, _, p) = fixture(5, settings: taskSettings(), spaces: FakeSpaceSwitcher())
    c.open(profileID: "task-view", reverse: false)
    c.handle(.moveDown)
    #expect(p.selection == 4 && p.desktopSelection == nil)
    c.handle(.moveDown)
    #expect(p.desktopSelection == 1)
    c.handle(.moveRight)
    #expect(p.desktopSelection == 2)
    c.handle(.moveLeft)
    #expect(p.desktopSelection == 1)
    for action: WindowAction in [.close, .minimize, .toggleFullscreen, .hideApp, .quitApp] {
        c.handle(.action(action))
    }
    #expect(actor.actions.isEmpty && p.items.count == 5)
    c.handle(.moveUp)
    #expect(p.desktopSelection == nil && p.selection == 4)
    c.handle(.moveDown)
    c.handle(.next)
    #expect(p.desktopSelection == nil && p.selection == 0)
    c.handle(.previous)
    c.handle(.moveDown)
    c.handle(.previous)
    #expect(p.desktopSelection == nil && p.selection == 3)
    c.handle(.moveDown)
    c.handle(.backspace)
    #expect(p.desktopSelection == nil && p.selection == 3)
    c.handle(.moveDown)
    p.onHover?(3)
    #expect(p.desktopSelection == nil && p.selection == 3)
    c.handle(.moveDown)
    c.handle(.text("no match"))
    #expect(p.desktopSelection == nil && p.items.isEmpty && p.desktops.count == 3)
    c.handle(.moveDown)
    #expect(p.desktopSelection == 1)
    c.handle(.backspace)
    #expect(p.desktopSelection == nil && p.query == "no matc")
    c.handle(.moveDown)
    c.handle(.cancel)
    #expect(!p.isVisible && actor.actions.isEmpty)
}

@MainActor @Test func desktopConfirmFocusesEligibleMRUOutsideGridFilter() {
    guard NSScreen.main != nil else { return }
    let spaces = FakeSpaceSwitcher()
    var settings = taskSettings()
    settings.profiles[2].filters.spaces = .current
    let (c, tracker, actor, _, p) = fixture(0, settings: settings, spaces: spaces)
    tracker.windows = [
        WindowInfo(id: 1, pid: 1, spaceIDs: [1]),
        WindowInfo(id: 2, pid: 2, spaceIDs: [10]),
        WindowInfo(id: 3, pid: 3, spaceIDs: [10]),
        WindowInfo(id: 4, pid: 4, isMinimized: true, spaceIDs: [10]),
        WindowInfo(id: 5, pid: 5, isAppHidden: true, spaceIDs: [10]),
        WindowInfo(id: 6, pid: 6, spaceIDs: [10, 1]),
    ]
    tracker.focusHistory = FocusHistory(mostRecentFirst: [6, 5, 4, 3, 2, 1])
    actor.onPerform = { #expect(!p.isVisible) }
    c.open(profileID: "task-view", reverse: false)
    #expect(p.items.map(\.id) == [6, 1])
    c.handle(.moveDown)
    c.handle(.moveLeft)
    c.handle(.confirm)
    #expect(!p.isVisible && spaces.switches.isEmpty)
    #expect(actor.actions.count == 1 && actor.actions.first?.0 == .focus && actor.actions.first?.1.id == 3)
}

@MainActor @Test func emptyAndCurrentDesktopsWorkWithoutWindowCells() {
    guard NSScreen.main != nil else { return }
    let spaces = FakeSpaceSwitcher()
    let (c, _, actor, _, p) = fixture(0, settings: taskSettings(), spaces: spaces)
    spaces.onSwitch = { #expect(!p.isVisible) }
    c.open(profileID: "task-view", reverse: false)
    #expect(p.isVisible && p.items.isEmpty)
    c.handle(.moveDown)
    c.handle(.confirm)
    #expect(!p.isVisible && actor.actions.isEmpty && spaces.switches.isEmpty)
    c.open(profileID: "task-view", reverse: false)
    c.handle(.moveDown)
    c.handle(.moveLeft)
    c.handle(.confirm)
    #expect(!p.isVisible && spaces.switches.map(\.id) == [10])
    c.open(profileID: "task-view", reverse: false)
    p.onDesktopClick?(2)
    #expect(!p.isVisible && spaces.switches.map(\.id) == [10, 30] && actor.actions.isEmpty)
}

@MainActor @Test func desktopItemsUseFullscreenOwnerAndDistinctAppIconsInMRUOrder() {
    let desktop = FakeSpaceSwitcher().desktops[2]
    let pinned = WindowInfo(id: 1, pid: 1, bundleIdentifier: "one", appName: "Pinned", spaceIDs: [1, 30])
    let owner = WindowInfo(id: 2, pid: 2, appName: "Player", isFullscreen: true, spaceIDs: [30])
    let duplicate = WindowInfo(id: 3, pid: 3, bundleIdentifier: "one", spaceIDs: [30])
    var windows = [pinned, owner, duplicate]
    for id: UInt32 in 4...6 {
        windows.append(WindowInfo(id: id, pid: pid_t(id), spaceIDs: [30]))
    }
    var requested: [pid_t] = []
    let item = SwitcherController.desktopItem(for: desktop, windows: windows) { window in
        requested.append(window.pid)
        return NSImage(size: NSSize(width: 32, height: 32))
    }
    #expect(item.title == "Player" && item.appIcons.count == 4)
    #expect(requested == [1, 2, 4, 5])
    let empty = SwitcherController.desktopItem(for: desktop, windows: []) { _ in nil }
    #expect(empty.title == String(localized: "Full Screen") && empty.appIcons.isEmpty)
}

@MainActor @Test func desktopStripRefreshPreservesSelectionBySpaceID() {
    guard NSScreen.main != nil else { return }
    let spaces = FakeSpaceSwitcher()
    let (c, tracker, _, _, p) = fixture(1, settings: taskSettings(), spaces: spaces)
    c.open(profileID: "task-view", reverse: false)
    c.handle(.moveDown)
    c.handle(.moveRight)
    tracker.windows.append(WindowInfo(id: 9, pid: 9, appName: "Video", isFullscreen: true, spaceIDs: [30]))
    spaces.desktops.swapAt(0, 2)
    tracker.onChange?()
    #expect(p.desktops.first?.title == "Video" && p.desktopSelection == 0)
    spaces.desktops.removeFirst(2)
    tracker.onChange?()
    #expect(p.desktops.isEmpty && p.desktopSelection == nil)
}

@MainActor @Test func desktopTileClickAndHitTesting() throws {
    let desktops = FakeSpaceSwitcher().desktops
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
    let strip = DesktopStripView()
    host.addSubview(strip)
    let layout = TaskViewLayout.DesktopStrip(count: desktops.count, screenWidth: host.bounds.width)
    strip.setItems(desktops.map { DesktopItem(desktop: $0, title: "Tile", appIcons: []) })
    strip.place(using: layout)
    var clicked: Int?
    strip.onClick = { clicked = $0 }

    let frame = layout.tileFrame(at: 1).offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
    let titlePoint = CGPoint(x: frame.midX, y: frame.minY + 8)
    let tile = try #require(host.hitTest(titlePoint))
    #expect(tile === host.hitTest(CGPoint(x: frame.midX, y: frame.midY)))
    #expect(!tile.acceptsFirstResponder)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: titlePoint, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               eventNumber: 1, clickCount: 1, pressure: 1))
    tile.mouseDown(with: event)
    #expect(clicked == 1)
    #expect(host.hitTest(CGPoint(x: frame.maxX + 1, y: frame.midY)) === host)
}

@MainActor @Test func closedWindowsAreInvalidatedInTheThumbnailCache() {
    let thumbnails = FakeThumbnails()
    let (c, tracker, _, _, _) = fixture(5, thumbnails: thumbnails)
    c.start()
    tracker.onChange?()
    #expect(thumbnails.invalidated.isEmpty)
    tracker.windows.removeAll { $0.id == 2 || $0.id == 5 }
    tracker.onChange?()
    #expect(Set(thumbnails.invalidated) == [2, 5])
    tracker.onChange?()
    #expect(thumbnails.invalidated.count == 2)
}

@MainActor @Test func thumbnailsLoadWithBoundedConcurrencyInPriorityOrder() async throws {
    guard NSScreen.main != nil else { return }
    let thumbnails = FakeThumbnails()
    thumbnails.captureDelay = 30_000_000
    let (c, _, _, _, panel) = fixture(10, thumbnails: thumbnails)
    panel.thumbnailPixelSize = CGSize(width: 200, height: 120)
    c.open(profileID: "all-windows", reverse: false)
    for _ in 0..<200 where panel.thumbnailUpdates.count < 10 { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(Set(panel.thumbnailUpdates) == Set((1...10).map { CGWindowID($0) }))
    #expect(thumbnails.maxRunning > 1 && thumbnails.maxRunning <= SwitcherController.maxConcurrentCaptures)
    #expect(thumbnails.requested.first == CGWindowID(panel.items[panel.selection].id))
    c.close()
}

@MainActor @Test func iconCachePrunesAppsWithoutTrackedWindows() {
    typealias Key = SwitcherController.IconKey
    let image = NSImage(size: NSSize(width: 8, height: 8))
    var cache: [Key: NSImage] = [
        Key(pid: 1, bundleIdentifier: "a"): image,
        Key(pid: 2, bundleIdentifier: "b"): image,
        Key(pid: 1, bundleIdentifier: "reused"): image,
    ]
    SwitcherController.pruneIconCache(&cache, keeping: [WindowInfo(id: 1, pid: 1, bundleIdentifier: "a")])
    #expect(Array(cache.keys) == [Key(pid: 1, bundleIdentifier: "a")])
}
