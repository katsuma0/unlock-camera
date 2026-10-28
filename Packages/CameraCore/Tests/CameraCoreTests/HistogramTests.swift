import XCTest
@testable import CameraCore

final class HistogramTests: XCTestCase {
    // MARK: - Histogram

    func testEmptyHistogramHas256ZeroBinsPerChannel() {
        let histogram = Histogram()
        XCTAssertEqual(Histogram.binCount, 256)
        XCTAssertEqual(histogram.sampleCount, 0)
        for channel in HistogramChannel.allCases {
            XCTAssertEqual(histogram.bins(channel), [UInt32](repeating: 0, count: 256), "\(channel)")
        }
        XCTAssertEqual(histogram, Histogram())
    }

    func testChannelCasesAndRawValues() {
        XCTAssertEqual(HistogramChannel.allCases, [.luma, .red, .green, .blue])
        XCTAssertEqual(HistogramChannel.allCases.map(\.rawValue), ["luma", "red", "green", "blue"])
        XCTAssertEqual(HistogramChannel(rawValue: "green"), .green)
        XCTAssertNil(HistogramChannel(rawValue: "alpha"))
    }

    func testBinsReturnsTheMatchingChannel() {
        var histogram = Histogram()
        histogram.luma[1] = 5
        histogram.red[2] = 6
        histogram.green[3] = 7
        histogram.blue[4] = 8
        XCTAssertEqual(histogram.bins(.luma)[1], 5)
        XCTAssertEqual(histogram.bins(.red)[2], 6)
        XCTAssertEqual(histogram.bins(.green)[3], 7)
        XCTAssertEqual(histogram.bins(.blue)[4], 8)
        XCTAssertEqual(histogram.bins(.luma)[2], 0)
        XCTAssertNotEqual(histogram, Histogram())
    }

    func testNormalizedLinearDividesByTallestBin() {
        var histogram = Histogram()
        histogram.luma[10] = 4
        histogram.luma[20] = 16
        let values = histogram.normalized(.luma, compress: false)
        XCTAssertEqual(values.count, 256)
        XCTAssertEqual(values[10], 0.25, accuracy: 1e-7)
        XCTAssertEqual(values[20], 1)
        XCTAssertEqual(values.filter { $0 != 0 }.count, 2)
    }

    func testNormalizedCompressTakesSquareRootsAndIsTheDefault() {
        var histogram = Histogram()
        histogram.red[10] = 4
        histogram.red[20] = 16
        histogram.red[30] = 1
        let values = histogram.normalized(.red)
        XCTAssertEqual(values, histogram.normalized(.red, compress: true))
        XCTAssertEqual(values[10], 0.5, accuracy: 1e-7)
        XCTAssertEqual(values[20], 1)
        XCTAssertEqual(values[30], 0.25, accuracy: 1e-7)
        // The compressed tail sits higher than the linear one, which is the point of compressing.
        XCTAssertGreaterThan(values[30], histogram.normalized(.red, compress: false)[30])
    }

