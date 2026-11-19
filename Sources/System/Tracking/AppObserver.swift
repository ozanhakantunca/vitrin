// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// One `AppObserver` per tracked process. It owns a serial background queue on which *every* AX call for
// that app happens, so an unresponsive app only ever stalls its own queue (bounded by the messaging
// timeout) — never the main thread, never other apps. Results are handed to the `WindowTracker` on the
// main actor through `sink`.
//
// The AXObserver's run-loop source is attached to the main run loop, but its callback does no IPC: it only
// hops the (element, notification) pair onto the app's queue.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VitrinCore
import VitrinPrivate

extension Tracking {
    /// Result of a full scan of one app.
    struct AppScan {
        var windows: [ScannedWindow]
        /// Every window id WindowServer lists for the pid (eligible or not), for pruning focus history.
        var windowServerIDs: Set<CGWindowID>
        /// Window ids whose AX element is known to be gone.
        var deadIDs: Set<CGWindowID>
        /// Previously known windows whose read failed this time (not an answer): keep their last state.
        var unknownIDs: Set<CGWindowID> = []
        /// Front-to-back positions of this app's windows in the snapshot the scan used.
        var zPositions: [CGWindowID: Int]
        /// `false` when the app stopped answering part-way: windows not reported keep their previous state.
        var isComplete: Bool
        /// The app's focused window at scan time.
        var focusedWindowID: CGWindowID?
        /// `DispatchTime` (uptime ns) when the scan started.
        var startedAt: UInt64
    }

    /// The scanning state of one app (cached other-Space elements, brute-force bookkeeping). Not thread-safe:
    /// owned by one queue (an `AppObserver`'s, or the caller of a one-shot dump).
    final class AppScanner {
        let identity: AppIdentity
        let app: AXUIElement
        /// Last known element of every switchable window (including ones only brute force can reach).
        private(set) var elements: [CGWindowID: AXUIElement] = [:]
        private var bruteForceAttempts: [CGWindowID: Int] = [:]
        private var bruteForceCursor: UInt64 = 0

        static let maxBruteForceAttempts = 3
        static let bruteForceBudget: TimeInterval = 0.25

        init(identity: AppIdentity) {
            self.identity = identity
            app = AXUIElementCreateApplication(identity.pid)
            AXUIElementSetMessagingTimeout(app, Tracking.axMessagingTimeout)
        }

        func resetBruteForce() {
            bruteForceAttempts.removeAll()
            bruteForceCursor = 0
        }

        func forget(_ windowID: CGWindowID) {
            elements[windowID] = nil
        }

        func remember(_ windowID: CGWindowID, _ element: AXUIElement) {
            elements[windowID] = element
        }

        /// The cached window id of `element`, else its live `_AXUIElementGetWindow`.
        func windowID(of element: AXUIElement) -> CGWindowID? {
            if let cached = elements.first(where: { CFEqual($0.value, element) })?.key { return cached }
            return AXReader.windowID(element)
        }

