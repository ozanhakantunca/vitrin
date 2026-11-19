// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Watches `~/.config/vitrin/config.json` for external edits (text editors, dotfile managers) and for
// Vitrin's own atomic saves.
//
// Strategy: every kqueue event (from any watched vnode) restarts a short debounce timer. When it fires the
// watcher *re-establishes all watches from the current filesystem state* and then reads the file; it calls
// `onChange` only if the bytes differ from the last ones it saw. Re-arming before reading means a change that
// races the rescan is either seen by the read or triggers another event on the fresh watches.
//
// Watched vnodes (all opened with O_EVTONLY):
// - the directory containing the config path, and the directory of every hop in its symlink chain
//   (atomic replace = rename into the directory; `ln -sfn` = unlink + symlink in the link's directory);
//   a directory that doesn't exist yet is replaced by its nearest existing ancestor;
// - the parent of any symlinked ancestor directory (so retargeting a folded `~/.config/vitrin` link counts);
// - the final resolved file itself (in-place writes, truncation, deletion).

import Darwin
import Dispatch
import Foundation
import VitrinCore

public final class ConfigFileWatcher: @unchecked Sendable {
    /// The config path as given (may be a symlink).
    public let url: URL
    public let debounceInterval: TimeInterval

    private let onChange: @MainActor @Sendable () -> Void
    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "io.github.ozanhakantunca.vitrin.config-watcher")
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounce: DispatchWorkItem?
    private var lastContents: Data?
    private var isRunning = false

    /// - Parameters:
    ///   - onChange: called on the main queue, at most once per debounce window, when the file's bytes
    ///     changed (including appearing or disappearing).
    public init(
        url: URL = ConfigStore.defaultURL,
        debounceInterval: TimeInterval = 0.2,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.url = url.standardizedFileURL
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        // Sources hold only a weak reference back; cancelling closes their descriptors.
        for source in sources.values { source.cancel() }
        debounce?.cancel()
    }

    /// Starts watching. The current content becomes the baseline (no callback for it). Idempotent.
    public func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
            rearm()
            lastContents = readContents()
        }
    }

    public func stop() {
        queue.sync {
            isRunning = false
            debounce?.cancel()
            debounce = nil
            for source in sources.values { source.cancel() }
            sources = [:]
        }
    }

    /// The paths currently watched (for tests and diagnostics).
    var watchedPaths: Set<String> {
        queue.sync { Set(sources.keys) }
    }

    // MARK: - Private (on `queue`)

    private func scheduleRescan() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rescan() }
        debounce = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func rescan() {
        guard isRunning else { return }
        debounce = nil
        rearm()
        let contents = readContents()
        guard contents != lastContents else { return }
        lastContents = contents
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
    }

    private func readContents() -> Data? {
        // Follows symlinks; nil when missing or unreadable (both count as "changed" against real bytes).
        try? Data(contentsOf: url)
    }

    /// Replaces the watch set with one derived from the current filesystem state. Unchanged paths keep
    /// their existing source unless the vnode behind the path was replaced (checked by device + inode).
    private func rearm() {
        let wanted = Self.watchTargets(for: url)
        for (path, source) in sources where wanted[path] == nil || !Self.isSameVnode(source.handle, path: path) {
            source.cancel()
            sources[path] = nil
        }
        for (path, isDirectory) in wanted where sources[path] == nil {
            if let source = makeSource(path: path, isDirectory: isDirectory) {
                sources[path] = source
            }
        }
    }

    private func makeSource(path: String, isDirectory: Bool) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let mask: DispatchSource.FileSystemEvent = isDirectory
            ? [.write, .delete, .rename, .link, .revoke]
            : [.write, .extend, .attrib, .delete, .rename, .link, .revoke]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleRescan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // MARK: - Path resolution (pure filesystem reads; internal for tests)

    /// Paths to watch → whether each is a directory.
    static func watchTargets(for url: URL, maxHops: Int = 32) -> [String: Bool] {
        var targets: [String: Bool] = [:]
        let fileManager = FileManager.default
        var path = url.standardizedFileURL.path
        var hops = 0
        while true {
            let directory = (path as NSString).deletingLastPathComponent
            if let existing = nearestExistingDirectory(directory) { targets[existing] = true }
            // A symlinked ancestor (e.g. GNU stow folding `~/.config/vitrin` into one link) is watched
            // through its link; its own directory is watched too so retargeting that link is noticed.
            for linkParent in symlinkedAncestorParents(of: directory) { targets[linkParent] = true }
            guard hops < maxHops, let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
                break
            }
            hops += 1
            // Lexical normalisation only: `NSString.standardizingPath` would resolve the next hop itself.
            let absolute = destination.hasPrefix("/")
                ? destination : (directory as NSString).appendingPathComponent(destination)
            path = URL(fileURLWithPath: absolute).standardized.path
        }
        // `path` is now the last hop: a regular file, a missing file (dangling link), or a loop we gave up on.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            targets[path] = false
        }
        return targets
    }

    private static func symlinkedAncestorParents(of directory: String) -> [String] {
        var result: [String] = []
        var prefix = "/"
        for component in (directory as NSString).pathComponents.dropFirst() {
            let candidate = (prefix as NSString).appendingPathComponent(component)
            // Top-level links (/var, /tmp, /etc → /private/…) are fixed by the OS; never watch `/` for them.
            if prefix != "/", (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)) != nil {
                result.append(prefix)
            }
            prefix = candidate
        }
        return result
    }

    private static func nearestExistingDirectory(_ path: String) -> String? {
        var candidate = path
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { return nil }
            candidate = parent
        }
    }

    private static func isSameVnode(_ fd: Int32, path: String) -> Bool {
        var watched = stat()
        var current = stat()
        guard fstat(fd, &watched) == 0, stat(path, &current) == 0 else { return false }
        return watched.st_dev == current.st_dev && watched.st_ino == current.st_ino
    }
}
