import Foundation

/// An 8-bit RGBA color. Overlay bitmaps store these premultiplied.
public struct RGBA8: Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let clear = RGBA8(r: 0, g: 0, b: 0, a: 0)
    public static let black = RGBA8(r: 0, g: 0, b: 0)
    public static let white = RGBA8(r: 255, g: 255, b: 255)
    public static let red = RGBA8(r: 255, g: 0, b: 0)
    public static let yellow = RGBA8(r: 255, g: 255, b: 0)
    public static let green = RGBA8(r: 0, g: 255, b: 0)
    public static let blue = RGBA8(r: 0, g: 0, b: 255)
    public static let magenta = RGBA8(r: 255, g: 0, b: 255)
    public static let cyan = RGBA8(r: 0, g: 255, b: 255)
    /// Violet rather than a dark purple, so crushed blacks stand out from the blue band above them.
    public static let purple = RGBA8(r: 128, g: 0, b: 255)
    public static let pink = RGBA8(r: 255, g: 105, b: 180)

    /// Same color with alpha `alpha`, color channels premultiplied (c * alpha / 255, rounded).
    /// The color is read as opaque: its current alpha is replaced, not multiplied in.
    public func premultiplied(alpha: UInt8) -> RGBA8 {
        RGBA8(r: Self.scale(r, by: alpha), g: Self.scale(g, by: alpha), b: Self.scale(b, by: alpha), a: alpha)
    }

    private static func scale(_ value: UInt8, by alpha: UInt8) -> UInt8 {
        // Adding 127 makes the integer division round to nearest; the result never exceeds 255.
        UInt8((Int(value) * Int(alpha) + 127) / 255)
    }
}

/// Premultiplied RGBA8, row-major, top-left origin, bytesPerRow = width * 4.
public struct RGBABitmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    /// Fully transparent. Negative sizes count as 0.
    public init(width: Int, height: Int) {
        let w = Swift.max(width, 0)
        let h = Swift.max(height, 0)
        let (area, areaOverflow) = w.multipliedReportingOverflow(by: h)
        let (bytes, bytesOverflow) = area.multipliedReportingOverflow(by: 4)
        // A size that can't be addressed becomes empty instead of trapping.
        if areaOverflow || bytesOverflow {
            self.width = 0
            self.height = 0
            self.pixels = []
        } else {
            self.width = w
            self.height = h
            self.pixels = [UInt8](repeating: 0, count: bytes)
        }
    }

    /// Out of range: get returns .clear, set is ignored.
    public subscript(x: Int, y: Int) -> RGBA8 {
        get {
            guard let i = byteOffset(x: x, y: y) else { return .clear }
            return RGBA8(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
        }
        set {
            guard let i = byteOffset(x: x, y: y) else { return }
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    /// Clockwise quarter turns (mod 4, negatives allowed). One turn: new width = old height,
    /// new(x', y') = old(x: y', y: oldHeight - 1 - x').
    public func rotated(quarterTurns: Int) -> RGBABitmap {
        let w = width
        let h = height
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return remapped(width: h, height: w, step: -w) { y in (h - 1) * w + y }
        case 2: return remapped(width: w, height: h, step: -1) { y in (h - 1 - y) * w + w - 1 }
        case 3: return remapped(width: h, height: w, step: w) { y in w - 1 - y }
        default: return self
        }
    }

    /// Left-right flip: new(x, y) = old(width - 1 - x, y).
    public func mirroredHorizontally() -> RGBABitmap {
        let w = width
        return remapped(width: w, height: height, step: -1) { y in y * w + w - 1 }
    }

    /// True when every alpha is 0, so drawing the bitmap would change nothing.
    public var isFullyTransparent: Bool {
        pixels.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return true }
            let count = buffer.count
            var i = 3
            while i < count {
                if p[i] != 0 { return false }
                i += 4
            }
            return true
        }
    }

    /// Pixel count, or nil when width, height and pixels disagree (all three are public and can drift apart).
    private var validPixelCount: Int? {
        guard width >= 0, height >= 0 else { return nil }
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, area <= pixels.count / 4 else { return nil }
        return area
    }

    private func byteOffset(x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height, validPixelCount != nil else { return nil }
        return (y * width + x) * 4
    }

    /// New bitmap whose row y copies source pixels rowStart(y), rowStart(y) + step, ... (pixel indices).
    private func remapped(width newWidth: Int, height newHeight: Int, step: Int, rowStart: (Int) -> Int) -> RGBABitmap {
        var result = RGBABitmap(width: newWidth, height: newHeight)
        guard validPixelCount != nil, !result.pixels.isEmpty else { return result }
        let byteStep = 4 * step
        pixels.withUnsafeBufferPointer { sourceBuffer in
            result.pixels.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let src = sourceBuffer.baseAddress, let dst = destinationBuffer.baseAddress else { return }
                var d = 0
                var y = 0
                while y < newHeight {
                    var s = 4 * rowStart(y)
                    var x = 0
                    while x < newWidth {
                        dst[d] = src[s]
                        dst[d + 1] = src[s + 1]
                        dst[d + 2] = src[s + 2]
                        dst[d + 3] = src[s + 3]
                        d += 4
                        s += byteStep
                        x += 1
                    }
                    y += 1
                }
            }
        }
        return result
    }
}

