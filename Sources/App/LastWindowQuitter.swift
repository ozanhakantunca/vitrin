// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Runs `LastWindowQuitPolicy` on the window tracker's inventory: re-evaluated on every tracker change and
// when a countdown ends, and quits what the policy returns with `NSRunningApplication.terminate()`.

import AppKit
import VitrinCore

@MainActor
final class LastWindowQuitter {
    /// Facts about the apps behind `pids`, for the policy.
    typealias AppFacts = @MainActor (_ pids: Set<pid_t>) -> [LastWindowQuitPolicy.RunningApp]

    private var policy = LastWindowQuitPolicy()
    private var settings: AppSettings
    private let windows: @MainActor () -> [WindowInfo]
    /// `false` while the tracker isn't observing windows: its empty inventory must not look like closed windows.
    private let isTracking: @MainActor () -> Bool
    private let appFacts: AppFacts
    private let quit: @MainActor (pid_t) -> Void
    private let now: () -> TimeInterval
    private let ownPID: pid_t
    private var scheduledCheck: DispatchWorkItem?
    private(set) var scheduledDeadline: TimeInterval?

    init(
        settings: AppSettings,
        windows: @escaping @MainActor () -> [WindowInfo],
        isTracking: @escaping @MainActor () -> Bool,
        appFacts: @escaping AppFacts = LastWindowQuitter.runningAppFacts,
        quit: @escaping @MainActor (pid_t) -> Void = LastWindowQuitter.terminate,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.settings = settings
        self.windows = windows
        self.isTracking = isTracking
        self.appFacts = appFacts
        self.quit = quit
        self.now = now
        self.ownPID = ownPID
    }

    func apply(settings: AppSettings) {
        self.settings = settings
        evaluate()
    }

    /// Re-runs the policy on the current windows. Cheap when the feature is off.
    func evaluate() {
        guard settings.quitAppsWhenLastWindowCloses, isTracking() else {
            policy.reset()
            schedule(at: nil)
            return
        }
        let windows = windows()
        let pids = policy.watchedPIDs.union(windows.map(\.pid))
        let outcome = policy.update(windows: windows, runningApps: appFacts(pids), settings: settings,
                                    ownPID: ownPID, now: now())
        for pid in outcome.appsToQuit { quit(pid) }
        schedule(at: outcome.nextCheck)
    }

    private func schedule(at deadline: TimeInterval?) {
        guard deadline != scheduledDeadline else { return }
        scheduledCheck?.cancel()
        scheduledCheck = nil
        scheduledDeadline = deadline
        guard let deadline else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scheduledDeadline == deadline else { return }
                self.scheduledCheck = nil
                self.scheduledDeadline = nil
                self.evaluate()
            }
        }
        scheduledCheck = item
        // A hair late, so `now >= deadline` holds when it fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now()) + 0.02, execute: item)
    }

    // MARK: - System

    static func runningAppFacts(_ pids: Set<pid_t>) -> [LastWindowQuitPolicy.RunningApp] {
        pids.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return LastWindowQuitPolicy.RunningApp(
                pid: pid,
                bundleIdentifier: app.bundleIdentifier,
                isRegular: app.activationPolicy == .regular,
                isHidden: app.isHidden,
                isTerminated: app.isTerminated
            )
        }
    }

    static func terminate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        let sent = app.terminate()
        Log.app.notice("Last window closed: quitting \(name, privacy: .public) (\(sent ? "sent" : "refused", privacy: .public))")
    }
}
