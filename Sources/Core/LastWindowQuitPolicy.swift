// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// "Quit apps when their last window closes" (the Windows behaviour). This is the whole decision: the app
// layer feeds it the tracker's windows plus a few facts about the running apps, and quits the apps it
// returns with `NSRunningApplication.terminate()` (like ⌘Q, so unsaved-changes prompts still appear).

import CoreGraphics
import Foundation

/// Decides which apps to quit because the user closed their last standard window.
///
/// An app is quit only when all of these hold:
/// - the feature is on, the app is a regular (Dock) app, not Finder or Vitrin, not terminated, and its
///   exception does not say `keepRunningWhenLastWindowCloses`;
/// - it had at least one standard window, and now has none, and has had none for `gracePeriod`
///   (window → tab swaps, a splash screen replaced by the main window, re-reads after a Space switch);
/// - it is not hidden (⌘H): the countdown starts over once the app is visible again.
///
/// A window counts when the tracker knows it (any Space, minimized and fullscreen included) and it is a
/// standard window. Floating panels and sheets never reach the tracker; dialogs, open/save panels and
/// windows that can't be minimized (About, settings) have `isStandardWindow == false` and don't count. Once a window was seen as standard it keeps counting until it closes, because minimized
/// windows and windows of hidden apps briefly report a dialog subrole.
public struct LastWindowQuitPolicy: Sendable, Equatable {
    /// How long an app must stay without standard windows before it is quit.
    public static let gracePeriod: TimeInterval = 1
    /// Apps that are never quit, whatever the settings say.
    public static let alwaysKeptBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "io.github.ozanhakantunca.vitrin",
    ]
    /// More apps than this losing their last window at the same moment looks like a tracking glitch
    /// (sleep/wake, a permission change), not something the user did: none of them is quit.
    public static let maximumSimultaneousQuits = 2

    /// What the policy needs to know about one running app.
    public struct RunningApp: Sendable, Equatable {
        public var pid: pid_t
        public var bundleIdentifier: String?
        /// `NSApplication.ActivationPolicy.regular`: the app shows in the Dock.
        public var isRegular: Bool
        public var isHidden: Bool
        public var isTerminated: Bool

        public init(pid: pid_t, bundleIdentifier: String?, isRegular: Bool = true, isHidden: Bool = false,
                    isTerminated: Bool = false) {
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.isRegular = isRegular
            self.isHidden = isHidden
            self.isTerminated = isTerminated
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Apps to quit now.
        public var appsToQuit: [pid_t]
        /// When to call `update` again even if nothing changes (an app is counting down), as `now` time.
        public var nextCheck: TimeInterval?

        public init(appsToQuit: [pid_t] = [], nextCheck: TimeInterval? = nil) {
            self.appsToQuit = appsToQuit
            self.nextCheck = nextCheck
        }
    }

    struct AppState: Sendable, Equatable {
        /// Open windows of the app that are (or were once seen as) standard windows.
        var standardWindowIDs: Set<CGWindowID> = []
        /// The app had a standard window since it started being watched (or since it was last quit).
        var hadStandardWindow = false
        /// When the app's standard window count reached zero while visible.
        var zeroSince: TimeInterval?
        /// A quit was already sent; don't send another until the app shows a window again.
        var quitRequested = false
    }

    private(set) var apps: [pid_t: AppState] = [:]

    public init() {}

    /// Apps whose state is kept (pass their facts to the next `update`, even if they have no windows).
    public var watchedPIDs: Set<pid_t> { Set(apps.keys) }

    /// Forgets everything (tracking stopped, or its windows can't be trusted).
    public mutating func reset() {
        apps.removeAll()
    }

    /// Whether `app` may ever be quit by this feature.
    public static func isEligible(_ app: RunningApp, settings: AppSettings, ownPID: pid_t) -> Bool {
        guard settings.quitAppsWhenLastWindowCloses, app.isRegular, !app.isTerminated,
              app.pid > 0, app.pid != ownPID else { return false }
        if let bundleID = app.bundleIdentifier {
            if alwaysKeptBundleIdentifiers.contains(bundleID) { return false }
            if settings.exception(forBundleIdentifier: bundleID)?.keepRunningWhenLastWindowCloses == true { return false }
        }
        return true
    }

    /// Feeds the current windows (all apps) and the facts of the apps in `runningApps`; returns the apps to
    /// quit now. Apps missing from `runningApps` are forgotten. `now` is a monotonic time in seconds.
    public mutating func update(windows: [WindowInfo], runningApps: [RunningApp], settings: AppSettings,
                                ownPID: pid_t, now: TimeInterval) -> Outcome {
        guard settings.quitAppsWhenLastWindowCloses else {
            reset()
            return Outcome()
        }
        let windowsByPID = Dictionary(grouping: windows, by: \.pid)
        var next: [pid_t: AppState] = [:]
        var ready: [pid_t] = []
        var nextCheck: TimeInterval?

        for app in runningApps where next[app.pid] == nil {
            guard Self.isEligible(app, settings: settings, ownPID: ownPID) else { continue }
            var state = apps[app.pid] ?? AppState()
            let present = windowsByPID[app.pid] ?? []
            let standardNow = present.filter { $0.isStandardWindow || $0.isMinimized || $0.isFullscreen }.map(\.id)
            state.standardWindowIDs = state.standardWindowIDs.intersection(present.map(\.id)).union(standardNow)

            if !state.standardWindowIDs.isEmpty {
                state.hadStandardWindow = true
                state.zeroSince = nil
                state.quitRequested = false
            } else if state.hadStandardWindow && !state.quitRequested {
                if app.isHidden {
                    state.zeroSince = nil
                } else {
                    let since = state.zeroSince ?? now
                    state.zeroSince = since
                    let deadline = since + Self.gracePeriod
                    if now >= deadline {
                        ready.append(app.pid)
                    } else {
                        nextCheck = min(nextCheck ?? deadline, deadline)
                    }
                }
            }
            next[app.pid] = state
        }

        if ready.count > Self.maximumSimultaneousQuits {
            // Forget that these apps had windows: they are quit only after showing a window again.
            for pid in ready { next[pid] = AppState() }
            ready = []
        } else {
            for pid in ready {
                next[pid]?.quitRequested = true
                next[pid]?.zeroSince = nil
            }
        }
        apps = next
        return Outcome(appsToQuit: ready.sorted(), nextCheck: nextCheck)
    }
}
