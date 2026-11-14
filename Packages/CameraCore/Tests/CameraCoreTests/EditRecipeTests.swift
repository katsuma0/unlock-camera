import Foundation
import XCTest
@testable import CameraCore

final class EditRecipeTests: XCTestCase {
    private let colorPaths: [(String, WritableKeyPath<EditRecipe, Double>)] = [
        ("exposure", \.exposure), ("highlights", \.highlights), ("shadows", \.shadows), ("contrast", \.contrast),
        ("brightness", \.brightness), ("saturation", \.saturation), ("vibrance", \.vibrance), ("warmth", \.warmth),
        ("tint", \.tint),
    ]
    private let unitPaths: [(String, WritableKeyPath<EditRecipe, Double>)] = [
        ("sharpness", \.sharpness), ("vignette", \.vignette),
    ]

    private func full() -> EditRecipe {
        EditRecipe(exposure: 0.1 + 0.2, highlights: -0.7, shadows: 0.45, contrast: 1.0 / 3, brightness: -0.25,
                   saturation: 0.6, vibrance: -0.15, warmth: 0.8, tint: -0.33, sharpness: 0.2 + 0.1,
                   vignette: 0.75, look: .chrome, quarterTurns: 3, flipped: true, straightenDegrees: -12.5,
                   crop: CropRect(x: 0.1, y: 0.2, width: 0.3 + 0.0000001, height: 0.4), cropAspect: .threeTwo)
    }

