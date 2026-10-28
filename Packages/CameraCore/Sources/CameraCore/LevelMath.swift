import Foundation

/// Horizon level from CoreMotion gravity in the device frame: x to the right of the screen, y to the top of the
/// device, z out of the screen. Upright portrait gravity is about (0, -1, 0).
public enum LevelMath {
    /// Device roll in degrees in (-180, 180]: atan2(-gx, -gy). Portrait 0, landscapeLeft (top of the phone to the
    /// left) +90, landscapeRight -90, upside down 180. Flat on a table there is no screen-plane gravity to measure,
    /// so it returns 0, as it does for non-finite input.
    public static func rollDegrees(gravityX: Double, gravityY: Double) -> Double {
        guard gravityX.isFinite, gravityY.isFinite,
              gravityX * gravityX + gravityY * gravityY > flatThreshold * flatThreshold else { return 0 }
        let degrees = atan2(-gravityX, -gravityY) * 180 / .pi
        // atan2 gives -pi upside down when gx is +0, and the range keeps +180 for that pose.
        return degrees > -180 && degrees <= 180 ? degrees : 180
    }

    /// Signed distance from the nearest multiple of 90 degrees, in (-45, 45], so the level works in every orientation.
    /// Non-finite roll returns 0.
    public static func deviationFromLevel(_ roll: Double) -> Double {
        guard roll.isFinite else { return 0 }
        // remainder is exact and already lands in [-45, 45]; only -45 needs moving to the other end.
        let deviation = roll.remainder(dividingBy: 90)
        return deviation <= -45 ? deviation + 90 : deviation
    }

    /// Nearest quarter turn 0...3: round(roll / 90) mod 4 (positive modulo). +90 -> 1, 180 -> 2, -90 -> 3.
    /// Non-finite roll returns 0.
    public static func quarterTurns(_ roll: Double) -> Int {
        guard roll.isFinite else { return 0 }
        // Dropping whole turns first keeps the Int conversion in range for any finite roll.
        let turns = Int((roll.truncatingRemainder(dividingBy: 360) / 90).rounded())
        return ((turns % 4) + 4) % 4
    }

    /// Camera pitch in degrees: asin(-gz), +90 with the screen facing up (camera pointing down), -90 facing down.
    /// NaN returns 0.
    public static func pitchDegrees(gravityZ: Double) -> Double {
        guard !gravityZ.isNaN else { return 0 }
        // Gravity reads a little over 1 g while the phone moves, and asin is undefined past 1.
        return asin(Swift.min(Swift.max(-gravityZ, -1), 1)) * 180 / .pi
    }

    /// One step of exponential smoothing that goes the short way around the circle, so 170 and -170 meet at 180
    /// instead of sweeping through 0. Result in (-180, 180]; factor clamped 0...1.
    public static func smoothAngle(previous: Double, next: Double, factor: Double) -> Double {
        // A bad sample is skipped, and a bad history restarts from the new sample.
        guard next.isFinite else { return previous.isFinite ? normalizedDegrees(previous) : 0 }
        guard previous.isFinite else { return normalizedDegrees(next) }
        // A NaN factor shows the raw angle instead of freezing the level on an old one.
        let f = factor.isNaN ? 1 : Swift.min(Swift.max(factor, 0), 1)
        // Wrapping both first keeps the difference small, so huge inputs can't overflow it.
        let from = normalizedDegrees(previous)
        return normalizedDegrees(from + f * normalizedDegrees(normalizedDegrees(next) - from))
    }

    /// |deviationFromLevel| <= tolerance. A non-finite roll is never level, so a bad reading can't show a false match.
    public static func isLevel(_ roll: Double, tolerance: Double = 1) -> Bool {
        guard roll.isFinite else { return false }
        return abs(deviationFromLevel(roll)) <= tolerance
    }

    // MARK: - Helpers

    /// Wraps a finite angle into (-180, 180].
    static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.remainder(dividingBy: 360)
        return wrapped <= -180 ? wrapped + 360 : wrapped
    }

    // Under 0.001 g in the screen plane (about 0.06 degrees from flat) the direction is sensor noise.
    private static let flatThreshold = 0.001
}
