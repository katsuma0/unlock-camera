import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import os
import CameraCore

/// Builds night mode and long exposures from the video data output stream: frames are optionally aligned,
/// filtered for blur, and merged on the GPU with a CIImageAccumulator using the plan's blend.
final class StackedCaptureEngine: @unchecked Sendable {
    struct Configuration: Sendable {
        var plan: StackPlan
        var isBulb: Bool
        /// Frames timestamped before this were exposed with the old settings and are skipped.
        var startTime: CMTime
        /// Orientation that turns sensor-oriented frames upright in the final photo.
        var outputOrientation: CGImagePropertyOrientation
        /// Clockwise degrees and mirroring that put frames upright over the portrait preview.
        var previewRotation: Double
        var previewMirrored: Bool
    }

    let configuration: Configuration

    private let progress: @Sendable (StackProgress) -> Void
    private let startUptime: UInt64

    /// Guards `status`. Held for a few instructions at a time, so the main actor can read the flags freely.
    private let stateLock = NSLock()
    private var status = Status()

    /// Serializes accumulator work between the video queue and the final render. The main actor never waits
    /// on it, because merging one frame can keep it busy for several milliseconds.
    private let workLock = NSLock()
    private var accumulator: CIImageAccumulator?
    private var reference: LumaImage?
    private var keptSharpness: [Double] = []
    private var framesSeen = 0
    private var lastReportUptime: UInt64?
    private var preview: CGImage?
    private var previewIsCurrent = false

    private struct Status {
        var framesAccumulated = 0
        var isFinished = false
        var isCancelled = false
        var isDelivered = false
        var failure: String?
    }

    private enum FrameOutcome {
        case merged
        case rejected
        case skipped
        case failed(String)
    }

    /// `progress` is called from the video queue, at most about 8 times a second.
    init(configuration: Configuration, progress: @escaping @Sendable (StackProgress) -> Void) {
        self.configuration = configuration
        self.progress = progress
        self.startUptime = DispatchTime.now().uptimeNanoseconds
        // The first use sets up Metal, tens of milliseconds; better here than on the first frame.
        _ = Self.context
    }

    /// Video data queue. Feeds one frame. Returns true once no more frames are needed
    /// (plan complete, stopped early, or cancelled).
    func consume(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // Frames keep arriving after the end; answering from the flag keeps them from queueing behind the
        // final render.
        if isFinished { return true }
        let start = configuration.startTime
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if start.isNumeric, timestamp.isNumeric, CMTimeCompare(timestamp, start) < 0 { return false }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }

