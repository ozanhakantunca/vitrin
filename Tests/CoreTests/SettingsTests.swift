import Foundation
import Testing
@testable import VitrinCore

@Test func versionIsSet() {
    #expect(!VitrinCore.version.isEmpty)
}

// MARK: - KeyCombo

@Suite struct KeyComboTests {
    @Test(arguments: [
        ("option+tab", "option+tab"),
        ("Alt + Tab", "option+tab"),
        ("cmd+shift+tab", "shift+command+tab"),
        ("⌥+keyAboveTab", "option+keyAboveTab"),
        ("ctrl+opt+keyCode:48", "control+option+tab"),
        ("command+keyCode:200", "command+keyCode:200"),
        ("fn+f5", "fn+f5"),
        ("esc", "escape"),
    ])
    func parsesToCanonicalString(input: String, canonical: String) throws {
        let combo = try #require(KeyCombo(string: input))
        #expect(combo.stringValue == canonical)
        #expect(KeyCombo(string: canonical) == combo)
    }

    @Test(arguments: ["", "option+", "hyper+tab", "option+nosuchkey", "option+keyCode:99999"])
    func rejectsInvalidStrings(input: String) {
        #expect(KeyCombo(string: input) == nil)
    }

    @Test func encodesAsHumanReadableString() throws {
        let combo = KeyCombo(modifiers: [.command, .option], key: .keyAboveTab)
        let data = try JSONEncoder().encode([combo])
        #expect(String(decoding: data, as: UTF8.self) == #"["option+command+keyAboveTab"]"#)
        #expect(try JSONDecoder().decode([KeyCombo].self, from: data) == [combo])
    }

    @Test func keyAboveTabConflictsWithGraveAndSection() {
        let semantic = KeyCombo(modifiers: .option, key: .keyAboveTab)
        #expect(semantic.conflicts(with: KeyCombo(modifiers: .option, key: .grave)))
        #expect(semantic.conflicts(with: KeyCombo(modifiers: .option, key: .code(KeyCode.isoSection))))
        #expect(!semantic.conflicts(with: KeyCombo(modifiers: .command, key: .grave)))
        #expect(!semantic.conflicts(with: KeyCombo(modifiers: .option, key: .tab)))
    }

    @Test func resolvesKeyAboveTabPerKeyboardType() {
        #expect(KeyCombo.Key.keyAboveTab.keyCode(isISOKeyboard: false) == KeyCode.grave)
        #expect(KeyCombo.Key.keyAboveTab.keyCode(isISOKeyboard: true) == KeyCode.isoSection)
        #expect(KeyCombo.Key.tab.keyCode(isISOKeyboard: true) == KeyCode.tab)
    }

    @Test func displayString() {
        #expect(KeyCombo(modifiers: .option, key: .tab).displayString == "⌥⇥")
        #expect(KeyCombo(modifiers: [.shift, .command], key: .code(0x00)).displayString == "⇧⌘A")
    }
}

// MARK: - Defaults & JSON

@Suite struct AppSettingsTests {
    @Test func defaultProfiles() throws {
        let profiles = AppSettings.defaults.profiles
        #expect(profiles.map(\.id) == ["all-windows", "current-app", "task-view"])

        let all = profiles[0]
        #expect(all.isEnabled && all.trigger == KeyCombo(modifiers: .option, key: .tab) && all.style == .thumbnails)
        #expect(all.filters == WindowFilters())

        let app = profiles[1]
        #expect(app.isEnabled && app.trigger == KeyCombo(modifiers: .option, key: .keyAboveTab))
        #expect(app.filters.apps == .activeApp)

        let task = profiles[2]
        #expect(!task.isEnabled && task.trigger == KeyCombo(modifiers: .command, key: .tab))
        #expect(task.style == .taskView && task.size == .large)
    }

    @Test func defaultsHaveNoValidationIssues() {
        #expect(AppSettings.defaults.validate().isEmpty)
    }

