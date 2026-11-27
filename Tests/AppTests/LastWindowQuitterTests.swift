import CoreGraphics
import Foundation
import Testing
import VitrinCore
@testable import Vitrin

@MainActor @Suite struct LastWindowQuitterTests {
    final class World {
        var windows: [WindowInfo] = []
        var tracking = true
        var now: TimeInterval = 100
        var quits: [pid_t] = []
        var apps: [pid_t: LastWindowQuitPolicy.RunningApp] = [10: .init(pid: 10, bundleIdentifier: "com.example.ten")]
    }

    func make(_ world: World, enabled: Bool = true) -> LastWindowQuitter {
        var settings = AppSettings()
        settings.quitAppsWhenLastWindowCloses = enabled
        return LastWindowQuitter(
            settings: settings,
            windows: { world.windows },
            isTracking: { world.tracking },
            appFacts: { pids in pids.compactMap { world.apps[$0] } },
            quit: { world.quits.append($0) },
            now: { world.now },
            ownPID: 1
        )
    }

    @Test func quitsOnceTheCountdownEnds() {
        let world = World()
        let quitter = make(world)
        world.windows = [WindowInfo(id: 1, pid: 10)]
        quitter.evaluate()
        world.windows = []
        quitter.evaluate()
        #expect(quitter.scheduledDeadline == 100 + LastWindowQuitPolicy.gracePeriod)
        #expect(world.quits.isEmpty)
        world.now += LastWindowQuitPolicy.gracePeriod
        quitter.evaluate()
        #expect(world.quits == [10])
        #expect(quitter.scheduledDeadline == nil)
    }

    @Test func emptyInventoryWhileNotTrackingNeverQuits() {
        let world = World()
        let quitter = make(world)
        world.windows = [WindowInfo(id: 1, pid: 10)]
        quitter.evaluate()
        // Tracking stops (permission revoked, Vitrin shutting down): the tracker forgets every window.
        world.tracking = false
        world.windows = []
        quitter.evaluate()
        #expect(quitter.scheduledDeadline == nil)
        world.tracking = true
        world.now += 10
        quitter.evaluate()
        world.now += 10
        quitter.evaluate()
        #expect(world.quits.isEmpty)
    }

    @Test func turningTheSettingOffCancelsACountdown() {
        let world = World()
        let quitter = make(world)
        world.windows = [WindowInfo(id: 1, pid: 10)]
        quitter.evaluate()
        world.windows = []
        quitter.evaluate()
        #expect(quitter.scheduledDeadline != nil)
        quitter.apply(settings: AppSettings())
        #expect(quitter.scheduledDeadline == nil)
        world.now += 10
        quitter.evaluate()
        #expect(world.quits.isEmpty)
    }
}
