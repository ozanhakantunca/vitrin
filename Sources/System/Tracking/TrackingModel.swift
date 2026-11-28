// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Pure, side-effect-free pieces of window tracking: which apps and windows are switch destinations,
// CGWindowList parsing and z-order seeding, display geometry and `SwitcherContext` computation.
// Everything here works on plain values so it can be unit-tested without Accessibility or a WindowServer.

import AppKit
import ApplicationServices
import CoreGraphics
import VitrinCore

/// Namespace for window-tracking internals (keeps names clear of the other `VitrinSystem` lanes).
enum Tracking {}

// MARK: - WindowServer records

extension Tracking {
    /// One row of `CGWindowListCopyWindowInfo`.
    struct WindowServerRecord: Sendable, Equatable {
        var id: CGWindowID
        var pid: pid_t
        /// `kCGWindowLayer`; 0 is the normal window level.
        var layer: Int
        /// Global, top-left-origin coordinates.
        var bounds: CGRect
        var alpha: Double
        var isOnScreen: Bool
        /// Only present with the Screen Recording permission.
        var title: String?

        init(id: CGWindowID, pid: pid_t, layer: Int = 0, bounds: CGRect = .zero, alpha: Double = 1,
             isOnScreen: Bool = true, title: String? = nil) {
            self.id = id
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
            self.alpha = alpha
            self.isOnScreen = isOnScreen
            self.title = title
        }

        /// Parses one CGWindowList dictionary; `nil` if it lacks an id or owner pid.
        init?(_ dictionary: [String: Any]) {
            guard let id = (dictionary[kCGWindowNumber as String] as? NSNumber)?.uint32Value, id != 0,
                  let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            var bounds = CGRect.zero
            if let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
            }
            self.init(
                id: id,
                pid: pid,
                layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                title: (dictionary[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        /// Parses a whole CGWindowList result, preserving its front-to-back order.
        static func parse(_ list: [[String: Any]]) -> [WindowServerRecord] {
            list.compactMap(WindowServerRecord.init)
        }
    }
}

// MARK: - Eligibility

extension Tracking {
    /// Accessibility facts about one window element (from one batched AX read). `nil` = not answered.
    struct AXWindowAttributes: Sendable, Equatable {
        var role: String?
        var subrole: String?
        var title: String?
        var position: CGPoint?
        var size: CGSize?
        var isMinimized: Bool?
        var isFullscreen: Bool?
        var isMain: Bool?
        /// The window has an enabled minimize button. Only read for standard windows that are neither minimized
        /// nor fullscreen: panels (open/save), About and settings windows usually can't be minimized.
        var canMinimize: Bool?

        init(role: String? = nil, subrole: String? = nil, title: String? = nil, position: CGPoint? = nil,
             size: CGSize? = nil, isMinimized: Bool? = nil, isFullscreen: Bool? = nil, isMain: Bool? = nil,
             canMinimize: Bool? = nil) {
            self.role = role
            self.subrole = subrole
            self.title = title
            self.position = position
            self.size = size
            self.isMinimized = isMinimized
            self.isFullscreen = isFullscreen
            self.isMain = isMain
            self.canMinimize = canMinimize
        }

        var frame: CGRect? {
            guard let position, let size else { return nil }
            return CGRect(origin: position, size: size)
        }
    }

    /// Which processes and windows are switch destinations.
    ///
    /// The window rules are adapted from AltTab's `isActualWindow` (pre-2025) and `WindowAdmissionResolver`
    /// (github.com/lwouis/alt-tab-macos, GPL-3.0, © lwouis and contributors):
    /// - role `AXWindow`, subrole `AXStandardWindow` or `AXDialog` (minimized windows and windows of hidden apps
    ///   briefly report `AXDialog`), or a custom window root that is the app's main window / titled and substantial;
    /// - floating panels and system dialogs are auxiliary, except for apps whose real windows float
    ///   (Books, Keynote's presenter window, IINA);
    /// - only the normal window level (0), unless the window is fullscreen or the app's main window;
    /// - not tiny: at least 100 pt in one dimension (AltTab's threshold).
    enum Eligibility {
        static let minimumSide: CGFloat = 100
        static let normalLevel = 0

        /// Apps whose genuine windows are `AXFloatingWindow`s or sit above the normal level.
        static let floatingWindowApps: Set<String> = [
            "com.apple.iBooksX",
            "com.apple.iWork.Keynote",
            "com.colliderli.iina",
        ]

        /// Whether to observe the process at all. Regular apps always; accessory (UIElement) apps too, since
        /// some own real windows — their helper surfaces are filtered out by `isSwitchable`.
        static func shouldTrack(pid: pid_t, ownPID: pid_t, activationPolicy: NSApplication.ActivationPolicy,
                                isTerminated: Bool) -> Bool {
            guard pid > 0, pid != ownPID, !isTerminated else { return false }
            switch activationPolicy {
            case .regular, .accessory: return true
            case .prohibited: return false
            @unknown default: return false
            }
        }

        /// A regular window of the app, for "quit when the last window closes": standard subrole and minimizable.
        /// Panels, dialogs and windows such as About or Settings don't qualify. Minimized and fullscreen windows
        /// aren't checked here (`LastWindowQuitPolicy` counts them anyway).
        static func isStandardWindow(_ attributes: AXWindowAttributes) -> Bool {
            attributes.subrole == (kAXStandardWindowSubrole as String) && attributes.canMinimize != false
        }

        /// Whether the window behind `attributes` (and its WindowServer row, if known) is a switch destination.
        static func isSwitchable(windowID: CGWindowID?, attributes: AXWindowAttributes,
                                 record: WindowServerRecord?, bundleIdentifier: String?) -> Bool {
            guard let windowID, windowID != 0 else { return false }
            guard attributes.role == (kAXWindowRole as String) else { return false }
            let floatsByDesign = bundleIdentifier.map(floatingWindowApps.contains) ?? false
            let subrole = attributes.subrole
            let isAuxiliary = subrole == (kAXFloatingWindowSubrole as String) || subrole == "AXSystemDialog"
            if isAuxiliary && !floatsByDesign { return false }

            let size = attributes.size ?? record?.bounds.size
            guard let size, size.width >= minimumSide || size.height >= minimumSide else { return false }

            let isFullscreen = attributes.isFullscreen == true
            let isMain = attributes.isMain == true
            if let level = record?.layer, !floatsByDesign {
                // Below normal is the desktop's layer (wallpaper, replacement desktops): never a destination.
                guard level >= normalLevel else { return false }
                guard level == normalLevel || isFullscreen || isMain else { return false }
            }

            if subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String) { return true }
            if floatsByDesign && isAuxiliary { return true }
            if isMain { return true }
            let hasTitle = !(attributes.title ?? "").isEmpty
            return hasTitle && size.width >= minimumSide && size.height >= minimumSide / 2
        }
    }
}

// MARK: - Z-order seeding

extension Tracking {
    enum ZOrder {
        /// Front-to-back ids of normal-level, visible windows owned by `pids`: the seed for `FocusHistory` at
        /// launch, so MRU order is sensible before any focus event was observed.
        static func seed(_ records: [WindowServerRecord], pids: Set<pid_t>) -> [CGWindowID] {
            var seen = Set<CGWindowID>()
            return records.compactMap { record in
                guard record.isOnScreen, record.layer == Eligibility.normalLevel, record.alpha > 0,
                      pids.contains(record.pid), seen.insert(record.id).inserted else { return nil }
                return record.id
            }
        }

