import CoreGraphics
import Testing
import VitrinCore
@testable import Vitrin

@Test func gridLayouts() {
    let screen = CGSize(width: 1440, height: 875)
    func grid(_ n: Int, _ width: CGFloat = 220) -> GridLayout {
        GridLayout.compute(count: n, screenSize: screen, cell: CellMetrics(thumbnailWidth: width))
    }
    #expect(grid(1).panelSize == CGSize(width: 280, height: 223))
    #expect(grid(5).panelSize == CGSize(width: 1272, height: 223))
    #expect(grid(6).columns == 3 && grid(6).rows == 2)
    #expect(grid(11, 160).columns == 6 && grid(11, 160).metrics.thumbnailWidth == 160)
    #expect(grid(30).columns == 6 && grid(30).metrics.thumbnailWidth == 156)
    #expect(grid(50).columns == 8 && grid(50).rows == 7 && grid(50).scrolls)
    #expect(grid(50).metrics.thumbnailWidth == 120)
    #expect(grid(0).rows == 0)
    let balanced = GridLayout.compute(count: 7, screenSize: screen, cell: CellMetrics(thumbnailWidth: 160, forcedColumns: 6))
    #expect(balanced.columns == 4 && balanced.lastRowCount == 3)
    #expect(balanced.cellOrigin(at: 4).x == balanced.cellOrigin(at: 0).x + 94)
}

@Test func listGeometry() {
    #expect([1440, 2560, 1000, 400].map { ListSizing.rowWidth(screenWidth: CGFloat($0), panelPadding: 16) } == [616, 1068, 418, 328])
    #expect([160, 220, 300].map { ListSizing.rowHeight(forBaseThumbnailWidth: CGFloat($0)) } == [34, 40, 48])
    let row = ListRowLayout.compute(rowWidth: 616, rowHeight: 40, badgeCount: 2, titleTextWidth: 180, appNameTextWidth: 60)
    #expect(row.icon == CGRect(x: 12, y: 10, width: 20, height: 20))
    #expect(row.title == CGRect(x: 42, y: 12, width: 180, height: 16))
    #expect(row.appName == CGRect(x: 230, y: 12, width: 60, height: 16))
    let long = ListRowLayout.compute(rowWidth: 616, rowHeight: 40, badgeCount: 0, titleTextWidth: 1000, appNameTextWidth: 1000)
    #expect(long.appName?.width == 172)
    #expect(ListRowLayout.compute(rowWidth: 616, rowHeight: 40, badgeCount: 0, titleTextWidth: 10, appNameTextWidth: 0).appName == nil)
}

@Test func sizingAndPreview() {
    for (size, width, icon) in [(SwitcherSize.small, CGFloat(160), CGFloat(96)), (.medium, 220, 128), (.large, 300, 160)] {
        #expect(SwitcherSizing.baseThumbnailWidth(for: size, screenSize: .zero, itemCount: 1) == width)
        #expect(SwitcherSizing.iconSide(forBaseThumbnailWidth: width) == icon)
    }
    #expect(PreviewGeometry.cocoaFrame(fromGlobalTopLeft: CGRect(x: 0, y: -500, width: 400, height: 300), primaryScreenHeight: 900) == CGRect(x: 0, y: 1100, width: 400, height: 300))
}

@Test func desktopStripFitsAndCentersTiles() {
    typealias Strip = TaskViewLayout.DesktopStrip
    #expect(Strip(count: 0, screenWidth: 1440).reservedHeight == 0)
    #expect(Strip(count: 1, screenWidth: 1440).reservedHeight == 0)
    let strip = Strip(count: 3, screenWidth: 1440)
    #expect(strip.frame.midX == 720 && strip.frame.minY == 24)
    #expect(strip.tileWidth == 160 && strip.frame.height == 96 + Strip.captionHeight)
    #expect(strip.tileFrame(at: 2).maxX == strip.frame.width)

    let crowded = Strip(count: 16, screenWidth: 900)
    #expect(crowded.tileWidth < strip.tileWidth && crowded.frame.height < strip.frame.height)
    #expect(crowded.frame.minX >= 23.99 && crowded.frame.maxX <= 876.01)
    #expect(abs(crowded.tileFrame(at: 15).maxX - crowded.frame.width) < 0.01)
}

@Test func taskViewGridReservesVisibleStripHeight() {
    let screen = CGSize(width: 1200, height: 600)
    var cell = CellMetrics(thumbnailWidth: 280)
    cell.minThumbnailWidth = 280
    let strip = TaskViewLayout.DesktopStrip(count: 3, screenWidth: screen.width)
    let plain = TaskViewLayout.compute(count: 5, screenSize: screen, cell: cell)
    let reduced = TaskViewLayout.compute(count: 5, screenSize: screen, cell: cell, stripHeight: strip.reservedHeight)
    #expect(reduced.panelSize == plain.panelSize)
    #expect(reduced.scrollAreaHeight == plain.scrollAreaHeight - strip.reservedHeight)
    #expect(!plain.scrolls && reduced.scrolls)
}
