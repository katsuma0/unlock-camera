import XCTest
@testable import CameraCore

final class LensMathTests: XCTestCase {
    /// Horizontal FOV in degrees that a lens of `mm` (35 mm equivalent) gives on a sensor of `aspect`,
    /// worked backwards through the same diagonal geometry.
    private func horizontalFOV(forEquivalent mm: Double, aspect: Double) -> Double {
        let tanHalfDiagonal = 43.2666 / (2 * mm)
        let tanHalfHorizontal = tanHalfDiagonal / (1 + 1 / (aspect * aspect)).squareRoot()
        return 2 * atan(tanHalfHorizontal) * 180 / .pi
    }

    // MARK: - Equivalent focal length

    func testFullFrameFiftyMillimetre() {
        // A 36 x 24 mm frame behind a 50 mm lens sees 2 * atan(18 / 50) across its width.
        let fov = 2 * atan(18.0 / 50.0) * 180 / .pi
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: fov, aspect: 1.5), 50, accuracy: 1e-3)
    }

    func testDefaultAspectIsFourThree() {
        let fov = horizontalFOV(forEquivalent: 24, aspect: 4.0 / 3.0)
        XCTAssertEqual(fov, 71.59, accuracy: 0.01)
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: fov), 24, accuracy: 1e-9)
        XCTAssertEqual(
            LensMath.equivalentFocalLength(horizontalFOV: fov),
            LensMath.equivalentFocalLength(horizontalFOV: fov, aspect: 4.0 / 3.0)
        )
    }

    func testRoundTripAcrossFocalLengthsAndAspects() {
        for aspect in [1.0, 4.0 / 3.0, 1.5, 16.0 / 9.0, 2.39] {
            for mm in [13.0, 24, 26, 48, 77, 120, 200] {
                let fov = horizontalFOV(forEquivalent: mm, aspect: aspect)
                XCTAssertEqual(
                    LensMath.equivalentFocalLength(horizontalFOV: fov, aspect: aspect), mm,
                    accuracy: mm * 1e-9, "\(mm) mm at \(aspect)"
                )
            }
        }
    }

    func testSquareSensorUsesTheSquareRootOfTwoDiagonal() {
        // tan(45 degrees) is 1, so the diagonal factor is all that is left.
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: 90, aspect: 1), 43.2666 / (2 * 2.0.squareRoot()), accuracy: 1e-9)
    }

    func testWiderFieldMeansShorterFocalLength() {
        var previous = Double.infinity
        for fov in stride(from: 5.0, through: 175, by: 5) {
            let mm = LensMath.equivalentFocalLength(horizontalFOV: fov)
            XCTAssertGreaterThan(mm, 0)
            XCTAssertLessThan(mm, previous, "\(fov)")
            previous = mm
        }
    }

    func testWiderAspectAtTheSameHorizontalFOVMeansLongerFocalLength() {
        // A wider frame with the same width has a shorter diagonal, so it matches a longer lens.
        let fourThree = LensMath.equivalentFocalLength(horizontalFOV: 70, aspect: 4.0 / 3.0)
        let sixteenNine = LensMath.equivalentFocalLength(horizontalFOV: 70, aspect: 16.0 / 9.0)
        XCTAssertGreaterThan(sixteenNine, fourThree)
    }

    func testInvalidFieldOfViewReturnsZero() {
        for fov in [0, -0.0, -10, 180, 200, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: fov), 0, "\(fov)")
        }
    }

    func testExtremeButValidFieldOfViewStaysFinite() {
        // So narrow that tan underflows to 0: guarded instead of dividing by zero.
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: .leastNonzeroMagnitude), 0)
        // A little wider, tan is not 0 but 43.2666 / (2 * tan) overflows Double. That is unknown too, not infinity.
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: 1e-306), 0)
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: .leastNormalMagnitude), 0)
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: .leastNormalMagnitude / 1e6, aspect: 1), 0)
        let narrow = LensMath.equivalentFocalLength(horizontalFOV: 1e-300)
        XCTAssertTrue(narrow.isFinite)
        XCTAssertGreaterThan(narrow, 0)
        let wide = LensMath.equivalentFocalLength(horizontalFOV: 179.999999)
        XCTAssertTrue(wide.isFinite)
        XCTAssertGreaterThan(wide, 0)
    }

    func testEveryValidFieldOfViewGivesAFiniteFocalLength() {
        for aspect in [1.0, 4.0 / 3.0, 16.0 / 9.0, 0.75] {
            var fov = Double.leastNonzeroMagnitude
            while fov < 180 {
                let mm = LensMath.equivalentFocalLength(horizontalFOV: fov, aspect: aspect)
                XCTAssertTrue(mm.isFinite && mm >= 0, "\(fov) degrees at \(aspect): \(mm)")
                fov *= 3
            }
            let widest = LensMath.equivalentFocalLength(horizontalFOV: 180.0.nextDown, aspect: aspect)
            XCTAssertTrue(widest.isFinite && widest > 0, "\(aspect): \(widest)")
        }
    }

    func testAspectBelowOneIsFlippedAndInvalidAspectFallsBackToFourThree() {
        let reference = LensMath.equivalentFocalLength(horizontalFOV: 70, aspect: 4.0 / 3.0)
        XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: 70, aspect: 3.0 / 4.0), reference, accuracy: 1e-9)
        for bad in [0, -1, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(LensMath.equivalentFocalLength(horizontalFOV: 70, aspect: bad), reference, accuracy: 1e-9, "\(bad)")
        }
        XCTAssertTrue(LensMath.equivalentFocalLength(horizontalFOV: 70, aspect: .leastNonzeroMagnitude).isFinite)
    }

    // MARK: - Relative zoom

    func testRelativeZoom() {
        XCTAssertEqual(LensMath.relativeZoom(focalLength: 48, reference: 24), 2)
        XCTAssertEqual(LensMath.relativeZoom(focalLength: 24, reference: 24), 1)
        XCTAssertEqual(LensMath.relativeZoom(focalLength: 120, reference: 24), 5)
        XCTAssertEqual(LensMath.relativeZoom(focalLength: 13, reference: 24), 13.0 / 24.0)
    }

    func testRelativeZoomGuards() {
        for bad in [0, -24, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(LensMath.relativeZoom(focalLength: 24, reference: bad), 1, "reference \(bad)")
            XCTAssertEqual(LensMath.relativeZoom(focalLength: bad, reference: 24), 1, "focal length \(bad)")
        }
        // An invalid FOV gives 0 mm; that lens still reads as 1x rather than 0x.
        let unknown = LensMath.equivalentFocalLength(horizontalFOV: .nan)
        XCTAssertEqual(LensMath.relativeZoom(focalLength: unknown, reference: 24), 1)
        XCTAssertEqual(LensMath.relativeZoom(focalLength: 1e300, reference: 1e-300), 1)
    }

    // MARK: - Labels

    func testZoomLabelFollowsTheIOSCameraStyle() {
        XCTAssertEqual(LensMath.zoomLabel(0.5, selected: false), ".5")
        XCTAssertEqual(LensMath.zoomLabel(0.5, selected: true), ".5\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(1, selected: false), "1")
        XCTAssertEqual(LensMath.zoomLabel(1, selected: true), "1\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(2, selected: false), "2")
        XCTAssertEqual(LensMath.zoomLabel(5, selected: true), "5\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(1.2, selected: false), "1.2")
        XCTAssertEqual(LensMath.zoomLabel(2.5, selected: true), "2.5\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(10, selected: false), "10")
        XCTAssertEqual(LensMath.zoomLabel(12.5, selected: false), "12.5")
        XCTAssertEqual(LensMath.zoomLabel(0.7, selected: false), ".7")
    }

    func testZoomLabelRoundsToOneDecimalFirst() {
        XCTAssertEqual(LensMath.zoomLabel(0.49, selected: false), ".5")
        XCTAssertEqual(LensMath.zoomLabel(0.54, selected: false), ".5")
        XCTAssertEqual(LensMath.zoomLabel(0.96, selected: true), "1\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(1.04, selected: false), "1")
        XCTAssertEqual(LensMath.zoomLabel(1.96, selected: false), "2")
        XCTAssertEqual(LensMath.zoomLabel(3.21, selected: false), "3.2")
        XCTAssertEqual(LensMath.zoomLabel(0.05, selected: false), ".1")
    }

    func testZoomLabelOfRealLensRatios() {
        XCTAssertEqual(LensMath.zoomLabel(LensMath.relativeZoom(focalLength: 13, reference: 24), selected: true), ".5\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(LensMath.relativeZoom(focalLength: 77, reference: 24), selected: false), "3.2")
        XCTAssertEqual(LensMath.zoomLabel(LensMath.relativeZoom(focalLength: 120, reference: 24), selected: false), "5")
        XCTAssertEqual(LensMath.zoomLabel(LensMath.relativeZoom(focalLength: 48, reference: 24), selected: true), "2\u{00D7}")
    }

    func testZoomLabelSelectedUsesTheMultiplicationSign() {
        let label = LensMath.zoomLabel(2, selected: true)
        XCTAssertEqual(label.unicodeScalars.last?.value, 0x00D7)
        XCTAssertFalse(label.contains("x"))
    }

    func testZoomLabelInvalidInput() {
        XCTAssertEqual(LensMath.zoomLabel(0, selected: false), "0")
        XCTAssertEqual(LensMath.zoomLabel(0.04, selected: false), "0")
        XCTAssertEqual(LensMath.zoomLabel(-1, selected: true), "0\u{00D7}")
        XCTAssertEqual(LensMath.zoomLabel(.nan, selected: false), "0")
        XCTAssertEqual(LensMath.zoomLabel(.infinity, selected: false), "0")
        XCTAssertFalse(LensMath.zoomLabel(1e300, selected: false).isEmpty)
        XCTAssertFalse(LensMath.zoomLabel(.greatestFiniteMagnitude, selected: true).isEmpty)
    }

    func testFocalLengthLabel() {
        XCTAssertEqual(LensMath.focalLengthLabel(24), "24 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(23.6), "24 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(77.4), "77 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(13), "13 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(0), "0 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(-5), "0 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(.nan), "0 mm")
        XCTAssertEqual(LensMath.focalLengthLabel(.infinity), "0 mm")
        XCTAssertFalse(LensMath.focalLengthLabel(1e300).isEmpty)
    }

    func testFieldOfViewToLabelPipeline() {
        let fov = horizontalFOV(forEquivalent: 24, aspect: 4.0 / 3.0)
        XCTAssertEqual(LensMath.focalLengthLabel(LensMath.equivalentFocalLength(horizontalFOV: fov)), "24 mm")
        let tele = LensMath.equivalentFocalLength(horizontalFOV: horizontalFOV(forEquivalent: 120, aspect: 4.0 / 3.0))
        XCTAssertEqual(LensMath.zoomLabel(LensMath.relativeZoom(focalLength: tele, reference: 24), selected: true), "5\u{00D7}")
    }
}
