// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Live inventory of every switchable window plus the MRU focus history.
//
// Threading model
// - `WindowTracker` is main-actor only. It never makes an AX call itself: `windows`, `axElement(for:)` and
//   `currentContext()` read state that is already current (the last two do cheap, non-AX WindowServer /
//   CoreGraphics reads at most).
// - Each tracked app has a `Tracking.AppObserver` with its own serial queue; all AX IPC for that app runs
//   there with a 0.5 s messaging timeout, so a hung app only delays its own updates.
// - Observers publish results with `DispatchQueue.main.async`; the tracker applies them and coalesces
//   `onChange` to at most one call per main run-loop turn.
//
// Event sources: NSWorkspace (launch / terminate / activate / hide / unhide / active Space / wake),
// screen-parameter changes, and one AXObserver per app (window created, element destroyed, focused & main
// window changed, (de)miniaturized, title changed, moved, resized, app activated / hidden / shown).

import AppKit
import ApplicationServices
import CoreGraphics
import VitrinCore
import VitrinPrivate

@MainActor
public final class WindowTracker: WindowTracking {
    /// Current windows, already in MRU order (never-focused windows follow in WindowServer z-order).
    public private(set) var windows: [WindowInfo] = []
    public private(set) var focusHistory = FocusHistory()
    public var onChange: (() -> Void)?

    /// Whether `start()` was called (and `stop()` wasn't since).
    public private(set) var isStarted = false
    /// Whether AX observation is running (requires the Accessibility permission).
    public private(set) var isObservingAccessibility = false

    private struct TrackedApp {
        let observer: Tracking.AppObserver
        let runningApplication: NSRunningApplication
        var isHidden: Bool
    }

    private struct HistoryOwner {
        var pid: pid_t
        /// Uptime ns of the last `recordFocus` / seed for this id.
        var recordedAt: UInt64
    }

