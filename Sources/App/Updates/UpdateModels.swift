import Foundation

/// A newer release found on GitHub.
struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let htmlURL: URL
    let dmgURL: URL?
    let notes: String
}

/// Pure helpers: version comparison and release-JSON parsing. No I/O.
enum UpdateLogic {
    /// Parsed semantic version. `v` prefix and `+build` metadata are ignored.
    struct SemVer: Equatable, Comparable {
        var core: [Int]          // major, minor, patch (padded to 3)
        var prerelease: [String] // empty = stable

        init?(_ string: String) {
            var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
            var pre: [String] = []
            if let dash = s.firstIndex(of: "-") {
                pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
                s = String(s[..<dash])
            }
            let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
            core = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
            prerelease = pre
        }

        var isPrerelease: Bool { !prerelease.isEmpty }

        static func < (a: SemVer, b: SemVer) -> Bool {
            if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
            if a.prerelease == b.prerelease { return false }
            if a.prerelease.isEmpty { return false }  // stable > prerelease
            if b.prerelease.isEmpty { return true }
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                switch (Int(x), Int(y)) {
                case let (i?, j?): return i < j
                case (_?, nil): return true   // numeric < alphanumeric
                case (nil, _?): return false
                default: return x < y
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }

    /// `true` when `candidate` is strictly newer than `current`. Unparseable input → `false`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let c = SemVer(candidate), let cur = SemVer(current) else { return false }
        return c > cur
    }

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    /// Parses a `releases/latest` JSON body into an update that is newer than `currentVersion`.
    /// Returns nil for drafts, prereleases (unless the current version is a 0.x prerelease),
    /// malformed JSON, the skipped version, or anything not strictly newer.
    static func parseRelease(
        _ data: Data, currentVersion: String, skippedVersion: String? = nil
    ) -> AvailableUpdate? {
        guard let dto = try? JSONDecoder().decode(ReleaseDTO.self, from: data),
              dto.draft != true,
              let candidate = SemVer(dto.tag_name),
              let current = SemVer(currentVersion),
              let page = URL(string: dto.html_url), page.scheme == "https"
        else { return nil }

        let currentIsZeroPre = current.core[0] == 0
        if (dto.prerelease == true || candidate.isPrerelease) && !currentIsZeroPre { return nil }
        guard candidate > current else { return nil }

        var version = dto.tag_name.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        if let skipped = skippedVersion, SemVer(skipped) == candidate { return nil }

        let dmg = dto.assets?
            .first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { $0.scheme == "https" ? $0 : nil }
        return AvailableUpdate(version: version, htmlURL: page, dmgURL: dmg, notes: dto.body ?? "")
    }
}
