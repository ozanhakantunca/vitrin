// Tests for the trackpad gesture recognizer's pure parts. Nothing here starts a multitouch device.

import Testing
@testable import VitrinPrivate
@testable import VitrinSystem

/// Feeds frames 10 ms apart into a machine.
private struct Driver {
    var machine: SwipeStateMachine
    var time = 100.0

    init(_ configuration: SwipeStateMachine.Configuration = .init()) {
        machine = SwipeStateMachine(configuration: configuration)
    }

    /// Default contact set for `n` fingers (ids 0..<n): stable while the count is stable.
    static func contacts(_ n: Int) -> UInt64 { n >= 64 ? .max : (1 << UInt64(n)) - 1 }

    @discardableResult
    mutating func frame(_ n: Int, x: Float, y: Float = 0.5, contacts: UInt64? = nil, dt: Double = 0.01) -> [GestureEvent] {
        time += dt
        return machine.consume(TouchFrame(timestamp: time, fingerCount: n, x: x, y: y, contacts: contacts ?? Self.contacts(n)))
    }

    /// Moves `n` fingers linearly over `steps` frames (excluding the start point), collecting every event.
    @discardableResult
    mutating func move(_ n: Int = 3, fromX: Float, toX: Float, fromY: Float = 0.5, toY: Float = 0.5, steps: Int = 20) -> [GestureEvent] {
        var events: [GestureEvent] = []
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            events += frame(n, x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
        }
        return events
    }

    @discardableResult
    mutating func lift(to n: Int = 0, x: Float = 0.5) -> [GestureEvent] { frame(n, x: x) }
}

@Suite struct SwipeStateMachineTests {
    let open: Float = 0.06
    let step: Float = 0.07

    @Test func defaults() {
        let c = SwipeStateMachine.Configuration()
        #expect(c.fingerCount == 3)
        #expect(c.openThreshold == 0.06)
        #expect(c.stepDistance == 0.07)
    }

    // MARK: Opening

    @Test func opensForwardOnRightSwipePastThreshold() {
        var d = Driver()
        #expect(d.frame(3, x: 0.5).isEmpty)
        #expect(d.machine.phase == .tracking)
        #expect(d.frame(3, x: 0.5 + open - 0.005).isEmpty)
        #expect(d.frame(3, x: 0.5 + open + 0.001) == [.open(reverse: false)])
        #expect(d.machine.phase == .open)
    }

    @Test func opensReverseOnLeftSwipePastThreshold() {
        var d = Driver()
        d.frame(3, x: 0.5)
        #expect(d.frame(3, x: 0.5 - open + 0.005).isEmpty)
        #expect(d.frame(3, x: 0.5 - open - 0.001) == [.open(reverse: true)])
    }

    @Test func opensOnlyOncePerGesture() {
        var d = Driver()
        d.frame(3, x: 0.2)
        let events = d.move(fromX: 0.2, toX: 0.2 + open + step - 0.01)
        #expect(events == [.open(reverse: false)])
    }

    @Test func openingUsesNetDisplacementFromTouchDown() {
        var d = Driver()
        d.frame(3, x: 0.5)
        // Back-and-forth that never nets out past the threshold.
        for _ in 0..<10 {
            #expect(d.frame(3, x: 0.5 + open * 0.9).isEmpty)
            #expect(d.frame(3, x: 0.5 - open * 0.9).isEmpty)
        }
        #expect(d.machine.phase == .tracking)
    }

    @Test func jitterBelowThresholdEmitsNothing() {
        var d = Driver()
        d.frame(3, x: 0.5, y: 0.5)
        let jitter: [(Float, Float)] = [(0.01, 0.005), (-0.02, 0.01), (0.03, -0.01), (0.059, 0.0), (-0.059, 0.02), (0.0, -0.03)]
        for (dx, dy) in jitter {
            #expect(d.frame(3, x: 0.5 + dx, y: 0.5 + dy).isEmpty)
        }
        #expect(d.machine.phase == .tracking)
        #expect(d.lift().isEmpty)
        #expect(d.machine.phase == .idle)
    }

