// MultitouchSupport smoke tests. Nothing here starts (or registers a callback on) a device.

import Darwin
import Testing
@testable import VitrinPrivate
import VitrinPrivateC

private let multitouchFrameworkPresent: Bool = {
    // The binary lives in the dyld shared cache, not on disk, so probe with dlopen rather than the file system.
    dlopen(PrivateAPI.Library.multitouchSupport.rawValue, RTLD_LAZY | RTLD_LOCAL) != nil
}()

@Suite(.enabled(if: multitouchFrameworkPresent)) struct MultitouchSymbolTests {
    @Test func symbolsResolveFromMultitouchSupport() {
        let mtSymbols = PrivateAPI.Symbol.allCases.filter { $0.library == .multitouchSupport }
        #expect(mtSymbols.count == 8)
        let report = PrivateAPI.availabilityReport().filter { mtSymbols.contains($0.symbol) }
        for entry in report {
            #expect(entry.isAvailable, "\(entry)")
            #expect(entry.imagePath?.contains("MultitouchSupport") == true, "\(entry)")
        }
        #expect(Multitouch.isAvailable)
    }

    /// Enumerating devices is read-only (no start, no callback); a Mac without a trackpad returns an empty list.
    @Test func deviceListEnumerates() throws {
        let list = try #require(Multitouch.DeviceList())
        for device in list.devices {
            #expect(device.address != 0)
            _ = device.isBuiltIn
            _ = device.deviceID
        }
    }
}

@Suite struct MultitouchLayoutTests {
    @Test func touchStructMatchesDocumentedLayout() {
        #expect(MemoryLayout<VPMTTouch>.size == 96)
        #expect(MemoryLayout<VPMTTouch>.stride == 96)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.frame) == 0x00)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.timestamp) == 0x08)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.identifier) == 0x10)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.state) == 0x14)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.fingerID) == 0x18)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.handID) == 0x1c)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.normalized) == 0x20)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.size) == 0x30)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.angle) == 0x38)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.majorAxis) == 0x3c)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.minorAxis) == 0x40)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.absolute) == 0x44)
        #expect(MemoryLayout<VPMTTouch>.offset(of: \.density) == 0x5c)
    }

    private func touch(id: Int32, state: Int, x: Float, y: Float) -> VPMTTouch {
        var t = VPMTTouch()
        t.identifier = id
        t.state = Int32(state)
        t.normalized.position = VPMTPoint(x: x, y: y)
        return t
    }

    @Test func summarizeCountsOnlyTouchingContacts() {
        let touches = [
            touch(id: 1, state: VPMTTouchStateTouching, x: 0.2, y: 0.2),
            touch(id: 2, state: VPMTTouchStateMakeTouch, x: 0.4, y: 0.4),
            touch(id: 3, state: VPMTTouchStateTouching, x: 0.6, y: 0.6),
            touch(id: 4, state: VPMTTouchStateBreakTouch, x: 0.9, y: 0.9),   // lifting
            touch(id: 5, state: VPMTTouchStateHoverInRange, x: 0.0, y: 0.0), // hovering
            touch(id: 6, state: VPMTTouchStateOutOfRange, x: 0.0, y: 0.0),
        ]
        let summary = touches.withUnsafeBufferPointer {
            Multitouch.summarize($0.baseAddress, count: Int32($0.count), timestamp: 12.5, device: 42)
        }
        #expect(summary.device == 42)
        #expect(summary.timestamp == 12.5)
        #expect(summary.fingerCount == 3)
        #expect(abs(summary.x - 0.4) < 1e-6)
        #expect(abs(summary.y - 0.4) < 1e-6)
        #expect(summary.contacts == 0b1110)
    }

    @Test func summarizeEmptyFrame() {
        let summary = Multitouch.summarize(nil, count: 5, timestamp: 1, device: 1)
        #expect(summary.fingerCount == 0)
        #expect(summary.x == 0 && summary.y == 0 && summary.contacts == 0)
        var none: [VPMTTouch] = []
        let empty = none.withUnsafeMutableBufferPointer {
            Multitouch.summarize($0.baseAddress, count: 0, timestamp: 1, device: 1)
        }
        #expect(empty.fingerCount == 0)
    }

    @Test func touchingStates() {
        let touching = (0...7).filter { Multitouch.isTouching(state: Int32($0)) }
        #expect(touching == [VPMTTouchStateMakeTouch, VPMTTouchStateTouching])
    }
}
