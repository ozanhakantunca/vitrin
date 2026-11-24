import Foundation
import Testing
import VitrinCore
@testable import Vitrin

@MainActor struct SettingsStoreTests {
    private func makeStore() throws -> (SettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrin-ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        return (SettingsStore(store: ConfigStore(url: url)), url)
    }

    @Test func liveReloadOfCorruptFileKeepsSettingsAndFile() throws {
        let (store, url) = try makeStore()
        store.settings.launchAtLogin = true
        var changes = 0
        store.onChange = { _ in changes += 1 }

        let garbage = Data(#"{ "launchAtLogin": "#.utf8)
        try garbage.write(to: url)
        store.reloadFromDisk()

        #expect(store.settings.launchAtLogin)
        #expect(changes == 0)
        #expect(store.lastError?.contains("untouched") == true)
        #expect(try Data(contentsOf: url) == garbage)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["config.json"])

        // Once the file is valid again it applies and clears the error.
        try Data(#"{ "launchAtLogin": false }"#.utf8).write(to: url)
        store.reloadFromDisk()
        #expect(!store.settings.launchAtLogin)
        #expect(store.lastError == nil)
        #expect(changes == 1)
    }
}
