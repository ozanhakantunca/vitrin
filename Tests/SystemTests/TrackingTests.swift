// Tests for the pure parts of window tracking (no Accessibility permission needed).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import VitrinCore
@testable import VitrinSystem

/// Set `VITRIN_SKIP_WINDOWSERVER_TESTS=1` on headless CI runners without a GUI login session.
private let hasWindowServerSession = ProcessInfo.processInfo.environment["VITRIN_SKIP_WINDOWSERVER_TESTS"] == nil

private typealias Attributes = Tracking.AXWindowAttributes
private typealias Record = Tracking.WindowServerRecord

private func standardWindow(_ subrole: String? = kAXStandardWindowSubrole as String, title: String? = "Doc",
                            size: CGSize = CGSize(width: 800, height: 600), isMain: Bool? = false,
                            isFullscreen: Bool? = false) -> Attributes {
    Attributes(role: kAXWindowRole as String, subrole: subrole, title: title, position: .zero, size: size,
               isMinimized: false, isFullscreen: isFullscreen, isMain: isMain)
}

private func switchable(_ attributes: Attributes, layer: Int? = 0, windowID: CGWindowID? = 42,
                        bundle: String? = "com.example.app") -> Bool {
    let record = layer.map { Record(id: windowID ?? 0, pid: 1, layer: $0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)) }
    return Tracking.Eligibility.isSwitchable(windowID: windowID, attributes: attributes, record: record, bundleIdentifier: bundle)
}

@Suite struct TrackingEligibilityTests {
    @Test func standardWindowsAndDialogsAreSwitchable() {
        #expect(switchable(standardWindow()))
        #expect(switchable(standardWindow(kAXDialogSubrole as String)))
        #expect(switchable(standardWindow(kAXDialogSubrole as String, title: nil)))
    }

    @Test func requiresAWindowIDAndWindowRole() {
        #expect(!switchable(standardWindow(), windowID: nil))
        #expect(!switchable(standardWindow(), windowID: 0))
        var group = standardWindow()
        group.role = "AXGroup"
        #expect(!switchable(group))
    }

    @Test func floatingPanelsAndSystemDialogsAreAuxiliary() {
        #expect(!switchable(standardWindow(kAXFloatingWindowSubrole as String)))
        #expect(!switchable(standardWindow("AXSystemDialog")))
        // …except for apps whose real windows float.
        #expect(switchable(standardWindow(kAXFloatingWindowSubrole as String), layer: 3, bundle: "com.colliderli.iina"))
    }

    @Test func tinyWindowsAreSkipped() {
        #expect(!switchable(standardWindow(size: CGSize(width: 60, height: 40))))
        #expect(switchable(standardWindow(size: CGSize(width: 120, height: 40))))
        #expect(switchable(standardWindow(size: CGSize(width: 40, height: 120))))
    }

    @Test func onlyNormalLevelUnlessFullscreenOrMain() {
        #expect(!switchable(standardWindow(), layer: 3))
        #expect(switchable(standardWindow(isFullscreen: true), layer: 3))
        #expect(switchable(standardWindow(isMain: true), layer: 3))
        // Below normal is the desktop layer: never, even when "main".
        #expect(!switchable(standardWindow(isMain: true), layer: -2147483623))
        // Unknown level (no WindowServer row) is permissive.
        #expect(switchable(standardWindow(), layer: nil))
    }

    @Test func customWindowRoots() {
        // Broken / custom toolkits: AXWindow without a conventional subrole.
        #expect(switchable(standardWindow("AXUnknown", title: "Emulator")))
        #expect(switchable(standardWindow(nil, title: nil, isMain: true)))
        #expect(!switchable(standardWindow("AXUnknown", title: nil)))
        #expect(!switchable(standardWindow("AXUnknown", title: "Strip", size: CGSize(width: 720, height: 40))))
    }