    private func assertRect(_ rect: CropRect?, _ expected: CropRect, file: StaticString = #filePath,
                            line: UInt = #line) {
        guard let rect else { return XCTFail("no crop", file: file, line: line) }
        XCTAssertEqual(rect.x, expected.x, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(rect.y, expected.y, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 1e-12, file: file, line: line)
    }

    // MARK: - Identity

    func testIdentityRendersNothing() {
        let recipe = EditRecipe()
        XCTAssertEqual(recipe, .identity)
        XCTAssertTrue(recipe.isIdentity)
        XCTAssertFalse(recipe.hasGeometry)
        XCTAssertNil(recipe.crop)
        XCTAssertNil(recipe.cropAspect)

        let p = recipe.parameters
        XCTAssertEqual(p.orientation, 1)
        XCTAssertEqual(p.straightenAngle, 0)
        XCTAssertEqual(p.ev, 0)
        XCTAssertEqual(p.highlightAmount, 1)
        XCTAssertEqual(p.shadowAmount, 0)
        XCTAssertEqual(p.toneCurve, EditParameters.identityCurve)
        XCTAssertEqual(p.contrast, 1)
        XCTAssertEqual(p.brightness, 0)
        XCTAssertEqual(p.saturation, 1)
        XCTAssertEqual(p.vibrance, 0)
        XCTAssertEqual(p.targetNeutral, EditParameters.neutral)
        XCTAssertNil(p.lookFilterName)
        XCTAssertEqual(p.sharpness, 0)
        XCTAssertEqual(p.vignetteIntensity, 0)
        XCTAssertTrue(p.isNeutral)
        XCTAssertFalse(p.usesOrientation || p.usesStraighten || p.usesExposure || p.usesHighlightShadow
                       || p.usesToneCurve || p.usesColorControls || p.usesVibrance || p.usesTemperatureAndTint
                       || p.usesLook || p.usesSharpen || p.usesVignette)
    }

    func testFilterConstants() {
        XCTAssertEqual(EditParameters.neutral, EditParameters.WhitePoint(temperature: 6500, tint: 0))
        XCTAssertEqual(EditParameters.identityCurve.map(\.x), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(EditParameters.identityCurve.map(\.y), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(EditParameters.highlightShadowRadius, 0)
        XCTAssertEqual(EditParameters.sharpenRadius, 1.69)
        XCTAssertEqual(EditParameters.vignetteRadius, 1.5)
    }

    func testEveryChangeBreaksIdentity() {
        for (name, path) in colorPaths + unitPaths {
            var recipe = EditRecipe()
            recipe[keyPath: path] = 0.5
            XCTAssertFalse(recipe.isIdentity, name)
            XCTAssertFalse(recipe.hasGeometry, name)
            XCTAssertFalse(recipe.parameters.isNeutral, name)
        }
        var look = EditRecipe()
        look.look = .mono
        XCTAssertFalse(look.isIdentity)
        XCTAssertTrue(look.parameters.usesLook)

        var turned = EditRecipe()
        turned.quarterTurns = 1
        var mirrored = EditRecipe()
        mirrored.flipped = true
        var straightened = EditRecipe()
        straightened.straightenDegrees = 1
        var cropped = EditRecipe()
        cropped.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        for recipe in [turned, mirrored, straightened, cropped] {
            XCTAssertFalse(recipe.isIdentity)
            XCTAssertTrue(recipe.hasGeometry)
        }
        XCTAssertTrue(turned.parameters.usesOrientation)
        XCTAssertTrue(mirrored.parameters.usesOrientation)
        XCTAssertTrue(straightened.parameters.usesStraighten)
        XCTAssertTrue(cropped.parameters.isNeutral)

        // A preset that matches the photo crops nothing, so the photo is still the original.
        var namedOnly = EditRecipe()
        namedOnly.cropAspect = .fourThree
        XCTAssertTrue(namedOnly.isIdentity)
        XCTAssertNotEqual(namedOnly, .identity)
    }

    // MARK: - Clamping

    func testAdjustmentsClampWhenSetAndWhenMade() {
        for (name, path) in colorPaths {
            var recipe = EditRecipe()
            recipe[keyPath: path] = 3
            XCTAssertEqual(recipe[keyPath: path], 1, name)
            recipe[keyPath: path] = -3
            XCTAssertEqual(recipe[keyPath: path], -1, name)
            recipe[keyPath: path] = .nan
            XCTAssertEqual(recipe[keyPath: path], 0, name)
            recipe[keyPath: path] = .infinity
            XCTAssertEqual(recipe[keyPath: path], 1, name)
            recipe[keyPath: path] = -0.4
            XCTAssertEqual(recipe[keyPath: path], -0.4, name)
        }
        for (name, path) in unitPaths {
            var recipe = EditRecipe()
            recipe[keyPath: path] = -0.5
            XCTAssertEqual(recipe[keyPath: path], 0, name)
            recipe[keyPath: path] = 2
            XCTAssertEqual(recipe[keyPath: path], 1, name)
            recipe[keyPath: path] = .nan
            XCTAssertEqual(recipe[keyPath: path], 0, name)
            recipe[keyPath: path] = 0.3
            XCTAssertEqual(recipe[keyPath: path], 0.3, name)
        }
        let made = EditRecipe(exposure: 9, highlights: -.infinity, shadows: .nan, contrast: 2, brightness: -2,
                              saturation: 1.5, vibrance: -7, warmth: 1.01, tint: -1.01, sharpness: 4, vignette: -1,
                              straightenDegrees: 90)
        XCTAssertEqual(made.exposure, 1)
        XCTAssertEqual(made.highlights, -1)
        XCTAssertEqual(made.shadows, 0)
        XCTAssertEqual(made.contrast, 1)
        XCTAssertEqual(made.brightness, -1)
        XCTAssertEqual(made.saturation, 1)
        XCTAssertEqual(made.vibrance, -1)
        XCTAssertEqual(made.warmth, 1)
        XCTAssertEqual(made.tint, -1)
        XCTAssertEqual(made.sharpness, 1)
        XCTAssertEqual(made.vignette, 0)
        XCTAssertEqual(made.straightenDegrees, 45)
    }

    func testStraightenClampsAndTurnsWrap() {
        var recipe = EditRecipe()
        recipe.straightenDegrees = -90
        XCTAssertEqual(recipe.straightenDegrees, -45)
        recipe.straightenDegrees = .nan
        XCTAssertEqual(recipe.straightenDegrees, 0)
        recipe.straightenDegrees = 12.5
        XCTAssertEqual(recipe.straightenDegrees, 12.5)

        let cases = [(0, 0), (1, 1), (3, 3), (4, 0), (5, 1), (-1, 3), (-4, 0), (-6, 2), (Int.max, 3), (Int.min, 0)]
        for (turns, expected) in cases {
            recipe.quarterTurns = turns
            XCTAssertEqual(recipe.quarterTurns, expected, "\(turns)")
            XCTAssertEqual(EditRecipe(quarterTurns: turns).quarterTurns, expected, "\(turns)")
        }
        recipe.quarterTurns = 3
        recipe.quarterTurns += 1
        XCTAssertEqual(recipe.quarterTurns, 0)
    }

    func testCropStaysInsideThePicture() {
        var recipe = EditRecipe()
        recipe.crop = CropRect(x: -0.2, y: 0.5, width: 0.7, height: 0.9)
        assertRect(recipe.crop, CropRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        recipe.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        assertRect(recipe.crop, CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        for bad in [CropRect(x: .nan, y: 0, width: 0.5, height: 0.5), CropRect(x: 0, y: 0, width: .infinity, height: 1),
                    CropRect(x: 0.5, y: 0.5, width: -0.2, height: 0.3), CropRect(x: 1.2, y: 0, width: 0.5, height: 1),
                    CropRect(x: 0.2, y: 0.2, width: 0.009, height: 0.5), CropRect(x: 0, y: 0, width: 1, height: 1),
                    CropRect(x: -0.1, y: -0.1, width: 1.3, height: 1.2),
                    CropRect(x: 1e-12, y: 0, width: 1 - 2e-12, height: 1)] {
            recipe.crop = bad
            XCTAssertNil(recipe.crop, "\(bad)")
            XCTAssertNil(EditRecipe(crop: bad).crop, "\(bad)")
        }
        recipe.crop = CropRect(x: 0.2, y: 0.2, width: EditRecipe.minimumCropSide, height: 0.5)
        XCTAssertNotNil(recipe.crop)
    }

    func testACropInsideThePictureReadsBackExactly() throws {
        // 0.1 + 0.3 - 0.1 is 0.30000000000000004 in doubles, so recomputing a side would change it.
        let inside = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        var recipe = EditRecipe()
        recipe.crop = inside
        XCTAssertEqual(recipe.crop, inside)
        XCTAssertEqual(EditRecipe(crop: inside).crop, inside)
        XCTAssertEqual(EditRecipe.decoded(from: try EditRecipe(crop: inside).encoded()).crop, inside)
    }

    func testWarmthAndTintAtZeroKeepTheExactWhite() {
        for value in [0.0, -0.0] {
            XCTAssertEqual(EditRecipe(warmth: value, tint: value).parameters.targetNeutral, EditParameters.neutral)
            XCTAssertFalse(EditRecipe(warmth: value, tint: value).parameters.usesTemperatureAndTint)
        }
    }

    // MARK: - Adjustment data

    func testFormat() {
        XCTAssertEqual(EditRecipe.formatIdentifier, "ca.katsuma.openshutter.edit")
        XCTAssertEqual(EditRecipe.formatVersion, "1")
        XCTAssertTrue(EditRecipe.canRead(formatIdentifier: "ca.katsuma.openshutter.edit", formatVersion: "1"))
        XCTAssertFalse(EditRecipe.canRead(formatIdentifier: "ca.katsuma.openshutter.edit", formatVersion: "2"))
        XCTAssertFalse(EditRecipe.canRead(formatIdentifier: "com.apple.photo", formatVersion: "1"))
    }

    func testCodableRoundTrip() throws {
        let recipe = full()
        let data = try recipe.encoded()
        let restored = EditRecipe.decoded(from: data)
        XCTAssertEqual(restored, recipe)
        XCTAssertEqual(try restored.encoded(), data)
        XCTAssertEqual(EditRecipe.decoded(from: try EditRecipe().encoded()), .identity)
    }

    func testTheJSONStaysUnderOneKilobyte() throws {
        let data = try full().encoded()
        XCTAssertLessThan(data.count, 1024)
        XCTAssertGreaterThan(data.count, 100)
        // Clamped values are never NaN, which JSON can't hold.
        XCTAssertNoThrow(try EditRecipe(exposure: .nan, straightenDegrees: .nan).encoded())
    }

    func testMissingKeysTakeDefaults() {
        let partial = EditRecipe.decoded(from: Data(#"{"exposure": 0.5, "look": "noir", "later": 1}"#.utf8))
        XCTAssertEqual(partial, EditRecipe(exposure: 0.5, look: .noir))
        XCTAssertEqual(EditRecipe.decoded(from: Data("{}".utf8)), .identity)
        for garbage in ["", "nope", "[]", "null", "3"] {
            XCTAssertEqual(EditRecipe.decoded(from: Data(garbage.utf8)), .identity, garbage)
        }
    }

    func testDecodingClampsAndToleratesBadValues() {
        let restored = EditRecipe.decoded(from: Data(#"""
        {"exposure": 7, "highlights": "bright", "sharpness": -2, "vignette": 0.25, "quarterTurns": 6,
         "flipped": "yes", "straightenDegrees": 100, "look": "sepia",
         "crop": {"x": -1, "y": 0.5, "width": 1.5, "height": 2}, "cropAspect": {"long": 16, "short": 9}}
        """#.utf8))
        XCTAssertEqual(restored.exposure, 1)
        XCTAssertEqual(restored.highlights, 0)
        XCTAssertEqual(restored.sharpness, 0)
        XCTAssertEqual(restored.vignette, 0.25)
        XCTAssertEqual(restored.quarterTurns, 2)
        XCTAssertFalse(restored.flipped)
        XCTAssertEqual(restored.straightenDegrees, 45)
        XCTAssertEqual(restored.look, .none)
        assertRect(restored.crop, CropRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(restored.cropAspect, .sixteenNine)

        let badCrop = EditRecipe.decoded(from: Data(#"{"crop": {"x": 0.1}, "cropAspect": "wide", "tint": -0.5}"#.utf8))
        XCTAssertNil(badCrop.crop)
        XCTAssertNil(badCrop.cropAspect)
        XCTAssertEqual(badCrop.tint, -0.5)
    }

    func testColorOnlyResetsTheGeometryOnly() {
        let recipe = full()
        let color = recipe.colorOnly
        XCTAssertFalse(color.hasGeometry)
        XCTAssertEqual(color.quarterTurns, 0)
        XCTAssertFalse(color.flipped)
        XCTAssertEqual(color.straightenDegrees, 0)
        XCTAssertNil(color.crop)
        XCTAssertNil(color.cropAspect)
        for (name, path) in colorPaths + unitPaths {
            XCTAssertEqual(color[keyPath: path], recipe[keyPath: path], name)
        }
        XCTAssertEqual(color.look, .chrome)
        XCTAssertEqual(color.parameters.orientation, 1)
        XCTAssertEqual(color.parameters.straightenAngle, 0)
        XCTAssertEqual(color.parameters.ev, recipe.parameters.ev)
        XCTAssertEqual(color.parameters.targetNeutral, recipe.parameters.targetNeutral)
        XCTAssertTrue(EditRecipe(quarterTurns: 1, flipped: true).colorOnly.isIdentity)
    }

    // MARK: - Filter values

    func testParametersAtFullStrength() {
        let up = EditRecipe(exposure: 1, highlights: 1, shadows: 1, contrast: 1, brightness: 1, saturation: 1,
                            vibrance: 1, warmth: 1, tint: 1, sharpness: 1, vignette: 1,
                            straightenDegrees: 45).parameters
        XCTAssertEqual(up.ev, 2)
        XCTAssertEqual(up.highlightAmount, 1)
        XCTAssertEqual(up.toneCurve[3].y, 0.85, accuracy: 1e-12)
        XCTAssertEqual(up.toneCurve.map(\.x), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual([up.toneCurve[0].y, up.toneCurve[1].y, up.toneCurve[2].y, up.toneCurve[4].y], [0, 0.25, 0.5, 1])
        XCTAssertEqual(up.shadowAmount, 1)
        XCTAssertEqual(up.contrast, 1.3, accuracy: 1e-12)
        XCTAssertEqual(up.brightness, 0.15, accuracy: 1e-12)
        XCTAssertEqual(up.saturation, 2)
        XCTAssertEqual(up.vibrance, 1)
        XCTAssertEqual(up.targetNeutral.temperature, 1_000_000 / (1_000_000 / 6500 + 75), accuracy: 1e-9)
        XCTAssertLessThan(up.targetNeutral.temperature, 4400)
        XCTAssertEqual(up.targetNeutral.tint, -50)
        XCTAssertEqual(up.sharpness, 0.8, accuracy: 1e-12)
        XCTAssertEqual(up.vignetteIntensity, 1)
        XCTAssertEqual(up.straightenAngle, .pi / 4, accuracy: 1e-12)

        let down = EditRecipe(exposure: -1, highlights: -1, shadows: -1, contrast: -1, brightness: -1, saturation: -1,
                              vibrance: -1, warmth: -1, tint: -1, straightenDegrees: -45).parameters
        XCTAssertEqual(down.ev, -2)
        XCTAssertEqual(down.highlightAmount, 0.25, accuracy: 1e-12)
        XCTAssertEqual(down.toneCurve, EditParameters.identityCurve)
        XCTAssertEqual(down.shadowAmount, -1)
        XCTAssertEqual(down.contrast, 0.7, accuracy: 1e-12)
        XCTAssertEqual(down.brightness, -0.15, accuracy: 1e-12)
        XCTAssertEqual(down.saturation, 0)
        XCTAssertEqual(down.vibrance, -1)
        XCTAssertGreaterThan(down.targetNeutral.temperature, 12_000)
        XCTAssertEqual(down.targetNeutral.tint, 50)
        XCTAssertEqual(down.straightenAngle, -.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(EditParameters.neutral, EditParameters.WhitePoint(temperature: 6500, tint: 0))
    }

    func testParametersMoveTheRightWayAndAreMonotonic() {
        let steps = stride(from: -1.0, through: 1.0, by: 0.125).map { $0 }
        func series(_ build: (Double) -> EditRecipe, _ read: (EditParameters) -> Double) -> [Double] {
            steps.map { read(build($0).parameters) }
        }
        func assertRising(_ values: [Double], _ name: String, strictly: Bool = true) {
            for (a, b) in zip(values, values.dropFirst()) {
                if strictly { XCTAssertLessThan(a, b, name) } else { XCTAssertLessThanOrEqual(a, b, name) }
            }
        }
        assertRising(series({ EditRecipe(exposure: $0) }, \.ev), "exposure")
        assertRising(series({ EditRecipe(shadows: $0) }, \.shadowAmount), "shadows")
        assertRising(series({ EditRecipe(contrast: $0) }, \.contrast), "contrast")
        assertRising(series({ EditRecipe(brightness: $0) }, \.brightness), "brightness")
        assertRising(series({ EditRecipe(saturation: $0) }, \.saturation), "saturation")
        assertRising(series({ EditRecipe(vibrance: $0) }, \.vibrance), "vibrance")
        assertRising(series({ EditRecipe(straightenDegrees: $0 * 45) }, \.straightenAngle), "straighten")
        // Warmer and pinker both move the target white away from the picture's own white.
        assertRising(series({ EditRecipe(warmth: $0) }, { -$0.targetNeutral.temperature }), "warmth")
        assertRising(series({ EditRecipe(tint: $0) }, { -$0.targetNeutral.tint }), "tint")
        // Highlights recover below 0 and lift above it, so one of the two moves at every step and neither goes back.
        let amounts = series({ EditRecipe(highlights: $0) }, \.highlightAmount)
        let lifts = series({ EditRecipe(highlights: $0) }, { $0.toneCurve[3].y })
        assertRising(amounts, "highlight amount", strictly: false)
        assertRising(lifts, "highlight lift", strictly: false)
        assertRising(zip(amounts, lifts).map { $0 + $1 }, "highlights")

        let unitSteps = stride(from: 0.0, through: 1.0, by: 0.125).map { $0 }
        assertRising(unitSteps.map { EditRecipe(sharpness: $0).parameters.sharpness }, "sharpness")
        assertRising(unitSteps.map { EditRecipe(vignette: $0).parameters.vignetteIntensity }, "vignette")
    }

    func testOnlyTheMovedFilterRuns() {
        let warm = EditRecipe(warmth: 0.2).parameters
        XCTAssertTrue(warm.usesTemperatureAndTint)
        XCTAssertFalse(warm.usesColorControls || warm.usesExposure || warm.usesToneCurve || warm.usesHighlightShadow)
        let bright = EditRecipe(highlights: 0.4).parameters
        XCTAssertTrue(bright.usesToneCurve)
        XCTAssertFalse(bright.usesHighlightShadow)
        let recover = EditRecipe(highlights: -0.4).parameters
        XCTAssertTrue(recover.usesHighlightShadow)
        XCTAssertFalse(recover.usesToneCurve)
        XCTAssertTrue(EditRecipe(shadows: 0.1).parameters.usesHighlightShadow)
        XCTAssertTrue(EditRecipe(saturation: -0.1).parameters.usesColorControls)
        XCTAssertTrue(EditRecipe(tint: 0.1).parameters.usesTemperatureAndTint)
        XCTAssertTrue(EditRecipe(vibrance: 0.1).parameters.usesVibrance)
        XCTAssertTrue(EditRecipe(sharpness: 0.1).parameters.usesSharpen)
        XCTAssertTrue(EditRecipe(vignette: 0.1).parameters.usesVignette)
        XCTAssertTrue(EditRecipe(exposure: 0.1).parameters.usesExposure)
    }

    func testLooks() {
        XCTAssertEqual(EditRecipe.Look.allCases.map(\.title),
                       ["Original", "Mono", "Tonal", "Noir", "Fade", "Chrome", "Process", "Transfer", "Instant"])
        XCTAssertNil(EditRecipe.Look.none.filterName)
        XCTAssertEqual(EditRecipe.Look.allCases.compactMap(\.filterName),
                       ["CIPhotoEffectMono", "CIPhotoEffectTonal", "CIPhotoEffectNoir", "CIPhotoEffectFade",
                        "CIPhotoEffectChrome", "CIPhotoEffectProcess", "CIPhotoEffectTransfer", "CIPhotoEffectInstant"])
        XCTAssertEqual(EditRecipe(look: .fade).parameters.lookFilterName, "CIPhotoEffectFade")
    }

    // MARK: - Geometry

    // 2 x 2 integer matrices on centred picture coordinates, x to the right and y down, as EXIF describes them.
    private typealias Matrix = [[Int]]
    private func times(_ a: Matrix, _ b: Matrix) -> Matrix {
        (0..<2).map { r in (0..<2).map { c in a[r][0] * b[0][c] + a[r][1] * b[1][c] } }
    }
    private let identity: Matrix = [[1, 0], [0, 1]]
    /// A quarter turn counterclockwise on screen: the top edge goes to the left.
    private let turn: Matrix = [[0, 1], [-1, 0]]
    /// Left and right swap.
    private let mirror: Matrix = [[-1, 0], [0, 1]]
    private func transform(_ recipe: EditRecipe) -> Matrix {
        var result = recipe.flipped ? mirror : identity
        for _ in 0..<recipe.quarterTurns { result = times(turn, result) }
        return result
    }

    func testOrientationMatchesTheEXIFMeaning() {
        // What showing each orientation upright does to the stored picture.
        let exif: [Int: Matrix] = [
            1: [[1, 0], [0, 1]],
            2: [[-1, 0], [0, 1]],    // mirrored left to right
            3: [[-1, 0], [0, -1]],   // half a turn
            4: [[1, 0], [0, -1]],    // mirrored top to bottom
            5: [[0, 1], [1, 0]],     // rows become columns
            6: [[0, -1], [1, 0]],    // a quarter turn clockwise
            7: [[0, -1], [-1, 0]],   // rows become columns, both reversed
            8: [[0, 1], [-1, 0]],    // a quarter turn counterclockwise
        ]
        var seen = Set<Int>()
        for turns in 0..<4 {
            for flipped in [false, true] {
                let recipe = EditRecipe(quarterTurns: turns, flipped: flipped)
                let orientation = recipe.parameters.orientation
                XCTAssertEqual(exif[orientation], transform(recipe), "\(turns) turns, flipped \(flipped)")
                seen.insert(orientation)
            }
        }
        XCTAssertEqual(seen, Set(1...8))
    }

    func testRotateAndFlipFollowTheScreen() {
        for turns in 0..<4 {
            for flipped in [false, true] {
                let start = EditRecipe(quarterTurns: turns, flipped: flipped, straightenDegrees: 10)
                var rotated = start
                rotated.rotateCounterclockwise()
                XCTAssertEqual(transform(rotated), times(turn, transform(start)), "rotate \(turns) \(flipped)")
                XCTAssertEqual(rotated.straightenDegrees, 10)
                var mirrored = start
                mirrored.flipHorizontally()
                XCTAssertEqual(transform(mirrored), times(mirror, transform(start)), "flip \(turns) \(flipped)")
                XCTAssertEqual(mirrored.straightenDegrees, -10)
            }
        }
    }

    func testTheCropFollowsRotateAndFlip() {
        var recipe = EditRecipe(crop: CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        recipe.rotateCounterclockwise()
        // The top edge goes left, so the left edge goes to the bottom.
        assertRect(recipe.crop, CropRect(x: 0.2, y: 0.6, width: 0.4, height: 0.3))
        for _ in 0..<3 { recipe.rotateCounterclockwise() }
        XCTAssertEqual(recipe.quarterTurns, 0)
        assertRect(recipe.crop, CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))

        recipe.flipHorizontally()
        assertRect(recipe.crop, CropRect(x: 0.6, y: 0.2, width: 0.3, height: 0.4))
        recipe.flipHorizontally()
        assertRect(recipe.crop, CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertFalse(recipe.flipped)

        var plain = EditRecipe()
        plain.rotateCounterclockwise()
        plain.flipHorizontally()
        XCTAssertNil(plain.crop)
        XCTAssertEqual(plain.quarterTurns, 3)
        XCTAssertTrue(plain.flipped)
    }

    func testCenteredCropShapes() {
        let landscape = 4.0 / 3
        // A lying 16:9 in a lying 4:3 photo takes the full width.
        assertRect(EditRecipe.centeredCrop(.sixteenNine, portrait: false, imageAspect: landscape),
                   CropRect(x: 0, y: 0.125, width: 1, height: 0.75))
        // A standing 16:9 in the same photo takes the full height.
        let standingWidth = (9.0 / 16) / landscape
        assertRect(EditRecipe.centeredCrop(.sixteenNine, portrait: true, imageAspect: landscape),
                   CropRect(x: (1 - standingWidth) / 2, y: 0, width: standingWidth, height: 1))
        assertRect(EditRecipe.centeredCrop(.square, portrait: false, imageAspect: 3.0 / 4),
                   CropRect(x: 0, y: 0.125, width: 1, height: 0.75))
        assertRect(EditRecipe.centeredCrop(.square, portrait: true, imageAspect: 3.0 / 4),
                   CropRect(x: 0, y: 0.125, width: 1, height: 0.75))
        XCTAssertEqual(EditRecipe.centeredCrop(.fourThree, portrait: false, imageAspect: 4032.0 / 3024), .unit)
        XCTAssertEqual(EditRecipe.centeredCrop(.fourThree, portrait: true, imageAspect: 3024.0 / 4032), .unit)
        for bad in [0, -1, Double.nan, .infinity] {
            XCTAssertEqual(EditRecipe.centeredCrop(.threeTwo, portrait: false, imageAspect: bad), .unit)
        }
    }

    func testSetCropAspectFollowsTheTurns() {
        var recipe = EditRecipe()
        recipe.setCropAspect(.square, portrait: false, imageWidth: 4000, imageHeight: 3000)
        assertRect(recipe.crop, CropRect(x: 0.125, y: 0, width: 0.75, height: 1))
        XCTAssertEqual(recipe.cropAspect, .square)

        // Turned once, the 4000 x 3000 photo shows standing, 3000 wide.
        recipe.quarterTurns = 1
        recipe.setCropAspect(.square, portrait: false, imageWidth: 4000, imageHeight: 3000)
        assertRect(recipe.crop, CropRect(x: 0, y: 0.125, width: 1, height: 0.75))

        recipe.setCropAspect(.fourThree, portrait: true, imageWidth: 4000, imageHeight: 3000)
        XCTAssertNil(recipe.crop)
        XCTAssertEqual(recipe.cropAspect, .fourThree)

        recipe.setCropAspect(nil, portrait: false, imageWidth: 4000, imageHeight: 3000)
        XCTAssertNil(recipe.crop)
        XCTAssertNil(recipe.cropAspect)
    }
}
