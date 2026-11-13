import Foundation

// MARK: - What a shot needs

/// What a NIGHT or LONG shot asks of the person holding the phone.
public enum SteadyNeed: String, Codable, Sendable, Hashable, CaseIterable {
    /// Short or aligned enough for steady hands.
    case holdStill
    /// A hand would smear it.
    case tripod
}

/// The one rule for whether a shot needs a tripod, shared by the status pill, the panels and the photo's metadata.
public enum SteadyAdvice {
    /// NIGHT shots longer than this need a tripod: the longest automatic time the planner gives steady hands.
    public static let nightHandheldSeconds = NightModePlanner.recommendedMaxSeconds(for: .steady)

    /// LONG: Real adds light over the whole time; a frame longer than a hand can hold this lens; frames that are not
    /// aligned. A handheld limit that isn't finite and positive is the 24 mm one, as in the night planner, and a frame
    /// of unknown length counts as too long to hold.
    public static func longExposure(plan: StackPlan, align: Bool, handheldLimit: Double) -> SteadyNeed {
        // Real adds light over the whole duration, so any movement smears the picture.
        if plan.blend == .additive { return .tripod }
        // Each frame on its own is longer than a steady hand can hold this lens.
        let limit = ExposureMath.isPositive(handheldLimit)
            ? handheldLimit : ExposureMath.handheldLimit(equivalentFocalLength: 24)
        if !(plan.frameSeconds <= limit) { return .tripod }
        // Without alignment, a handheld phone smears the background along with the moving subject.
        return align ? .holdStill : .tripod
    }

    /// NIGHT: a tripod when the person picked Tripod, or when the shot runs past `nightHandheldSeconds`. NaN seconds
    /// stand for the automatic time, which stays within steady hands' reach unless Tripod is picked.
    public static func night(stability: NightStabilityChoice, seconds: Double) -> SteadyNeed {
        if stability == .tripod { return .tripod }
        return seconds > nightHandheldSeconds ? .tripod : .holdStill
    }
}

// MARK: - The status pill

/// Where the shot is, for the status pill.
public enum SteadyPhase: Sendable, Hashable {
    /// Before the shutter: the person is framing and setting up.
    case framing
    /// A settle wait or a self timer is counting down.
    case countingDown
    /// Frames are still coming in.
    case capturing
}

/// The icon at the start of the pill.
public enum SteadyIcon: String, Sendable, Hashable {
    /// The drawn tripod glyph (SF Symbols has none).
    case tripod
    /// `hand.raised.fill`.
    case hand
}

/// What the status pill over the picture says, one case per state. The words are plain (no "stack", "frames" or
/// exposure terms) because the simple interface shows them too.
public enum SteadyMessage: Hashable, Sendable, CaseIterable {
    /// The shot needs a tripod and the phone is moving.
    case useTripod
    /// The phone is steady, on a tripod or braced, whatever the shot needs.
    case steady
    /// A shot steady hands can manage, and the phone is moving.
    case holdStill
    /// No motion sensor (the Simulator): what the shot needs, without claiming the phone moves or is steady.
    case noSensor(SteadyNeed)
    /// A settle wait or a self timer before the shot.
    case countingDown
    /// The shot is running and on target.
    case capturing
    /// A shot steady hands can manage has turned off target.
    case drifted
    /// A shot that needs a tripod was bumped.
    case bumped

    public static var allCases: [SteadyMessage] {
        [.useTripod, .steady, .holdStill] + SteadyNeed.allCases.map(SteadyMessage.noSensor)
            + [.countingDown, .capturing, .drifted, .bumped]
    }

    /// The message for the moment. During a shot only a bump (tripod shots) or drift (handheld shots) replaces
    /// "Keep still"; before it the steadiness speaks, unless there is no sensor to tell.
    public init(need: SteadyNeed, phase: SteadyPhase, isSteady: Bool, sensorAvailable: Bool = true,
                isOffTarget: Bool = false, wasBumped: Bool = false) {
        switch phase {
        case .capturing:
            if sensorAvailable, need == .tripod, wasBumped {
                self = .bumped
            } else if sensorAvailable, need == .holdStill, isOffTarget {
                self = .drifted
            } else {
                self = .capturing
            }
        case .countingDown:
            self = .countingDown
        case .framing:
            if !sensorAvailable {
                self = .noSensor(need)
            } else if isSteady {
                self = .steady
            } else {
                self = need == .tripod ? .useTripod : .holdStill
            }
        }
    }

