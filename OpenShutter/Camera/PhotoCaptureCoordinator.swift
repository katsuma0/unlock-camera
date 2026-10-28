import Foundation
import AVFoundation
import ImageIO
import UIKit
import CameraCore

/// Owns one capturePhoto(with:delegate:) call: builds the settings, collects every photo the output
/// delivers (processed, RAW, bracket frames, Live Photo movie), crops, saves to Photos, and reports.
/// CameraService keeps it alive until `completion` fires.
final class PhotoCaptureCoordinator: NSObject, AVCapturePhotoCaptureDelegate {
    let request: PhotoRequest

    private let focalLength35mm: Double
    private let willCapture: @MainActor () -> Void
    private let completion: @MainActor (Result<[CaptureResult], Error>) -> Void
    /// iOS suspends a backgrounded app within seconds, while processing, cropping and saving a shot taken just
    /// before leaving the app can take longer. Held from the request until the result is delivered, so it also
    /// covers the wait behind earlier photos' deliveries.
    private let backgroundTime = BackgroundTime()

    // AVFoundation calls the delegate on its own queue; the lock keeps the collected state consistent
    // even if callbacks for one request ever overlap.
    private let lock = NSLock()
    private var photos: [CapturedPhoto] = []
    private var livePhotoMovie: URL?
    private var firstError: Error?
    private var shutterDate: Date?
    private var announcedCapture = false
    private var finished = false

    /// - Parameters:
    ///   - lensName / focalLength35mm: for the summary line.
    ///   - willCapture: called on the main actor at the moment of exposure (flash + haptic).
    ///   - completion: called once, on the main actor, after everything is saved or failed.
    init(request: PhotoRequest, lensName: String, focalLength35mm: Double,
         willCapture: @escaping @MainActor () -> Void,
         completion: @escaping @MainActor (Result<[CaptureResult], Error>) -> Void) {
        self.request = request
        // The EXIF focal length wins when present because it includes zoom; the lens value covers the rest.
        // The lens name is not shown: localized device names are too long for the one-line summary.
        self.focalLength35mm = focalLength35mm
        self.willCapture = willCapture
        self.completion = completion
        super.init()
        let backgroundTime = self.backgroundTime
        Task { @MainActor in backgroundTime.begin() }
    }

    /// Output-level setup that needs a session reconfiguration (ProRAW, Live Photo, depth, max dimensions,
    /// max quality prioritization). Session queue, inside begin/commitConfiguration. Only enables what
    /// the output supports.
    static func configureOutput(_ output: AVCapturePhotoOutput, options: DeviceOptions, capabilities: CameraCapabilities) {
        // Each switch is only written when it changes, because every write can rebuild the render pipeline.
        // The order matters: ProRAW and depth change which of the later features the output supports.
        let proRAW = options.rawFormat == .proRAW && output.isAppleProRAWSupported
        if output.isAppleProRAWEnabled != proRAW { output.isAppleProRAWEnabled = proRAW }

        let device = sourceDevice(of: output)
        let depth = options.depth && output.isDepthDataDeliverySupported
            && depthAllowsZoom(device: device, zoomRange: capabilities.zoomRange)
        if output.isDepthDataDeliveryEnabled != depth { output.isDepthDataDeliveryEnabled = depth }

        // A Live Photo movie can't accompany a RAW shot (ProRAW refuses it outright), so the pipeline
        // isn't prepared for movies while RAW is on.
        let livePhoto = options.livePhoto && options.rawFormat == .none && output.isLivePhotoCaptureSupported
        if output.isLivePhotoCaptureEnabled != livePhoto { output.isLivePhotoCaptureEnabled = livePhoto }

        // Deferred delivery hands back proxies through a callback this coordinator doesn't take. Settled before
        // the size is picked, because it decides whether the 24 MP size is delivered as asked.
        if output.isAutoDeferredPhotoDeliveryEnabled { output.isAutoDeferredPhotoDeliveryEnabled = false }

        if let device,
           let dimensions = pickDimensions(options.photoResolution,
                                           from: serviceable(device.activeFormat.supportedMaxPhotoDimensions, output: output)),
           !sameDimensions(output.maxPhotoDimensions, dimensions) {
            output.maxPhotoDimensions = dimensions
        }

        if output.maxPhotoQualityPrioritization != .quality { output.maxPhotoQualityPrioritization = .quality }

        let contentAware = options.geometricCorrection && output.isContentAwareDistortionCorrectionSupported
        if output.isContentAwareDistortionCorrectionEnabled != contentAware {
            output.isContentAwareDistortionCorrectionEnabled = contentAware
        }

        // Preparing the constant color pipeline costs a rebuild, so it follows the setting instead of the hardware.
        let constantColor = output.isConstantColorSupported && options.constantColor
        if output.isConstantColorEnabled != constantColor { output.isConstantColorEnabled = constantColor }

        let zeroShutterLag = output.isZeroShutterLagSupported
        if output.isZeroShutterLagEnabled != zeroShutterLag { output.isZeroShutterLagEnabled = zeroShutterLag }
        // Responsive capture builds on zero shutter lag, so its support is read after that is settled.
        // Fast capture prioritization stays off: it would quietly lower the processing the user picked.
        let responsive = output.isResponsiveCaptureSupported
        if output.isResponsiveCaptureEnabled != responsive { output.isResponsiveCaptureEnabled = responsive }
    }