    @Test func standardWindowsForQuitOnLastWindowClose() {
        let standard = kAXStandardWindowSubrole as String
        #expect(Tracking.Eligibility.isStandardWindow(.init(role: kAXWindowRole as String, subrole: standard, canMinimize: true)))
        // Open/save panels, About and settings windows: a disabled or missing minimize button.
        #expect(!Tracking.Eligibility.isStandardWindow(.init(role: kAXWindowRole as String, subrole: standard, canMinimize: false)))
        // Minimized / fullscreen windows aren't checked for the button.
        #expect(Tracking.Eligibility.isStandardWindow(.init(role: kAXWindowRole as String, subrole: standard, isMinimized: true)))
        #expect(!Tracking.Eligibility.isStandardWindow(.init(role: kAXWindowRole as String, subrole: kAXDialogSubrole as String)))
        #expect(!Tracking.Eligibility.isStandardWindow(.init(role: kAXWindowRole as String, subrole: nil, isMain: true)))
    }

    @Test func sizeFallsBackToWindowServerBounds() {
        var attributes = standardWindow()
        attributes.size = nil
        #expect(switchable(attributes))
        #expect(!Tracking.Eligibility.isSwitchable(windowID: 1, attributes: attributes, record: nil, bundleIdentifier: nil))
    }

    @Test func appSelection() {
        let rules = Tracking.Eligibility.self
        #expect(rules.shouldTrack(pid: 10, ownPID: 1, activationPolicy: .regular, isTerminated: false))
        #expect(rules.shouldTrack(pid: 10, ownPID: 1, activationPolicy: .accessory, isTerminated: false))
        #expect(!rules.shouldTrack(pid: 10, ownPID: 1, activationPolicy: .prohibited, isTerminated: false))
        #expect(!rules.shouldTrack(pid: 10, ownPID: 10, activationPolicy: .regular, isTerminated: false))
        #expect(!rules.shouldTrack(pid: 10, ownPID: 1, activationPolicy: .regular, isTerminated: true))
        #expect(!rules.shouldTrack(pid: -1, ownPID: 1, activationPolicy: .regular, isTerminated: false))
    }
}

@Suite struct TrackingWindowListTests {
    private func dictionary(id: CGWindowID, pid: pid_t, layer: Int = 0, onScreen: Bool = true, alpha: Double = 1,
                            bounds: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200), name: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowIsOnscreen as String: NSNumber(value: onScreen),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
        if let name { result[kCGWindowName as String] = name }
        return result
    }

    @Test func parsesCGWindowListRows() throws {
        let rows = [
            dictionary(id: 5, pid: 100, name: "Inbox"),
            [kCGWindowOwnerPID as String: NSNumber(value: 1)], // no id
            dictionary(id: 6, pid: 101, layer: 25, onScreen: false, alpha: 0.5, name: ""),
        ]
        let records = Record.parse(rows)
        #expect(records.count == 2)
        let first = try #require(records.first)
        #expect(first == Record(id: 5, pid: 100, layer: 0, bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
                                alpha: 1, isOnScreen: true, title: "Inbox"))
        #expect(records[1].layer == 25 && !records[1].isOnScreen && records[1].alpha == 0.5 && records[1].title == nil)
    }

    @Test func zOrderSeedKeepsVisibleNormalWindowsOfTrackedApps() {
        let records = [
            Record(id: 1, pid: 10, layer: 25),                    // menu bar extra
            Record(id: 2, pid: 10),                                // front window
            Record(id: 3, pid: 99),                                // untracked app
            Record(id: 4, pid: 11, isOnScreen: false),             // other Space / minimized
            Record(id: 5, pid: 11, alpha: 0),                      // invisible helper
            Record(id: 6, pid: 11),
            Record(id: 2, pid: 10),                                // duplicate row
        ]
        let seed = Tracking.ZOrder.seed(records, pids: [10, 11])
        #expect(seed == [2, 6])
        let history = FocusHistory(mostRecentFirst: seed)
        #expect(history.mostRecentFirst == [2, 6])
        #expect(Tracking.ZOrder.indices(records) == [1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5])
    }

    @Test func mruOrderPutsFocusedFirstThenZOrder() {
        var history = FocusHistory()
        history.recordFocus(30)
        history.recordFocus(10) // most recent
        let windows = [40, 30, 20, 10, 50].map { WindowInfo(id: CGWindowID($0), pid: 1) }
        let zIndex: [CGWindowID: Int] = [50: 0, 20: 1, 40: 2]
        let ordered = Tracking.ZOrder.mruOrdered(windows, history: history, zIndex: zIndex)
        #expect(ordered.map(\.id) == [10, 30, 50, 20, 40])
        #expect(ordered[0].lastFocusSequence != nil && ordered[2].lastFocusSequence == nil)
    }
}

