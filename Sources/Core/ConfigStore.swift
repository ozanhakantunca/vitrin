import Foundation

/// Errors surfaced by `ConfigStore`. Loading never throws; errors ride along in `ConfigLoadResult`.
public enum ConfigError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The file exists but couldn't be read (permissions, I/O). It was left untouched.
    case unreadable(path: String, reason: String)
    /// The file isn't valid JSON (or not a JSON object). It was moved/copied to `backupPath`.
    case corrupt(path: String, reason: String, backupPath: String?)
    /// A schema migration step failed. The original file was backed up to `backupPath`.
    case migrationFailed(fromVersion: Int, reason: String, backupPath: String?)
    case writeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            return "Couldn't read \(path): \(reason)"
        case let .corrupt(path, reason, backup):
            return "\(path) is not valid JSON (\(reason)); " + (backup.map { "moved it to \($0)" } ?? "backup failed")
        case let .migrationFailed(version, reason, backup):
            return "Couldn't migrate config from schema \(version): \(reason)" + (backup.map { "; original saved at \($0)" } ?? "")
        case let .writeFailed(path, reason):
            return "Couldn't write \(path): \(reason)"
        }
    }
}

public struct ConfigLoadResult: Sendable {
    public enum Origin: Sendable, Hashable {
        /// Settings came from the file (possibly with field-level warnings).
        case file
        /// No config file (or an empty one) — built-in defaults.
        case defaultsNoFile
        /// The file was unusable — built-in defaults; see `error`.
        case defaultsAfterError
    }

    public var settings: AppSettings
    public var origin: Origin
    public var error: ConfigError?
    /// Non-fatal problems, e.g. `profiles[1].style: unknown value; using default`.
    public var warnings: [String]
    /// Set when the file was written by an older schema and migrated in memory (not yet saved).
    public var migratedFromVersion: Int?
    /// The file declares a newer schema than this build understands. Saving would drop data the
    /// newer version wrote, so the app should avoid overwriting it automatically.
    public var isFromNewerVersion: Bool
}

/// Schema migrations, applied to the raw JSON object before decoding.
public struct ConfigMigrator: Sendable {
    /// Migrates a JSON object from version `n` to `n + 1` in place.
    public typealias Step = @Sendable (_ json: inout [String: Any]) throws -> Void

    public var currentVersion: Int
    /// Keyed by the version the step migrates *from*. Versions without a step only get their number bumped.
    public var steps: [Int: Step]

    public init(currentVersion: Int, steps: [Int: Step] = [:]) {
        self.currentVersion = currentVersion
        self.steps = steps
    }

    /// The production migration chain. Add `steps[1] = { json in … }` when introducing schema 2.
    public static let standard = ConfigMigrator(currentVersion: AppSettings.currentSchemaVersion)

    /// Returns the version the JSON was migrated from, or `nil` if no migration was needed.
    /// A missing `schemaVersion` is treated as current (minimal hand-written configs are fine).
    func migrate(_ json: inout [String: Any]) throws -> Int? {
        let declared = (json["schemaVersion"] as? NSNumber)?.intValue ?? currentVersion
        guard declared < currentVersion else { return nil }
        for version in declared..<currentVersion {
            do {
                try steps[version]?(&json)
            } catch {
                throw MigrationError(fromVersion: version, underlying: error)
            }
        }
        json["schemaVersion"] = currentVersion
        return declared
    }

    struct MigrationError: Error {
        var fromVersion: Int
        var underlying: Error
    }
}