    /// The pill's main line, sentence case without a full stop.
    public var title: String {
        switch self {
        case .useTripod: return "Use a tripod"
        case .steady: return "Steady"
        case .holdStill: return "Hold still"
        case .noSensor(let need): return need == .tripod ? "Use a tripod" : "Hold still"
        case .countingDown, .capturing: return "Keep still"
        case .drifted: return "Line up the crosses"
        case .bumped: return "The phone moved"
        }
    }

    /// A second, smaller line, only on warnings.
    public var detail: String? {
        switch self {
        case .useTripod: return "The phone is moving."
        case .bumped: return "Keep still."
        default: return nil
        }
    }

    /// The VoiceOver label: the whole pill as one sentence or two.
    public var spoken: String {
        switch self {
        case .useTripod: return "Use a tripod. The phone is moving."
        case .steady: return "The phone is steady."
        case .holdStill: return "Hold the phone still."
        case .noSensor(let need): return need == .tripod ? "Use a tripod." : "Hold still."
        case .countingDown, .capturing: return "Keep the phone still."
        case .drifted: return "The phone has turned. Line up the two crosses."
        case .bumped: return "The phone moved. Keep it still."
        }
    }

    /// A warning pill is filled with the accent colour and its text and icon take the colour that reads on it; the
    /// rest are dark with white text.
    public var isWarning: Bool {
        switch self {
        case .useTripod, .bumped: return true
        default: return false
        }
    }

    public var icon: SteadyIcon {
        switch self {
        case .holdStill, .drifted: return .hand
        case .noSensor(let need): return need == .tripod ? .tripod : .hand
        default: return .tripod
        }
    }

    /// On a dark pill the icon takes the accent colour when the phone is where the shot needs it, and stays white
    /// otherwise. Warnings draw it like their text.
    public var isIconAccented: Bool {
        switch self {
        case .steady, .countingDown, .capturing: return true
        default: return false
        }
    }
}

// MARK: - Steadiness

/// Whether the phone is steady, from the rotation speed the gyro reports, without the flicker a single sample would
/// cause: Steady after a still spell, and gone after a spell of motion or one sharp jolt, so a finger on a control of
/// a phone on a tripod doesn't flip it.
public struct StillnessDetector: Sendable, Hashable {
    /// Rotation speed in rad/s below which the phone counts as still. A tripod reads about 0.005, a careful hand
    /// about 0.05.
    public var stillThreshold: Double
    /// Seconds still before Steady.
    public var steadyAfter: Double
    /// Seconds of motion before Steady drops. A still pause shorter than this doesn't restart the count, so a
    /// phone that keeps moving between short pauses still drops.
    public var movingAfter: Double
    /// Rotation speed in rad/s at which one sample drops Steady at once: the phone was picked up.
    public var jolt: Double
    public private(set) var isSteady = false

    private var stillSince: TimeInterval?
    private var movingSince: TimeInterval?
    private var lastTime: TimeInterval?

    /// Samples come about 30 times a second; a silence longer than this means the sensor stopped, and what was
    /// seen before it says nothing about now.
    static let longestGap: TimeInterval = 1

    public init(stillThreshold: Double = 0.03, steadyAfter: Double = 1.5, movingAfter: Double = 0.5,
                jolt: Double = 0.25) {
        self.stillThreshold = stillThreshold
        self.steadyAfter = steadyAfter
        self.movingAfter = movingAfter
        self.jolt = jolt
    }

