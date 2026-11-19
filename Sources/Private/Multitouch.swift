// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Thin, fail-safe wrapper over the private MultitouchSupport framework (raw trackpad contact frames).
// Approach adapted from AltTab (github.com/lwouis/alt-tab-macos, GPL-3.0, `TrackpadEvents`): enumerate the
// devices with `MTDeviceCreateList`, register one C contact-frame callback per device, `MTDeviceStart(_, 0)`.
// Layout and signatures: see `VPMTTouch` in VitrinPrivateC.h.
//
// Nothing links against MultitouchSupport: every call resolves through `PrivateAPI` and becomes a no-op
// (or returns nil / false) when the framework or a symbol is missing.

import CoreFoundation
import os
import VitrinPrivateC

public enum Multitouch {
    /// The symbols the gesture recognizer cannot work without.
    public static let requiredSymbols: [PrivateAPI.Symbol] = [
        .mtDeviceCreateList, .mtRegisterContactFrameCallback, .mtUnregisterContactFrameCallback,
        .mtDeviceStart, .mtDeviceStop,
    ]

    /// Whether raw contact frames can be received on this macOS.
    public static var isAvailable: Bool {
        requiredSymbols.allSatisfy(PrivateAPI.isAvailable)
    }

    /// The C callback type devices deliver frames to. Must be a non-capturing closure / C function.
    public typealias ContactFrameCallback = VPMTContactFrameCallback

    // MARK: Frames

    /// One contact frame reduced to the fingers actually touching the pad (no C types, no allocation).
    public struct FrameSummary: Sendable, Hashable {
        /// Address of the device that produced the frame (`Device.address`).
        public var device: UInt
        /// Seconds of host uptime.
        public var timestamp: Double
        /// Contacts in `MakeTouch` / `Touching` state.
        public var fingerCount: Int
        /// Centroid of those contacts, normalized (x 0 left … 1 right, y 0 bottom … 1 top). 0 when none.
        public var x: Float
        public var y: Float
        /// `1 << (identifier & 63)` for each touching contact.
        public var contacts: UInt64

        public init(device: UInt, timestamp: Double, fingerCount: Int, x: Float, y: Float, contacts: UInt64) {
            self.device = device
            self.timestamp = timestamp
            self.fingerCount = fingerCount
            self.x = x
            self.y = y
            self.contacts = contacts
        }
    }

    /// Receives every frame on MultitouchSupport's private thread. Keep it short and allocation-free.
    public typealias FrameHandler = @Sendable (FrameSummary) -> Void

    private static let frameHandler = OSAllocatedUnfairLock<FrameHandler?>(initialState: nil)

    /// Installs (or with `nil` removes) the process-wide handler `frameCallback` forwards to.
    public static func setFrameHandler(_ handler: FrameHandler?) {
        frameHandler.withLock { $0 = handler }
    }

    /// The one C callback Vitrin registers on every device: summarizes the frame and forwards it to the
    /// handler set with `setFrameHandler`.
    public static let frameCallback: ContactFrameCallback = { device, touches, count, timestamp, _ in
        guard let handler = Multitouch.frameHandler.withLock({ $0 }) else { return 0 }
        handler(Multitouch.summarize(touches, count: count, timestamp: timestamp, device: UInt(bitPattern: device)))
        return 0
    }

    /// Whether a contact in `state` is a finger on the pad.
    public static func isTouching(state: Int32) -> Bool {
        state == Int32(VPMTTouchStateMakeTouch) || state == Int32(VPMTTouchStateTouching)
    }

    /// Reduces `count` contiguous touches to a `FrameSummary`.
    public static func summarize(_ touches: UnsafePointer<VPMTTouch>?, count: Int32, timestamp: Double, device: UInt) -> FrameSummary {
        var touching = 0
        var sumX: Float = 0, sumY: Float = 0
        var contacts: UInt64 = 0
        if let touches, count > 0 {
            for touch in UnsafeBufferPointer(start: touches, count: Int(count)) where isTouching(state: touch.state) {
                touching += 1
                sumX += touch.normalized.position.x
                sumY += touch.normalized.position.y
                contacts |= 1 << UInt64(UInt32(bitPattern: touch.identifier) & 63)
            }
        }
        let divisor = Float(max(touching, 1))
        return FrameSummary(device: device, timestamp: timestamp, fingerCount: touching,
                            x: sumX / divisor, y: sumY / divisor, contacts: contacts)
    }

    /// A snapshot of the multitouch devices present when it was created. Keeps them alive (the devices are
    /// owned by the `MTDeviceCreateList` array this object retains).
    ///
    /// Not thread-safe; use from one thread (the recognizer uses the main thread).
    public final class DeviceList {
        private let array: CFArray
        public let devices: [Device]

        /// `nil` if MultitouchSupport is unavailable. May be empty (e.g. a Mac mini with no trackpad).
        public init?() {
            guard let create = PrivateAPI.function(.mtDeviceCreateList, as: VPMTDeviceCreateListFn.self),
                  let list = create()?.takeRetainedValue() else { return nil }
            array = list
            devices = (0..<CFArrayGetCount(list)).compactMap { index in
                CFArrayGetValueAtIndex(list, index).map { Device(ref: UnsafeMutableRawPointer(mutating: $0)) }
            }
        }
    }

    /// One MTDevice. Valid only while its `DeviceList` is alive.
    public struct Device: Hashable {
        public let ref: VPMTDeviceRef

        /// Identity of the device pointer, as frames report it (`device` argument of the callback).
        public var address: UInt { UInt(bitPattern: ref) }

        public var isBuiltIn: Bool? {
            PrivateAPI.function(.mtDeviceIsBuiltIn, as: VPMTDeviceIsBuiltInFn.self).map { $0(ref) }
        }

        public var isRunning: Bool? {
            PrivateAPI.function(.mtDeviceIsRunning, as: VPMTDeviceIsRunningFn.self).map { $0(ref) }
        }

        public var deviceID: UInt64? {
            guard let fn = PrivateAPI.function(.mtDeviceGetDeviceID, as: VPMTDeviceGetDeviceIDFn.self) else { return nil }
            var id: UInt64 = 0
            return fn(ref, &id) == 0 ? id : nil
        }

        /// Registers `callback` and starts the device. Returns false if unavailable or the start failed
        /// (the callback is unregistered again in that case).
        @discardableResult
        public func start(callback: ContactFrameCallback = Multitouch.frameCallback) -> Bool {
            guard let register = PrivateAPI.function(.mtRegisterContactFrameCallback, as: VPMTRegisterContactFrameCallbackFn.self),
                  let start = PrivateAPI.function(.mtDeviceStart, as: VPMTDeviceStartFn.self) else { return false }
            register(ref, callback)
            if start(ref, 0) == 0 { return true }
            PrivateAPI.function(.mtUnregisterContactFrameCallback, as: VPMTUnregisterContactFrameCallbackFn.self)?(ref, callback)
            return false
        }

        /// Unregisters `callback` and stops the device. Safe to call on a device that is not running.
        public func stop(callback: ContactFrameCallback = Multitouch.frameCallback) {
            PrivateAPI.function(.mtUnregisterContactFrameCallback, as: VPMTUnregisterContactFrameCallbackFn.self)?(ref, callback)
            if isRunning != false {
                _ = PrivateAPI.function(.mtDeviceStop, as: VPMTDeviceStopFn.self)?(ref)
            }
        }
    }
}
