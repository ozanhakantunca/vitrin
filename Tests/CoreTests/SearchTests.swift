import Foundation
import Testing
@testable import VitrinCore

@Test func searchRankingAndFiltering() {
    let windows = [WindowInfo(id: 1, pid: 1, title: "a x b c"), WindowInfo(id: 2, pid: 1, title: "xxabc"), WindowInfo(id: 3, pid: 1, title: "abc")]
    #expect(WindowSearch.filter(windows, query: "abc").map(\.id) == [3, 2, 1])
    #expect(WindowSearch.filter(windows, query: "nope").isEmpty)
    #expect(WindowSearch.filter(windows, query: "  ") == windows)
}

@Test func searchFieldsAndTies() {
    let windows = [WindowInfo(id: 1, pid: 1, appName: "Safari", title: "GitHub"), WindowInfo(id: 2, pid: 1, appName: "Chrome"), WindowInfo(id: 3, pid: 1, appName: "Chrome")]
    #expect(WindowSearch.filter(windows, query: "saf git").map(\.id) == [1])
    #expect(WindowSearch.filter(windows, query: "chr").map(\.id) == [2, 3])
}

@Test func searchTurkish() {
    for (query, candidate) in [("istanbul", "İstanbul"), ("ı", "i"), ("s g u o c", "ş ğ ü ö ç")] {
        #expect(FuzzyMatcher.score(query: query, candidate: candidate) != nil)
    }
}

@Test func searchPerformance() {
    let windows = (0..<500).map { WindowInfo(id: UInt32($0), pid: 1, appName: "Browser", title: "Example window \($0)") }
    let start = Date()
    for _ in 0..<10 { _ = WindowSearch.filter(windows, query: "ex win") }
    #expect(Date().timeIntervalSince(start) < 1)
}