    /// One sample: the rotation speed (its size; the sign is ignored) at `time` in seconds, CoreMotion's timestamp.
    /// A NaN speed or a time that isn't finite is skipped; a time earlier than the last sample's, or after a long
    /// silence, starts over from this sample.
    public mutating func add(speed: Double, at time: TimeInterval) {
        guard !speed.isNaN, time.isFinite else { return }
        if let last = lastTime, time < last || time - last > Self.longestGap {
            reset()
        }
        lastTime = time
        let speed = abs(speed)
        if speed < stillThreshold {
            let since = stillSince ?? time
            stillSince = since
            if isSteady {
                // A pause as long as the drop delay forgives the motion before it.
                if movingSince != nil, time - since >= movingAfter { movingSince = nil }
            } else if time - since >= steadyAfter {
                isSteady = true
                movingSince = nil
            }
            return
        }
        stillSince = nil
        guard isSteady else { return }
        if speed >= jolt {
            drop()
            return
        }
        let since = movingSince ?? time
        movingSince = since
        if time - since >= movingAfter { drop() }
    }

    public mutating func reset() {
        isSteady = false
        stillSince = nil
        movingSince = nil
        lastTime = nil
    }

    private mutating func drop() {
        isSteady = false
        movingSince = nil
    }
}

// MARK: - Drift during a shot

/// An offset on screen in points: x to the right, y down, as SwiftUI lays out.
public struct DriftOffset: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = DriftOffset(x: 0, y: 0)

    public var length: Double { hypot(x, y) }
}

/// How far the camera has turned since a shot began, from the gyro's rotation rate, and the two flags the pill
/// shows: off target (handheld shots) and bumped (tripod shots). Rates are about the device axes (x to the right of
/// the screen, y to the top of the device, z out of the screen, right-hand rule), so with the interface held in
/// portrait they are screen axes in any pose. Integrating the rate fixes the signs by those axes alone, where the
/// frame an attitude difference comes back in would need a phone to pin down.
public struct DriftTracker: Sendable, Hashable {
    /// Points per radian of turn at true scale for the picture as laid out (`DriftMath.pointsPerRadian`). 0 until
    /// known, and while it is 0 the shot is never off target.
    public var pointsPerRadian: Double
    /// Radians since the start. Positive turns the back camera's aim up.
    public private(set) var angleX = 0.0
    /// Positive turns the aim to the left.
    public private(set) var angleY = 0.0
    /// Twist about the lens axis, counterclockwise as the person sees the screen.
    public private(set) var angleZ = 0.0
    /// The shown offset has been past `DriftMath.offTargetDistance` for `offTargetDelay`, and not yet back under
    /// `onTargetDistance`.
    public private(set) var isOffTarget = false
    /// A sample turned faster than `DriftMath.bumpSpeed` within the last `bumpHold` seconds. Speed, not the
    /// integrated angle, because integrated tripod noise over 30 s is about the size of a small bump.
    public private(set) var wasBumped = false

    private var lastTime: TimeInterval?
    private var farSince: TimeInterval?
    private var bumpedAt: TimeInterval?

    public init(pointsPerRadian: Double = 0) {
        self.pointsPerRadian = pointsPerRadian
    }

    /// One gyro sample in rad/s at `time` in seconds (CoreMotion's timestamp). The first sample only sets the time;
    /// each later one adds rate times the time since the last, at most `DriftMath.longestStep`, so a stall can't
    /// throw the cross. Each axis under `DriftMath.deadBand` adds nothing, so tripod noise doesn't walk the cross.
    /// A sample with a rate or time that isn't finite is skipped. A time earlier than the last sample's adds nothing
    /// and restarts the two flags.
    public mutating func add(rateX: Double, rateY: Double, rateZ: Double, at time: TimeInterval) {
        guard rateX.isFinite, rateY.isFinite, rateZ.isFinite, time.isFinite else { return }
        if let last = lastTime {
            if time < last {
                isOffTarget = false
                wasBumped = false
                farSince = nil
                bumpedAt = nil
            }
            let step = Swift.min(Swift.max(time - last, 0), DriftMath.longestStep)
            angleX += Self.live(rateX) * step
            angleY += Self.live(rateY) * step
            angleZ += Self.live(rateZ) * step
        }
        lastTime = time

        if hypot(hypot(rateX, rateY), rateZ) > DriftMath.bumpSpeed { bumpedAt = time }
        wasBumped = bumpedAt.map { time - $0 < DriftMath.bumpHold } ?? false

        let distance = displayOffset.length
        if isOffTarget {
            if distance < DriftMath.onTargetDistance {
                isOffTarget = false
                farSince = nil
            }
        } else if distance > DriftMath.offTargetDistance {
            let since = farSince ?? time
            farSince = since
            if time - since >= DriftMath.offTargetDelay { isOffTarget = true }
        } else {
            farSince = nil
        }
    }

