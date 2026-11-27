// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Accessibility reads for window tracking. Every function here may block for up to the AX messaging
// timeout, so they are called only from background queues (one serial queue per app, see `AppObserver`)
// — never from the main thread.

import ApplicationServices
import CoreGraphics
import Foundation
import VitrinCore
import VitrinPrivate

extension Tracking {
    /// AX messaging timeout for every element Vitrin talks to (the system default is 6 s).
    static let axMessagingTimeout: Float = 0.5

    /// `kAXFullScreenAttribute` is not exported by the SDK headers.
    static let fullScreenAttribute = "AXFullScreen"

    /// Outcome of an AX read: a value, or why there is none.
    enum AXRead<Value> {
        case value(Value)
        /// The element is gone (`.invalidUIElement`).
        case dead
        /// The app did not answer within the messaging timeout (`.cannotComplete`): unknown, retry later.
        case unresponsive
        /// Any other error (permission missing, attribute unsupported, …).
        case failed(AXError)
    }

    enum AXReader {
        private static let windowAttributeNames: [String] = [
            kAXRoleAttribute as String,
            kAXSubroleAttribute as String,
            kAXTitleAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
            kAXMinimizedAttribute as String,
            fullScreenAttribute,
            kAXMainAttribute as String,
            kAXMinimizeButtonAttribute as String,
        ]

        static func classify(_ error: AXError) -> AXRead<Never>? {
            switch error {
            case .success: return nil
            case .invalidUIElement: return .dead
            case .cannotComplete: return .unresponsive
            default: return .failed(error)
            }
        }

        /// Reads every window attribute in one IPC round-trip.
        static func windowAttributes(_ element: AXUIElement) -> AXRead<AXWindowAttributes> {
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, windowAttributeNames as CFArray, [], &values)
            if let failure = classify(error) { return failure.cast() }
            let array = values as? [AnyObject] ?? []
            func value(_ index: Int) -> AnyObject? { index < array.count ? sanitize(array[index]) : nil }
            var attributes = AXWindowAttributes()
            attributes.role = value(0) as? String
            attributes.subrole = value(1) as? String
            attributes.title = value(2) as? String
            attributes.position = value(3).flatMap { pointValue($0) }
            attributes.size = value(4).flatMap { sizeValue($0) }
            attributes.isMinimized = (value(5) as? NSNumber)?.boolValue
            attributes.isFullscreen = (value(6) as? NSNumber)?.boolValue
            attributes.isMain = (value(7) as? NSNumber)?.boolValue
            if attributes.subrole == (kAXStandardWindowSubrole as String), attributes.isMinimized != true,
               attributes.isFullscreen != true {
                attributes.canMinimize = value(8).flatMap(asElement).map(isEnabled) ?? false
            }
            // Every attribute failing usually means the element died between listing and reading.
            if attributes.role == nil && attributes.subrole == nil && attributes.size == nil {
                var probe: CFTypeRef?
                let probeError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &probe)
                if let failure = classify(probeError) { return failure.cast() }
            }
            return .value(attributes)
        }

        /// The app's window list (`kAXWindows`, current Space only) plus its focused and main window, which
        /// are not Space-filtered — one round-trip (AltTab's `windowsIncludingKeyAndMain`).
        static func appWindows(_ app: AXUIElement) -> AXRead<(windows: [AXUIElement], focused: AXUIElement?)> {
            let names = [kAXWindowsAttribute as String, kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String]
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(app, names as CFArray, [], &values)
            if let failure = classify(error) { return failure.cast() }
            let array = values as? [AnyObject] ?? []
            func value(_ index: Int) -> AnyObject? { index < array.count ? sanitize(array[index]) : nil }
            var windows = (value(0) as? [AXUIElement]) ?? []
            let focused = value(1).flatMap(asElement)
            let main = value(2).flatMap(asElement)
            for extra in [focused, main].compactMap({ $0 }) where !windows.contains(where: { CFEqual($0, extra) }) {
                windows.append(extra)
            }
            return .value((windows, focused))
        }

        /// `kAXEnabled` of a button (one more round-trip); unknown counts as disabled.
        private static func isEnabled(_ button: AXUIElement) -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &value) == .success else { return false }
            return (value as? NSNumber)?.boolValue ?? false
        }

        static func focusedWindow(_ app: AXUIElement) -> AXRead<AXUIElement?> {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            if error == .noValue { return .value(nil) }
            if let failure = classify(error) { return failure.cast() }
            return .value(value.flatMap { asElement($0 as AnyObject) })
        }

        static func windowID(_ element: AXUIElement) -> CGWindowID? {
            AXPrivate.windowID(of: element)
        }

        // MARK: Value helpers

        /// `AXUIElementCopyMultipleAttributeValues` without `.stopOnError` puts an `AXValue` of type `.axError`
        /// in place of every attribute it could not read; map those to `nil` (AltTab `castSafely`).
        private static func sanitize(_ value: AnyObject) -> AnyObject? {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }

        private static func asElement(_ value: AnyObject) -> AXUIElement? {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        /// A failed `AXValueGetValue` leaves the out-param untouched: that is "unknown", not zero.
        private static func pointValue(_ value: AnyObject) -> CGPoint? {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
        }

        private static func sizeValue(_ value: AnyObject) -> CGSize? {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
        }
    }
}

