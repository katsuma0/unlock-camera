import XCTest
@testable import CameraCore

final class BracketPlanTests: XCTestCase {
    private let phone = ExposureRanges(seconds: (1.0 / 8000)...1, iso: 50...3200, aperture: 1.78...1.78)

    private func assertEqual(_ a: [Double], _ b: [Double], accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "\(a) vs \(b)", file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y, accuracy: accuracy, "\(a) vs \(b)", file: file, line: line)
        }
    }

    private func decode(_ json: String) throws -> BracketPlan {
        try JSONDecoder().decode(BracketPlan.self, from: Data(json.utf8))
    }

    // MARK: - Kind and limits

    func testKindTitlesAndIDs() {
        XCTAssertEqual(BracketKind.allCases, [.off, .exposure, .focus, .whiteBalance])
        XCTAssertEqual(BracketKind.allCases.map(\.title), ["Off", "Exposure", "Focus", "White balance"])
        XCTAssertEqual(BracketKind.allCases.map(\.id), ["off", "exposure", "focus", "whiteBalance"])
    }

    func testDefaultsAndOff() {
        let plan = BracketPlan()
        XCTAssertEqual(plan.kind, .off)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.step, 1)
        XCTAssertEqual(plan, .off)
        XCTAssertTrue(BracketPlan.off.isOff)
        XCTAssertFalse(BracketPlan(kind: .exposure).isOff)
        XCTAssertFalse(BracketPlan(kind: .focus).isOff)
        XCTAssertEqual(BracketPlan(kind: .exposure), BracketPlan(kind: .exposure, count: 3, step: 1))
    }

    func testExposureAndWhiteBalanceCountsAreOddAndClamped() {
        let expected: [(Int, Int)] = [(Int.min, 3), (-7, 3), (0, 3), (1, 3), (2, 3), (3, 3), (4, 5), (5, 5), (6, 7),
                                      (7, 7), (8, 9), (9, 9), (10, 9), (11, 9), (Int.max, 9)]
        for kind in [BracketKind.exposure, .whiteBalance] {
            for (input, output) in expected {
                XCTAssertEqual(BracketPlan(kind: kind, count: input).count, output, "\(kind) \(input)")
            }
        }
    }

    func testFocusCountIsClamped() {
        let expected: [(Int, Int)] = [(Int.min, 2), (0, 2), (1, 2), (2, 2), (8, 8), (15, 15), (30, 30), (31, 30),
                                      (Int.max, 30)]
        for (input, output) in expected {
            XCTAssertEqual(BracketPlan(kind: .focus, count: input).count, output, "\(input)")
        }
    }

    func testOffKeepsCountAndStep() {
        let plan = BracketPlan(kind: .off, count: 7, step: 2.5)
        XCTAssertEqual(plan.count, 7)
        XCTAssertEqual(plan.step, 2.5)
        XCTAssertEqual(plan.exposureOffsets(), [0])
        XCTAssertEqual(plan.summary, "Off")
        // JSON cannot hold NaN or infinity, so those fall back to the default step.
        XCTAssertEqual(BracketPlan(kind: .off, step: .nan).step, 1)
        XCTAssertEqual(BracketPlan(kind: .off, step: .infinity).step, 1)
    }

    func testStepClampsPerKind() {
        XCTAssertEqual(BracketPlan(kind: .exposure, step: 0.1).step, 0.3)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: 0.3).step, 0.3)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: 1.0 / 3.0).step, 1.0 / 3.0)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: 3).step, 3)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: 5).step, 3)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: -1).step, 0.3)
        XCTAssertEqual(BracketPlan(kind: .focus, step: 0.001).step, 0.005)
        XCTAssertEqual(BracketPlan(kind: .focus, step: 0.05).step, 0.05)
        XCTAssertEqual(BracketPlan(kind: .focus, step: 1).step, 0.5)
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, step: 2).step, 5)
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, step: 10).step, 10)
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, step: 200).step, 100)
    }

    func testNonFiniteSteps() {
        // NaN takes the default step of 1 before the clamp; infinities go to the nearer bound.
        XCTAssertEqual(BracketPlan(kind: .exposure, step: .nan).step, 1)
        XCTAssertEqual(BracketPlan(kind: .focus, step: .nan).step, 0.5)
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, step: .nan).step, 5)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: .infinity).step, 3)
        XCTAssertEqual(BracketPlan(kind: .exposure, step: -.infinity).step, 0.3)
    }

    // MARK: - Exposure

    func testExposureOffsetsCenterFirstThenAlternating() {
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 3, step: 1).exposureOffsets(), [0, -1, 1])
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 5, step: 1).exposureOffsets(), [0, -1, 1, -2, 2])
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 9, step: 0.5).exposureOffsets(),
                       [0, -0.5, 0.5, -1, 1, -1.5, 1.5, -2, 2])
        // An even count rounds up to the next odd one.
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 4, step: 2).exposureOffsets(), [0, -2, 2, -4, 4])
        XCTAssertEqual(BracketPlan.off.exposureOffsets(), [0])
    }

    func testExposureOffsetsInThirdStops() {
        let offsets = BracketPlan(kind: .exposure, count: 5, step: 1.0 / 3.0).exposureOffsets()
        assertEqual(offsets, [0, -1.0 / 3.0, 1.0 / 3.0, -2.0 / 3.0, 2.0 / 3.0], accuracy: 1e-12)
        XCTAssertEqual(offsets.reduce(0, +), 0, accuracy: 1e-12)
    }

    func testExposureOffsetsForOtherKindsKeepOneExposure() {
        XCTAssertEqual(BracketPlan(kind: .focus, count: 8, step: 0.05).exposureOffsets(), [0])
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, count: 5, step: 10).exposureOffsets(), [0])
    }

    func testExposuresChangeTheShutterFirst() {
        let base = ExposureValues(seconds: 1.0 / 125, iso: 100, aperture: 1.78)
        let shots = BracketPlan(kind: .exposure, count: 3, step: 1).exposures(around: base, ranges: phone)
        XCTAssertEqual(shots.count, 3)
        XCTAssertEqual(shots[0], base)
        XCTAssertEqual(shots[1].seconds, 1.0 / 250, accuracy: 1e-15)
        XCTAssertEqual(shots[2].seconds, 2.0 / 125, accuracy: 1e-15)
        for shot in shots {
            XCTAssertEqual(shot.iso, 100)
            XCTAssertEqual(shot.aperture, 1.78)
        }
    }

    func testExposuresMoveLeftoverStopsIntoISOAtTheShortEnd() {
        let base = ExposureValues(seconds: 1.0 / 4000, iso: 100, aperture: 1.78)
        let shots = BracketPlan(kind: .exposure, count: 5, step: 2).exposures(around: base, ranges: phone)
        // Offsets 0, -2, +2, -4, +4. At -2 the shutter has one stop left and ISO takes the other;
        // at -4 ISO runs out as well, so that frame is brighter than asked.
        // Typed on its own line: Swift 6.4 gives up on the inline literal of five divisions.
        let seconds: [Double] = [1.0 / 4000, 1.0 / 8000, 1.0 / 1000, 1.0 / 8000, 1.0 / 250]
        XCTAssertEqual(shots.map(\.seconds), seconds)
        assertEqual(shots.map(\.iso), [100, 50, 100, 50, 100])
    }

    func testExposuresMoveLeftoverStopsIntoISOAtTheLongEnd() {
        let base = ExposureValues(seconds: 0.5, iso: 400, aperture: 1.78)
        let shots = BracketPlan(kind: .exposure, count: 3, step: 2).exposures(around: base, ranges: phone)
        XCTAssertEqual(shots, [base, ExposureValues(seconds: 0.125, iso: 400, aperture: 1.78),
                               ExposureValues(seconds: 1, iso: 800, aperture: 1.78)])
        let hot = BracketPlan(kind: .exposure, count: 3, step: 3)
            .exposures(around: ExposureValues(seconds: 0.5, iso: 3200, aperture: 1.78), ranges: phone)
        XCTAssertEqual(hot[2], ExposureValues(seconds: 1, iso: 3200, aperture: 1.78))
    }

    func testExposuresKeepTheRequestedSpacingInsideTheRanges() {
        let base = ExposureValues(seconds: 1.0 / 60, iso: 200, aperture: 1.78)
        for step in [1.0 / 3.0, 0.5, 2.0 / 3.0, 1] {
            let plan = BracketPlan(kind: .exposure, count: 7, step: step)
            let shots = plan.exposures(around: base, ranges: phone)
            XCTAssertEqual(shots.count, 7)
            for (shot, offset) in zip(shots, plan.exposureOffsets()) {
                XCTAssertEqual(ExposureMath.stops(from: base, to: shot), offset, accuracy: 1e-9)
                XCTAssertEqual(shot.iso, 200)
            }
        }
    }

    func testExposuresClampTheBaseFirst() {
        let base = ExposureValues(seconds: 5, iso: 10, aperture: 2.8)
        let clamped = ExposureValues(seconds: 1, iso: 50, aperture: 1.78)
        XCTAssertEqual(BracketPlan.off.exposures(around: base, ranges: phone), [clamped])
        XCTAssertEqual(BracketPlan(kind: .focus, count: 8, step: 0.05).exposures(around: base, ranges: phone),
                       [clamped])
        XCTAssertEqual(BracketPlan(kind: .whiteBalance).exposures(around: base, ranges: phone), [clamped])
        let shots = BracketPlan(kind: .exposure, count: 3, step: 1).exposures(around: base, ranges: phone)
        XCTAssertEqual(shots, [clamped, ExposureValues(seconds: 0.5, iso: 50, aperture: 1.78),
                               ExposureValues(seconds: 1, iso: 100, aperture: 1.78)])
    }

    // MARK: - Focus

    func testFocusPositionsCentredOnTheCenter() {
        assertEqual(BracketPlan(kind: .focus, count: 3, step: 0.1).focusPositions(center: 0.5), [0.4, 0.5, 0.6])
        assertEqual(BracketPlan(kind: .focus, count: 2, step: 0.2).focusPositions(center: 0.5), [0.4, 0.6])
        assertEqual(BracketPlan(kind: .focus, count: 4, step: 0.05).focusPositions(center: 0.3),
                    [0.225, 0.275, 0.325, 0.375])
    }

    func testFocusPositionsShiftNearTheEnds() {
        assertEqual(BracketPlan(kind: .focus, count: 3, step: 0.1).focusPositions(center: 0.05), [0, 0.1, 0.2])
        assertEqual(BracketPlan(kind: .focus, count: 3, step: 0.1).focusPositions(center: 0), [0, 0.1, 0.2])
        assertEqual(BracketPlan(kind: .focus, count: 4, step: 0.1).focusPositions(center: 0.97), [0.7, 0.8, 0.9, 1])
        // A run exactly as wide as the range fills it.
        assertEqual(BracketPlan(kind: .focus, count: 3, step: 0.5).focusPositions(center: 0.9), [0, 0.5, 1])
    }

    func testFocusPositionsWiderThanTheRangeAreClampedAndDeduplicated() {
        assertEqual(BracketPlan(kind: .focus, count: 30, step: 0.5).focusPositions(center: 0.9), [0, 0.15, 0.65, 1])
        assertEqual(BracketPlan(kind: .focus, count: 4, step: 0.5).focusPositions(center: 0.95), [0.2, 0.7, 1])
    }

    func testFocusPositionsKeepCountAndSpacingWheneverTheyFit() {
        let plan = BracketPlan(kind: .focus, count: 5, step: 0.1)
        for i in 0...20 {
            let center = Double(i) / 20
            let positions = plan.focusPositions(center: center)
            XCTAssertEqual(positions.count, 5, "center \(center)")
            XCTAssertGreaterThanOrEqual(positions.first ?? -1, 0)
            XCTAssertLessThanOrEqual(positions.last ?? 2, 1)
            for (a, b) in zip(positions, positions.dropFirst()) {
                XCTAssertEqual(b - a, 0.1, accuracy: 1e-9, "center \(center)")
            }
            // Away from the ends nothing shifts, so the run stays centred.
            if center >= 0.2 && center <= 0.8 {
                XCTAssertEqual(positions.reduce(0, +) / 5, center, accuracy: 1e-9)
            }
        }
    }

    func testFocusPositionsForOffAndOtherKinds() {
        XCTAssertEqual(BracketPlan.off.focusPositions(center: 0.3), [0.3])
        XCTAssertEqual(BracketPlan(kind: .exposure).focusPositions(center: 0.3), [0.3])
        XCTAssertEqual(BracketPlan(kind: .whiteBalance).focusPositions(center: 0.3), [0.3])
        // AVFoundation rejects lens positions outside 0...1, so the center is clamped.
        XCTAssertEqual(BracketPlan.off.focusPositions(center: 1.4), [1])
        XCTAssertEqual(BracketPlan.off.focusPositions(center: -0.2), [0])
        assertEqual(BracketPlan(kind: .focus, count: 3, step: 0.1).focusPositions(center: 3), [0.8, 0.9, 1])
    }

    // MARK: - White balance

    func testKelvinValuesFollowMiredOffsets() {
        assertEqual(BracketPlan(kind: .whiteBalance, count: 3, step: 10).kelvinValues(center: 5000),
                    [5000, 1e6 / 190, 1e6 / 210])
        assertEqual(BracketPlan(kind: .whiteBalance, count: 5, step: 20).kelvinValues(center: 5000),
                    [5000, 1e6 / 180, 1e6 / 220, 6250, 1e6 / 240])
        // -s mireds is bluer (higher Kelvin), +s is warmer.
        let values = BracketPlan(kind: .whiteBalance, count: 3, step: 25).kelvinValues(center: 4000)
        XCTAssertGreaterThan(values[1], values[0])
        XCTAssertLessThan(values[2], values[0])
    }

    func testKelvinValuesAreClamped() {
        let values = BracketPlan(kind: .whiteBalance, count: 9, step: 100).kelvinValues(center: 9000)
        let centerMired = 1e6 / 9000
        let expected = [0, -1, 1, -2, 2, -3, 3, -4, 4].map { k -> Double in
            let mired = centerMired + Double(k) * 100
            return mired > 0 ? min(max(1e6 / mired, 1000), 40000) : 40000
        }
        assertEqual(values, expected, accuracy: 1e-6)
        XCTAssertEqual(values[1], 40000)
        XCTAssertEqual(values[3], 40000)
        XCTAssertEqual(values[8], 1e6 / (centerMired + 400), accuracy: 1e-6)
        for value in values {
            XCTAssertTrue((1000...40000).contains(value))
        }
        // 1500 K plus 400 mireds would be about 940 K.
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, count: 9, step: 100).kelvinValues(center: 1500)[8], 1000)
    }

    func testKelvinCenterOutsideTheRangeIsClampedFirst() {
        assertEqual(BracketPlan(kind: .whiteBalance, count: 3, step: 10).kelvinValues(center: 50000),
                    [40000, 40000, 1e6 / 35])
        assertEqual(BracketPlan(kind: .whiteBalance, count: 3, step: 10).kelvinValues(center: 500),
                    [1000, 1e6 / 990, 1000])
    }

    func testCandleAndTheDialEndsBracketAroundTheirOwnValue() {
        // Candle is 1900 K, below the dial's 2000...10000 K; clamping to the dial range would repeat frames.
        assertEqual(BracketPlan(kind: .whiteBalance, count: 3, step: 10).kelvinValues(center: 1900),
                    [1900, 1e6 / (1e6 / 1900 - 10), 1e6 / (1e6 / 1900 + 10)])
        for center in [1900.0, 2000, 10000] {
            let values = BracketPlan(kind: .whiteBalance, count: 5, step: 20).kelvinValues(center: center)
            XCTAssertEqual(values[0], center, accuracy: 1e-9)
            XCTAssertEqual(Set(values).count, values.count, "\(values)")
        }
    }

    func testKelvinValuesForOffAndOtherKinds() {
        XCTAssertEqual(BracketPlan.off.kelvinValues(center: 5000), [5000])
        XCTAssertEqual(BracketPlan(kind: .exposure).kelvinValues(center: 3200), [3200])
        XCTAssertEqual(BracketPlan(kind: .focus).kelvinValues(center: 3200), [3200])
        XCTAssertEqual(BracketPlan.off.kelvinValues(center: 15000), [15000])
        XCTAssertEqual(BracketPlan.off.kelvinValues(center: 50000), [40000])
    }

    // MARK: - Summary

    func testSummary() {
        XCTAssertEqual(BracketPlan.off.summary, "Off")
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 3, step: 1).summary, "3 \u{00D7} \u{00B1}1 EV")
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 5, step: 0.67).summary, "5 \u{00D7} \u{00B1}0.7 EV")
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 5, step: 2.0 / 3.0).summary, "5 \u{00D7} \u{00B1}0.7 EV")
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 3, step: 1.0 / 3.0).summary, "3 \u{00D7} \u{00B1}0.3 EV")
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 7, step: 1.5).summary, "7 \u{00D7} \u{00B1}1.5 EV")
        XCTAssertEqual(BracketPlan(kind: .exposure, count: 4, step: 2).summary, "5 \u{00D7} \u{00B1}2 EV")
        XCTAssertEqual(BracketPlan(kind: .focus, count: 8, step: 0.05).summary, "Focus \u{00D7} 8")
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, count: 3, step: 10).summary, "WB 3 \u{00D7} \u{00B1}10 mired")
        XCTAssertEqual(BracketPlan(kind: .whiteBalance, count: 5, step: 12.5).summary,
                       "WB 5 \u{00D7} \u{00B1}12.5 mired")
    }

    // MARK: - Mutation and Codable

    func testReassignedPropertiesStillRespectTheLimits() {
        var plan = BracketPlan(kind: .exposure)
        plan.count = 100
        plan.step = 50
        XCTAssertEqual(plan.exposureOffsets().count, 9)
        XCTAssertEqual(plan.exposureOffsets().last, 12)
        XCTAssertEqual(plan.summary, "9 \u{00D7} \u{00B1}3 EV")
        plan.kind = .focus
        let positions = plan.focusPositions(center: 0.5)
        XCTAssertLessThanOrEqual(positions.count, 30)
        XCTAssertEqual(positions.first, 0)
        XCTAssertEqual(positions.last, 1)
        plan.kind = .whiteBalance
        XCTAssertEqual(plan.kelvinValues(center: 5000).count, 9)
        plan.count = -4
        plan.kind = .exposure
        XCTAssertEqual(plan.exposureOffsets().count, 3)
    }

    func testCodableRoundTrip() throws {
        let plans = [BracketPlan.off, BracketPlan(kind: .exposure, count: 5, step: 2.0 / 3.0),
                     BracketPlan(kind: .focus, count: 12, step: 0.02), BracketPlan(kind: .whiteBalance, count: 7, step: 15),
                     BracketPlan(kind: .off, count: 5, step: 0.7)]
        for plan in plans {
            XCTAssertEqual(try JSONDecoder().decode(BracketPlan.self, from: JSONEncoder().encode(plan)), plan)
        }
    }

    func testDecodingAppliesClampsAndDefaults() throws {
        XCTAssertEqual(try decode("{}"), .off)
        XCTAssertEqual(try decode(#"{"kind":"exposure","count":4,"step":0.1}"#),
                       BracketPlan(kind: .exposure, count: 5, step: 0.3))
        XCTAssertEqual(try decode(#"{"kind":"focus"}"#), BracketPlan(kind: .focus, count: 3, step: 0.5))
        // Unknown kinds and wrong types fall back field by field instead of failing the whole plan.
        XCTAssertEqual(try decode(#"{"kind":"iso","count":"many","step":"big"}"#), .off)
        XCTAssertEqual(try decode(#"{"kind":"whiteBalance","count":"x","step":30}"#),
                       BracketPlan(kind: .whiteBalance, count: 3, step: 30))
        XCTAssertThrowsError(try decode("[1, 2]"))
    }
}