public enum PeakingColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case red, yellow, green, blue, white

    public var id: String { rawValue }

    public var rgba: RGBA8 {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .white: return .white
        }
    }

    public var title: String {
        switch self {
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .white: return "White"
        }
    }
}

public struct OverlayOptions: Hashable, Sendable {
    /// Luma 0...1; nil = off. Pixels at or above it get diagonal stripes.
    public var zebraThreshold: Double?
    /// Stripe period in overlay pixels, clamped >= 2.
    public var stripePeriod: Int
    /// Shifts the stripes; advance it over time to animate them.
    public var stripePhase: Int
    /// Normalized Sobel magnitude threshold (see `OverlayRenderer`); nil = off.
    public var peakingThreshold: Double?
    public var peakingColor: RGBA8
    public var falseColor: Bool

    public init(zebraThreshold: Double? = nil, stripePeriod: Int = 6, stripePhase: Int = 0,
                peakingThreshold: Double? = nil, peakingColor: RGBA8 = .red, falseColor: Bool = false) {
        self.zebraThreshold = zebraThreshold
        self.stripePeriod = Swift.max(stripePeriod, 2)
        self.stripePhase = stripePhase
        self.peakingThreshold = peakingThreshold
        self.peakingColor = peakingColor
        self.falseColor = falseColor
    }

    /// Nothing enabled, so rendering would produce a fully transparent bitmap.
    public var isEmpty: Bool {
        zebraThreshold == nil && peakingThreshold == nil && !falseColor
    }

    /// Maps a 0...1 UI sensitivity (clamped) to a peaking threshold: 0 -> 0.45 (only the crispest edges),
    /// 1 -> 0.08, linear in between.
    public static func peakingThreshold(sensitivity: Double) -> Double {
        // NaN reads as the least sensitive setting so a bad value can't flood the preview with edges.
        let s = sensitivity.isNaN ? 0 : Swift.min(Swift.max(sensitivity, 0), 1)
        // Weighted form hits both endpoints exactly.
        return 0.45 * (1 - s) + 0.08 * s
    }
}

