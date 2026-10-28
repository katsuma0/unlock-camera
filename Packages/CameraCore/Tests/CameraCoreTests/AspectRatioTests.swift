import Foundation
import XCTest
@testable import CameraCore

final class AspectRatioTests: XCTestCase {
    private func assertRect(_ rect: CropRect, x: Double, y: Double, width: Double, height: Double,
                            accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.x, x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(rect.y, y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(rect.width, width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(rect.height, height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - CropRect

    func testCropRectEdges() {
        let rect = CropRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(rect.x, 10)
        XCTAssertEqual(rect.y, 20)
        XCTAssertEqual(rect.width, 100)
        XCTAssertEqual(rect.height, 50)
        XCTAssertEqual(rect.maxX, 110)
        XCTAssertEqual(rect.maxY, 70)
    }

    func testCropRectUnit() {
        XCTAssertEqual(CropRect.unit, CropRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(CropRect.unit.maxX, 1)
        XCTAssertEqual(CropRect.unit.maxY, 1)
    }

    func testCropRectCodableRoundTrip() throws {
        let rect = CropRect(x: 0.125, y: 0, width: 0.75, height: 1)
        let data = try JSONEncoder().encode(rect)
        XCTAssertEqual(try JSONDecoder().decode(CropRect.self, from: data), rect)
    }

    // MARK: - Init

    func testInitIsOrderAgnostic() {
        let portrait = AspectRatio(3, 4)
        XCTAssertEqual(portrait.long, 4)
        XCTAssertEqual(portrait.short, 3)
        XCTAssertEqual(portrait, AspectRatio(4, 3))
        XCTAssertEqual(AspectRatio(9, 16), .sixteenNine)
        XCTAssertEqual(AspectRatio(1, 2.39), .cinemaScope)
    }

    func testInvalidInputFallsBackToFourThree() {
        let cases: [(Double, Double)] = [
            (0, 3), (4, 0), (-16, 9), (16, -9), (-1, -2), (0, 0),
            (.nan, 2), (2, .nan), (.infinity, 1), (1, -.infinity),
            (1e300, 1e-300),
        ]
        for (a, b) in cases {
            let shape = AspectRatio(a, b)
            XCTAssertEqual(shape, .fourThree, "\(a) : \(b)")
            XCTAssertEqual(shape.long, 4)
            XCTAssertEqual(shape.short, 3)
        }
    }

    // MARK: - Ratio and label

    func testRatio() {
        XCTAssertEqual(AspectRatio.fourThree.ratio, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(AspectRatio.sixteenNine.ratio, 16.0 / 9.0, accuracy: 1e-12)
        XCTAssertEqual(AspectRatio.threeTwo.ratio, 1.5)
        XCTAssertEqual(AspectRatio.square.ratio, 1)
        XCTAssertEqual(AspectRatio.cinemaScope.ratio, 2.39, accuracy: 1e-12)
        XCTAssertEqual(AspectRatio.xpan.ratio, 65.0 / 24.0, accuracy: 1e-12)
        XCTAssertEqual(AspectRatio(3, 4).ratio, 4.0 / 3.0, accuracy: 1e-12)
        for preset in AspectRatio.presets {
            XCTAssertGreaterThanOrEqual(preset.ratio, 1)
        }
    }

    func testPresetLabels() {
        XCTAssertEqual(AspectRatio.fourThree.label, "4:3")
        XCTAssertEqual(AspectRatio.threeTwo.label, "3:2")
        XCTAssertEqual(AspectRatio.sixteenNine.label, "16:9")
        XCTAssertEqual(AspectRatio.square.label, "1:1")
        XCTAssertEqual(AspectRatio.fiveFour.label, "5:4")
        XCTAssertEqual(AspectRatio.twoOne.label, "2:1")
        XCTAssertEqual(AspectRatio.cinemaScope.label, "2.39:1")
        XCTAssertEqual(AspectRatio.xpan.label, "65:24")
    }

    func testLabelPrintsWholeNumberSidesAsGiven() {
        XCTAssertEqual(AspectRatio(1920, 1080).label, "1920:1080")
        XCTAssertEqual(AspectRatio(8, 6).label, "8:6")
        XCTAssertEqual(AspectRatio(3, 4).label, "4:3")
        XCTAssertEqual(AspectRatio(16.0, 9.0).label, "16:9")
    }

    func testLabelReducesOtherSidesToXToOne() {
        XCTAssertEqual(AspectRatio(1.85, 1).label, "1.85:1")
        XCTAssertEqual(AspectRatio(1, 1.85).label, "1.85:1")
        XCTAssertEqual(AspectRatio(2.4, 1).label, "2.4:1")
        XCTAssertEqual(AspectRatio(4.5, 3).label, "1.5:1")
        XCTAssertEqual(AspectRatio(16, 9.5).label, "1.68:1")
        XCTAssertEqual(AspectRatio(10.5, 1).label, "10.5:1")
        XCTAssertEqual(AspectRatio(1.3333, 1).label, "1.33:1")
    }

    func testLabelDropsTrailingZerosButKeepsWholeDigits() {
        XCTAssertEqual(AspectRatio(1.5, 1.5).label, "1:1")
        XCTAssertEqual(AspectRatio(2.0001, 1).label, "2:1")
        XCTAssertEqual(AspectRatio(20.5, 2.05).label, "10:1")
        XCTAssertEqual(AspectRatio(100.5, 1.005).label, "100:1")
    }

    func testIdIsLabel() {
        for preset in AspectRatio.presets {
            XCTAssertEqual(preset.id, preset.label)
        }
        XCTAssertEqual(AspectRatio(1.85, 1).id, "1.85:1")
    }

    // MARK: - Presets

    func testPresetValues() {
        XCTAssertEqual(AspectRatio.fourThree.long, 4)
        XCTAssertEqual(AspectRatio.fourThree.short, 3)
        XCTAssertEqual(AspectRatio.sixteenNine.long, 16)
        XCTAssertEqual(AspectRatio.sixteenNine.short, 9)
        XCTAssertEqual(AspectRatio.square.long, 1)
        XCTAssertEqual(AspectRatio.square.short, 1)
        XCTAssertEqual(AspectRatio.cinemaScope.long, 2.39)
        XCTAssertEqual(AspectRatio.cinemaScope.short, 1)
        XCTAssertEqual(AspectRatio.xpan.long, 65)
        XCTAssertEqual(AspectRatio.xpan.short, 24)
    }

    func testPresetOrder() {
        XCTAssertEqual(AspectRatio.presets,
                       [.fourThree, .square, .sixteenNine, .threeTwo, .fiveFour, .twoOne, .cinemaScope, .xpan])
        XCTAssertEqual(AspectRatio.presets.map(\.label), ["4:3", "1:1", "16:9", "3:2", "5:4", "2:1", "2.39:1", "65:24"])
        XCTAssertEqual(Set(AspectRatio.presets.map(\.id)).count, AspectRatio.presets.count)
    }

    // MARK: - Pixel crop

    func testCenteredCropIsTheFullFrameWhenShapesMatch() {
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 4032, height: 3024),
                       CropRect(x: 0, y: 0, width: 4032, height: 3024))
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 3024, height: 4032),
                       CropRect(x: 0, y: 0, width: 3024, height: 4032))
        XCTAssertEqual(AspectRatio.sixteenNine.centeredCrop(width: 1920, height: 1080),
                       CropRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(AspectRatio.square.centeredCrop(width: 3000, height: 3000),
                       CropRect(x: 0, y: 0, width: 3000, height: 3000))
    }

    func testCenteredCropLandscape() {
        XCTAssertEqual(AspectRatio.sixteenNine.centeredCrop(width: 4032, height: 3024),
                       CropRect(x: 0, y: 378, width: 4032, height: 2268))
        XCTAssertEqual(AspectRatio.square.centeredCrop(width: 4032, height: 3024),
                       CropRect(x: 504, y: 0, width: 3024, height: 3024))
        XCTAssertEqual(AspectRatio.threeTwo.centeredCrop(width: 4032, height: 3024),
                       CropRect(x: 0, y: 168, width: 4032, height: 2688))
        XCTAssertEqual(AspectRatio.fiveFour.centeredCrop(width: 4032, height: 3024),
                       CropRect(x: 126, y: 0, width: 3780, height: 3024))
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 1920, height: 1080),
                       CropRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    func testCenteredCropPortraitRunsTheLongSideVertically() {
        XCTAssertEqual(AspectRatio.sixteenNine.centeredCrop(width: 3024, height: 4032),
                       CropRect(x: 378, y: 0, width: 2268, height: 4032))
        XCTAssertEqual(AspectRatio.threeTwo.centeredCrop(width: 3024, height: 4032),
                       CropRect(x: 168, y: 0, width: 2688, height: 4032))
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 1080, height: 1920),
                       CropRect(x: 0, y: 240, width: 1080, height: 1440))
        XCTAssertEqual(AspectRatio.square.centeredCrop(width: 3024, height: 4032),
                       CropRect(x: 0, y: 504, width: 3024, height: 3024))
    }

    func testCenteredCropTreatsASquareImageAsLandscape() {
        assertRect(AspectRatio.sixteenNine.centeredCrop(width: 3000, height: 3000),
                   x: 0, y: 656.25, width: 3000, height: 1687.5)
        assertRect(AspectRatio.threeTwo.centeredCrop(width: 1000, height: 1000),
                   x: 0, y: 500.0 / 3.0, width: 1000, height: 2000.0 / 3.0)
    }

    func testCenteredCropWideFormats() {
        assertRect(AspectRatio.cinemaScope.centeredCrop(width: 4032, height: 3024),
                   x: 0, y: (3024 - 4032 / 2.39) / 2, width: 4032, height: 4032 / 2.39)
        assertRect(AspectRatio.xpan.centeredCrop(width: 4032, height: 3024),
                   x: 0, y: 767.6307692307692, width: 4032, height: 1488.7384615384615)
        assertRect(AspectRatio.xpan.centeredCrop(width: 3024, height: 4032),
                   x: 767.6307692307692, y: 0, width: 1488.7384615384615, height: 4032)
    }

    func testCenteredCropInvariants() {
        let sizes: [(Double, Double)] = [
            (4032, 3024), (3024, 4032), (1920, 1080), (1080, 1920), (3000, 3000), (640, 480), (7, 5), (1, 1000),
        ]
        for (w, h) in sizes {
            for preset in AspectRatio.presets {
                let crop = preset.centeredCrop(width: w, height: h)
                let message = "\(preset.label) in \(w)x\(h)"
                // Inside the image and centred.
                XCTAssertGreaterThanOrEqual(crop.x, -1e-9, message)
                XCTAssertGreaterThanOrEqual(crop.y, -1e-9, message)
                XCTAssertLessThanOrEqual(crop.maxX, w + 1e-9, message)
                XCTAssertLessThanOrEqual(crop.maxY, h + 1e-9, message)
                XCTAssertEqual(crop.x, w - crop.maxX, accuracy: 1e-9, message)
                XCTAssertEqual(crop.y, h - crop.maxY, accuracy: 1e-9, message)
                // The requested shape, long side along the image's long axis.
                let long = max(crop.width, crop.height)
                let short = min(crop.width, crop.height)
                XCTAssertEqual(long / short, preset.ratio, accuracy: 1e-9, message)
                if w >= h {
                    XCTAssertGreaterThanOrEqual(crop.width, crop.height, message)
                } else {
                    XCTAssertGreaterThanOrEqual(crop.height, crop.width, message)
                }
                // Largest possible: it spans the image in at least one direction.
                XCTAssertTrue(abs(crop.width - w) < 1e-9 || abs(crop.height - h) < 1e-9, message)
            }
        }
    }

    func testCenteredCropStaysInsideTheImageAtTheRoundingEdge() {
        // One ulp under 130 x 4 / 3: the products round so the full-height crop came out an ulp wider than the image.
        let width = (130.0 * 4 / 3).nextDown
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: width, height: 130),
                       CropRect(x: 0, y: 0, width: width, height: 130))
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 130, height: width),
                       CropRect(x: 0, y: 0, width: 130, height: width))
        // Images a couple of ulps either side of each preset's own shape, where rounding picks the branch.
        var outside: [String] = []
        for preset in AspectRatio.presets {
            for side in stride(from: 100.0, through: 300.0, by: 1.0) {
                let exact = side * preset.long / preset.short
                for near in [exact.nextDown.nextDown, exact.nextDown, exact.nextUp, exact.nextUp.nextUp] {
                    for (w, h) in [(near, side), (side, near)] {
                        let crop = preset.centeredCrop(width: w, height: h)
                        if crop.x < 0 || crop.y < 0 || crop.maxX > w || crop.maxY > h {
                            outside.append("\(preset.label) in \(w)x\(h): \(crop)")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(outside.isEmpty, "\(outside.count) crops leave the image, e.g. \(outside.prefix(3))")
    }

    func testCenteredCropOfAnEmptyOrInvalidImageIsZero() {
        let zero = CropRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 0, height: 3024), zero)
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 4032, height: 0), zero)
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: -4032, height: 3024), zero)
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: .nan, height: 3024), zero)
        XCTAssertEqual(AspectRatio.fourThree.centeredCrop(width: 4032, height: .infinity), zero)
    }

    // MARK: - Normalized crop

    func testNormalizedCrop() {
        assertRect(AspectRatio.sixteenNine.normalizedCrop(imageAspect: 4.0 / 3.0), x: 0, y: 0.125, width: 1, height: 0.75)
        assertRect(AspectRatio.square.normalizedCrop(imageAspect: 4.0 / 3.0), x: 0.125, y: 0, width: 0.75, height: 1)
        assertRect(AspectRatio.fourThree.normalizedCrop(imageAspect: 4.0 / 3.0), x: 0, y: 0, width: 1, height: 1)
        assertRect(AspectRatio.fourThree.normalizedCrop(imageAspect: 16.0 / 9.0), x: 0.125, y: 0, width: 0.75, height: 1)
    }

    func testNormalizedCropOfAPortraitImage() {
        assertRect(AspectRatio.sixteenNine.normalizedCrop(imageAspect: 3.0 / 4.0), x: 0.125, y: 0, width: 0.75, height: 1)
        assertRect(AspectRatio.fourThree.normalizedCrop(imageAspect: 3.0 / 4.0), x: 0, y: 0, width: 1, height: 1)
        assertRect(AspectRatio.square.normalizedCrop(imageAspect: 3.0 / 4.0), x: 0, y: 0.125, width: 1, height: 0.75)
    }

    func testNormalizedCropMatchesThePixelCrop() {
        let sizes: [(Double, Double)] = [(4032, 3024), (3024, 4032), (1920, 1080), (3000, 3000), (1, 1000)]
        for preset in AspectRatio.presets {
            for (w, h) in sizes {
                let pixels = preset.centeredCrop(width: w, height: h)
                assertRect(preset.normalizedCrop(imageAspect: w / h),
                           x: pixels.x / w, y: pixels.y / h, width: pixels.width / w, height: pixels.height / h,
                           accuracy: 1e-12)
            }
        }
    }

    func testNormalizedCropStaysInsideTheUnitSquareAtTheRoundingEdge() {
        // One ulp under 65 / 24 used to give a width of 1.0000000000000002 and a negative x.
        XCTAssertEqual(AspectRatio.xpan.normalizedCrop(imageAspect: (65.0 / 24).nextDown), .unit)
        var outside: [String] = []
        for preset in AspectRatio.presets {
            for shape in [preset.ratio, 1 / preset.ratio] {
                var aspect = shape.nextDown.nextDown.nextDown.nextDown
                for _ in 0..<9 {
                    let crop = preset.normalizedCrop(imageAspect: aspect)
                    if crop.x < 0 || crop.y < 0 || crop.maxX > 1 || crop.maxY > 1 {
                        outside.append("\(preset.label) at \(aspect): \(crop)")
                    }
                    aspect = aspect.nextUp
                }
            }
        }
        XCTAssertTrue(outside.isEmpty, "\(outside.count) crops leave the frame, e.g. \(outside.prefix(3))")
    }

    func testNormalizedCropOfAnUnusableAspectKeepsTheWholeFrame() {
        XCTAssertEqual(AspectRatio.sixteenNine.normalizedCrop(imageAspect: 0), .unit)
        XCTAssertEqual(AspectRatio.sixteenNine.normalizedCrop(imageAspect: -1.5), .unit)
        XCTAssertEqual(AspectRatio.sixteenNine.normalizedCrop(imageAspect: .nan), .unit)
        XCTAssertEqual(AspectRatio.sixteenNine.normalizedCrop(imageAspect: .infinity), .unit)
    }

    // MARK: - Matching

    func testMatchesWithinHalfAPercent() {
        XCTAssertTrue(AspectRatio.sixteenNine.matches(AspectRatio(1.78, 1)))
        XCTAssertTrue(AspectRatio.fourThree.matches(AspectRatio(3, 4)))
        XCTAssertTrue(AspectRatio.fourThree.matches(AspectRatio(1.33, 1)))
        XCTAssertTrue(AspectRatio.fourThree.matches(AspectRatio(4032, 3024)))
        XCTAssertTrue(AspectRatio.cinemaScope.matches(AspectRatio(2.4, 1)))
        XCTAssertTrue(AspectRatio(1.5, 1).matches(AspectRatio(1.506, 1)))
        XCTAssertFalse(AspectRatio(1.5, 1).matches(AspectRatio(1.509, 1)))
        XCTAssertFalse(AspectRatio.cinemaScope.matches(AspectRatio(2.35, 1)))
        XCTAssertFalse(AspectRatio.sixteenNine.matches(AspectRatio(1.85, 1)))
        XCTAssertFalse(AspectRatio.fourThree.matches(.threeTwo))
    }

    func testMatchesIsReflexiveAndSymmetric() {
        let shapes = AspectRatio.presets + [AspectRatio(1.78, 1), AspectRatio(1.506, 1), AspectRatio(1.509, 1)]
        for a in shapes {
            XCTAssertTrue(a.matches(a))
            for b in shapes {
                XCTAssertEqual(a.matches(b), b.matches(a), "\(a.label) vs \(b.label)")
            }
        }
    }

    func testPresetsAreDistinctShapes() {
        for (i, a) in AspectRatio.presets.enumerated() {
            for (j, b) in AspectRatio.presets.enumerated() where i != j {
                XCTAssertFalse(a.matches(b), "\(a.label) vs \(b.label)")
            }
        }
    }

    // MARK: - Assigned sides

    func testDirectlyAssignedSidesStillReadSafely() {
        var shape = AspectRatio.sixteenNine
        shape.long = 1
        // Swapped sides read as the same shape the init would have made.
        XCTAssertEqual(shape.ratio, 9)
        XCTAssertEqual(shape.label, "9:1")
        shape.short = 0
        XCTAssertEqual(shape.ratio, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(shape.label, "4:3")
        XCTAssertEqual(shape.centeredCrop(width: 4032, height: 3024), CropRect(x: 0, y: 0, width: 4032, height: 3024))
        shape.long = .nan
        XCTAssertEqual(shape.ratio, 4.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: - Coding

    func testCodableRoundTrip() throws {
        for preset in AspectRatio.presets {
            let data = try JSONEncoder().encode(preset)
            XCTAssertEqual(try JSONDecoder().decode(AspectRatio.self, from: data), preset)
        }
    }

    func testCodableUsesLongAndShortKeys() throws {
        let data = try JSONEncoder().encode(AspectRatio.sixteenNine)
        XCTAssertEqual(try JSONDecoder().decode([String: Double].self, from: data), ["long": 16, "short": 9])
    }

    func testDecodingAppliesTheInitRules() throws {
        let swapped = try JSONDecoder().decode(AspectRatio.self, from: Data(#"{"long": 3, "short": 4}"#.utf8))
        XCTAssertEqual(swapped, .fourThree)
        let invalid = try JSONDecoder().decode(AspectRatio.self, from: Data(#"{"long": 0, "short": -2}"#.utf8))
        XCTAssertEqual(invalid, .fourThree)
        XCTAssertThrowsError(try JSONDecoder().decode(AspectRatio.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AspectRatio.self, from: Data(#"{"long": "4", "short": 3}"#.utf8)))
    }

    func testHashable() {
        let shapes = Set([AspectRatio.fourThree, AspectRatio(3, 4), AspectRatio.sixteenNine])
        XCTAssertEqual(shapes.count, 2)
    }
}