        let step = workLock.withLock { merge(pixelBuffer) }
        // Outside the lock, so a handler that calls back into the engine can't deadlock it. A cancel that
        // landed meanwhile already took the overlay down; a late report would bring it back.
        if let report = step.report, !isCancelled {
            progress(report)
        }
        return step.isDone
    }

    var isFinished: Bool { withStatus { $0.isFinished } }
    var isCancelled: Bool { withStatus { $0.isCancelled } }
    var framesAccumulated: Int { withStatus { $0.framesAccumulated } }

    /// Stop collecting and keep what is there.
    func finishEarly() {
        withStatus { $0.isFinished = true }
    }

    func cancel() {
        withStatus { status in
            status.isCancelled = true
            status.isFinished = true
        }
        // The accumulator is the size of a full frame in floats, so it goes now rather than with the engine,
        // but on another queue: a frame may be mid-merge, and the caller is usually the main actor.
        DispatchQueue.global(qos: .utility).async { [self] in
            workLock.withLock { releaseResources() }
        }
    }

    /// Final upright image cropped to `aspect`, after consume returned true. Call off the video queue.
    /// Delivers at most one image per stack. The accumulator goes once an image is delivered or the stack is
    /// cancelled. A render that fails keeps it, so the same frames can render again later: iOS refuses GPU work
    /// from a backgrounded app, and the stack is still whole once the app is back in front.
    func renderFinal(aspect: AspectRatio, noiseReduction: Double) throws -> CGImage {
        try workLock.withLock { try renderMerged(aspect: aspect, noiseReduction: noiseReduction) }
    }

    // MARK: - Work lock held

    private func renderMerged(aspect: AspectRatio, noiseReduction: Double) throws -> CGImage {
        let current = withStatus { status -> Status in
            status.isFinished = true
            return status
        }
        if current.isCancelled {
            releaseResources()
            throw CameraError.cancelled
        }
        if current.isDelivered {
            throw CameraError.captureFailed("The merged photo was already delivered.")
        }
        if let failure = current.failure {
            releaseResources()
            throw CameraError.captureFailed(failure)
        }
        guard let accumulator, current.framesAccumulated > 0 else {
            releaseResources()
            throw CameraError.captureFailed("No frames were captured.")
        }

        let plan = configuration.plan
        let extent = accumulator.extent
        let scale = plan.outputScale(framesAccumulated: current.framesAccumulated)
        var image = Self.scaled(accumulator.image(), by: scale)
        let strength = noiseReduction.isFinite ? min(max(noiseReduction, 0), 1) : 0
        if plan.purpose == .night, strength > 0 {
            image = Self.denoised(image, strength: strength, extent: extent)
        }
        if Self.needsRollOff(blend: plan.blend, scale: scale) {
            image = Self.rolledOff(image)
        }
        image = image.oriented(configuration.outputOrientation)
        let bounds = image.extent
        let crop = aspect.centeredCrop(width: Double(bounds.width), height: Double(bounds.height))
        let rendered = Self.renderPhoto(image, in: Self.pixelRect(crop, in: bounds))
        // The render leaves its uncached intermediates pooled until cleared, whatever the outcome.
        Self.context.clearCaches()
        let after = withStatus { status -> Status in
            if rendered != nil, !status.isCancelled {
                status.isDelivered = true
            }
            return status
        }
        // A full-size render takes a moment; a cancel that landed during it still means no photo.
        if after.isCancelled {
            releaseResources()
            throw CameraError.cancelled
        }
        guard let rendered else {
            // The frames stay for another try (see renderFinal); cancel() or the engine's release frees them.
            Self.log.error("Final render of \(current.framesAccumulated) stacked frames failed; they are kept")
            throw CameraError.captureFailed("Couldn't render the merged photo.")
        }
        // The photo is about to be encoded, which needs memory of its own, so the float buffer goes now.
        releaseResources()
        return rendered
    }

    private func merge(_ pixelBuffer: CVPixelBuffer) -> (isDone: Bool, report: StackProgress?) {
        let before = withStatus { $0 }
        if before.isFinished {
            if before.isCancelled { releaseResources() }
            return (true, nil)
        }

        framesSeen += 1
        let outcome = add(pixelBuffer, framesSoFar: before.framesAccumulated)
        let plan = configuration.plan
        let target = max(1, plan.frameCount)
        // Rejected or unusable frames don't count toward the plan, so a phone that keeps shaking would never
        // finish. Past twice the plan the stack ends with what it has.
        let seenLimit = target > Int.max / 2 ? Int.max : max(target * 2, target + 8)
        let seen = framesSeen
        let after = withStatus { status -> Status in
            switch outcome {
            case .merged:
                status.framesAccumulated += 1
            case .failed(let reason):
                status.failure = reason
                status.isFinished = true
            case .rejected, .skipped:
                break
            }
            if status.framesAccumulated >= target || seen >= seenLimit {
                status.isFinished = true
            }
            return status
        }

        if after.isCancelled {
            releaseResources()
            return (true, nil)
        }
        if case .failed(let reason) = outcome {
            Self.log.error("Stack stopped: \(reason, privacy: .public)")
            return (true, nil)
        }
        if case .merged = outcome {
            previewIsCurrent = false
        }
        // The last frame always reports, so the overlay ends on the full count.
        let report = makeReport(framesAccumulated: after.framesAccumulated, force: after.isFinished)
        return (after.isFinished, report)
    }

    private func add(_ pixelBuffer: CVPixelBuffer, framesSoFar: Int) -> FrameOutcome {
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = frame.extent
        guard !extent.isEmpty, !extent.isInfinite else { return .skipped }
        let plan = configuration.plan

        var luma: LumaImage?
        if plan.align || plan.rejectBlurryFrames,
           let measured = FrameAnalyzer.luma(of: pixelBuffer, maxLongSide: Tuning.lumaLongSide),
           !measured.isEmpty {
            luma = measured
        }

        var sharpness: Double?
        var shift = CGPoint.zero
        if let luma {
            if plan.rejectBlurryFrames {
                let score = FrameAlignment.sharpness(luma)
                if score.isFinite {
                    if keptSharpness.count >= Tuning.blurCheckAfterFrames,
                       score < Tuning.blurKeepFraction * Self.median(keptSharpness) {
                        return .rejected
                    }
                    sharpness = score
                }
            }
            if plan.align, let reference, reference.width == luma.width, reference.height == luma.height {
                let match = FrameAlignment.estimateTranslation(reference: reference, moving: luma)
                if match.confidence >= Tuning.minimumAlignmentConfidence, match.dx.isFinite, match.dy.isFinite {
                    // Per axis, because the luma's width and height are rounded separately when it is scaled.
                    let scaleX = Double(extent.width) / Double(luma.width)
                    let scaleY = Double(extent.height) / Double(luma.height)
                    // Whole sensor pixels: a fractional shift would resample, and soften, every frame.
                    shift = CGPoint(x: (-match.dx * scaleX).rounded(), y: (match.dy * scaleY).rounded())
                }
            }
        }

        // Only the first frame may create it: a fresh accumulator later would blend frames into nothing.
        if accumulator == nil, framesSoFar == 0 {
            guard let made = Self.makeAccumulator(extent: extent, blend: plan.blend) else {
                return .failed("There isn't enough memory to merge the frames.")
            }
            accumulator = made
        }
        // A format change mid-stack would mix two frame sizes; those frames can't join this stack.
        guard let accumulator, accumulator.extent == extent else { return .skipped }

        var aligned = frame
        if shift != .zero {
            // Core Image's y axis points up while the luma rows run down, hence the sign flip above.
            aligned = frame.transformed(by: CGAffineTransform(translationX: shift.x, y: shift.y))
                .clampedToExtent()
                .cropped(to: extent)
        }

        if framesSoFar == 0 {
            // A copy rather than a blend with the empty accumulator, so lighten keeps values below zero.
            accumulator.setImage(aligned)
        } else {
            guard let merged = Self.blended(aligned, into: accumulator.image(), blend: plan.blend,
                                            count: framesSoFar + 1) else { return .skipped }
            accumulator.setImage(merged.cropped(to: extent))
        }

        if let sharpness {
            keptSharpness.append(sharpness)
        }
        if plan.align, reference == nil, let luma {
            reference = luma
        }
        return .merged
    }

    private func makeReport(framesAccumulated count: Int, force: Bool) -> StackProgress? {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force, let last = lastReportUptime, now >= last, now - last < Tuning.reportInterval {
            return nil
        }
        lastReportUptime = now
        if !previewIsCurrent, let image = renderPreview(framesAccumulated: count) {
            preview = image
            previewIsCurrent = true
        }
        let plan = configuration.plan
        let isBulb = configuration.isBulb
        return StackProgress(
            framesCaptured: count,
            framesPlanned: isBulb ? 0 : max(1, plan.frameCount),
            elapsed: now > startUptime ? Double(now - startUptime) / 1e9 : 0,
            estimatedTotal: isBulb ? nil : plan.estimatedDuration(),
            preview: preview
        )
    }

    private func renderPreview(framesAccumulated count: Int) -> CGImage? {
        guard let accumulator, count > 0 else { return nil }
        var image = accumulator.image()
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        if longSide > Tuning.previewLongSide {
            let factor = Tuning.previewLongSide / longSide
            let shrink = CGAffineTransform(scaleX: factor, y: factor)
            // The filter reaches past the border; clamped, it reads edge pixels there instead of transparent black,
            // which would leave a dark, half-transparent rim around the preview.
            image = image.clampedToExtent()
                .transformed(by: shrink, highQualityDownsample: true)
                .cropped(to: extent.applying(shrink))
        }
        let scale = configuration.plan.outputScale(framesAccumulated: count)
        image = Self.scaled(image, by: scale)
        if Self.needsRollOff(blend: configuration.plan.blend, scale: scale) {
            image = Self.rolledOff(image)
        }
        image = image.oriented(Self.orientation(clockwiseDegrees: configuration.previewRotation))
        if configuration.previewMirrored {
            let bounds = image.extent
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.minX + bounds.maxX, ty: 0))
        }
        // The rendered CGImage is a copy, so the accumulator can change as soon as this returns.
        return Self.render(image, in: Self.pixelRect(inside: image.extent))
    }

    private func releaseResources() {
        accumulator = nil
        reference = nil
        keptSharpness = []
        preview = nil
        previewIsCurrent = false
    }

    private func withStatus<T>(_ body: (inout Status) -> T) -> T {
        stateLock.withLock { body(&status) }
    }

    // MARK: - Core Image

    private enum Tuning {
        static let lumaLongSide = 512
        static let blurKeepFraction = 0.6
        /// The median of fewer frames says too little about how sharp this scene can be.
        static let blurCheckAfterFrames = 3
        /// Below this the match barely beats the rest of the search window, so the shift is a guess, and a
        /// wrong shift smears more than none.
        static let minimumAlignmentConfidence = 0.1
        static let reportInterval: UInt64 = 150_000_000
        static let previewLongSide: CGFloat = 720
        static let gainTolerance = 1e-6
    }

    /// Highlight shoulder, in sRGB-encoded units so the table steps are finer than an 8-bit output step
    /// everywhere: identity up to the knee, then an exponential approach to white that reaches it at `upper`.
    private enum RollOff {
        static let knee = 0.9
        /// Colors outside sRGB dip below zero, further once gain scales them, and lookups clamp to the domain.
        /// Down to here the identity part passes them through untouched.
        static let lower = -2.0
        /// About 5x white in linear light. Brighter values clamp to white, which they are anyway.
        static let upper = 2.0
        static let entries = 2048

        static func value(_ x: Double) -> Double {
            guard x > knee else { return x }
            let span = 1 - knee
            let reach = 1 - exp(-(upper - knee) / span)
            return knee + span * (1 - exp(-(x - knee) / span)) / reach
        }

        static let table: Data = {
            var values = [Float32](repeating: 0, count: entries * 3)
            for index in 0..<entries {
                let x = lower + (upper - lower) * Double(index) / Double(entries - 1)
                let y = Float32(value(x))
                values[3 * index] = y
                values[3 * index + 1] = y
                values[3 * index + 2] = y
            }
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        }()
    }

    private static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    private static let curveSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)
    private static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// One context for every stack: creating one is expensive, and it is safe to share between threads.
    private static let context: CIContext = {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "StackedCaptureEngine"
        ]
        if let workingSpace {
            options[.workingColorSpace] = workingSpace
        }
        return CIContext(options: options)
    }()

    private static let log = Logger(subsystem: "ca.katsuma.openshutter", category: "Stacking")

    /// Float storage keeps a running mean of thousands of frames exact enough; half floats are the fallback
    /// for a device that refuses the larger buffer, and still hold a mean of a few hundred frames. A running
    /// maximum (lighten) only ever keeps one of its inputs and gathers no rounding error, so it starts with half
    /// floats: half the memory, and half the traffic of every merge, at up to 30 merges a second.
    private static func makeAccumulator(extent: CGRect, blend: StackBlend) -> CIImageAccumulator? {
        let formats: [CIFormat] = blend == .lighten ? [.RGBAh, .RGBAf] : [.RGBAf, .RGBAh]
        for format in formats {
            // With a color space the stored values are tagged, so reading them back can't be mismatched.
            if let workingSpace, let made = CIImageAccumulator(extent: extent, format: format, colorSpace: workingSpace) {
                return made
            }
            if let made = CIImageAccumulator(extent: extent, format: format) {
                return made
            }
        }
        log.error("No accumulator for \(Int(extent.width))x\(Int(extent.height)) frames")
        return nil
    }

    /// Average and additive keep the running mean acc + (frame - acc) / n; additive applies n at the end
    /// (StackPlan.outputScale). CIMix does that in one step on two opaque images, so alpha stays exactly 1.
    /// Adding two scaled copies with CIAdditionCompositing would sum the alphas as well, and every filter
    /// that unpremultiplies afterwards would divide the colors by that sum.
    private static func blended(_ frame: CIImage, into current: CIImage, blend: StackBlend, count: Int) -> CIImage? {
        switch blend {
        case .additive, .average:
            let mix = CIFilter.mix()
            mix.inputImage = frame
            mix.backgroundImage = current
            mix.amount = Float(1 / Double(max(count, 1)))
            return mix.outputImage
        case .lighten:
            let maximum = CIFilter.maximumCompositing()
            maximum.inputImage = frame
            maximum.backgroundImage = current
            return maximum.outputImage
        }
    }

    /// Multiplies RGB only. Alpha stays 1, so whether the filter unpremultiplies first makes no difference.
    private static func scaled(_ image: CIImage, by factor: Double) -> CIImage {
        guard factor.isFinite, factor > 0, factor != 1 else { return image }
        let value = CGFloat(factor)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? image
    }

    private static func denoised(_ image: CIImage, strength: Double, extent: CGRect) -> CIImage {
        let filter = CIFilter.noiseReduction()
        // Clamped edges stop the filter from pulling transparent black into the border pixels.
        filter.inputImage = image.clampedToExtent()
        filter.noiseLevel = Float(0.02 * strength)
        filter.sharpness = 0.4
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// Additive stacks and digital gain push light past white, which would otherwise clip hard. The night planner's
    /// gain of "1" can come out a rounding step above it, and that alone mustn't dim every white by the shoulder.
    private static func needsRollOff(blend: StackBlend, scale: Double) -> Bool {
        blend == .additive || scale > 1 + Tuning.gainTolerance
    }

    /// CIToneCurve only sees 0...1 before iOS 26, but the light that matters here sits above 1, so a color
    /// table over the real range rolls it off instead.
    private static func rolledOff(_ image: CIImage) -> CIImage {
        guard let curveSpace else { return image }
        let curves = CIFilter.colorCurves()
        curves.inputImage = image
        curves.curvesData = RollOff.table
        curves.curvesDomain = CIVector(x: CGFloat(RollOff.lower), y: CGFloat(RollOff.upper))
        curves.colorSpace = curveSpace
        return curves.outputImage ?? image
    }

    /// Renders now, not when the image is first drawn: the accumulator behind `image` changes with the next
    /// frame, and a deferred render would land on whichever thread draws it.
    private static func render(_ image: CIImage, in rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1, !rect.isInfinite else { return nil }
        guard let rendered = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: outputSpace,
                                                   deferred: false) else { return nil }
        return opaque(rendered)
    }

    /// The final photo goes through a render task rather than createCGImage, because only the task reports a GPU
    /// that refused the work, as iOS does for a backgrounded app. Saving whatever createCGImage handed back then
    /// would free the frames for an image that may hold nothing.
    private static func renderPhoto(_ image: CIImage, in rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1, !rect.isInfinite else { return nil }
        let width = Int(rect.width)
        let height = Int(rect.height)
        let bytesPerRow = width * 4
        guard let pixels = NSMutableData(length: bytesPerRow * height) else { return nil }
        let destination = CIRenderDestination(bitmapData: pixels.mutableBytes, width: width, height: height,
                                              bytesPerRow: bytesPerRow, format: .RGBA8)
        destination.colorSpace = outputSpace
        // CGImage rows run top down; only a flipped destination stores its top row first.
        destination.isFlipped = true
        do {
            _ = try context.startTask(toRender: image, from: rect, to: destination, at: .zero).waitUntilCompleted()
        } catch {
            log.error("Final render failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        // Opaque, so the alpha byte is skipped and the HEIF encoder stores no alpha plane (as in `opaque`).
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: outputSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// The render is opaque, so premultiplied and straight values are the same bytes. Re-tagging it as having
    /// no alpha, without copying, keeps the HEIF encoder from storing an alpha plane.
    private static func opaque(_ image: CGImage) -> CGImage {
        let skipped: CGImageAlphaInfo
        switch image.alphaInfo {
        case .premultipliedLast, .last:
            skipped = .noneSkipLast
        case .premultipliedFirst, .first:
            skipped = .noneSkipFirst
        default:
            return image
        }
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let space = image.colorSpace, space.model == .rgb,
              let provider = image.dataProvider else { return image }
        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let info = CGBitmapInfo(rawValue: byteOrder | skipped.rawValue)
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: image.renderingIntent) ?? image
    }

    /// Whole quarter turns only: anything else would tilt the frame inside its own bounds.
    private static func orientation(clockwiseDegrees degrees: Double) -> CGImagePropertyOrientation {
        guard degrees.isFinite else { return .up }
        // The remainder keeps Int(_:) far from values it would trap on.
        let turns = Int((degrees / 90).rounded().truncatingRemainder(dividingBy: 4))
        switch (turns + 4) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    /// The centred aspect crop, snapped to whole pixels and kept centred.
    private static func pixelRect(_ crop: CropRect, in bounds: CGRect) -> CGRect {
        let width = snappedDown(min(CGFloat(crop.width), bounds.width))
        let height = snappedDown(min(CGFloat(crop.height), bounds.height))
        guard width >= 1, height >= 1 else { return pixelRect(inside: bounds) }
        return CGRect(x: bounds.minX + ((bounds.width - width) / 2).rounded(.down),
                      y: bounds.minY + ((bounds.height - height) / 2).rounded(.down),
                      width: width, height: height)
    }

    /// Whole pixels inside `bounds`, so a scaled-down edge never renders as a half-transparent row.
    private static func pixelRect(inside bounds: CGRect) -> CGRect {
        let minX = snappedUp(bounds.minX)
        let minY = snappedUp(bounds.minY)
        let maxX = snappedDown(bounds.maxX)
        let maxY = snappedDown(bounds.maxY)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    /// Scaling leaves values like 539.9999; those mean 540, not 539.
    private static func snappedDown(_ value: CGFloat) -> CGFloat {
        let nearest = value.rounded()
        return abs(value - nearest) < 0.01 ? nearest : value.rounded(.down)
    }

    private static func snappedUp(_ value: CGFloat) -> CGFloat {
        let nearest = value.rounded()
        return abs(value - nearest) < 0.01 ? nearest : value.rounded(.up)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
