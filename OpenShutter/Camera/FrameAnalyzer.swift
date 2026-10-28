import Foundation
import Accelerate
import CoreVideo
import CoreGraphics
import CameraCore

/// Turns preview frames into a histogram and the peaking / zebra / false color overlay.
/// Runs on the video data queue and limits itself to about 12 frames a second.
final class FrameAnalyzer: @unchecked Sendable {
    init() {}

    /// Thread-safe.
    func setOptions(_ options: AnalysisOptions) {
        lock.withLock { state.options = options }
    }

    /// Thread-safe. Clockwise degrees that rotate sensor-oriented frames to match the portrait preview,
    /// and whether the preview is mirrored (front camera).
    func setPreviewTransform(rotationDegrees: Double, mirrored: Bool) {
        let turns = Self.quarterTurns(rotationDegrees)
        lock.withLock {
            state.quarterTurns = turns
            state.mirrored = mirrored
        }
    }

    /// Video data queue. nil for frames it skips, or when nothing is enabled.
    func analyze(_ pixelBuffer: CVPixelBuffer) -> AnalysisFrame? {
        guard let pass = beginPass(at: DispatchTime.now().uptimeNanoseconds) else { return nil }
        defer { lock.withLock { state.isWorking = false } }

        let wantsOverlay = !pass.overlay.isEmpty
        guard let reading = measure(pixelBuffer, wantsLuma: wantsOverlay) else { return nil }

        var overlay: CGImage?
        if wantsOverlay, let luma = reading.luma, !luma.isEmpty {
            var bitmap = OverlayRenderer.render(luma, options: pass.overlay)
            // Nothing above the zebra level and no edges: skip the image so the preview composites nothing.
            if !bitmap.isFullyTransparent {
                if pass.quarterTurns != 0 {
                    bitmap = bitmap.rotated(quarterTurns: pass.quarterTurns)
                }
                if pass.mirrored {
                    bitmap = bitmap.mirroredHorizontally()
                }
                overlay = Self.makeImage(bitmap)
            }
        }
        return AnalysisFrame(histogram: reading.histogram, stats: reading.stats, overlay: overlay)
    }

