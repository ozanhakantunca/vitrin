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
    func perform(_ action: WindowAction, on window: WindowInfo) -> Bool { actions.append((action, window)); return true }
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
private final class FakeThumbnails: ThumbnailProviding {
    let isAvailable = false
    func cachedThumbnail(for windowID: CGWindowID) -> CGImage? { nil }
    func thumbnail(for windowID: CGWindowID, maxPixelSize: CGSize) async -> CGImage? { nil }
    func invalidate(windowID: CGWindowID) {}
    func removeAll() {}
}
@MainActor private final class FakePanel: SwitcherPresentingF2 {
    var isVisible = false
    let columns = 3
    let thumbnailPixelSize = CGSize.zero
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onAction: ((Int, WindowAction) -> Void)?
    var items: [SwitcherItem] = []
    var selection = 0
    var query = ""
    var badges: [CGWindowID: SwitcherBadges] = [:]
    func show(items: [SwitcherItem], selectedIndex: Int, profile: ShortcutProfile, on screen: NSScreen) { self.items = items; selection = selectedIndex; isVisible = true }
    func updateSelection(_ index: Int) { selection = index }
    func updateThumbnail(windowID: CGWindowID, image: CGImage) {}
    func hide() { isVisible = false }
    func setSearchQuery(_ query: String) { self.query = query }
    func setBadges(_ badges: [CGWindowID: SwitcherBadges]) { self.badges = badges }
}
@MainActor private func fixture(_ count: Int) -> (SwitcherController, FakeTracker, FakeActor, FakeHotkeys, FakePanel) {
    let tracker = FakeTracker(); let actor = FakeActor(); let hotkeys = FakeHotkeys(); let panel = FakePanel()
    tracker.windows = (0..<count).map { (index: Int) -> WindowInfo in
        let pid: pid_t = index < 2 ? 1 : 2
        let appName: String = index == 0 ? "Chrome" : "App"
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        return WindowInfo(id: CGWindowID(index + 1), pid: pid, appName: appName, title: "Window \(index)", frame: frame)
    }
    return (SwitcherController(settings: .defaults, tracker: tracker, actor: actor, hotkeys: hotkeys, thumbnails: FakeThumbnails(), panel: panel), tracker, actor, hotkeys, panel)
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