    @Test func jsonRoundTrip() throws {
        var settings = AppSettings.defaults
        settings.profiles.append(ShortcutProfile(
            id: "custom", name: "Mouse screen", trigger: KeyCombo(modifiers: [.control, .option], key: .code(0x00)),
            filters: WindowFilters(spaces: .current, screens: .withMouse, includeMinimized: false, includeHidden: false, includeFullscreen: false),
            style: .titles, size: .small, releaseBehavior: .keepOpen))
        settings.profiles.append(ShortcutProfile(id: "unbound", name: "No shortcut yet", trigger: nil))
        settings.appExceptions = [AppException(bundleIdentifier: "com.parallels.desktop.console", hide: .whenNoOpenWindows, ignoreShortcutsWhenFrontmost: true)]
        settings.appearance = Appearance(theme: .dark, showOnScreen: .withMouse)
        settings.launchAtLogin = true
        settings.showMenuBarIcon = false
        settings.showDesktopsInTaskView = false

        let data = try ConfigStore.encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func encodedJSONIsDotfileFriendly() throws {
        let text = String(decoding: try ConfigStore.encode(.defaults), as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\n  \"appExceptions\""))            // pretty-printed
        #expect(text.contains("\"trigger\" : \"option+tab\""))       // human-readable shortcut
        #expect(text.contains("\"trigger\" : \"option+keyAboveTab\""))
        let topLevelKeys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { $0.split(separator: "\"")[1] }
        #expect(topLevelKeys == topLevelKeys.sorted())               // sorted keys
    }
}

// MARK: - Tolerant decoding

@Suite struct TolerantDecodingTests {
    func load(_ json: String) -> ConfigLoadResult {
        ConfigStore(url: URL(fileURLWithPath: "/nonexistent/config.json")).decode(Data(json.utf8))
    }

    @Test func emptyObjectGivesDefaults() {
        let result = load("{}")
        #expect(result.origin == .file && result.error == nil && result.warnings.isEmpty)
        #expect(result.settings == .defaults)
    }

