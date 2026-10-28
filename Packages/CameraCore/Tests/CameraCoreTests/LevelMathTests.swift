import Foundation
import XCTest
@testable import CameraCore

final class LevelMathTests: XCTestCase {
    /// Gravity in the screen plane after turning the phone counterclockwise (as seen from the front) by `degrees`
    /// from upright portrait.
    private func gravity(rotatedBy degrees: Double, length: Double = 1) -> (x: Double, y: Double) {
        let radians = degrees * .pi / 180
        return (-sin(radians) * length, -cos(radians) * length)
    }

    // MARK: - Roll

    func testRollInTheFourOrientations() {
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0, gravityY: -1), 0)      // portrait
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: -1, gravityY: 0), 90)     // landscapeLeft, top of the phone left
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 1, gravityY: 0), -90)     // landscapeRight
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0, gravityY: 1), 180)     // upside down
    }

    func testUpsideDownIsPlus180WhicheverZeroGravityXIs() {
        // gx = +0 makes atan2 see -0 and return -pi; the range is (-180, 180].
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0, gravityY: 1), 180)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: -0.0, gravityY: 1), 180)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0, gravityY: 0.4), 180)
    }

    func testRollSignFollowsTheTurnDirection() {
        // A small counterclockwise turn tips gravity towards -x and reads positive.
        XCTAssertGreaterThan(LevelMath.rollDegrees(gravityX: -0.05, gravityY: -0.99), 0)
        XCTAssertLessThan(LevelMath.rollDegrees(gravityX: 0.05, gravityY: -0.99), 0)
        // Just past upside down on either side.
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: -0.01, gravityY: 1), 180 - 0.5729386976834859, accuracy: 1e-9)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0.01, gravityY: 1), -180 + 0.5729386976834859, accuracy: 1e-9)
    }

    func testRollMatchesTheTurnAllTheWayAround() {
        var degrees = -179.0
        while degrees <= 180 {
            let g = gravity(rotatedBy: degrees)
            let roll = LevelMath.rollDegrees(gravityX: g.x, gravityY: g.y)
            XCTAssertEqual(roll, degrees, accuracy: 1e-9)
            XCTAssertGreaterThan(roll, -180)
            XCTAssertLessThanOrEqual(roll, 180)
            degrees += 1
        }
    }

    func testRollIgnoresTheGravityLength() {
        for length in [0.01, 0.3, 1, 1.4] {
            let g = gravity(rotatedBy: 30, length: length)
            XCTAssertEqual(LevelMath.rollDegrees(gravityX: g.x, gravityY: g.y), 30, accuracy: 1e-9)
        }
    }

    func testRollFlatOnATableIsZero() {
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0, gravityY: 0), 0)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 1e-5, gravityY: -1e-5), 0)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: -0.0004, gravityY: 0.0005), 0)
        // A real tilt is measured even when it is small.
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: -0.01, gravityY: 0), 90)
    }

    func testRollOfNonFiniteGravityIsZero() {
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: .nan, gravityY: -1), 0)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: 0, gravityY: .infinity), 0)
        XCTAssertEqual(LevelMath.rollDegrees(gravityX: -.infinity, gravityY: .nan), 0)
    }

    // MARK: - Deviation from level

    func testDeviationFromLevel() {
        XCTAssertEqual(LevelMath.deviationFromLevel(0), 0)
        XCTAssertEqual(LevelMath.deviationFromLevel(3), 3)
        XCTAssertEqual(LevelMath.deviationFromLevel(-3), -3)
        XCTAssertEqual(LevelMath.deviationFromLevel(88), -2)
        XCTAssertEqual(LevelMath.deviationFromLevel(92), 2)
        XCTAssertEqual(LevelMath.deviationFromLevel(-92), -2)
        XCTAssertEqual(LevelMath.deviationFromLevel(180), 0)
        XCTAssertEqual(LevelMath.deviationFromLevel(179), -1)
        XCTAssertEqual(LevelMath.deviationFromLevel(-179), 1)
        XCTAssertEqual(LevelMath.deviationFromLevel(270.5), 0.5)
        XCTAssertEqual(LevelMath.deviationFromLevel(721), 1)
        XCTAssertEqual(LevelMath.deviationFromLevel(44.9), 44.9, accuracy: 1e-12)
        XCTAssertEqual(LevelMath.deviationFromLevel(45.1), -44.9, accuracy: 1e-12)
    }

    func testDeviationExactlyBetweenQuartersIsPlus45() {
        XCTAssertEqual(LevelMath.deviationFromLevel(45), 45)
        XCTAssertEqual(LevelMath.deviationFromLevel(-45), 45)
        XCTAssertEqual(LevelMath.deviationFromLevel(135), 45)
        XCTAssertEqual(LevelMath.deviationFromLevel(-135), 45)
        XCTAssertEqual(LevelMath.deviationFromLevel(225), 45)
    }

    func testDeviationStaysInRange() {
        var roll = -720.0
        while roll <= 720 {
            let deviation = LevelMath.deviationFromLevel(roll)
            XCTAssertGreaterThan(deviation, -45, "\(roll)")
            XCTAssertLessThanOrEqual(deviation, 45, "\(roll)")
            roll += 0.25
        }
    }

    func testDeviationOfNonFiniteRollIsZero() {
        XCTAssertEqual(LevelMath.deviationFromLevel(.nan), 0)
        XCTAssertEqual(LevelMath.deviationFromLevel(.infinity), 0)
        XCTAssertEqual(LevelMath.deviationFromLevel(-.infinity), 0)
    }

    // MARK: - Quarter turns

    func testQuarterTurns() {
        XCTAssertEqual(LevelMath.quarterTurns(0), 0)
        XCTAssertEqual(LevelMath.quarterTurns(90), 1)
        XCTAssertEqual(LevelMath.quarterTurns(180), 2)
        XCTAssertEqual(LevelMath.quarterTurns(-90), 3)
        XCTAssertEqual(LevelMath.quarterTurns(-180), 2)
        XCTAssertEqual(LevelMath.quarterTurns(270), 3)
    }

    func testQuarterTurnsRoundToTheNearestQuarter() {
        XCTAssertEqual(LevelMath.quarterTurns(44), 0)
        XCTAssertEqual(LevelMath.quarterTurns(46), 1)
        XCTAssertEqual(LevelMath.quarterTurns(-44), 0)
        XCTAssertEqual(LevelMath.quarterTurns(-46), 3)
        XCTAssertEqual(LevelMath.quarterTurns(134), 1)
        XCTAssertEqual(LevelMath.quarterTurns(136), 2)
        XCTAssertEqual(LevelMath.quarterTurns(-134), 3)
        XCTAssertEqual(LevelMath.quarterTurns(-136), 2)
        XCTAssertEqual(LevelMath.quarterTurns(179.9), 2)
        XCTAssertEqual(LevelMath.quarterTurns(-179.9), 2)
    }

    func testQuarterTurnsRoundHalvesAwayFromZero() {
        XCTAssertEqual(LevelMath.quarterTurns(45), 1)
        XCTAssertEqual(LevelMath.quarterTurns(-45), 3)
        XCTAssertEqual(LevelMath.quarterTurns(135), 2)
        XCTAssertEqual(LevelMath.quarterTurns(-135), 2)
        XCTAssertEqual(LevelMath.quarterTurns(315), 0)
    }

    func testQuarterTurnsWrapWholeTurns() {
        XCTAssertEqual(LevelMath.quarterTurns(360), 0)
        XCTAssertEqual(LevelMath.quarterTurns(-360), 0)
        XCTAssertEqual(LevelMath.quarterTurns(450), 1)
        XCTAssertEqual(LevelMath.quarterTurns(-450), 3)
        XCTAssertEqual(LevelMath.quarterTurns(3780), 2)
        XCTAssertEqual(LevelMath.quarterTurns(-3690), 3)
        // 405 = 360 + 45 rounds the same way 45 does.
        XCTAssertEqual(LevelMath.quarterTurns(405), 1)
        XCTAssertEqual(LevelMath.quarterTurns(-405), 3)
    }

    func testQuarterTurnsNeverTrap() {
        for roll in [Double.nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            XCTAssertTrue((0...3).contains(LevelMath.quarterTurns(roll)), "\(roll)")
        }
        XCTAssertEqual(LevelMath.quarterTurns(.nan), 0)
        XCTAssertEqual(LevelMath.quarterTurns(.infinity), 0)
    }

    func testQuarterTurnsAgreeWithDeviation() {
        var roll = -400.0
        while roll <= 400 {
            let deviation = LevelMath.deviationFromLevel(roll)
            // At exactly 45 past a quarter the two documented ranges round differently, so ties are skipped.
            if abs(deviation) < 44.99 {
                let rebuilt = Double(LevelMath.quarterTurns(roll)) * 90 + deviation
                XCTAssertEqual(LevelMath.normalizedDegrees(rebuilt - roll), 0, accuracy: 1e-9, "\(roll)")
            }
            roll += 1.7
        }
    }

    // MARK: - Pitch

    func testPitch() {
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: -1), 90)     // screen up, camera pointing at the floor
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: 1), -90)     // screen down, camera pointing at the sky
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: 0), 0)       // upright
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: -0.5), 30, accuracy: 1e-9)
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: 0.5), -30, accuracy: 1e-9)
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: -(0.5.squareRoot())), 45, accuracy: 1e-9)
    }

    func testPitchClampsGravityPastOneG() {
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: -1.3), 90)
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: 2), -90)
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: -.infinity), 90)
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: .infinity), -90)
    }

    func testPitchOfNaNIsZero() {
        XCTAssertEqual(LevelMath.pitchDegrees(gravityZ: .nan), 0)
    }

    // MARK: - Smoothing

    func testSmoothAngleMovesByTheFactor() {
        XCTAssertEqual(LevelMath.smoothAngle(previous: 0, next: 10, factor: 0.5), 5)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: 0.25), 15)
        XCTAssertEqual(LevelMath.smoothAngle(previous: -20, next: -40, factor: 0.5), -30)
    }

    func testSmoothAngleTakesTheShortWayAcross180() {
        XCTAssertEqual(LevelMath.smoothAngle(previous: 170, next: -170, factor: 0.5), 180)
        XCTAssertEqual(LevelMath.smoothAngle(previous: -170, next: 170, factor: 0.5), 180)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 170, next: -170, factor: 0.25), 175)
        XCTAssertEqual(LevelMath.smoothAngle(previous: -170, next: 170, factor: 0.25), -175)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 175, next: -165, factor: 0.5), -175)
    }

    func testSmoothAngleConvergesWithoutSweepingThroughZero() {
        var angle = 170.0
        for _ in 0..<200 {
            angle = LevelMath.smoothAngle(previous: angle, next: -170, factor: 0.2)
            XCTAssertGreaterThanOrEqual(abs(angle), 170 - 1e-9)
            XCTAssertGreaterThan(angle, -180)
            XCTAssertLessThanOrEqual(angle, 180)
        }
        XCTAssertEqual(angle, -170, accuracy: 1e-9)
    }

    func testSmoothAngleClampsTheFactor() {
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: 0), 10)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: 1), 30)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: 3), 30)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: -1), 10)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: .infinity), 30)
        // NaN follows the sensor rather than freezing the level.
        XCTAssertEqual(LevelMath.smoothAngle(previous: 10, next: 30, factor: .nan), 30)
    }

    func testSmoothAngleNormalizesTheResult() {
        XCTAssertEqual(LevelMath.smoothAngle(previous: 350, next: 350, factor: 0.5), -10)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 0, next: 720, factor: 1), 0)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 170, next: -170, factor: 1), -170)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 90, next: -180, factor: 1), 180)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 3600, next: 3610, factor: 0.5), 5)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 1e300, next: -1e300, factor: 0.5),
                       LevelMath.smoothAngle(previous: LevelMath.normalizedDegrees(1e300),
                                             next: LevelMath.normalizedDegrees(-1e300), factor: 0.5))
    }

    func testSmoothAngleExactHalfTurnGoesPositive() {
        XCTAssertEqual(LevelMath.smoothAngle(previous: 0, next: 180, factor: 0.5), 90)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 0, next: -180, factor: 0.5), 90)
    }

    func testSmoothAngleSkipsBadSamples() {
        XCTAssertEqual(LevelMath.smoothAngle(previous: 12, next: .nan, factor: 0.5), 12)
        XCTAssertEqual(LevelMath.smoothAngle(previous: 370, next: .infinity, factor: 0.5), 10)
        XCTAssertEqual(LevelMath.smoothAngle(previous: .nan, next: -30, factor: 0.5), -30)
        XCTAssertEqual(LevelMath.smoothAngle(previous: -.infinity, next: 200, factor: 0.5), -160)
        XCTAssertEqual(LevelMath.smoothAngle(previous: .nan, next: .nan, factor: 0.5), 0)
    }

    // MARK: - Level check

    func testIsLevelWithTheDefaultTolerance() {
        XCTAssertTrue(LevelMath.isLevel(0))
        XCTAssertTrue(LevelMath.isLevel(0.9))
        XCTAssertTrue(LevelMath.isLevel(1))
        XCTAssertTrue(LevelMath.isLevel(-1))
        XCTAssertFalse(LevelMath.isLevel(1.1))
        XCTAssertFalse(LevelMath.isLevel(3))
        XCTAssertFalse(LevelMath.isLevel(45))
    }

    func testIsLevelInEveryOrientation() {
        XCTAssertTrue(LevelMath.isLevel(90.5))
        XCTAssertTrue(LevelMath.isLevel(-89.5))
        XCTAssertTrue(LevelMath.isLevel(179.5))
        XCTAssertTrue(LevelMath.isLevel(-179.5))
        XCTAssertTrue(LevelMath.isLevel(180))
        XCTAssertFalse(LevelMath.isLevel(92))
    }

    func testIsLevelWithACustomTolerance() {
        XCTAssertTrue(LevelMath.isLevel(3, tolerance: 5))
        XCTAssertTrue(LevelMath.isLevel(-5, tolerance: 5))
        XCTAssertFalse(LevelMath.isLevel(6, tolerance: 5))
        XCTAssertTrue(LevelMath.isLevel(0, tolerance: 0))
        XCTAssertFalse(LevelMath.isLevel(0.01, tolerance: 0))
        XCTAssertFalse(LevelMath.isLevel(0, tolerance: -1))
        XCTAssertFalse(LevelMath.isLevel(0, tolerance: .nan))
    }

    func testIsLevelIsFalseForAnUnknownRoll() {
        XCTAssertFalse(LevelMath.isLevel(.nan))
        XCTAssertFalse(LevelMath.isLevel(.infinity, tolerance: 90))
    }

    func testIsLevelAgreesWithRollFromGravity() {
        let g = gravity(rotatedBy: 90.4)
        XCTAssertTrue(LevelMath.isLevel(LevelMath.rollDegrees(gravityX: g.x, gravityY: g.y)))
        let tilted = gravity(rotatedBy: 2)
        XCTAssertFalse(LevelMath.isLevel(LevelMath.rollDegrees(gravityX: tilted.x, gravityY: tilted.y)))
    }

    // MARK: - Helpers

    func testNormalizedDegrees() {
        XCTAssertEqual(LevelMath.normalizedDegrees(0), 0)
        XCTAssertEqual(LevelMath.normalizedDegrees(180), 180)
        XCTAssertEqual(LevelMath.normalizedDegrees(-180), 180)
        XCTAssertEqual(LevelMath.normalizedDegrees(190), -170)
        XCTAssertEqual(LevelMath.normalizedDegrees(-190), 170)
        XCTAssertEqual(LevelMath.normalizedDegrees(540), 180)
        XCTAssertEqual(LevelMath.normalizedDegrees(-540), 180)
        XCTAssertEqual(LevelMath.normalizedDegrees(725), 5)
        XCTAssertEqual(LevelMath.normalizedDegrees(-360), 0)
    }
}