    /// Where the camera points now relative to where it pointed at the start, at true scale.
    public func aimOffset(pointsPerRadian: Double) -> DriftOffset {
        DriftMath.aimOffset(angleX: angleX, angleY: angleY, pointsPerRadian: pointsPerRadian)
    }

    /// The moving cross's offset from the fixed one, as drawn with `pointsPerRadian`.
    public var displayOffset: DriftOffset {
        DriftMath.displayOffset(aimOffset(pointsPerRadian: pointsPerRadian))
    }

    /// Back to the start of a shot; `pointsPerRadian` stays.
    public mutating func reset() {
        self = DriftTracker(pointsPerRadian: pointsPerRadian)
    }

    private static func live(_ rate: Double) -> Double {
        abs(rate) < DriftMath.deadBand ? 0 : rate
    }
}

/// Scale, limits and thresholds of the drift crosshair. First guesses, to be tuned by hand and on a tripod in wind.
public enum DriftMath {
    /// rad/s per axis below which the gyro's reading is noise (a tripod reads about 0.005 in all).
    public static let deadBand = 0.004
    /// Seconds one sample may add at most.
    public static let longestStep = 0.1
    /// The cross moves this many times its true distance: at true scale half a degree of hand sway is 3 pt, yet
    /// about 25 px of blur on a 12 MP picture.
    public static let gain = 3.0
    /// Points the moving cross may sit from the fixed one; farther drift keeps its direction at this distance.
    public static let radius = 64.0
    /// Shown offsets under this many points are drawn as none.
    public static let minimumOffset = 1.0
    /// Shown points past which a handheld shot is off target, once it has stayed there `offTargetDelay` seconds.
    public static let offTargetDistance = 24.0
    /// Shown points under which it is back on target.
    public static let onTargetDistance = 16.0
    public static let offTargetDelay = 0.3
    /// rad/s in one sample that counts as a bump on a tripod shot.
    public static let bumpSpeed = 0.1
    /// Seconds a bump stays on the pill.
    public static let bumpHold = 3.0
    /// Degrees the moving cross's arms turn at most for a twist.
    public static let twistLimit = 45.0
    /// Seconds of capture after which the crosshair hides: integrated gyro drift grows with time, and Star trails
    /// or a long bulb would end with the cross somewhere the phone never went.
    public static let trackingLimit = 60.0

    /// Points per radian of turn at true scale: a lens of `equivalentFocalLength` (35 mm terms) moves the picture by
    /// that many millimetres on a 43.3 mm diagonal per radian, and the whole sensor image spans `imageDiagonal`
    /// points on screen. 0 when either isn't finite and positive.
    public static func pointsPerRadian(equivalentFocalLength: Double, imageDiagonal: Double) -> Double {
        guard ExposureMath.isPositive(equivalentFocalLength), ExposureMath.isPositive(imageDiagonal) else { return 0 }
        let value = equivalentFocalLength * imageDiagonal / LensMath.fullFrameDiagonal
        return value.isFinite ? value : 0
    }

    /// Where the camera points relative to where it started, as an on-screen pointer: turn right and it goes right,
    /// tilt up and it goes up. Zero for angles or a scale that aren't usable.
    public static func aimOffset(angleX: Double, angleY: Double, pointsPerRadian: Double) -> DriftOffset {
        guard ExposureMath.isPositive(pointsPerRadian), angleX.isFinite, angleY.isFinite else { return .zero }
        // Turning left (positive y) moves the aim left; tilting up (positive x) moves it up, which is -y on screen.
        let x = -angleY * pointsPerRadian
        let y = -angleX * pointsPerRadian
        return x.isFinite && y.isFinite ? DriftOffset(x: x, y: y) : .zero
    }