    /// Settings for `request` checked against what `output` supports right now. Unsupported extras
    /// (flash on a lens without one, RAW where none is available) are dropped, never passed through,
    /// because AVFoundation raises an exception for them. Session queue.
    static func makeSettings(for request: PhotoRequest, output: AVCapturePhotoOutput, capabilities: CameraCapabilities) throws -> AVCapturePhotoSettings {
        // capturePhoto raises when there is no live video connection to take the picture from.
        guard let connection = output.connection(with: .video), connection.isEnabled, connection.isActive else {
            throw CameraError.captureFailed("The camera isn't ready yet.")
        }
        let device = sourceDevice(of: output)
        // The output raises for any photo request while the device runs in a Log color space.
        if let device, isLogColorSpace(device) {
            throw CameraError.captureFailed("Photos can't be taken while the camera is set to Apple Log.")
        }

        let rawType = rawPixelFormat(for: request.rawFormat, output: output, device: device, connection: connection)
        var processed = processedFormat(for: request.processedFormat, quality: request.quality, output: output)
        if processed == nil && rawType == nil {
            // RAW alone was asked for but isn't possible right now (Bayer RAW while zoomed, a lens without RAW).
            // A HEIF beats a shutter press that saves nothing.
            processed = processedFormat(for: .heif, quality: request.quality, output: output)
        }
        guard processed != nil || rawType != nil else {
            throw CameraError.captureFailed("The camera offers no photo format right now.")
        }
        let isBayerRAW = rawType.map { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) } ?? false

