import XCTest
@testable import CameraCore

final class OverlaysTests: XCTestCase {
    // MARK: - RGBA8

    func testRGBA8DefaultsToOpaque() {
        let color = RGBA8(r: 1, g: 2, b: 3)
        XCTAssertEqual(color.a, 255)
        XCTAssertEqual(RGBA8(r: 1, g: 2, b: 3, a: 4).a, 4)
    }

    func testNamedColors() {
        XCTAssertEqual(RGBA8.clear, RGBA8(r: 0, g: 0, b: 0, a: 0))
        XCTAssertEqual(RGBA8.black, RGBA8(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(RGBA8.white, RGBA8(r: 255, g: 255, b: 255, a: 255))
        XCTAssertEqual(RGBA8.red, RGBA8(r: 255, g: 0, b: 0))
        XCTAssertEqual(RGBA8.yellow, RGBA8(r: 255, g: 255, b: 0))
        XCTAssertEqual(RGBA8.green, RGBA8(r: 0, g: 255, b: 0))
        XCTAssertEqual(RGBA8.blue, RGBA8(r: 0, g: 0, b: 255))
        XCTAssertEqual(RGBA8.magenta, RGBA8(r: 255, g: 0, b: 255))
        XCTAssertEqual(RGBA8.cyan, RGBA8(r: 0, g: 255, b: 255))
        let named: [RGBA8] = [.clear, .black, .white, .red, .yellow, .green, .blue, .magenta, .cyan, .purple, .pink]
        XCTAssertEqual(Set(named).count, named.count, "every named color is distinct")
        for color in named where color != .clear {
            XCTAssertEqual(color.a, 255)
        }
    }

    func testPremultipliedScalesAndRounds() {
        XCTAssertEqual(RGBA8.white.premultiplied(alpha: 200), RGBA8(r: 200, g: 200, b: 200, a: 200))
        XCTAssertEqual(RGBA8.red.premultiplied(alpha: 128), RGBA8(r: 128, g: 0, b: 0, a: 128))
        XCTAssertEqual(RGBA8.white.premultiplied(alpha: 0), .clear)
        XCTAssertEqual(RGBA8(r: 10, g: 20, b: 30).premultiplied(alpha: 255), RGBA8(r: 10, g: 20, b: 30))
        // 128 * 200 / 255 = 100.39 rounds down; 1 * 128 / 255 = 0.502 rounds up; 3 * 85 / 255 = 1 exactly.
        XCTAssertEqual(RGBA8(r: 128, g: 1, b: 3).premultiplied(alpha: 200).r, 100)
        XCTAssertEqual(RGBA8(r: 128, g: 1, b: 3).premultiplied(alpha: 128).g, 1)
        XCTAssertEqual(RGBA8(r: 128, g: 1, b: 3).premultiplied(alpha: 85).b, 1)
    }

    func testPremultipliedReplacesTheExistingAlpha() {
        let translucent = RGBA8(r: 255, g: 255, b: 255, a: 0)
        XCTAssertEqual(translucent.premultiplied(alpha: 255), .white)
        XCTAssertEqual(RGBA8(r: 100, g: 50, b: 0, a: 10).premultiplied(alpha: 51), RGBA8(r: 20, g: 10, b: 0, a: 51))
    }

    func testPremultipliedMatchesRoundedFormulaForEveryPair() {
        for value in 0...255 {
            for alpha in 0...255 {
                let expected = UInt8((Double(value) * Double(alpha) / 255).rounded())
                let color = RGBA8(r: UInt8(value), g: 0, b: UInt8(value)).premultiplied(alpha: UInt8(alpha))
                if color.r != expected || color.b != expected || color.a != UInt8(alpha) || color.g != 0 {
                    XCTFail("value \(value) alpha \(alpha): got \(color), expected \(expected)")
                    return
                }
            }
        }
    }

    func testRGBA8CodableRoundTrip() throws {
        let colors: [RGBA8] = [.clear, .pink, RGBA8(r: 1, g: 2, b: 3, a: 4)]
        let data = try JSONEncoder().encode(colors)
        XCTAssertEqual(try JSONDecoder().decode([RGBA8].self, from: data), colors)
    }

    // MARK: - RGBABitmap

    func testNewBitmapIsTransparentAndSized() {
        let bitmap = RGBABitmap(width: 3, height: 2)
        XCTAssertEqual(bitmap.width, 3)
        XCTAssertEqual(bitmap.height, 2)
        XCTAssertEqual(bitmap.pixels, [UInt8](repeating: 0, count: 24))
        XCTAssertTrue(bitmap.isFullyTransparent)
    }

    func testNegativeOrHugeSizesGiveEmptyBitmaps() {
        for (width, height) in [(-1, 5), (5, -1), (0, 0), (Int.max, 2), (Int.max / 4, 2)] {
            let bitmap = RGBABitmap(width: width, height: height)
            XCTAssertTrue(bitmap.pixels.isEmpty, "\(width) x \(height)")
            XCTAssertTrue(bitmap.isFullyTransparent)
            XCTAssertEqual(bitmap[0, 0], .clear)
        }
        XCTAssertEqual(RGBABitmap(width: -1, height: 5).height, 5)
    }

    func testSubscriptReadsAndWritesRowMajorRGBA() {
        var bitmap = RGBABitmap(width: 3, height: 2)
        let color = RGBA8(r: 1, g: 2, b: 3, a: 4)
        bitmap[2, 1] = color
        XCTAssertEqual(bitmap[2, 1], color)
        let offset = (1 * 3 + 2) * 4
        XCTAssertEqual(Array(bitmap.pixels[offset..<(offset + 4)]), [1, 2, 3, 4])
        XCTAssertEqual(bitmap[1, 1], .clear)
        XCTAssertFalse(bitmap.isFullyTransparent)
        bitmap[2, 1] = .clear
        XCTAssertTrue(bitmap.isFullyTransparent)
    }

    func testOutOfRangeSubscriptReadsClearAndIgnoresWrites() {
        var bitmap = RGBABitmap(width: 2, height: 2)
        for (x, y) in [(-1, 0), (0, -1), (2, 0), (0, 2), (Int.min, Int.max)] {
            bitmap[x, y] = .white
            XCTAssertEqual(bitmap[x, y], .clear, "(\(x), \(y))")
        }
        XCTAssertEqual(bitmap, RGBABitmap(width: 2, height: 2))
    }

    func testSubscriptSurvivesAPixelArrayThatNoLongerMatches() {
        var bitmap = RGBABitmap(width: 2, height: 2)
        bitmap.pixels = [1, 2, 3]
        XCTAssertEqual(bitmap[1, 1], .clear)
        bitmap[1, 1] = .white
        XCTAssertEqual(bitmap.pixels, [1, 2, 3])
        XCTAssertEqual(bitmap.rotated(quarterTurns: 1).pixels.count, 16)
        XCTAssertEqual(bitmap.mirroredHorizontally().pixels.count, 16)
    }

    func testAlphaDecidesTransparency() {
        var bitmap = RGBABitmap(width: 2, height: 1)
        bitmap[0, 0] = RGBA8(r: 0, g: 0, b: 0, a: 1)
        XCTAssertFalse(bitmap.isFullyTransparent)
        bitmap[0, 0] = .clear
        XCTAssertTrue(bitmap.isFullyTransparent)
        XCTAssertTrue(RGBABitmap(width: 0, height: 0).isFullyTransparent)
    }

    func testOneClockwiseTurnFollowsTheDocumentedMapping() {
        let bitmap = numbered(width: 3, height: 2)
        let turned = bitmap.rotated(quarterTurns: 1)
        XCTAssertEqual(turned.width, 2)
        XCTAssertEqual(turned.height, 3)
        for y in 0..<3 {
            for x in 0..<2 {
                XCTAssertEqual(turned[x, y], bitmap[y, 2 - 1 - x], "(\(x), \(y))")
            }
        }
        // Clockwise: the top-left corner ends up top-right, the bottom-left ends up top-left.
        XCTAssertEqual(turned[1, 0], bitmap[0, 0])
        XCTAssertEqual(turned[0, 0], bitmap[0, 1])
    }

    func testTwoAndThreeTurns() {
        let bitmap = numbered(width: 3, height: 2)
        let half = bitmap.rotated(quarterTurns: 2)
        XCTAssertEqual(half.width, 3)
        XCTAssertEqual(half.height, 2)
        for y in 0..<2 {
            for x in 0..<3 {
                XCTAssertEqual(half[x, y], bitmap[3 - 1 - x, 2 - 1 - y])
            }
        }
        let three = bitmap.rotated(quarterTurns: 3)
        XCTAssertEqual(three.width, 2)
        XCTAssertEqual(three.height, 3)
        for y in 0..<3 {
            for x in 0..<2 {
                XCTAssertEqual(three[x, y], bitmap[3 - 1 - y, x])
            }
        }
        XCTAssertEqual(bitmap.rotated(quarterTurns: 1).rotated(quarterTurns: 1), half)
        XCTAssertEqual(half.rotated(quarterTurns: 1), three)
    }

    func testTurnsWrapModuloFourIncludingNegatives() {
        let bitmap = numbered(width: 4, height: 3)
        XCTAssertEqual(bitmap.rotated(quarterTurns: 0), bitmap)
        XCTAssertEqual(bitmap.rotated(quarterTurns: 4), bitmap)
        XCTAssertEqual(bitmap.rotated(quarterTurns: -4), bitmap)
        XCTAssertEqual(bitmap.rotated(quarterTurns: 5), bitmap.rotated(quarterTurns: 1))
        XCTAssertEqual(bitmap.rotated(quarterTurns: -1), bitmap.rotated(quarterTurns: 3))
        XCTAssertEqual(bitmap.rotated(quarterTurns: -2), bitmap.rotated(quarterTurns: 2))
        XCTAssertEqual(bitmap.rotated(quarterTurns: -7), bitmap.rotated(quarterTurns: 1))
        XCTAssertEqual(bitmap.rotated(quarterTurns: Int.min), bitmap)
        XCTAssertEqual(bitmap.rotated(quarterTurns: Int.max), bitmap.rotated(quarterTurns: 3))
        var full = bitmap
        for _ in 0..<4 { full = full.rotated(quarterTurns: 1) }
        XCTAssertEqual(full, bitmap)
        XCTAssertEqual(bitmap.rotated(quarterTurns: 1).rotated(quarterTurns: -1), bitmap)
    }

    func testRotatingEmptyBitmapsSwapsTheSize() {
        let empty = RGBABitmap(width: 0, height: 5)
        let turned = empty.rotated(quarterTurns: 1)
        XCTAssertEqual(turned.width, 5)
        XCTAssertEqual(turned.height, 0)
        XCTAssertTrue(turned.pixels.isEmpty)
    }

    func testMirrorFlipsColumns() {
        let bitmap = numbered(width: 3, height: 2)
        let mirrored = bitmap.mirroredHorizontally()
        XCTAssertEqual(mirrored.width, 3)
        XCTAssertEqual(mirrored.height, 2)
        for y in 0..<2 {
            for x in 0..<3 {
                XCTAssertEqual(mirrored[x, y], bitmap[3 - 1 - x, y])
            }
        }
        XCTAssertEqual(mirrored.mirroredHorizontally(), bitmap)
        // Mirroring then turning twice is a vertical flip.
        let flipped = mirrored.rotated(quarterTurns: 2)
        XCTAssertEqual(flipped[0, 0], bitmap[0, 1])
        let single = RGBABitmap(width: 1, height: 1)
        XCTAssertEqual(single.mirroredHorizontally(), single)
    }

    // MARK: - PeakingColor

    func testPeakingColors() {
        XCTAssertEqual(PeakingColor.allCases, [.red, .yellow, .green, .blue, .white])
        XCTAssertEqual(PeakingColor.allCases.map(\.title), ["Red", "Yellow", "Green", "Blue", "White"])
        XCTAssertEqual(PeakingColor.allCases.map(\.rgba), [.red, .yellow, .green, .blue, .white])
        for color in PeakingColor.allCases {
            XCTAssertEqual(color.id, color.rawValue)
            XCTAssertEqual(PeakingColor(rawValue: color.rawValue), color)
        }
    }

    func testPeakingColorCodableUsesRawValues() throws {
        let data = try JSONEncoder().encode([PeakingColor.yellow, .white])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"yellow\",\"white\"]")
        XCTAssertEqual(try JSONDecoder().decode([PeakingColor].self, from: data), [.yellow, .white])
    }

    // MARK: - OverlayOptions

    func testOptionDefaults() {
        let options = OverlayOptions()
        XCTAssertNil(options.zebraThreshold)
        XCTAssertEqual(options.stripePeriod, 6)
        XCTAssertEqual(options.stripePhase, 0)
        XCTAssertNil(options.peakingThreshold)
        XCTAssertEqual(options.peakingColor, .red)
        XCTAssertFalse(options.falseColor)
        XCTAssertTrue(options.isEmpty)
    }

    func testStripePeriodIsClampedToTwo() {
        XCTAssertEqual(OverlayOptions(stripePeriod: 1).stripePeriod, 2)
        XCTAssertEqual(OverlayOptions(stripePeriod: 0).stripePeriod, 2)
        XCTAssertEqual(OverlayOptions(stripePeriod: -9).stripePeriod, 2)
        XCTAssertEqual(OverlayOptions(stripePeriod: 2).stripePeriod, 2)
        XCTAssertEqual(OverlayOptions(stripePeriod: 7).stripePeriod, 7)
    }

    func testAnyEnabledLayerMakesOptionsNonEmpty() {
        XCTAssertFalse(OverlayOptions(zebraThreshold: 0.9).isEmpty)
        XCTAssertFalse(OverlayOptions(peakingThreshold: 0.2).isEmpty)
        XCTAssertFalse(OverlayOptions(falseColor: true).isEmpty)
        XCTAssertTrue(OverlayOptions(stripePeriod: 10, stripePhase: 3, peakingColor: .blue).isEmpty)
    }

    func testOptionsAreHashable() {
        let a = OverlayOptions(zebraThreshold: 0.9, peakingThreshold: 0.2)
        var b = a
        XCTAssertEqual(a, b)
        b.stripePhase = 1
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, a, b]).count, 2)
    }

    func testPeakingThresholdFromSensitivity() {
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: 0), 0.45)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: 1), 0.08)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: 0.5), 0.265, accuracy: 1e-12)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: 0.25), 0.3575, accuracy: 1e-12)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: -3), 0.45)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: 7), 0.08)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: .infinity), 0.08)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: -.infinity), 0.45)
        XCTAssertEqual(OverlayOptions.peakingThreshold(sensitivity: .nan), 0.45)
        var previous = Double.infinity
        for step in 0...20 {
            let threshold = OverlayOptions.peakingThreshold(sensitivity: Double(step) / 20)
            XCTAssertLessThan(threshold, previous, "more sensitivity means a lower threshold")
            previous = threshold
        }
    }

    // MARK: - False color

    func testFalseColorBands() {
        let cases: [(Double, RGBA8?)] = [
            (-1, .purple), (0, .purple), (0.0249, .purple),
            (0.025, .blue), (0.0999, .blue),
            (0.10, nil), (0.2, nil), (0.3799, nil),
            (0.38, .green), (0.42, .green), (0.4599, .green),
            (0.46, nil), (0.6999, nil),
            (0.70, .pink), (0.7699, .pink),
            (0.77, nil), (0.9299, nil),
            (0.93, .yellow), (0.9899, .yellow),
            (0.99, .red), (1, .red), (3, .red), (.infinity, .red),
            (-.infinity, .purple), (.nan, nil),
        ]
        for (luma, color) in cases {
            XCTAssertEqual(OverlayRenderer.falseColor(luma: luma), color, "luma \(luma)")
        }
    }

    // MARK: - Sobel

    func testSobelIsZeroOnFlatImages() {
        let image = LumaImage(width: 5, height: 4, fill: 0.7)
        for y in 0..<4 {
            for x in 0..<5 {
                XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: x, y: y), 0)
            }
        }
    }

    func testSobelVerticalAndHorizontalStepEdges() {
        // Columns 0...1 black, 2...3 white: at x = 1 and x = 2, gx = 4 so the magnitude is exactly 1.
        let vertical = LumaImage(width: 4, height: 3, pixels: [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1])
        for y in 0..<3 {
            XCTAssertEqual(OverlayRenderer.sobelMagnitude(vertical, x: 0, y: y), 0)
            XCTAssertEqual(OverlayRenderer.sobelMagnitude(vertical, x: 1, y: y), 1)
            XCTAssertEqual(OverlayRenderer.sobelMagnitude(vertical, x: 2, y: y), 1)
            XCTAssertEqual(OverlayRenderer.sobelMagnitude(vertical, x: 3, y: y), 0)
        }
        let horizontal = LumaImage(width: 3, height: 4, pixels: [0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(horizontal, x: 1, y: 1), 0.5, accuracy: 1e-7)
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(horizontal, x: 0, y: 2), 0.5, accuracy: 1e-7)
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(horizontal, x: 2, y: 3), 0)
    }

    func testSobelHandComputedValue() {
        // 0.1 0.2 0.3 / 0.4 0.5 0.6 / 0.7 0.8 0.9: gx = 0.8, gy = 2.4, magnitude = sqrt(6.4) / 4.
        let image = LumaImage(width: 3, height: 3, pixels: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: 1, y: 1), 6.4.squareRoot() / 4, accuracy: 1e-6)
    }

    func testSobelDiagonalEdges() {
        // Exact equality: the gradients are whole numbers, and a Double result has no Float rounding left in it.
        // Only the bottom-right sample of (0, 0) is white once clamped: gx = gy = 1.
        let corner = LumaImage(width: 2, height: 2, pixels: [0, 0, 0, 1])
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(corner, x: 0, y: 0), 2.0.squareRoot() / 4)
        // White L around the bottom-right: gx = gy = 3.
        let diagonal = LumaImage(width: 3, height: 3, pixels: [0, 0, 1, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(diagonal, x: 1, y: 1), 18.0.squareRoot() / 4)
        // The strongest response for values in 0...1 (gx = 4, gy = 2) stays below the sqrt(2) bound.
        let strongest = LumaImage(width: 3, height: 3, pixels: [0, 0, 1, 0, 0.5, 1, 0, 1, 1])
        let magnitude = OverlayRenderer.sobelMagnitude(strongest, x: 1, y: 1)
        XCTAssertEqual(magnitude, 20.0.squareRoot() / 4)
        XCTAssertLessThan(magnitude, 2.0.squareRoot())
    }

    func testSobelMatchesADoubleReference() {
        // The result is a Double, so it must carry Double precision: a Float computation misses by up to ~1e-7.
        var rng = SeededGenerator(seed: 34)
        for (width, height) in [(13, 9), (1, 1), (1, 4), (4, 1), (2, 3)] {
            let pixels = (0..<(width * height)).map { _ in Float.random(in: 0...1, using: &rng) }
            let image = LumaImage(width: width, height: height, pixels: pixels)
            for y in -1...height {
                for x in -1...width {
                    func sample(_ dx: Int, _ dy: Int) -> Double {
                        let sx = min(max(x + dx, 0), width - 1)
                        let sy = min(max(y + dy, 0), height - 1)
                        return Double(pixels[sy * width + sx])
                    }
                    var gx = 0.0
                    var gy = 0.0
                    for d in -1...1 {
                        let weight = d == 0 ? 2.0 : 1.0
                        gx += weight * (sample(1, d) - sample(-1, d))
                        gy += weight * (sample(d, 1) - sample(d, -1))
                    }
                    let expected = (gx * gx + gy * gy).squareRoot() / 4
                    XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: x, y: y), expected, accuracy: 1e-12,
                                   "\(width)x\(height) at (\(x), \(y))")
                }
            }
        }
    }

    func testSobelClampsSamplesAtTheBorder() {
        // At x = 0 the left column repeats column 0, so the gradient only sees column 1.
        let image = LumaImage(width: 2, height: 1, pixels: [0, 1])
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: 0, y: 0), 1)
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: 1, y: 0), 1)
        // Far outside, every sample clamps onto the same edge pixel.
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: -50, y: 0), 0)
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: Int.max, y: Int.min), 0)
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(image, x: -1, y: 0), 0)
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(LumaImage(width: 1, height: 1, fill: 0.3), x: 0, y: 0), 0)
    }

    func testSobelOnEmptyOrBrokenImagesIsZero() {
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(LumaImage(width: 0, height: 0), x: 0, y: 0), 0)
        var broken = LumaImage(width: 3, height: 3, fill: 1)
        broken.pixels = [1]
        XCTAssertEqual(OverlayRenderer.sobelMagnitude(broken, x: 1, y: 1), 0)
    }

    // MARK: - Render

    func testRenderMatchesInputSizeAndIsEmptyWithoutLayers() {
        let image = LumaImage(width: 7, height: 5, fill: 1)
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions())
        XCTAssertEqual(bitmap.width, 7)
        XCTAssertEqual(bitmap.height, 5)
        XCTAssertEqual(bitmap.pixels.count, 7 * 5 * 4)
        XCTAssertTrue(bitmap.isFullyTransparent)
    }

    func testRenderEmptyOrBrokenImage() {
        let empty = OverlayRenderer.render(LumaImage(width: 0, height: 3), options: OverlayOptions(falseColor: true))
        XCTAssertEqual(empty.width, 0)
        XCTAssertEqual(empty.height, 3)
        XCTAssertTrue(empty.pixels.isEmpty)
        var broken = LumaImage(width: 4, height: 4, fill: 1)
        broken.pixels = [1, 1]
        let bitmap = OverlayRenderer.render(broken, options: OverlayOptions(zebraThreshold: 0.5, peakingThreshold: 0.1, falseColor: true))
        XCTAssertEqual(bitmap.width, 4)
        XCTAssertEqual(bitmap.height, 4)
        XCTAssertTrue(bitmap.isFullyTransparent)
    }

    func testZebraStripesFollowTheDiagonalPattern() {
        let image = LumaImage(width: 9, height: 7, fill: 1)
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0.9))
        let stripe = RGBA8(r: 230, g: 230, b: 230, a: 230)
        for y in 0..<7 {
            for x in 0..<9 {
                let expected = (x + y) % 6 < 3 ? stripe : RGBA8.clear
                XCTAssertEqual(bitmap[x, y], expected, "(\(x), \(y))")
            }
        }
    }

    func testZebraOnlyMarksPixelsAtOrAboveTheThreshold() {
        // Stripe pixels everywhere for period 2 at even x + y; values below 0.5 stay clear.
        let image = LumaImage(width: 4, height: 1, pixels: [0.4999, 0.5, 0.5, 1])
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0.5, stripePeriod: 2))
        XCTAssertEqual(bitmap[0, 0], .clear, "below the threshold")
        XCTAssertEqual(bitmap[1, 0], .clear, "off stripe")
        XCTAssertEqual(bitmap[2, 0].a, 230, "equal to the threshold counts")
        XCTAssertEqual(bitmap[3, 0], .clear, "off stripe")
    }

    func testStripePhaseShiftsTheStripes() {
        let image = LumaImage(width: 12, height: 3, fill: 1)
        for phase in [-13, -7, -1, 0, 1, 5, 6, 11, Int.max, Int.min] {
            let options = OverlayOptions(zebraThreshold: 0, stripePeriod: 6, stripePhase: phase)
            let bitmap = OverlayRenderer.render(image, options: options)
            let reduced = ((phase % 6) + 6) % 6
            for y in 0..<3 {
                for x in 0..<12 {
                    let lit = (x + y + reduced) % 6 < 3
                    XCTAssertEqual(bitmap[x, y].a, lit ? 230 : 0, "phase \(phase) at (\(x), \(y))")
                }
            }
        }
        let shifted = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0, stripePhase: 1))
        let base = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0))
        XCTAssertEqual(shifted[0, 0], base[1, 0])
    }

    func testOddPeriodsLightTheLowerHalf() {
        // period 5: (x + y) mod 5 < 2 is lit, so 2 of every 5 pixels.
        let image = LumaImage(width: 10, height: 1, fill: 1)
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0.5, stripePeriod: 5))
        let lit = (0..<10).map { bitmap[$0, 0].a != 0 }
        XCTAssertEqual(lit, [true, true, false, false, false, true, true, false, false, false])
    }

    func testHugeStripePeriodsFollowTheFormulaWithoutOverflow() {
        // stripePeriod has no upper bound, and reducing the phase used to trap for periods near Int.max.
        let image = LumaImage(width: 5, height: 4, fill: 1)
        let periods = [2, 3, 6, Int.max / 2, Int.max / 2 + 1, Int.max - 1, Int.max]
        let phases = [Int.min, Int.min + 1, -7, -1, 0, 1, 5, Int.max - 1, Int.max]
        for period in periods {
            for phase in phases {
                let options = OverlayOptions(zebraThreshold: 0.5, stripePeriod: period, stripePhase: phase)
                let bitmap = OverlayRenderer.render(image, options: options)
                for y in 0..<4 {
                    for x in 0..<5 {
                        // Two residues below period <= Int.max can't overflow a UInt sum.
                        let position = (residue(x + y, period) + residue(phase, period)) % UInt(period)
                        let lit = position < UInt(period / 2)
                        XCTAssertEqual(bitmap[x, y].a, lit ? 230 : 0, "period \(period) phase \(phase) at (\(x), \(y))")
                    }
                }
            }
        }
        // Period Int.max with phase -1: only x + y = 0 lands on Int.max - 1, past the lit half.
        let shifted = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0.5, stripePeriod: Int.max,
                                                                            stripePhase: -1))
        XCTAssertEqual(shifted[0, 0].a, 0)
        XCTAssertEqual(shifted[1, 0].a, 230)
        XCTAssertEqual(shifted[4, 3].a, 230)
    }

    func testRendererClampsAStripePeriodSetAfterInit() {
        var options = OverlayOptions(zebraThreshold: 0.5)
        options.stripePeriod = 0
        let bitmap = OverlayRenderer.render(LumaImage(width: 4, height: 1, fill: 1), options: options)
        XCTAssertEqual((0..<4).map { bitmap[$0, 0].a }, [230, 0, 230, 0])
        options.stripePeriod = -3
        XCTAssertEqual(OverlayRenderer.render(LumaImage(width: 4, height: 1, fill: 1), options: options), bitmap)
    }

    func testZebraIgnoresNaNPixelsAndNaNThresholds() {
        let image = LumaImage(width: 2, height: 1, pixels: [.nan, .nan])
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions(zebraThreshold: 0, stripePeriod: 2))
        XCTAssertTrue(bitmap.isFullyTransparent)
        let bright = LumaImage(width: 2, height: 1, fill: 1)
        let nanThreshold = OverlayRenderer.render(bright, options: OverlayOptions(zebraThreshold: .nan, stripePeriod: 2))
        XCTAssertTrue(nanThreshold.isFullyTransparent)
    }

    func testFalseColorLayerUsesAlpha200() {
        let levels: [Float] = [0.01, 0.05, 0.2, 0.42, 0.5, 0.73, 0.85, 0.95, 1]
        let image = LumaImage(width: levels.count, height: 1, pixels: levels)
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions(falseColor: true))
        for (x, level) in levels.enumerated() {
            let expected = OverlayRenderer.falseColor(luma: Double(level))?.premultiplied(alpha: 200) ?? .clear
            XCTAssertEqual(bitmap[x, 0], expected, "luma \(level)")
        }
        XCTAssertEqual(bitmap[3, 0], RGBA8(r: 0, g: 200, b: 0, a: 200), "middle gray is green")
        XCTAssertEqual(bitmap[2, 0], .clear)
    }

    func testRenderedFalseColorAgreesWithFalseColorAtBandEdges() {
        // Float pixels nearest each threshold, on both sides, must land in the same band as falseColor(luma:).
        var levels: [Float] = []
        for edge in [0.025, 0.10, 0.38, 0.46, 0.70, 0.77, 0.93, 0.99] {
            let nearest = Float(edge)
            levels += [nearest.nextDown, nearest, nearest.nextUp]
        }
        levels.append(.nan)
        let image = LumaImage(width: levels.count, height: 1, pixels: levels)
        let bitmap = OverlayRenderer.render(image, options: OverlayOptions(falseColor: true))
        for (x, level) in levels.enumerated() {
            let expected = OverlayRenderer.falseColor(luma: Double(level))?.premultiplied(alpha: 200) ?? .clear
            XCTAssertEqual(bitmap[x, 0], expected, "luma \(level)")
        }
    }

    func testZebraCompositesOverFalseColor() {
        // Yellow band (0.95) under a white stripe: 230 + 200 * 25 / 255 = 249.6 rounds to 250.
        let image = LumaImage(width: 2, height: 1, fill: 0.95)
        let options = OverlayOptions(zebraThreshold: 0.9, stripePeriod: 2, falseColor: true)
        let bitmap = OverlayRenderer.render(image, options: options)
        XCTAssertEqual(bitmap[0, 0], RGBA8(r: 250, g: 250, b: 230, a: 250))
        XCTAssertEqual(bitmap[1, 0], RGBA8(r: 200, g: 200, b: 0, a: 200), "off stripe shows plain false color")
        // A pixel with no false color band gets the plain stripe.
        let plain = OverlayRenderer.render(LumaImage(width: 1, height: 1, fill: 0.5),
                                           options: OverlayOptions(zebraThreshold: 0.1, falseColor: true))
        XCTAssertEqual(plain[0, 0], RGBA8(r: 230, g: 230, b: 230, a: 230))
    }

    func testPeakingMarksEdgesAndCoversOtherLayers() {
        // Left half black, right half white; peaking marks the two columns beside the edge.
        var pixels: [Float] = []
        for _ in 0..<4 { pixels += [0, 0, 0, 1, 1, 1] }
        let image = LumaImage(width: 6, height: 4, pixels: pixels)
        let options = OverlayOptions(zebraThreshold: 0.9, stripePeriod: 2, peakingThreshold: 0.5,
                                     peakingColor: RGBA8(r: 0, g: 0, b: 255, a: 7), falseColor: true)
        let bitmap = OverlayRenderer.render(image, options: options)
        let peak = RGBA8(r: 0, g: 0, b: 255, a: 255)
        for y in 0..<4 {
            XCTAssertEqual(bitmap[2, y], peak, "row \(y), dark side of the edge")
            XCTAssertEqual(bitmap[3, y], peak, "row \(y), bright side of the edge")
            XCTAssertNotEqual(bitmap[0, y], peak)
            XCTAssertNotEqual(bitmap[5, y], peak)
        }
        // Away from the edge the lower layers still show: purple for black, red (or striped red) for white.
        XCTAssertEqual(bitmap[0, 0], RGBA8.purple.premultiplied(alpha: 200))
        XCTAssertEqual(bitmap[5, 0].a, 200)
        XCTAssertEqual(bitmap[4, 0].a, 250)
    }

    func testPeakingThresholdEdgeCases() {
        let image = LumaImage(width: 3, height: 3, fill: 0.3)
        let everything = OverlayRenderer.render(image, options: OverlayOptions(peakingThreshold: -1))
        XCTAssertEqual(everything[1, 1], RGBA8.red, "a negative threshold marks even flat pixels")
        let zero = OverlayRenderer.render(image, options: OverlayOptions(peakingThreshold: 0))
        XCTAssertEqual(zero[0, 0], RGBA8.red, "magnitude 0 >= threshold 0")
        let nothing = OverlayRenderer.render(image, options: OverlayOptions(peakingThreshold: .nan))
        XCTAssertTrue(nothing.isFullyTransparent)
        let unreachable = OverlayRenderer.render(image, options: OverlayOptions(peakingThreshold: 1.5))
        XCTAssertTrue(unreachable.isFullyTransparent)
    }

    func testRenderedPeakingAgreesWithSobelMagnitude() {
        var rng = SeededGenerator(seed: 21)
        let width = 23, height = 17
        let pixels = (0..<(width * height)).map { _ in Float.random(in: 0...1, using: &rng) }
        let image = LumaImage(width: width, height: height, pixels: pixels)
        // Thresholds include values taken straight from the image, so ties are exercised.
        let thresholds = [0.1, 0.3, 0.6, OverlayRenderer.sobelMagnitude(image, x: 5, y: 5),
                          OverlayRenderer.sobelMagnitude(image, x: 0, y: 16)]
        for threshold in thresholds {
            let bitmap = OverlayRenderer.render(image, options: OverlayOptions(peakingThreshold: threshold, peakingColor: .green))
            for y in 0..<height {
                for x in 0..<width {
                    let marked = OverlayRenderer.sobelMagnitude(image, x: x, y: y) >= threshold
                    XCTAssertEqual(bitmap[x, y], marked ? RGBA8.green : RGBA8.clear, "(\(x), \(y)) threshold \(threshold)")
                }
            }
        }
    }

    func testRenderedPeakingAgreesWithSobelMagnitudeOnThinImages() {
        // One or two pixel wide or tall images clamp most samples, which is where the renderer's row cache could slip.
        var rng = SeededGenerator(seed: 55)
        for (width, height) in [(1, 1), (1, 6), (6, 1), (2, 2), (2, 5), (5, 2), (3, 3)] {
            let pixels = (0..<(width * height)).map { _ in Float.random(in: 0...1, using: &rng) }
            let image = LumaImage(width: width, height: height, pixels: pixels)
            for (tx, ty) in [(0, 0), (width - 1, height - 1), (width / 2, height / 2)] {
                // A threshold taken from the image itself, so the pixel that ties with it must be marked.
                let threshold = OverlayRenderer.sobelMagnitude(image, x: tx, y: ty)
                let options = OverlayOptions(peakingThreshold: threshold, peakingColor: .green)
                let bitmap = OverlayRenderer.render(image, options: options)
                XCTAssertEqual(bitmap[tx, ty], .green, "\(width)x\(height) tie at (\(tx), \(ty))")
                for y in 0..<height {
                    for x in 0..<width {
                        let marked = OverlayRenderer.sobelMagnitude(image, x: x, y: y) >= threshold
                        XCTAssertEqual(bitmap[x, y], marked ? RGBA8.green : RGBA8.clear, "\(width)x\(height) at (\(x), \(y))")
                    }
                }
            }
        }
    }

    func testRenderedLayersAgreeWithReferenceOnRandomImages() {
        var rng = SeededGenerator(seed: 8)
        let width = 19, height = 11
        let pixels = (0..<(width * height)).map { _ in Float.random(in: -0.1...1.1, using: &rng) }
        let image = LumaImage(width: width, height: height, pixels: pixels)
        let options = OverlayOptions(zebraThreshold: 0.8, stripePeriod: 4, stripePhase: 3,
                                     peakingThreshold: 0.35, peakingColor: .yellow, falseColor: true)
        let bitmap = OverlayRenderer.render(image, options: options)
        let zebra = RGBA8.white.premultiplied(alpha: 230)
        for y in 0..<height {
            for x in 0..<width {
                let value = Double(image[x, y])
                var expected = OverlayRenderer.falseColor(luma: value)?.premultiplied(alpha: 200) ?? .clear
                if value >= 0.8 && (x + y + 3) % 4 < 2 {
                    expected = over(zebra, expected)
                }
                if OverlayRenderer.sobelMagnitude(image, x: x, y: y) >= 0.35 {
                    expected = .yellow
                }
                XCTAssertEqual(bitmap[x, y], expected, "(\(x), \(y))")
            }
        }
    }

    func testRenderedOutputIsValidPremultiplied() {
        var rng = SeededGenerator(seed: 13)
        let pixels = (0..<(32 * 24)).map { _ in Float.random(in: 0...1, using: &rng) }
        let image = LumaImage(width: 32, height: 24, pixels: pixels)
        let options = OverlayOptions(zebraThreshold: 0.7, peakingThreshold: 0.2, peakingColor: .white, falseColor: true)
        let bitmap = OverlayRenderer.render(image, options: options)
        for y in 0..<24 {
            for x in 0..<32 {
                let p = bitmap[x, y]
                XCTAssertLessThanOrEqual(p.r, p.a)
                XCTAssertLessThanOrEqual(p.g, p.a)
                XCTAssertLessThanOrEqual(p.b, p.a)
            }
        }
    }

    // MARK: - Helpers

    /// Each pixel gets a distinct color so remapping mistakes show up.
    private func numbered(width: Int, height: Int) -> RGBABitmap {
        var bitmap = RGBABitmap(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                bitmap[x, y] = RGBA8(r: UInt8(x), g: UInt8(y), b: UInt8(y * width + x), a: 255)
            }
        }
        return bitmap
    }

    /// value mod period in 0..<period, for any Int value and period >= 1.
    private func residue(_ value: Int, _ period: Int) -> UInt {
        let r = value % period
        return UInt(r < 0 ? r + period : r)
    }

    /// Source-over on premultiplied colors with rounding, written out independently of the renderer.
    private func over(_ top: RGBA8, _ bottom: RGBA8) -> RGBA8 {
        func mix(_ t: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(min(255, (Double(t) + Double(b) * (255 - Double(top.a)) / 255).rounded()))
        }
        return RGBA8(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a: mix(top.a, bottom.a))
    }

    /// SplitMix64, so a failing random case reproduces.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
