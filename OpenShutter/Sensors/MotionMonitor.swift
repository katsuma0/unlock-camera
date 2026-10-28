import Foundation
import CoreMotion
import CameraCore

/// Turns CoreMotion gravity into the level, icon rotation and a "held still" signal for night mode.
@MainActor
final class MotionMonitor {
    var onUpdate: ((MotionState) -> Void)?

    private let manager = CMMotionManager()
    private var state = MotionState()
    private var smoothedRoll: Double?
    private var stillSince: Date?
    private var lastPublished = MotionState()

    /// Rotation rate (rad/s) below which the phone counts as still. A tripod reads around 0.005,
    /// a careful handheld grip around 0.05.
    private let stillThreshold = 0.03
    private let stillDuration: TimeInterval = 1.5

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
        stillSince = nil
    }

    private func handle(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let rawRoll = LevelMath.rollDegrees(gravityX: gravity.x, gravityY: gravity.y)
        let roll = smoothedRoll.map { LevelMath.smoothAngle(previous: $0, next: rawRoll, factor: 0.25) } ?? rawRoll
        smoothedRoll = roll

        let rate = motion.rotationRate
        let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
        let now = Date()
        if speed < stillThreshold {
            if stillSince == nil { stillSince = now }
        } else {
            stillSince = nil
        }

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
        next.isSteady = stillSince.map { now.timeIntervalSince($0) >= stillDuration } ?? false
        state = next

        // Publishing every 1/30 s would redraw SwiftUI for changes nobody sees. Only what a view shows counts: the
        // icons' quarter turn, the level line in half degree steps, level and steady flags, and whether the phone
        // lies flat, which hides the level.
        if abs(next.levelDeviation - lastPublished.levelDeviation) > 0.5
            || next.quarterTurns != lastPublished.quarterTurns
            || next.isLevel != lastPublished.isLevel
            || next.isSteady != lastPublished.isSteady
            || isFlat != (abs(lastPublished.pitch) > 70) {
            lastPublished = next
            onUpdate?(next)
        }
    }
}
