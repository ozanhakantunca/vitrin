// Brute-force AX element search: bounds and bookkeeping. Read-only (never changes focus or Spaces).

import ApplicationServices
import Foundation
import Testing
@testable import VitrinPrivate

@Suite struct BruteForceTests {
    @Test func emptyRequestDoesNothing() {
        let result = AXPrivate.windowElements(pid: getpid(), windowIDs: [], startingAt: 17)
        #expect(result.elements.isEmpty)
        #expect(result.nextElementID == 17)
        #expect(!result.appUnresponsive)
    }

    @Test func zeroBudgetReturnsImmediately() {
        let start = Date()
        let result = AXPrivate.windowElements(pid: getpid(), windowIDs: [123_456], startingAt: 5, budget: 0)
        #expect(result.elements.isEmpty)
        #expect(result.nextElementID == 5) // nothing tried: resume where we were
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(AXPrivate.windowElementsByBruteForce(pid: getpid(), budget: 0).isEmpty)
    }

    @Test func budgetBoundsTheSweep() {
        // Without the Accessibility permission (or for a pid without windows) nothing is found, and the sweep
        // must still stop around its budget instead of walking the whole id space.
        let start = Date()
        let result = AXPrivate.windowElements(pid: getpid(), windowIDs: [123_456], budget: 0.05)
        #expect(result.elements.isEmpty)
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(result.nextElementID > 0 || result.appUnresponsive)
    }

    @Test func spaceFrontSymbolResolves() {
        #expect(PrivateAPI.isAvailable(.spaceSetFrontPSN))
    }
}