        let bracketFrames = exposureBracket(for: request, output: output, device: device, capabilities: capabilities)
        let settings: AVCapturePhotoSettings
        if let bracketFrames {
            let bracket = AVCapturePhotoBracketSettings(rawPixelFormatType: rawType ?? 0, processedFormat: processed,
                                                        bracketedSettings: bracketFrames)
            if output.isLensStabilizationDuringBracketedCaptureSupported { bracket.isLensStabilizationEnabled = true }
            settings = bracket
        } else if let rawType, let processed {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processed)
        } else if let rawType {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        } else {
            settings = AVCapturePhotoSettings(format: processed)
        }
        let isBracket = bracketFrames != nil

        if let dimensions = photoDimensions(for: request.resolution, output: output, device: device) {
            settings.maxPhotoDimensions = dimensions
        }
        // Bayer RAW is the sensor readout itself; the output insists on the fastest prioritization for it.
        // Bracket frames must each keep their own exposure, which multi-frame fusion would blend away
        // (the stabilization switch this setting replaced is unsupported for brackets too).
        settings.photoQualityPrioritization = isBayerRAW || isBracket
            ? .speed
            : prioritization(for: request.processing, limit: output.maxPhotoQualityPrioritization)

        // Brackets don't take a flash mode at all; the default (off) is left alone for them.
        var flashCanFire = false
        if !isBracket, let mode = flashMode(for: request.flash), output.supportedFlashModes.contains(mode) {
            settings.flashMode = mode
            flashCanFire = mode != .off
        }
        if request.silentShutter && output.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }

        // Constant color fires the flash by design and raises without it, and RAW can't carry it. Apple warns
        // against it with locked white balance, where it would override the color the user set.
        let constantColor = request.constantColor && flashCanFire && rawType == nil && !isBracket
            && output.isConstantColorSupported && output.isConstantColorEnabled
            && device?.whiteBalanceMode != .locked
        if constantColor { settings.isConstantColorEnabled = true }

        // ProRAW switches content aware correction off by itself; Bayer RAW and brackets skip it to stay
        // on documented ground.
        let rawAllowsCorrection = rawType.map { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? true
        if request.contentAwareCorrection, rawAllowsCorrection, !isBracket, output.isContentAwareDistortionCorrectionEnabled {
            settings.isAutoContentAwareDistortionCorrectionEnabled = true
        }

        if request.livePhoto, rawType == nil, !isBracket, !constantColor,
           output.isLivePhotoCaptureEnabled, !output.isLivePhotoCaptureSuspended {
            settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenShutter-live-\(UUID().uuidString).mov")
        }

        // Depth is embedded in HEIF and JPEG only, so it rides on processed single shots. A cropped photo can't
        // keep it (its calibration describes the full frame), so the extra processing is skipped for those.
        if request.depth, rawType == nil, !isBracket, !constantColor, request.aspect.matches(.fourThree),
           output.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true
        }

        // Embedded previews give the result thumbnail without decoding a full 48 MP frame, and let Photos
        // show a RAW-only shot without a RAW develop. Width and height are given together, as required.
        if processed != nil, let codec = preferredThumbnailCodec(settings.availableEmbeddedThumbnailPhotoCodecTypes) {
            settings.embeddedThumbnailPhotoFormat = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: thumbnailPixelSize,
                AVVideoHeightKey: thumbnailPixelSize,
            ]
        }
        if rawType != nil, let codec = preferredThumbnailCodec(settings.availableRawEmbeddedThumbnailPhotoCodecTypes) {
            settings.rawEmbeddedThumbnailPhotoFormat = [AVVideoCodecKey: codec]
        }

        // GPS goes into the file itself as well as the Photos asset, so exported originals keep it.
        if let location = request.location, let gps = gpsMetadata(location) {
            var metadata = settings.metadata
            metadata[kCGImagePropertyGPSDictionary as String] = gps
            settings.metadata = metadata
        }
        return settings
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let isFirst = lock.withLock { () -> Bool in
            guard !announcedCapture else { return false }
            announcedCapture = true
            shutterDate = Date()
            return true
        }
        guard isFirst else { return }
        let willCapture = self.willCapture
        Task { @MainActor in willCapture() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            record(error)
            return
        }
        // Flattening now, rather than holding the AVCapturePhoto, lets the output recycle its buffers
        // before the next shot.
        guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
            record(CameraError.captureFailed("The camera returned no image data."))
            return
        }
        let captured = CapturedPhoto(data: data, isRaw: photo.isRawPhoto, sequence: photo.sequenceCount,
                                     facts: ExposureFacts(photo))
        lock.withLock { photos.append(captured) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard error == nil else {
            // Photos rejects an asset whose paired movie is damaged; the still is saved on its own instead.
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        lock.withLock { livePhotoMovie = outputFileURL }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let batch = lock.withLock { () -> Batch? in
            guard !finished else { return nil }
            finished = true
            let batch = Batch(photos: photos, movie: livePhotoMovie, error: firstError ?? error, date: shutterDate ?? Date())
            photos = []
            livePhotoMovie = nil
            return batch
        }
        guard let batch else { return }
        let request = self.request
        let focalLength = focalLength35mm
        let completion = self.completion
        let backgroundTime = self.backgroundTime
        // Cropping a 48 MP frame and waiting on Photos must not hold up the output's delegate queue.
        Self.deliveryLock.withLock {
            let previous = Self.lastDelivery
            Self.lastDelivery = Task.detached(priority: .userInitiated) {
                // Never throws or returns early, even if cancelled, so a queued photo can't lose its completion.
                await previous?.value
                let result = await Self.deliver(batch, request: request, focalLength35mm: focalLength)
                await MainActor.run {
                    completion(result)
                    backgroundTime.end()
                }
            }
        }
    }

    // MARK: - Delivery

    /// Deliveries run one at a time, in the order captures finish. A crop decodes the whole 48 MP frame (about
    /// 195 MB) before encoding and saving it, so overlapping photos would multiply that and compete for the CPU.
    private static let deliveryLock = NSLock()
    /// The newest delivery, which the next one waits for. Guarded by `deliveryLock`.
    nonisolated(unsafe) private static var lastDelivery: Task<Void, Never>?

    private func record(_ error: Error) {
        lock.withLock {
            if firstError == nil { firstError = error }
        }
    }

    /// Crops, saves and summarizes every asset of the batch. One asset per bracket frame; a RAW and a
    /// processed photo of the same frame become one asset with the DNG as its alternate resource.
    private static func deliver(_ batch: Batch, request: PhotoRequest, focalLength35mm: Double) async -> Result<[CaptureResult], Error> {
        defer {
            // Photos moves the movie on success; anything still there belongs to a failed save.
            if let movie = batch.movie { try? FileManager.default.removeItem(at: movie) }
        }
        let isBracket = batch.photos.contains { $0.sequence > 0 }
        var results: [CaptureResult] = []

        for (processed, raw) in pairedAssets(batch.photos) {
            let primary: EncodedImage
            if let processed {
                primary = prepare(processed.data, request: request)
            } else if let raw {
                // A DNG is never cropped: it is the sensor record, and editors apply their own crop.
                primary = unchanged(raw.data, fallbackType: rawTypeIdentifier)
            } else {
                continue
            }
            let pairedRaw = processed == nil ? nil : raw?.data
            let movie = !isBracket && processed != nil ? batch.movie : nil
            let outcome = await save(primary, raw: pairedRaw, movie: movie, location: request.location)

            let facts = (processed?.facts ?? ExposureFacts()).filled(from: raw?.facts)
            let kind: CaptureResult.Kind = isBracket ? .bracket : (raw != nil ? .raw : .photo)
            results.append(CaptureResult(kind: kind, assetIdentifier: outcome.identifier, thumbnail: primary.thumbnail,
                                         summary: summary(facts, fallbackFocalLength: focalLength35mm),
                                         date: batch.date, savedToLibrary: outcome.saved))
        }

        guard !results.isEmpty else {
            if let error = batch.error as? CameraError { return .failure(error) }
            let reason = batch.error?.localizedDescription ?? "The camera returned no photo."
            return .failure(CameraError.captureFailed(reason))
        }
        // A save that failed still returns its result, marked unsaved, so the model can tell the user.
        return .success(results)
    }

    private static func save(_ primary: EncodedImage, raw: Data?, movie: URL?, location: LocationStamp?) async -> (saved: Bool, identifier: String?) {
        do {
            let identifier = try await PhotoLibrary.savePhoto(primary: primary.data, primaryType: primary.typeIdentifier,
                                                              raw: raw, livePhotoMovie: movie, location: location)
            return (true, identifier)
        } catch {
            // Photos refuses the whole asset when the still and movie don't pair up; the still alone is
            // still worth keeping. Without add access a retry would only fail again.
            guard movie != nil, await PhotoLibrary.ensureAddAccess() else { return (false, nil) }
            return await save(primary, raw: raw, movie: nil, location: location)
        }
    }

    /// Processed and RAW photos grouped into assets, in capture order. The two halves of one frame share a
    /// bracket sequence number. Should an OS ever number every photo separately instead, the sets don't
    /// overlap and equal counts pair in delivery order. Anything unmatched is saved as its own asset.
    private static func pairedAssets(_ photos: [CapturedPhoto]) -> [(processed: CapturedPhoto?, raw: CapturedPhoto?)] {
        let processed = photos.filter { !$0.isRaw }.sorted { $0.sequence < $1.sequence }
        let raws = photos.filter { $0.isRaw }.sorted { $0.sequence < $1.sequence }
        if raws.isEmpty { return processed.map { (processed: $0, raw: nil) } }
        if processed.isEmpty { return raws.map { (processed: nil, raw: $0) } }
        if processed.count == raws.count,
           Set(processed.map(\.sequence)).isDisjoint(with: raws.map(\.sequence)) {
            return zip(processed, raws).map { (processed: $0, raw: $1) }
        }
        var rawsBySequence = Dictionary(grouping: raws, by: \.sequence)
        var assets: [(processed: CapturedPhoto?, raw: CapturedPhoto?)] = processed.map { photo in
            let partner = rawsBySequence[photo.sequence]?.first
            if partner != nil { rawsBySequence[photo.sequence]?.removeFirst() }
            return (processed: photo, raw: partner)
        }
        for leftover in rawsBySequence.values.joined().sorted(by: { $0.sequence < $1.sequence }) {
            assets.append((processed: nil, raw: leftover))
        }
        return assets
    }

    /// The photo cropped to the request's aspect, or as delivered when cropping fails: losing the shot
    /// over a crop would be worse than a 4:3 frame.
    private static func prepare(_ data: Data, request: PhotoRequest) -> EncodedImage {
        if let cropped = try? MediaWriter.crop(data, to: request.aspect, quality: request.quality) {
            return cropped
        }
        return unchanged(data, fallbackType: sniffedType(data))
    }

    /// The data as delivered, with its type, displayed size and thumbnail. MediaWriter documents a 4:3 crop as
    /// returning the data untouched, so it describes the file without re-encoding it. Data ImageIO can't parse
    /// keeps the fallback type and an unknown (zero) size; Photos is the final judge of whether it is usable.
    private static func unchanged(_ data: Data, fallbackType: String) -> EncodedImage {
        if let described = try? MediaWriter.crop(data, to: .fourThree, quality: 1) {
            return described
        }
        return EncodedImage(data: data, typeIdentifier: fallbackType, pixelSize: PixelSize(width: 0, height: 0), thumbnail: nil)
    }

    /// JPEG starts with FF D8 FF; everything else the output delivers here is HEIF.
    private static func sniffedType(_ data: Data) -> String {
        let jpegMagic: [UInt8] = [0xFF, 0xD8, 0xFF]
        return data.prefix(3).elementsEqual(jpegMagic) ? "public.jpeg" : "public.heic"
    }

    private static func summary(_ facts: ExposureFacts, fallbackFocalLength: Double) -> String {
        let exposure = MediaWriter.summary(exposureSeconds: facts.seconds ?? 0, iso: facts.iso ?? 0,
                                           aperture: facts.aperture ?? 0)
        let focal = facts.focalLength35mm ?? fallbackFocalLength
        guard focal.isFinite, focal > 0 else { return exposure }
        let lens = LensMath.focalLengthLabel(focal)
        return exposure.isEmpty ? lens : exposure + " \u{00B7} " + lens
    }

    // MARK: - Settings helpers

    /// Long side of result thumbnails, matching MediaWriter's.
    private static let thumbnailPixelSize = 400

    /// DNG; Photos wants this rather than the generic camera RAW type.
    private static let rawTypeIdentifier = "com.adobe.raw-image"

    private static func sourceDevice(of output: AVCapturePhotoOutput) -> AVCaptureDevice? {
        for connection in output.connections {
            for port in connection.inputPorts where port.mediaType == .video {
                if let input = port.input as? AVCaptureDeviceInput { return input.device }
            }
        }
        return nil
    }

    private static func processedFormat(for format: ProcessedFormat, quality: Double, output: AVCapturePhotoOutput) -> [String: Any]? {
        let preferred: [AVVideoCodecType]
        switch format {
        case .none: return nil
        case .heif: preferred = [.hevc, .jpeg]
        case .jpeg: preferred = [.jpeg, .hevc]
        }
        let available = output.availablePhotoCodecTypes
        guard let codec = preferred.first(where: { available.contains($0) }) else { return nil }
        let compression = quality.isFinite ? min(max(quality, 0), 1) : 0.9
        return [AVVideoCodecKey: codec, AVVideoCompressionPropertiesKey: [AVVideoQualityKey: compression]]
    }

    private static func rawPixelFormat(for format: RawFormat, output: AVCapturePhotoOutput, device: AVCaptureDevice?,
                                       connection: AVCaptureConnection) -> OSType? {
        guard format != .none else { return nil }
        let available = output.availableRawPhotoPixelFormatTypes
        if format == .proRAW, output.isAppleProRAWEnabled,
           let proRAW = available.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAW
        }
        // Without ProRAW (not enabled, or not on this lens) a Bayer DNG is still RAW. The output raises for
        // Bayer RAW at any zoom other than exactly 1, so a zoomed shot, or one taken mid zoom ramp, drops RAW.
        guard let device, device.videoZoomFactor == 1, !device.isRampingVideoZoom,
              connection.videoScaleAndCropFactor == 1 else { return nil }
        return available.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    /// JPEG previews open everywhere; otherwise the output's first (most compatible) choice.
    private static func preferredThumbnailCodec(_ codecs: [AVVideoCodecType]) -> AVVideoCodecType? {
        codecs.contains(.jpeg) ? .jpeg : codecs.first
    }

    /// The exposure bracket for the output, or nil for a single photo. Center frame first, symmetric,
    /// never longer than the output allows, every value inside the active format's limits.
    private static func exposureBracket(for request: PhotoRequest, output: AVCapturePhotoOutput, device: AVCaptureDevice?,
                                        capabilities: CameraCapabilities) -> [AVCaptureBracketedStillImageSettings]? {
        guard request.bracket.kind == .exposure, let device else { return nil }
        let offsets = request.bracket.exposureOffsets()
        var count = min(offsets.count, output.maxBracketedCapturePhotoCount)
        // Offsets come center first and then in pairs, so an odd prefix stays balanced around the metered shot.
        if count < offsets.count && count % 2 == 0 { count -= 1 }
        guard count >= 2 else { return nil }

        let format = device.activeFormat
        // Exposure target bias only steers auto exposure; locked or custom exposure ignores it, so those
        // brackets are built from explicit durations and ISOs around what the sensor is doing now.
        var base = request.bracketBase
        if base == nil && device.exposureMode != .continuousAutoExposure && device.exposureMode != .autoExpose {
            base = ExposureValues(seconds: device.exposureDuration.seconds, iso: Double(device.iso),
                                  aperture: Double(device.lensAperture))
        }
        if let base {
            return request.bracket.exposures(around: base, ranges: capabilities.exposure).prefix(count).map { values in
                AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: clampedDuration(values.seconds, for: format),
                    iso: clampedISO(values.iso, for: format)
                )
            }
        }
        let current = device.exposureTargetBias
        let lower = device.minExposureTargetBias
        let upper = device.maxExposureTargetBias
        return offsets.prefix(count).map { offset in
            let wanted = current + Float(offset)
            let bias = wanted.isFinite && lower <= upper
                ? min(max(wanted, lower), upper)
                : AVCaptureDevice.currentExposureTargetBias
            return AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: bias)
        }
    }

    /// Stays in CMTime for the final clamp so rounding can't land a hair outside the format's range.
    private static func clampedDuration(_ seconds: Double, for format: AVCaptureDevice.Format) -> CMTime {
        let lower = format.minExposureDuration
        let upper = format.maxExposureDuration
        // Without usable bounds nothing can be checked, so the frame keeps the current duration, which bracket
        // settings accept by documentation.
        guard lower.isNumeric, upper.isNumeric, CMTimeCompare(lower, upper) <= 0 else {
            return AVCaptureDevice.currentExposureDuration
        }
        guard seconds.isFinite, seconds > 0 else { return lower }
        let bounded = min(max(seconds, lower.seconds), upper.seconds)
        let time = CMTime(seconds: bounded, preferredTimescale: 1_000_000_000)
        return CMTimeMinimum(CMTimeMaximum(time, lower), upper)
    }

    private static func clampedISO(_ iso: Double, for format: AVCaptureDevice.Format) -> Float {
        let lower = format.minISO
        let upper = format.maxISO
        guard lower.isFinite, upper.isFinite, lower <= upper else { return AVCaptureDevice.currentISO }
        guard iso.isFinite else { return lower }
        return min(max(Float(iso), lower), upper)
    }

    /// The supported size for `resolution` that the output can deliver right now, or nil to keep the default.
    private static func photoDimensions(for resolution: PhotoResolution, output: AVCapturePhotoOutput,
                                        device: AVCaptureDevice?) -> CMVideoDimensions? {
        guard let device else { return nil }
        let limit = output.maxPhotoDimensions
        let allowed = serviceable(device.activeFormat.supportedMaxPhotoDimensions, output: output).filter {
            $0.width <= limit.width && $0.height <= limit.height
        }
        return pickDimensions(resolution, from: allowed)
    }

    /// Sizes the output delivers as asked. Apple documents 5712 x 4284 (24 MP) as serviced at that size only
    /// through deferred delivery, which stays off here so every photo can be cropped and saved by this
    /// coordinator; requesting it would quietly return a smaller photo instead.
    private static func serviceable(_ dimensions: [CMVideoDimensions], output: AVCapturePhotoOutput) -> [CMVideoDimensions] {
        guard !output.isAutoDeferredPhotoDeliveryEnabled else { return dimensions }
        return dimensions.filter { !($0.width == 5712 && $0.height == 4284) }
    }

    private static func isLogColorSpace(_ device: AVCaptureDevice) -> Bool {
        if device.activeColorSpace == .appleLog { return true }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return device.activeColorSpace == .appleLog2
        }
        #endif
        return false
    }

    /// Automatic takes the largest size. A megapixel choice takes the largest size not clearly above it
    /// (a "48 MP" sensor delivers 48.8), or the smallest when even that is bigger.
    private static func pickDimensions(_ resolution: PhotoResolution, from candidates: [CMVideoDimensions]) -> CMVideoDimensions? {
        let sorted = candidates
            .filter { $0.width > 0 && $0.height > 0 }
            .sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        guard let target = resolution.targetMegapixels else { return sorted.last }
        let limit = Double(target) * 1.1 * 1_000_000
        return sorted.last { Double(Int($0.width) * Int($0.height)) <= limit } ?? sorted.first
    }

    private static func sameDimensions(_ a: CMVideoDimensions, _ b: CMVideoDimensions) -> Bool {
        a.width == b.width && a.height == b.height
    }

    private static func prioritization(for level: ProcessingLevel,
                                       limit: AVCapturePhotoOutput.QualityPrioritization) -> AVCapturePhotoOutput.QualityPrioritization {
        let wanted: AVCapturePhotoOutput.QualityPrioritization
        switch level {
        case .minimal: wanted = .speed
        case .balanced: wanted = .balanced
        case .maximum: wanted = .quality
        }
        return wanted.rawValue <= limit.rawValue ? wanted : limit
    }

    private static func flashMode(for setting: FlashSetting) -> AVCaptureDevice.FlashMode? {
        switch setting {
        case .off: return nil
        case .auto: return .auto
        case .on: return .on
        }
    }

    /// Reuses MediaWriter's GPS dictionary so files from every path carry the same tags.
    private static func gpsMetadata(_ location: LocationStamp) -> Any? {
        let metadata = CaptureMetadata(exposureSeconds: 0, iso: 0, aperture: 0, focalLength35mm: nil, lensModel: "",
                                       comment: nil, date: location.timestamp, location: location)
        return MediaWriter.properties(for: metadata)[kCGImagePropertyGPSDictionary]
    }

    /// Depth delivery limits zoom on some formats: only listed factors are legal and any other raises.
    /// Depth stays off unless every zoom the app can set remains legal with it.
    private static func depthAllowsZoom(device: AVCaptureDevice?, zoomRange: ClosedRange<Double>) -> Bool {
        guard let device else { return false }
        let format = device.activeFormat
        if format.zoomFactorsOutsideOfVideoZoomRangesForDepthDeliverySupported { return true }
        let ranges = format.supportedVideoZoomRangesForDepthDataDelivery
        if ranges.isEmpty { return true }
        let lower = min(Double(device.minAvailableVideoZoomFactor), zoomRange.lowerBound)
        let upper = max(min(Double(device.maxAvailableVideoZoomFactor), Double(format.videoMaxZoomFactor), 15), zoomRange.upperBound)
        return ranges.contains { Double($0.lowerBound) <= lower + 0.001 && Double($0.upperBound) >= upper - 0.001 }
    }
}

