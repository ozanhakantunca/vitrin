// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Reliable window focusing. `NSRunningApplication.activate` + AXRaise is not enough: it can focus the
// wrong window of a multi-window app, fails across Spaces, and is suppressed by focus-stealing
// prevention. The sequence below (front process for a specific window, then a synthetic key-window
// event, then AXRaise) is what AltTab, yabai and Hammerspoon use.
//
// The focus-event record layout is adapted from AltTab's WindowFocusEvent.swift / SkyLight.framework.swift
// (github.com/lwouis/alt-tab-macos, GPL-3.0, © lwouis and contributors), which in turn ports
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468.

import ApplicationServices
import Foundation
import VitrinPrivateC

public enum WindowFocus {
    public struct FrontProcessMode: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let allWindows = FrontProcessMode(rawValue: UInt32(VPFrontProcessAllWindows))
        public static let userGenerated = FrontProcessMode(rawValue: UInt32(VPFrontProcessUserGenerated))
        public static let noWindows = FrontProcessMode(rawValue: UInt32(VPFrontProcessNoWindows))
    }

    /// `GetProcessForPID`, resolved at runtime (deprecated API, but the SLPS* calls need a PSN).
    public static func processSerialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let fn = PrivateAPI.function(.getProcessForPID, as: VPGetProcessForPIDFn.self) else { return nil }
        var psn = ProcessSerialNumber()
        guard fn(pid, &psn) == noErr else { return nil }
        return psn
    }

    /// Makes the process front, targeting `windowID`. **Changes focus.**
    @discardableResult
    public static func setFrontProcess(_ psn: ProcessSerialNumber, windowID: CGWindowID, mode: FrontProcessMode = .userGenerated) -> Bool {
        guard let fn = PrivateAPI.function(.setFrontProcessWithOptions, as: VPSetFrontProcessWithOptionsFn.self) else { return false }
        var psn = psn
        return fn(&psn, windowID, mode.rawValue) == .success
    }

    /// Makes `windowID` the key window of its process by posting a synthetic left-mouse down + up pair
    /// whose coordinates are far outside any window content. **Changes focus.**
    ///
    /// Both edges are always sent: an unmatched "down" leaves SDL-based apps with a pending focus click
    /// that disables cursor confinement (AltTab #5381, #5900).
    @discardableResult
    public static func makeKeyWindow(_ psn: ProcessSerialNumber, windowID: CGWindowID) -> Bool {
        guard let fn = PrivateAPI.function(.postEventRecordTo, as: VPPostEventRecordToFn.self) else { return false }
        var psn = psn
        var ok = true
        for type in [FocusEventType.mouseDown, .mouseUp] {
            var bytes = focusEventRecord(windowID: windowID, type: type)
            let status = bytes.withUnsafeMutableBufferPointer { fn(&psn, $0.baseAddress!) }
            ok = ok && status == .success
        }
        return ok
    }

    /// Full focus of one window: front process → key window → AXRaise. **Changes focus.**
    ///
    /// - Parameter element: the window's AX element; when given, it is raised (orders it above the app's
    ///   other windows). Requires the Accessibility permission.
    /// - Returns: `false` if the process couldn't be fronted (unavailable API / dead pid).
    @discardableResult
    public static func focus(windowID: CGWindowID, pid: pid_t, element: AXUIElement? = nil) -> Bool {
        guard let psn = processSerialNumber(for: pid) else { return false }
        let fronted = setFrontProcess(psn, windowID: windowID, mode: .userGenerated)
        makeKeyWindow(psn, windowID: windowID)
        if let element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        return fronted
    }

    /// Makes `pid` the front process of `space` only (`SLSSpaceSetFrontPSN`). **Changes focus state.**
    ///
    /// `setFrontProcess` toward a window on another Space also rewrites the *origin* Space's remembered front
    /// app, so returning to that Space would pop the focused app's windows there (AltTab #4507). Calling this
    /// with the origin Space and its previous front app afterwards repairs it. Approach from AltTab's
    /// `Window.restoreOriginSpaceFront` (github.com/lwouis/alt-tab-macos, GPL-3.0).
    @discardableResult
    public static func setSpaceFrontProcess(space: SkyLight.SpaceID, pid: pid_t) -> Bool {
        guard let fn = PrivateAPI.function(.spaceSetFrontPSN, as: VPSpaceSetFrontPSNFn.self),
              let cid = SkyLight.mainConnectionID,
              let psn = processSerialNumber(for: pid) else { return false }
        return fn(cid, space, psn) == .success
    }

    // MARK: Event record (internal for tests)

    enum FocusEventType: UInt8 {
        case mouseDown = 0x01
        case mouseUp = 0x02
    }

    /// Off-content point used for both coordinate fields; finite and far from any resize edge.
    static let offContentPoint = CGPoint(x: 300_000, y: 300_000)

    /// The zero-filled 0x100-byte CGSEventRecord posted by `makeKeyWindow` (declared length 0xf8).
    static func focusEventRecord(windowID: CGWindowID, type: FocusEventType) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(VPFocusEventRecordBufferSize))
        bytes[Int(VPFocusEventOffsetLength)] = UInt8(VPFocusEventRecordDeclaredSize)
        bytes[Int(VPFocusEventOffsetType)] = type.rawValue
        bytes[Int(VPFocusEventOffsetFlags)] = 0x10
        write(offContentPoint, into: &bytes, at: Int(VPFocusEventOffsetGlobalPoint))
        write(offContentPoint, into: &bytes, at: Int(VPFocusEventOffsetWindowPoint))
        write(windowID, into: &bytes, at: Int(VPFocusEventOffsetWindowID))
        return bytes
    }

    private static func write<T>(_ value: T, into bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { raw in
            bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
        }
    }
}
