import CoreGraphics
import Foundation
import Testing
@testable import VitrinCore

@Suite struct LastWindowQuitPolicyTests {
    typealias App = LastWindowQuitPolicy.RunningApp
    let ownPID: pid_t = 999
    let grace = LastWindowQuitPolicy.gracePeriod

    var enabled: AppSettings {
        var settings = AppSettings()
        settings.quitAppsWhenLastWindowCloses = true
        return settings
    }

    func window(_ id: CGWindowID, pid: pid_t = 10, standard: Bool = true, minimized: Bool = false,
                fullscreen: Bool = false, spaces: [SpaceID] = [1]) -> WindowInfo {
        WindowInfo(id: id, pid: pid, bundleIdentifier: "com.example.app\(pid)", isMinimized: minimized,
                   isFullscreen: fullscreen, isStandardWindow: standard, spaceIDs: spaces)
    }

    func app(_ pid: pid_t = 10, bundle: String? = nil, regular: Bool = true, hidden: Bool = false,
             terminated: Bool = false) -> App {
        App(pid: pid, bundleIdentifier: bundle ?? "com.example.app\(pid)", isRegular: regular, isHidden: hidden,
            isTerminated: terminated)
    }

    /// Runs `steps` of (time, windows, apps) and returns every quit outcome.
    func run(_ policy: inout LastWindowQuitPolicy, settings: AppSettings? = nil,
             _ steps: [(TimeInterval, [WindowInfo], [App])]) -> [LastWindowQuitPolicy.Outcome] {
        steps.map { now, windows, apps in
            policy.update(windows: windows, runningApps: apps, settings: settings ?? enabled, ownPID: ownPID, now: now)
        }
    }

    static func idle(_ outcomes: [LastWindowQuitPolicy.Outcome]) -> Bool {
        outcomes.allSatisfy { $0.appsToQuit.isEmpty && $0.nextCheck == nil }
    }

    static func noQuits(_ outcomes: [LastWindowQuitPolicy.Outcome]) -> Bool {
        outcomes.allSatisfy { $0.appsToQuit.isEmpty }
    }

    // MARK: Trigger

    @Test func quitsAfterLastStandardWindowStaysClosedForTheGracePeriod() {
        var policy = LastWindowQuitPolicy()
        let outcomes = run(&policy, [
            (0, [window(1), window(2)], [app()]),
            (1, [window(2)], [app()]),
            (2, [], [app()]),
            (2 + grace / 2, [], [app()]),
            (2 + grace, [], [app()]),
        ])
        #expect(outcomes.map(\.appsToQuit) == [[], [], [], [], [10]])
        #expect(outcomes[2].nextCheck == 2 + grace)
        #expect(outcomes[3].nextCheck == 2 + grace)
        #expect(outcomes[4].nextCheck == nil)
    }

    @Test func quitIsSentOnceUntilTheAppShowsAWindowAgain() {
        var policy = LastWindowQuitPolicy()
        let outcomes = run(&policy, [
            (0, [window(1)], [app()]),
            (1, [], [app()]),
            (1 + grace, [], [app()]),   // quit
            (5, [], [app()]),           // quit was cancelled (e.g. "processes running"): don't nag
            (6, [window(3)], [app()]),
            (7, [], [app()]),
            (7 + grace, [], [app()]),   // quit again
        ])
        #expect(outcomes.map(\.appsToQuit) == [[], [], [10], [], [], [], [10]])
    }

    @Test func windowReappearingWithinTheGracePeriodCancels() {
        var policy = LastWindowQuitPolicy()
        // A tab switch or a splash screen replaced by the main window: ids change, the count dips briefly.
        let outcomes = run(&policy, [
            (0, [window(1)], [app()]),
            (1, [], [app()]),
            (1.3, [window(2)], [app()]),
            (1 + grace, [window(2)], [app()]),
            (3, [], [app()]),
            (3 + grace * 0.9, [], [app()]),
        ])
        #expect(Self.noQuits(outcomes))
        #expect(outcomes[3].nextCheck == nil)
        #expect(outcomes[5].nextCheck == 3 + grace)
    }

    // MARK: What counts as a window

    @Test func appsThatNeverHadAStandardWindowAreNotQuit() {
        var policy = LastWindowQuitPolicy()
        // Launched windowless, then showed only a dialog (e.g. an open panel), which the user cancelled.
        let outcomes = run(&policy, [
            (0, [], [app()]),
            (1, [window(1, standard: false)], [app()]),
            (2, [], [app()]),
            (5, [], [app()]),
        ])
        #expect(Self.idle(outcomes))
    }

    @Test func dialogsDontKeepAnAppAlive() {
        var policy = LastWindowQuitPolicy()
        let outcomes = run(&policy, [
            (0, [window(1), window(2, standard: false)], [app()]),
            (1, [window(2, standard: false)], [app()]),
            (1 + grace, [window(2, standard: false)], [app()]),
        ])
        #expect(outcomes.map(\.appsToQuit) == [[], [], [10]])
    }

    @Test func minimizedFullscreenAndOtherSpaceWindowsCount() {
        for kept in [window(2, minimized: true), window(2, fullscreen: true), window(2, spaces: [7])] {
            var policy = LastWindowQuitPolicy()
            let outcomes = run(&policy, [
                (0, [window(1), kept], [app()]),
                (1, [kept], [app()]),
                (10, [kept], [app()]),
            ])
            #expect(Self.idle(outcomes))
        }
    }

