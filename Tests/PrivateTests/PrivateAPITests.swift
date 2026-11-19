// Smoke tests for the private API layer. Read-only: nothing here changes system state
// (no hotkey toggling, no focusing).

import CoreGraphics
import Foundation
import Testing
@testable import VitrinPrivate
import VitrinPrivateC

/// Set `VITRIN_SKIP_WINDOWSERVER_TESTS=1` on headless CI runners without a GUI login session.
private let hasWindowServerSession = ProcessInfo.processInfo.environment["VITRIN_SKIP_WINDOWSERVER_TESTS"] == nil

@Suite struct SymbolAvailabilityTests {
    @Test func everySymbolResolves() {
        let report = PrivateAPI.availabilityReport()
        let missing = report.filter { !$0.isAvailable }
        #expect(missing.isEmpty, "unresolved: \(missing.map(\.symbol.rawValue))\n\(PrivateAPI.availabilityReportText())")
        #expect(report.count == PrivateAPI.Symbol.allCases.count)
        #expect(PrivateAPI.allSymbolsAvailable)
    }

    @Test func reportNamesImages() {
        for entry in PrivateAPI.availabilityReport() where entry.isAvailable {
            #expect(entry.imagePath != nil, "\(entry.symbol)")
            #expect(entry.symbol.candidates.contains(entry.resolvedName ?? ""))
        }
        print(PrivateAPI.availabilityReportText())
    }
}

@Suite(.enabled(if: hasWindowServerSession)) struct SkyLightQueryTests {
    @Test func mainConnectionIsNonZero() throws {
        let cid = try #require(SkyLight.mainConnectionID)
        #expect(cid != 0)
    }

    @Test func activeSpaceIsReported() throws {
        let space = try #require(SkyLight.activeSpace())
        #expect(space != 0)
        #expect(SkyLight.spaceType(space) != nil)
    }

    @Test func managedDisplaysIncludeTheActiveSpace() throws {
        let displays = try #require(SkyLight.managedDisplays())
        #expect(!displays.isEmpty)
        for display in displays {
            #expect(!display.identifier.isEmpty)
            #expect(!display.spaces.isEmpty)
            if let current = display.currentSpaceID {
                #expect(display.spaces.contains { $0.id == current })
            }
        }
        let current = try #require(SkyLight.currentSpaces())
        let active = try #require(SkyLight.activeSpace())
        #expect(current.contains(active))
    }

    @Test func currentSpacePerDisplayMatchesManagedDisplays() throws {
        let displays = try #require(SkyLight.managedDisplays())
        for display in displays {
            guard let expected = display.currentSpaceID else { continue }
            #expect(SkyLight.currentSpace(onDisplay: display.identifier) == expected)
        }
    }

    @Test func activeMenuBarDisplayIsKnown() throws {
        let identifier = try #require(SkyLight.activeMenuBarDisplayIdentifier())
        #expect(!identifier.isEmpty)
        if let active = SkyLight.activeSpace() {
            #expect(SkyLight.displayIdentifier(forSpace: active) != nil)
        }
    }

    @Test func spacesForAnOnScreenWindow() throws {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let firstID: CGWindowID? = list.lazy.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }.first
        let windowID = try #require(firstID, "no on-screen window to query")
        let spaces = try #require(SkyLight.spaces(forWindow: windowID))
        _ = spaces // may be empty for some system windows; the call itself must succeed
        #expect(SkyLight.spaces(forWindows: []) != nil)
    }

    @Test func mainDisplayIdentifier() {
        #expect(SkyLight.displayIdentifier(for: CGMainDisplayID()) != nil)
    }
}

@Suite(.enabled(if: hasWindowServerSession)) struct ReadOnlyHotKeyAndProcessTests {
    @Test func commandTabBindingIsReadable() throws {
        #expect(SymbolicHotKeys.isEnabled(.commandTab) != nil)
        let value = try #require(SymbolicHotKeys.value(of: .commandTab))
        #expect(value.keyCode == 0x30) // Tab
        #expect(value.modifiers.contains(.maskCommand))
    }

    @Test func processSerialNumberForSelf() throws {
        let psn = try #require(WindowFocus.processSerialNumber(for: getpid()))
        #expect(psn.highLongOfPSN != 0 || psn.lowLongOfPSN != 0)
    }
}

@Suite struct ByteLayoutTests {
    @Test func remoteTokenLayout() {
        let token = AXPrivate.remoteToken(pid: 0x0102_0304, elementID: 0x1122_3344_5566_7788)
        #expect(token.count == 20)
        #expect(Array(token) == [
            0x04, 0x03, 0x02, 0x01,                          // pid
            0x00, 0x00, 0x00, 0x00,                          // 0
            0x6f, 0x63, 0x6f, 0x63,                          // 'coco'
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // element id
        ])
    }

    @Test func focusEventRecordLayout() {
        let down = WindowFocus.focusEventRecord(windowID: 0xAABB_CCDD, type: .mouseDown)
        let up = WindowFocus.focusEventRecord(windowID: 0xAABB_CCDD, type: .mouseUp)
        #expect(down.count == 0x100)
        #expect(down[0x04] == 0xF8)
        #expect(down[0x08] == 0x01 && up[0x08] == 0x02)
        #expect(down[0x3A] == 0x10)
        #expect(Array(down[0x3C..<0x40]) == [0xDD, 0xCC, 0xBB, 0xAA])

        var point = WindowFocus.offContentPoint
        let pointBytes = withUnsafeBytes(of: &point) { Array($0) }
        #expect(Array(down[0x10..<0x20]) == pointBytes)
        #expect(Array(down[0x20..<0x30]) == pointBytes)
        #expect(down[0xF8...].allSatisfy { $0 == 0 }) // padding stays zeroed

        // The two edges differ only in the event type byte.
        let differing = (0..<0x100).filter { down[$0] != up[$0] }
        #expect(differing == [0x08])
    }
}
