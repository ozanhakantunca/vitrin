import Foundation

// Tolerant decoding: hand-edited or older config files must never crash the app.
//
// - Missing keys        → the field's default.
// - Unknown keys        → ignored (Codable ignores them by construction).
// - Wrong type / value  → the field's default, plus a human-readable warning.
// - Bad array element   → element skipped, plus a warning (one typo must not wipe every profile).
//
// Warnings are collected through `decoder.userInfo[.vitrinWarnings]` so `ConfigStore` can surface them.

final class DecodingWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

extension CodingUserInfoKey {
    static let vitrinWarnings = CodingUserInfoKey(rawValue: "io.github.ozanhakantunca.vitrin.warnings")!
}

func codingPathString(_ path: [CodingKey]) -> String {
    let joined = path.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
    return joined.hasPrefix(".") ? String(joined.dropFirst()) : (joined.isEmpty ? "<root>" : joined)
}

extension Decoder {
    func warn(_ message: String) {
        (userInfo[.vitrinWarnings] as? DecodingWarnings)?.append(message)
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when it is missing, `null`, or invalid.
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T, _ decoder: Decoder) -> T {
        do {
            if let value = try decodeIfPresent(T.self, forKey: key) { return value }
            return fallback()
        } catch {
            decoder.warn("\(codingPathString(codingPath + [key])): \(describe(error)); using default")
            return fallback()
        }
    }

    /// Decodes an array, skipping elements that fail to decode. Missing / non-array → `fallback`.
    func decodeLossyArray<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> [T], _ decoder: Decoder) -> [T] {
        guard contains(key) else { return fallback() }
        do {
            guard var array = try? nestedUnkeyedContainer(forKey: key) else {
                if try decodeNil(forKey: key) { return fallback() }
                decoder.warn("\(codingPathString(codingPath + [key])): expected an array; using default")
                return fallback()
            }
            var result: [T] = []
            while !array.isAtEnd {
                let index = array.currentIndex
                do {
                    result.append(try array.decode(T.self))
                } catch {
                    decoder.warn("\(codingPathString(codingPath + [key]))[\(index)]: \(describe(error)); skipped")
                    // Advance past the bad element.
                    _ = try? array.decode(AnyDecodable.self)
                }
            }
            return result
        } catch {
            decoder.warn("\(codingPathString(codingPath + [key])): \(describe(error)); using default")
            return fallback()
        }
    }
}

/// Consumes any JSON value (used to skip a bad array element).
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

func describe(_ error: Error) -> String {
    guard let error = error as? DecodingError else { return String(describing: error) }
    switch error {
    case .typeMismatch(let type, _): return "expected \(type)"
    case .valueNotFound(let type, _): return "missing \(type) value"
    case .keyNotFound(let key, _): return "missing key \"\(key.stringValue)\""
    case .dataCorrupted(let context): return context.debugDescription
    @unknown default: return String(describing: error)
    }
}
