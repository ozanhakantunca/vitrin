// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Private HIServices accessibility helpers. All calls that query another process require the
// Accessibility (TCC) permission; without it they return nil / empty.

import ApplicationServices
import Foundation
import VitrinPrivateC

public enum AXPrivate {
    /// The `CGWindowID` behind an AX window element (`_AXUIElementGetWindow`).
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = PrivateAPI.function(.axUIElementGetWindow, as: VPAXUIElementGetWindowFn.self) else { return nil }
        var windowID: CGWindowID = 0
        guard fn(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    /// The 20-byte token `_AXUIElementCreateWithRemoteToken` expects (layout documented in VitrinPrivateC.h):
    /// `pid (Int32) | 0 (Int32) | 0x636f636f (UInt32) | elementID (UInt64)`, little-endian.
    public static func remoteToken(pid: pid_t, elementID: UInt64) -> Data {
        var token = Data(capacity: Int(VPAXRemoteTokenSize))
        withUnsafeBytes(of: pid.littleEndian) { token.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0).littleEndian) { token.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(VPAXRemoteTokenMagic).littleEndian) { token.append(contentsOf: $0) }
        withUnsafeBytes(of: elementID.littleEndian) { token.append(contentsOf: $0) }
        return token
    }

    /// Recreates the AX element `elementID` of process `pid`. Returns an element even for ids that don't
    /// exist; validate it (e.g. read its subrole) before use.
    public static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let fn = PrivateAPI.function(.axUIElementCreateWithRemoteToken, as: VPAXUIElementCreateWithRemoteTokenFn.self) else { return nil }
        return fn(remoteToken(pid: pid, elementID: elementID) as CFData)?.takeRetainedValue()
    }

    /// Window elements of `pid` found by brute-forcing element ids — the only way to reach windows on
    /// other Spaces, which `kAXWindowsAttribute` omits. Each probe is an IPC round-trip to the target app,
    /// so call this off the main thread and keep `elementIDs` small (AltTab uses 0..<1000).
    ///
    /// `budget` caps the wall-clock time (an unresponsive app would otherwise cost one messaging timeout per id),
    /// and the scan stops early once the app answers `.cannotComplete` twice in a row.
    public static func windowElementsByBruteForce(
        pid: pid_t,
        elementIDs: Range<UInt64> = 0..<1000,
        subroles: Set<String> = [kAXStandardWindowSubrole as String, kAXDialogSubrole as String],
        budget: TimeInterval = 0.5
    ) -> [AXUIElement] {
        guard PrivateAPI.isAvailable(.axUIElementCreateWithRemoteToken) else { return [] }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, budget) * 1e9)
        var windows: [AXUIElement] = []
        var timeouts = 0
        for elementID in elementIDs {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            guard let element = element(pid: pid, elementID: elementID) else { continue }
            var subrole: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if error == .cannotComplete {
                timeouts += 1
                if timeouts >= 2 { break }
                continue
            }
            timeouts = 0
            guard error == .success, let value = subrole as? String, subroles.contains(value) else { continue }
            windows.append(element)
        }
        return windows
    }

    /// Result of `windowElements(pid:windowIDs:...)`.
    public struct BruteForceResult {
        /// The `AXWindow` root element found for each requested window id.
        public var elements: [CGWindowID: AXUIElement]
        /// The element id the sweep stopped at; pass it back as `startingAt` to resume instead of re-walking
        /// the same dead prefix (long-lived apps keep their windows at high, sparse ids).
        public var nextElementID: UInt64
        /// The app stopped answering (`.cannotComplete`); the sweep was abandoned.
        public var appUnresponsive: Bool

        public init(elements: [CGWindowID: AXUIElement] = [:], nextElementID: UInt64 = 0, appUnresponsive: Bool = false) {
            self.elements = elements
            self.nextElementID = nextElementID
            self.appUnresponsive = appUnresponsive
        }
    }

    /// Finds the AX window elements of specific `windowIDs` of `pid` by brute-forcing element ids, within a
    /// wall-clock `budget`. Used for windows on other Spaces, which `kAXWindowsAttribute` omits. Off-main only.
    ///
    /// `_AXUIElementGetWindow` on a *descendant* reports its containing window's id too, so a match is only
    /// accepted for the element whose role is `AXWindow` (the root). One sweep resolves every requested id.
    /// Adapted from AltTab's `AXUIElement.windowsByBruteForce` / `BruteForceWindowMatch`
    /// (github.com/lwouis/alt-tab-macos, GPL-3.0, © lwouis and contributors).
    public static func windowElements(
        pid: pid_t,
        windowIDs: Set<CGWindowID>,
        startingAt firstElementID: UInt64 = 0,
        budget: TimeInterval = 0.25
    ) -> BruteForceResult {
        guard !windowIDs.isEmpty, PrivateAPI.isAvailable(.axUIElementCreateWithRemoteToken),
              PrivateAPI.isAvailable(.axUIElementGetWindow) else {
            return BruteForceResult(nextElementID: firstElementID)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, budget) * 1e9)
        var remaining = windowIDs
        var result = BruteForceResult(nextElementID: firstElementID)
        var elementID = firstElementID
        var timeouts = 0
        while !remaining.isEmpty, DispatchTime.now().uptimeNanoseconds < deadline {
            defer { elementID &+= 1 }
            guard let candidate = element(pid: pid, elementID: elementID) else { continue }
            guard let getWindow = PrivateAPI.function(.axUIElementGetWindow, as: VPAXUIElementGetWindowFn.self) else { break }
            var windowID: CGWindowID = 0
            let error = getWindow(candidate, &windowID)
            if error == .cannotComplete {
                timeouts += 1
                if timeouts >= 2 { result.appUnresponsive = true; break }
                continue
            }
            timeouts = 0
            guard error == .success, remaining.contains(windowID) else { continue }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == (kAXWindowRole as String) else { continue }
            result.elements[windowID] = candidate
            remaining.remove(windowID)
        }
        result.nextElementID = remaining.isEmpty ? 0 : elementID
        return result
    }
}
