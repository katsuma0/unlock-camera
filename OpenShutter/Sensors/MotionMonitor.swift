import Foundation
import CoreMotion
import CameraCore

/// Turns CoreMotion into the level, the icons' rotation and the "steady" signal NIGHT and the tripod status use, and,
/// while a NIGHT or LONG shot runs, how far the phone has turned since it began (DriftState).
@MainActor
final class MotionMonitor {
    var onUpdate: ((MotionState) -> Void)?
    /// The drift's flags changed: tracking, off target or bumped. The angles go to DriftState alone, so nothing else
    /// redraws 30 times a second.
    var onDriftChange: (() -> Void)?
    /// Holds the angles back while nobody can see them (the battery saver's black screen). Tracking goes on, so the
    /// cross is in the right place when the screen lights up again.
    var pausesDriftAngles = false

    private let manager = CMMotionManager()
    private var state = MotionState()
    private var smoothedRoll: Double?
    /// Steady after a still spell, gone after a spell of motion or one jolt, so a finger on a control of a phone on a
    /// tripod doesn't flip it.
    private var stillness = StillnessDetector()
    private var lastPublished = MotionState()

    private var drift: DriftState?
    private var tracker = DriftTracker()
    /// The back camera aims where the cross says; the selfie camera's mirrored preview would turn the cross around.
    private var tracksAim = false
    private var lastAngleTime: TimeInterval?

    /// At most this many drift updates a second, whatever rate the sensor runs at.
    private static let angleInterval = 1.0 / 30

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            // The handler runs on the main queue, so hopping onto the main actor is free.
            MainActor.assumeIsolated {
                self?.handle(motion)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        smoothedRoll = nil
        // What the sensor saw before the pause says nothing about the phone when it starts again.
        stillness.reset()
        endDrift()
    }

    /// From the start of a stack: angles from zero, flags off until the first sample. `tracksAim` is false for the
    /// selfie camera, which still notices a bump.
    func beginDrift(into drift: DriftState, equivalentFocalLength: Double, tracksAim: Bool) {
        self.drift = drift
        self.tracksAim = tracksAim
        drift.begin(equivalentFocalLength: equivalentFocalLength)
        tracker = DriftTracker(pointsPerRadian: drift.pointsPerRadian)
        lastAngleTime = nil
        onDriftChange?()
    }

    /// The shot is over (all frames in, stopped, cancelled, failed or interrupted).
    func endDrift() {
        guard let drift else { return }
        self.drift = nil
        if drift.end() { onDriftChange?() }
    }

    private func handle(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let rawRoll = LevelMath.rollDegrees(gravityX: gravity.x, gravityY: gravity.y)
        let roll = smoothedRoll.map { LevelMath.smoothAngle(previous: $0, next: rawRoll, factor: 0.25) } ?? rawRoll
        smoothedRoll = roll

        let rate = motion.rotationRate
        let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
        // Sensor time, not the clock: samples queued behind a busy main thread keep their own spacing.
        stillness.add(speed: speed, at: motion.timestamp)

        let pitch = LevelMath.pitchDegrees(gravityZ: gravity.z)
        // Flat on a table the roll is meaningless; keep the last orientation instead of spinning icons.
        let isFlat = abs(pitch) > 70
        var next = state
        if !isFlat {
            next.roll = roll
            next.levelDeviation = LevelMath.deviationFromLevel(roll)
            // Held near 45 degrees, hand sway would spin every icon back and forth. Like UIDeviceOrientation, the
            // orientation only changes once the phone is about 10 degrees past the diagonal.
            let away = abs((roll - Double(state.quarterTurns) * 90).remainder(dividingBy: 360))
            if away > 55 {
                next.quarterTurns = LevelMath.quarterTurns(roll)
            }
            next.isLevel = LevelMath.isLevel(roll, tolerance: 1)
        }
        next.pitch = pitch
        next.isSteady = stillness.isSteady
        next.isAvailable = true
        state = next

        trackDrift(rate, at: motion.timestamp)

        // Publishing every 1/30 s would redraw SwiftUI for changes nobody sees. Only what a view shows counts: the
        // icons' quarter turn, the level line in half degree steps, level and steady flags, whether the phone lies
        // flat, which hides the level, and the first sample, which says the sensor works.
        if abs(next.levelDeviation - lastPublished.levelDeviation) > 0.5
            || next.quarterTurns != lastPublished.quarterTurns
            || next.isLevel != lastPublished.isLevel
            || next.isSteady != lastPublished.isSteady
            || next.isAvailable != lastPublished.isAvailable
            || isFlat != (abs(lastPublished.pitch) > 70) {
            lastPublished = next
            onUpdate?(next)
        }
    }

    private func trackDrift(_ rate: CMRotationRate, at time: TimeInterval) {
        guard let drift else { return }
        // The layout can change during a shot (the phone turned, the bands faded in), so the scale follows it.
        tracker.pointsPerRadian = drift.pointsPerRadian
        tracker.add(rateX: rate.x, rateY: rate.y, rateZ: rate.z, at: time)
        let tracking = tracksAim && !tracker.isPastTrackingLimit
        // Off target only while the crosses show: the pill would otherwise ask to line up crosses nobody can see.
        if drift.setFlags(tracking: tracking, offTarget: tracking && tracker.isOffTarget, bumped: tracker.wasBumped) {
            onDriftChange?()
        }
        guard tracking, !pausesDriftAngles else { return }
        if let last = lastAngleTime, time >= last, time - last < Self.angleInterval - 0.002 { return }
        lastAngleTime = time
        drift.setAngles(x: tracker.angleX, y: tracker.angleY, z: tracker.angleZ)
    }
}