    @Test func fastFirstFrameKeepsOvershootAsSteps() {
        var d = Driver()
        d.frame(3, x: 0.3)
        #expect(d.frame(3, x: 0.3 + open + 2 * step + 0.005) == [.open(reverse: false), .next, .next])
        var r = Driver()
        r.frame(3, x: 0.7)
        #expect(r.frame(3, x: 0.7 - open - step - 0.005) == [.open(reverse: true), .previous])
    }

    @Test func stepsPerFrameAreCapped() {
        var d = Driver()
        d.frame(3, x: 0.0)
        let events = d.frame(3, x: 1.0) // a glitchy jump across the whole pad
        #expect(events.first == .open(reverse: false))
        #expect(events.dropFirst().allSatisfy { $0 == .next })
        #expect(events.count == 1 + SwipeStateMachine.Configuration().maxStepsPerFrame)
        // The excess is dropped, not replayed later.
        #expect(d.frame(3, x: 1.0).isEmpty)
    }

    // MARK: Stepping

    @Test func stepsForwardEveryStepDistance() {
        var d = Driver()
        d.frame(3, x: 0.2)
        #expect(d.frame(3, x: 0.2 + open + 0.001) == [.open(reverse: false)])
        let anchor: Float = 0.2 + open
        #expect(d.frame(3, x: anchor + step - 0.005).isEmpty)
        #expect(d.frame(3, x: anchor + step + 0.002) == [.next])
        #expect(d.frame(3, x: anchor + 2 * step - 0.005).isEmpty)
        #expect(d.frame(3, x: anchor + 2 * step + 0.002) == [.next])
        let more = d.move(fromX: anchor + 2 * step + 0.002, toX: anchor + 5 * step + 0.002, steps: 30)
        #expect(more == [.next, .next, .next])
    }

    @Test func steppingBackEmitsPrevious() {
        var d = Driver()
        d.frame(3, x: 0.2)
        d.frame(3, x: 0.2 + open + 0.001)
        let anchor: Float = 0.2 + open
        #expect(d.frame(3, x: anchor + step + 0.002) == [.next])
        // Hysteresis: a small move back does nothing; a full step back is `.previous`.
        #expect(d.frame(3, x: anchor + step - 0.03).isEmpty)
        #expect(d.frame(3, x: anchor - 0.002) == [.previous])
        #expect(d.frame(3, x: anchor - step - 0.004) == [.previous])
    }

    @Test func reverseOpenThenRightSwipeIsForward() {
        var d = Driver()
        d.frame(3, x: 0.7)
        #expect(d.frame(3, x: 0.7 - open - 0.001) == [.open(reverse: true)])
        let anchor: Float = 0.7 - open
        #expect(d.frame(3, x: anchor - step - 0.002) == [.previous])
        #expect(d.frame(3, x: anchor + 0.002) == [.next])
    }

    @Test func jitterAfterOpenDoesNotStep() {
        var d = Driver()
        d.frame(3, x: 0.4)
        d.frame(3, x: 0.4 + open + 0.001)
        let anchor: Float = 0.4 + open
        for offset: Float in [0.02, -0.03, 0.05, -0.06, 0.0, 0.069, -0.069] {
            #expect(d.frame(3, x: anchor + offset).isEmpty)
        }
    }

    @Test func verticalTravelIsIgnoredWhileOpen() {
        var d = Driver()
        d.frame(3, x: 0.4, y: 0.5)
        d.frame(3, x: 0.4 + open + 0.001, y: 0.5)
        #expect(d.move(fromX: 0.4 + open + 0.001, toX: 0.4 + open + 0.001, fromY: 0.5, toY: 0.95).isEmpty)
        #expect(d.machine.phase == .open)
    }

    // MARK: Lift

    @Test func liftAfterOpenEnds() {
        for remaining in [0, 1, 2] {
            var d = Driver()
            d.frame(3, x: 0.5)
            d.frame(3, x: 0.5 + open + 0.01)
            #expect(d.lift(to: remaining) == [.end], "lift to \(remaining)")
            #expect(d.machine.phase == .idle)
            #expect(d.lift(to: 0).isEmpty, "only one end")
        }
    }