        /// Position of every window in a front-to-back list (used to order never-focused windows).
        static func indices(_ records: [WindowServerRecord]) -> [CGWindowID: Int] {
            var result: [CGWindowID: Int] = [:]
            for (index, record) in records.enumerated() where result[record.id] == nil {
                result[record.id] = index
            }
            return result
        }

        /// MRU order: stamped windows by focus sequence, then never-focused ones by z-index (unknown last), then id.
        static func mruOrdered(_ windows: [WindowInfo], history: FocusHistory, zIndex: [CGWindowID: Int]) -> [WindowInfo] {
            let byZ = windows.sorted { lhs, rhs in
                let l = zIndex[lhs.id] ?? Int.max, r = zIndex[rhs.id] ?? Int.max
                return l != r ? l < r : lhs.id < rhs.id
            }
            return history.ordered(byZ)
        }
    }
}

// MARK: - Displays & context

extension Tracking {
    struct DisplayInfo: Sendable, Equatable {
        var id: CGDirectDisplayID
        /// Global, top-left-origin coordinates (`CGDisplayBounds`).
        var bounds: CGRect
        /// SkyLight display UUID (`nil` if unknown).
        var uuid: String?

        init(id: CGDirectDisplayID, bounds: CGRect, uuid: String? = nil) {
            self.id = id
            self.bounds = bounds
            self.uuid = uuid
        }

