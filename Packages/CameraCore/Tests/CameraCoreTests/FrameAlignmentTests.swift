import XCTest
@testable import CameraCore

final class FrameAlignmentTests: XCTestCase {
    // MARK: - Test scenes

    /// Smooth multi-scale value noise defined on the whole plane, so a copy moved by any real offset can be
    /// rendered exactly: moving(x, y) = scene(x - dx, y - dy) gives moving(x + dx, y + dy) = reference(x, y).
    private static func scene(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        var total = 0.0
        var amplitude = 0.5
        var spacing = 40.0
        for octave in 0..<4 {
            total += amplitude * valueNoise(x / spacing, y / spacing, seed: seed &* 31 &+ UInt64(octave))
            amplitude *= 0.5
            spacing *= 0.4
        }
        return total
    }

    private static func valueNoise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let x0 = x.rounded(.down)
        let y0 = y.rounded(.down)
        let fx = x - x0
        let fy = y - y0
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let ix = Int64(x0)
        let iy = Int64(y0)
        let a = lattice(ix, iy, seed)
        let b = lattice(ix + 1, iy, seed)
        let c = lattice(ix, iy + 1, seed)
        let d = lattice(ix + 1, iy + 1, seed)
        let topRow = a + (b - a) * sx
        let bottomRow = c + (d - c) * sx
        return topRow + (bottomRow - topRow) * sy
    }

    private static func lattice(_ x: Int64, _ y: Int64, _ seed: UInt64) -> Double {
        var h = (UInt64(bitPattern: x) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: y) &* 0xC2B2_AE3D_27D4_EB4F)
        h ^= seed &* 0x1656_67B1_9E37_79F9
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h &*= 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }

    private static func render(width: Int, height: Int, shiftX: Double = 0, shiftY: Double = 0,
                               seed: UInt64 = 7) -> LumaImage {
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = Float(scene(Double(x) - shiftX, Double(y) - shiftY, seed: seed))
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    private static func blob(width: Int, height: Int, centerX: Double, centerY: Double, sigma: Double) -> LumaImage {
        var image = LumaImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                image[x, y] = Float(exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
            }
        }
        return image
    }

    private static func boxBlurred(_ image: LumaImage) -> LumaImage {
        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                var sum: Float = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        sum += image[x + ox, y + oy]
                    }
                }
                out[x, y] = sum / 9
            }
        }
        return out
    }

    private static func scaled(_ image: LumaImage, by factor: Float) -> LumaImage {
        var out = image
        for i in out.pixels.indices {
            out.pixels[i] *= factor
        }
        return out
    }

    // MARK: - AlignmentResult

    func testAlignmentResultStoresValues() {
        let result = AlignmentResult(dx: -3.25, dy: 7.5, confidence: 0.4)
        XCTAssertEqual(result.dx, -3.25)
        XCTAssertEqual(result.dy, 7.5)
        XCTAssertEqual(result.confidence, 0.4)
    }

    func testAlignmentResultClampsConfidenceIntoUnitRange() {
        XCTAssertEqual(AlignmentResult(dx: 0, dy: 0, confidence: 1.5).confidence, 1)
        XCTAssertEqual(AlignmentResult(dx: 0, dy: 0, confidence: -0.2).confidence, 0)
        XCTAssertEqual(AlignmentResult(dx: 0, dy: 0, confidence: .nan).confidence, 0)
        XCTAssertEqual(AlignmentResult(dx: 0, dy: 0, confidence: .infinity).confidence, 1)
        XCTAssertEqual(AlignmentResult(dx: 0, dy: 0, confidence: 0).confidence, 0)
        XCTAssertEqual(AlignmentResult(dx: 0, dy: 0, confidence: 1).confidence, 1)
    }

    func testZeroHasNoShiftAndNoConfidence() {
        XCTAssertEqual(AlignmentResult.zero.dx, 0)
        XCTAssertEqual(AlignmentResult.zero.dy, 0)
        XCTAssertEqual(AlignmentResult.zero.confidence, 0)
        XCTAssertEqual(AlignmentResult.zero, AlignmentResult(dx: 0, dy: 0, confidence: 0))
    }

    func testAlignmentResultIsHashable() {
        let set: Set<AlignmentResult> = [
            AlignmentResult(dx: 1, dy: 2, confidence: 0.5),
            AlignmentResult(dx: 1, dy: 2, confidence: 0.5),
            AlignmentResult(dx: 2, dy: 1, confidence: 0.5),
            .zero,
        ]
        XCTAssertEqual(set.count, 3)
    }

    // MARK: - estimateTranslation: accuracy

    func testIdenticalImagesGiveNoShiftAndFullConfidence() {
        let image = Self.render(width: 192, height: 144)
        let result = FrameAlignment.estimateTranslation(reference: image, moving: image)
        XCTAssertEqual(result.dx, 0, accuracy: 0.02)
        XCTAssertEqual(result.dy, 0, accuracy: 0.02)
        XCTAssertEqual(result.confidence, 1, accuracy: 1e-12)
    }

    func testIntegerShiftsAreRecovered() {
        let reference = Self.render(width: 192, height: 144)
        let shifts = [(3, 2), (-5, 4), (0, -7), (12, 0), (-20, -15), (31, 22), (1, -1), (-44, 9)]
        for (dx, dy) in shifts {
            let moving = Self.render(width: 192, height: 144, shiftX: Double(dx), shiftY: Double(dy))
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
            XCTAssertEqual(result.dx, Double(dx), accuracy: 0.1, "shift (\(dx), \(dy))")
            XCTAssertEqual(result.dy, Double(dy), accuracy: 0.1, "shift (\(dx), \(dy))")
            XCTAssertGreaterThan(result.confidence, 0.5, "shift (\(dx), \(dy))")
        }
    }

    func testSubpixelShiftsAreRecovered() {
        let reference = Self.render(width: 192, height: 144)
        let shifts = [(2.5, -1.25), (-3.3, 0.6), (0.4, 0), (7.75, -4.5), (-0.5, 0.5), (15.2, 10.8)]
        for (dx, dy) in shifts {
            let moving = Self.render(width: 192, height: 144, shiftX: dx, shiftY: dy)
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
            XCTAssertEqual(result.dx, dx, accuracy: 0.2, "shift (\(dx), \(dy))")
            XCTAssertEqual(result.dy, dy, accuracy: 0.2, "shift (\(dx), \(dy))")
        }
    }

    func testPreviewSizedFramesUseTheFullSearchRange() {
        let reference = Self.render(width: 504, height: 378, seed: 3)
        for (dx, dy) in [(40.0, -30.0), (-47.0, 46.0), (6.5, 2.25)] {
            let moving = Self.render(width: 504, height: 378, shiftX: dx, shiftY: dy, seed: 3)
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
            XCTAssertEqual(result.dx, dx, accuracy: 0.2, "shift (\(dx), \(dy))")
            XCTAssertEqual(result.dy, dy, accuracy: 0.2, "shift (\(dx), \(dy))")
            XCTAssertGreaterThan(result.confidence, 0.5, "shift (\(dx), \(dy))")
        }
    }

    func testContentMovingRightAndDownGivesPositiveShift() {
        let reference = Self.blob(width: 160, height: 120, centerX: 70, centerY: 60, sigma: 6)
        let moving = Self.blob(width: 160, height: 120, centerX: 77, centerY: 64, sigma: 6)
        let forward = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
        XCTAssertEqual(forward.dx, 7, accuracy: 0.25)
        XCTAssertEqual(forward.dy, 4, accuracy: 0.25)
        let backward = FrameAlignment.estimateTranslation(reference: moving, moving: reference)
        XCTAssertEqual(backward.dx, -7, accuracy: 0.25)
        XCTAssertEqual(backward.dy, -4, accuracy: 0.25)
    }

    func testShiftingMovingByMinusResultAlignsItOntoReference() {
        let width = 192
        let height = 144
        let reference = Self.render(width: width, height: height)
        let moving = Self.render(width: width, height: height, shiftX: 5, shiftY: -3)
        let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
        let shiftX = -Int(result.dx.rounded())
        let shiftY = -Int(result.dy.rounded())
        XCTAssertEqual(shiftX, -5)
        XCTAssertEqual(shiftY, 3)

        var accumulator = StackAccumulator(width: width, height: height, channels: 1, blend: .average)
        accumulator.add(FloatImage(width: width, height: height, channels: 1, pixels: reference.pixels))
        accumulator.add(FloatImage(width: width, height: height, channels: 1, pixels: moving.pixels),
                        shiftX: shiftX, shiftY: shiftY)
        let stacked = accumulator.result()
        // Away from the edges the moved frame lands exactly on the reference, so the average changes nothing.
        for y in 10..<(height - 10) {
            for x in 10..<(width - 10) {
                XCTAssertEqual(stacked[x, y, 0], reference[x, y], accuracy: 1e-6, "(\(x), \(y))")
            }
        }
    }

    // MARK: - estimateTranslation: search behaviour

    /// `reference` with a white frame `percent` of each side wide.
    private static func whiteBorder(_ reference: LumaImage, percent: Int) -> LumaImage {
        var moving = reference
        let bandX = reference.width * percent / 100
        let bandY = reference.height * percent / 100
        for y in 0..<reference.height {
            for x in 0..<reference.width
            where x < bandX || x >= reference.width - bandX || y < bandY || y >= reference.height - bandY {
                moving[x, y] = 1
            }
        }
        return moving
    }

    func testBordersAreIgnored() {
        let reference = Self.render(width: 504, height: 378)
        // An 8% frame of pure white, inside the ignored 10% margins: a perfect match must stay perfect.
        let result = FrameAlignment.estimateTranslation(reference: reference,
                                                        moving: Self.whiteBorder(reference, percent: 8))
        XCTAssertEqual(result.dx, 0, accuracy: 0.05)
        XCTAssertEqual(result.dy, 0, accuracy: 0.05)
        XCTAssertGreaterThan(result.confidence, 0.99)
    }

    func testTheCentralEightyPercentIsCompared() {
        // A 12% frame reaches into the compared area, so the match is no longer perfect (but still found).
        let reference = Self.render(width: 504, height: 378)
        let result = FrameAlignment.estimateTranslation(reference: reference,
                                                        moving: Self.whiteBorder(reference, percent: 12))
        XCTAssertEqual(result.dx, 0, accuracy: 0.05)
        XCTAssertEqual(result.dy, 0, accuracy: 0.05)
        XCTAssertLessThan(result.confidence, 0.95)
    }

    func testUnrelatedImagesScoreFarLowerConfidenceThanShiftedCopies() {
        let reference = Self.render(width: 192, height: 144, seed: 7)
        let shifted = Self.render(width: 192, height: 144, shiftX: 4, shiftY: -2, seed: 7)
        let unrelated = Self.render(width: 192, height: 144, seed: 1234)
        let good = FrameAlignment.estimateTranslation(reference: reference, moving: shifted)
        let bad = FrameAlignment.estimateTranslation(reference: reference, moving: unrelated)
        XCTAssertGreaterThan(good.confidence, 0.8)
        XCTAssertLessThan(bad.confidence, 0.5)
        XCTAssertLessThan(bad.confidence, good.confidence - 0.3)
    }

    func testNoiseLowersConfidenceButKeepsTheShift() {
        let reference = Self.render(width: 192, height: 144)
        var noisy = Self.render(width: 192, height: 144, shiftX: 6, shiftY: 3)
        var state: UInt64 = 99
        for i in noisy.pixels.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            noisy.pixels[i] += Float(Double(state >> 11) / Double(UInt64(1) << 53) - 0.5) * 0.3
        }
        let clean = FrameAlignment.estimateTranslation(
            reference: reference, moving: Self.render(width: 192, height: 144, shiftX: 6, shiftY: 3))
        let result = FrameAlignment.estimateTranslation(reference: reference, moving: noisy)
        XCTAssertEqual(result.dx, 6, accuracy: 0.3)
        XCTAssertEqual(result.dy, 3, accuracy: 0.3)
        XCTAssertLessThan(result.confidence, clean.confidence)
        XCTAssertGreaterThan(result.confidence, 0)
    }

    func testMaxShiftLimitsTheResult() {
        let reference = Self.render(width: 192, height: 144)
        let moving = Self.render(width: 192, height: 144, shiftX: 10, shiftY: -9)
        let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving, maxShift: 4)
        XCTAssertLessThanOrEqual(abs(result.dx), 4)
        XCTAssertLessThanOrEqual(abs(result.dy), 4)
        // Still pointing the right way: the best match inside the limit is at its edge.
        XCTAssertGreaterThan(result.dx, 3)
        XCTAssertLessThan(result.dy, -3)
        // But the content really moved further, so the clamped shift must not be trusted.
        XCTAssertEqual(result.confidence, 0)
    }

    func testMotionPastMaxShiftGetsNoConfidence() {
        // 504x378 has a coarse level 8x smaller. With maxShift 3 the coarse window still spans +/-1 coarse pixel
        // (8 px), so it matches an 8 px motion perfectly; the clamped 3 px result must not inherit that score.
        let reference = Self.render(width: 504, height: 378, seed: 5)
        let cases: [(dx: Double, dy: Double, maxShift: Int)] = [(8, 0, 3), (23, 0, 20), (0, -12, 9), (49, 0, 48)]
        for item in cases {
            let moving = Self.render(width: 504, height: 378, shiftX: item.dx, shiftY: item.dy, seed: 5)
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving,
                                                            maxShift: item.maxShift)
            let label = "shift (\(item.dx), \(item.dy)) maxShift \(item.maxShift)"
            XCTAssertLessThanOrEqual(abs(result.dx), Double(item.maxShift), label)
            XCTAssertLessThanOrEqual(abs(result.dy), Double(item.maxShift), label)
            XCTAssertEqual(result.confidence, 0, label)
        }
    }

    func testShiftAtTheLimitKeepsItsConfidence() {
        let reference = Self.render(width: 504, height: 378, seed: 5)
        for (shift, limit) in [(16.0, 16), (48.0, 48), (20.0, 20)] {
            let moving = Self.render(width: 504, height: 378, shiftX: shift, shiftY: -shift, seed: 5)
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving, maxShift: limit)
            XCTAssertEqual(result.dx, shift, accuracy: 0.1, "maxShift \(limit)")
            XCTAssertEqual(result.dy, -shift, accuracy: 0.1, "maxShift \(limit)")
            XCTAssertGreaterThan(result.confidence, 0.5, "maxShift \(limit)")
        }
    }

    func testSubpixelShiftInTheLastPixelBeforeTheLimit() {
        // The parabola needs the cost one step past the limit; without it these come back as whole pixels.
        let reference = Self.render(width: 504, height: 378, seed: 5)
        let cases: [(dx: Double, dy: Double, maxShift: Int)] = [(15.7, 0, 16), (-15.6, 15.75, 16), (47.7, -47.6, 48)]
        for item in cases {
            let moving = Self.render(width: 504, height: 378, shiftX: item.dx, shiftY: item.dy, seed: 5)
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving,
                                                            maxShift: item.maxShift)
            let label = "shift (\(item.dx), \(item.dy)) maxShift \(item.maxShift)"
            XCTAssertEqual(result.dx, item.dx, accuracy: 0.15, label)
            XCTAssertEqual(result.dy, item.dy, accuracy: 0.15, label)
            XCTAssertGreaterThan(result.confidence, 0.5, label)
        }
    }

    func testZeroOrNegativeMaxShiftReturnsNoShift() {
        let reference = Self.render(width: 192, height: 144)
        let moving = Self.render(width: 192, height: 144, shiftX: 3, shiftY: 2)
        for limit in [0, -1, -48, Int.min] {
            let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving, maxShift: limit)
            // A single candidate is its own mean, so nothing stands out.
            XCTAssertEqual(result, .zero, "maxShift \(limit)")
        }
    }

    func testHugeMaxShiftStillFindsASmallShift() {
        let reference = Self.render(width: 192, height: 144)
        let moving = Self.render(width: 192, height: 144, shiftX: 6, shiftY: -4)
        let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving, maxShift: Int.max)
        XCTAssertEqual(result.dx, 6, accuracy: 0.1)
        XCTAssertEqual(result.dy, -4, accuracy: 0.1)
    }

    private struct LCG {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    /// A lit office tower at night on a 760x600 canvas: a window grid whose pitch grows 40% from left to right,
    /// as a facade in perspective does, 90% of the windows lit at random brightness, and six street lights in the
    /// bottom quarter. Windows repeat every 24 px or so, which is what can pull a coarse match a window away.
    private static func litFacade(seed: UInt64) -> [Float] {
        let width = 760
        let height = 600
        let pitch = 24.0
        var random = LCG(state: seed)
        var canvas = [Float](repeating: 0.04, count: width * height)
        var top = 10.0
        while top < Double(height - 10) {
            var left = 8.0
            while left < Double(width - 8) {
                let cell = pitch * (1 + 0.4 * left / Double(width))
                let level = random.next() < 0.9 ? 0.45 + 0.5 * random.next() : 0.08 + 0.05 * random.next()
                for y in Int(top)..<min(Int(top) + Int(pitch * 0.6), height) {
                    for x in Int(left)..<min(Int(left) + Int(cell * 0.55), width) {
                        canvas[y * width + x] = Float(level)
                    }
                }
                left += cell
            }
            top += pitch * 1.1
        }
        for _ in 0..<6 {
            let cx = Int(random.next() * Double(width))
            let cy = Int(Double(height) * (0.75 + 0.2 * random.next()))
            for y in max(cy - 6, 0)..<min(cy + 6, height) {
                for x in max(cx - 6, 0)..<min(cx + 6, width) {
                    canvas[y * width + x] = 1
                }
            }
        }
        return canvas
    }

    /// The 512x384 part of a 760-wide canvas from (left, top), with its own noise of up to +/-0.05.
    private static func crop(_ canvas: [Float], left: Int, top: Int, seed: UInt64) -> LumaImage {
        var random = LCG(state: seed)
        var image = LumaImage(width: 512, height: 384)
        for y in 0..<384 {
            for x in 0..<512 {
                let noise = Float(random.next() + random.next() - 1) * 0.05
                image[x, y] = min(max(canvas[(y + top) * 760 + x + left] + noise, 0), 1)
            }
        }
        return image
    }

    func testRepeatingWindowsDoNotPullTheMatchAWindowAway() {
        let facade = Self.litFacade(seed: 1)
        let reference = Self.crop(facade, left: 120, top: 100, seed: 2)
        // Moved 5 px right and 3 px up. Refining only the coarse winner ends near (-23, 23), a window away.
        let moving = Self.crop(facade, left: 115, top: 103, seed: 3)
        let result = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
        XCTAssertEqual(result.dx, 5, accuracy: 0.5)
        XCTAssertEqual(result.dy, -3, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.1)
    }

    func testSmallAndElongatedImagesStillAlign() {
        let small = Self.render(width: 64, height: 48)
        let smallMoved = Self.render(width: 64, height: 48, shiftX: 5, shiftY: -3)
        let smallResult = FrameAlignment.estimateTranslation(reference: small, moving: smallMoved)
        XCTAssertEqual(smallResult.dx, 5, accuracy: 0.1)
        XCTAssertEqual(smallResult.dy, -3, accuracy: 0.1)

        let strip = Self.render(width: 320, height: 40)
        let stripMoved = Self.render(width: 320, height: 40, shiftX: 9, shiftY: 2)
        let stripResult = FrameAlignment.estimateTranslation(reference: strip, moving: stripMoved)
        XCTAssertEqual(stripResult.dx, 9, accuracy: 0.1)
        XCTAssertEqual(stripResult.dy, 2, accuracy: 0.1)
    }

    // MARK: - estimateTranslation: invalid input

    func testSizeMismatchReturnsZero() {
        let reference = Self.render(width: 192, height: 144)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: reference, moving: Self.render(width: 144, height: 192)), .zero)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: reference, moving: Self.render(width: 191, height: 144)), .zero)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: reference, moving: Self.render(width: 192, height: 143)), .zero)
    }

    func testFlatImagesReturnZero() {
        let textured = Self.render(width: 96, height: 72)
        let gray = LumaImage(width: 96, height: 72, fill: 0.3)
        let black = LumaImage(width: 96, height: 72)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: gray, moving: gray), .zero)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: black, moving: gray), .zero)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: textured, moving: gray), .zero)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: gray, moving: textured), .zero)
        // A single hot pixel is not enough texture to align on.
        var nearlyBlack = black
        nearlyBlack[40, 30] = 0.004
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: nearlyBlack, moving: nearlyBlack), .zero)
    }

    func testInvalidPixelValuesReturnZero() {
        let textured = Self.render(width: 96, height: 72)
        var broken = textured
        broken[10, 10] = .nan
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: textured, moving: broken), .zero)
        broken[10, 10] = .infinity
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: broken, moving: textured), .zero)
    }

    func testTinyAndEmptyImagesReturnZero() {
        for (width, height) in [(0, 0), (1, 1), (7, 7), (8, 7), (7, 40), (3, 2)] {
            let a = Self.render(width: width, height: height)
            let b = Self.render(width: width, height: height, shiftX: 1)
            XCTAssertEqual(FrameAlignment.estimateTranslation(reference: a, moving: b), .zero, "\(width)x\(height)")
        }
    }

    func testSmallestAlignableSizeStaysInRange() {
        let a = Self.render(width: 8, height: 8)
        let b = Self.render(width: 8, height: 8, shiftX: 1, shiftY: 1)
        let result = FrameAlignment.estimateTranslation(reference: a, moving: b, maxShift: 3)
        XCTAssertLessThanOrEqual(abs(result.dx), 3)
        XCTAssertLessThanOrEqual(abs(result.dy), 3)
        XCTAssertTrue((0...1).contains(result.confidence))
    }

    func testMismatchedPixelCountReturnsZero() {
        let reference = Self.render(width: 32, height: 32)
        var shortened = Self.render(width: 32, height: 32, shiftX: 2)
        shortened.pixels.removeLast()
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: reference, moving: shortened), .zero)
        XCTAssertEqual(FrameAlignment.estimateTranslation(reference: shortened, moving: reference), .zero)
    }

    // MARK: - estimateTranslation: speed

    func testPreviewSizedFramesAlignQuickly() {
        let reference = Self.render(width: 504, height: 378, seed: 11)
        let moving = Self.render(width: 504, height: 378, shiftX: 9, shiftY: -6, seed: 11)
        let warmUp = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
        XCTAssertEqual(warmUp.dx, 9, accuracy: 0.1)
        XCTAssertEqual(warmUp.dy, -6, accuracy: 0.1)
        let runs = 5
        let start = Date()
        for _ in 0..<runs {
            _ = FrameAlignment.estimateTranslation(reference: reference, moving: moving)
        }
        let perRun = Date().timeIntervalSince(start) / Double(runs)
        // The target is ~15 ms in -O and a Debug build measured ~25 ms. The loose bound keeps slow simulators
        // and coverage builds green while still failing on a search that left the coarse level, which costs seconds.
        XCTAssertLessThan(perRun, 0.25, "\(perRun * 1000) ms per 504x378 alignment")
    }

    // MARK: - Pyramid and sub-pixel helpers

    func testPyramidHalvesUntilTheLongSideFitsTheCoarseSize() {
        func sizes(_ width: Int, _ height: Int) -> [[Int]] {
            FrameAlignment.pyramid(LumaImage(width: width, height: height)).map { [$0.width, $0.height] }
        }
        XCTAssertEqual(sizes(504, 378), [[504, 378], [252, 189], [126, 94], [63, 47]])
        XCTAssertEqual(sizes(4032, 3024), [[4032, 3024], [2016, 1512], [1008, 756], [504, 378], [252, 189],
                                           [126, 94], [63, 47]])
        XCTAssertEqual(sizes(65, 10), [[65, 10], [32, 5]])
        // At least one level, even when the input already fits.
        XCTAssertEqual(sizes(64, 48), [[64, 48], [32, 24]])
        XCTAssertEqual(sizes(8, 8), [[8, 8], [4, 4]])
        // Halving stops before a side gets too short to search, even if the long side is still large.
        XCTAssertEqual(sizes(1000, 10), [[1000, 10], [500, 5]])
    }

    func testHalvedAveragesTwoByTwoBlocksAndDropsOddEdges() {
        let even = LumaImage(width: 4, height: 2, pixels: [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(FrameAlignment.halved(even), LumaImage(width: 2, height: 1, pixels: [2.5, 4.5]))
        let odd = LumaImage(width: 3, height: 3, pixels: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(FrameAlignment.halved(odd), LumaImage(width: 1, height: 1, pixels: [3]))
    }

    func testParabolicOffset() {
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 1, center: 0, plus: 1), 0)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 1.5, center: 0.5, plus: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 0.5, center: 0.5, plus: 1.5), -0.5, accuracy: 1e-12)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 3, center: 1, plus: 2), 1.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 2, center: 1, plus: 3), -1.0 / 6.0, accuracy: 1e-12)
        // No minimum to fit: flat, downward-opening, or a missing neighbour.
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 1, center: 1, plus: 1), 0)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 0, center: 1, plus: 0), 0)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: .infinity, center: 0, plus: 1), 0)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 1, center: 0, plus: .nan), 0)
        // A vertex further out is clamped to half a pixel.
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 1, center: 2, plus: 5), -0.5)
        XCTAssertEqual(FrameAlignment.parabolicOffset(minus: 5, center: 2, plus: 1), 0.5)
    }

    // MARK: - sharpness

    func testSharpnessOfImagesSmallerThanThreeByThreeIsZero() {
        for (width, height) in [(0, 0), (2, 2), (2, 5), (5, 2), (1, 9)] {
            var image = LumaImage(width: width, height: height)
            for i in image.pixels.indices {
                image.pixels[i] = Float(i % 2)
            }
            XCTAssertEqual(FrameAlignment.sharpness(image), 0, "\(width)x\(height)")
        }
    }

    func testSharpnessOfSingleInteriorPixelIsZero() {
        // 3x3 has one interior Laplacian value, and one value has no variance.
        let image = LumaImage(width: 3, height: 3, pixels: [0, 1, 0, 1, 0, 1, 0, 1, 0])
        XCTAssertEqual(FrameAlignment.sharpness(image), 0)
    }

    func testSharpnessOfUniformAndLinearImagesIsZero() {
        XCTAssertEqual(FrameAlignment.sharpness(LumaImage(width: 10, height: 8, fill: 0.3)), 0, accuracy: 1e-12)
        var ramp = LumaImage(width: 10, height: 8)
        for y in 0..<8 {
            for x in 0..<10 {
                ramp[x, y] = Float(x) * 0.05 + Float(y) * 0.02
            }
        }
        XCTAssertEqual(FrameAlignment.sharpness(ramp), 0, accuracy: 1e-10)
    }

    func testSharpnessMatchesHandComputedLaplacianVariance() {
        // One bright pixel in the middle of 5x5: interior Laplacian values are -4, four 1s and four 0s.
        // Mean 0, mean square 20/9.
        var dot = LumaImage(width: 5, height: 5)
        dot[2, 2] = 1
        XCTAssertEqual(FrameAlignment.sharpness(dot), 20.0 / 9.0, accuracy: 1e-9)

        // 4x4 checkerboard: interior values 4, -4, -4, 4, so the variance is 16.
        var checker = LumaImage(width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                checker[x, y] = Float((x + y) % 2)
            }
        }
        XCTAssertEqual(FrameAlignment.sharpness(checker), 16, accuracy: 1e-9)
    }

    func testSharpnessUsesInteriorPixelsOnly() {
        // Corner pixels feed no interior Laplacian, so they could only matter if border pixels were sampled.
        var dot = LumaImage(width: 5, height: 5)
        dot[2, 2] = 1
        var withCorners = dot
        withCorners[0, 0] = 1
        withCorners[4, 4] = 1
        withCorners[0, 4] = 1
        withCorners[4, 0] = 1
        XCTAssertEqual(FrameAlignment.sharpness(withCorners), FrameAlignment.sharpness(dot), accuracy: 1e-12)
    }

    func testSharpnessDropsWhenTheImageIsBlurred() {
        let sharp = Self.render(width: 120, height: 90)
        let soft = Self.boxBlurred(sharp)
        let softer = Self.boxBlurred(soft)
        let s0 = FrameAlignment.sharpness(sharp)
        let s1 = FrameAlignment.sharpness(soft)
        let s2 = FrameAlignment.sharpness(softer)
        XCTAssertGreaterThan(s0, 0)
        XCTAssertLessThan(s1, s0 * 0.5)
        XCTAssertLessThan(s2, s1)
    }

    func testSharpnessScalesWithContrastSquared() {
        let image = Self.render(width: 60, height: 40)
        let base = FrameAlignment.sharpness(image)
        XCTAssertEqual(FrameAlignment.sharpness(Self.scaled(image, by: 2)), base * 4, accuracy: base * 1e-4)
        XCTAssertEqual(FrameAlignment.sharpness(Self.scaled(image, by: 0.5)), base * 0.25, accuracy: base * 1e-4)
    }

    func testSharpnessIgnoresInconsistentPixelCount() {
        var image = Self.render(width: 10, height: 10)
        image.pixels.removeLast()
        XCTAssertEqual(FrameAlignment.sharpness(image), 0)
    }

    // MARK: - framesToKeep

    func testFramesToKeepEmptyAndSingle() {
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: []), [])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [0]), [0])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [42]), [0])
    }

    func testFramesToKeepOddCountUsesTheMiddleValue() {
        // Sorted 1, 2, 8, 9, 10: median 8, threshold 4.8.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [10, 9, 2, 8, 1]), [0, 1, 3])
    }

    func testFramesToKeepEvenCountAveragesTheMiddleValues() {
        // Median (3 + 5) / 2 = 4, threshold 2.4: only the 1 goes.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [7, 1, 5, 3]), [0, 2, 3])
        // Median (2 + 4) / 2 = 3 with fraction 1: 3 itself is absent, so 2 goes and 4 stays.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [4, 2], keepFraction: 1), [0])
    }

    func testFramesToKeepKeepsValuesEqualToTheThreshold() {
        // Median 4, fraction 0.5: threshold exactly 2, and 2 >= 2.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [2, 4, 4, 8, 1], keepFraction: 0.5), [0, 1, 2, 3])
    }

    func testFramesToKeepAlwaysKeepsTheSharpest() {
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [3, 9, 5], keepFraction: 10), [1])
        // Ties for sharpest: the first one is the guaranteed frame.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [7, 7, 1], keepFraction: 5), [0])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [1, 2, 3], keepFraction: .infinity), [2])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [1, 2, 3], keepFraction: .nan), [2])
    }

    func testFramesToKeepWithZeroOrNegativeFractionKeepsEverything() {
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [5, 0, 3], keepFraction: 0), [0, 1, 2])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [5, 0, 3], keepFraction: -1), [0, 1, 2])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [0, 0, 0, 0]), [0, 1, 2, 3])
    }

    func testFramesToKeepDefaultFraction() {
        // Median 10, default fraction 0.6: threshold 6.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [10, 5.9, 6, 12, 20]), [0, 2, 3, 4])
    }

    func testFramesToKeepNeverKeepsNaNScores() {
        // NaN is left out of the median too: median of 4 and 5 is 4.5, threshold 2.7.
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [.nan, 5, 4]), [1, 2])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [.nan, .nan]), [0])
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [.nan, 0, 0]), [1, 2])
    }

    func testFramesToKeepHandlesInfiniteScores() {
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: [.infinity, 1, 2]), [0, 2])
    }

    func testFramesToKeepOnRealFrames() {
        let sharp = Self.render(width: 80, height: 60)
        let soft = Self.boxBlurred(Self.boxBlurred(sharp))
        let scores = [sharp, soft, sharp, sharp, soft].map(FrameAlignment.sharpness)
        XCTAssertEqual(FrameAlignment.framesToKeep(sharpness: scores), [0, 2, 3])
    }
}