    @Test func liftBeforeOpenEmitsNothing() {
        var d = Driver()
        d.frame(3, x: 0.5)
        d.frame(3, x: 0.5 + open * 0.5)
        #expect(d.lift().isEmpty)
        #expect(d.machine.phase == .idle)
    }

    @Test func fingersLandingOneByOneStartTrackingAtThree() {
        var d = Driver()
        #expect(d.frame(1, x: 0.1).isEmpty)
        #expect(d.frame(2, x: 0.3).isEmpty)
        #expect(d.machine.phase == .idle)
        #expect(d.frame(3, x: 0.5).isEmpty)
        #expect(d.machine.phase == .tracking)
        #expect(d.frame(3, x: 0.5 + open + 0.001) == [.open(reverse: false)])
    }

    // MARK: Rejection

    @Test func verticalSwipeIsRejected() {
        for direction: Float in [1, -1] {
            var d = Driver()
            d.frame(3, x: 0.5, y: 0.5)
            #expect(d.move(fromX: 0.5, toX: 0.51, fromY: 0.5, toY: 0.5 + direction * 0.05, steps: 5).isEmpty)
            #expect(d.machine.phase == .rejected)
            // Horizontal travel afterwards cannot open it any more.
            #expect(d.move(fromX: 0.51, toX: 0.9, fromY: 0.5 + direction * 0.05, toY: 0.5 + direction * 0.05).isEmpty)
            #expect(d.lift().isEmpty)
            #expect(d.machine.phase == .idle)
        }
    }

    @Test func diagonalWaitsForHorizontalDominance() {
        var d = Driver()
        d.frame(3, x: 0.3, y: 0.5)
        // |dx| past the threshold but not 1.5× |dy|; |dy| doesn't dominate either → keep tracking.
        #expect(d.frame(3, x: 0.3 + 0.07, y: 0.56).isEmpty)
        #expect(d.machine.phase == .tracking)
        #expect(d.frame(3, x: 0.3 + 0.1, y: 0.56) == [.open(reverse: false)])
    }

    @Test func diagonalWithVerticalDominanceIsRejected() {
        var d = Driver()
        d.frame(3, x: 0.3, y: 0.5)
        #expect(d.frame(3, x: 0.3 + 0.05, y: 0.56).isEmpty)
        #expect(d.machine.phase == .rejected)
    }

    @Test func twoFingerSwipeIsIgnored() {
        var d = Driver()
        #expect(d.frame(2, x: 0.1).isEmpty)
        #expect(d.move(2, fromX: 0.1, toX: 0.9).isEmpty)
        #expect(d.machine.phase == .idle)
    }

    @Test func fourFingerSwipeIsIgnoredIncludingItsLiftThroughThree() {
        var d = Driver()
        #expect(d.frame(4, x: 0.1).isEmpty)
        #expect(d.machine.phase == .rejected)
        #expect(d.move(4, fromX: 0.1, toX: 0.9).isEmpty)
        // Lifting one finger leaves three on the pad: still the same (rejected) gesture.
        #expect(d.frame(3, x: 0.9).isEmpty)
        #expect(d.move(3, fromX: 0.9, toX: 0.5).isEmpty)
        #expect(d.machine.phase == .rejected)
        #expect(d.lift(to: 2).isEmpty)
        #expect(d.machine.phase == .idle)
    }

    // MARK: Finger count changes mid-gesture

    @Test func extraFingerBeforeOpenRejects() {
        var d = Driver()
        d.frame(3, x: 0.3)
        d.frame(3, x: 0.33)
        #expect(d.frame(4, x: 0.35).isEmpty)
        #expect(d.machine.phase == .rejected)
        #expect(d.frame(3, x: 0.5).isEmpty)
        #expect(d.frame(3, x: 0.6).isEmpty)
    }

