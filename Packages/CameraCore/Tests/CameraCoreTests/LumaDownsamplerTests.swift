import XCTest
@testable import CameraCore

final class LumaDownsamplerTests: XCTestCase {
    // MARK: - Luma planes

    func testFactorOneFullRangeIsValueOver255() {
        let bytes: [UInt8] = [0, 1, 128, 200, 254, 255]
        let image = withPlane(bytes, width: 3, height: 2, bytesPerRow: 3) {
            LumaDownsampler.downsample($0, factor: 1, videoRange: false)
        }
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        for (index, byte) in bytes.enumerated() {
            XCTAssertEqual(image.pixels[index], Float(byte) / 255, accuracy: 1e-6)
        }
        XCTAssertEqual(image.pixels[0], 0)
        XCTAssertEqual(image.pixels[5], 1)
    }

    func testFactorTwoAveragesEachBlock() {
        let bytes: [UInt8] = [
            0, 10, 20, 30,
            40, 50, 60, 70,
            80, 90, 100, 110,
            120, 130, 140, 150,
        ]
        let image = withPlane(bytes, width: 4, height: 4, bytesPerRow: 4) {
            LumaDownsampler.downsample($0, factor: 2, videoRange: false)
        }
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image[0, 0], 25 / 255, accuracy: 1e-6)
        XCTAssertEqual(image[1, 0], 45 / 255, accuracy: 1e-6)
        XCTAssertEqual(image[0, 1], 105 / 255, accuracy: 1e-6)
        XCTAssertEqual(image[1, 1], 125 / 255, accuracy: 1e-6)
    }

    func testFractionalBlockMeanIsKept() {
        // Mean 0.5 of a byte: the box filter must not round to whole byte values.
        let bytes: [UInt8] = [10, 11]
        let image = withPlane(bytes, width: 2, height: 1, bytesPerRow: 2) {
            LumaDownsampler.downsample($0, factor: 2, videoRange: false)
        }
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.pixels[0], 10.5 / 255, accuracy: 1e-6)
    }

    func testFactorBelowOneCountsAsOne() {
        let bytes: [UInt8] = [5, 50, 150, 250]
        for factor in [0, -1, -3, Int.min] {
            let image = withPlane(bytes, width: 2, height: 2, bytesPerRow: 2) {
                LumaDownsampler.downsample($0, factor: factor, videoRange: false)
            }
            let reference = withPlane(bytes, width: 2, height: 2, bytesPerRow: 2) {
                LumaDownsampler.downsample($0, factor: 1, videoRange: false)
            }
            XCTAssertEqual(image, reference, "factor \(factor)")
        }
    }

    func testOutputSizeRoundsDownAndDropsLeftoverEdges() {
        // 5 x 3 at factor 2 gives 2 x 1; the last column and the last row fall outside every block.
        var bytes = [UInt8](repeating: 0, count: 15)
        for y in 0..<3 { bytes[y * 5 + 4] = 255 }
        for x in 0..<5 { bytes[2 * 5 + x] = 255 }
        let image = withPlane(bytes, width: 5, height: 3, bytesPerRow: 5) {
            LumaDownsampler.downsample($0, factor: 2, videoRange: false)
        }
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.pixels, [0, 0])
    }

    func testFactorLargerThanPlaneGivesOnePixelMean() {
        let bytes: [UInt8] = [0, 30, 60, 90, 120, 150]
        let image = withPlane(bytes, width: 3, height: 2, bytesPerRow: 3) {
            LumaDownsampler.downsample($0, factor: 8, videoRange: false)
        }
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.pixels[0], 75 / 255, accuracy: 1e-6)
    }

    func testFactorLargerThanOneAxisKeepsAtLeastOneRow() {
        // 10 x 2 at factor 4: two 4 x 2 blocks, columns 8 and 9 dropped.
        var bytes = [UInt8](repeating: 0, count: 20)
        for y in 0..<2 {
            for x in 0..<10 {
                bytes[y * 10 + x] = x < 4 ? 40 : (x < 8 ? 80 : 255)
            }
        }
        let image = withPlane(bytes, width: 10, height: 2, bytesPerRow: 10) {
            LumaDownsampler.downsample($0, factor: 4, videoRange: false)
        }
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.pixels[0], 40 / 255, accuracy: 1e-6)
        XCTAssertEqual(image.pixels[1], 80 / 255, accuracy: 1e-6)
    }

    func testEmptyPlaneGivesEmptyImage() {
        let bytes: [UInt8] = [1, 2, 3, 4]
        for (width, height) in [(0, 2), (2, 0), (0, 0), (-1, 2), (2, -1)] {
            let image = withPlane(bytes, width: width, height: height, bytesPerRow: 2) {
                LumaDownsampler.downsample($0, factor: 1, videoRange: false)
            }
            XCTAssertTrue(image.isEmpty, "\(width) x \(height)")
            XCTAssertTrue(image.pixels.isEmpty)
            let limited = withPlane(bytes, width: width, height: height, bytesPerRow: 2) {
                LumaDownsampler.downsample($0, maxLongSide: 1, videoRange: true)
            }
            XCTAssertTrue(limited.isEmpty)
        }
    }

    func testRowPaddingIsNeverRead() {
        // 2 x 2 pixels in rows of 4 bytes; the padding holds 255 and must not leak into the result.
        let bytes: [UInt8] = [0, 0, 255, 255, 0, 0, 255, 255]
        for factor in [1, 2] {
            let image = withPlane(bytes, width: 2, height: 2, bytesPerRow: 4) {
                LumaDownsampler.downsample($0, factor: factor, videoRange: false)
            }
            XCTAssertEqual(image.width, 2 / factor)
            XCTAssertTrue(image.pixels.allSatisfy { $0 == 0 }, "factor \(factor)")
        }
    }

    func testShortBytesPerRowNarrowsThePlane() {
        // An invalid bytesPerRow < width can't be read safely, so only bytesPerRow pixels per row are used.
        let bytes: [UInt8] = [10, 20, 30, 40]
        let image = withPlane(bytes, width: 4, height: 2, bytesPerRow: 2) {
            LumaDownsampler.downsample($0, factor: 1, videoRange: false)
        }
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.pixels[3], 40 / 255, accuracy: 1e-6)
    }

    func testVideoRangeMapsStudioSwingToUnitRange() {
        let bytes: [UInt8] = [16, 235, 125, 0, 255, 17]
        let image = withPlane(bytes, width: 6, height: 1, bytesPerRow: 6) {
            LumaDownsampler.downsample($0, factor: 1, videoRange: true)
        }
        XCTAssertEqual(image.pixels[0], 0)
        XCTAssertEqual(image.pixels[1], 1, accuracy: 1e-6)
        XCTAssertEqual(image.pixels[2], 109 / 219, accuracy: 1e-6)
        XCTAssertEqual(image.pixels[3], 0, "footroom clamps to black")
        XCTAssertEqual(image.pixels[4], 1, "headroom clamps to white")
        XCTAssertEqual(image.pixels[5], 1 / 219, accuracy: 1e-6)
    }

    func testVideoRangeMapsTheBlockMean() {
        // The range mapping applies to the block mean (16), not to each pixel (0 and 16/219).
        let bytes: [UInt8] = [0, 32]
        let image = withPlane(bytes, width: 2, height: 1, bytesPerRow: 2) {
            LumaDownsampler.downsample($0, factor: 2, videoRange: true)
        }
        XCTAssertEqual(image.pixels, [0])
    }

    func testFullRangeAndVideoRangeDifferForTheSameBytes() {
        let bytes: [UInt8] = [16, 235]
        let full = withPlane(bytes, width: 2, height: 1, bytesPerRow: 2) {
            LumaDownsampler.downsample($0, factor: 1, videoRange: false)
        }
        let video = withPlane(bytes, width: 2, height: 1, bytesPerRow: 2) {
            LumaDownsampler.downsample($0, factor: 1, videoRange: true)
        }
        XCTAssertEqual(full.pixels[0], 16 / 255, accuracy: 1e-6)
        XCTAssertEqual(full.pixels[1], 235 / 255, accuracy: 1e-6)
        XCTAssertEqual(video.pixels[0], 0)
        XCTAssertEqual(video.pixels[1], 1, accuracy: 1e-6)
    }

    func testRandomPlanesMatchReference() {
        var rng = SeededGenerator(seed: 7)
        for videoRange in [false, true] {
            for (width, height, rowBytes) in [(37, 23, 40), (16, 9, 16), (1, 5, 3), (64, 1, 64)] {
                let bytes = (0..<(rowBytes * height)).map { _ in UInt8.random(in: 0...255, using: &rng) }
                // 1...4 have their own loops; 5...9 cover the general loop with and without leftover bytes.
                for factor in 1...9 {
                    let image = withPlane(bytes, width: width, height: height, bytesPerRow: rowBytes) {
                        LumaDownsampler.downsample($0, factor: factor, videoRange: videoRange)
                    }
                    let expected = referenceLuma(bytes, width: width, height: height, rowBytes: rowBytes,
                                                 factor: factor, videoRange: videoRange)
                    XCTAssertEqual(image.width, expected.width)
                    XCTAssertEqual(image.height, expected.height)
                    for (got, want) in zip(image.pixels, expected.pixels) {
                        XCTAssertEqual(got, want, accuracy: 1e-6, "\(width)x\(height) factor \(factor)")
                    }
                }
            }
        }
    }

    func testOutputStaysInUnitRange() {
        var rng = SeededGenerator(seed: 11)
        let bytes = (0..<(48 * 32 * 4)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        for factor in 1...5 {
            let luma = withPlane(bytes, width: 48 * 4, height: 32, bytesPerRow: 48 * 4) {
                [LumaDownsampler.downsample($0, factor: factor, videoRange: false),
                 LumaDownsampler.downsample($0, factor: factor, videoRange: true)]
            }
            let bgra = withPlane(bytes, width: 48, height: 32, bytesPerRow: 48 * 4) {
                LumaDownsampler.downsampleBGRA($0, factor: factor)
            }
            for image in luma + [bgra] {
                XCTAssertTrue(image.pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
            }
        }
    }

    // MARK: - maxLongSide

    func testMaxLongSideChoosesCeilingFactor() {
        let bytes = (0..<(100 * 60)).map { UInt8($0 % 251) }
        let cases: [(limit: Int, factor: Int)] = [(25, 4), (30, 4), (33, 4), (34, 3), (50, 2), (99, 2), (100, 1), (1_000, 1)]
        for (limit, factor) in cases {
            let image = withPlane(bytes, width: 100, height: 60, bytesPerRow: 100) {
                LumaDownsampler.downsample($0, maxLongSide: limit, videoRange: false)
            }
            let expected = withPlane(bytes, width: 100, height: 60, bytesPerRow: 100) {
                LumaDownsampler.downsample($0, factor: factor, videoRange: false)
            }
            XCTAssertEqual(image, expected, "maxLongSide \(limit)")
            XCTAssertLessThanOrEqual(max(image.width, image.height), limit)
        }
    }

    func testMaxLongSideUsesTheTallerAxisForPortrait() {
        let bytes = [UInt8](repeating: 77, count: 30 * 90)
        let image = withPlane(bytes, width: 30, height: 90, bytesPerRow: 30) {
            LumaDownsampler.downsample($0, maxLongSide: 45, videoRange: false)
        }
        XCTAssertEqual(image.width, 15)
        XCTAssertEqual(image.height, 45)
        XCTAssertEqual(image.pixels[0], 77 / 255, accuracy: 1e-6)
    }

    func testMaxLongSideBelowOneCountsAsOne() {
        let bytes = (0..<(10 * 6)).map { UInt8($0) }
        let mean = Float(bytes.reduce(0) { $0 + Int($1) }) / Float(bytes.count) / 255
        for limit in [1, 0, -4, Int.min] {
            let image = withPlane(bytes, width: 10, height: 6, bytesPerRow: 10) {
                LumaDownsampler.downsample($0, maxLongSide: limit, videoRange: false)
            }
            XCTAssertEqual(image.width, 1, "maxLongSide \(limit)")
            XCTAssertEqual(image.height, 1)
            XCTAssertEqual(image.pixels[0], mean, accuracy: 1e-6)
        }
    }

    func testHugeMaxLongSideKeepsFullSize() {
        let bytes = [UInt8](repeating: 9, count: 12)
        let image = withPlane(bytes, width: 4, height: 3, bytesPerRow: 4) {
            LumaDownsampler.downsample($0, maxLongSide: Int.max, videoRange: false)
        }
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
    }

    // MARK: - BGRA

    func testBGRAUsesRec709Weights() {
        let cases: [(bgra: [UInt8], luma: Float)] = [
            ([255, 255, 255, 255], 1),
            ([0, 0, 0, 255], 0),
            ([0, 0, 255, 255], 0.2126),
            ([0, 255, 0, 255], 0.7152),
            ([255, 0, 0, 255], 0.0722),
            ([255, 255, 255, 0], 1),
            ([10, 20, 30, 99], (0.2126 * 30 + 0.7152 * 20 + 0.0722 * 10) / 255),
        ]
        for (bgra, luma) in cases {
            let image = withPlane(bgra, width: 1, height: 1, bytesPerRow: 4) {
                LumaDownsampler.downsampleBGRA($0, factor: 1)
            }
            XCTAssertEqual(image.width, 1)
            XCTAssertEqual(image.height, 1)
            XCTAssertEqual(image.pixels[0], luma, accuracy: 1e-6, "\(bgra)")
        }
    }

    func testBGRAWhiteIsExactlyOne() {
        let bytes = [UInt8](repeating: 255, count: 4 * 4 * 4)
        let image = withPlane(bytes, width: 4, height: 4, bytesPerRow: 16) {
            LumaDownsampler.downsampleBGRA($0, factor: 2)
        }
        XCTAssertEqual(image.pixels, [1, 1, 1, 1])
    }

    func testBGRABoxAveragesLuma() {
        // Red, green / blue, white: mean luma (0.2126 + 0.7152 + 0.0722 + 1) / 4 = 0.5.
        let bytes: [UInt8] = [
            0, 0, 255, 255, 0, 255, 0, 255,
            255, 0, 0, 255, 255, 255, 255, 255,
        ]
        let image = withPlane(bytes, width: 2, height: 2, bytesPerRow: 8) {
            LumaDownsampler.downsampleBGRA($0, factor: 2)
        }
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.pixels[0], 0.5, accuracy: 1e-6)
    }

    func testBGRARowPaddingIsNeverRead() {
        // 3 x 2 black pixels in rows of 16 bytes; the last 4 bytes of each row are white padding.
        var bytes = [UInt8](repeating: 0, count: 32)
        for row in 0..<2 {
            for i in 12..<16 { bytes[row * 16 + i] = 255 }
        }
        let image = withPlane(bytes, width: 3, height: 2, bytesPerRow: 16) {
            LumaDownsampler.downsampleBGRA($0, factor: 1)
        }
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.pixels, [Float](repeating: 0, count: 6))
    }

    func testBGRAShortBytesPerRowNarrowsThePlane() {
        let bytes = [UInt8](repeating: 255, count: 16)
        let image = withPlane(bytes, width: 4, height: 2, bytesPerRow: 8) {
            LumaDownsampler.downsampleBGRA($0, factor: 1)
        }
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
    }

    func testBGRAFactorRulesMatchLumaPlanes() {
        let bytes = [UInt8](repeating: 255, count: 5 * 3 * 4)
        for (factor, size) in [(0, (5, 3)), (-2, (5, 3)), (2, (2, 1)), (4, (1, 1)), (50, (1, 1))] {
            let image = withPlane(bytes, width: 5, height: 3, bytesPerRow: 20) {
                LumaDownsampler.downsampleBGRA($0, factor: factor)
            }
            XCTAssertEqual(image.width, size.0, "factor \(factor)")
            XCTAssertEqual(image.height, size.1, "factor \(factor)")
        }
    }

    func testBGRAEmptyPlaneGivesEmptyImage() {
        let bytes: [UInt8] = [1, 2, 3, 4]
        for (width, height, rowBytes) in [(0, 1, 4), (1, 0, 4), (1, 1, 3), (-1, 1, 4)] {
            let image = withPlane(bytes, width: width, height: height, bytesPerRow: rowBytes) {
                LumaDownsampler.downsampleBGRA($0, factor: 1)
            }
            XCTAssertTrue(image.isEmpty)
        }
    }

    func testRandomBGRAMatchesReference() {
        var rng = SeededGenerator(seed: 3)
        let width = 21, height = 13, rowBytes = 96
        let bytes = (0..<(rowBytes * height)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        for factor in 1...9 {
            let image = withPlane(bytes, width: width, height: height, bytesPerRow: rowBytes) {
                LumaDownsampler.downsampleBGRA($0, factor: factor)
            }
            let outWidth = width / factor
            let outHeight = height / factor
            XCTAssertEqual(image.width, outWidth)
            XCTAssertEqual(image.height, outHeight)
            for oy in 0..<outHeight {
                for ox in 0..<outWidth {
                    var sum = 0.0
                    for y in (oy * factor)..<((oy + 1) * factor) {
                        for x in (ox * factor)..<((ox + 1) * factor) {
                            let p = y * rowBytes + 4 * x
                            sum += 0.0722 * Double(bytes[p]) + 0.7152 * Double(bytes[p + 1]) + 0.2126 * Double(bytes[p + 2])
                        }
                    }
                    let expected = Float(sum / Double(factor * factor) / 255)
                    XCTAssertEqual(image[ox, oy], expected, accuracy: 1e-6)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Runs body with a PlaneView over bytes. The view must not escape the closure.
    private func withPlane<R>(_ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                              _ body: (PlaneView) -> R) -> R {
        // One byte of backing keeps baseAddress non-nil for the empty-plane cases.
        let storage = bytes.isEmpty ? [UInt8(0)] : bytes
        return storage.withUnsafeBytes { raw in
            body(PlaneView(base: raw.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow))
        }
    }

    /// Straightforward box filter in Double, for comparing against the optimized loops.
    private func referenceLuma(_ bytes: [UInt8], width: Int, height: Int, rowBytes: Int,
                               factor: Int, videoRange: Bool) -> LumaImage {
        let blockWidth = min(factor, width)
        let blockHeight = min(factor, height)
        let outWidth = width / blockWidth
        let outHeight = height / blockHeight
        var pixels: [Float] = []
        for oy in 0..<outHeight {
            for ox in 0..<outWidth {
                var sum = 0.0
                for y in (oy * blockHeight)..<((oy + 1) * blockHeight) {
                    for x in (ox * blockWidth)..<((ox + 1) * blockWidth) {
                        sum += Double(bytes[y * rowBytes + x])
                    }
                }
                let mean = sum / Double(blockWidth * blockHeight)
                let value = videoRange ? (mean - 16) / 219 : mean / 255
                pixels.append(Float(min(max(value, 0), 1)))
            }
        }
        return LumaImage(width: outWidth, height: outHeight, pixels: pixels)
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