        /// Full scan: `kAXWindows` + focused/main + cached elements, then brute force for windows WindowServer
        /// lists but AX doesn't (other Spaces), then one batched attribute read per window.
        func scan(bruteForce: Bool) -> AppScan {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let snapshot = WindowServerSnapshot.shared.records()
            var mine: [WindowServerRecord] = []
            var zPositions: [CGWindowID: Int] = [:]
            for (index, record) in snapshot.enumerated() where record.pid == identity.pid {
                mine.append(record)
                if zPositions[record.id] == nil { zPositions[record.id] = index }
            }
            let recordByID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let displays = DisplayInfo.active()
            var scan = AppScan(windows: [], windowServerIDs: Set(recordByID.keys), deadIDs: [], zPositions: zPositions,
                               isComplete: true, focusedWindowID: nil, startedAt: startedAt)

            var candidates: [CGWindowID: AXUIElement] = [:]
            switch AXReader.appWindows(app) {
            case let .value((windows, focused)):
                for element in windows {
                    guard let windowID = AXReader.windowID(element), candidates[windowID] == nil else { continue }
                    candidates[windowID] = element
                }
                scan.focusedWindowID = focused.flatMap(AXReader.windowID)
            case .unresponsive:
                scan.isComplete = false
                return scan
            case .dead, .failed:
                break // no AX windows (app quitting, not AX-enabled, or permission missing)
            }
            for (windowID, element) in elements where candidates[windowID] == nil {
                candidates[windowID] = element
            }

            // Windows on other Spaces: AX omits them from kAXWindows; reach them by element-id brute force.
            let attempted = Set(bruteForceAttempts.keys)
            bruteForceAttempts = bruteForceAttempts.filter { recordByID[$0.key] != nil }
            let missing = mine.filter { record in
                record.layer == Eligibility.normalLevel && candidates[record.id] == nil
                    && (record.bounds.width >= Eligibility.minimumSide || record.bounds.height >= Eligibility.minimumSide)
                    && (bruteForceAttempts[record.id] ?? 0) < Self.maxBruteForceAttempts
            }.map(\.id)
            let hasNewMissing = missing.contains { !attempted.contains($0) }
            if !missing.isEmpty && (bruteForce || hasNewMissing) {
                let start = hasNewMissing ? 0 : bruteForceCursor
                let result = AXPrivate.windowElements(pid: identity.pid, windowIDs: Set(missing), startingAt: start,
                                                      budget: Self.bruteForceBudget)
                bruteForceCursor = result.nextElementID
                for windowID in missing {
                    if let element = result.elements[windowID] {
                        candidates[windowID] = element
                        bruteForceAttempts[windowID] = nil
                    } else {
                        bruteForceAttempts[windowID, default: 0] += 1
                    }
                }
                if result.appUnresponsive {
                    scan.isComplete = false
                }
            }

            var kept: [CGWindowID: AXUIElement] = [:]
            var hung = false
            let ordered = candidates.sorted { (zPositions[$0.key] ?? Int.max, $0.key) < (zPositions[$1.key] ?? Int.max, $1.key) }
            for (index, (windowID, element)) in ordered.enumerated() {
                switch AXReader.windowAttributes(element) {
                case let .value(attributes):
                    let record = recordByID[windowID]
                    guard Eligibility.isSwitchable(windowID: windowID, attributes: attributes, record: record,
                                                   bundleIdentifier: identity.bundleIdentifier) else { continue }
                    let info = WindowBuilder.make(windowID: windowID, attributes: attributes, record: record,
                                                  app: identity, displays: displays)
                    scan.windows.append(ScannedWindow(info: info, element: element))
                    kept[windowID] = element
                case .dead:
                    scan.deadIDs.insert(windowID)
                case .unresponsive:
                    // The app is hung: stop paying a timeout per window; keep what we knew.
                    scan.isComplete = false
                    hung = true
                    for (rest, restElement) in ordered[index...] where elements[rest] != nil {
                        kept[rest] = restElement
                    }
                case .failed:
                    // A failed read is not an answer (AltTab `throwIfNotSuccess`): keep what we knew.
                    if elements[windowID] != nil {
                        scan.unknownIDs.insert(windowID)
                        kept[windowID] = element
                    }
                }
                if hung { break }
            }
            elements = kept
            return scan
        }

        /// Re-reads one window. `nil` = unknown (app unresponsive / error); `.some(nil)` = not a switchable window
        /// (closed or no longer eligible).
        func refresh(windowID: CGWindowID, element: AXUIElement) -> ScannedWindow?? {
            switch AXReader.windowAttributes(element) {
            case let .value(attributes):
                let record = WindowServerSnapshot.shared.records().first { $0.id == windowID }
                guard Eligibility.isSwitchable(windowID: windowID, attributes: attributes, record: record,
                                               bundleIdentifier: identity.bundleIdentifier) else {
                    elements[windowID] = nil
                    return .some(nil)
                }
                elements[windowID] = element
                let info = WindowBuilder.make(windowID: windowID, attributes: attributes, record: record,
                                              app: identity, displays: DisplayInfo.active())
                return ScannedWindow(info: info, element: element)
            case .dead:
                elements[windowID] = nil
                return .some(nil)
            case .unresponsive, .failed:
                return nil
            }
        }
    }
}

// MARK: - Observer

extension Tracking {
    final class AppObserver: @unchecked Sendable {
        enum Event {
            case scanned(AppScan)
            case windowUpdated(ScannedWindow)
            case windowRemoved(CGWindowID)
            case focused(CGWindowID)
        }

        typealias Sink = @Sendable (AppObserver, Event) -> Void

        let identity: AppIdentity
        let queue: DispatchQueue
        private let sink: Sink