    @Test func extraFingerAfterOpenPausesSteppingThenReanchors() {
        var d = Driver()
        d.frame(3, x: 0.2)
        d.frame(3, x: 0.2 + open + 0.001)
        // Four fingers: travel is not counted.
        #expect(d.move(4, fromX: 0.26, toX: 0.6).isEmpty)
        #expect(d.machine.phase == .open)
        // Back to three somewhere else: re-anchored there, no jump.
        #expect(d.frame(3, x: 0.62).isEmpty)
        #expect(d.frame(3, x: 0.62 + step - 0.005).isEmpty)
        #expect(d.frame(3, x: 0.62 + step + 0.002) == [.next])
    }

    @Test func liftFromFourFingersAfterOpenStillEnds() {
        var d = Driver()
        d.frame(3, x: 0.2)
        d.frame(3, x: 0.2 + open + 0.001)
        d.frame(4, x: 0.3)
        #expect(d.lift(to: 0) == [.end])
    }

    @Test func swappedFingerWhileTrackingIsNotTravel() {
        var d = Driver()
        d.frame(3, x: 0.3, contacts: 0b0111)
        // Same count, different contacts, centroid jumped 0.1: re-anchor, no open.
        #expect(d.frame(3, x: 0.4, contacts: 0b1011).isEmpty)
        #expect(d.machine.phase == .tracking)
        #expect(d.frame(3, x: 0.4 + open - 0.005, contacts: 0b1011).isEmpty)
        #expect(d.frame(3, x: 0.4 + open + 0.001, contacts: 0b1011) == [.open(reverse: false)])
    }

    @Test func swappedFingerWhileOpenReanchors() {
        var d = Driver()
        d.frame(3, x: 0.3, contacts: 0b0111)
        d.frame(3, x: 0.3 + open + 0.001, contacts: 0b0111)
        #expect(d.frame(3, x: 0.3 + open + 0.15, contacts: 0b1110).isEmpty)
        #expect(d.frame(3, x: 0.3 + open + 0.15 + step + 0.002, contacts: 0b1110) == [.next])
    }

    // MARK: Re-arming

    @Test func rearmsAfterEnd() {
        var d = Driver()
        for _ in 0..<3 {
            d.frame(3, x: 0.5)
            #expect(d.move(fromX: 0.5, toX: 0.5 + open + step + 0.01) == [.open(reverse: false), .next])
            #expect(d.lift() == [.end])
        }
        d.frame(3, x: 0.5)
        #expect(d.move(fromX: 0.5, toX: 0.5 - open - 0.01) == [.open(reverse: true)])
        #expect(d.lift(to: 1) == [.end])
    }

    @Test func rearmsAfterRejection() {
        var d = Driver()
        d.frame(3, x: 0.5, y: 0.2)
        d.move(fromX: 0.5, toX: 0.5, fromY: 0.2, toY: 0.6)
        #expect(d.machine.phase == .rejected)
        d.lift()
        d.frame(3, x: 0.5)
        #expect(d.frame(3, x: 0.5 + open + 0.001) == [.open(reverse: false)])
    }

    @Test func liftingToTwoAndBackStartsAFreshGesture() {
        var d = Driver()
        d.frame(3, x: 0.3)
        d.frame(3, x: 0.3 + open + 0.001)
        #expect(d.lift(to: 2, x: 0.4) == [.end])
        #expect(d.frame(3, x: 0.4).isEmpty)
        #expect(d.machine.phase == .tracking)
        #expect(d.frame(3, x: 0.4 + open + 0.001) == [.open(reverse: false)])
    }

    // MARK: Timing / robustness

    @Test func longFrameGapEndsTheGesture() {
        var d = Driver()
        d.frame(3, x: 0.3)
        d.frame(3, x: 0.3 + open + 0.001)
        // The lift frame was lost (e.g. sleep); the next frame arrives a second later with fingers down.
        #expect(d.frame(3, x: 0.8, dt: 1.0) == [.end])
        #expect(d.machine.phase == .tracking) // the new frame started a new gesture
        #expect(d.frame(3, x: 0.8 - open - 0.001) == [.open(reverse: true)])
    }

    @Test func clockGoingBackwardsEndsTheGesture() {
        var d = Driver()
        d.frame(3, x: 0.3)
        d.frame(3, x: 0.3 + open + 0.001)
        #expect(d.frame(3, x: 0.5, dt: -5) == [.end])
    }