        /// The active displays (thread-safe CoreGraphics calls).
        static func active() -> [DisplayInfo] {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
            return ids.prefix(Int(count)).map { id in
                let uuid = CGDisplayCreateUUIDFromDisplayID(id).flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
                return DisplayInfo(id: id, bounds: CGDisplayBounds(id), uuid: uuid)
            }
        }
    }

    enum Geometry {
        /// The display holding the largest part of `frame`; if it overlaps none, the display nearest its center.
        static func displayID(for frame: CGRect, displays: [DisplayInfo]) -> CGDirectDisplayID? {
            guard !displays.isEmpty, !frame.isNull, !frame.isInfinite else { return nil }
            var best: (id: CGDirectDisplayID, area: CGFloat)?
            for display in displays {
                let overlap = display.bounds.intersection(frame)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                if area > 0, area > (best?.area ?? 0) { best = (display.id, area) }
            }
            if let best { return best.id }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let containing = displayID(containing: center, displays: displays) { return containing }
            return displays.min { distance(center, $0.bounds) < distance(center, $1.bounds) }?.id
        }

        /// The display containing `point` (global, top-left origin).
        static func displayID(containing point: CGPoint, displays: [DisplayInfo]) -> CGDirectDisplayID? {
            displays.first { $0.bounds.contains(point) }?.id
        }

        static func displayID(forUUID uuid: String?, displays: [DisplayInfo]) -> CGDirectDisplayID? {
            guard let uuid else { return nil }
            return displays.first { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }?.id
        }

        private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
    }

    enum Context {
        /// Builds the filtering context from plain values.
        ///
        /// - `activeDisplayID`: the display of the frontmost app's most recently focused window, falling back to
        ///   the display whose menu bar is active.
        /// - `mouseDisplayID`: the display under `mouseLocation` (global, top-left origin).
        static func make(
            frontmostPID: pid_t?,
            currentSpaceIDs: Set<SpaceID>,
            mruWindows: [WindowInfo],
            activeMenuBarDisplayUUID: String?,
            mouseLocation: CGPoint?,
            displays: [DisplayInfo]
        ) -> SwitcherContext {
            let frontWindow = frontmostPID.flatMap { pid in mruWindows.first { $0.pid == pid && !$0.isMinimized } }
            let activeDisplay = frontWindow?.displayID
                ?? Geometry.displayID(forUUID: activeMenuBarDisplayUUID, displays: displays)
            let mouseDisplay = mouseLocation.flatMap { Geometry.displayID(containing: $0, displays: displays) }
            return SwitcherContext(
                activePID: frontmostPID,
                currentSpaceIDs: currentSpaceIDs,
                activeDisplayID: activeDisplay,
                mouseDisplayID: mouseDisplay
            )
        }
    }
}

// MARK: - Diagnostics

extension Tracking {
    enum Dump {
        static func line(index: Int, _ window: WindowInfo) -> String {
            let f = window.frame
            let frame = "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            let spaces = window.spaceIDs.map(String.init).joined(separator: ",")
            return "\(index). wid=\(window.id) pid=\(window.pid) app=\(quoted(window.appName))"
                + " bundle=\(window.bundleIdentifier ?? "-") title=\(quoted(window.title))"
                + " frame=\(frame) minimized=\(window.isMinimized) appHidden=\(window.isAppHidden)"
                + " fullscreen=\(window.isFullscreen) standard=\(window.isStandardWindow) spaces=[\(spaces)]"
                + " display=\(window.displayID.map(String.init) ?? "-")"
                + " seq=\(window.lastFocusSequence.map(String.init) ?? "-")"
        }

        static func context(_ context: SwitcherContext) -> String {
            let spaces = context.currentSpaceIDs.sorted().map(String.init).joined(separator: ",")
            return "context: activePID=\(context.activePID.map(String.init) ?? "-") currentSpaces=[\(spaces)]"
                + " activeDisplay=\(context.activeDisplayID.map(String.init) ?? "-")"
                + " mouseDisplay=\(context.mouseDisplayID.map(String.init) ?? "-")"
        }

        static func text(header: [String], context: SwitcherContext, mruWindows: [WindowInfo]) -> String {
            var lines = header
            lines.append(Dump.context(context))
            lines.append("windows (\(mruWindows.count), MRU order):")
            for (index, window) in mruWindows.enumerated() {
                lines.append(line(index: index, window))
            }
            return lines.joined(separator: "\n")
        }

        private static func quoted(_ string: String) -> String {
            "\"" + string.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
        }
    }
}
