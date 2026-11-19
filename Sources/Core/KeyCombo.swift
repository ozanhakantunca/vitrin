import Foundation

/// Modifier keys that must be held for a shortcut. The switcher stays open while they are held.
public struct ModifierSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)
    public static let function = ModifierSet(rawValue: 1 << 4)

    /// Canonical order (the order macOS menus display them: ⌃⌥⇧⌘, then fn).
    static let canonical: [(flag: ModifierSet, name: String, symbol: String)] = [
        (.control, "control", "⌃"),
        (.option, "option", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "command", "⌘"),
        (.function, "fn", "fn"),
    ]

    static let aliases: [String: ModifierSet] = [
        "control": .control, "ctrl": .control, "ctl": .control, "⌃": .control, "^": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "command": .command, "cmd": .command, "⌘": .command,
        "fn": .function, "function": .function, "globe": .function,
    ]

    /// Canonical lowercase names, e.g. `["option", "command"]`.
    public var names: [String] {
        Self.canonical.filter { contains($0.flag) }.map(\.name)
    }

    /// e.g. `"⌥⌘"`.
    public var symbols: String {
        Self.canonical.filter { contains($0.flag) }.map(\.symbol).joined()
    }
}

/// A keyboard shortcut: a set of held modifiers plus one trigger key.
///
/// JSON form is a single human-readable string, e.g. `"option+tab"`, `"option+keyAboveTab"`,
/// `"command+shift+keyCode:50"`. Parsing is case-insensitive and accepts common aliases
/// (`alt`, `opt`, `cmd`, `ctrl`, `⌘`, …); encoding always produces the canonical form.
public struct KeyCombo: Sendable, Hashable, Codable, CustomStringConvertible {
    public var modifiers: ModifierSet
    public var key: Key

