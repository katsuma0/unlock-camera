import Foundation

/// Shrinks camera planes into the small `LumaImage`s that histograms, overlays and frame alignment work on.
public enum LumaDownsampler {
    /// Box-filter downsample of an 8-bit luma plane by an integer factor (< 1 counts as 1).
    /// Output is (width / factor) x (height / factor) rounded down, at least 1x1 for a non-empty plane;
    /// leftover columns and rows at the right and bottom edges are dropped.
    /// videoRange maps 16...235 to 0...1 (clamped); otherwise value / 255.
    public static func downsample(_ plane: PlaneView, factor: Int, videoRange: Bool) -> LumaImage {
        // A row never holds more pixels than bytes, so a short bytesPerRow narrows the plane instead of overreading.
        let width = Swift.min(plane.width, plane.bytesPerRow)
        return boxFilter(plane, width: width, factor: factor, layout: .luma,
                         black: videoRange ? 16 : 0, span: videoRange ? 219 : 255)
    }

    /// Picks factor = ceil(max(width, height) / maxLongSide) so the long side ends up <= maxLongSide.
    /// maxLongSide < 1 counts as 1.
    public static func downsample(_ plane: PlaneView, maxLongSide: Int, videoRange: Bool) -> LumaImage {
        let limit = Swift.max(maxLongSide, 1)
        let longSide = Swift.max(plane.width, plane.height)
        // Spelled without (longSide + limit - 1), which overflows when limit is huge.
        let factor = longSide / limit + (longSide % limit > 0 ? 1 : 0)
        return downsample(plane, factor: factor, videoRange: videoRange)
    }

    /// Box-filter downsample of a BGRA8 interleaved plane (width in pixels, bytesPerRow >= 4 * width) to
    /// Rec.709 luma of the 8-bit values. Same size rules as `downsample(_:factor:videoRange:)`; alpha is ignored.
    public static func downsampleBGRA(_ plane: PlaneView, factor: Int) -> LumaImage {
        let width = Swift.min(plane.width, plane.bytesPerRow / 4)
        // Rows sum luma x 10000 with integer weights, so full scale is 255 x 10000 and white is exactly 1.
        return boxFilter(plane, width: width, factor: factor, layout: .bgra, black: 0, span: 2_550_000)
    }

    // MARK: - Helpers

    private enum Layout {
        case luma
        case bgra
    }

    /// Shared skeleton: sums each block row by row, then maps the block mean m to (m - black) / span, clamped.
    /// The mapping runs on the mean, so it costs one conversion per output pixel instead of one per input byte.
    private static func boxFilter(_ plane: PlaneView, width: Int, factor: Int, layout: Layout,
                                  black: Double, span: Double) -> LumaImage {
        let height = plane.height
        guard width > 0, height > 0 else { return LumaImage(width: 0, height: 0) }
        let f = Swift.max(factor, 1)
        // A factor larger than the plane still yields one pixel, averaging everything there is on that axis.
        let blockWidth = Swift.min(f, width)
        let blockHeight = Swift.min(f, height)
        let outWidth = width / blockWidth
        let outHeight = height / blockHeight
        let rowBytes = plane.bytesPerRow
        let area = Double(blockWidth * blockHeight)
        let blackSum = black * area
        let scale = 1 / (span * area)
        let src = plane.base.assumingMemoryBound(to: UInt8.self)

        var pixels = [Float](repeating: 0, count: outWidth * outHeight)
        var sums = [Int](repeating: 0, count: outWidth)
        pixels.withUnsafeMutableBufferPointer { outBuffer in
            sums.withUnsafeMutableBufferPointer { sumBuffer in
                guard let out = outBuffer.baseAddress, let sum = sumBuffer.baseAddress else { return }
                // while loops throughout: for-in over a range costs several times more per pixel in Debug builds.
                var oy = 0
                while oy < outHeight {
                    var ox = 0
                    while ox < outWidth {
                        sum[ox] = 0
                        ox += 1
                    }
                    var y = oy * blockHeight
                    let yEnd = y + blockHeight
                    while y < yEnd {
                        let row = src + y * rowBytes
                        switch layout {
                        case .luma: addLumaRow(row, into: sum, count: outWidth, blockWidth: blockWidth)
                        case .bgra: addBGRARow(row, into: sum, count: outWidth, blockWidth: blockWidth)
                        }
                        y += 1
                    }
                    let outRow = out + oy * outWidth
                    ox = 0
                    while ox < outWidth {
                        // Subtracting the black level first keeps black at exactly 0.
                        let value = (Double(sum[ox]) - blackSum) * scale
                        outRow[ox] = Float(value < 0 ? 0 : (value > 1 ? 1 : value))
                        ox += 1
                    }
                    oy += 1
                }
            }
        }
        return LumaImage(width: outWidth, height: outHeight, pixels: pixels)
    }