public enum OverlayRenderer {
    /// Same size as `luma`, premultiplied. Layers, bottom to top, composited source-over:
    /// false color (alpha 200); zebra stripes, plain white at alpha 230, where luma >= zebraThreshold and
    /// ((x + y + stripePhase) mod period) < period / 2; peaking (peakingColor at alpha 255) where
    /// `sobelMagnitude` >= peakingThreshold.
    public static func render(_ luma: LumaImage, options: OverlayOptions) -> RGBABitmap {
        var bitmap = RGBABitmap(width: luma.width, height: luma.height)
        let width = bitmap.width
        let height = bitmap.height
        // pixels is public and may no longer match the size; draw nothing rather than read past the end.
        guard width > 0, height > 0, luma.pixels.count == width * height, !options.isEmpty else { return bitmap }

        let falseColorOn = options.falseColor
        let zebraOn = options.zebraThreshold != nil
        let zebraThreshold = options.zebraThreshold ?? 0
        let peakingOn = options.peakingThreshold != nil
        let peakingThreshold = options.peakingThreshold ?? 0
        let period = Swift.max(options.stripePeriod, 2)
        let litWidth = period / 2
        // Brought into 0..<period without forming phase + period, which overflows for a period near Int.max.
        var phase = options.stripePhase % period
        if phase < 0 {
            phase += period
        }
        let peak = options.peakingColor.premultiplied(alpha: 255)
        let palette = Self.palette
        // Rows widened to Double once each and kept three at a time (row r in slot r % 3): the Sobel sums then run
        // at the precision sobelMagnitude reports, for one conversion per pixel instead of one per neighbour read.
        var rows = [Double](repeating: 0, count: 3 * width)

        luma.pixels.withUnsafeBufferPointer { lumaBuffer in
            palette.withUnsafeBufferPointer { paletteBuffer in
                rows.withUnsafeMutableBufferPointer { rowBuffer in
                    bitmap.pixels.withUnsafeMutableBufferPointer { outBuffer in
                        guard let src = lumaBuffer.baseAddress, let colors = paletteBuffer.baseAddress,
                              let ring = rowBuffer.baseAddress, let out = outBuffer.baseAddress else { return }
                        var o = 0
                        var widened = 0
                        var y = 0
                        while y < height {
                            let below = y < height - 1 ? y + 1 : y
                            while widened <= below {
                                let from = src + widened * width
                                let to = ring + (widened % 3) * width
                                var i = 0
                                while i < width {
                                    to[i] = Double(from[i])
                                    i += 1
                                }
                                widened += 1
                            }
                            let mid = ring + (y % 3) * width
                            let up = y > 0 ? ring + ((y - 1) % 3) * width : mid
                            let down = y < height - 1 ? ring + ((y + 1) % 3) * width : mid
                            // (y + phase) mod period, again arranged so no intermediate sum can overflow.
                            var stripe = y % period
                            stripe = stripe < period - phase ? stripe + phase : stripe - (period - phase)
                            var x = 0
                            while x < width {
                                let v = mid[x]
                                // band(_:) and sobel(...) are written out below because a call per pixel costs about
                                // as much as this whole loop body in Debug builds (@inline(__always) is ignored there).
                                // OverlaysTests checks that both copies agree exactly.
                                var entry = 0
                                if falseColorOn && v == v {
                                    if v < 0.46 {
                                        if v < 0.10 {
                                            entry = v < 0.025 ? 2 : 4
                                        } else if v >= 0.38 {
                                            entry = 6
                                        }
                                    } else if v < 0.77 {
                                        if v >= 0.70 {
                                            entry = 8
                                        }
                                    } else if v >= 0.93 {
                                        entry = v < 0.99 ? 10 : 12
                                    }
                                }
                                if zebraOn && stripe < litWidth && v >= zebraThreshold {
                                    entry += 1
                                }
                                var marked = false
                                if peakingOn {
                                    let left = x > 0 ? x - 1 : x
                                    let right = x < width - 1 ? x + 1 : x
                                    let gx = (up[right] + 2 * mid[right] + down[right]) - (up[left] + 2 * mid[left] + down[left])
                                    let gy = (down[left] + 2 * down[x] + down[right]) - (up[left] + 2 * up[x] + up[right])
                                    marked = (gx * gx + gy * gy).squareRoot() / 4 >= peakingThreshold
                                }
                                if marked {
                                    out[o] = peak.r
                                    out[o + 1] = peak.g
                                    out[o + 2] = peak.b
                                    out[o + 3] = peak.a
                                } else {
                                    let c = colors + 4 * entry
                                    if c[3] != 0 {
                                        out[o] = c[0]
                                        out[o + 1] = c[1]
                                        out[o + 2] = c[2]
                                        out[o + 3] = c[3]
                                    }
                                }
                                o += 4
                                stripe += 1
                                if stripe == period {
                                    stripe = 0
                                }
                                x += 1
                            }
                            y += 1
                        }
                    }
                }
            }
        }
        return bitmap
    }

