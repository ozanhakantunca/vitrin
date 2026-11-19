// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Pure recognition logic for the trackpad switcher gesture: three fingers swiped horizontally open the
// switcher, further travel steps the selection, lifting commits. No I/O, no clocks: frames in, events out.

/// What the trackpad gesture asks the switcher to do.
public enum GestureEvent: Sendable, Hashable {
    /// Horizontal travel crossed the open threshold. `reverse` = the swipe went left.
    case open(reverse: Bool)
    /// One more step of travel to the right (forward).
    case next
    /// One more step of travel to the left (backward).
    case previous
    /// The fingers lifted after an `open` (commit the selection).
    case end
}

/// One multitouch frame, reduced to what the recognizer needs. Built without allocation on the
/// MultitouchSupport thread.
public struct TouchFrame: Sendable, Hashable {
    /// One finger on the pad.
    public struct Touch: Sendable, Hashable {
        public var id: Int32
        /// Normalized pad coordinates: x 0 (left) … 1 (right), y 0 (bottom) … 1 (top).
        public var x: Float
        public var y: Float

        public init(id: Int32, x: Float, y: Float) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    /// Seconds, monotonic (MultitouchSupport reports host uptime).
    public var timestamp: Double
    /// Fingers touching the pad (hovering / lifting contacts excluded).
    public var fingerCount: Int
    /// Centroid of the touching fingers (undefined when `fingerCount == 0`).
    public var x: Float
    public var y: Float
    /// Bit set of contact identifiers (`1 << (id & 63)`). A change with an unchanged count means a finger
    /// was swapped, so the centroid jumped; the machine re-anchors instead of reading it as travel.
    public var contacts: UInt64

    public init(timestamp: Double, fingerCount: Int, x: Float = 0, y: Float = 0, contacts: UInt64 = 0) {
        self.timestamp = timestamp
        self.fingerCount = fingerCount
        self.x = x
        self.y = y
        self.contacts = contacts
    }

    public init(timestamp: Double, touches: [Touch]) {
        var sumX: Float = 0, sumY: Float = 0, contacts: UInt64 = 0
        for touch in touches {
            sumX += touch.x
            sumY += touch.y
            contacts |= Self.contactBit(touch.id)
        }
        let count = Float(max(touches.count, 1))
        self.init(timestamp: timestamp, fingerCount: touches.count, x: sumX / count, y: sumY / count, contacts: contacts)
    }

    public static func contactBit(_ id: Int32) -> UInt64 {
        1 << UInt64(UInt32(bitPattern: id) & 63)
    }
}

/// Recognizes exactly-N-finger (default 3) horizontal swipes.
///
/// - **idle** → N fingers down → **tracking** (anchored at the centroid). More than N → **rejected**.
/// - **tracking**: net horizontal displacement `|dx| ≥ openThreshold` with `|dx| ≥ horizontalDominance·|dy|`
///   emits `.open(reverse: dx < 0)` (right = forward). Vertical displacement `|dy| ≥ verticalRejectThreshold`
///   that dominates `|dx|` → **rejected** (Mission Control / App Exposé swipes). Count change → idle /
///   rejected, no events.
/// - **open**: every further `stepDistance` of horizontal travel emits `.next` (right) / `.previous` (left);
///   vertical travel is ignored. Count drops below N → `.end`, back to idle. More than N fingers pauses
///   stepping; it resumes (re-anchored) when exactly N touch again.
/// - **rejected**: ignores everything until fewer than N fingers touch.
/// - A frame gap longer than `maxFrameGap` (a lost lift frame, sleep) or a clock going backwards ends the
///   gesture as if the fingers had lifted (`.end` if open) before the new frame is processed.
public struct SwipeStateMachine: Sendable {
    public struct Configuration: Sendable, Hashable {
        public var fingerCount = 3
        /// Net horizontal travel (fraction of pad width) that opens the switcher.
        public var openThreshold: Float = 0.06
        /// Additional travel per selection step after opening.
        public var stepDistance: Float = 0.07
        /// Vertical travel that classifies the gesture as vertical (when it also dominates horizontally).
        public var verticalRejectThreshold: Float = 0.04
        /// Opening requires `|dx| ≥ horizontalDominance · |dy|`.
        public var horizontalDominance: Float = 1.5
        /// Longer gaps between frames end the gesture.
        public var maxFrameGap: Double = 0.5
        /// Cap on steps emitted by one frame (a glitchy jump must not flood the switcher).
        public var maxStepsPerFrame = 4