        // Everything below is touched only on `queue`.
        private let scanner: AppScanner
        private var observer: AXObserver?
        private var runLoopSource: CFRunLoopSource?
        private var retainedSelf: Unmanaged<AppObserver>?
        private var pendingAppNotifications: [String] = AppObserver.appNotifications
        private var subscribedWindows: Set<CGWindowID> = []
        private var registrationAttempts = 0
        private var rescanScheduled = false
        private var rescanWantsBruteForce = false
        private var unresponsiveRetries = 0
        private var pendingRefresh: Set<CGWindowID> = []
        private var invalidated = false

        static let appNotifications: [String] = [
            kAXWindowCreatedNotification as String,
            kAXFocusedWindowChangedNotification as String,
            kAXMainWindowChangedNotification as String,
            kAXApplicationActivatedNotification as String,
            kAXApplicationHiddenNotification as String,
            kAXApplicationShownNotification as String,
        ]

        static let windowNotifications: [String] = [
            kAXUIElementDestroyedNotification as String,
            kAXTitleChangedNotification as String,
            kAXWindowMiniaturizedNotification as String,
            kAXWindowDeminiaturizedNotification as String,
            kAXWindowMovedNotification as String,
            kAXWindowResizedNotification as String,
        ]

        init(identity: AppIdentity, sink: @escaping Sink) {
            self.identity = identity
            self.sink = sink
            queue = DispatchQueue(label: "io.github.ozanhakantunca.vitrin.ax.\(identity.pid)", qos: .userInitiated)
            scanner = AppScanner(identity: identity)
        }

        // MARK: Requests (any thread)

        /// Subscribes and performs the initial scan (with brute force for other-Space windows).
        func start() {
            queue.async { [self] in
                guard !invalidated else { return }
                registerAppNotifications()
                rescan(bruteForce: true)
            }
        }

        /// Full rescan. `resetBruteForce` also forgets which windows brute force already failed to find.
        func requestRescan(bruteForce: Bool, resetBruteForce: Bool = false, delay: TimeInterval = 0.05) {
            queue.async { [self] in
                guard !invalidated else { return }
                if resetBruteForce { scanner.resetBruteForce() }
                if observer == nil || !pendingAppNotifications.isEmpty { registerAppNotifications() }
                scheduleRescan(bruteForce: bruteForce, delay: delay)
            }
        }

        /// Reads the app's focused window and reports it as `.focused`.
        func requestFocusedWindow() {
            queue.async { [self] in
                guard !invalidated else { return }
                reportFocusedWindow()
            }
        }

        /// Stops observing. Safe from any thread; the object is released once pending work drains.
        func invalidate() {
            queue.async { [self] in
                guard !invalidated else { return }
                invalidated = true
                if let runLoopSource {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                }
                runLoopSource = nil
                observer = nil
                if let retainedSelf {
                    self.retainedSelf = nil
                    // Release on main, after any callback already executing there has returned.
                    DispatchQueue.main.async { retainedSelf.release() }
                }
            }
        }

        /// Called from the AXObserver callback (main thread). No IPC here.
        fileprivate func receive(_ notification: String, _ element: AXUIElement) {
            queue.async { [self] in
                guard !invalidated else { return }
                handle(notification, element)
            }
        }

        // MARK: Queue-only

        private func registerAppNotifications() {
            if observer == nil {
                var created: AXObserver?
                guard AXObserverCreate(identity.pid, appObserverCallback, &created) == .success, let created else {
                    scheduleRegistrationRetry()
                    return
                }
                observer = created
                let source = AXObserverGetRunLoopSource(created)
                runLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                retainedSelf = Unmanaged.passRetained(self)
            }
            guard let observer, let refcon = retainedSelf?.toOpaque() else { return }
            var stillPending: [String] = []
            for notification in pendingAppNotifications {
                let error = AXObserverAddNotification(observer, scanner.app, notification as CFString, refcon)
                switch error {
                case .success, .notificationAlreadyRegistered, .notificationUnsupported, .notImplemented:
                    continue
                default:
                    // .cannotComplete (app still launching / busy), .apiDisabled, …: retry later.
                    stillPending.append(notification)
                }
            }
            pendingAppNotifications = stillPending
            if !stillPending.isEmpty { scheduleRegistrationRetry() } else { registrationAttempts = 0 }
        }