    /// Luma of a 420 bi-planar (or BGRA) buffer, downsampled so the long side is at most `maxLongSide`.
    static func luma(of pixelBuffer: CVPixelBuffer, maxLongSide: Int) -> LumaImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let wideLuma = ByteBuffer()
        let resample = ByteBuffer()
        // The plane views point into these buffers, so they must outlive every read below.
        return withExtendedLifetime((wideLuma, resample)) { () -> LumaImage? in
            guard let planes = planes(of: pixelBuffer, wideLuma: wideLuma, wideChroma: nil) else { return nil }
            let image = lumaImage(from: planes, maxLongSide: maxLongSide, scratch: resample)
            return image.isEmpty ? nil : image
        }
    }

    /// Premultiplied RGBA8 bitmap to CGImage.
    static func makeImage(_ bitmap: RGBABitmap) -> CGImage? {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 0, height > 0 else { return nil }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, bitmap.pixels.count >= byteCount else { return nil }
        let data = bitmap.pixels.withUnsafeBufferPointer { buffer -> CFData? in
            guard let base = buffer.baseAddress else { return nil }
            return CFDataCreate(nil, base, byteCount)
        }
        guard let data, let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Per-frame work

    private struct State {
        var options = AnalysisOptions.off
        var quarterTurns = 0
        var mirrored = false
        /// Uptime in nanoseconds before which frames are skipped.
        var nextAnalysis: UInt64 = 0
        var stripePhase = 0
        /// A frame is being analyzed; the scratch buffers belong to it.
        var isWorking = false
    }

    private struct Pass {
        var overlay: OverlayOptions
        var quarterTurns: Int
        var mirrored: Bool
    }

    private struct Reading {
        var histogram: Histogram
        var stats: ExposureStats
        var luma: LumaImage?
    }

    private static let interval: UInt64 = 1_000_000_000 / 12
    private static let overlayLongSide = 480
    private static let histogramSamples = 40_000.0
    private static let stripePeriod = 6
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private let lock = NSLock()
    private var state = State()
    /// 10-bit planes narrowed to 8 bits, and the vImage resample target. Reused so a frame allocates nothing.
    private let wideLuma = ByteBuffer()
    private let wideChroma = ByteBuffer()
    private let resample = ByteBuffer()

    /// Claims the next analysis slot, or nil when the frame should be skipped. The zebra phase moves once
    /// per analysis, which animates the stripes at the analysis rate.
    private func beginPass(at now: UInt64) -> Pass? {
        lock.withLock { () -> Pass? in
            // A second caller arriving mid-analysis would share the scratch buffers, so it skips its frame.
            guard !state.options.isOff, !state.isWorking, now >= state.nextAnalysis else { return nil }
            state.nextAnalysis = now + Self.interval
            state.isWorking = true
            state.stripePhase = (state.stripePhase + 1) % Self.stripePeriod
            let options = state.options
            let overlay = OverlayOptions(
                zebraThreshold: options.zebraThreshold,
                stripePeriod: Self.stripePeriod,
                stripePhase: state.stripePhase,
                peakingThreshold: options.peakingThreshold,
                peakingColor: options.peakingColor.rgba,
                falseColor: options.falseColor
            )
            return Pass(overlay: overlay, quarterTurns: state.quarterTurns, mirrored: state.mirrored)
        }
    }

    /// Everything that reads the pixel buffer, so it stays locked only as long as needed. The histogram is
    /// always computed: it is cheap at ~40k samples and the clipping warning needs its stats.
    private func measure(_ pixelBuffer: CVPixelBuffer, wantsLuma: Bool) -> Reading? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        if !Self.isTenBit(CVPixelBufferGetPixelFormatType(pixelBuffer)) {
            // Back to 8-bit frames: give the 10-bit copies (12 MB at 4K) back.
            wideLuma.release()
            wideChroma.release()
        }
        guard let planes = Self.planes(of: pixelBuffer, wideLuma: wideLuma, wideChroma: wideChroma) else { return nil }

        let histogram: Histogram
        let stats: ExposureStats
        switch planes {
        case let .yCbCr(luma, chroma, fullRange):
            let step = Self.histogramStep(width: luma.width, height: luma.height)
            (histogram, stats) = HistogramComputer.compute(luma: luma, chroma: chroma, step: step, fullRange: fullRange)
        case let .bgra(plane):
            let step = Self.histogramStep(width: plane.width, height: plane.height)
            (histogram, stats) = HistogramComputer.compute(bgra: plane, step: step)
        }
        let luma = wantsLuma ? Self.lumaImage(from: planes, maxLongSide: Self.overlayLongSide, scratch: resample) : nil
        return Reading(histogram: histogram, stats: stats, luma: luma)
    }

    // MARK: - Plane access

    private enum Planes {
        /// 4:2:0 luma plus interleaved CbCr. The chroma view is empty when it was not read, which CameraCore
        /// treats as luma only.
        case yCbCr(luma: PlaneView, chroma: PlaneView, fullRange: Bool)
        case bgra(PlaneView)
    }

    /// Views of a locked pixel buffer in the 8-bit layouts CameraCore reads. 10-bit buffers (HDR and Log video)
    /// are narrowed into the scratch buffers first; their chroma is skipped when `wideChroma` is nil.
    /// nil for every other format, including the compressed ones the CPU can't read.
    private static func planes(of pixelBuffer: CVPixelBuffer, wideLuma: ByteBuffer, wideChroma: ByteBuffer?) -> Planes? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let luma = plane(of: pixelBuffer, index: 0, bytesPerPixel: 1) else { return nil }
            let chroma = plane(of: pixelBuffer, index: 1, bytesPerPixel: 2) ?? emptyPlane(at: luma.base)
            return .yCbCr(luma: luma, chroma: chroma, fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            guard let wide = plane(of: pixelBuffer, index: 0, bytesPerPixel: 2),
                  let luma = narrowed(wide, channels: 1, into: wideLuma) else { return nil }
            var chroma = emptyPlane(at: luma.base)
            if let wideChroma, let wideCbCr = plane(of: pixelBuffer, index: 1, bytesPerPixel: 4),
               let narrow = narrowed(wideCbCr, channels: 2, into: wideChroma) {
                chroma = narrow
            }
            return .yCbCr(luma: luma, chroma: chroma, fullRange: format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        case kCVPixelFormatType_32BGRA:
            guard !CVPixelBufferIsPlanar(pixelBuffer), let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard width > 0, height > 0, bytesPerRow >= 4 * width else { return nil }
            return .bgra(PlaneView(base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow))

        default:
            return nil
        }
    }

    private static func isTenBit(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    /// One plane with its width in pixels. Rejects planes whose rows are too short for their width,
    /// so nothing downstream can read past a row.
    private static func plane(of pixelBuffer: CVPixelBuffer, index: Int, bytesPerPixel: Int) -> PlaneView? {
        guard CVPixelBufferIsPlanar(pixelBuffer), index < CVPixelBufferGetPlaneCount(pixelBuffer),
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
        guard width > 0, height > 0, bytesPerRow >= width * bytesPerPixel else { return nil }
        return PlaneView(base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func emptyPlane(at base: UnsafeRawPointer) -> PlaneView {
        PlaneView(base: base, width: 0, height: 0, bytesPerRow: 0)
    }

    /// 16-bit samples (10 bits stored in the high bits) to 8-bit ones in `scratch`. vImage does the whole plane
    /// in a millisecond or two, where a Swift loop would take tens of milliseconds in a Debug build.
    private static func narrowed(_ wide: PlaneView, channels: Int, into scratch: ByteBuffer) -> PlaneView? {
        let samples = wide.width * channels
        let rowBytes = alignedRowBytes(samples)
        guard let output = scratch.reserve(rowBytes * wide.height) else { return nil }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: wide.base), height: vImagePixelCount(wide.height),
                                   width: vImagePixelCount(samples), rowBytes: wide.bytesPerRow)
        var destination = vImage_Buffer(data: output, height: vImagePixelCount(wide.height),
                                        width: vImagePixelCount(samples), rowBytes: rowBytes)
        guard vImageConvert_16UToPlanar8(&source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return PlaneView(base: UnsafeRawPointer(output), width: wide.width, height: wide.height, bytesPerRow: rowBytes)
    }

    // MARK: - Downsampling

    /// Luma with the long side at most `maxLongSide`, box filtered by CameraCore. Planes more than twice that
    /// size are first resampled by vImage to twice the target, so the Swift loop reads a few hundred kilobytes
    /// instead of a full 12 MP frame (which costs tens of milliseconds in Debug builds).
    private static func lumaImage(from planes: Planes, maxLongSide: Int, scratch: ByteBuffer) -> LumaImage {
        // Capped past any sensor size, which changes nothing, so `2 * limit` below can't overflow.
        let limit = min(max(maxLongSide, 1), 1 << 20)
        switch planes {
        case let .yCbCr(luma, _, fullRange):
            if let small = resampled(luma, bytesPerPixel: 1, limit: limit, scratch: scratch) {
                return LumaDownsampler.downsample(small, factor: 2, videoRange: !fullRange)
            }
            return LumaDownsampler.downsample(luma, maxLongSide: limit, videoRange: !fullRange)
        case let .bgra(plane):
            if let small = resampled(plane, bytesPerPixel: 4, limit: limit, scratch: scratch) {
                return LumaDownsampler.downsampleBGRA(small, factor: 2)
            }
            let longSide = max(plane.width, plane.height)
            let factor = longSide / limit + (longSide % limit > 0 ? 1 : 0)
            return LumaDownsampler.downsampleBGRA(plane, factor: factor)
        }
    }

    /// The plane scaled to twice the target size (aspect kept), or nil when it is already small enough or
    /// vImage declines, in which case the caller box filters the original.
    private static func resampled(_ plane: PlaneView, bytesPerPixel: Int, limit: Int, scratch: ByteBuffer) -> PlaneView? {
        let width = min(plane.width, plane.bytesPerRow / bytesPerPixel)
        let height = plane.height
        let longSide = max(width, height)
        guard width > 0, height > 0, longSide > 2 * limit else { return nil }
        let scale = Double(limit) / Double(longSide)
        let targetWidth = 2 * max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = 2 * max(1, Int((Double(height) * scale).rounded()))
        let rowBytes = alignedRowBytes(targetWidth * bytesPerPixel)
        guard let output = scratch.reserve(rowBytes * targetHeight) else { return nil }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: plane.base), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: plane.bytesPerRow)
        var destination = vImage_Buffer(data: output, height: vImagePixelCount(targetHeight),
                                        width: vImagePixelCount(targetWidth), rowBytes: rowBytes)
        let error = bytesPerPixel == 4
            ? vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
            : vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
        return PlaneView(base: UnsafeRawPointer(output), width: targetWidth, height: targetHeight, bytesPerRow: rowBytes)
    }

    // MARK: - Helpers

    /// Even, so every sample lands on the first luma pixel of its 2x2 chroma block.
    private static func histogramStep(width: Int, height: Int) -> Int {
        let area = Double(max(width, 0)) * Double(max(height, 0))
        let ideal = (area / histogramSamples).squareRoot()
        return max(2, 2 * Int((ideal / 2).rounded()))
    }

    /// Clockwise quarter turns for a rotation in degrees; anything that isn't a finite number counts as 0.
    private static func quarterTurns(_ degrees: Double) -> Int {
        guard degrees.isFinite else { return 0 }
        // Reduced before the Int conversion, which would trap on a huge value.
        let turns = (degrees / 90).rounded().truncatingRemainder(dividingBy: 4)
        return (Int(turns) + 4) % 4
    }

    /// Rows padded to 16 bytes, which vImage processes fastest.
    private static func alignedRowBytes(_ bytes: Int) -> Int {
        (bytes + 15) & ~15
    }
}

/// Raw memory that grows on demand and is reused across frames.
private final class ByteBuffer {
    private var pointer: UnsafeMutableRawPointer?
    private var capacity = 0

    /// At least `count` bytes, or nil for a size that can't be allocated.
    func reserve(_ count: Int) -> UnsafeMutableRawPointer? {
        guard count > 0 else { return nil }
        if let pointer, capacity >= count { return pointer }
        pointer?.deallocate()
        let fresh = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        pointer = fresh
        capacity = count
        return fresh
    }

    func release() {
        pointer?.deallocate()
        pointer = nil
        capacity = 0
    }

    deinit {
        pointer?.deallocate()
    }
}