    func testNormalizedPeakIsExactlyOne() {
        var histogram = Histogram()
        histogram.blue[200] = 7
        histogram.blue[3] = 3
        XCTAssertEqual(histogram.normalized(.blue, compress: true)[200], 1)
        XCTAssertEqual(histogram.normalized(.blue, compress: false)[200], 1)
        let all = histogram.normalized(.blue)
        XCTAssertTrue(all.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testNormalizedAllZeroGivesZeros() {
        let histogram = Histogram()
        for compress in [true, false] {
            let values = histogram.normalized(.green, compress: compress)
            XCTAssertEqual(values, [Float](repeating: 0, count: 256))
        }
    }

    func testBucketedEvenSplits() {
        var histogram = Histogram()
        histogram.luma = [UInt32](repeating: 1, count: 256)
        XCTAssertEqual(histogram.bucketed(.luma, count: 4), [64, 64, 64, 64])
        XCTAssertEqual(histogram.bucketed(.luma, count: 1), [256])
        XCTAssertEqual(histogram.bucketed(.luma, count: 256), histogram.luma)
        XCTAssertEqual(histogram.bucketed(.luma, count: 64), [UInt32](repeating: 4, count: 64))
    }

    func testBucketedLastBucketTakesTheRest() {
        var histogram = Histogram()
        histogram.green = (0..<256).map { UInt32($0) }
        // 256 / 3 = 85: buckets 0..<85, 85..<170, then 170..<256 (86 bins).
        let three = histogram.bucketed(.green, count: 3)
        XCTAssertEqual(three, [3_570, 10_795, 18_275])
        XCTAssertEqual(three.reduce(0, +), 32_640)
        // 256 / 200 = 1: 199 single bins, then the last bucket sums bins 199...255.
        let many = histogram.bucketed(.green, count: 200)
        XCTAssertEqual(many.count, 200)
        XCTAssertEqual(Array(many.prefix(199)), (0..<199).map { UInt32($0) })
        XCTAssertEqual(many[199], UInt32((199...255).reduce(0, +)))
    }

    func testBucketedClampsCount() {
        var histogram = Histogram()
        histogram.red = [UInt32](repeating: 2, count: 256)
        XCTAssertEqual(histogram.bucketed(.red, count: 0), [512])
        XCTAssertEqual(histogram.bucketed(.red, count: -5), [512])
        XCTAssertEqual(histogram.bucketed(.red, count: Int.min), [512])
        XCTAssertEqual(histogram.bucketed(.red, count: 1_000), histogram.red)
        XCTAssertEqual(histogram.bucketed(.red, count: Int.max).count, 256)
    }

    func testBucketedSaturatesInsteadOfOverflowing() {
        var histogram = Histogram()
        histogram.blue[0] = UInt32.max
        histogram.blue[1] = 10
        XCTAssertEqual(histogram.bucketed(.blue, count: 1), [UInt32.max])
        XCTAssertEqual(histogram.bucketed(.blue, count: 128)[0], UInt32.max)
    }

    // MARK: - ExposureStats

    func testExposureStatsInitAndEmpty() {
        let stats = ExposureStats(meanLuma: 0.4, medianLuma: 0.3, clippedHighlights: 0.02, crushedShadows: 0.01)
        XCTAssertEqual(stats.meanLuma, 0.4)
        XCTAssertEqual(stats.medianLuma, 0.3)
        XCTAssertEqual(stats.clippedHighlights, 0.02)
        XCTAssertEqual(stats.crushedShadows, 0.01)
        XCTAssertEqual(ExposureStats.empty, ExposureStats(meanLuma: 0, medianLuma: 0, clippedHighlights: 0, crushedShadows: 0))
        XCTAssertNotEqual(stats, .empty)
    }

    // MARK: - LumaImage

    func testLumaImageUniformMidGray() {
        let image = LumaImage(width: 4, height: 4, fill: 0.5)
        let (histogram, stats) = HistogramComputer.compute(luma: image)
        XCTAssertEqual(histogram.sampleCount, 16)
        // 0.5 * 255 = 127.5 rounds half up.
        XCTAssertEqual(histogram.luma[128], 16)
        XCTAssertEqual(histogram.luma.reduce(0, +), 16)
        XCTAssertEqual(stats.meanLuma, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stats.medianLuma, 128.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(stats.clippedHighlights, 0)
        XCTAssertEqual(stats.crushedShadows, 0)
    }

    func testLumaImageLeavesRGBEmpty() {
        let image = LumaImage(width: 3, height: 1, pixels: [0.1, 0.99, 1])
        let (histogram, stats) = HistogramComputer.compute(luma: image)
        XCTAssertEqual(histogram.red, [UInt32](repeating: 0, count: 256))
        XCTAssertEqual(histogram.green, [UInt32](repeating: 0, count: 256))
        XCTAssertEqual(histogram.blue, [UInt32](repeating: 0, count: 256))
        // Without RGB, clipping comes from luma alone: 0.99 and 1 land in bins 252 and 255.
        XCTAssertEqual(stats.clippedHighlights, 2.0 / 3, accuracy: 1e-12)
    }

    func testLumaImageMixedValuesClampAndClassify() {
        let values: [Float] = [0, 0.01, 0.2, 0.5, 0.98, 1, 1.5, -0.5]
        let image = LumaImage(width: 4, height: 2, pixels: values)
        let (histogram, stats) = HistogramComputer.compute(luma: image)
        var expected = [UInt32](repeating: 0, count: 256)
        expected[0] = 2      // 0 and -0.5 (clamped)
        expected[3] = 1      // 0.01 * 255 = 2.55
        expected[51] = 1     // 0.2
        expected[128] = 1    // 0.5
        expected[250] = 1    // 0.98 * 255 = 249.9
        expected[255] = 2    // 1 and 1.5 (clamped)
        XCTAssertEqual(histogram.luma, expected)
        XCTAssertEqual(histogram.sampleCount, 8)
        XCTAssertEqual(stats.crushedShadows, 3.0 / 8, accuracy: 1e-12)
        XCTAssertEqual(stats.clippedHighlights, 3.0 / 8, accuracy: 1e-12)
        // Mean of the clamped values: (0.01 + 0.2 + 0.5 + 0.98 + 1 + 1) / 8.
        XCTAssertEqual(stats.meanLuma, 3.69 / 8, accuracy: 1e-6)
        // Sorted bins 0 0 3 51 | 128 250 255 255: the two middle samples are 51 and 128.
        XCTAssertEqual(stats.medianLuma, 89.5 / 255, accuracy: 1e-12)
    }

    func testLumaImageNaNCountsAsBlack() {
        let image = LumaImage(width: 2, height: 1, pixels: [.nan, 1])
        let (histogram, stats) = HistogramComputer.compute(luma: image)
        XCTAssertEqual(histogram.luma[0], 1)
        XCTAssertEqual(histogram.luma[255], 1)
        XCTAssertEqual(stats.meanLuma, 0.5, accuracy: 1e-12)
        XCTAssertFalse(stats.meanLuma.isNaN)
        XCTAssertEqual(stats.crushedShadows, 0.5, accuracy: 1e-12)
    }

    func testLumaImageInfinitiesClamp() {
        let image = LumaImage(width: 2, height: 1, pixels: [-.infinity, .infinity])
        let (histogram, stats) = HistogramComputer.compute(luma: image)
        XCTAssertEqual(histogram.luma[0], 1)
        XCTAssertEqual(histogram.luma[255], 1)
        XCTAssertEqual(stats.meanLuma, 0.5, accuracy: 1e-12)
    }

    func testLumaImageExactLevelsLandInTheirOwnBins() {
        let pixels = (0..<256).map { Float($0) / 255 }
        let (histogram, stats) = HistogramComputer.compute(luma: LumaImage(width: 16, height: 16, pixels: pixels))
        XCTAssertEqual(histogram.luma, [UInt32](repeating: 1, count: 256))
        // Bins 0...4 crushed, 250...255 clipped.
        XCTAssertEqual(stats.crushedShadows, 5.0 / 256, accuracy: 1e-12)
        XCTAssertEqual(stats.clippedHighlights, 6.0 / 256, accuracy: 1e-12)
        XCTAssertEqual(stats.meanLuma, 0.5, accuracy: 1e-6)
        XCTAssertEqual(stats.medianLuma, 127.5 / 255, accuracy: 1e-12)
    }

    func testLumaImageRoundsToNearestBin() {
        for level in 0..<255 {
            let below = LumaImage(width: 1, height: 1, pixels: [(Float(level) + 0.4) / 255])
            let above = LumaImage(width: 1, height: 1, pixels: [(Float(level) + 0.6) / 255])
            XCTAssertEqual(HistogramComputer.compute(luma: below).0.luma[level], 1, "level \(level) + 0.4")
            XCTAssertEqual(HistogramComputer.compute(luma: above).0.luma[level + 1], 1, "level \(level) + 0.6")
        }
    }

    func testLumaImageClippingAndCrushingThresholds() {
        // Bin 249 is not clipped, 250 is; bin 4 is crushed, 5 is not.
        let pixels: [Float] = [249, 250, 4, 5].map { $0 / 255 }
        let (_, stats) = HistogramComputer.compute(luma: LumaImage(width: 4, height: 1, pixels: pixels))
        XCTAssertEqual(stats.clippedHighlights, 0.25, accuracy: 1e-12)
        XCTAssertEqual(stats.crushedShadows, 0.25, accuracy: 1e-12)
    }

    func testEmptyLumaImageGivesEmptyResult() {
        for image in [LumaImage(width: 0, height: 0), LumaImage(width: 5, height: 0), LumaImage(width: 0, height: 3)] {
            let (histogram, stats) = HistogramComputer.compute(luma: image)
            XCTAssertEqual(histogram, Histogram())
            XCTAssertEqual(stats, .empty)
        }
    }

    func testLumaImageWithMismatchedPixelArrayReadsOnlyWhatExists() {
        var image = LumaImage(width: 4, height: 4, fill: 1)
        image.pixels = [1, 1, 1]
        let (histogram, stats) = HistogramComputer.compute(luma: image)
        XCTAssertEqual(histogram.sampleCount, 3)
        XCTAssertEqual(histogram.luma[255], 3)
        XCTAssertEqual(stats.meanLuma, 1, accuracy: 1e-12)
    }

    func testMedianOfTwoEvenGroupsIsHalfway() {
        let pixels = [Float](repeating: 10.0 / 255, count: 5) + [Float](repeating: 20.0 / 255, count: 5)
        let (_, stats) = HistogramComputer.compute(luma: LumaImage(width: 10, height: 1, pixels: pixels))
        XCTAssertEqual(stats.medianLuma, 15.0 / 255, accuracy: 1e-12)
    }

    func testMedianOfOddCountIsTheMiddleSample() {
        let pixels: [Float] = [200, 10, 30].map { $0 / 255 }
        let (_, stats) = HistogramComputer.compute(luma: LumaImage(width: 3, height: 1, pixels: pixels))
        XCTAssertEqual(stats.medianLuma, 30.0 / 255, accuracy: 1e-12)
        let skewed: [Float] = [10, 10, 10, 250].map { $0 / 255 }
        let (_, skewedStats) = HistogramComputer.compute(luma: LumaImage(width: 4, height: 1, pixels: skewed))
        XCTAssertEqual(skewedStats.medianLuma, 10.0 / 255, accuracy: 1e-12)
    }

    // MARK: - YCbCr

    func testFullRangeNeutralGray() {
        let (histogram, stats) = ycbcr(luma: [UInt8](repeating: 100, count: 16), width: 4, height: 4,
                                       chroma: [UInt8](repeating: 128, count: 8), step: 1, fullRange: true)
        XCTAssertEqual(histogram.sampleCount, 16)
        for channel in HistogramChannel.allCases {
            XCTAssertEqual(histogram.bins(channel)[100], 16, "\(channel)")
            XCTAssertEqual(histogram.bins(channel).reduce(0, +), 16, "\(channel)")
        }
        XCTAssertEqual(stats.meanLuma, 100.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(stats.medianLuma, 100.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(stats.clippedHighlights, 0)
        XCTAssertEqual(stats.crushedShadows, 0)
    }

    func testFullRangeWhiteAndBlack() {
        let (white, whiteStats) = ycbcr(luma: [255, 255, 255, 255], width: 2, height: 2,
                                        chroma: [128, 128], step: 1, fullRange: true)
        for channel in HistogramChannel.allCases {
            XCTAssertEqual(white.bins(channel)[255], 4, "\(channel)")
        }
        XCTAssertEqual(whiteStats.clippedHighlights, 1)
        XCTAssertEqual(whiteStats.meanLuma, 1, accuracy: 1e-12)
        let (black, blackStats) = ycbcr(luma: [0, 0, 0, 0], width: 2, height: 2,
                                        chroma: [128, 128], step: 1, fullRange: true)
        XCTAssertEqual(black.luma[0], 4)
        XCTAssertEqual(blackStats.crushedShadows, 1)
        XCTAssertEqual(blackStats.meanLuma, 0)
    }

    func testStrongCrClipsRedWhileLumaIsFine() {
        // Y 200, Cr 255: R = 200 + 1.5748 * 127 (clamps to 255), G = 200 - 0.4681 * 127 = 140.55, B = 200.
        let (histogram, stats) = ycbcr(luma: [200, 200, 200, 200], width: 2, height: 2,
                                       chroma: [128, 255], step: 1, fullRange: true)
        XCTAssertEqual(histogram.luma[200], 4)
        XCTAssertEqual(histogram.red[255], 4)
        XCTAssertEqual(histogram.green[141], 4)
        XCTAssertEqual(histogram.blue[200], 4)
        XCTAssertEqual(stats.clippedHighlights, 1, "a clipped red channel counts even with luma at 200")
    }

    func testFullRangeRedDecodesToRed() {
        // BT.709 full range encoding of pure red: Y 54, Cb 99, Cr 255.
        let (histogram, stats) = ycbcr(luma: [54], width: 1, height: 1, chroma: [99, 255], step: 1, fullRange: true)
        XCTAssertEqual(histogram.luma[54], 1)
        XCTAssertEqual(histogram.red[254], 1)   // 54 + 1.5748 * 127 = 253.9996
        XCTAssertEqual(histogram.green[0], 1)   // 54 + 0.1873 * 29 - 0.4681 * 127 = -0.017
        XCTAssertEqual(histogram.blue[0], 1)    // 54 - 1.8556 * 29 = 0.19
        XCTAssertEqual(stats.clippedHighlights, 1)
        XCTAssertEqual(stats.crushedShadows, 0)
    }

    func testBlueChromaDrivesBlueAndGreen() {
        // Cb 228: B = 100 + 1.8556 * 100 = 285.56 (clamps), G = 100 - 0.1873 * 100 = 81.27, R = 100.
        let (histogram, _) = ycbcr(luma: [100], width: 1, height: 1, chroma: [228, 128], step: 1, fullRange: true)
        XCTAssertEqual(histogram.red[100], 1)
        XCTAssertEqual(histogram.green[81], 1)
        XCTAssertEqual(histogram.blue[255], 1)
    }

    func testVideoRangeLevels() {
        // Y' = (Y - 16) / 219: 16 -> 0, 235 -> 255, 125 -> 126.92 -> 127, 5 -> clamped 0.
        let (histogram, stats) = ycbcr(luma: [16, 235, 125, 5], width: 2, height: 2,
                                       chroma: [128, 128], step: 1, fullRange: false)
        XCTAssertEqual(histogram.luma[0], 2)
        XCTAssertEqual(histogram.luma[255], 1)
        XCTAssertEqual(histogram.luma[127], 1)
        // Neutral chroma: R = G = B = Y', so RGB bins match luma bins.
        XCTAssertEqual(histogram.red, histogram.luma)
        XCTAssertEqual(histogram.green, histogram.luma)
        XCTAssertEqual(histogram.blue, histogram.luma)
        XCTAssertEqual(stats.meanLuma, (1 + 109.0 / 219) / 4, accuracy: 1e-12)
    }

    func testVideoRangeChromaScale() {
        // C' = (C - 128) / 224: Cr 240 gives R = (100 - 16) / 219 * 255 + 1.5748 * 112 / 224 * 255 = 298.6 -> 255,
        // G = 97.81 - 0.4681 * 0.5 * 255 = 38.13 -> 38.
        let (histogram, _) = ycbcr(luma: [100], width: 1, height: 1, chroma: [128, 240], step: 1, fullRange: false)
        XCTAssertEqual(histogram.luma[98], 1)
        XCTAssertEqual(histogram.red[255], 1)
        XCTAssertEqual(histogram.green[38], 1)
        XCTAssertEqual(histogram.blue[98], 1)
    }

    func testVideoRangeClippingAndCrushingThresholds() {
        // 230 -> 249.18 (not clipped), 231 -> 250.34 (clipped), 19 -> 3.49 (crushed), 20 -> 4.66 (not crushed).
        let (histogram, stats) = ycbcr(luma: [230, 231, 19, 20], width: 2, height: 2,
                                       chroma: [128, 128], step: 1, fullRange: false)
        XCTAssertEqual(histogram.luma[249], 1)
        XCTAssertEqual(histogram.luma[250], 1)
        XCTAssertEqual(histogram.luma[3], 1)
        XCTAssertEqual(histogram.luma[5], 1)
        XCTAssertEqual(stats.clippedHighlights, 0.25, accuracy: 1e-12)
        XCTAssertEqual(stats.crushedShadows, 0.25, accuracy: 1e-12)
    }

    func testFullRangeClippingAndCrushingThresholds() {
        let (_, stats) = ycbcr(luma: [249, 250, 4, 5], width: 2, height: 2,
                               chroma: [128, 128], step: 1, fullRange: true)
        XCTAssertEqual(stats.clippedHighlights, 0.25, accuracy: 1e-12)
        XCTAssertEqual(stats.crushedShadows, 0.25, accuracy: 1e-12)
    }

    func testRGBClipsAt252() {
        // Neutral chroma keeps RGB equal to luma, so isolate the RGB rule with a green-heavy pixel instead:
        // Y 240, Cb 128, Cr 104: R = 240 - 37.8 = 202.2, G = 240 + 11.23 = 251.23 -> 251 (not clipped).
        let (notClipped, notClippedStats) = ycbcr(luma: [240], width: 1, height: 1, chroma: [128, 104],
                                                  step: 1, fullRange: true)
        XCTAssertEqual(notClipped.green[251], 1)
        XCTAssertEqual(notClippedStats.clippedHighlights, 0)
        // Cr 100: G = 240 + 0.4681 * 28 = 253.1 -> 253 (clipped through green alone).
        let (clipped, clippedStats) = ycbcr(luma: [240], width: 1, height: 1, chroma: [128, 100],
                                            step: 1, fullRange: true)
        XCTAssertEqual(clipped.green[253], 1)
        XCTAssertEqual(clippedStats.clippedHighlights, 1)
    }

    func testStepSamplesEveryNthPixelFromTheOrigin() {
        let luma = (0..<16).map { UInt8($0) }
        let chroma = [UInt8](repeating: 128, count: 8)
        let (two, _) = ycbcr(luma: luma, width: 4, height: 4, chroma: chroma, step: 2, fullRange: true)
        XCTAssertEqual(two.sampleCount, 4)
        for value in [0, 2, 8, 10] {
            XCTAssertEqual(two.luma[value], 1, "value \(value)")
        }
        let (three, _) = ycbcr(luma: luma, width: 4, height: 4, chroma: chroma, step: 3, fullRange: true)
        XCTAssertEqual(three.sampleCount, 4)
        for value in [0, 3, 12, 15] {
            XCTAssertEqual(three.luma[value], 1, "value \(value)")
        }
        for step in [1, 0, -1, Int.min] {
            let (all, _) = ycbcr(luma: luma, width: 4, height: 4, chroma: chroma, step: step, fullRange: true)
            XCTAssertEqual(all.sampleCount, 16, "step \(step)")
            XCTAssertEqual(all.luma.reduce(0, +), 16)
        }
        let (one, _) = ycbcr(luma: luma, width: 4, height: 4, chroma: chroma, step: Int.max, fullRange: true)
        XCTAssertEqual(one.sampleCount, 1)
        XCTAssertEqual(one.luma[0], 1)
    }

    func testEachPixelReadsItsOwnChromaSample() {
        // 4 x 2 luma at Y 100; chroma pixel 0 neutral, chroma pixel 1 with Cr 255 for columns 2 and 3.
        let (histogram, stats) = ycbcr(luma: [UInt8](repeating: 100, count: 8), width: 4, height: 2,
                                       chroma: [128, 128, 128, 255], step: 1, fullRange: true)
        XCTAssertEqual(histogram.red[100], 4)
        XCTAssertEqual(histogram.red[255], 4)
        XCTAssertEqual(histogram.green[100], 4)
        XCTAssertEqual(histogram.green[41], 4)   // 100 - 0.4681 * 127 = 40.55
        XCTAssertEqual(histogram.blue[100], 8)
        XCTAssertEqual(stats.clippedHighlights, 0.5, accuracy: 1e-12)
    }

    func testChromaRowsUseTheirOwnBytesPerRow() {
        // 2 x 4 luma, chroma 1 x 2 in rows of 4 bytes: the padding bytes must not be read as chroma.
        let chroma: [UInt8] = [128, 255, 0, 0, 128, 128, 0, 0]
        let (histogram, _) = ycbcr(luma: [UInt8](repeating: 100, count: 8), width: 2, height: 4,
                                   chroma: chroma, chromaWidth: 1, chromaHeight: 2, chromaRowBytes: 4,
                                   step: 1, fullRange: true)
        // Luma rows 0 and 1 use chroma row 0 (Cr 255), rows 2 and 3 use chroma row 1 (neutral).
        XCTAssertEqual(histogram.red[255], 4)
        XCTAssertEqual(histogram.red[100], 4)
    }

    func testOddSizedPlanesClampChromaAtTheEdges() {
        // 5 x 3 luma with a 2 x 1 chroma plane: column 4 and row 2 reuse the last chroma sample.
        let (histogram, _) = ycbcr(luma: [UInt8](repeating: 100, count: 15), width: 5, height: 3,
                                   chroma: [128, 128, 128, 255], chromaWidth: 2, chromaHeight: 1, chromaRowBytes: 4,
                                   step: 1, fullRange: true)
        XCTAssertEqual(histogram.sampleCount, 15)
        XCTAssertEqual(histogram.red[100], 6)
        XCTAssertEqual(histogram.red[255], 9)
    }

    func testMissingChromaGivesLumaOnly() {
        let luma: [UInt8] = [10, 252, 128, 200]
        for (chromaWidth, chromaHeight, rowBytes) in [(0, 1, 2), (1, 0, 2), (1, 1, 1)] {
            let (histogram, stats) = ycbcr(luma: luma, width: 2, height: 2, chroma: [128, 255],
                                           chromaWidth: chromaWidth, chromaHeight: chromaHeight, chromaRowBytes: rowBytes,
                                           step: 1, fullRange: true)
            XCTAssertEqual(histogram.sampleCount, 4)
            XCTAssertEqual(histogram.luma[10], 1)
            XCTAssertEqual(histogram.luma[252], 1)
            XCTAssertEqual(histogram.red, [UInt32](repeating: 0, count: 256))
            XCTAssertEqual(histogram.green, [UInt32](repeating: 0, count: 256))
            XCTAssertEqual(histogram.blue, [UInt32](repeating: 0, count: 256))
            XCTAssertEqual(stats.clippedHighlights, 0.25, accuracy: 1e-12)
            XCTAssertEqual(stats.meanLuma, (10.0 + 252 + 128 + 200) / 4 / 255, accuracy: 1e-12)
        }
    }

    func testEmptyLumaPlaneGivesEmptyResult() {
        for (width, height) in [(0, 2), (2, 0), (-3, 2)] {
            let (histogram, stats) = ycbcr(luma: [1, 2, 3, 4], width: width, height: height,
                                           chroma: [128, 128], chromaWidth: 1, chromaHeight: 1, chromaRowBytes: 2,
                                           lumaRowBytes: 2, step: 1, fullRange: true)
            XCTAssertEqual(histogram, Histogram())
            XCTAssertEqual(stats, .empty)
        }
    }

    func testLumaRowPaddingIsNeverRead() {
        // 2 x 2 luma in rows of 4 bytes; padding is 255 and must not show up as clipped samples.
        let (histogram, stats) = ycbcr(luma: [50, 50, 255, 255, 50, 50, 255, 255], width: 2, height: 2,
                                       chroma: [128, 128], chromaWidth: 1, chromaHeight: 1, chromaRowBytes: 2,
                                       lumaRowBytes: 4, step: 1, fullRange: true)
        XCTAssertEqual(histogram.luma[50], 4)
        XCTAssertEqual(stats.clippedHighlights, 0)
    }

    func testRandomYCbCrMatchesDoubleReference() {
        var rng = SeededGenerator(seed: 42)
        var checked = 0
        while checked < 3_000 {
            let y = UInt8.random(in: 0...255, using: &rng)
            let cb = UInt8.random(in: 0...255, using: &rng)
            let cr = UInt8.random(in: 0...255, using: &rng)
            let fullRange = Bool.random(using: &rng)
            guard let expected = referenceYCbCr(y: y, cb: cb, cr: cr, fullRange: fullRange) else { continue }
            let (histogram, stats) = ycbcr(luma: [y], width: 1, height: 1, chroma: [cb, cr], step: 1, fullRange: fullRange)
            let message = "Y \(y) Cb \(cb) Cr \(cr) full \(fullRange)"
            XCTAssertEqual(histogram.luma[expected.luma], 1, message)
            XCTAssertEqual(histogram.red[expected.red], 1, message)
            XCTAssertEqual(histogram.green[expected.green], 1, message)
            XCTAssertEqual(histogram.blue[expected.blue], 1, message)
            let clipped = expected.luma >= 250 || expected.red >= 252 || expected.green >= 252 || expected.blue >= 252
            XCTAssertEqual(stats.clippedHighlights, clipped ? 1 : 0, message)
            XCTAssertEqual(stats.crushedShadows, expected.luma <= 4 ? 1 : 0, message)
            XCTAssertEqual(stats.meanLuma, expected.mean, accuracy: 1e-12, message)
            checked += 1
        }
    }

    func testEveryLumaByteInBothRanges() {
        for fullRange in [true, false] {
            let luma = (0..<256).map { UInt8($0) }
            let (histogram, stats) = ycbcr(luma: luma, width: 16, height: 16,
                                           chroma: [UInt8](repeating: 128, count: 128), step: 1, fullRange: fullRange)
            var expected = [UInt32](repeating: 0, count: 256)
            var sum = 0.0
            for value in 0..<256 {
                let reference = referenceYCbCr(y: UInt8(value), cb: 128, cr: 128, fullRange: fullRange)
                XCTAssertNotNil(reference, "no ties expected for neutral chroma")
                expected[reference?.luma ?? 0] += 1
                sum += reference?.mean ?? 0
            }
            XCTAssertEqual(histogram.luma, expected, "full range \(fullRange)")
            XCTAssertEqual(histogram.red, expected)
            XCTAssertEqual(stats.meanLuma, sum / 256, accuracy: 1e-12)
        }
    }

    func testBinTotalsEqualSampleCount() {
        var rng = SeededGenerator(seed: 5)
        let width = 33, height = 17
        let luma = (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let chroma = (0..<(17 * 2 * 9)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        for step in 1...4 {
            let (histogram, stats) = ycbcr(luma: luma, width: width, height: height, chroma: chroma,
                                           chromaWidth: 16, chromaHeight: 8, chromaRowBytes: 34, step: step, fullRange: false)
            let expectedSamples = ((width + step - 1) / step) * ((height + step - 1) / step)
            XCTAssertEqual(histogram.sampleCount, expectedSamples, "step \(step)")
            for channel in HistogramChannel.allCases {
                XCTAssertEqual(Int(histogram.bins(channel).reduce(0, +)), expectedSamples, "\(channel) step \(step)")
            }
            for value in [stats.meanLuma, stats.medianLuma, stats.clippedHighlights, stats.crushedShadows] {
                XCTAssertTrue(value >= 0 && value <= 1)
            }
        }
    }

    // MARK: - BGRA

    func testBGRAWhite() {
        let (histogram, stats) = bgra([UInt8](repeating: 255, count: 16), width: 2, height: 2, step: 1)
        for channel in HistogramChannel.allCases {
            XCTAssertEqual(histogram.bins(channel)[255], 4, "\(channel)")
        }
        XCTAssertEqual(histogram.sampleCount, 4)
        XCTAssertEqual(stats.meanLuma, 1, accuracy: 1e-12)
        XCTAssertEqual(stats.medianLuma, 1, accuracy: 1e-12)
        XCTAssertEqual(stats.clippedHighlights, 1)
        XCTAssertEqual(stats.crushedShadows, 0)
    }

    func testBGRAByteOrderAndWeights() {
        // B 10, G 20, R 30: luma = 0.2126 * 30 + 0.7152 * 20 + 0.0722 * 10 = 21.404.
        let (histogram, stats) = bgra([10, 20, 30, 0], width: 1, height: 1, step: 1)
        XCTAssertEqual(histogram.blue[10], 1)
        XCTAssertEqual(histogram.green[20], 1)
        XCTAssertEqual(histogram.red[30], 1)
        XCTAssertEqual(histogram.luma[21], 1)
        XCTAssertEqual(stats.meanLuma, 21.404 / 255, accuracy: 1e-12)
    }

    func testBGRAPureRedClipsThroughTheRedChannel() {
        let (histogram, stats) = bgra([0, 0, 255, 255], width: 1, height: 1, step: 1)
        XCTAssertEqual(histogram.luma[54], 1)   // 0.2126 * 255 = 54.21
        XCTAssertEqual(histogram.red[255], 1)
        XCTAssertEqual(histogram.green[0], 1)
        XCTAssertEqual(histogram.blue[0], 1)
        XCTAssertEqual(stats.clippedHighlights, 1)
        XCTAssertEqual(stats.meanLuma, 0.2126, accuracy: 1e-12)
    }

    func testBGRAClippingAndCrushingThresholds() {
        // R 252 alone clips, R 251 doesn't; black is crushed.
        let pixels: [UInt8] = [0, 0, 252, 255, 0, 0, 251, 255, 0, 0, 0, 255, 128, 128, 128, 255]
        let (histogram, stats) = bgra(pixels, width: 4, height: 1, step: 1)
        XCTAssertEqual(histogram.luma[128], 1)
        XCTAssertEqual(stats.clippedHighlights, 0.25, accuracy: 1e-12)
        XCTAssertEqual(stats.crushedShadows, 0.25, accuracy: 1e-12)
    }

    func testBGRAStepPaddingAndShortRows() {
        // 4 x 4 grays (value 10 * index) in rows of 20 bytes with white padding.
        var bytes = [UInt8](repeating: 255, count: 20 * 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let value = UInt8(10 * (y * 4 + x))
                for c in 0..<3 { bytes[y * 20 + 4 * x + c] = value }
            }
        }
        let (all, allStats) = bgra(bytes, width: 4, height: 4, rowBytes: 20, step: 1)
        XCTAssertEqual(all.sampleCount, 16)
        XCTAssertEqual(allStats.clippedHighlights, 0, "padding must not be sampled")
        let (two, _) = bgra(bytes, width: 4, height: 4, rowBytes: 20, step: 2)
        XCTAssertEqual(two.sampleCount, 4)
        for value in [0, 20, 80, 100] {
            XCTAssertEqual(two.luma[value], 1, "value \(value)")
            XCTAssertEqual(two.red[value], 1)
        }
        let (zero, _) = bgra(bytes, width: 4, height: 4, rowBytes: 20, step: 0)
        XCTAssertEqual(zero.sampleCount, 16)
        let (huge, _) = bgra(bytes, width: 4, height: 4, rowBytes: 20, step: Int.max)
        XCTAssertEqual(huge.sampleCount, 1)
        // bytesPerRow 8 holds only two pixels per row.
        let (short, _) = bgra(bytes, width: 4, height: 4, rowBytes: 8, step: 1)
        XCTAssertEqual(short.sampleCount, 8)
    }

    func testBGRAEmptyPlaneGivesEmptyResult() {
        for (width, height, rowBytes) in [(0, 1, 4), (1, 0, 4), (1, 1, 3)] {
            let (histogram, stats) = bgra([1, 2, 3, 4], width: width, height: height, rowBytes: rowBytes, step: 1)
            XCTAssertEqual(histogram, Histogram())
            XCTAssertEqual(stats, .empty)
        }
    }

    func testRandomBGRAMatchesDoubleReference() {
        var rng = SeededGenerator(seed: 99)
        var checked = 0
        while checked < 3_000 {
            let b = UInt8.random(in: 0...255, using: &rng)
            let g = UInt8.random(in: 0...255, using: &rng)
            let r = UInt8.random(in: 0...255, using: &rng)
            let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            // Exact .5 ties may round either way in Double, so leave them out.
            if abs(luma - luma.rounded(.down) - 0.5) < 1e-6 { continue }
            let (histogram, stats) = bgra([b, g, r, 255], width: 1, height: 1, step: 1)
            XCTAssertEqual(histogram.luma[Int(luma.rounded())], 1, "B \(b) G \(g) R \(r)")
            XCTAssertEqual(stats.meanLuma, luma / 255, accuracy: 1e-12)
            checked += 1
        }
    }

    // MARK: - Helpers

    /// Builds both planes from byte arrays. Chroma defaults to (width / 2) x (height / 2), at least 1 x 1,
    /// with tightly packed rows.
    private func ycbcr(luma: [UInt8], width: Int, height: Int, chroma: [UInt8],
                       chromaWidth: Int? = nil, chromaHeight: Int? = nil, chromaRowBytes: Int? = nil,
                       lumaRowBytes: Int? = nil, step: Int, fullRange: Bool) -> (Histogram, ExposureStats) {
        let cw = chromaWidth ?? max(width / 2, 1)
        let ch = chromaHeight ?? max(height / 2, 1)
        let lumaStorage = luma.isEmpty ? [UInt8(0)] : luma
        let chromaStorage = chroma.isEmpty ? [UInt8(0)] : chroma
        return lumaStorage.withUnsafeBytes { lumaRaw in
            chromaStorage.withUnsafeBytes { chromaRaw in
                let lumaPlane = PlaneView(base: lumaRaw.baseAddress!, width: width, height: height,
                                          bytesPerRow: lumaRowBytes ?? width)
                let chromaPlane = PlaneView(base: chromaRaw.baseAddress!, width: cw, height: ch,
                                            bytesPerRow: chromaRowBytes ?? 2 * cw)
                return HistogramComputer.compute(luma: lumaPlane, chroma: chromaPlane, step: step, fullRange: fullRange)
            }
        }
    }

    private func bgra(_ bytes: [UInt8], width: Int, height: Int, rowBytes: Int? = nil, step: Int) -> (Histogram, ExposureStats) {
        bytes.withUnsafeBytes { raw in
            let plane = PlaneView(base: raw.baseAddress!, width: width, height: height, bytesPerRow: rowBytes ?? 4 * width)
            return HistogramComputer.compute(bgra: plane, step: step)
        }
    }

    /// The documented decode in Double. nil when a value sits within 1e-6 of a .5 tie, where Double
    /// rounding error could pick either neighbour.
    private func referenceYCbCr(y: UInt8, cb: UInt8, cr: UInt8, fullRange: Bool)
        -> (luma: Int, red: Int, green: Int, blue: Int, mean: Double)? {
        let yp = fullRange ? Double(y) / 255 : (Double(y) - 16) / 219
        let cbp = (Double(cb) - 128) / (fullRange ? 255 : 224)
        let crp = (Double(cr) - 128) / (fullRange ? 255 : 224)
        let red = yp + 1.5748 * crp
        let green = yp - 0.1873 * cbp - 0.4681 * crp
        let blue = yp + 1.8556 * cbp
        var bins: [Int] = []
        for value in [min(max(yp, 0), 1), red, green, blue] {
            let scaled = min(max(value * 255, 0), 255)
            if abs(scaled - scaled.rounded(.down) - 0.5) < 1e-6 { return nil }
            bins.append(Int(scaled.rounded()))
        }
        return (bins[0], bins[1], bins[2], bins[3], min(max(yp, 0), 1))
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