/// Loads and saves `~/.config/vitrin/config.json`.
///
/// - Dotfiles-friendly: pretty-printed, sorted keys, trailing newline; unchanged content is not rewritten;
///   a symlinked config (stow / chezmoi / home-manager) is written through, never replaced.
/// - Reads JSON5 (comments, trailing commas) so hand edits are forgiving. Comments are not preserved on save.
/// - Atomic writes.
public struct ConfigStore: Sendable {
    public let url: URL
    public let migrator: ConfigMigrator
    private let now: @Sendable () -> Date

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("vitrin", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    public init(
        url: URL = ConfigStore.defaultURL,
        migrator: ConfigMigrator = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.migrator = migrator
        self.now = now
    }

    // MARK: Load

    public func load() -> ConfigLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return result(.defaults, .defaultsNoFile)
        } catch {
            return result(.defaults, .defaultsAfterError, error: .unreadable(path: url.path, reason: error.localizedDescription))
        }
        return decode(data)
    }

    /// Decodes config bytes. Exposed for tests and for "import settings" features.
    func decode(_ data: Data) -> ConfigLoadResult {
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            return result(.defaults, .defaultsNoFile)
        }

        var json: [String: Any]
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
            guard let dictionary = object as? [String: Any] else {
                return corrupt(data, reason: "top-level value must be an object")
            }
            json = dictionary
        } catch {
            return corrupt(data, reason: (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }

        var warnings: [String] = []
        let declaredVersion = (json["schemaVersion"] as? NSNumber)?.intValue
        let isNewer = (declaredVersion ?? 0) > migrator.currentVersion
        if isNewer, let declaredVersion {
            warnings.append("config schema \(declaredVersion) is newer than this version of Vitrin understands (\(migrator.currentVersion)); unknown settings are ignored")
        }

        let migratedFrom: Int?
        do {
            migratedFrom = try migrator.migrate(&json)
        } catch let error as ConfigMigrator.MigrationError {
            let backup = try? backUp(data, suffix: "pre-migration", moveOriginal: false)
            return result(.defaults, .defaultsAfterError, error: .migrationFailed(
                fromVersion: error.fromVersion, reason: String(describing: error.underlying), backupPath: backup?.path))
        } catch {
            return result(.defaults, .defaultsAfterError, error: .migrationFailed(fromVersion: declaredVersion ?? 0, reason: "\(error)", backupPath: nil))
        }

        do {
            let normalized = try JSONSerialization.data(withJSONObject: json)
            let collector = DecodingWarnings()
            let decoder = JSONDecoder()
            decoder.userInfo[.vitrinWarnings] = collector
            var settings = try decoder.decode(AppSettings.self, from: normalized)
            if !isNewer { settings.schemaVersion = migrator.currentVersion }
            warnings += collector.messages
            return ConfigLoadResult(settings: settings, origin: .file, error: nil, warnings: warnings,
                                    migratedFromVersion: migratedFrom, isFromNewerVersion: isNewer)
        } catch {
            // Unreachable in practice (every field is tolerant), but never crash.
            return corrupt(data, reason: describe(error))
        }
    }

    private func result(_ settings: AppSettings, _ origin: ConfigLoadResult.Origin, error: ConfigError? = nil) -> ConfigLoadResult {
        ConfigLoadResult(settings: settings, origin: origin, error: error, warnings: [], migratedFromVersion: nil, isFromNewerVersion: false)
    }

    private func corrupt(_ data: Data, reason: String) -> ConfigLoadResult {
        let backup = try? backUp(data, suffix: "corrupt", moveOriginal: true)
        return result(.defaults, .defaultsAfterError, error: .corrupt(path: url.path, reason: reason, backupPath: backup?.path))
    }

    /// Writes `data` to `config.json.<suffix>-<timestamp>` next to `url`. When `moveOriginal` is set and
    /// the config is a regular file (not a symlink into a dotfiles repo), the original is removed so the
    /// next save starts clean.
    private func backUp(_ data: Data, suffix: String, moveOriginal: Bool) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now())
        let directory = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).\(suffix)-\(stamp)"
        var backup = directory.appendingPathComponent(base)
        var counter = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("\(base)-\(counter)")
            counter += 1
        }

        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if moveOriginal && !isSymlink {
            try FileManager.default.moveItem(at: url, to: backup)
        } else {
            try data.write(to: backup, options: .withoutOverwriting)
        }
        return backup
    }

    // MARK: Save

    public static func encode(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        return data
    }

    /// Atomically writes `settings`. Does nothing if the file already has identical content.
    public func save(_ settings: AppSettings) throws {
        // Write through symlinks so dotfile managers keep their link.
        let target = url.resolvingSymlinksInPath()
        do {
            let data = try Self.encode(settings)
            if let existing = try? Data(contentsOf: target), existing == data { return }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw ConfigError.writeFailed(path: target.path, reason: error.localizedDescription)
        }
    }
}