        private func scheduleRegistrationRetry() {
            registrationAttempts += 1
            guard registrationAttempts <= 6 else { return } // 0.25 … 8 s; refreshAll() tries again later
            let delay = 0.25 * pow(2, Double(registrationAttempts - 1))
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard !invalidated, observer == nil || !pendingAppNotifications.isEmpty else { return }
                registerAppNotifications()
                scheduleRescan(bruteForce: false, delay: 0)
            }
        }

        private func subscribe(windowID: CGWindowID, element: AXUIElement) {
            guard let observer, let refcon = retainedSelf?.toOpaque(), !subscribedWindows.contains(windowID) else { return }
            var ok = true
            for notification in Self.windowNotifications {
                let error = AXObserverAddNotification(observer, element, notification as CFString, refcon)
                if error == .cannotComplete { ok = false; break }
            }
            if ok { subscribedWindows.insert(windowID) }
        }

        private func scheduleRescan(bruteForce: Bool, delay: TimeInterval) {
            rescanWantsBruteForce = rescanWantsBruteForce || bruteForce
            guard !rescanScheduled else { return }
            rescanScheduled = true
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard !invalidated else { return }
                rescan(bruteForce: false)
            }
        }

        private func rescan(bruteForce: Bool) {
            let wantsBruteForce = bruteForce || rescanWantsBruteForce
            rescanScheduled = false
            rescanWantsBruteForce = false
            let scan = scanner.scan(bruteForce: wantsBruteForce)
            for window in scan.windows {
                subscribe(windowID: window.info.id, element: window.element)
            }
            subscribedWindows.subtract(scan.deadIDs)
            sink(self, .scanned(scan))
            if scan.isComplete {
                unresponsiveRetries = 0
            } else {
                // Back off while the app is hung: 1, 2, 4 … 30 s.
                unresponsiveRetries += 1
                let delay = min(30, pow(2, Double(unresponsiveRetries - 1)))
                scheduleRescan(bruteForce: wantsBruteForce, delay: delay)
            }
        }

        private func reportFocusedWindow() {
            switch AXReader.focusedWindow(scanner.app) {
            case let .value(element?):
                guard let windowID = scanner.windowID(of: element) else { return }
                sink(self, .focused(windowID))
                if scanner.elements[windowID] == nil { scheduleRescan(bruteForce: false, delay: 0.05) }
            default:
                break
            }
        }

        private func handle(_ notification: String, _ element: AXUIElement) {
            switch notification {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                guard let windowID = scanner.windowID(of: element) else { return }
                sink(self, .focused(windowID))
                if scanner.elements[windowID] == nil { scheduleRescan(bruteForce: false, delay: 0.05) }
            case kAXApplicationActivatedNotification:
                reportFocusedWindow()
            case kAXUIElementDestroyedNotification:
                // The element is dead: match it by identity (CFEqual is local), not by asking the app.
                if let windowID = scanner.elements.first(where: { CFEqual($0.value, element) })?.key {
                    scanner.forget(windowID)
                    subscribedWindows.remove(windowID)
                    pendingRefresh.remove(windowID)
                    sink(self, .windowRemoved(windowID))
                } else {
                    scheduleRescan(bruteForce: false, delay: 0.1)
                }
            case kAXWindowCreatedNotification,
                 kAXApplicationHiddenNotification,
                 kAXApplicationShownNotification:
                scheduleRescan(bruteForce: false, delay: 0.05)
            case kAXWindowMovedNotification, kAXWindowResizedNotification:
                scheduleRefresh(element, delay: 0.1) // coalesce drags
            default: // title changed, (de)miniaturized
                scheduleRefresh(element, delay: 0.02)
            }
        }

        private func scheduleRefresh(_ element: AXUIElement, delay: TimeInterval) {
            guard let windowID = scanner.windowID(of: element) else { return }
            guard pendingRefresh.insert(windowID).inserted else { return }
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard !invalidated, pendingRefresh.remove(windowID) != nil else { return }
                switch scanner.refresh(windowID: windowID, element: element) {
                case let .some(.some(window)):
                    subscribe(windowID: windowID, element: window.element)
                    sink(self, .windowUpdated(window))
                case .some(.none):
                    sink(self, .windowRemoved(windowID))
                case .none:
                    break
                }
            }
        }
    }
}

/// AXObserver callback (main run loop). Must stay IPC-free: it only forwards to the app's queue.
private func appObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                 _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let appObserver = Unmanaged<Tracking.AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    appObserver.receive(notification as String, element)
}