    @Test func gapWhileTrackingResetsSilently() {
        var d = Driver()
        d.frame(3, x: 0.3)
        #expect(d.frame(3, x: 0.3 + open + 0.01, dt: 2.0).isEmpty) // new origin, not travel
        #expect(d.machine.phase == .tracking)
    }

    @Test func resetForgetsWithoutEvents() {
        var d = Driver()
        d.frame(3, x: 0.3)
        d.frame(3, x: 0.3 + open + 0.001)
        d.machine.reset()
        #expect(d.machine.phase == .idle)
        #expect(d.lift().isEmpty)
    }

    @Test func nonFiniteCoordinatesNeitherCrashNorHang() {
        var d = Driver()
        d.frame(3, x: 0.3)
        d.frame(3, x: 0.3 + open + 0.001)
        #expect(d.frame(3, x: .infinity).isEmpty)
        #expect(d.frame(3, x: .nan).isEmpty)
        let huge = d.frame(3, x: 1e30)
        #expect(huge.count <= SwipeStateMachine.Configuration().maxStepsPerFrame)
        var t = Driver()
        #expect(t.frame(3, x: .nan).isEmpty)
        #expect(t.frame(3, x: 0.9).isEmpty)
    }

    @Test func customFingerCount() {
        var config = SwipeStateMachine.Configuration()
        config.fingerCount = 4
        var d = Driver(config)
        d.frame(3, x: 0.2)
        #expect(d.move(3, fromX: 0.2, toX: 0.8).isEmpty)
        d.lift()
        d.frame(4, x: 0.2)
        #expect(d.frame(4, x: 0.2 + open + 0.001) == [.open(reverse: false)])
        #expect(d.lift(to: 3) == [.end])
    }

    // MARK: TouchFrame

    @Test func touchFrameFromTouches() {
        let frame = TouchFrame(timestamp: 1, touches: [
            .init(id: 1, x: 0.1, y: 0.2), .init(id: 2, x: 0.3, y: 0.4), .init(id: 66, x: 0.5, y: 0.6),
        ])
        #expect(frame.fingerCount == 3)
        #expect(abs(frame.x - 0.3) < 1e-6)
        #expect(abs(frame.y - 0.4) < 1e-6)
        #expect(frame.contacts == 0b0110) // 66 & 63 == 2 collides with id 2: still a stable set
        let empty = TouchFrame(timestamp: 1, touches: [])
        #expect(empty.fingerCount == 0 && empty.x == 0 && empty.contacts == 0)
    }
}

@Suite struct SystemTrackpadGesturesTests {
    private func settings(_ values: [String: [String: Int]]) -> SystemTrackpadGestures {
        SystemTrackpadGestures { key, domain in values[domain]?[key] }
    }

    private let builtIn = "com.apple.AppleMultitouchTrackpad"
    private let bluetooth = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    private let swipe = "TrackpadThreeFingerHorizSwipeGesture"
    private let drag = "TrackpadThreeFingerDrag"

    @Test func neverWrittenMeansMacOSDefaultWhichConflicts() {
        let s = settings([:])
        #expect(s.horizontalSwipe == nil)
        #expect(!s.threeFingerDrag)
        #expect(s.conflictsWithThreeFingerSwipe)
    }

    @Test func fourFingerSpacesSwipeDoesNotConflict() {
        let s = settings([builtIn: [swipe: 0], bluetooth: [swipe: 0]])
        #expect(s.horizontalSwipe == .off)
        #expect(!s.conflictsWithThreeFingerSwipe)
    }

    @Test func threeFingerSpacesSwipeConflicts() {
        #expect(settings([builtIn: [swipe: 2]]).horizontalSwipe == .spaces)
        #expect(settings([builtIn: [swipe: 2]]).conflictsWithThreeFingerSwipe)
        // Either domain is enough (built-in vs Magic Trackpad), the most conflicting value wins.
        #expect(settings([builtIn: [swipe: 0], bluetooth: [swipe: 2]]).horizontalSwipe == .spaces)
        #expect(settings([builtIn: [swipe: 1], bluetooth: [swipe: 0]]).horizontalSwipe == .pages)
    }

