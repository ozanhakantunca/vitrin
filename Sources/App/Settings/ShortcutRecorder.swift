import AppKit
import Combine
import SwiftUI
import VitrinCore

/// Integration contract: observe `shared.$isRecording` on the main actor and pause
/// the global hotkey event tap BEFORE recording begins. Resume when it becomes false.
/// A global tap runs before a local NSEvent monitor and otherwise swallows shortcuts.
@MainActor
final class SettingsRecorderState: ObservableObject {
    static let shared = SettingsRecorderState()

    @Published private(set) var isRecording = false
    @Published private(set) var owner: UUID?
    @Published private(set) var prompt = String(localized: "Press a shortcut")
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onRecord: ((KeyCombo?) -> Void)?
    private var functionKeyIsHeld = false

    private init() {}

    func begin(owner: UUID, onRecord: @escaping (KeyCombo?) -> Void) {
        cancel()
        self.owner = owner
        self.onRecord = onRecord
        functionKeyIsHeld = NSEvent.modifierFlags.contains(.function)
        prompt = String(localized: "Press a shortcut")
        // @Published emits synchronously: the subscriber must pause the tap here,
        // without dispatching asynchronously, before the next physical key event.
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRecording else { return false }
                if event.type == .flagsChanged {
                    if event.keyCode == 63 {
                        self.functionKeyIsHeld = event.modifierFlags.contains(.function)
                    }
                    let symbols = SettingsRecordedKey.modifiers(from: event.modifierFlags).symbols
                    self.prompt = symbols.isEmpty ? String(localized: "Press a shortcut") : symbols
                    return true
                }
                // Arrow/navigation and F-key events carry .function even without
                // a held Fn key. Only retain it when it is physically held.
                var flags = event.modifierFlags
                if !self.functionKeyIsHeld { flags.remove(.function) }
                switch SettingsRecordedKey.interpret(keyCode: event.keyCode, flags: flags) {
                case .cancel: self.cancel()
                case .clear: self.finish(nil)
                case .needsModifier: self.prompt = String(localized: "Hold at least one modifier key")
                case .shortcut(let combo): self.finish(combo)
                }
                return true
            }
            return consumed ? nil : event
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }

    func cancel(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onRecord = nil
        functionKeyIsHeld = false
        self.owner = nil
        isRecording = false
    }

    private func finish(_ combo: KeyCombo?) {
        let callback = onRecord
        // Persist while the tap is still paused, so applying the edited settings
        // cannot accidentally use the old shortcut registration.
        callback?(combo)
        cancel()
    }
}

@MainActor
struct ShortcutRecorder: View {
    @Binding var trigger: KeyCombo?
    @ObservedObject private var recorder = SettingsRecorderState.shared
    @State private var owner = UUID()

    private var isRecording: Bool { recorder.isRecording && recorder.owner == owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Trigger"))
                Spacer()
                Button {
                    if isRecording {
                        recorder.cancel(owner: owner)
                    } else {
                        recorder.begin(owner: owner) { trigger = $0 }
                    }
                } label: {
                    Text(isRecording ? recorder.prompt : SettingsShortcutLabel.text(trigger))
                        .monospaced()
                        .frame(minWidth: 160)
                }
                .accessibilityLabel(String(localized: "Record trigger shortcut"))
                .accessibilityValue(isRecording ? recorder.prompt : SettingsShortcutLabel.text(trigger))
                .accessibilityHint(String(localized: "Click, then press a key with at least one modifier. Escape cancels. Delete clears."))
                .help(String(localized: "Click to record a shortcut"))
            }
            Text(isRecording
                 ? String(localized: "Escape cancels. Delete clears. A modifier is required.")
                 : String(localized: "Click the shortcut to record a new combination."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear { recorder.cancel(owner: owner) }
    }
}
