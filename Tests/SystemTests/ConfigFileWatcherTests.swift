import Foundation
import Testing
@testable import VitrinSystem

@MainActor
private final class ChangeCounter {
    var count = 0
}

/// Real kqueue watches on a temp directory. Each test owns its directory.
@Suite(.serialized) @MainActor struct ConfigFileWatcherTests {
    private let root: URL

    init() throws {
        // Resolve /var → /private/var so expectations about watched paths are stable.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitrin-watcher-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeWatcher(_ url: URL, counter: ChangeCounter) -> ConfigFileWatcher {
        let watcher = ConfigFileWatcher(url: url, debounceInterval: 0.05) { counter.count += 1 }
        watcher.start()
        return watcher
    }

    /// Polls the main actor (which is where callbacks land) until `condition` holds or the timeout expires.
    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Lets any pending (spurious) callback arrive, for "nothing happened" assertions.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func writeInPlace(_ text: String, to url: URL) throws {
        // O_TRUNC + write on the existing vnode (no rename), like `echo > file`.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func plainInPlaceWriteFiresOnceAndIdenticalContentDoesNot() async throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let counter = ChangeCounter()
        let watcher = makeWatcher(file, counter: counter)
        defer { watcher.stop() }

        try writeInPlace(#"{"launchAtLogin": true}"#, to: file)
        #expect(await eventually { counter.count == 1 })

        // Same bytes again (e.g. our own save of unchanged settings, or `touch`): no callback.
        try writeInPlace(#"{"launchAtLogin": true}"#, to: file)
        await settle()
        #expect(counter.count == 1)

        try writeInPlace(#"{"launchAtLogin": false}"#, to: file)
        #expect(await eventually { counter.count == 2 })
    }

    @Test func atomicReplaceIsFollowedRepeatedly() async throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let counter = ChangeCounter()
        let watcher = makeWatcher(file, counter: counter)
        defer { watcher.stop() }

        for round in 1...3 {
            // write-to-temp + rename, as editors and `ConfigStore.save` do: the watched vnode is replaced.
            try Data(#"{"round": \#(round)}"#.utf8).write(to: file, options: .atomic)
            #expect(await eventually { counter.count == round }, "round \(round)")
        }
        // The watcher must now be on the newest vnode: an in-place write is still noticed.
        try writeInPlace(#"{"round": "in place"}"#, to: file)
        #expect(await eventually { counter.count == 4 })
    }

    @Test func deleteAndRecreateAreBothChanges() async throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let counter = ChangeCounter()
        let watcher = makeWatcher(file, counter: counter)
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: file)
        #expect(await eventually { counter.count == 1 })
        try Data(#"{"back": true}"#.utf8).write(to: file)
        #expect(await eventually { counter.count == 2 })
    }

    @Test func symlinkTargetEditsAndRetargetingAreFollowed() async throws {
        defer { cleanUp() }
        let configDir = root.appendingPathComponent("config", isDirectory: true)
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let a = dotfiles.appendingPathComponent("a.json")
        let b = dotfiles.appendingPathComponent("b.json")
        try Data(#"{"file": "a"}"#.utf8).write(to: a)
        try Data(#"{"file": "b"}"#.utf8).write(to: b)
        let link = configDir.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)

        let counter = ChangeCounter()
        let watcher = makeWatcher(link, counter: counter)
        defer { watcher.stop() }
        #expect(watcher.watchedPaths == [configDir.path, dotfiles.path, a.path])

        // Edit the target in place, then atomically (the target's directory is watched too).
        try writeInPlace(#"{"file": "a", "v": 2}"#, to: a)
        #expect(await eventually { counter.count == 1 })
        try Data(#"{"file": "a", "v": 3}"#.utf8).write(to: a, options: .atomic)
        #expect(await eventually { counter.count == 2 })

        // Retarget the link (`ln -sfn b config.json` = unlink + symlink).
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        #expect(await eventually { counter.count == 3 })
        #expect(await eventually { watcher.watchedPaths.contains(b.path) && !watcher.watchedPaths.contains(a.path) })

        try writeInPlace(#"{"file": "b", "v": 2}"#, to: b)
        #expect(await eventually { counter.count == 4 })

        // The old target no longer matters.
        try writeInPlace(#"{"file": "a", "v": 4}"#, to: a)
        await settle()
        #expect(counter.count == 4)
    }

    @Test func relativeSymlinkChainsAreResolved() throws {
        defer { cleanUp() }
        let real = root.appendingPathComponent("real", isDirectory: true)
        let mid = root.appendingPathComponent("mid", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        for dir in [real, mid, config] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: real.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            atPath: mid.appendingPathComponent("link.json").path, withDestinationPath: "../real/config.json")
        try FileManager.default.createSymbolicLink(
            atPath: config.appendingPathComponent("config.json").path, withDestinationPath: "../mid/link.json")

        let targets = ConfigFileWatcher.watchTargets(for: config.appendingPathComponent("config.json"))
        #expect(targets == [config.path: true, mid.path: true, real.path: true,
                            real.appendingPathComponent("config.json").path: false])
    }

    @Test func symlinkLoopsAndDanglingLinksDoNotHang() throws {
        defer { cleanUp() }
        let loop = root.appendingPathComponent("loop.json")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop.json")
        #expect(ConfigFileWatcher.watchTargets(for: loop) == [root.path: true])

        let dangling = root.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing/config.json")
        #expect(ConfigFileWatcher.watchTargets(for: dangling) == [root.path: true])
    }

    @Test func missingDirectoryIsWatchedFromTheNearestAncestor() async throws {
        defer { cleanUp() }
        let dir = root.appendingPathComponent("dot-config/vitrin", isDirectory: true)
        let file = dir.appendingPathComponent("config.json")
        let counter = ChangeCounter()
        let watcher = makeWatcher(file, counter: counter)
        defer { watcher.stop() }
        #expect(watcher.watchedPaths == [root.path])

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"created": true}"#.utf8).write(to: file, options: .atomic)
        #expect(await eventually { counter.count == 1 })
        #expect(await eventually { watcher.watchedPaths == [dir.path, file.path] })

        // Now fully armed on the new file.
        try writeInPlace(#"{"created": "again"}"#, to: file)
        #expect(await eventually { counter.count == 2 })
    }

    @Test func fileCreatedLaterInAnExistingDirectory() async throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("config.json")
        let counter = ChangeCounter()
        let watcher = makeWatcher(file, counter: counter)
        defer { watcher.stop() }

        try Data(#"{"new": true}"#.utf8).write(to: file)
        #expect(await eventually { counter.count == 1 })
    }

    @Test func stopSilencesTheWatcher() async throws {
        defer { cleanUp() }
        let file = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let counter = ChangeCounter()
        let watcher = makeWatcher(file, counter: counter)
        watcher.stop()
        #expect(watcher.watchedPaths.isEmpty)

        try writeInPlace(#"{"after": "stop"}"#, to: file)
        await settle()
        #expect(counter.count == 0)
    }
}