extension Tracking.AXRead where Value == Never {
    func cast<T>() -> Tracking.AXRead<T> {
        switch self {
        case .dead: return .dead
        case .unresponsive: return .unresponsive
        case let .failed(error): return .failed(error)
        }
    }
}

// MARK: - WindowServer snapshot

extension Tracking {
    /// A shared, briefly cached `CGWindowListCopyWindowInfo(.optionAll)` so N per-app scans triggered together
    /// (e.g. on a Space change) cost one WindowServer query. Thread-safe.
    final class WindowServerSnapshot: @unchecked Sendable {
        static let shared = WindowServerSnapshot()

        private let lock = NSLock()
        private var cached: (time: UInt64, records: [WindowServerRecord])?
        private let maxAgeNanoseconds: UInt64 = 100_000_000

        /// Every window (all Spaces, minimized, hidden), front to back.
        func records() -> [WindowServerRecord] {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if let cached, now &- cached.time < maxAgeNanoseconds {
                lock.unlock()
                return cached.records
            }
            lock.unlock()
            let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let records = WindowServerRecord.parse(list)
            lock.lock()
            cached = (now, records)
            lock.unlock()
            return records
        }

        func invalidate() {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }
}

// MARK: - Window construction

extension Tracking {
    /// A tracked window as produced on an app queue: the model value plus its AX element.
    struct ScannedWindow {
        var info: WindowInfo
        var element: AXUIElement
    }

    /// Identity of the owning app, captured once on the main actor.
    struct AppIdentity: Sendable, Equatable {
        var pid: pid_t
        var bundleIdentifier: String?
        var name: String
    }

    enum WindowBuilder {
        /// Builds the model value. `isAppHidden` and `lastFocusSequence` are filled in on the main actor.
        static func make(windowID: CGWindowID, attributes: AXWindowAttributes, record: WindowServerRecord?,
                         app: AppIdentity, displays: [DisplayInfo]) -> WindowInfo {
            let frame = attributes.frame ?? record?.bounds ?? .zero
            let title = (attributes.title?.isEmpty == false ? attributes.title : record?.title) ?? ""
            let spaces = SkyLight.spaces(forWindow: windowID) ?? []
            return WindowInfo(
                id: windowID,
                pid: app.pid,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                title: title,
                frame: frame,
                isMinimized: attributes.isMinimized ?? false,
                isFullscreen: attributes.isFullscreen ?? false,
                isStandardWindow: Eligibility.isStandardWindow(attributes),
                spaceIDs: spaces,
                displayID: Geometry.displayID(for: frame, displays: displays)
            )
        }
    }
}
