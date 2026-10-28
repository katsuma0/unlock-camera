import XCTest
@testable import CameraCore

final class StackingTests: XCTestCase {
    // MARK: - Helpers

    /// Single channel image whose value encodes its position, so any misplaced pixel is visible.
    private func positionImage(width: Int, height: Int) -> FloatImage {
        var image = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y, 0] = Float(x + 100 * y)
            }
        }
        return image
    }

    private func frame(_ width: Int, _ height: Int, _ channels: Int, _ pixels: [Float]) -> FloatImage {
        FloatImage(width: width, height: height, channels: channels, pixels: pixels)
    }

    // MARK: - FloatImage

    func testFillInitSetsSizeAndValue() {
        let image = FloatImage(width: 3, height: 2, channels: 4, fill: 0.25)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.channels, 4)
        XCTAssertEqual(image.pixels, [Float](repeating: 0.25, count: 24))
        XCTAssertEqual(FloatImage(width: 2, height: 2, channels: 1).pixels, [0, 0, 0, 0])
    }

    func testFillInitClampsInvalidSizes() {
        let noChannels = FloatImage(width: 2, height: 2, channels: 0)
        XCTAssertEqual(noChannels.channels, 1)
        XCTAssertEqual(noChannels.pixels.count, 4)

        let tooManyChannels = FloatImage(width: 2, height: 1, channels: 9)
        XCTAssertEqual(tooManyChannels.channels, 4)
        XCTAssertEqual(tooManyChannels.pixels.count, 8)

        let negative = FloatImage(width: -3, height: 5, channels: 2, fill: 1)
        XCTAssertEqual(negative.width, 0)
        XCTAssertEqual(negative.height, 5)
        XCTAssertTrue(negative.pixels.isEmpty)
    }

    func testPixelsInitKeepsInterleavedRowMajorLayout() {
        // Value = 10 * pixel index + channel.
        let pixels: [Float] = [0, 1, 2, 10, 11, 12, 20, 21, 22, 30, 31, 32]
        let image = FloatImage(width: 2, height: 2, channels: 3, pixels: pixels)
        XCTAssertEqual(image.pixels, pixels)
        XCTAssertEqual(image[0, 0, 0], 0)
        XCTAssertEqual(image[1, 0, 2], 12)
        XCTAssertEqual(image[0, 1, 1], 21)
        XCTAssertEqual(image[1, 1, 0], 30)
        XCTAssertEqual(image[1, 1, 2], 32)
    }

    func testSubscriptGetClampsCoordinatesAndChannel() {
        let image = frame(2, 2, 3, [0, 1, 2, 10, 11, 12, 20, 21, 22, 30, 31, 32])
        XCTAssertEqual(image[-4, 0, 0], 0)
        XCTAssertEqual(image[9, 0, 1], 11)
        XCTAssertEqual(image[0, -1, 2], 2)
        XCTAssertEqual(image[0, 7, 1], 21)
        XCTAssertEqual(image[5, 5, 0], 30)
        XCTAssertEqual(image[1, 1, 7], 32)
        XCTAssertEqual(image[1, 1, -2], 30)
        XCTAssertEqual(image[Int.min, Int.max, Int.max], 22)
    }

    func testSubscriptSetWritesInsideAndIgnoresOutside() {
        var image = FloatImage(width: 2, height: 2, channels: 2)
        image[1, 0, 1] = 5
        image[0, 1, 0] = -2
        XCTAssertEqual(image.pixels, [0, 0, 0, 5, -2, 0, 0, 0])

        let before = image
        image[-1, 0, 0] = 9
        image[2, 0, 0] = 9
        image[0, -1, 0] = 9
        image[0, 2, 0] = 9
        image[0, 0, -1] = 9
        image[0, 0, 2] = 9
        image[Int.max, Int.min, 0] = 9
        XCTAssertEqual(image, before)
    }

    func testSubscriptStaysTotalOnEmptyOrInconsistentImages() {
        let empty = FloatImage(width: 0, height: 0, channels: 1)
        XCTAssertEqual(empty[0, 0, 0], 0)
        XCTAssertEqual(empty[3, -3, 1], 0)

        var shortened = FloatImage(width: 2, height: 2, channels: 1, fill: 3)
        shortened.pixels.removeLast(2)
        XCTAssertEqual(shortened[0, 0, 0], 3)
        XCTAssertEqual(shortened[1, 1, 0], 0)
        shortened[1, 1, 0] = 4
        XCTAssertEqual(shortened.pixels, [3, 3])

        var noChannels = FloatImage(width: 2, height: 2, channels: 1, fill: 3)
        noChannels.channels = 0
        XCTAssertEqual(noChannels[0, 0, 0], 0)
    }

    func testEquatableComparesSizeChannelsAndPixels() {
        let a = FloatImage(width: 2, height: 1, channels: 2, fill: 1)
        XCTAssertEqual(a, frame(2, 1, 2, [1, 1, 1, 1]))
        XCTAssertNotEqual(a, FloatImage(width: 1, height: 2, channels: 2, fill: 1))
        XCTAssertNotEqual(a, FloatImage(width: 4, height: 1, channels: 1, fill: 1))
        XCTAssertNotEqual(a, frame(2, 1, 2, [1, 1, 1, 2]))
    }

    // MARK: - StackAccumulator basics

    func testNewAccumulatorIsEmptyAndReturnsZeros() {
        for blend in StackBlend.allCases {
            let accumulator = StackAccumulator(width: 3, height: 2, channels: 2, blend: blend)
            XCTAssertEqual(accumulator.count, 0)
            XCTAssertEqual(accumulator.blend, blend)
            XCTAssertEqual(accumulator.result(), FloatImage(width: 3, height: 2, channels: 2))
            XCTAssertEqual(accumulator.result(scale: 4), FloatImage(width: 3, height: 2, channels: 2))
            XCTAssertEqual(accumulator.result(scale: .infinity), FloatImage(width: 3, height: 2, channels: 2))
        }
    }

    func testSingleFrameResultIsAnExactCopy() {
        let single = frame(2, 2, 2, [0.1, -0.5, 3.75, 1e-7, 0.3, 2, -8, 0.6])
        for blend in StackBlend.allCases {
            var accumulator = StackAccumulator(width: 2, height: 2, channels: 2, blend: blend)
            accumulator.add(single)
            XCTAssertEqual(accumulator.count, 1)
            XCTAssertEqual(accumulator.result(), single, "\(blend)")
        }
    }

    func testAverageKeepsRunningMean() {
        var accumulator = StackAccumulator(width: 2, height: 1, channels: 1, blend: .average)
        accumulator.add(frame(2, 1, 1, [0, 3]))
        accumulator.add(frame(2, 1, 1, [0, 6]))
        accumulator.add(frame(2, 1, 1, [1, 0]))
        XCTAssertEqual(accumulator.count, 3)
        let mean = accumulator.result()
        XCTAssertEqual(mean[0, 0, 0], 1.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(mean[1, 0, 0], 3, accuracy: 1e-6)
    }

    func testAdditiveStoresTheMeanAndScaleByCountGivesTheSum() {
        var accumulator = StackAccumulator(width: 1, height: 1, channels: 3, blend: .additive)
        accumulator.add(frame(1, 1, 3, [0.1, 0.2, 0.3]))
        accumulator.add(frame(1, 1, 3, [0.3, 0.2, 0.1]))
        accumulator.add(frame(1, 1, 3, [0.2, 0.2, 0.2]))
        accumulator.add(frame(1, 1, 3, [0.4, 0.0, 1.0]))
        let mean = accumulator.result()
        XCTAssertEqual(mean[0, 0, 0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(mean[0, 0, 1], 0.15, accuracy: 1e-6)
        XCTAssertEqual(mean[0, 0, 2], 0.4, accuracy: 1e-6)

        let sum = accumulator.result(scale: Double(accumulator.count))
        XCTAssertEqual(sum[0, 0, 0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(sum[0, 0, 1], 0.6, accuracy: 1e-6)
        XCTAssertEqual(sum[0, 0, 2], 1.6, accuracy: 1e-6)
    }

    func testAdditiveAndAverageAccumulateIdentically() {
        var additive = StackAccumulator(width: 2, height: 2, channels: 1, blend: .additive)
        var average = StackAccumulator(width: 2, height: 2, channels: 1, blend: .average)
        let frames = [frame(2, 2, 1, [1, 2, 3, 4]), frame(2, 2, 1, [0, 0, 9, -1]), frame(2, 2, 1, [5, 5, 5, 5])]
        for (index, item) in frames.enumerated() {
            additive.add(item, shiftX: index, shiftY: -index)
            average.add(item, shiftX: index, shiftY: -index)
        }
        XCTAssertEqual(additive.result(), average.result())
    }

    func testLightenKeepsPerChannelMaximumIncludingNegatives() {
        var accumulator = StackAccumulator(width: 2, height: 1, channels: 2, blend: .lighten)
        accumulator.add(frame(2, 1, 2, [-3, 5, -1, -2]))
        accumulator.add(frame(2, 1, 2, [-4, 7, -0.5, -9]))
        accumulator.add(frame(2, 1, 2, [-2, 1, -8, -2.5]))
        XCTAssertEqual(accumulator.count, 3)
        XCTAssertEqual(accumulator.result().pixels, [-2, 7, -0.5, -2])
    }

    func testResultScaleMultipliesMeanAndMax() {
        var average = StackAccumulator(width: 2, height: 1, channels: 1, blend: .average)
        average.add(frame(2, 1, 1, [1, 2]))
        average.add(frame(2, 1, 1, [3, 6]))
        XCTAssertEqual(average.result(scale: 0.5).pixels, [1, 2])
        XCTAssertEqual(average.result(scale: 2.5).pixels, [5, 10])
        XCTAssertEqual(average.result(scale: 0).pixels, [0, 0])
        XCTAssertEqual(average.result(scale: -1).pixels, [-2, -4])

        var lighten = StackAccumulator(width: 2, height: 1, channels: 1, blend: .lighten)
        lighten.add(frame(2, 1, 1, [1, 8]))
        lighten.add(frame(2, 1, 1, [4, 2]))
        XCTAssertEqual(lighten.result(scale: 0.25).pixels, [1, 2])
    }

    func testResultDoesNotChangeTheAccumulator() {
        var accumulator = StackAccumulator(width: 1, height: 1, channels: 1, blend: .average)
        accumulator.add(frame(1, 1, 1, [2]))
        _ = accumulator.result(scale: 10)
        accumulator.add(frame(1, 1, 1, [4]))
        XCTAssertEqual(accumulator.result().pixels, [3])
    }

    func testMismatchedFramesAreIgnored() {
        var accumulator = StackAccumulator(width: 2, height: 2, channels: 1, blend: .average)
        accumulator.add(FloatImage(width: 2, height: 2, channels: 1, fill: 1))
        accumulator.add(FloatImage(width: 3, height: 2, channels: 1, fill: 9))
        accumulator.add(FloatImage(width: 2, height: 1, channels: 1, fill: 9))
        accumulator.add(FloatImage(width: 2, height: 2, channels: 3, fill: 9))
        var corrupted = FloatImage(width: 2, height: 2, channels: 1, fill: 9)
        corrupted.pixels.append(9)
        accumulator.add(corrupted)
        XCTAssertEqual(accumulator.count, 1)
        XCTAssertEqual(accumulator.result(), FloatImage(width: 2, height: 2, channels: 1, fill: 1))
    }

    func testInvalidAccumulatorSizesAreClampedLikeFloatImage() {
        var accumulator = StackAccumulator(width: 2, height: 2, channels: 0, blend: .average)
        accumulator.add(FloatImage(width: 2, height: 2, channels: 1, fill: 2))
        XCTAssertEqual(accumulator.count, 1)
        XCTAssertEqual(accumulator.result(), FloatImage(width: 2, height: 2, channels: 1, fill: 2))

        var empty = StackAccumulator(width: -1, height: 3, channels: 1, blend: .lighten)
        empty.add(FloatImage(width: 0, height: 3, channels: 1), shiftX: 5, shiftY: -5)
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty.result(scale: 2), FloatImage(width: 0, height: 3, channels: 1))
    }

    // MARK: - Shifts

    func testShiftedContentLandsAtShiftedPosition() {
        var single = FloatImage(width: 6, height: 5, channels: 1)
        single[1, 1, 0] = 1
        var accumulator = StackAccumulator(width: 6, height: 5, channels: 1, blend: .lighten)
        accumulator.add(single, shiftX: 2, shiftY: 1)
        let out = accumulator.result()
        XCTAssertEqual(out[3, 2, 0], 1)
        XCTAssertEqual(out[1, 1, 0], 0)
        XCTAssertEqual(out.pixels.reduce(0, +), 1)
    }

    func testShiftSamplesClampedSourceForEveryPixel() {
        let width = 5
        let height = 4
        let source = positionImage(width: width, height: height)
        let shifts = [(0, 0), (2, 1), (-1, -2), (0, 3), (4, 0), (-4, -3), (1, -1), (5, 4), (-5, -4)]
        for (shiftX, shiftY) in shifts {
            var accumulator = StackAccumulator(width: width, height: height, channels: 1, blend: .average)
            accumulator.add(source, shiftX: shiftX, shiftY: shiftY)
            let out = accumulator.result()
            for y in 0..<height {
                for x in 0..<width {
                    let sourceX = min(max(x - shiftX, 0), width - 1)
                    let sourceY = min(max(y - shiftY, 0), height - 1)
                    XCTAssertEqual(out[x, y, 0], Float(sourceX + 100 * sourceY),
                                   "shift (\(shiftX), \(shiftY)) at (\(x), \(y))")
                }
            }
        }
    }

    func testShiftKeepsChannelsOfAPixelTogether() {
        let width = 4
        let height = 3
        var source = FloatImage(width: width, height: height, channels: 3)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    source[x, y, c] = Float(1000 * c + x + 10 * y)
                }
            }
        }
        var accumulator = StackAccumulator(width: width, height: height, channels: 3, blend: .lighten)
        accumulator.add(source, shiftX: 1, shiftY: -1)
        let out = accumulator.result()
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = min(max(x - 1, 0), width - 1)
                let sourceY = min(max(y + 1, 0), height - 1)
                for c in 0..<3 {
                    XCTAssertEqual(out[x, y, c], Float(1000 * c + sourceX + 10 * sourceY), "(\(x), \(y), \(c))")
                }
            }
        }
    }

    func testHugeShiftsRepeatTheNearestCornerWithoutTrapping() {
        let source = positionImage(width: 3, height: 3)
        let cases: [(Int, Int, Float)] = [
            (Int.max, Int.max, 0),        // content pushed far right and down: everything samples (0, 0)
            (Int.min, Int.min, 202),      // far left and up: everything samples (2, 2)
            (1000, -1000, 200),           // right and up: (0, 2)
            (-1000, 1000, 2),             // left and down: (2, 0)
        ]
        for (shiftX, shiftY, expected) in cases {
            var accumulator = StackAccumulator(width: 3, height: 3, channels: 1, blend: .average)
            accumulator.add(source, shiftX: shiftX, shiftY: shiftY)
            XCTAssertEqual(accumulator.result().pixels, [Float](repeating: expected, count: 9),
                           "shift (\(shiftX), \(shiftY))")
        }
    }

    func testShiftByMinusMotionAlignsAMovedFrame() {
        let width = 12
        let height = 9
        let reference = positionImage(width: width, height: height)
        // The same scene with its content moved by (+3, +1), as a later handheld frame would show it.
        var moved = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height {
            for x in 0..<width {
                moved[x, y, 0] = reference[x - 3, y - 1, 0]
            }
        }
        var accumulator = StackAccumulator(width: width, height: height, channels: 1, blend: .average)
        accumulator.add(reference)
        accumulator.add(moved, shiftX: -3, shiftY: -1)
        let out = accumulator.result()
        // Where both frames have real content, the average equals the reference exactly.
        for y in 0..<(height - 1) {
            for x in 0..<(width - 3) {
                XCTAssertEqual(out[x, y, 0], reference[x, y, 0], "(\(x), \(y))")
            }
        }
    }

    func testRunningMeanMatchesDirectMeanOverManyFrames() {
        var generator = SplitMix(seed: 42)
        let frameCount = 600
        let pixelCount = 8
        var sums = [Double](repeating: 0, count: pixelCount)
        var accumulator = StackAccumulator(width: 4, height: 2, channels: 1, blend: .additive)
        for _ in 0..<frameCount {
            var pixels = [Float](repeating: 0, count: pixelCount)
            for i in 0..<pixelCount {
                pixels[i] = Float(generator.nextUnit() * 2)
                sums[i] += Double(pixels[i])
            }
            accumulator.add(frame(4, 2, 1, pixels))
        }
        XCTAssertEqual(accumulator.count, frameCount)
        let mean = accumulator.result()
        let total = accumulator.result(scale: Double(frameCount))
        for i in 0..<pixelCount {
            XCTAssertEqual(Double(mean.pixels[i]), sums[i] / Double(frameCount), accuracy: 1e-5)
            XCTAssertEqual(Double(total.pixels[i]), sums[i], accuracy: 1e-2)
        }
    }

    func testRunningMeanIsBitExactWithTheDocumentedFormula() {
        // This type is the reference for the GPU stacking math, so each step must be exactly
        // mean += (frame - mean) / count on the shifted, edge-clamped frame, not an algebraic variant of it.
        let width = 5
        let height = 3
        let channels = 2
        var generator = SplitMix(seed: 7)
        for blend in [StackBlend.additive, .average] {
            var accumulator = StackAccumulator(width: width, height: height, channels: channels, blend: blend)
            var expected = [Float](repeating: 0, count: width * height * channels)
            for n in 1...40 {
                var frame = FloatImage(width: width, height: height, channels: channels)
                for i in frame.pixels.indices {
                    frame.pixels[i] = Float(generator.nextUnit() * 3 - 0.5)
                }
                let shiftX = n % 7 - 3
                let shiftY = n % 5 - 2
                accumulator.add(frame, shiftX: shiftX, shiftY: shiftY)
                for y in 0..<height {
                    for x in 0..<width {
                        for c in 0..<channels {
                            let sample = frame[x - shiftX, y - shiftY, c]
                            let i = (y * width + x) * channels + c
                            expected[i] += (sample - expected[i]) / Float(n)
                        }
                    }
                }
            }
            XCTAssertEqual(accumulator.result().pixels, expected, "\(blend)")
        }
    }

    func testLightenSkipsNaNInAnyFrame() {
        // NaN in the first frame must not pin a pixel for the rest of the stack, and a later NaN never wins.
        var accumulator = StackAccumulator(width: 3, height: 1, channels: 1, blend: .lighten)
        accumulator.add(frame(3, 1, 1, [.nan, 1, .nan]))
        accumulator.add(frame(3, 1, 1, [2, .nan, .nan]))
        accumulator.add(frame(3, 1, 1, [0.5, 3, .nan]))
        let out = accumulator.result().pixels
        XCTAssertEqual(out[0], 2)
        XCTAssertEqual(out[1], 3)
        // Only a pixel that is NaN in every frame stays NaN.
        XCTAssertTrue(out[2].isNaN)
    }

    func testLightenOverManyShiftedFramesTracesAStreak() {
        // A star moving one pixel per frame leaves a trail, the reason lighten exists.
        let width = 8
        var accumulator = StackAccumulator(width: width, height: 1, channels: 1, blend: .lighten)
        var star = FloatImage(width: width, height: 1, channels: 1, fill: 0.1)
        star[1, 0, 0] = 1
        for step in 0..<5 {
            accumulator.add(star, shiftX: step, shiftY: 0)
        }
        XCTAssertEqual(accumulator.result().pixels, [0.1, 1, 1, 1, 1, 1, 0.1, 0.1])
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(UInt64(1) << 53)
        }
    }
}