    /// IRE-style bands for luma 0...1: < 0.025 purple, < 0.10 blue, < 0.38 nil, < 0.46 green (middle gray),
    /// < 0.70 nil, < 0.77 pink (skin highlights), < 0.93 nil, < 0.99 yellow, else red. NaN gives nil.
    public static func falseColor(luma: Double) -> RGBA8? {
        bandColors[band(luma)]
    }

    /// Normalized Sobel magnitude at (x, y): sqrt(gx^2 + gy^2) / 4, computed in Double. For luma in 0...1 it
    /// peaks at sqrt(20) / 4 (about 1.12). Every sample position is clamped to the image (clamp-to-edge).
    /// Empty image gives 0.
    public static func sobelMagnitude(_ luma: LumaImage, x: Int, y: Int) -> Double {
        guard luma.width > 0, luma.height > 0 else { return 0 }
        // pixels is public and may no longer match the size; the clamped subscript would read past the end.
        let (area, overflow) = luma.width.multipliedReportingOverflow(by: luma.height)
        guard !overflow, luma.pixels.count == area else { return 0 }
        // Past one pixel outside, every sample clamps to the same edge pixels, so this keeps x - 1 and
        // x + 1 from overflowing without changing the result.
        let cx = Swift.min(Swift.max(x, -1), luma.width)
        let cy = Swift.min(Swift.max(y, -1), luma.height)
        return sobel(Double(luma[cx - 1, cy - 1]), Double(luma[cx, cy - 1]), Double(luma[cx + 1, cy - 1]),
                     Double(luma[cx - 1, cy]), Double(luma[cx + 1, cy]),
                     Double(luma[cx - 1, cy + 1]), Double(luma[cx, cy + 1]), Double(luma[cx + 1, cy + 1]))
    }

    // MARK: - Helpers

    /// Colors for band indices from `band(_:)`; index 0 is no band.
    private static let bandColors: [RGBA8?] = [nil, .purple, .blue, .green, .pink, .yellow, .red]

    /// 0 for no band (and NaN, which would otherwise fail every comparison and land in red), else 1...6.
    /// Split at 0.46 first so a pixel needs at most four comparisons; `render` repeats this shape inline.
    private static func band(_ luma: Double) -> Int {
        if luma.isNaN { return 0 }
        if luma < 0.46 {
            if luma < 0.10 { return luma < 0.025 ? 1 : 2 }
            return luma < 0.38 ? 0 : 3
        }
        if luma < 0.77 { return luma < 0.70 ? 0 : 4 }
        if luma < 0.93 { return 0 }
        return luma < 0.99 ? 5 : 6
    }

    /// Premultiplied bytes per band: entry 2 * band is the false color alone, 2 * band + 1 has the zebra
    /// white composited over it. Built once so the per-pixel loop only copies bytes.
    private static let palette: [UInt8] = {
        let zebra = RGBA8.white.premultiplied(alpha: 230)
        var bytes: [UInt8] = []
        for color in bandColors {
            let base = color?.premultiplied(alpha: 200) ?? .clear
            let striped = over(zebra, base)
            bytes += [base.r, base.g, base.b, base.a, striped.r, striped.g, striped.b, striped.a]
        }
        return bytes
    }()

    /// Source-over for premultiplied colors.
    private static func over(_ top: RGBA8, _ bottom: RGBA8) -> RGBA8 {
        let keep = 255 - Int(top.a)
        func mix(_ t: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(Swift.min(Int(t) + (Int(b) * keep + 127) / 255, 255))
        }
        return RGBA8(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a: mix(top.a, bottom.a))
    }

    /// Double, so the result carries Double rounding rather than Float's. Keep the operation order identical to
    /// the copy in `render` so both give the same bits: a pixel is marked exactly when this reaches the threshold.
    private static func sobel(_ topLeft: Double, _ top: Double, _ topRight: Double, _ left: Double, _ right: Double,
                              _ bottomLeft: Double, _ bottom: Double, _ bottomRight: Double) -> Double {
        let gx = (topRight + 2 * right + bottomRight) - (topLeft + 2 * left + bottomLeft)
        let gy = (bottomLeft + 2 * bottom + bottomRight) - (topLeft + 2 * top + topRight)
        return (gx * gx + gy * gy).squareRoot() / 4
    }
}
