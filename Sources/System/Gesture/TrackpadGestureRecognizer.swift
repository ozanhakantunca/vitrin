// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Three-finger horizontal trackpad swipe → switcher events, from raw MultitouchSupport contact frames.
// Device handling adapted from AltTab (github.com/lwouis/alt-tab-macos, GPL-3.0, `TrackpadEvents`).
//
// Threading:
// - MultitouchSupport calls `Multitouch.frameCallback` on its own thread (~90–120 Hz while fingers touch).
//   `GestureFrameSink` runs `SwipeStateMachine` right there under an unfair lock; frames that produce no
//   event (nearly all of them) allocate nothing and never touch the main thread.
// - Events are appended to a pending buffer; the first one schedules a single `DispatchQueue.main.async`
//   drain, so a burst of events costs one main-queue hop. `onEvent` is called on the main actor, in order.
//
// System gesture conflict: frames are observed, not intercepted. With macOS's default "swipe between
// full-screen apps with three fingers" both Vitrin and the Dock react. See `SystemTrackpadGestures` and
// `systemThreeFingerSwipeConflicts`: users must move the system gesture to four fingers.

import AppKit
import Foundation
import IOKit
import os
import VitrinPrivate

@MainActor
public final class TrackpadGestureRecognizer {
    /// Called on the main actor for every recognized event.
    public var onEvent: ((GestureEvent) -> Void)?

    public private(set) var isRunning = false
    /// Multitouch devices currently started (0 on a Mac without a trackpad; grows on plug-in).
    public var deviceCount: Int { session?.started.count ?? 0 }
    public let configuration: SwipeStateMachine.Configuration

    /// Whether MultitouchSupport (and the symbols the recognizer needs) exist on this macOS.
    public nonisolated static var isSupported: Bool { Multitouch.isAvailable }

    /// True when a macOS gesture also uses three fingers horizontally (the default "swipe between
    /// full-screen apps", three-finger "swipe between pages", or Three Finger Drag). Re-read on each access.
    public nonisolated static var systemThreeFingerSwipeConflicts: Bool {
        SystemTrackpadGestures.current().conflictsWithThreeFingerSwipe
    }

    /// Delay before re-enumerating devices after wake / plug events (devices need a moment to come up).
    var rescanDelay: TimeInterval = 1.0

    private var session: DeviceSession?
    private var deviceWatcher: MultitouchDeviceWatcher?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var rescanGeneration = 0

    /// Only one recognizer receives frames at a time (the MT callback is process-wide).
    private static weak var active: TrackpadGestureRecognizer?

    public init(configuration: SwipeStateMachine.Configuration = SwipeStateMachine.Configuration()) {
        self.configuration = configuration
    }

    /// Starts every multitouch device and watches for wake / plug-in / unplug. Returns false if
    /// MultitouchSupport is unavailable. Succeeds with zero devices (they are picked up when plugged in).
    /// Starting a second recognizer stops the first.
    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        guard Self.isSupported else { return false }
        if let other = Self.active, other !== self { other.stop() }
        Self.active = self

        GestureFrameSink.shared.activate(configuration: configuration)
        Multitouch.setFrameHandler { GestureFrameSink.shared.process($0) }
        startDevices()
        installObservers()
        isRunning = true
        return true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        rescanGeneration += 1
        removeObservers()
        session = nil // stops the devices
        Multitouch.setFrameHandler(nil)
        GestureFrameSink.shared.deactivate()
        if Self.active === self { Self.active = nil }
    }

    /// Re-enumerates devices now (also triggered automatically on wake and device plug / unplug).
    public func rescanDevices() {
        guard isRunning else { return }
        session = nil
        GestureFrameSink.shared.resetGesture()
        startDevices()
    }

    // MARK: - Private

    private func startDevices() {
        session = DeviceSession()
    }

    private func scheduleRescan() {
        rescanGeneration += 1
        let generation = rescanGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + rescanDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rescanGeneration == generation else { return }
                self.rescanDevices()
            }
        }
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRescan() }
            })
        }
        deviceWatcher = MultitouchDeviceWatcher { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers = []
        deviceWatcher = nil
    }

    /// Main-queue drain of the sink's pending events.
    fileprivate static func drain() {
        let events = GestureFrameSink.shared.takePending()
        guard let recognizer = active, recognizer.isRunning else { return }
        for event in events { recognizer.onEvent?(event) }
    }
}