    @Test func threeFingerPageSwipeConflicts() {
        #expect(settings([builtIn: [swipe: 1], bluetooth: [swipe: 1]]).conflictsWithThreeFingerSwipe)
    }

    @Test func threeFingerDragConflicts() {
        let s = settings([builtIn: [swipe: 0, drag: 1], bluetooth: [swipe: 0]])
        #expect(s.threeFingerDrag)
        #expect(s.conflictsWithThreeFingerSwipe)
    }

    @Test func unknownValuesAreIgnored() {
        #expect(settings([builtIn: [swipe: 7], bluetooth: [swipe: 0]]).horizontalSwipe == .off)
    }

    @Test func currentReadsWithoutCrashing() {
        _ = SystemTrackpadGestures.current()
        _ = TrackpadGestureRecognizer.systemThreeFingerSwipeConflicts
    }
}

@Suite struct GestureFrameSinkTests {
    private func summary(_ device: UInt, _ t: Double, _ n: Int, _ x: Float) -> Multitouch.FrameSummary {
        Multitouch.FrameSummary(device: device, timestamp: t, fingerCount: n, x: x, y: 0.5, contacts: 0b111)
    }

    private func activeState() -> GestureFrameSink.State {
        var state = GestureFrameSink.State()
        state.accepting = true
        return state
    }

    @Test func ignoresFramesWhenInactive() {
        var state = GestureFrameSink.State()
        #expect(!GestureFrameSink.consume(summary(1, 1.00, 3, 0.2), into: &state))
        #expect(!GestureFrameSink.consume(summary(1, 1.01, 3, 0.4), into: &state))
        #expect(state.pending.isEmpty)
    }

    @Test func coalescesIntoOneDrainUntilTaken() {
        var state = activeState()
        #expect(!GestureFrameSink.consume(summary(1, 1.00, 3, 0.2), into: &state))
        #expect(GestureFrameSink.consume(summary(1, 1.01, 3, 0.3), into: &state)) // open → schedule
        #expect(!GestureFrameSink.consume(summary(1, 1.02, 3, 0.34), into: &state)) // next → already scheduled
        #expect(state.pending == [.open(reverse: false), .next])
        state.pending.removeAll()
        state.drainScheduled = false // what `takePending` does
        #expect(GestureFrameSink.consume(summary(1, 1.03, 0, 0), into: &state))
        #expect(state.pending == [.end])
    }

    @Test func otherDevicesAreIgnoredWhileAGestureIsInProgress() {
        var state = activeState()
        _ = GestureFrameSink.consume(summary(1, 1.00, 3, 0.2), into: &state)
        // A Magic Mouse with one resting finger must not reset the trackpad's gesture.
        #expect(!GestureFrameSink.consume(summary(2, 1.005, 1, 0.9), into: &state))
        #expect(state.machine.phase == .tracking)
        #expect(GestureFrameSink.consume(summary(1, 1.01, 3, 0.3), into: &state))
        #expect(state.pending == [.open(reverse: false)])
        _ = GestureFrameSink.consume(summary(1, 1.02, 0, 0), into: &state)
        // Idle again: the other device may now drive the machine.
        state.pending.removeAll()
        state.drainScheduled = false
        _ = GestureFrameSink.consume(summary(2, 1.03, 3, 0.8), into: &state)
        #expect(state.device == 2)
        #expect(GestureFrameSink.consume(summary(2, 1.04, 3, 0.7), into: &state))
        #expect(state.pending == [.open(reverse: true)])
    }
}

@Suite @MainActor struct TrackpadGestureRecognizerTests {
    /// Construction and stop are side-effect free; `start()` is never called (it would start real devices).
    @Test func idleRecognizer() {
        let recognizer = TrackpadGestureRecognizer()
        #expect(!recognizer.isRunning)
        #expect(recognizer.deviceCount == 0)
        recognizer.stop()
        recognizer.rescanDevices() // no-op while stopped
        #expect(!recognizer.isRunning)
        #expect(recognizer.deviceCount == 0)
    }
}
