import CoreGraphics
import Testing
@testable import Vitrin

@MainActor @Test func initialSelectionRules() {
    #expect(SwitcherController.initialSelection(count: 1, reverse: false) == 0)
    #expect(SwitcherController.initialSelection(count: 5, reverse: false) == 1)
    #expect(SwitcherController.initialSelection(count: 5, reverse: true) == 4)
}

@Test func previewGeometryFlipsCoordinates() {
    let frame = PreviewGeometry.cocoaFrame(fromGlobalTopLeft: CGRect(x: 100, y: 50, width: 800, height: 600), primaryScreenHeight: 900)
    #expect(frame == CGRect(x: 100, y: 250, width: 800, height: 600))
}