// MARK: - Device session

/// The devices started by one enumeration. Releasing it stops them (also covers a recognizer deallocated
/// without `stop()`).
private final class DeviceSession {
    let list: Multitouch.DeviceList?
    let started: [Multitouch.Device]

    init() {
        list = Multitouch.DeviceList()
        started = list?.devices.filter { $0.start() } ?? []
    }

    deinit {
        // Unregister + stop before `list` (which owns the devices) is released.
        for device in started { device.stop() }
    }
}

// MARK: - Frame sink (MultitouchSupport thread → main queue)

final class GestureFrameSink: @unchecked Sendable {
    static let shared = GestureFrameSink()

    struct State {
        var machine = SwipeStateMachine()
        var accepting = false
        /// Device whose frames drive the machine; others are ignored until it is idle again.
        var device: UInt = 0
        var pending: [GestureEvent] = []
        var drainScheduled = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func activate(configuration: SwipeStateMachine.Configuration) {
        lock.withLock { state in
            state.machine = SwipeStateMachine(configuration: configuration)
            state.device = 0
            state.pending.removeAll(keepingCapacity: true)
            state.pending.reserveCapacity(16)
            state.accepting = true
        }
    }

    func deactivate() {
        lock.withLock { state in
            state.accepting = false
            state.machine.reset()
            state.device = 0
            state.pending.removeAll(keepingCapacity: true)
        }
    }

    /// Drops the gesture in progress without emitting events (device re-enumeration).
    func resetGesture() {
        lock.withLock { state in
            state.machine.reset()
            state.device = 0
        }
    }

    /// Called on the MultitouchSupport thread for every frame.
    func process(_ summary: Multitouch.FrameSummary) {
        let scheduleDrain = lock.withLock { state -> Bool in
            Self.consume(summary, into: &state)
        }
        if scheduleDrain {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TrackpadGestureRecognizer.drain() }
            }
        }
    }

    /// Runs one frame through the machine. Returns true if the caller must schedule a main-queue drain.
    static func consume(_ summary: Multitouch.FrameSummary, into state: inout State) -> Bool {
        guard state.accepting else { return false }
        if summary.device != state.device {
            guard state.machine.phase == .idle else { return false }
            state.device = summary.device
        }
        let events = state.machine.consume(TouchFrame(
            timestamp: summary.timestamp, fingerCount: summary.fingerCount,
            x: summary.x, y: summary.y, contacts: summary.contacts
        ))
        guard !events.isEmpty else { return false }
        state.pending.append(contentsOf: events)
        guard !state.drainScheduled else { return false }
        state.drainScheduled = true
        return true
    }

    func takePending() -> [GestureEvent] {
        lock.withLock { state in
            let events = state.pending
            state.pending.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            return events
        }
    }
}

// MARK: - IOKit plug / unplug notifications

/// Calls `onChange` (on the main run loop) whenever a multitouch device appears or disappears.
/// The matched class names are those of trackpad / Magic Mouse multitouch drivers; matching a class that
/// does not exist is harmless, so the list is deliberately broad.
private final class MultitouchDeviceWatcher {
    static let serviceClasses = [
        "AppleMultitouchDevice",
        "AppleMultitouchTrackpadHIDEventDriver",
        "AppleMultitouchMouseHIDEventDriver",
    ]

    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            MultitouchDeviceWatcher.drain(iterator)
            guard let refcon else { return }
            Unmanaged<MultitouchDeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        for name in Self.serviceClasses {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                // IOServiceAddMatchingNotification consumes the matching dictionary.
                guard let matching = IOServiceMatching(name),
                      IOServiceAddMatchingNotification(port, type, matching, callback, refcon, &iterator) == KERN_SUCCESS
                else { continue }
                Self.drain(iterator) // arms the notification; existing devices are not changes
                iterators.append(iterator)
            }
        }
    }

    deinit {
        for iterator in iterators { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) } // also removes its run loop source
    }

    private static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}