@Suite struct TrackingGeometryTests {
    private let displays = [
        Tracking.DisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), uuid: "AAAA-1"),
        Tracking.DisplayInfo(id: 2, bounds: CGRect(x: 1440, y: -200, width: 2560, height: 1440), uuid: "bbbb-2"),
    ]

    @Test func displayWithLargestOverlapWins() {
        #expect(Tracking.Geometry.displayID(for: CGRect(x: 100, y: 100, width: 400, height: 300), displays: displays) == 1)
        #expect(Tracking.Geometry.displayID(for: CGRect(x: 1300, y: 100, width: 800, height: 300), displays: displays) == 2)
        #expect(Tracking.Geometry.displayID(for: CGRect(x: 1000, y: 100, width: 600, height: 300), displays: displays) == 1)
    }

    @Test func offscreenFrameMapsToNearestDisplay() {
        #expect(Tracking.Geometry.displayID(for: CGRect(x: -5000, y: 10, width: 100, height: 100), displays: displays) == 1)
        #expect(Tracking.Geometry.displayID(for: CGRect(x: 9000, y: 10, width: 100, height: 100), displays: displays) == 2)
        #expect(Tracking.Geometry.displayID(for: .zero, displays: []) == nil)
    }

    @Test func pointAndUUIDLookup() {
        #expect(Tracking.Geometry.displayID(containing: CGPoint(x: 1500, y: -100), displays: displays) == 2)
        #expect(Tracking.Geometry.displayID(containing: CGPoint(x: 100, y: 2000), displays: displays) == nil)
        #expect(Tracking.Geometry.displayID(forUUID: "BBBB-2", displays: displays) == 2)
        #expect(Tracking.Geometry.displayID(forUUID: nil, displays: displays) == nil)
    }

    @Test func contextFromPlainValues() {
        let windows = [
            WindowInfo(id: 1, pid: 7, isMinimized: true, displayID: 1),
            WindowInfo(id: 2, pid: 7, displayID: 2),
            WindowInfo(id: 3, pid: 8, displayID: 1),
        ]
        let context = Tracking.Context.make(frontmostPID: 7, currentSpaceIDs: [4, 9], mruWindows: windows,
                                            activeMenuBarDisplayUUID: "AAAA-1", mouseLocation: CGPoint(x: 10, y: 10),
                                            displays: displays)
        #expect(context == SwitcherContext(activePID: 7, currentSpaceIDs: [4, 9], activeDisplayID: 2, mouseDisplayID: 1))

        // No window of the frontmost app: fall back to the active menu bar's display.
        let fallback = Tracking.Context.make(frontmostPID: 99, currentSpaceIDs: [], mruWindows: windows,
                                             activeMenuBarDisplayUUID: "bbbb-2", mouseLocation: nil, displays: displays)
        #expect(fallback == SwitcherContext(activePID: 99, currentSpaceIDs: [], activeDisplayID: 2, mouseDisplayID: nil))
    }
}

