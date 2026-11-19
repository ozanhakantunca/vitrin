import Foundation

private func normalized(_ text: String) -> [Character] {
    Array(text.replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "I", with: "i")
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: "ı", with: "i"))
}

private struct Candidate {
    let chars: [Character]
    let starts: [Bool]

    init(_ text: String) {
        // Preserve boundaries before folding removes case distinctions.
        var chars: [Character] = []
        var starts: [Bool] = []
        var previous: Character?
        for char in text {
            let folded = normalized(String(char))
            let boundary = previous == nil || !(previous?.isLetter == true || previous?.isNumber == true)
                || (previous?.isLowercase == true && char.isUppercase)
            for (index, value) in folded.enumerated() {
                chars.append(value)
                starts.append(index == 0 && boundary)
            }
            previous = char
        }
        self.chars = chars
        self.starts = starts
    }

    func score(_ word: [Character]) -> Int? {
        guard !word.isEmpty, word.count <= chars.count else { return nil }
        var best: Int?
        for start in chars.indices where chars[start] == word[0] {
            var position = start
            var matched = 1
            var consecutive = 0
            var boundaries = starts[start] ? 1 : 0
            while matched < word.count {
                let old = position
                position += 1
                while position < chars.count && chars[position] != word[matched] { position += 1 }
                if position == chars.count { break }
                if position == old + 1 { consecutive += 1 }
                if starts[position] { boundaries += 1 }
                matched += 1
            }
            guard matched == word.count else { continue }
            let contiguous = position - start + 1 == word.count
            let tier = contiguous ? (start == 0 ? 4 : (starts[start] ? 3 : 2)) : 1
            // Keep tiers distinct regardless of candidate length.
            let detail = min(999, boundaries * 20 + consecutive * 5 + max(0, 100 - (position - start + 1 - word.count)))
            let value = tier * 1000 + detail
            best = max(best ?? value, value)
        }
        return best
    }
}

public enum FuzzyMatcher {
    public static func score(query: String, candidate: String) -> Int? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }
        guard !words.isEmpty else { return 0 }
        let candidate = Candidate(candidate)
        var total = 0
        for word in words {
            guard let score = candidate.score(word) else { return nil }
            total += score
        }
        return total
    }
}

public enum WindowSearch {
    public static func filter(_ windows: [WindowInfo], query: String) -> [WindowInfo] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }
        guard !words.isEmpty else { return windows }
        var matches: [(Int, Int, WindowInfo)] = []
        for (index, window) in windows.enumerated() {
            let title = Candidate(window.title)
            let app = Candidate(window.appName)
            var total = 0
            var titleOnly = false
            var appOnly = false
            var valid = true
            for word in words {
                let t = title.score(word)
                let a = app.score(word)
                guard let best = [t, a].compactMap({ $0 }).max() else { valid = false; break }
                total += best
                if t != nil && (a == nil || t! > a!) { titleOnly = true }
                if a != nil && (t == nil || a! > t!) { appOnly = true }
            }
            if valid { matches.append((total + (titleOnly && appOnly ? 10 : 0), index, window)) }
        }
        return matches.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }
}
