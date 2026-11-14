import XCTest
@testable import CameraCore

final class ZoomMathTests: XCTestCase {
    /// Values no zoom reading should ever be, and that every function must survive.
    private let unusable: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, -1, -.greatestFiniteMagnitude]

    /// A grid value is a whole number of tenths below 10 and a whole number from 10, and at least 0.1.
    private func isOnGrid(_ zoom: Double) -> Bool {
        guard zoom.isFinite, zoom >= 0.1 else { return false }
        if zoom < 10 {
            let tenths = zoom * 10
            return abs(tenths - tenths.rounded()) < 1e-9 && zoom == tenths.rounded() / 10
        }
        return zoom == zoom.rounded()
    }

    private func isUsableZoom(_ zoom: Double) -> Bool {
        zoom.isFinite && zoom > 0
    }

    /// A range with ends out of order or NaN. `init(uncheckedBounds:)` traps on those in a debug build but not in a
    /// release one, so the app could hand one over. ClosedRange is frozen as its two bounds in order, which is
    /// what lets two Doubles stand in for it here.
    private func unchecked(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
        unsafeBitCast((lower, upper), to: ClosedRange<Double>.self)
    }

    // MARK: - Constants

    func testConstantsMatchTheDesign() {
        XCTAssertEqual(ZoomMath.pointsPerStop, 100)
        XCTAssertEqual(ZoomMath.tenthsLimit, 10)
        XCTAssertEqual(ZoomMath.gridHysteresis, 0.1)
        XCTAssertEqual(ZoomMath.lensHysteresis, 0.05)
        XCTAssertEqual(ZoomMath.settleRate, 4)
    }

    // MARK: - Wheel travel

    func testFingerLeftZoomsInOneDoublingPerHundredPoints() {
        XCTAssertEqual(ZoomMath.zoom(from: 1, translation: -100), 2)
        XCTAssertEqual(ZoomMath.zoom(from: 1, translation: 100), 0.5)
        XCTAssertEqual(ZoomMath.zoom(from: 1.4, translation: -100), 2.8)
        XCTAssertEqual(ZoomMath.zoom(from: 3, translation: -200), 12)
        XCTAssertEqual(ZoomMath.zoom(from: 8, translation: 400), 0.5)
        XCTAssertEqual(ZoomMath.zoom(from: 1, translation: -50), 2.0.squareRoot(), accuracy: 1e-12)
    }

    func testNoTravelIsTheStartExactly() {
        for start in [0.5, 1, 1.4, 3.7, 12, 40] {
            XCTAssertEqual(ZoomMath.zoom(from: start, translation: 0), start)
            XCTAssertEqual(ZoomMath.zoom(from: start, translation: -0.0), start)
        }
    }

    func testPointsPerStopScalesTheTravel() {
        XCTAssertEqual(ZoomMath.zoom(from: 2, translation: -50, pointsPerStop: 50), 4)
        XCTAssertEqual(ZoomMath.zoom(from: 2, translation: 200, pointsPerStop: 200), 1)
        XCTAssertEqual(ZoomMath.offset(of: 4, from: 2, pointsPerStop: 50), 50)
        // An unusable scale is the default, not a division by zero.
        for scale in unusable {
            XCTAssertEqual(ZoomMath.zoom(from: 1, translation: -100, pointsPerStop: scale), 2, "\(scale)")
            XCTAssertEqual(ZoomMath.offset(of: 2, from: 1, pointsPerStop: scale), 100, "\(scale)")
        }
    }

    func testTravelBetweenNeighbouringValuesMatchesTheDesignTable() {
        // Points of finger travel for one step of the shown value (map-zoom 5.2).
        let table: [(from: Double, to: Double, points: Double)] = [
            (0.5, 0.6, 26.3), (0.9, 1.0, 15.2), (1.0, 1.1, 13.8), (1.4, 1.5, 10.0), (2.0, 2.1, 7.0), (3.0, 3.1, 4.7),
            (4.0, 4.1, 3.6), (5.0, 5.1, 2.9), (8.0, 8.1, 1.8), (9.9, 10, 1.4), (10, 11, 13.8), (20, 21, 7.0),
            (39, 40, 3.7),
        ]
        for row in table {
            XCTAssertEqual(ZoomMath.offset(of: row.to, from: row.from), row.points, accuracy: 0.06,
                           "\(row.from) to \(row.to)")
        }
        // Lens to lens is one stroke each; the long ends of the spans take a screen and a half.
        for (from, to) in [(0.5, 1.0), (1, 2), (2, 4), (4, 8)] as [(Double, Double)] {
            XCTAssertEqual(ZoomMath.offset(of: to, from: from), 100, accuracy: 1e-9)
        }
        XCTAssertEqual(ZoomMath.offset(of: 25, from: 0.5), 564.4, accuracy: 0.05)
        XCTAssertEqual(ZoomMath.offset(of: 40, from: 0.5), 632.2, accuracy: 0.05)
    }

    func testOffsetPutsLargerValuesToTheRight() {
        XCTAssertEqual(ZoomMath.offset(of: 2, from: 1), 100)
        XCTAssertEqual(ZoomMath.offset(of: 0.5, from: 1), -100)
        XCTAssertEqual(ZoomMath.offset(of: 1.4, from: 1.4), 0)
        XCTAssertGreaterThan(ZoomMath.offset(of: 1.5, from: 1.4), 0)
        XCTAssertLessThan(ZoomMath.offset(of: 1.3, from: 1.4), 0)
    }

    func testOffsetIsTheInverseOfTheDrag() {
        // Dragging the wheel by t brings the value that sat at offset -t to the centre line.
        for center in [0.5, 1, 1.4, 3.7, 12, 40] {
            for travel in [-250.0, -100, -13.8, -1, 0, 0.5, 7, 100, 300] {
                let value = ZoomMath.zoom(from: center, translation: travel)
                XCTAssertEqual(ZoomMath.offset(of: value, from: center), -travel, accuracy: 1e-9,
                               "\(center) by \(travel)")
            }
            for value in [0.5, 0.9, 1, 2.3, 8, 25] {
                let travel = -ZoomMath.offset(of: value, from: center)
                XCTAssertEqual(ZoomMath.zoom(from: center, translation: travel), value, accuracy: value * 1e-12,
                               "\(value) from \(center)")
            }
        }
    }

    func testWheelTravelStaysFiniteForAnyInput() {
        for start in unusable {
            // An unusable start counts as 1.
            XCTAssertEqual(ZoomMath.zoom(from: start, translation: -100), 2, "\(start)")
            XCTAssertEqual(ZoomMath.zoom(from: start, translation: 0), 1, "\(start)")
        }
        for travel in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(ZoomMath.zoom(from: 3, translation: travel), 3, "\(travel)")
        }
        // Past what a Double holds, the far end in the direction of travel, still finite and positive.
        let far = ZoomMath.zoom(from: 1e300, translation: -1e6)
        XCTAssertEqual(far, .greatestFiniteMagnitude)
        let near = ZoomMath.zoom(from: 1e-300, translation: 1e6)
        XCTAssertTrue(isUsableZoom(near))
        XCTAssertTrue(isUsableZoom(ZoomMath.zoom(from: .greatestFiniteMagnitude, translation: -1)))
        XCTAssertTrue(isUsableZoom(ZoomMath.zoom(from: 1, translation: 1e300, pointsPerStop: 1e-300)))
        XCTAssertTrue(isUsableZoom(ZoomMath.zoom(from: 1, translation: -1e300, pointsPerStop: 1e-300)))
    }

    func testOffsetStaysFiniteForAnyInput() {
        for bad in unusable {
            // An unusable value or centre counts as 1.
            XCTAssertEqual(ZoomMath.offset(of: bad, from: 2), -100, "\(bad)")
            XCTAssertEqual(ZoomMath.offset(of: 2, from: bad), 100, "\(bad)")
        }
        XCTAssertTrue(ZoomMath.offset(of: .greatestFiniteMagnitude, from: .leastNonzeroMagnitude).isFinite)
        XCTAssertEqual(ZoomMath.offset(of: .greatestFiniteMagnitude, from: 1, pointsPerStop: .greatestFiniteMagnitude),
                       .greatestFiniteMagnitude)
        XCTAssertEqual(ZoomMath.offset(of: .leastNormalMagnitude, from: 1, pointsPerStop: .greatestFiniteMagnitude),
                       -.greatestFiniteMagnitude)
    }

    // MARK: - Grid

    func testSnapsToTenthsBelowTenAndWholeNumbersFromTen() {
        XCTAssertEqual(ZoomMath.snapped(1.44), 1.4)
        XCTAssertEqual(ZoomMath.snapped(1.45), 1.5)
        XCTAssertEqual(ZoomMath.snapped(1.43), 1.4)
        XCTAssertEqual(ZoomMath.snapped(0.53), 0.5)
        XCTAssertEqual(ZoomMath.snapped(0.57), 0.6)
        XCTAssertEqual(ZoomMath.snapped(2.04), 2)
        XCTAssertEqual(ZoomMath.snapped(9.94), 9.9)
        XCTAssertEqual(ZoomMath.snapped(9.96), 10)
        XCTAssertEqual(ZoomMath.snapped(10.4), 10)
        XCTAssertEqual(ZoomMath.snapped(10.5), 11)
        XCTAssertEqual(ZoomMath.snapped(12.4), 12)
        XCTAssertEqual(ZoomMath.snapped(24.6), 25)
        XCTAssertEqual(ZoomMath.snapped(1234.4), 1234)
    }

    func testSnappedValuesAreTheDecimalsExactly() {
        // So a snapped value compares equal to a lens value or a label's decimal.
        for tenths in 1...99 {
            let decimal = Double(tenths) / 10
            XCTAssertEqual(ZoomMath.snapped(decimal + 0.01), decimal, "\(decimal)")
            XCTAssertEqual(ZoomMath.snapped(decimal - 0.01), decimal, "\(decimal)")
            XCTAssertEqual(ZoomMath.snapped(decimal), decimal, "\(decimal)")
        }
        XCTAssertEqual(ZoomMath.snapped(0.7000001), 0.7)
        XCTAssertEqual(ZoomMath.snapped(2.9999999), 3)
    }

    func testGridStartsAtOneTenth() {
        XCTAssertEqual(ZoomMath.snapped(0.04), 0.1)
        XCTAssertEqual(ZoomMath.snapped(0.001), 0.1)
        XCTAssertEqual(ZoomMath.snapped(.leastNonzeroMagnitude), 0.1)
    }

    func testSnappingNeverLeavesTheGridAndStaysFinite() {
        var zoom = 0.05
        while zoom < 60 {
            XCTAssertTrue(isOnGrid(ZoomMath.snapped(zoom)), "\(zoom)")
            XCTAssertLessThanOrEqual(abs(ZoomMath.snapped(zoom) - zoom), zoom < 10 ? 0.05 + 1e-9 : 0.5 + 1e-9, "\(zoom)")
            zoom *= 1.0037
        }
        for bad in unusable {
            XCTAssertEqual(ZoomMath.snapped(bad), 1, "\(bad)")
        }
        XCTAssertEqual(ZoomMath.snapped(1e300), 1e300)
        XCTAssertEqual(ZoomMath.snapped(.greatestFiniteMagnitude), .greatestFiniteMagnitude)
    }

    func testHysteresisKeepsTheShownValueUntilPastTheMidpointByATenthOfAStep() {
        // Up from 1.4: the midpoint is 1.45, the threshold 1.46.
        XCTAssertEqual(ZoomMath.snapped(1.455, keeping: 1.4), 1.4)
        XCTAssertEqual(ZoomMath.snapped(1.459, keeping: 1.4), 1.4)
        XCTAssertEqual(ZoomMath.snapped(1.46, keeping: 1.4), 1.5)
        // Down from 1.5: the threshold is 1.44.
        XCTAssertEqual(ZoomMath.snapped(1.445, keeping: 1.5), 1.5)
        XCTAssertEqual(ZoomMath.snapped(1.44, keeping: 1.5), 1.4)
        // Within a step either way nothing moves.
        for raw in stride(from: 1.341, through: 1.459, by: 0.002) {
            XCTAssertEqual(ZoomMath.snapped(raw, keeping: 1.4), 1.4, "\(raw)")
        }
    }

    func testHysteresisAcrossTheWholeNumberLimit() {
        // From 9.9 up: tenths, so the threshold is 9.96.
        XCTAssertEqual(ZoomMath.snapped(9.955, keeping: 9.9), 9.9)
        XCTAssertEqual(ZoomMath.snapped(9.96, keeping: 9.9), 10)
        // From 10 down to 9.9: still a tenth step on that side.
        XCTAssertEqual(ZoomMath.snapped(9.945, keeping: 10), 10)
        XCTAssertEqual(ZoomMath.snapped(9.94, keeping: 10), 9.9)
        // From 10 up: whole steps, so the threshold is 10.6.
        XCTAssertEqual(ZoomMath.snapped(10.55, keeping: 10), 10)
        XCTAssertEqual(ZoomMath.snapped(10.6, keeping: 10), 11)
        XCTAssertEqual(ZoomMath.snapped(11.4, keeping: 12), 11)
        XCTAssertEqual(ZoomMath.snapped(11.45, keeping: 12), 12)
    }

    func testAFastMoveLandsOnTheNearestValue() {
        XCTAssertEqual(ZoomMath.snapped(3.04, keeping: 1.4), 3)
        XCTAssertEqual(ZoomMath.snapped(0.62, keeping: 1.4), 0.6)
        XCTAssertEqual(ZoomMath.snapped(17.2, keeping: 2), 17)
    }

    func testHysteresisSnapsAnOffGridCurrentValueFirst() {
        XCTAssertEqual(ZoomMath.snapped(1.455, keeping: 1.43), 1.4)
        XCTAssertEqual(ZoomMath.snapped(1.38, keeping: 1.43), 1.4)
        XCTAssertEqual(ZoomMath.snapped(0.1, keeping: 0.02), 0.1)
    }

    func testHysteresisNeverLeavesTheGrid() {
        // A finger wandering back and forth across many steps.
        var raw = 0.6
        var shown = ZoomMath.snapped(raw)
        var direction = 1.0
        for step in 0..<4000 {
            raw *= pow(2, direction * 0.004)
            if raw > 30 || raw < 0.55 { direction = -direction }
            if step % 97 == 0 { direction = -direction }
            let next = ZoomMath.snapped(raw, keeping: shown)
            XCTAssertTrue(isOnGrid(next), "\(raw) -> \(next)")
            // Never more than half a step and the hysteresis away from the raw value.
            let stepSize = next < 10 ? 0.1 : 1
            XCTAssertLessThanOrEqual(abs(next - raw), stepSize * 0.6 + 1e-9, "\(raw) -> \(next)")
            shown = next
        }
    }

    func testHysteresisWithUnusableInput() {
        for bad in unusable {
            // A bad sample keeps what is shown; without anything shown it is a plain snap.
            XCTAssertEqual(ZoomMath.snapped(bad, keeping: 1.4), 1.4, "\(bad)")
            XCTAssertEqual(ZoomMath.snapped(1.46, keeping: bad), 1.5, "\(bad)")
            XCTAssertEqual(ZoomMath.snapped(bad, keeping: bad), 1, "\(bad)")
        }
    }

    // MARK: - Ramps

    func testStopsAreTheDistanceInDoublings() {
        XCTAssertEqual(ZoomMath.stops(from: 1, to: 2), 1)
        XCTAssertEqual(ZoomMath.stops(from: 4, to: 1), 2)
        XCTAssertEqual(ZoomMath.stops(from: 0.5, to: 8), 4)
        XCTAssertEqual(ZoomMath.stops(from: 1.4, to: 1.4), 0)
        XCTAssertEqual(ZoomMath.stops(from: .nan, to: 2), 1)
        XCTAssertEqual(ZoomMath.stops(from: 2, to: -3), 1)
        XCTAssertTrue(ZoomMath.stops(from: .leastNonzeroMagnitude, to: .greatestFiniteMagnitude).isFinite)
    }

    func testTransitionDurationMatchesTheDesignTable() {
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 0), 0.24, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 1), 0.28, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 2), 0.32, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 3), 0.36, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 4), 0.40, accuracy: 1e-12)
        // Long zooms are clamped.
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 5.25), 0.45, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 5.64), 0.45)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: 100), 0.45)
    }

    func testTransitionDurationIsMonotonicAndClamped() {
        var previous = 0.0
        for stops in stride(from: 0.0, through: 10, by: 0.05) {
            let duration = ZoomMath.transitionDuration(stops: stops)
            XCTAssertGreaterThanOrEqual(duration, previous, "\(stops)")
            XCTAssertTrue(ZoomMath.durationRange.contains(duration), "\(stops)")
            previous = duration
        }
        // Direction doesn't matter, and nothing unusable escapes the range.
        XCTAssertEqual(ZoomMath.transitionDuration(stops: -2), ZoomMath.transitionDuration(stops: 2))
        XCTAssertEqual(ZoomMath.transitionDuration(stops: .nan), 0.24, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: .infinity), 0.45)
        XCTAssertEqual(ZoomMath.transitionDuration(stops: -.infinity), 0.45)
    }

    func testRampRatesMatchTheDesignTable() {
        let table: [(from: Double, to: Double, rate: Double)] = [
            (1, 2, 3.57), (4, 8, 3.57), (1.4, 2, 1.97), (0.5, 1, 3.57), (1, 4, 6.25), (0.5, 2, 6.25), (4, 1, 6.25),
            (1, 8, 8.33), (0.5, 8, 10), (8, 0.5, 10), (25, 0.5, 12.54),
        ]
        for row in table {
            XCTAssertEqual(ZoomMath.rampRate(from: row.from, to: row.to), row.rate, accuracy: 0.01,
                           "\(row.from) to \(row.to)")
        }
        // A short step sits at the floor, and the longest zooms at the ceiling.
        XCTAssertEqual(ZoomMath.rampRate(from: 3.7, to: 4), 1.5)
        XCTAssertEqual(ZoomMath.rampRate(from: 1.4, to: 1.4), 1.5)
        XCTAssertEqual(ZoomMath.rampRate(from: 0.5, to: 40), 14)
    }

    func testRampRateIsMonotonicSymmetricAndCoversTheDistanceInTheDuration() {
        var previous = 0.0
        for stops in stride(from: 0.0, through: 9, by: 0.05) {
            let to = pow(2, stops)
            let rate = ZoomMath.rampRate(from: 1, to: to)
            XCTAssertGreaterThanOrEqual(rate, previous, "\(stops)")
            XCTAssertTrue(ZoomMath.rateRange.contains(rate), "\(stops)")
            XCTAssertEqual(rate, ZoomMath.rampRate(from: to, to: 1), accuracy: 1e-12, "\(stops)")
            // Inside the clamps the ramp takes exactly the transition's duration.
            if rate > ZoomMath.rateRange.lowerBound, rate < ZoomMath.rateRange.upperBound {
                XCTAssertEqual(rate * ZoomMath.transitionDuration(stops: stops), stops, accuracy: 1e-9, "\(stops)")
            }
            previous = rate
        }
    }

    func testRampDurationIsTheDistanceOverTheRate() {
        XCTAssertEqual(ZoomMath.rampDuration(from: 1, to: 2), 0.28, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.rampDuration(from: 1, to: 4), 0.32, accuracy: 1e-12)
        // At the floor the ramp is quicker than the transition: 3.7 to 4 takes 0.07 s, not 0.24.
        XCTAssertEqual(ZoomMath.rampDuration(from: 3.7, to: 4), log2(4 / 3.7) / 1.5, accuracy: 1e-12)
        XCTAssertLessThan(ZoomMath.rampDuration(from: 3.7, to: 4), 0.08)
        XCTAssertEqual(ZoomMath.rampDuration(from: 2, to: 2), 0)
        // At the ceiling it is a little longer.
        XCTAssertEqual(ZoomMath.rampDuration(from: 0.5, to: 40), log2(80) / 14, accuracy: 1e-12)
    }

    func testRampsStayFiniteForAnyInput() {
        for bad in unusable {
            // An unusable end counts as 1.
            XCTAssertEqual(ZoomMath.rampRate(from: bad, to: 2), ZoomMath.rampRate(from: 1, to: 2), "\(bad)")
            XCTAssertEqual(ZoomMath.rampRate(from: 4, to: bad), ZoomMath.rampRate(from: 4, to: 1), "\(bad)")
            XCTAssertEqual(ZoomMath.rampDuration(from: bad, to: bad), 0, "\(bad)")
        }
        let extreme = ZoomMath.rampRate(from: .leastNonzeroMagnitude, to: .greatestFiniteMagnitude)
        XCTAssertEqual(extreme, 14)
        XCTAssertTrue(ZoomMath.rampDuration(from: .leastNonzeroMagnitude, to: .greatestFiniteMagnitude).isFinite)
    }

    // MARK: - Span

    func testSpanAcrossLensesForEachPhone() {
        // 5x telephoto: 25x.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 5], buttonZooms: [0.5, 1, 2, 5], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...25)
        // 4x telephoto with its 8x button: 40x.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...40)
        // 3x telephoto: 15x.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 3], buttonZooms: [0.5, 1, 2, 3], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...15)
        // No telephoto, the wide's 2x button: 10x.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1], buttonZooms: [0.5, 1, 2], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...10)
        // One 12 MP lens: 5x.
        XCTAssertEqual(ZoomMath.span(lensZooms: [1], buttonZooms: [1], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 1...5)
    }

    func testSpanIsTheSameFromWhicheverLensIsActive() {
        for (active, range) in [(0.5, 1.0...15), (1, 1...15), (4, 1...15)] as [(Double, ClosedRange<Double>)] {
            XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: active,
                                         activeFactorRange: range, switchesLenses: true), 0.5...40, "\(active)")
        }
    }

    func testSpanOnOneLensStopsAtFiveTimesItsOwnLongestButton() {
        // The wide with 1...15: its own buttons are 1 and 2, so 10x, whether or not the phone has a telephoto.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: false), 1...10)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1], buttonZooms: [0.5, 1, 2], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: false), 1...10)
        // The ultra wide: only its own .5 button.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 0.5,
                                     activeFactorRange: 1...15, switchesLenses: false), 0.5...2.5)
        // The 4x telephoto with its 8x button.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 4,
                                     activeFactorRange: 1...15, switchesLenses: false), 4...40)
        // A 5x telephoto without a crop button.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 5], buttonZooms: [0.5, 1, 2, 5], activeZoom: 5,
                                     activeFactorRange: 1...15, switchesLenses: false), 5...25)
        // A lens with no buttons in the list (the selfie camera, given none): five times its own value.
        XCTAssertEqual(ZoomMath.span(lensZooms: [], buttonZooms: [], activeZoom: 1, activeFactorRange: 1...10,
                                     switchesLenses: false), 1...5)
    }

    func testSpanFollowsTheActiveLensFactorRange() {
        // A format that can't zoom: only the lenses' own values, whichever way.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...1, switchesLenses: true), 0.5...4)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...1, switchesLenses: false), 1...1)
        // A smaller largest factor than the buttons ask for.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...6, switchesLenses: true), 0.5...24)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...6, switchesLenses: false), 1...6)
        // A larger smallest factor moves the lower end on the active lens only.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1.2...15, switchesLenses: false), 1.2...10)
    }

    func testSpanEndsSitOnTheGrid() {
        // A 2.5x telephoto: five times its button is 12.5, so the controls stop at 12, as Apple's Camera does.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 2.5], buttonZooms: [0.5, 1, 2.5], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...12)
        // Fifteen times a 2.5x lens is 37.5.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 2.5], buttonZooms: [0.5, 1, 2.5], activeZoom: 2.5,
                                     activeFactorRange: 1...15, switchesLenses: false), 2.5...12)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 2.5], buttonZooms: [0.5, 1, 2.5], activeZoom: 1,
                                     activeFactorRange: 1...7.45, switchesLenses: true), 0.5...12)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.52, 1], buttonZooms: [0.52, 1], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.6...5)
        // A span too narrow for any grid value stays as the camera can do it.
        let narrow = ZoomMath.span(lensZooms: [], buttonZooms: [], activeZoom: 1.03, activeFactorRange: 1...1.04,
                                   switchesLenses: false)
        XCTAssertEqual(narrow.lowerBound, 1.03, accuracy: 1e-12)
        XCTAssertEqual(narrow.upperBound, 1.03 * 1.04, accuracy: 1e-12)
    }

    func testSpanIgnoresOrderAndUnusableEntries() {
        XCTAssertEqual(ZoomMath.span(lensZooms: [4, 0.5, 1], buttonZooms: [8, 1, 0.5, 4, 2], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...40)
        XCTAssertEqual(ZoomMath.span(lensZooms: [.nan, 0.5, -1, 1, 4, .infinity, 0],
                                     buttonZooms: [.nan, 0.5, 1, 2, 4, 8, 0, -.infinity], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...40)
        // Switching with no usable lens falls back to the active lens.
        XCTAssertEqual(ZoomMath.span(lensZooms: [.nan], buttonZooms: [], activeZoom: 1, activeFactorRange: 1...15,
                                     switchesLenses: true), 1...5)
        // Buttons that leave out the longest lens can't make it unreachable.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1], activeZoom: 1,
                                     activeFactorRange: 1...15, switchesLenses: true), 0.5...20)
    }

    func testSpanStaysFiniteAndOrderedForAnyInput() {
        let ranges: [ClosedRange<Double>] = [
            1...15, 1...1, -Double.infinity...Double.infinity, 0...0, -5...(-1), 1...Double.infinity,
            unchecked(.nan, .nan), unchecked(1, .nan), unchecked(.nan, 15), unchecked(15, 1),
        ]
        let actives: [Double] = [1, 0.5, 4, .nan, 0, -2, .infinity, 1e300, 1e-300]
        for range in ranges {
            for active in actives {
                for switches in [true, false] {
                    let span = ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8],
                                             activeZoom: active, activeFactorRange: range, switchesLenses: switches)
                    XCTAssertTrue(isUsableZoom(span.lowerBound), "\(range) \(active) \(switches) \(span)")
                    XCTAssertTrue(isUsableZoom(span.upperBound), "\(range) \(active) \(switches) \(span)")
                    XCTAssertLessThanOrEqual(span.lowerBound, span.upperBound)
                }
            }
        }
        // An unusable active zoom counts as the wide; an unusable factor range as no zoom at all.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: .nan,
                                     activeFactorRange: 1...15, switchesLenses: false), 1...10)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: unchecked(.nan, .nan), switchesLenses: false), 1...1)
        // A largest factor that isn't a number is no zoom too, so only the lenses' own values.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: unchecked(1, .nan), switchesLenses: true), 0.5...4)
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: unchecked(.nan, .nan), switchesLenses: true), 0.5...4)
        // An infinite largest factor leaves the button rule to set the end.
        XCTAssertEqual(ZoomMath.span(lensZooms: [0.5, 1, 4], buttonZooms: [0.5, 1, 2, 4, 8], activeZoom: 1,
                                     activeFactorRange: 1...Double.infinity, switchesLenses: false), 1...10)
        XCTAssertEqual(ZoomMath.span(lensZooms: [], buttonZooms: [], activeZoom: 1e300, activeFactorRange: 1...15,
                                     switchesLenses: false), 1000...1000)
    }

    // MARK: - Lens choice

    private let lenses = [0.5, 1, 4]

    private func lens(_ zoom: Double, current: Int? = nil, maxFactor: Double = 15, continuing: Bool = false,
                      in lensZooms: [Double]? = nil) -> Int? {
        ZoomMath.lensIndex(for: zoom, lensZooms: lensZooms ?? lenses, current: current, currentMaxFactor: maxFactor,
                           continuing: continuing)
    }

    func testStrictPicksTheLongestLensAtOrBelowTheZoom() {
        XCTAssertEqual(lens(0.5), 0)
        XCTAssertEqual(lens(0.99), 0)
        XCTAssertEqual(lens(1), 1)
        XCTAssertEqual(lens(3.99), 1)
        XCTAssertEqual(lens(4), 2)
        XCTAssertEqual(lens(4.1), 2)
        XCTAssertEqual(lens(40), 2)
        // Below every lens, the widest.
        XCTAssertEqual(lens(0.3), 0)
        // A reading a hair under a lens's value stays on that lens, as the model's rule allows.
        XCTAssertEqual(lens(0.9995), 1)
        XCTAssertEqual(lens(0.998), 0)
        // Strict ignores the current lens.
        XCTAssertEqual(lens(4.1, current: 1), 2)
    }

    func testContinuingKeepsTheWiderLensUpToFivePercentPastTheNext() {
        XCTAssertEqual(lens(4, current: 1, continuing: true), 1)
        XCTAssertEqual(lens(4.1, current: 1, continuing: true), 1)
        XCTAssertEqual(lens(4.19, current: 1, continuing: true), 1)
        XCTAssertEqual(lens(4.2, current: 1, continuing: true), 2)
        XCTAssertEqual(lens(5, current: 1, continuing: true), 2)
        // The ultra wide hands the 1x over at 1.05.
        XCTAssertEqual(lens(1.04, current: 0, continuing: true), 0)
        XCTAssertEqual(lens(1.05, current: 0, continuing: true), 1)
        // The lift chooses strictly, so 4.1 ends on the telephoto.
        XCTAssertEqual(lens(4.1, current: 1, continuing: false), 2)
    }

    func testGoingDownALensHandsOverBelowItsOwnValue() {
        XCTAssertEqual(lens(3.99, current: 2, continuing: true), 1)
        XCTAssertEqual(lens(4, current: 2, continuing: true), 2)
        XCTAssertEqual(lens(0.99, current: 1, continuing: true), 0)
        XCTAssertEqual(lens(0.6, current: 2, continuing: true), 0)
    }

    func testAJumpPastTheNextLensSwapsOnce() {
        // From the ultra wide straight to 4.1: past the 1x by far, so the telephoto, not two swaps.
        XCTAssertEqual(lens(4.1, current: 0, continuing: true), 2)
    }

    func testALensThatCantReachTheZoomNeverKeepsIt() {
        XCTAssertEqual(lens(4.1, current: 1, maxFactor: 4, continuing: true), 2)
        XCTAssertEqual(lens(4.1, current: 1, maxFactor: 4.15, continuing: true), 1)
        XCTAssertEqual(lens(1.04, current: 0, maxFactor: 2, continuing: true), 1)
        // An unusable largest factor counts as none, so nothing is kept.
        for bad in [Double.nan, 0, -3, -Double.infinity] {
            XCTAssertEqual(lens(4.1, current: 1, maxFactor: bad, continuing: true), 2, "\(bad)")
        }
        XCTAssertEqual(lens(4.1, current: 1, maxFactor: .infinity, continuing: true), 1)
    }

    func testLensChoiceWithoutAUsableCurrentLensIsStrict() {
        for current in [nil, 3, -1, 99] as [Int?] {
            XCTAssertEqual(lens(4.1, current: current, continuing: true), 2, "\(String(describing: current))")
        }
        // A current index pointing at an unusable entry.
        XCTAssertEqual(lens(4.1, current: 0, continuing: true, in: [.nan, 0.5, 1, 4]), 3)
    }

    func testLensChoiceSkipsUnusableEntriesAndAnyOrder() {
        XCTAssertNil(lens(2, in: []))
        XCTAssertNil(lens(2, in: [.nan, 0, -1, .infinity]))
        XCTAssertEqual(lens(4.1, in: [.nan, 0.5, 1, 4]), 3)
        XCTAssertEqual(lens(0.3, in: [.nan, 0.5, 1, 4]), 1)
        let unsorted = [4.0, 0.5, 1]
        XCTAssertEqual(lens(4.1, in: unsorted), 0)
        XCTAssertEqual(lens(2, in: unsorted), 2)
        XCTAssertEqual(lens(0.3, in: unsorted), 1)
        XCTAssertEqual(lens(4.1, current: 2, continuing: true, in: unsorted), 2)
        XCTAssertEqual(lens(4.2, current: 2, continuing: true, in: unsorted), 0)
    }

    func testLensChoiceForAnUnusableZoomIsTheOneForOne() {
        for bad in unusable {
            XCTAssertEqual(lens(bad), 1, "\(bad)")
        }
    }

    // MARK: - Ticks

    private func assertTickRules(_ ticks: [Double], in span: ClosedRange<Double>, file: StaticString = #filePath,
                                 line: UInt = #line) {
        for (a, b) in zip(ticks, ticks.dropFirst()) {
            XCTAssertLessThan(a, b, "ascending and unique", file: file, line: line)
            XCTAssertGreaterThanOrEqual(ZoomMath.offset(of: b, from: a), 5.6, "\(a) to \(b)", file: file, line: line)
        }
        for tick in ticks {
            XCTAssertTrue(span.contains(tick), "\(tick) in \(span)", file: file, line: line)
            XCTAssertTrue(isOnGrid(tick), "\(tick)", file: file, line: line)
        }
    }

    func testTicksFollowTheStepsOfEachBand() {
        XCTAssertEqual(ZoomMath.ticks(in: 0.5...2), (5...20).map { Double($0) / 10 })
        XCTAssertEqual(ZoomMath.ticks(in: 2...5), stride(from: 20, through: 50, by: 2).map { Double($0) / 10 })
        XCTAssertEqual(ZoomMath.ticks(in: 5...10), stride(from: 50, through: 100, by: 5).map { Double($0) / 10 })
        XCTAssertEqual(ZoomMath.ticks(in: 10...25), (10...25).map(Double.init))
        XCTAssertEqual(ZoomMath.ticks(in: 25...100), stride(from: 25, through: 100, by: 5).map(Double.init))
        XCTAssertEqual(ZoomMath.ticks(in: 100...200), stride(from: 100, through: 200, by: 10).map(Double.init))
        XCTAssertEqual(Array(ZoomMath.ticks(in: 0.5...40).suffix(4)), [25, 30, 35, 40])
        // The decimals exactly, so a tick compares equal to a lens value.
        XCTAssertTrue(ZoomMath.ticks(in: 0.5...40).contains(0.7))
        XCTAssertTrue(ZoomMath.ticks(in: 0.5...40).contains(2.6))
    }

    func testTicksKeepTheirRulesOnEverySpan() {
        let spans: [ClosedRange<Double>] = [0.5...25, 0.5...40, 0.5...10, 1...5, 0.5...15, 4...60, 0.5...2.5,
                                            0.1...1000, 0.52...37.5, 1.95...5.05]
        for span in spans {
            let ticks = ZoomMath.ticks(in: span)
            XCTAssertFalse(ticks.isEmpty, "\(span)")
            assertTickRules(ticks, in: span)
        }
        let all = ZoomMath.ticks(in: 0.1...1000)
        XCTAssertEqual(all.first, 0.1)
        XCTAssertEqual(all.last, 1000)
        XCTAssertEqual(all.count, 110)
    }

    func testTicksBetweenOffGridEnds() {
        let ticks = ZoomMath.ticks(in: 0.52...37.5)
        XCTAssertEqual(ticks.first, 0.6)
        XCTAssertEqual(ticks.last, 35)
        // The first tick of a band whose lower end falls between its steps.
        XCTAssertEqual(ZoomMath.ticks(in: 2.1...3).first, 2.2)
        XCTAssertEqual(ZoomMath.ticks(in: 4.85...6).first, 5)
        XCTAssertEqual(ZoomMath.ticks(in: 26...50).first, 30)
    }

    func testTicksOfTinyAndUnusableSpans() {
        XCTAssertEqual(ZoomMath.ticks(in: 1...1), [1])
        XCTAssertEqual(ZoomMath.ticks(in: 1.03...1.07), [])
        XCTAssertEqual(ZoomMath.ticks(in: unchecked(.nan, .nan)), [1])
        XCTAssertEqual(ZoomMath.ticks(in: unchecked(.nan, 1.2)), [1, 1.1, 1.2])
        XCTAssertEqual(ZoomMath.ticks(in: unchecked(2, .nan)), [2])
        // Ends out of order read as the lower one.
        XCTAssertEqual(ZoomMath.ticks(in: unchecked(3, 1)), [3])
        XCTAssertEqual(ZoomMath.ticks(in: 0...0), [0.1])
        XCTAssertEqual(ZoomMath.ticks(in: 5...5.04), [5])
        let wide = ZoomMath.ticks(in: -Double.infinity...Double.infinity)
        XCTAssertEqual(wide, ZoomMath.ticks(in: 0.1...1000))
        XCTAssertEqual(ZoomMath.ticks(in: 500...1e300).last, 1000)
        XCTAssertEqual(ZoomMath.ticks(in: 2000...3000), [1000])
    }

    // MARK: - Steps

    private let phoneSpan: ClosedRange<Double> = 0.5...40

    func testANudgeMovesOneTick() {
        let cases: [(from: Double, up: Double, down: Double)] = [
            (1, 1.1, 0.9), (1.9, 2, 1.8), (2, 2.2, 1.9), (2.2, 2.4, 2), (4.8, 5, 4.6), (5, 5.5, 4.8), (9.5, 10, 9),
            (10, 11, 9.5), (24, 25, 23), (25, 30, 24), (35, 40, 30),
        ]
        for row in cases {
            XCTAssertEqual(ZoomMath.nudged(row.from, by: 1, in: phoneSpan), row.up, "\(row.from) up")
            XCTAssertEqual(ZoomMath.nudged(row.from, by: -1, in: phoneSpan), row.down, "\(row.from) down")
        }
    }

    func testNudgesStopAtTheEnds() {
        XCTAssertEqual(ZoomMath.nudged(40, by: 1, in: phoneSpan), 40)
        XCTAssertEqual(ZoomMath.nudged(0.5, by: -1, in: phoneSpan), 0.5)
        XCTAssertEqual(ZoomMath.nudged(1, by: 1000, in: phoneSpan), 40)
        XCTAssertEqual(ZoomMath.nudged(1, by: -1000, in: phoneSpan), 0.5)
        XCTAssertEqual(ZoomMath.nudged(1, by: .max, in: phoneSpan), 40)
        XCTAssertEqual(ZoomMath.nudged(1, by: .min, in: phoneSpan), 0.5)
        // From outside the span the first step is its end.
        XCTAssertEqual(ZoomMath.nudged(50, by: -1, in: phoneSpan), 40)
        XCTAssertEqual(ZoomMath.nudged(50, by: 1, in: phoneSpan), 40)
        XCTAssertEqual(ZoomMath.nudged(0.3, by: 1, in: phoneSpan), 0.5)
        XCTAssertEqual(ZoomMath.nudged(0.3, by: -1, in: phoneSpan), 0.5)
    }

    func testSeveralStepsAtOnce() {
        XCTAssertEqual(ZoomMath.nudged(1, by: 3, in: phoneSpan), 1.3)
        XCTAssertEqual(ZoomMath.nudged(1, by: -3, in: phoneSpan), 0.7)
        XCTAssertEqual(ZoomMath.nudged(1.9, by: 2, in: phoneSpan), 2.2)
    }

    func testSpanEndsOffTheTickGridAreStepsToo() {
        // A 2.5x telephoto's span ends at 12 in the tick band of whole numbers, and a lens of 37 would end between
        // the fives.
        XCTAssertEqual(ZoomMath.nudged(35, by: 1, in: 0.5...37), 37)
        XCTAssertEqual(ZoomMath.nudged(37, by: -1, in: 0.5...37), 35)
        XCTAssertEqual(ZoomMath.nudged(0.6, by: -1, in: 0.55...5), 0.55)
    }

    func testStepsCountFromTheValueAsReadOut() {
        // 1.46 is read out as 1.5x: one step either way is a value that reads differently.
        XCTAssertEqual(ZoomMath.nudged(1.46, by: 1, in: phoneSpan), 1.6)
        XCTAssertEqual(ZoomMath.nudged(1.46, by: -1, in: phoneSpan), 1.4)
        XCTAssertEqual(ZoomMath.nudged(1.43, by: 1, in: phoneSpan), 1.5)
        XCTAssertEqual(ZoomMath.nudged(1.43, by: -1, in: phoneSpan), 1.3)
        // Between the ticks of a coarser band.
        XCTAssertEqual(ZoomMath.nudged(2.3, by: 1, in: phoneSpan), 2.4)
        XCTAssertEqual(ZoomMath.nudged(2.3, by: -1, in: phoneSpan), 2.2)
        XCTAssertEqual(ZoomMath.nudged(12.4, by: -1, in: phoneSpan), 12)
    }

    func testNoStepsKeepsTheZoomInsideTheSpan() {
        XCTAssertEqual(ZoomMath.nudged(1.43, by: 0, in: phoneSpan), 1.43)
        XCTAssertEqual(ZoomMath.nudged(50, by: 0, in: phoneSpan), 40)
        XCTAssertEqual(ZoomMath.nudged(0.2, by: 0, in: phoneSpan), 0.5)
        XCTAssertEqual(ZoomMath.nudged(.nan, by: 0, in: phoneSpan), 1)
    }

    func testOneToEightIsThirtyOneSwipes() {
        var zoom = 1.0
        var swipes = 0
        while zoom < 8, swipes < 100 {
            zoom = ZoomMath.nudged(zoom, by: 1, in: phoneSpan)
            swipes += 1
        }
        XCTAssertEqual(zoom, 8)
        XCTAssertEqual(swipes, 31)
    }

    func testEveryNudgeLandsOnATickOrAnEnd() {
        let span: ClosedRange<Double> = 0.5...37
        let stops = Set(ZoomMath.ticks(in: span) + [span.lowerBound, span.upperBound])
        var zoom = 0.5
        for _ in 0..<80 {
            zoom = ZoomMath.nudged(zoom, by: 1, in: span)
            XCTAssertTrue(stops.contains(zoom), "\(zoom)")
        }
        XCTAssertEqual(zoom, 37)
        for _ in 0..<80 {
            zoom = ZoomMath.nudged(zoom, by: -1, in: span)
            XCTAssertTrue(stops.contains(zoom), "\(zoom)")
        }
        XCTAssertEqual(zoom, 0.5)
    }

    func testEveryNudgeChangesWhatVoiceOverReadsUntilAnEnd() {
        // Off-grid spans and starting points included: a swipe that reads the same value back would seem broken.
        for span in [phoneSpan, 0.55...37, 1.03...1.07, 0.52...4.97] {
            for start in [span.lowerBound, 1.05, 1.46, span.upperBound] {
                for direction in [1, -1] {
                    var zoom = start
                    for _ in 0..<120 {
                        let next = ZoomMath.nudged(zoom, by: direction, in: span)
                        let atEnd = next == (direction > 0 ? span.upperBound : span.lowerBound)
                        if !atEnd {
                            XCTAssertNotEqual(LensMath.zoomLabel(next, selected: true),
                                              LensMath.zoomLabel(zoom, selected: true),
                                              "\(span) \(zoom) by \(direction)")
                        }
                        if next == zoom { break }
                        zoom = next
                    }
                    XCTAssertEqual(zoom, direction > 0 ? span.upperBound : span.lowerBound, "\(span) from \(start)")
                }
            }
        }
    }

    func testNudgesStayFiniteForAnyInput() {
        for bad in unusable {
            // An unusable zoom steps from 1.
            XCTAssertEqual(ZoomMath.nudged(bad, by: 1, in: phoneSpan), 1.1, "\(bad)")
            XCTAssertEqual(ZoomMath.nudged(bad, by: -1, in: phoneSpan), 0.9, "\(bad)")
        }
        let odd: [ClosedRange<Double>] = [
            unchecked(.nan, .nan), unchecked(.nan, 2), unchecked(4, 1), 0...0,
            -Double.infinity...Double.infinity, 3...3, 1.03...1.07,
        ]
        for span in odd {
            for steps in [-5, -1, 0, 1, 5] {
                XCTAssertTrue(isUsableZoom(ZoomMath.nudged(1.5, by: steps, in: span)), "\(span) \(steps)")
            }
        }
        XCTAssertEqual(ZoomMath.nudged(1.5, by: 1, in: 3...3), 3)
        XCTAssertEqual(ZoomMath.nudged(1.05, by: 1, in: 1.03...1.07), 1.07)
        XCTAssertEqual(ZoomMath.nudged(1.05, by: -1, in: 1.03...1.07), 1.03)
        XCTAssertEqual(ZoomMath.nudged(.greatestFiniteMagnitude, by: -1, in: phoneSpan), 40)
    }
}