@Suite struct TrackingDiagnosticsTests {
    @Test func dumpListsEveryField() {
        let window = WindowInfo(id: 77, pid: 12, bundleIdentifier: "com.example.app", appName: "Example",
                                title: "Say \"hi\"", frame: CGRect(x: 1, y: 2, width: 300, height: 200),
                                isMinimized: true, isAppHidden: false, isFullscreen: true, spaceIDs: [3, 5],
                                displayID: 1, lastFocusSequence: 9)
        let text = Tracking.Dump.text(header: ["header"], context: SwitcherContext(activePID: 12, currentSpaceIDs: [3]),
                                      mruWindows: [window])
        #expect(text.contains("header"))
        #expect(text.contains("activePID=12 currentSpaces=[3]"))
        #expect(text.contains("0. wid=77 pid=12 app=\"Example\" bundle=com.example.app title=\"Say \\\"hi\\\"\""))
        #expect(text.contains("frame=1,2 300x200 minimized=true appHidden=false fullscreen=true standard=true spaces=[3,5] display=1 seq=9"))
    }
}

@Suite struct TrackingFocusPlanTests {
    private let window = WindowInfo(id: 1, pid: 50, spaceIDs: [7])

    @Test func crossSpaceFocusRestoresTheOriginFront() {
        let plan = WindowActor.focusPlan(window: window, originSpace: 3, originFrontPID: 40, ownPID: 1)
        #expect(plan.restoreOriginFront?.space == 3 && plan.restoreOriginFront?.pid == 40)
    }

    @Test func noRepairWhenNotKnownToBeElsewhere() {
        let plan = WindowActor.FocusPlan()
        #expect(WindowActor.focusPlan(window: window, originSpace: 7, originFrontPID: 40, ownPID: 1) == plan)
        #expect(WindowActor.focusPlan(window: WindowInfo(id: 1, pid: 50), originSpace: 3, originFrontPID: 40, ownPID: 1) == plan)
        #expect(WindowActor.focusPlan(window: window, originSpace: 3, originFrontPID: 50, ownPID: 1) == plan)
        #expect(WindowActor.focusPlan(window: window, originSpace: 3, originFrontPID: 1, ownPID: 1) == plan)
        #expect(WindowActor.focusPlan(window: window, originSpace: nil, originFrontPID: 40, ownPID: 1) == plan)
    }
}

@Suite(.enabled(if: hasWindowServerSession)) struct TrackingWindowServerTests {
    @Test func snapshotListsWindows() {
        let snapshot = Tracking.WindowServerSnapshot()
        let records = snapshot.records()
        #expect(records.allSatisfy { $0.id != 0 })
        #expect(snapshot.records() == records) // served from the short-lived cache
        #expect(!Tracking.DisplayInfo.active().isEmpty)
    }

    @Test @MainActor func trackerLifecycleIsHarmless() {
        let tracker = WindowTracker()
        tracker.start()
        tracker.start() // idempotent
        #expect(tracker.isStarted)
        #expect(tracker.isObservingAccessibility == AXIsProcessTrusted())
        _ = tracker.currentContext()
        #expect(tracker.debugDump().contains("Vitrin window tracker: started=true"))
        tracker.stop()
        #expect(!tracker.isStarted)
        #expect(tracker.axElement(for: 1) == nil)
    }

    @Test @MainActor func oneShotDump() {
        let text = WindowTracker.dumpWithoutStarting()
        print(text)
        #expect(text.contains("Vitrin window dump"))
        #expect(text.contains("windows ("))
    }

    @Test @MainActor func actorRefusesOwnAndDeadProcesses() {
        let actor = WindowActor(tracker: WindowTracker())
        #expect(!actor.perform(.close, on: WindowInfo(id: 1, pid: ProcessInfo.processInfo.processIdentifier)))
        #expect(!actor.perform(.focus, on: WindowInfo(id: 1, pid: 999_999)))
    }
}