    /// Adds each block's byte sum for one row into `sums`. The common widths get loops of their own because in
    /// Debug builds a nested per-block loop costs more than the additions it performs.
    private static func addLumaRow(_ row: UnsafePointer<UInt8>, into sums: UnsafeMutablePointer<Int>,
                                   count: Int, blockWidth: Int) {
        var p = row
        var q = sums
        let end = sums + count
        switch blockWidth {
        case 1:
            while q < end {
                q.pointee += Int(p[0])
                p += 1
                q += 1
            }
        case 2:
            while q < end {
                q.pointee += Int(p[0]) + Int(p[1])
                p += 2
                q += 1
            }
        case 3:
            while q < end {
                q.pointee += Int(p[0]) + Int(p[1]) + Int(p[2])
                p += 3
                q += 1
            }
        case 4:
            while q < end {
                q.pointee += Int(p[0]) + Int(p[1]) + Int(p[2]) + Int(p[3])
                p += 4
                q += 1
            }
        default:
            while q < end {
                let blockEnd = p + blockWidth
                let quadEnd = blockEnd - 3
                var s = 0
                while p < quadEnd {
                    s += Int(p[0]) + Int(p[1]) + Int(p[2]) + Int(p[3])
                    p += 4
                }
                while p < blockEnd {
                    s += Int(p[0])
                    p += 1
                }
                q.pointee += s
                q += 1
            }
        }
    }

    /// Adds each block's Rec.709 luma x 10000 for one BGRA row into `sums`. The common widths sum each channel
    /// and weight once per block; the general loop keeps a single accumulator, since in Debug builds every
    /// extra local var costs a memory round trip per pixel.
    private static func addBGRARow(_ row: UnsafePointer<UInt8>, into sums: UnsafeMutablePointer<Int>,
                                   count: Int, blockWidth: Int) {
        var p = row
        var q = sums
        let end = sums + count
        switch blockWidth {
        case 2:
            while q < end {
                let b = Int(p[0]) + Int(p[4])
                let g = Int(p[1]) + Int(p[5])
                let r = Int(p[2]) + Int(p[6])
                q.pointee += 722 * b + 7_152 * g + 2_126 * r
                p += 8
                q += 1
            }
        case 3:
            while q < end {
                let b = Int(p[0]) + Int(p[4]) + Int(p[8])
                let g = Int(p[1]) + Int(p[5]) + Int(p[9])
                let r = Int(p[2]) + Int(p[6]) + Int(p[10])
                q.pointee += 722 * b + 7_152 * g + 2_126 * r
                p += 12
                q += 1
            }
        case 4:
            while q < end {
                let b = Int(p[0]) + Int(p[4]) + Int(p[8]) + Int(p[12])
                let g = Int(p[1]) + Int(p[5]) + Int(p[9]) + Int(p[13])
                let r = Int(p[2]) + Int(p[6]) + Int(p[10]) + Int(p[14])
                q.pointee += 722 * b + 7_152 * g + 2_126 * r
                p += 16
                q += 1
            }
        default:
            let blockBytes = 4 * blockWidth
            while q < end {
                let blockEnd = p + blockBytes
                var s = 0
                while p < blockEnd {
                    s += 722 * Int(p[0]) + 7_152 * Int(p[1]) + 2_126 * Int(p[2])
                    p += 4
                }
                q.pointee += s
                q += 1
            }
        }
    }
}