    @Test func minimizedDialogSubroleStillCounts() {
        // Minimized windows briefly report AXDialog: a window seen as standard keeps counting until it closes.
        var policy = LastWindowQuitPolicy()
        let outcomes = run(&policy, [
            (0, [window(1)], [app()]),
            (1, [window(1, standard: false, minimized: true)], [app()]),
            (2, [window(1, standard: false)], [app()]),
            (10, [window(1, standard: false)], [app()]),
        ])
        #expect(Self.idle(outcomes))
    }

    @Test func hiddenAppsWaitUntilVisibleAgain() {
        var policy = LastWindowQuitPolicy()
        let outcomes = run(&policy, [
            (0, [window(1)], [app()]),
            (1, [], [app(hidden: true)]),
            (5, [], [app(hidden: true)]),
            (6, [], [app()]),
            (6 + grace / 2, [], [app()]),
            (6 + grace, [], [app()]),
        ])
        #expect(outcomes.map(\.appsToQuit) == [[], [], [], [], [], [10]])
        #expect(outcomes[1].nextCheck == nil && outcomes[2].nextCheck == nil)
    }

    // MARK: Which apps

    @Test func onlyEligibleAppsAreQuit() {
        let finder = "com.apple.finder", vitrin = "io.github.ozanhakantunca.vitrin"
        let cases: [(App, AppSettings)] = [
            (app(regular: false), enabled),              // accessory / menu-bar app
            (app(terminated: true), enabled),            // already quitting
            (app(bundle: finder), enabled),
            (app(bundle: vitrin), enabled),
            (app(ownPID), enabled),
            (app(), AppSettings()),                      // feature off (the default)
            (app(bundle: "com.example.keep"), {
                var settings = enabled
                settings.appExceptions = [AppException(bundleIdentifier: "com.example.keep",
                                                       keepRunningWhenLastWindowCloses: true)]
                return settings
            }()),
        ]
        for (candidate, settings) in cases {
            #expect(!LastWindowQuitPolicy.isEligible(candidate, settings: settings, ownPID: ownPID))
            var policy = LastWindowQuitPolicy()
            let pid = candidate.pid
            let outcomes = run(&policy, settings: settings, [
                (0, [window(1, pid: pid)], [candidate]),
                (1, [], [candidate]),
                (5, [], [candidate]),
            ])
            #expect(Self.idle(outcomes))
            #expect(policy.watchedPIDs.isEmpty)
        }
        // An exception for another purpose doesn't keep the app running.
        var settings = enabled
        settings.appExceptions = [AppException(bundleIdentifier: "com.example.app10", ignoreShortcutsWhenFrontmost: true)]
        #expect(LastWindowQuitPolicy.isEligible(app(), settings: settings, ownPID: ownPID))
    }

    @Test func turningTheFeatureOnDoesNotQuitAppsThatAreAlreadyWindowless() {
        var policy = LastWindowQuitPolicy()
        _ = run(&policy, settings: AppSettings(), [(0, [window(1)], [app()]), (1, [], [app()])])
        let outcomes = run(&policy, [(2, [], [app()]), (10, [], [app()])])
        #expect(Self.idle(outcomes))
    }

    @Test func appsThatLeftAreForgotten() {
        var policy = LastWindowQuitPolicy()
        _ = run(&policy, [(0, [window(1)], [app()])])
        #expect(policy.watchedPIDs == [10])
        _ = run(&policy, [(1, [], [])]) // terminated: no longer among the running apps
        #expect(policy.watchedPIDs.isEmpty)
        // A new process reusing the pid starts from scratch.
        let outcomes = run(&policy, [(2, [], [app()]), (10, [], [app()])])
        #expect(Self.noQuits(outcomes))
    }

    @Test func resetForgetsEverything() {
        var policy = LastWindowQuitPolicy()
        _ = run(&policy, [(0, [window(1)], [app()])])
        policy.reset()
        let outcomes = run(&policy, [(1, [], [app()]), (10, [], [app()])])
        #expect(Self.noQuits(outcomes))
    }

    // MARK: Several apps

    @Test func appsCountDownIndependently() {
        var policy = LastWindowQuitPolicy()
        let apps = [app(10), app(20)]
        let outcomes = run(&policy, [
            (0, [window(1, pid: 10), window(2, pid: 20)], apps),
            (1, [window(2, pid: 20)], apps),
            (1.5, [], apps),
            (1 + grace, [], apps),
            (1.5 + grace, [], apps),
        ])
        #expect(outcomes.map(\.appsToQuit) == [[], [], [], [10], [20]])
        #expect(outcomes[2].nextCheck == 1 + grace)
        #expect(outcomes[3].nextCheck == 1.5 + grace)
    }

    @Test func manyAppsLosingEveryWindowAtOnceLooksLikeAGlitch() {
        var policy = LastWindowQuitPolicy()
        let apps = [app(10), app(20), app(30)]
        let outcomes = run(&policy, [
            (0, [window(1, pid: 10), window(2, pid: 20), window(3, pid: 30)], apps),
            (1, [], apps),
            (1 + grace, [], apps),
            (10, [], apps),
        ])
        #expect(Self.noQuits(outcomes))
        #expect(outcomes[3].nextCheck == nil)
        // Two at once is still something a user can do.
        var pair = LastWindowQuitPolicy()
        let two = run(&pair, [
            (0, [window(1, pid: 10), window(2, pid: 20)], [app(10), app(20)]),
            (1, [], [app(10), app(20)]),
            (1 + grace, [], [app(10), app(20)]),
        ])
        #expect(two.last?.appsToQuit == [10, 20])
    }
}