    @Test func missingKeysUseDefaults() {
        let result = load(#"{ "launchAtLogin": true, "profiles": [ { "name": "Mine", "trigger": "control+tab" } ] }"#)
        #expect(result.warnings.isEmpty)
        #expect(result.settings.launchAtLogin)
        #expect(result.settings.showDesktopsInTaskView)
        #expect(result.settings.showMenuBarIcon == AppSettings.defaults.showMenuBarIcon)
        #expect(result.settings.appearance == Appearance())
        let profile = result.settings.profiles[0]
        #expect(result.settings.profiles.count == 1)
        #expect(profile.name == "Mine" && profile.isEnabled && profile.style == .thumbnails && profile.filters == WindowFilters())
        #expect(!profile.id.isEmpty)
    }

    @Test func explicitEmptyProfilesIsRespected() {
        #expect(load(#"{ "profiles": [] }"#).settings.profiles.isEmpty)
    }

    @Test func unknownKeysAreIgnored() {
        let result = load(#"{ "futureFeature": { "x": 1 }, "appearance": { "theme": "dark", "blur": 3 } }"#)
        #expect(result.error == nil && result.warnings.isEmpty)
        #expect(result.settings.appearance.theme == .dark)
    }

    @Test func invalidValuesFallBackPerFieldWithWarnings() {
        let result = load("""
        { "launchAtLogin": "yes",
          "showDesktopsInTaskView": "yes",
          "appearance": { "theme": "sepia" },
          "profiles": [
            { "id": "a", "name": "A", "trigger": "hyper+tab", "style": "carousel", "filters": { "spaces": "current", "apps": 7 } },
            42,
            { "id": "b", "name": "B", "trigger": "option+tab" }
          ],
          "appExceptions": [ { "hide": "always" }, { "bundleIdentifier": "com.vmware.fusion", "hide": "always" } ] }
        """)
        #expect(result.origin == .file && result.error == nil)
        let s = result.settings
        #expect(s.launchAtLogin == false)
        #expect(s.showDesktopsInTaskView)
        #expect(s.appearance.theme == .system)
        #expect(s.profiles.map(\.id) == ["a", "b"])           // the bad element (42) is skipped, not fatal
        #expect(s.profiles[0].trigger == nil)                  // unparseable shortcut → unassigned
        #expect(s.profiles[0].style == .thumbnails)
        #expect(s.profiles[0].filters.spaces == .current)      // valid sibling fields survive
        #expect(s.profiles[0].filters.apps == .all)
        #expect(s.appExceptions == [AppException(bundleIdentifier: "com.vmware.fusion", hide: .always)])

        let warnings = result.warnings.joined(separator: "\n")
        for path in ["launchAtLogin", "showDesktopsInTaskView", "appearance.theme", "profiles[0].trigger", "profiles[0].style",
                     "profiles[0].filters.apps", "profiles[1]", "appExceptions[0]"] {
            #expect(warnings.contains(path), "missing warning for \(path)")
        }
    }

    @Test func json5CommentsAndTrailingCommasAreAccepted() {
        let result = load("""
        {
          // hand-edited
          "launchAtLogin": true,
        }
        """)
        #expect(result.origin == .file && result.error == nil)
        #expect(result.settings.launchAtLogin)
    }

    @Test func olderSchemaIsMigrated() throws {
        // Pretend schema 1 → 2 renamed "menuBarIcon" to "showMenuBarIcon".
        let migrator = ConfigMigrator(currentVersion: 2, steps: [
            1: { json in
                json["showMenuBarIcon"] = json.removeValue(forKey: "menuBarIcon")
            },
        ])
        let store = ConfigStore(url: URL(fileURLWithPath: "/nonexistent/config.json"), migrator: migrator)
        let result = store.decode(Data(#"{ "schemaVersion": 1, "menuBarIcon": false }"#.utf8))
        #expect(result.migratedFromVersion == 1)
        #expect(result.settings.schemaVersion == 2)
        #expect(result.settings.showMenuBarIcon == false)
        #expect(!result.isFromNewerVersion)
    }

    @Test func newerSchemaIsFlagged() {
        let result = load(#"{ "schemaVersion": 99, "launchAtLogin": true }"#)
        #expect(result.isFromNewerVersion)
        #expect(result.settings.launchAtLogin)
        #expect(result.settings.schemaVersion == 99)
        #expect(!result.warnings.isEmpty)
    }
}

// MARK: - ConfigStore file handling

@Suite struct ConfigStoreFileTests {
    let directory: URL
    let store: ConfigStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vitrin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConfigStore(url: directory.appendingPathComponent("vitrin/config.json"),
                            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path).sorted()
    }

    @Test func missingFileGivesDefaults() {
        let result = store.load()
        #expect(result.origin == .defaultsNoFile && result.error == nil)
        #expect(result.settings == .defaults)
    }

    @Test func saveCreatesDirectoryAndRoundTrips() throws {
        var settings = AppSettings.defaults
        settings.profiles[2].isEnabled = true
        settings.profiles[0].trigger = KeyCombo(modifiers: .control, key: .tab)
        try store.save(settings)
        let result = store.load()
        #expect(result.origin == .file && result.error == nil && result.warnings.isEmpty)
        #expect(result.settings == settings)
    }

    @Test func saveSkipsIdenticalContent() throws {
        try store.save(.defaults)
        let before = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: store.url.path)
        try store.save(.defaults)
        let after = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
        #expect(before != nil)
        #expect(after == Date(timeIntervalSince1970: 0))
    }

    @Test func saveWritesThroughSymlink() throws {
        let real = directory.appendingPathComponent("dotfiles/vitrin.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: real)

        var settings = AppSettings.defaults
        settings.launchAtLogin = true
        try store.save(settings)

        let values = try store.url.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: real)).launchAtLogin)
    }

    @Test func corruptFileIsMovedAsideAndDefaultsAreUsed() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data(#"{ "profiles": [ { "name": "oops" "#.utf8)
        try garbage.write(to: store.url)

        let result = store.load()
        #expect(result.origin == .defaultsAfterError)
        #expect(result.settings == .defaults)
        guard case let .corrupt(path, _, backupPath)? = result.error else {
            Issue.record("expected .corrupt, got \(String(describing: result.error))")
            return
        }
        #expect(path == store.url.path)
        let backup = try #require(backupPath)
        #expect(backup.hasSuffix("config.json.corrupt-20270115T080000Z"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == garbage)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))

        // A second corrupt file in the same second gets a distinct backup name.
        try garbage.write(to: store.url)
        guard case let .corrupt(_, _, secondBackup)? = store.load().error else {
            Issue.record("expected .corrupt")
            return
        }
        #expect(secondBackup?.hasSuffix("corrupt-20270115T080000Z-1") == true)
        #expect(try contents() == ["config.json.corrupt-20270115T080000Z", "config.json.corrupt-20270115T080000Z-1"])
    }

    @Test func nonObjectTopLevelIsCorrupt() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[1, 2]".utf8).write(to: store.url)
        let result = store.load()
        guard case .corrupt? = result.error else {
            Issue.record("expected .corrupt")
            return
        }
        #expect(result.settings == .defaults)
    }

