import SwiftUI
import VitrinCore

@MainActor
struct ShortcutsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedID: String?
    @State private var deletingID: String?

    private var selectedProfile: ShortcutProfile? {
        store.settings.profiles.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selectedID) {
                    ForEach(store.settings.profiles) { profile in
                        HStack(spacing: 8) {
                            Toggle(String(localized: "Enable \(profile.name)"), isOn: profileBinding(profile.id, \.isEnabled, fallback: profile.isEnabled))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).lineLimit(1)
                                Text(SettingsShortcutLabel.text(profile.trigger))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .tag(profile.id)
                        .padding(.vertical, 3)
                    }
                    .onMove { offsets, destination in
                        store.settings.profiles.move(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel(String(localized: "Shortcut profiles"))
                HStack(spacing: 12) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help(String(localized: "Add profile"))
                        .accessibilityLabel(String(localized: "Add profile"))
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .disabled(selectedProfile == nil)
                        .help(String(localized: "Duplicate profile"))
                        .accessibilityLabel(String(localized: "Duplicate profile"))
                    Button { deletingID = selectedID } label: { Image(systemName: "minus") }
                        .disabled(selectedProfile == nil)
                        .help(String(localized: "Delete profile"))
                        .accessibilityLabel(String(localized: "Delete profile"))
                    Spacer(minLength: 0)
                    Button { moveSelection(by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(!canMove(by: -1))
                        .help(String(localized: "Increase priority"))
                        .accessibilityLabel(String(localized: "Increase priority"))
                    Button { moveSelection(by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(!canMove(by: 1))
                        .help(String(localized: "Decrease priority"))
                        .accessibilityLabel(String(localized: "Decrease priority"))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                Text(String(localized: "Unlimited profiles. Drag to reorder; the first matching profile has priority."))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 10)
            }
            .frame(width: 240)
            Divider()
            if let profile = selectedProfile {
                ShortcutProfileEditor(store: store, profileID: profile.id)
                    .id(profile.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "keyboard").font(.largeTitle).accessibilityHidden(true)
                    Text(String(localized: "Select a profile or add a new one."))
                    Button(String(localized: "Add profile")) { add() }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { repairSelection() }
        .onChange(of: store.settings.profiles.map(\.id)) { _ in repairSelection() }
        .alert(String(localized: "Delete this profile?"), isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }
        )) {
            Button(String(localized: "Cancel"), role: .cancel) { deletingID = nil }
            Button(String(localized: "Delete"), role: .destructive) {
                if let deletingID { store.settings.profiles.removeAll { $0.id == deletingID } }
                deletingID = nil
                repairSelection()
            }
        } message: {
            Text(String(localized: "This removes the profile and its shortcut. Other profiles are kept."))
        }
    }

    private func profileBinding<Value>(_ id: String, _ keyPath: WritableKeyPath<ShortcutProfile, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            store.settings.profiles.first { $0.id == id }?[keyPath: keyPath] ?? fallback
        }, set: { value in
            guard let index = store.settings.profiles.firstIndex(where: { $0.id == id }) else { return }
            store.settings.profiles[index][keyPath: keyPath] = value
        })
    }

    private func repairSelection() {
        if !store.settings.profiles.contains(where: { $0.id == selectedID }) {
            selectedID = store.settings.profiles.first?.id
        }
    }

    private func add() {
        let profile = SettingsProfileFactory.make()
        store.settings.profiles.append(profile)
        selectedID = profile.id
    }

    private func duplicate() {
        guard let profile = selectedProfile,
              let index = store.settings.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let copy = SettingsProfileFactory.duplicate(profile)
        store.settings.profiles.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    private func canMove(by offset: Int) -> Bool {
        guard let index = store.settings.profiles.firstIndex(where: { $0.id == selectedID }) else { return false }
        return store.settings.profiles.indices.contains(index + offset)
    }

    private func moveSelection(by offset: Int) {
        guard canMove(by: offset), let index = store.settings.profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        store.settings.profiles.swapAt(index, index + offset)
    }
}

@MainActor
private struct ShortcutProfileEditor: View {
    @ObservedObject var store: SettingsStore
    let profileID: String

    private var profile: ShortcutProfile? { store.settings.profiles.first { $0.id == profileID } }

    private func binding<Value>(_ keyPath: WritableKeyPath<ShortcutProfile, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            profile?[keyPath: keyPath] ?? fallback
        }, set: { value in
            guard let index = store.settings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
            store.settings.profiles[index][keyPath: keyPath] = value
        })
    }

    var body: some View {
        Form {
            Section(String(localized: "Shortcut")) {
                TextField(String(localized: "Name"), text: binding(\.name, fallback: ""))
                ShortcutRecorder(trigger: binding(\.trigger, fallback: nil))
                ForEach(warnings, id: \.self) { SettingsWarning(message: $0) }
            }
            Section(String(localized: "Filters")) {
                SettingsPicker(title: String(localized: "Apps"), selection: binding(\.filters.apps, fallback: .all))
                SettingsPicker(title: String(localized: "Spaces"), selection: binding(\.filters.spaces, fallback: .all))
                SettingsPicker(title: String(localized: "Screens"), selection: binding(\.filters.screens, fallback: .all))
                Toggle(String(localized: "Include minimized windows"), isOn: binding(\.filters.includeMinimized, fallback: true))
                Toggle(String(localized: "Include hidden apps"), isOn: binding(\.filters.includeHidden, fallback: true))
                Toggle(String(localized: "Include fullscreen windows"), isOn: binding(\.filters.includeFullscreen, fallback: true))
            }
            Section(String(localized: "Presentation")) {
                Picker(String(localized: "Style"), selection: binding(\.style, fallback: .thumbnails)) {
                    ForEach(SwitcherStyle.allCases, id: \.self) { style in
                        Label(style.settingsLabel, systemImage: style.settingsSymbol).tag(style)
                    }
                }
                SettingsPicker(title: String(localized: "Size"), selection: binding(\.size, fallback: .auto))
                SettingsPicker(title: String(localized: "On modifier release"), selection: binding(\.releaseBehavior, fallback: .focusSelection))
            }
        }
        .formStyle(.grouped)
    }

    private var warnings: [String] {
        var result = store.issues.compactMap { issue -> String? in
            switch issue {
            case let .conflictingTriggers(a, b, trigger) where a == profileID || b == profileID:
                let otherID = a == profileID ? b : a
                let otherName = store.settings.profiles.first { $0.id == otherID }?.name ?? otherID
                let label = SettingsShortcutLabel.text(trigger)
                return String(localized: "\(label) conflicts with “\(otherName)”. The earlier profile has priority.")
            case .duplicateProfileID(let id) where id == profileID:
                return String(localized: "This profile ID is duplicated in the config file. Give each profile a unique ID.")
            case let .shiftReverseConflict(a, b, trigger) where a == profileID || b == profileID:
                let shiftedName = store.settings.profiles.first { $0.id == a }?.name ?? a
                let baseName = store.settings.profiles.first { $0.id == b }?.name ?? b
                let label = SettingsShortcutLabel.text(trigger)
                return String(localized: "“\(shiftedName)” uses \(label), which also reverses “\(baseName)”. The earlier profile has priority.")
            default:
                return nil
            }
        }
        // Explain Shift's dual purpose even if there is no current conflict.
        if profile?.trigger?.modifiers.contains(.shift) == true {
            result.append(String(localized: "Shift is also used for reverse cycling. This trigger may clash with another profile’s reverse shortcut."))
        }
        return Array(Set(result)).sorted()
    }
}