    private var apps: [pid_t: TrackedApp] = [:]
    private var windowsByID: [CGWindowID: WindowInfo] = [:]
    private var elementsByID: [CGWindowID: AXUIElement] = [:]
    private var windowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
    private var historyOwners: [CGWindowID: HistoryOwner] = [:]
    private var zIndex: [CGWindowID: Int] = [:]
    private var frontmostPID: pid_t?
    private var lastRecordedFocus: CGWindowID?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var defaultCenterTokens: [NSObjectProtocol] = []
    private var changeScheduled = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    // MARK: WindowTracking

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        registerNotifications()
        frontmostPID = Self.frontmostNonSelfPID(ownPID: ownPID)
        let records = Tracking.WindowServerSnapshot.shared.records()
        zIndex = Tracking.ZOrder.indices(records)
        seedHistoryIfEmpty(records)
        startAccessibilityIfTrusted()
        scheduleChange()
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(workspaceCenter.removeObserver)
        defaultCenterTokens.forEach(NotificationCenter.default.removeObserver)
        workspaceTokens.removeAll()
        defaultCenterTokens.removeAll()
        for app in apps.values { app.observer.invalidate() }
        apps.removeAll()
        windowsByID.removeAll()
        elementsByID.removeAll()
        windowIDsByPID.removeAll()
        historyOwners.removeAll()
        focusHistory = FocusHistory()
        lastRecordedFocus = nil
        isObservingAccessibility = false
        scheduleChange()
    }

    public func currentContext() -> SwitcherContext {
        let displays = Tracking.DisplayInfo.active()
        return Tracking.Context.make(
            frontmostPID: frontmostPID ?? Self.frontmostNonSelfPID(ownPID: ownPID),
            currentSpaceIDs: SkyLight.currentSpaces() ?? [],
            mruWindows: windows,
            activeMenuBarDisplayUUID: SkyLight.activeMenuBarDisplayIdentifier(),
            mouseLocation: CGEvent(source: nil)?.location,
            displays: displays
        )
    }

    public func axElement(for windowID: CGWindowID) -> AXUIElement? {
        elementsByID[windowID]
    }

    public func refreshAll() {
        guard isStarted else {
            start()
            return
        }
        Tracking.WindowServerSnapshot.shared.invalidate()
        let records = Tracking.WindowServerSnapshot.shared.records()
        zIndex = Tracking.ZOrder.indices(records)
        frontmostPID = Self.frontmostNonSelfPID(ownPID: ownPID) ?? frontmostPID
        seedHistoryIfEmpty(records)
        if isObservingAccessibility {
            addRunningApps()
            for app in apps.values {
                app.observer.requestRescan(bruteForce: true, resetBruteForce: true, delay: 0)
            }
            requestFocusedWindowOfFrontmostApp()
        } else {
            startAccessibilityIfTrusted()
        }
        scheduleChange()
    }

    // MARK: Diagnostics

    /// Every tracked window with all fields, in MRU order, plus the current context.
    public func debugDump() -> String {
        let header = [
            "Vitrin window tracker: started=\(isStarted) accessibility=\(AXIsProcessTrusted())"
                + " observing=\(isObservingAccessibility) apps=\(apps.count) history=\(focusHistory.mostRecentFirst.count)",
        ]
        return Tracking.Dump.text(header: header, context: currentContext(), mruWindows: windows)
    }

    /// A one-shot synchronous scan of every app, without starting observers, as `debugDump()` text.
    /// Blocks the caller (AX reads run concurrently on background threads); meant for `--dump-windows`.
    public static func dumpWithoutStarting() -> String {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            Tracking.Eligibility.shouldTrack(pid: $0.processIdentifier, ownPID: ownPID,
                                             activationPolicy: $0.activationPolicy, isTerminated: $0.isTerminated)
        }
        let identities = running.map(Self.identity(of:))
        let hiddenPIDs = Set(running.filter(\.isHidden).map(\.processIdentifier))
        let records = Tracking.WindowServerSnapshot.shared.records()
        var history = FocusHistory(mostRecentFirst: Tracking.ZOrder.seed(records, pids: Set(identities.map(\.pid))))
        let trusted = AXIsProcessTrusted()
        let frontPID = frontmostNonSelfPID(ownPID: ownPID)

        var scans: [Tracking.AppScan] = []
        if trusted {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Tracking.axMessagingTimeout)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: identities.count) { index in
                let scan = Tracking.AppScanner(identity: identities[index]).scan(bruteForce: true)
                lock.lock()
                scans.append(scan)
                lock.unlock()
            }
        }
        var all: [WindowInfo] = []
        for scan in scans {
            for window in scan.windows {
                var info = window.info
                info.isAppHidden = hiddenPIDs.contains(info.pid)
                all.append(info)
            }
            if let focused = scan.focusedWindowID, let pid = scan.windows.first?.info.pid, pid == frontPID {
                history.recordFocus(focused)
            }
        }
        let ordered = Tracking.ZOrder.mruOrdered(all, history: history, zIndex: Tracking.ZOrder.indices(records))
        let context = Tracking.Context.make(
            frontmostPID: frontPID,
            currentSpaceIDs: SkyLight.currentSpaces() ?? [],
            mruWindows: ordered,
            activeMenuBarDisplayUUID: SkyLight.activeMenuBarDisplayIdentifier(),
            mouseLocation: CGEvent(source: nil)?.location,
            displays: Tracking.DisplayInfo.active()
        )
        let header = [
            "Vitrin window dump (one-shot, observers not started): accessibility=\(trusted)"
                + " apps=\(identities.count) windowServerWindows=\(records.count)",
        ] + (trusted ? [] : ["(Accessibility not granted: no AX window data available)"])
        return Tracking.Dump.text(header: header, context: context, mruWindows: ordered)
    }

    // MARK: Setup

    private func startAccessibilityIfTrusted() {
        guard isStarted, !isObservingAccessibility, AXIsProcessTrusted() else { return }
        isObservingAccessibility = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Tracking.axMessagingTimeout)
        addRunningApps()
        requestFocusedWindowOfFrontmostApp()
    }

    private func addRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            addApp(app)
        }
    }

    private func addApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isObservingAccessibility, apps[pid] == nil,
              Tracking.Eligibility.shouldTrack(pid: pid, ownPID: ownPID, activationPolicy: app.activationPolicy,
                                               isTerminated: app.isTerminated) else { return }
        let observer = Tracking.AppObserver(identity: Self.identity(of: app)) { [weak self] observer, event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(event, from: observer)
                }
            }
        }
        apps[pid] = TrackedApp(observer: observer, runningApplication: app, isHidden: app.isHidden)
        observer.start()
    }

    private func removeApp(pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        app.observer.invalidate()
        for windowID in windowIDsByPID[pid] ?? [] {
            removeWindow(windowID)
        }
        windowIDsByPID[pid] = nil
        for (windowID, owner) in historyOwners where owner.pid == pid {
            focusHistory.remove(windowID)
            historyOwners[windowID] = nil
        }
        scheduleChange()
    }

    private static func identity(of app: NSRunningApplication) -> Tracking.AppIdentity {
        Tracking.AppIdentity(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.bundleIdentifier ?? ""
        )
    }

    private static func frontmostNonSelfPID(ownPID: pid_t) -> pid_t? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != ownPID else { return nil }
        return pid
    }

    private func seedHistoryIfEmpty(_ records: [Tracking.WindowServerRecord]) {
        guard focusHistory.isEmpty else { return }
        let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            Tracking.Eligibility.shouldTrack(pid: app.processIdentifier, ownPID: ownPID,
                                             activationPolicy: app.activationPolicy, isTerminated: app.isTerminated)
                ? app.processIdentifier : nil
        })
        let seed = Tracking.ZOrder.seed(records, pids: pids)
        focusHistory = FocusHistory(mostRecentFirst: seed)
        let now = DispatchTime.now().uptimeNanoseconds
        let ownerByID = Dictionary(records.map { ($0.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
        for windowID in seed {
            if let pid = ownerByID[windowID] { historyOwners[windowID] = HistoryOwner(pid: pid, recordedAt: now) }
        }
    }

    private func requestFocusedWindowOfFrontmostApp() {
        guard let pid = frontmostPID else { return }
        apps[pid]?.observer.requestFocusedWindow()
    }

    // MARK: Notifications

    private func registerNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (WindowTracker, Notification) -> Void) {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self, note)
                }
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { tracker, note in
            guard let app = Self.application(note) else { return }
            tracker.addApp(app)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { tracker, note in
            guard let app = Self.application(note) else { return }
            tracker.removeApp(pid: app.processIdentifier)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { tracker, note in
            guard let app = Self.application(note) else { return }
            tracker.applicationActivated(app)
        }
        observe(NSWorkspace.didHideApplicationNotification) { tracker, note in
            guard let app = Self.application(note) else { return }
            tracker.setHidden(true, pid: app.processIdentifier)
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { tracker, note in
            guard let app = Self.application(note) else { return }
            tracker.setHidden(false, pid: app.processIdentifier)
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { tracker, _ in
            tracker.spacesChanged()
        }
        observe(NSWorkspace.didWakeNotification) { tracker, _ in
            tracker.refreshAll()
        }
        defaultCenterTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    private static func application(_ note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ownPID else { return }
        frontmostPID = pid
        if apps[pid] == nil { addApp(app) } // e.g. an app that switched activation policy
        apps[pid]?.observer.requestFocusedWindow()
    }

    private func setHidden(_ hidden: Bool, pid: pid_t) {
        guard var app = apps[pid] else { return }
        app.isHidden = hidden
        apps[pid] = app
        for windowID in windowIDsByPID[pid] ?? [] {
            windowsByID[windowID]?.isAppHidden = hidden
        }
        app.observer.requestRescan(bruteForce: false)
        scheduleChange()
    }

    private func spacesChanged() {
        Tracking.WindowServerSnapshot.shared.invalidate()
        zIndex = Tracking.ZOrder.indices(Tracking.WindowServerSnapshot.shared.records())
        for app in apps.values {
            app.observer.requestRescan(bruteForce: true, delay: 0.05)
        }
        frontmostPID = Self.frontmostNonSelfPID(ownPID: ownPID) ?? frontmostPID
        requestFocusedWindowOfFrontmostApp()
    }

    private func screensChanged() {
        Tracking.WindowServerSnapshot.shared.invalidate()
        for app in apps.values {
            app.observer.requestRescan(bruteForce: false, delay: 0.2)
        }
    }

    // MARK: Applying observer events

    private func handle(_ event: Tracking.AppObserver.Event, from observer: Tracking.AppObserver) {
        let pid = observer.identity.pid
        guard isStarted, let app = apps[pid], app.observer === observer else { return } // stale observer
        switch event {
        case let .scanned(scan):
            apply(scan, pid: pid, isHidden: app.isHidden)
        case let .windowUpdated(window):
            upsert(window, isHidden: app.isHidden)
        case let .windowRemoved(windowID):
            removeWindow(windowID)
        case let .focused(windowID):
            if pid == frontmostPID { recordFocus(windowID, pid: pid) }
        }
    }

    private func apply(_ scan: Tracking.AppScan, pid: pid_t, isHidden: Bool) {
        let scannedIDs = Set(scan.windows.map(\.info.id))
        if scan.isComplete {
            for windowID in (windowIDsByPID[pid] ?? []).subtracting(scannedIDs).subtracting(scan.unknownIDs) {
                removeWindow(windowID)
            }
            // Forget focus records of this app's surfaces that turned out not to be switchable (panels, sheets…)
            // or that vanished — unless recorded after this scan started (a window newer than its snapshot).
            for (windowID, owner) in historyOwners where owner.pid == pid && !scannedIDs.contains(windowID)
                && !scan.unknownIDs.contains(windowID) && owner.recordedAt < scan.startedAt {
                focusHistory.remove(windowID)
                historyOwners[windowID] = nil
            }
        } else {
            for windowID in scan.deadIDs {
                removeWindow(windowID)
            }
        }
        for (windowID, position) in scan.zPositions {
            zIndex[windowID] = position
        }
        for window in scan.windows {
            upsert(window, isHidden: isHidden)
        }
        if let focused = scan.focusedWindowID, pid == frontmostPID, scannedIDs.contains(focused),
           lastRecordedFocus != focused {
            recordFocus(focused, pid: pid)
        }
        scheduleChange()
    }

    private func upsert(_ window: Tracking.ScannedWindow, isHidden: Bool) {
        var info = window.info
        info.isAppHidden = isHidden
        let windowID = info.id
        if windowsByID[windowID] != info {
            windowsByID[windowID] = info
            scheduleChange()
        }
        elementsByID[windowID] = window.element
        windowIDsByPID[info.pid, default: []].insert(windowID)
    }

    private func removeWindow(_ windowID: CGWindowID) {
        let info = windowsByID.removeValue(forKey: windowID)
        elementsByID[windowID] = nil
        if let pid = info?.pid ?? historyOwners[windowID]?.pid {
            windowIDsByPID[pid]?.remove(windowID)
        }
        focusHistory.remove(windowID)
        historyOwners[windowID] = nil
        if lastRecordedFocus == windowID { lastRecordedFocus = nil }
        scheduleChange()
    }

    private func recordFocus(_ windowID: CGWindowID, pid: pid_t) {
        focusHistory.recordFocus(windowID)
        historyOwners[windowID] = HistoryOwner(pid: pid, recordedAt: DispatchTime.now().uptimeNanoseconds)
        lastRecordedFocus = windowID
        scheduleChange()
    }

    // MARK: Change coalescing

    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushChange() }
        }
    }

    private func flushChange() {
        changeScheduled = false
        windows = Tracking.ZOrder.mruOrdered(Array(windowsByID.values), history: focusHistory, zIndex: zIndex)
        onChange?()
    }
}