    @Test func emptyFileGivesDefaultsWithoutError() throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(" \n".utf8).write(to: store.url)
        let result = store.load()
        #expect(result.origin == .defaultsNoFile && result.error == nil)
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func failingMigrationBacksUpAndFallsBack() throws {
        struct Boom: Error {}
        let failing = ConfigStore(url: store.url, migrator: ConfigMigrator(currentVersion: 2, steps: [1: { _ in throw Boom() }]),
                                  now: { Date(timeIntervalSince1970: 1_800_000_000) })
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{ "schemaVersion": 1 }"#.utf8).write(to: store.url)
        let result = failing.load()
        guard case let .migrationFailed(version, _, backup)? = result.error else {
            Issue.record("expected .migrationFailed")
            return
        }
        #expect(version == 1)
        #expect(backup?.hasSuffix("config.json.pre-migration-20270115T080000Z") == true)
        #expect(FileManager.default.fileExists(atPath: store.url.path)) // original left in place
    }
}

// MARK: - Validation

@Suite struct ValidationTests {
    func profile(_ id: String, _ trigger: String?, enabled: Bool = true) -> ShortcutProfile {
        ShortcutProfile(id: id, name: id, isEnabled: enabled, trigger: trigger.flatMap(KeyCombo.init(string:)))
    }

    @Test func reportsConflictsBetweenEnabledProfilesOnly() {
        let settings = AppSettings(profiles: [
            profile("a", "option+tab"),
            profile("b", "alt+tab"),
            profile("c", "option+tab", enabled: false),
            profile("d", nil),
            profile("e", "option+keyAboveTab"),
            profile("f", "option+grave"),
            profile("g", "command+tab"),
        ])
        let issues = settings.validate()
        #expect(issues.count == 2)
        #expect(issues.contains(.conflictingTriggers(profileID: "a", otherProfileID: "b", trigger: KeyCombo(modifiers: .option, key: .tab))))
        #expect(issues.contains(.conflictingTriggers(profileID: "e", otherProfileID: "f", trigger: KeyCombo(modifiers: .option, key: .keyAboveTab))))
    }

    @Test func enablingTaskViewNextToNativeDefaultsIsFine() {
        var settings = AppSettings.defaults
        settings.profiles[2].isEnabled = true
        #expect(settings.validate().isEmpty)
        settings.profiles[2].trigger = KeyCombo(modifiers: .option, key: .tab)
        #expect(settings.validate() == [.conflictingTriggers(profileID: "all-windows", otherProfileID: "task-view",
                                                             trigger: KeyCombo(modifiers: .option, key: .tab))])
    }

    @Test func reportsDuplicateIDsAndExceptions() {
        let settings = AppSettings(
            profiles: [profile("x", "option+tab"), profile("x", "control+tab")],
            appExceptions: [AppException(bundleIdentifier: "com.a"), AppException(bundleIdentifier: "com.a", hide: .always)]
        )
        #expect(Set(settings.validate()) == [.duplicateProfileID("x"), .duplicateAppException(bundleIdentifier: "com.a")])
    }

    @Test func unlimitedProfiles() {
        let many = (0..<50).map { i in profile("p\(i)", "control+option+keyCode:\(i)") }
        let settings = AppSettings(profiles: many)
        #expect(settings.activeProfiles.count == 50)
        #expect(settings.validate().isEmpty)
    }
}
