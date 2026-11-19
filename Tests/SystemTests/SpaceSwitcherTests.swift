import Foundation
import Testing
import VitrinCore
@testable import VitrinPrivate
@testable import VitrinSystem

@MainActor
struct SpaceSwitcherTests {
    @Test func mapsManagedSpacesInMissionControlOrder() {
        let spaces: [SkyLight.ManagedSpace] = [
            .init(id: 8, type: .other(9), uuid: nil),
            .init(id: 20, type: .user, uuid: nil),
            .init(id: 13, type: .fullscreen, uuid: nil),
            .init(id: 4, type: .system, uuid: nil),
            .init(id: 2, type: .user, uuid: nil)
        ]
        let display = SkyLight.ManagedDisplay(identifier: "Main", currentSpaceID: 13, spaces: spaces)
        let desktops = SpaceSwitcher.desktops(in: display)

        #expect(desktops.map(\.id) == [20, 13, 2])
        #expect(desktops.map(\.index) == [0, 1, 2])
        #expect(desktops.map(\.kind) == [.desktop(number: 1), .fullscreen, .desktop(number: 2)])
        #expect(desktops.map(\.isCurrent) == [false, true, false])
        #expect(desktops.allSatisfy { $0.displayIdentifier == "Main" })
    }
}

@MainActor
struct TemporarySpaceHotKeysTests {
    private let suiteName = "vitrin.tests.spaces.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let key = TemporarySpaceHotKeys.defaultsKey

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    @Test func recordsBeforeEnablingAndRestoresAfterRepeatedPosts() async {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backend = FakeSpaceHotKeys(states: [.moveLeftASpace: false, .moveRightASpace: true])
        var enables = 0
        var restores = 0
        backend.onSet = { enabled, hotKey in
            #expect(hotKey == .moveLeftASpace)
            if enabled {
                enables += 1
                #expect(defaults.array(forKey: key) as? [Int] == [79])
            } else {
                restores += 1
            }
        }
        let hotKeys = TemporarySpaceHotKeys(backend: backend, defaults: defaults, restoreDelay: .zero)

        let posted = hotKeys.post(whileEnabled: .moveLeftASpace) {
            #expect(backend.isEnabled(.moveLeftASpace) == true)
            #expect(defaults.array(forKey: key) as? [Int] == [79])
        }
        #expect(posted)
        #expect(hotKeys.post(whileEnabled: .moveLeftASpace) {})
        #expect(enables == 1)
        #expect(backend.isEnabled(.moveLeftASpace) == true)

        let deadline = ContinuousClock.now + .seconds(1)
        while restores == 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(restores == 1)
        #expect(backend.isEnabled(.moveLeftASpace) == false)
        #expect(backend.isEnabled(.moveRightASpace) == true)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test func recoversRecordedKeysAndKeepsFailedRestorations() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([79, 81, 118], forKey: key)
        let backend = FakeSpaceHotKeys(states: [
            .moveLeftASpace: true, .moveRightASpace: false, SymbolicHotKey.switchToDesktop[0]: true
        ])
        backend.failedRestores = [SymbolicHotKey.switchToDesktop[0]]
        let hotKeys = TemporarySpaceHotKeys(backend: backend, defaults: defaults)

        #expect(backend.isEnabled(.moveLeftASpace) == false)
        #expect(backend.isEnabled(.moveRightASpace) == false)
        #expect(defaults.array(forKey: key) as? [Int] == [118])

        backend.failedRestores.removeAll()
        hotKeys.restoreAll()
        #expect(backend.isEnabled(SymbolicHotKey.switchToDesktop[0]) == false)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test func enabledShortcutsStayEnabledAndFailedEnablesDoNotPost() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backend = FakeSpaceHotKeys(states: [.moveLeftASpace: true, .moveRightASpace: false])
        backend.failEnables = true
        let hotKeys = TemporarySpaceHotKeys(backend: backend, defaults: defaults)

        var posts = 0
        #expect(hotKeys.post(whileEnabled: .moveLeftASpace) { posts += 1 })
        #expect(!hotKeys.post(whileEnabled: .moveRightASpace) { posts += 1 })
        hotKeys.restoreAll()
        #expect(posts == 1)
        #expect(backend.isEnabled(.moveLeftASpace) == true)
        #expect(backend.isEnabled(.moveRightASpace) == false)
        #expect(defaults.object(forKey: key) == nil)
    }
}

private final class FakeSpaceHotKeys: SymbolicHotKeyBackend, @unchecked Sendable {
    private var states: [SymbolicHotKey: Bool]
    var onSet: ((Bool, SymbolicHotKey) -> Void)?
    var failedRestores: Set<SymbolicHotKey> = []
    var failEnables = false

    init(states: [SymbolicHotKey: Bool]) {
        self.states = states
    }

    func isEnabled(_ hotKey: SymbolicHotKey) -> Bool? { states[hotKey] }

    func setEnabled(_ enabled: Bool, _ hotKeys: [SymbolicHotKey]) -> Bool {
        for hotKey in hotKeys {
            onSet?(enabled, hotKey)
            if enabled ? failEnables : failedRestores.contains(hotKey) { return false }
            states[hotKey] = enabled
        }
        return true
    }
}
