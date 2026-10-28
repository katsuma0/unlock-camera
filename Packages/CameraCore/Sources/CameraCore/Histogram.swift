import Foundation

public enum HistogramChannel: String, Sendable, CaseIterable {
    case luma, red, green, blue
}

/// 256-bin counts per channel. Bin b holds values that round to b on a 0...255 scale.
public struct Histogram: Equatable, Sendable {
    public static let binCount = 256

    public var luma: [UInt32]
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    public var sampleCount: Int

    /// All zeros, 256 bins per channel.
    public init() {
        let zeros = [UInt32](repeating: 0, count: Histogram.binCount)
        luma = zeros
        red = zeros
        green = zeros
        blue = zeros
        sampleCount = 0
    }

    public func bins(_ channel: HistogramChannel) -> [UInt32] {
        switch channel {
        case .luma: return luma
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    /// Each bin divided by the channel's tallest bin (0...1), so the plot fills its height.
    /// compress takes square roots first, so dark tails stay visible next to a tall peak. All-zero gives zeros.
    public func normalized(_ channel: HistogramChannel, compress: Bool = true) -> [Float] {
        let values = bins(channel)
        var result = [Float](repeating: 0, count: values.count)
        var peak: UInt32 = 0
        for value in values where value > peak {
            peak = value
        }
        guard peak > 0 else { return result }
        let top = compress ? Double(peak).squareRoot() : Double(peak)
        for (index, value) in values.enumerated() {
            let v = Double(value)
            result[index] = Float((compress ? v.squareRoot() : v) / top)
        }
        return result
    }

    /// Sums runs of consecutive bins into `count` buckets (clamped 1...256) for drawing fewer, wider bars.
    /// When count doesn't divide the bin count, the last bucket takes the leftover bins.
    public func bucketed(_ channel: HistogramChannel, count: Int) -> [UInt32] {
        let values = bins(channel)
        let buckets = Swift.min(Swift.max(count, 1), Histogram.binCount)
        let size = values.count / buckets
        var result = [UInt32](repeating: 0, count: buckets)
        var start = 0
        for bucket in 0..<buckets {
            let end = bucket == buckets - 1 ? values.count : start + size
            // UInt64 so a sum past UInt32.max saturates instead of trapping.
            var sum: UInt64 = 0
            for index in start..<end {
                sum += UInt64(values[index])
            }
            result[bucket] = UInt32(clamping: sum)
            start = end
        }
        return result
    }
}

/// Exposure summary for the readout and clipping warnings.
public struct ExposureStats: Equatable, Sendable {
    /// 0...1, averaged from the sampled values (clamped) rather than the bins, so it isn't quantized.
    public var meanLuma: Double
    /// 0...1, from the luma histogram.
    public var medianLuma: Double
    /// Fraction of samples with luma >= 250, or any RGB channel >= 252 when RGB is known (0...255 scale).
    public var clippedHighlights: Double
    /// Fraction of samples with luma <= 4 (0...255 scale).
    public var crushedShadows: Double

    public init(meanLuma: Double, medianLuma: Double, clippedHighlights: Double, crushedShadows: Double) {
        self.meanLuma = meanLuma
        self.medianLuma = medianLuma
        self.clippedHighlights = clippedHighlights
        self.crushedShadows = crushedShadows
    }

    public static let empty = ExposureStats(meanLuma: 0, medianLuma: 0, clippedHighlights: 0, crushedShadows: 0)
}

public enum HistogramComputer {
    private static let clippedLumaBin = 250
    private static let clippedRGBBin = 252
    private static let crushedLumaBin = 4

    /// YCbCr 4:2:0 bi-planar: luma plane W x H (1 byte per pixel), chroma plane (W/2) x (H/2) of interleaved
    /// Cb, Cr bytes. Samples every `step` pixels in x and y, starting at (0, 0) (step < 1 counts as 1).
    /// BT.709 decode. Full range: Y' = Y / 255, C' = (C - 128) / 255. Video range: Y' = (Y - 16) / 219,
    /// C' = (C - 128) / 224. R = Y' + 1.5748 Cr', G = Y' - 0.1873 Cb' - 0.4681 Cr', B = Y' + 1.8556 Cb'.
    /// Bins are Y' * 255 and R, G, B * 255 rounded to nearest and clamped to 0...255. RGB uses the unclamped Y',
    /// as a real decode does; only the luma bins and mean clamp it. An empty chroma plane gives a luma-only
    /// result, as `compute(luma:)` does for a `LumaImage`.
    public static func compute(luma: PlaneView, chroma: PlaneView, step: Int, fullRange: Bool) -> (Histogram, ExposureStats) {
        let width = Swift.min(luma.width, luma.bytesPerRow)
        let height = luma.height
        guard width > 0, height > 0 else { return (Histogram(), .empty) }
        // Any step past the long side samples only (0, 0); capping it keeps x += stepSize from overflowing.
        let stepSize = Swift.min(Swift.max(step, 1), Swift.max(width, height))
        let tables = fullRange ? YCbCrTables.fullRange : YCbCrTables.videoRange
        let lumaRowBytes = luma.bytesPerRow
        let lumaBase = luma.base.assumingMemoryBound(to: UInt8.self)
        let chromaWidth = Swift.min(chroma.width, chroma.bytesPerRow / 2)
        let chromaHeight = chroma.height
        let hasChroma = chromaWidth > 0 && chromaHeight > 0

        // Slots 0..<256 count raw Y bytes until the loop ends, then hold luma bins; red, green, blue follow.
        var counts = [Int](repeating: 0, count: 4 * Histogram.binCount)
        var samples = 0
        var clipped: Int?
        if hasChroma {
            let chromaRowBytes = chroma.bytesPerRow
            let chromaBase = chroma.base.assumingMemoryBound(to: UInt8.self)
            let maxChromaX = chromaWidth - 1
            let maxChromaY = chromaHeight - 1
            let denominator = tables.denominator
            // A value plus half a bin at or above this lands past bin 255.
            let overflow = 256 * denominator
            // Locals, because reading a static inside the loop is an accessor call per sample in Debug builds.
            let lumaClip = clippedLumaBin
            let rgbClip = clippedRGBBin
            let result = tables.packed.withUnsafeBufferPointer { tableBuffer -> (Int, Int) in
                counts.withUnsafeMutableBufferPointer { countBuffer -> (Int, Int) in
                    guard let table = tableBuffer.baseAddress, let count = countBuffer.baseAddress else { return (0, 0) }
                    let redFromCr = table + 256
                    let greenFromCb = table + 512
                    let greenFromCr = table + 768
                    let blueFromCb = table + 1_024
                    let lumaBin = table + 1_280
                    var taken = 0
                    var hot = 0
                    var y = 0
                    while y < height {
                        let lumaRow = lumaBase + y * lumaRowBytes
                        let cy = y >> 1
                        let chromaRow = chromaBase + (cy < maxChromaY ? cy : maxChromaY) * chromaRowBytes
                        var x = 0
                        while x < width {
                            let yv = Int(lumaRow[x])
                            let cx = x >> 1
                            let pair = chromaRow + 2 * (cx < maxChromaX ? cx : maxChromaX)
                            let cb = Int(pair[0])
                            let cr = Int(pair[1])
                            let base = table[yv]
                            let r = base + redFromCr[cr]
                            let g = base + greenFromCb[cb] + greenFromCr[cr]
                            let b = base + blueFromCb[cb]
                            let rb = r < 0 ? 0 : (r >= overflow ? 255 : r / denominator)
                            let gb = g < 0 ? 0 : (g >= overflow ? 255 : g / denominator)
                            let bb = b < 0 ? 0 : (b >= overflow ? 255 : b / denominator)
                            count[yv] += 1
                            count[256 + rb] += 1
                            count[512 + gb] += 1
                            count[768 + bb] += 1
                            if lumaBin[yv] >= lumaClip || rb >= rgbClip || gb >= rgbClip || bb >= rgbClip {
                                hot += 1
                            }
                            taken += 1
                            x += stepSize
                        }
                        y += stepSize
                    }
                    return (taken, hot)
                }
            }
            samples = result.0
            clipped = result.1
        } else {
            samples = counts.withUnsafeMutableBufferPointer { countBuffer -> Int in
                guard let count = countBuffer.baseAddress else { return 0 }
                var taken = 0
                var y = 0
                while y < height {
                    let lumaRow = lumaBase + y * lumaRowBytes
                    var x = 0
                    while x < width {
                        count[Int(lumaRow[x])] += 1
                        taken += 1
                        x += stepSize
                    }
                    y += stepSize
                }
                return taken
            }
        }

        // Several Y bytes can share a bin (video range footroom and headroom), so remap after counting.
        var lumaBins = [Int](repeating: 0, count: Histogram.binCount)
        var lumaSum = 0.0
        for value in 0..<Histogram.binCount where counts[value] > 0 {
            lumaBins[tables.packed[1_280 + value]] += counts[value]
            lumaSum += Double(counts[value]) * tables.lumaValue[value]
        }
        counts.replaceSubrange(0..<Histogram.binCount, with: lumaBins)
        return finish(counts: counts, samples: samples, lumaSum: lumaSum, clippedSamples: clipped)
    }

    /// BGRA8 interleaved, sampled every `step` pixels in x and y (step < 1 counts as 1).
    /// Luma = Rec.709 weights on the 8-bit values, rounded to nearest for its bin.
    public static func compute(bgra: PlaneView, step: Int) -> (Histogram, ExposureStats) {
        let width = Swift.min(bgra.width, bgra.bytesPerRow / 4)
        let height = bgra.height
        guard width > 0, height > 0 else { return (Histogram(), .empty) }
        let stepSize = Swift.min(Swift.max(step, 1), Swift.max(width, height))
        let rowBytes = bgra.bytesPerRow
        let base = bgra.base.assumingMemoryBound(to: UInt8.self)
        let pixelStep = 4 * stepSize
        let rowEnd = 4 * width
        let lumaClip = clippedLumaBin
        let rgbClip = clippedRGBBin

        var counts = [Int](repeating: 0, count: 4 * Histogram.binCount)
        let (samples, clipped, lumaTotal) = counts.withUnsafeMutableBufferPointer { countBuffer -> (Int, Int, Int) in
            guard let count = countBuffer.baseAddress else { return (0, 0, 0) }
            var taken = 0
            var hot = 0
            // Luma x 10000 in integers: exact sums and exact round-half-up bins, with no float conversion per sample.
            var total = 0
            var y = 0
            while y < height {
                let row = base + y * rowBytes
                var p = 0
                while p < rowEnd {
                    let b = Int(row[p])
                    let g = Int(row[p + 1])
                    let r = Int(row[p + 2])
                    let scaled = 2_126 * r + 7_152 * g + 722 * b
                    let lb = (scaled + 5_000) / 10_000
                    total += scaled
                    count[lb] += 1
                    count[256 + r] += 1
                    count[512 + g] += 1
                    count[768 + b] += 1
                    if lb >= lumaClip || r >= rgbClip || g >= rgbClip || b >= rgbClip {
                        hot += 1
                    }
                    taken += 1
                    p += pixelStep
                }
                y += stepSize
            }
            return (taken, hot, total)
        }
        let lumaSum = Double(lumaTotal) / (255 * 10_000)
        return finish(counts: counts, samples: samples, lumaSum: lumaSum, clippedSamples: clipped)
    }

    /// Every pixel of a LumaImage. Only the luma channel is filled; RGB bins stay zero.
    /// Values are clamped to 0...1 (NaN counts as 0) for both the bins and the mean.
    public static func compute(luma image: LumaImage) -> (Histogram, ExposureStats) {
        guard image.width > 0, image.height > 0 else { return (Histogram(), .empty) }
        let (area, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        // pixels is public and may have been replaced; only read what is really there.
        let total = overflow ? image.pixels.count : Swift.min(area, image.pixels.count)
        guard total > 0 else { return (Histogram(), .empty) }

        var counts = [Int](repeating: 0, count: 4 * Histogram.binCount)
        let lumaSum = image.pixels.withUnsafeBufferPointer { pixelBuffer -> Double in
            counts.withUnsafeMutableBufferPointer { countBuffer -> Double in
                guard let src = pixelBuffer.baseAddress, let count = countBuffer.baseAddress else { return 0 }
                var sum = 0.0
                var i = 0
                while i < total {
                    // Double makes v * 255 + 0.5 exact, so bins round half up with no float error.
                    var v = Double(src[i])
                    // NaN fails v > 0 and so counts as black instead of trapping the Int conversion.
                    if !(v > 0) {
                        v = 0
                    } else if v > 1 {
                        v = 1
                    }
                    count[Int(v * 255 + 0.5)] += 1
                    sum += v
                    i += 1
                }
                return sum
            }
        }
        return finish(counts: counts, samples: total, lumaSum: lumaSum, clippedSamples: nil)
    }

    // MARK: - Helpers

    /// counts holds luma, red, green, blue bins (256 each). lumaSum is the sum of luma values in 0...1.
    /// clippedSamples is nil when RGB is unknown, so only the luma bins decide clipping.
    private static func finish(counts: [Int], samples: Int, lumaSum: Double, clippedSamples: Int?) -> (Histogram, ExposureStats) {
        var histogram = Histogram()
        histogram.sampleCount = samples
        for bin in 0..<Histogram.binCount {
            histogram.luma[bin] = UInt32(clamping: counts[bin])
            histogram.red[bin] = UInt32(clamping: counts[256 + bin])
            histogram.green[bin] = UInt32(clamping: counts[512 + bin])
            histogram.blue[bin] = UInt32(clamping: counts[768 + bin])
        }
        guard samples > 0 else { return (histogram, .empty) }

        var crushed = 0
        for bin in 0...crushedLumaBin {
            crushed += counts[bin]
        }
        var clipped = 0
        if let clippedSamples {
            clipped = clippedSamples
        } else {
            for bin in clippedLumaBin..<Histogram.binCount {
                clipped += counts[bin]
            }
        }
        let n = Double(samples)
        let stats = ExposureStats(
            meanLuma: Swift.min(Swift.max(lumaSum / n, 0), 1),
            medianLuma: medianBin(counts, total: samples) / 255,
            clippedHighlights: Double(clipped) / n,
            crushedShadows: Double(crushed) / n
        )
        return (histogram, stats)
    }

    /// Median of the binned luma values: the middle sample, or the mean of the two middle samples for an
    /// even count, so a frame split evenly between two tones reports the tone halfway between them.
    private static func medianBin(_ counts: [Int], total: Int) -> Double {
        let lowRank = (total - 1) / 2
        let highRank = total / 2
        var low = -1
        var seen = 0
        for bin in 0..<Histogram.binCount {
            seen += counts[bin]
            if low < 0 && seen > lowRank {
                low = bin
            }
            if seen > highRank {
                return Double(low + bin) / 2
            }
        }
        return Double(Swift.max(low, 0))
    }

    /// BT.709 decode as exact integers scaled by `denominator`, so every bin is the exact round-half-up of the
    /// documented formula: no float error can move a value across a bin edge.
    private struct YCbCrTables: Sendable {
        static let fullRange = YCbCrTables(fullRange: true)
        static let videoRange = YCbCrTables(fullRange: false)

        let denominator: Int
        /// Six runs of 256: Y' * 255 plus half a bin, Cr to red, Cb to green, Cr to green, Cb to blue, luma bin.
        let packed: [Int]
        /// Y' clamped to 0...1 per Y byte, for the mean.
        let lumaValue: [Double]

        init(fullRange: Bool) {
            let black = fullRange ? 0 : 16
            let lumaSpan = fullRange ? 255 : 219
            let chromaSpan = fullRange ? 255 : 224
            // Clears the 1 / lumaSpan and 1 / chromaSpan factors and the coefficients' four decimals.
            let denominator = 10_000 * lumaSpan * chromaSpan
            let half = denominator / 2
            var packed = [Int](repeating: 0, count: 6 * 256)
            var lumaValue = [Double](repeating: 0, count: 256)
            for v in 0..<256 {
                let lumaTerm = (v - black) * 255 * chromaSpan * 10_000
                let chromaTerm = (v - 128) * 255 * lumaSpan
                packed[v] = lumaTerm + half
                packed[256 + v] = 15_748 * chromaTerm
                packed[512 + v] = -1_873 * chromaTerm
                packed[768 + v] = -4_681 * chromaTerm
                packed[1_024 + v] = 18_556 * chromaTerm
                let rounded = lumaTerm + half
                packed[1_280 + v] = rounded < 0 ? 0 : Swift.min(rounded / denominator, 255)
                lumaValue[v] = Swift.min(Swift.max(Double(v - black) / Double(lumaSpan), 0), 1)
            }
            self.denominator = denominator
            self.packed = packed
            self.lumaValue = lumaValue
        }
    }
}