// MARK: - Private types

/// A UIKit background task that ends exactly once. `end` may run before `begin` when both are queued on the main
/// actor; the late `begin` then does nothing instead of holding the app awake until iOS cuts it off.
private final class BackgroundTime: @unchecked Sendable {
    /// Main actor only.
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var isFinished = false

    @MainActor func begin() {
        guard identifier == .invalid, !isFinished else { return }
        // Captured strongly: if the coordinator is gone when time runs out, the task must still end, or iOS
        // terminates the app.
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save photo") {
            // Out of time: the save resumes when the app comes back.
            self.end()
        }
    }

    @MainActor func end() {
        isFinished = true
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// One flattened photo from the output, with the exposure it was taken at.
private struct CapturedPhoto: Sendable {
    var data: Data
    var isRaw: Bool
    /// 1-based bracket position, 0 for a single shot.
    var sequence: Int
    var facts: ExposureFacts
}

/// Everything a finished capture produced, handed to the background save.
private struct Batch: Sendable {
    var photos: [CapturedPhoto]
    var movie: URL?
    var error: Error?
    var date: Date
}

/// Exposure values for the summary line, from the photo's EXIF.
private struct ExposureFacts: Sendable {
    var seconds: Double?
    var iso: Double?
    var aperture: Double?
    var focalLength35mm: Double?

    init() {}

    init(_ photo: AVCapturePhoto) {
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        seconds = Self.positive(exif?[kCGImagePropertyExifExposureTime as String])
        iso = Self.positive((exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first)
        aperture = Self.positive(exif?[kCGImagePropertyExifFNumber as String])
        focalLength35mm = Self.positive(exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String])
        // A bracket frame's EXIF is the authority, but its own settings say the same when EXIF is thin.
        if let frame = photo.bracketSettings as? AVCaptureManualExposureBracketedStillImageSettings {
            if seconds == nil, frame.exposureDuration.isNumeric { seconds = Self.positive(frame.exposureDuration.seconds) }
            if iso == nil { iso = Self.positive(Double(frame.iso)) }
        }
    }

    /// Fields this photo lacks, taken from its RAW or processed partner.
    func filled(from other: ExposureFacts?) -> ExposureFacts {
        guard let other else { return self }
        var result = self
        result.seconds = seconds ?? other.seconds
        result.iso = iso ?? other.iso
        result.aperture = aperture ?? other.aperture
        result.focalLength35mm = focalLength35mm ?? other.focalLength35mm
        return result
    }

    private static func positive(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let value as Double: number = value
        case let value as NSNumber: number = value.doubleValue
        default: number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }
}
