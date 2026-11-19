import CoreGraphics
import Testing
@testable import VitrinCore

private func window(
    _ id: CGWindowID, pid: pid_t = 100, bundle: String? = nil,
    minimized: Bool = false, hidden: Bool = false, fullscreen: Bool = false,
    spaces: [SpaceID] = [1], display: CGDirectDisplayID? = 1
) -> WindowInfo {
    WindowInfo(id: id, pid: pid, bundleIdentifier: bundle, appName: "App\(pid)", title: "W\(id)",
               isMinimized: minimized, isAppHidden: hidden, isFullscreen: fullscreen,
               spaceIDs: spaces, displayID: display)
}

@Suite struct FocusHistoryTests {
    @Test func focusMovesWindowToFront() {
        var history = FocusHistory()
        history.recordFocus(1)
        history.recordFocus(2)
        history.recordFocus(3)
        #expect(history.mostRecentFirst == [3, 2, 1])
        history.recordFocus(1)
        #expect(history.mostRecentFirst == [1, 3, 2])
        history.recordFocus(1)
        #expect(history.mostRecentFirst == [1, 3, 2])
    }

    @Test func seededFromZOrder() {
        let history = FocusHistory(mostRecentFirst: [7, 8, 9])
        #expect(history.mostRecentFirst == [7, 8, 9])
    }

    @Test func removalAndPruning() {
        var history = FocusHistory(mostRecentFirst: [1, 2, 3, 4])
        history.remove(2)
        #expect(history.mostRecentFirst == [1, 3, 4])
        #expect(history.sequence(for: 2) == nil)
        history.retainOnly([4, 1, 99])
        #expect(history.mostRecentFirst == [1, 4])
        history.remove(42) // unknown id is a no-op
        #expect(history.mostRecentFirst == [1, 4])
    }

    @Test func unseenWindowsKeepInputOrderAfterFocusedOnes() {
        var history = FocusHistory()
        history.recordFocus(30)
        history.recordFocus(10)
        // Input order (e.g. z-order) for the unseen windows: 50, 20, 40.
        let ordered = history.ordered([window(50), window(10), window(20), window(30), window(40)])
        #expect(ordered.map(\.id) == [10, 30, 50, 20, 40])
        #expect(ordered.map(\.lastFocusSequence) == [2, 1, nil, nil, nil])
    }

    @Test func orderingIsStableAcrossCalls() {
        let history = FocusHistory(mostRecentFirst: [3])
        let input = (1...20).map { window(CGWindowID($0)) }
        let first = history.ordered(input).map(\.id)
        #expect(first == [3] + (1...20).filter { $0 != 3 }.map(CGWindowID.init))
        #expect(history.ordered(input.reversed()).map(\.id) == [3] + (1...20).reversed().filter { $0 != 3 }.map(CGWindowID.init))
    }
}

@Suite struct WindowFilterTests {
    let windows: [WindowInfo] = [
        window(1, pid: 100, spaces: [1], display: 1),
        window(2, pid: 200, spaces: [2], display: 1),                 // other space, same display
        window(3, pid: 100, minimized: true, spaces: [1], display: 1),
        window(4, pid: 300, hidden: true, spaces: [3], display: 2),   // hidden app on display 2's current space
        window(5, pid: 200, fullscreen: true, spaces: [9], display: 2),
        window(6, pid: 400, spaces: [], display: nil),                // unknown space / display → permissive
        window(7, pid: 100, bundle: "com.vm.app", spaces: [1, 3], display: 2), // on several spaces
    ]
    let context = SwitcherContext(activePID: 100, currentSpaceIDs: [1, 3], activeDisplayID: 1, mouseDisplayID: 2)

    func ids(_ filters: WindowFilters, _ context: SwitcherContext? = nil) -> [CGWindowID] {
        ShortcutProfile(name: "t", trigger: nil, filters: filters)
            .windows(from: windows, context: context ?? self.context).map(\.id)
    }

    @Test func defaultFiltersShowEverything() {
        #expect(ids(WindowFilters()) == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func activeAppOnly() {
        #expect(ids(WindowFilters(apps: .activeApp)) == [1, 3, 7])
        #expect(ids(WindowFilters(apps: .activeApp), SwitcherContext()) == [])
    }

    @Test func currentSpacesOnly() {
        #expect(ids(WindowFilters(spaces: .current)) == [1, 3, 4, 6, 7])
        // Unknown current spaces → no space filtering.
        #expect(ids(WindowFilters(spaces: .current), SwitcherContext(activePID: 100)) == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func screens() {
        #expect(ids(WindowFilters(screens: .active)) == [1, 2, 3, 6])
        #expect(ids(WindowFilters(screens: .withMouse)) == [4, 5, 6, 7])
    }

    @Test func stateFlags() {
        #expect(ids(WindowFilters(includeMinimized: false)) == [1, 2, 4, 5, 6, 7])
        #expect(ids(WindowFilters(includeHidden: false)) == [1, 2, 3, 5, 6, 7])
        #expect(ids(WindowFilters(includeFullscreen: false)) == [1, 2, 3, 4, 6, 7])
    }

    @Test func combinedFiltersWithMRUOrder() {
        let profile = ShortcutProfile(name: "t", trigger: nil,
                                      filters: WindowFilters(spaces: .current, includeMinimized: false))
        let history = FocusHistory(mostRecentFirst: [7, 2, 4])
        let result = profile.windows(from: windows, history: history, context: context).map(\.id)
        #expect(result == [7, 4, 1, 6])
    }

    @Test func alwaysHiddenExceptionsAreRemoved() {
        let profile = ShortcutProfile(name: "t", trigger: nil)
        let exceptions = [AppException(bundleIdentifier: "com.vm.app", hide: .always),
                          AppException(bundleIdentifier: "com.other", hide: .always)]
        #expect(profile.windows(from: windows, exceptions: exceptions, context: context).map(\.id) == [1, 2, 3, 4, 5, 6])
        let notHidden = [AppException(bundleIdentifier: "com.vm.app", hide: .whenNoOpenWindows)]
        #expect(profile.windows(from: windows, exceptions: notHidden, context: context).count == 7)
    }

    @Test func windowIdentityIsByID() {
        var renamed = windows[0]
        renamed.title = "changed"
        #expect(renamed != windows[0])
        #expect(Set([renamed, windows[0]]).count == 2)
        #expect(renamed.hashValue == windows[0].hashValue)
        #expect(renamed.id == windows[0].id)
    }
}
