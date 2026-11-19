import AppKit
import Foundation

/// Checks GitHub Releases for a newer Vitrin. All failures are silent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let skippedVersionKey = "vitrin.skippedUpdateVersion"
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let initialDelay: TimeInterval = 10

    @Published private(set) var availableUpdate: AvailableUpdate?

    private let currentVersion: String
    private let repo: String
    private let session: URLSession
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(
        currentVersion: String,
        repo: String = "ozanhakantunca/vitrin",
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.repo = repo
        self.session = session
        self.defaults = defaults
    }

    deinit { task?.cancel() }

    func checkNow() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Vitrin/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            availableUpdate = UpdateLogic.parseRelease(
                data, currentVersion: currentVersion,
                skippedVersion: defaults.string(forKey: Self.skippedVersionKey))
        } catch {
            // Offline, rate-limited, private repo, … — stay silent.
        }
    }

    /// Checks ~10 s after launch, then every 24 h. Calling with `false` stops checking.
    func startPeriodicChecks(enabled: Bool) {
        task?.cancel()
        task = nil
        guard enabled else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.initialDelay * 1_000_000_000))
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    func skip(version: String) {
        defaults.set(version, forKey: Self.skippedVersionKey)
        if let update = availableUpdate, UpdateLogic.SemVer(update.version) == UpdateLogic.SemVer(version) {
            availableUpdate = nil
        }
    }
}

/// Builds the status-menu entry for a pending update.
@MainActor
enum UpdateMenuItem {
    /// nil when no update is available. Clicking opens the DMG (or the release page) in the browser.
    static func make(for checker: UpdateChecker) -> NSMenuItem? {
        guard let update = checker.availableUpdate else { return nil }
        let title = String(localized: "Update available: \(update.version)…")
        let item = NSMenuItem(title: title, action: #selector(Handler.open(_:)), keyEquivalent: "")
        let handler = Handler(url: update.dmgURL ?? update.htmlURL)
        item.target = handler
        item.representedObject = handler  // keep the (weakly-held) target alive with the item
        return item
    }

    @MainActor
    final class Handler: NSObject {
        let url: URL
        init(url: URL) { self.url = url }
        @objc func open(_ sender: Any?) { NSWorkspace.shared.open(url) }
    }
}