    public init(modifiers: ModifierSet, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// The trigger key.
    public enum Key: Sendable, Hashable {
        /// A hardware virtual key code (`kVK_*`), layout-independent.
        case code(UInt16)
        /// Semantic "the key physically above Tab": `` ` `` (kVK_ANSI_Grave) on ANSI keyboards,
        /// `§` (kVK_ISO_Section) on ISO keyboards. Resolved at runtime by the app layer.
        case keyAboveTab

        public static let tab = Key.code(KeyCode.tab)
        public static let space = Key.code(KeyCode.space)
        public static let escape = Key.code(KeyCode.escape)
        public static let grave = Key.code(KeyCode.grave)

        /// Resolves to a concrete key code for the current keyboard type.
        public func keyCode(isISOKeyboard: Bool) -> UInt16 {
            switch self {
            case .code(let code): return code
            case .keyAboveTab: return isISOKeyboard ? KeyCode.isoSection : KeyCode.grave
            }
        }

        /// Every key code this key may stand for (used for conflict detection).
        public var possibleKeyCodes: Set<UInt16> {
            switch self {
            case .code(let code): return [code]
            case .keyAboveTab: return [KeyCode.grave, KeyCode.isoSection]
            }
        }

        /// Canonical config name: a named key (`"tab"`, `"a"`, `"f5"`), `"keyAboveTab"`, or `"keyCode:N"`.
        public var name: String {
            switch self {
            case .keyAboveTab: return "keyAboveTab"
            case .code(let code): return KeyCode.nameByCode[code] ?? "keyCode:\(code)"
            }
        }

        public init?(name raw: String) {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if name == "keyabovetab" {
                self = .keyAboveTab
            } else if name.hasPrefix("keycode:"), let code = UInt16(name.dropFirst("keycode:".count)) {
                self = .code(code)
            } else if let code = KeyCode.codeByName[name] {
                self = .code(code)
            } else {
                return nil
            }
        }

        /// Short label for UI, e.g. `"⇥"`, `` "`" ``, `"A"`, `"F5"`.
        public var symbol: String {
            switch self {
            case .keyAboveTab: return "`"
            case .code(let code):
                if let symbol = KeyCode.symbolByCode[code] { return symbol }
                return name.count <= 3 ? name.uppercased() : name
            }
        }
    }

    // MARK: String form

    public init?(string: String) {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyPart = parts.last, !keyPart.isEmpty, let key = Key(name: keyPart) else { return nil }
        var modifiers: ModifierSet = []
        for part in parts.dropLast() {
            guard let modifier = ModifierSet.aliases[part.lowercased()] else { return nil }
            modifiers.insert(modifier)
        }
        self.init(modifiers: modifiers, key: key)
    }

    /// Canonical string, e.g. `"option+tab"`.
    public var stringValue: String {
        (modifiers.names + [key.name]).joined(separator: "+")
    }

    public var description: String { stringValue }

    /// Display label, e.g. `"⌥⇥"`.
    public var displayString: String {
        modifiers.symbols + key.symbol
    }

    /// Whether both combos could fire on the same keystroke.
    public func conflicts(with other: KeyCombo) -> Bool {
        modifiers == other.modifiers && !key.possibleKeyCodes.isDisjoint(with: other.key.possibleKeyCodes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let combo = KeyCombo(string: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid shortcut \"\(string)\" (expected e.g. \"option+tab\")"
            )
        }
        self = combo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

/// macOS virtual key codes (`kVK_*` from Carbon's Events.h), named by their ANSI-US position.
public enum KeyCode {
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let grave: UInt16 = 0x32
    public static let escape: UInt16 = 0x35
    public static let isoSection: UInt16 = 0x0A

    static let table: [(name: String, code: UInt16)] = [
        ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06),
        ("x", 0x07), ("c", 0x08), ("v", 0x09), ("section", 0x0A), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D),
        ("e", 0x0E), ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14),
        ("4", 0x15), ("6", 0x16), ("5", 0x17), ("equal", 0x18), ("9", 0x19), ("7", 0x1A), ("minus", 0x1B),
        ("8", 0x1C), ("0", 0x1D), ("rightbracket", 0x1E), ("o", 0x1F), ("u", 0x20), ("leftbracket", 0x21),
        ("i", 0x22), ("p", 0x23), ("return", 0x24), ("l", 0x25), ("j", 0x26), ("quote", 0x27), ("k", 0x28),
        ("semicolon", 0x29), ("backslash", 0x2A), ("comma", 0x2B), ("slash", 0x2C), ("n", 0x2D), ("m", 0x2E),
        ("period", 0x2F), ("tab", 0x30), ("space", 0x31), ("grave", 0x32), ("delete", 0x33), ("escape", 0x35),
        ("f17", 0x40), ("f18", 0x4F), ("f19", 0x50), ("f20", 0x5A), ("f5", 0x60), ("f6", 0x61), ("f7", 0x62),
        ("f3", 0x63), ("f8", 0x64), ("f9", 0x65), ("f11", 0x67), ("f13", 0x69), ("f16", 0x6A), ("f14", 0x6B),
        ("f10", 0x6D), ("f12", 0x6F), ("f15", 0x71), ("help", 0x72), ("home", 0x73), ("pageup", 0x74),
        ("forwarddelete", 0x75), ("f4", 0x76), ("end", 0x77), ("f2", 0x78), ("pagedown", 0x79), ("f1", 0x7A),
        ("left", 0x7B), ("right", 0x7C), ("down", 0x7D), ("up", 0x7E),
    ]

    static let nameByCode: [UInt16: String] = Dictionary(uniqueKeysWithValues: table.map { ($0.code, $0.name) })

    static let codeByName: [String: UInt16] = {
        var map = Dictionary(uniqueKeysWithValues: table.map { ($0.name, $0.code) })
        // Friendly aliases accepted on input only.
        map["esc"] = escape
        map["enter"] = 0x24
        map["backtick"] = grave
        map["`"] = grave
        map["§"] = isoSection
        map["backspace"] = 0x33
        return map
    }()

    static let symbolByCode: [UInt16: String] = [
        0x30: "⇥", 0x31: "Space", 0x32: "`", 0x0A: "§", 0x24: "↩", 0x35: "⎋", 0x33: "⌫", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[",
        0x27: "'", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".",
    ]
}