        public init() {}
    }

    /// Observable phase (for tests and diagnostics).
    public enum Phase: Sendable, Hashable {
        case idle
        case tracking
        case open
        case rejected
    }

    private enum State: Sendable {
        case idle
        case tracking(originX: Float, originY: Float)
        /// `stepAnchor == nil`: paused (too many fingers); re-anchor on the next valid frame.
        case open(stepAnchor: Float?)
        case rejected
    }

    public let configuration: Configuration
    private var state: State = .idle
    private var contacts: UInt64 = 0
    private var lastTimestamp: Double?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var phase: Phase {
        switch state {
        case .idle: return .idle
        case .tracking: return .tracking
        case .open: return .open
        case .rejected: return .rejected
        }
    }

    /// Forgets the current gesture without emitting anything (device restart, recognizer stopped).
    public mutating func reset() {
        state = .idle
        contacts = 0
        lastTimestamp = nil
    }

    /// Feeds one frame. Returns the events it produced, usually none (an empty array does not allocate).
    public mutating func consume(_ frame: TouchFrame) -> [GestureEvent] {
        var events: [GestureEvent] = []
        if let last = lastTimestamp, frame.timestamp - last > configuration.maxFrameGap || frame.timestamp < last {
            if case .open = state { events.append(.end) }
            state = .idle
        }
        lastTimestamp = frame.timestamp

        let target = configuration.fingerCount
        let count = frame.fingerCount
        switch state {
        case .idle:
            if count == target {
                begin(frame)
            } else if count > target {
                state = .rejected
            }

        case let .tracking(originX, originY):
            if count < target {
                state = .idle
            } else if count > target {
                state = .rejected
            } else if frame.contacts != contacts {
                begin(frame) // a finger was swapped: the centroid jump is not travel
            } else {
                let dx = frame.x - originX
                let dy = frame.y - originY
                if abs(dx) >= configuration.openThreshold && abs(dx) >= configuration.horizontalDominance * abs(dy) {
                    let reverse = dx < 0
                    events.append(.open(reverse: reverse))
                    // Anchor steps at the exact threshold crossing so a fast first frame keeps its overshoot.
                    let anchor = originX + (reverse ? -configuration.openThreshold : configuration.openThreshold)
                    state = .open(stepAnchor: step(from: anchor, to: frame.x, into: &events))
                } else if abs(dy) >= configuration.verticalRejectThreshold && abs(dy) > abs(dx) {
                    state = .rejected
                }
            }

        case let .open(stepAnchor):
            if count < target {
                events.append(.end)
                state = .idle
            } else if count > target {
                state = .open(stepAnchor: nil)
            } else if stepAnchor == nil || frame.contacts != contacts {
                contacts = frame.contacts
                state = .open(stepAnchor: frame.x)
            } else if let anchor = stepAnchor {
                state = .open(stepAnchor: step(from: anchor, to: frame.x, into: &events))
            }

        case .rejected:
            if count < target { state = .idle }
        }
        return events
    }

    private mutating func begin(_ frame: TouchFrame) {
        contacts = frame.contacts
        state = .tracking(originX: frame.x, originY: frame.y)
    }

    /// Emits one step per `stepDistance` travelled from `anchor` to `x`; returns the advanced anchor.
    private func step(from anchor: Float, to x: Float, into events: inout [GestureEvent]) -> Float {
        let distance = configuration.stepDistance
        guard distance > 0, x.isFinite, anchor.isFinite else { return x.isFinite ? x : anchor }
        let travel = x - anchor
        let steps = (abs(travel) / distance).rounded(.down)
        guard steps >= 1 else { return anchor }
        let event: GestureEvent = travel > 0 ? .next : .previous
        let emitted = min(Int(min(steps, 1_000)), max(configuration.maxStepsPerFrame, 0))
        events.append(contentsOf: repeatElement(event, count: emitted))
        return anchor + (travel > 0 ? steps : -steps) * distance
    }
}
