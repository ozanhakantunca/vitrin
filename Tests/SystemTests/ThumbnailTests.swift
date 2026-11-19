import CoreGraphics
import Testing
@testable import VitrinSystem

@Test func thumbnailAspectFit() {
    #expect(ThumbnailMath.fit(source: CGSize(width: 400, height: 200), into: CGSize(width: 100, height: 100)) == CGSize(width: 100, height: 50))
    #expect(ThumbnailMath.fit(source: CGSize(width: 200, height: 400), into: CGSize(width: 100, height: 100)) == CGSize(width: 50, height: 100))
    #expect(ThumbnailMath.fit(source: CGSize(width: 20, height: 10), into: CGSize(width: 100, height: 100)) == CGSize(width: 20, height: 10))
    #expect(ThumbnailMath.fit(source: .zero, into: .zero) == CGSize(width: 1, height: 1))
}

@Test func thumbnailLRU() {
    var cache = ThumbnailLRU<Int, String>(capacity: 2)
    cache.set(1, "one"); cache.set(2, "two")
    #expect(cache.get(1) == "one")
    cache.set(3, "three")
    #expect(cache.get(2) == nil)
    #expect(cache.get(1) == "one")
    cache.set(3, "updated"); cache.set(4, "four")
    #expect(cache.get(1) == nil)
    #expect(cache.get(3) == "updated")
}
