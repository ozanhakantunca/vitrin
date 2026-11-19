import AppKit
import SwiftUI
import VitrinCore

/// Pure factories and event conversion, kept outside the views for direct testing.
enum SettingsProfileFactory {
    static func make(id: String = UUID().uuidString) -> ShortcutProfile {
        ShortcutProfile(id: id, name: String(localized: "New profile"), trigger: nil)
    }

    static func duplicate(_ profile: ShortcutProfile, id: String = UUID().uuidString) -> ShortcutProfile {
        var copy = profile
        copy.id = id
        copy.name = String(localized: "\(profile.name) copy")
        return copy
    }
}

enum SettingsRecordedKey: Equatable {
    case cancel, clear, needsModifier
    case shortcut(KeyCombo)

    static func interpret(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> SettingsRecordedKey {
        if keyCode == KeyCode.escape { return .cancel }
        if keyCode == 51 || keyCode == 117 { return .clear }
        let modifiers = modifiers(from: flags)
        guard !modifiers.isEmpty else { return .needsModifier }
        let key: KeyCombo.Key = (keyCode == 50 || keyCode == 10) ? .keyAboveTab : .code(keyCode)
        return .shortcut(KeyCombo(modifiers: modifiers, key: key))
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}

enum SettingsShortcutLabel {
    static func text(_ combo: KeyCombo?) -> String {
        guard let combo else { return String(localized: "Not assigned") }
        if combo.key == .keyAboveTab || combo.key == .code(50) || combo.key == .code(10) {
            return String(localized: "\(combo.modifiers.symbols) key above Tab")
        }
        return combo.displayString
    }
}

protocol SettingsChoice: Hashable, CaseIterable {
    var settingsLabel: String { get }
}

@MainActor
struct SettingsPicker<Value: SettingsChoice>: View {
    let title: String
    @Binding var selection: Value

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { value in
                Text(value.settingsLabel).tag(value)
            }
        }
    }
}

extension Appearance.Theme: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

extension Appearance.ShowOnScreen: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .active: return String(localized: "Active screen")
        case .withMouse: return String(localized: "Screen with mouse")
        case .main: return String(localized: "Main screen")
        }
    }
}

extension AppScope: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .all: return String(localized: "All apps")
        case .activeApp: return String(localized: "Active app")
        }
    }
}

extension SpaceScope: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .all: return String(localized: "All Spaces")
        case .current: return String(localized: "Current Space")
        }
    }
}

extension ScreenScope: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .all: return String(localized: "All screens")
        case .active: return String(localized: "Active screen")
        case .withMouse: return String(localized: "Screen with mouse")
        }
    }
}

extension SwitcherStyle: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .thumbnails: return String(localized: "Thumbnails")
        case .appIcons: return String(localized: "App icons")
        case .titles: return String(localized: "Titles")
        case .taskView: return String(localized: "Task view")
        }
    }

    var settingsSymbol: String {
        switch self {
        case .thumbnails: return "rectangle.on.rectangle"
        case .appIcons: return "square.grid.2x2"
        case .titles: return "list.bullet"
        case .taskView: return "rectangle.grid.3x2"
        }
    }
}

extension SwitcherSize: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .auto: return String(localized: "Auto")
        }
    }
}

extension ReleaseBehavior: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .focusSelection: return String(localized: "Focus selection")
        case .keepOpen: return String(localized: "Keep open")
        }
    }
}

extension AppException.HideRule: SettingsChoice {
    var settingsLabel: String {
        switch self {
        case .never: return String(localized: "Never")
        case .always: return String(localized: "Always")
        case .whenNoOpenWindows: return String(localized: "When no open windows")
        }
    }
}

@MainActor
struct SettingsWarning: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