    /// The offset as drawn: `gain` times larger, kept within `radius` in the same direction, and none under
    /// `minimumOffset`. Zero for an offset that isn't finite, or a gain or radius that isn't positive.
    public static func displayOffset(_ offset: DriftOffset, gain: Double = DriftMath.gain,
                                     radius: Double = DriftMath.radius) -> DriftOffset {
        guard offset.x.isFinite, offset.y.isFinite, ExposureMath.isPositive(gain), radius > 0 else { return .zero }
        // Worked from the larger component, so neither squaring nor the gain can overflow the direction.
        let largest = Swift.max(abs(offset.x), abs(offset.y))
        guard largest > 0 else { return .zero }
        let unitX = offset.x / largest
        let unitY = offset.y / largest
        let unitLength = hypot(unitX, unitY)
        let length = largest * unitLength * gain
        guard length >= minimumOffset else { return .zero }
        let shown = Swift.min(length, radius, .greatestFiniteMagnitude)
        return DriftOffset(x: unitX / unitLength * shown, y: unitY / unitLength * shown)
    }

    /// Degrees to turn the moving cross's arms for a twist of `angleZ` radians: `gain` times the twist, within
    /// `twistLimit`, in SwiftUI's sense (clockwise positive), so a phone twisted counterclockwise turns the cross
    /// counterclockwise. 0 for a twist that isn't finite.
    public static func twistDegrees(_ angleZ: Double) -> Double {
        guard angleZ.isFinite else { return 0 }
        return ExposureMath.clamp(-angleZ * gain * 180 / .pi, -twistLimit, twistLimit)
    }
}

// MARK: - Battery saver

/// When the battery saver darkens the screen during a long shot. The screen stays lit for the start of the shot,
/// for its last seconds, while the phone moves (the crosshair has to be seen), while a finger holds the shutter, and
/// for a while after a touch woke it.
public enum DimPolicy {
    /// Shots shorter than this never dim: by the time it dims, it would be time to light it again.
    public static let minimumShotSeconds = 10.0
    /// The start of the shot stays visible this long.
    public static let startSeconds = 3.0
    /// A shot with less than this left stays lit, so the end and the result are seen.
    public static let minimumSecondsLeft = 5.0
    /// A shot without a set length (a bulb) dims after this long.
    public static let openEndedSeconds = 10.0
    /// A touch lights the screen for this long before it may dim again.
    public static let wakeSeconds = 10.0
    /// Brightness under the overlay, at most: on an LCD the backlight lights black too.
    public static let dimmedBrightness = 0.1

    /// - Parameters:
    ///   - isEnabled: the battery saver setting.
    ///   - isCapturing: a NIGHT, LONG or stacked MANUAL shot is taking its frames.
    ///   - elapsed: seconds since the shot started.
    ///   - total: the shot's estimated length in seconds; nil, or a value that isn't finite, for a shot that runs
    ///     until stopped.
    ///   - framesAllIn: every frame is in and the picture is being put together.
    ///   - isSteady: the phone is steady.
    ///   - sensorAvailable: the motion sensor works. Without it the phone counts as steady, so the Simulator can dim.
    ///   - bulbHeld: a finger holds the shutter.
    ///   - sinceWake: seconds since a touch last lit the screen during this shot; nil when none did. A value that
    ///     isn't a number counts as just now.
    public static func shouldDim(isEnabled: Bool, isCapturing: Bool, elapsed: Double, total: Double?,
                                 framesAllIn: Bool, isSteady: Bool, sensorAvailable: Bool, bulbHeld: Bool,
                                 sinceWake: Double?) -> Bool {
        guard isEnabled, isCapturing, !framesAllIn, !bulbHeld else { return false }
        guard isSteady || !sensorAvailable else { return false }
        if let sinceWake, !(sinceWake >= wakeSeconds) { return false }
        guard elapsed.isFinite else { return false }
        if let total, total.isFinite {
            return total >= minimumShotSeconds && elapsed >= startSeconds && total - elapsed >= minimumSecondsLeft
        }
        return elapsed >= openEndedSeconds
    }

    /// The brightness to set under the overlay: never above the person's own, never above `dimmedBrightness`. NaN
    /// counts as unknown and gets `dimmedBrightness`.
    public static func brightness(whileDimming saved: Double) -> Double {
        guard !saved.isNaN else { return dimmedBrightness }
        return Swift.min(Swift.max(saved, 0), dimmedBrightness)
    }
}
