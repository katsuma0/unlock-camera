import Foundation
import AVFoundation
import CoreMedia
import CameraCore

/// Reads what the active device, its format and the session's outputs can do into CameraCapabilities.
/// Every range here is what the crash-safe clamps elsewhere compare against, so the values are taken
/// straight from AVFoundation and only ever rounded toward the inside.
enum CapabilitiesBuilder {
    /// Session queue, with the device's input and the outputs already committed to the session (the photo
    /// output only reports RAW, Live Photo and depth support once it is connected to a camera).
    /// - Parameters:
    ///   - formats: descriptors of `device.formats`, cached by the caller because they never change.
    ///   - movieOutput: pass it only while it is part of the session.
    ///   - bayerRAWHint: Bayer RAW support measured while ProRAW was off. With ProRAW enabled the output
    ///     lists only ProRAW pixel formats, so the earlier measurement stands in.
    static func build(device: AVCaptureDevice, lens: LensInfo, formats: [FormatDescriptor],
                      photoOutput: AVCapturePhotoOutput?, movieOutput: AVCaptureMovieFileOutput?,
                      bayerRAWHint: Bool?) -> CameraCapabilities {
        let format = device.activeFormat
        let aperture = apertureInfo(device: device, format: format)
        let exposure = ExposureRanges(
            seconds: secondsRange(of: format),
            iso: isoRange(of: format),
            aperture: aperture.range,
            maxAutoSeconds: seconds(device.activeMaxExposureDuration, rounding: .down)
        )
        let customExposure = device.isExposureModeSupported(.custom)

        return CameraCapabilities(
            lens: lens,
            formatSummary: summary(of: format),
            exposure: exposure,
            biasRange: biasRange(of: device),
            supportsCustomExposure: customExposure,
            supportsVariableAperture: aperture.variable,
            apertureStops: aperture.stops,
            nativePriority: customExposure ? nativePriority(format: format, variableAperture: aperture.variable) : .none,
            supportsManualFocus: device.isLockingFocusWithCustomLensPositionSupported && device.isFocusModeSupported(.locked),
            supportsFocusPointOfInterest: device.isFocusPointOfInterestSupported,
            supportsExposurePointOfInterest: device.isExposurePointOfInterestSupported,
            supportsMeteringArea: meteringAreaSupported(device),
            minimumFocusDistance: device.minimumFocusDistance > 0 ? device.minimumFocusDistance : nil,
            supportsCustomWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            maxWhiteBalanceGain: max(1, Double(device.maxWhiteBalanceGain)),
            zoomRange: zoomRange(of: device),
            // The photo output's list supersedes the device's flag, and it also covers the front camera's
            // Retina Flash, which lights the screen instead of an LED.
            hasFlash: photoOutput.map { $0.supportedFlashModes.contains(.on) } ?? device.hasFlash,
            hasTorch: device.hasTorch && device.isTorchModeSupported(.on),
            photoDimensions: photoDimensions(of: format, output: photoOutput),
            heifSupported: photoOutput?.availablePhotoCodecTypes.contains(.hevc) ?? false,
            rawSupported: bayerRAWSupported(photoOutput, hint: bayerRAWHint),
            proRAWSupported: photoOutput?.isAppleProRAWSupported ?? false,
            livePhotoSupported: photoOutput?.isLivePhotoCaptureSupported ?? false,
            depthSupported: photoOutput?.isDepthDataDeliverySupported ?? false,
            constantColorSupported: photoOutput?.isConstantColorSupported ?? false,
            shutterSoundSuppressionSupported: photoOutput?.isShutterSoundSuppressionSupported ?? false,
            maxBracketCount: photoOutput?.maxBracketedCapturePhotoCount ?? 0,
            maxProcessing: maxProcessing(photoOutput, format: format),
            lowLightBoostSupported: device.isLowLightBoostSupported,
            geometricCorrectionSupported: device.isGeometricDistortionCorrectionSupported,
            contentAwareCorrectionSupported: photoOutput?.isContentAwareDistortionCorrectionSupported ?? false,
            globalToneMappingSupported: format.isGlobalToneMappingSupported,
            videoHDRSupported: format.isVideoHDRSupported,
            focusRangeRestrictionSupported: device.isAutoFocusRangeRestrictionSupported,
            smoothFocusSupported: device.isSmoothAutoFocusSupported,
            faceDrivenAutoExposureSupported: supportsAutoExposure(device),
            faceDrivenAutoFocusSupported: supportsAutoFocus(device),
            smudgeDetectionSupported: smudgeDetectionSupported(format),
            continuousAFTrackingSupported: continuousAFTrackingSupported(format),
            lowLightVideoNoiseReductionSupported: lowLightVideoNoiseReductionSupported(format),
            formats: formats,
            videoCodecs: videoCodecs(movieOutput: movieOutput, formats: formats),
            stabilizationModes: stabilizationModes(of: format),
            colorModes: colorModes(of: formats)
        )
    }

    // MARK: - Formats

    /// One descriptor per entry of `device.formats`; `index` is the position in that array.
    static func descriptors(for device: AVCaptureDevice) -> [FormatDescriptor] {
        device.formats.enumerated().map { index, format in descriptor(of: format, index: index) }
    }

    static func descriptor(of format: AVCaptureDevice.Format, index: Int) -> FormatDescriptor {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let rates = frameRateBounds(of: format)
        let spaces = format.supportedColorSpaces
        let maxPhotoPixels = format.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        let shutter = secondsRange(of: format)
        return FormatDescriptor(
            index: index,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            minFrameRate: rates?.lowerBound ?? 0,
            maxFrameRate: rates?.upperBound ?? 0,
            pixelFormat: fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
            supportsVideoHDR: format.isVideoHDRSupported,
            supportsHLG: spaces.contains(.HLG_BT2020),
            supportsAppleLog: spaces.contains(.appleLog),
            supportsAppleLog2: appleLog2Space(in: spaces) != nil,
            isBinned: format.isVideoBinned,
            maxPhotoPixels: maxPhotoPixels,
            fieldOfView: Double(format.videoFieldOfView),
            minISO: Double(format.minISO),
            maxISO: Double(format.maxISO),
            minExposure: shutter.lowerBound,
            maxExposure: shutter.upperBound
        )
    }

    /// Lowest and highest frame rate across all of the format's ranges.
    static func frameRateBounds(of format: AVCaptureDevice.Format) -> ClosedRange<Double>? {
        let ranges = format.videoSupportedFrameRateRanges
        guard let low = ranges.map(\.minFrameRate).min(), let high = ranges.map(\.maxFrameRate).max(), low <= high else { return nil }
        return low...high
    }

    /// "4032×3024 · 1–30 fps".
    static func summary(of format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let size = Formatting.resolution(width: Int(dimensions.width), height: Int(dimensions.height))
        guard let rates = frameRateBounds(of: format) else { return size }
        let low = rateText(rates.lowerBound)
        let high = rateText(rates.upperBound)
        let span = low == high ? "\(high) fps" : "\(low)\u{2013}\(high) fps"
        return "\(size) \u{00B7} \(span)"
    }

    private static func rateText(_ fps: Double) -> String {
        abs(fps - fps.rounded()) < 0.01 ? "\(Int(fps.rounded()))" : String(format: "%.2f", fps)
    }

    /// "420f", "420v", "x420". Codes that aren't printable ASCII fall back to their number.
    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Exposure

    /// Shutter range in seconds, rounded inward to whole nanoseconds so that turning a value back into a
    /// CMTime with a nanosecond timescale can never land outside the format's range (an NSRangeException).
    static func secondsRange(of format: AVCaptureDevice.Format) -> ClosedRange<Double> {
        let lower = seconds(format.minExposureDuration, rounding: .up) ?? 1.0 / 16_000
        let upper = seconds(format.maxExposureDuration, rounding: .down) ?? lower
        return min(lower, upper)...max(lower, upper)
    }

    static func isoRange(of format: AVCaptureDevice.Format) -> ClosedRange<Double> {
        let lower = Double(format.minISO)
        let upper = Double(format.maxISO)
        guard lower.isFinite, upper.isFinite, lower > 0 else { return 100...100 }
        return lower...max(lower, upper)
    }

    static func biasRange(of device: AVCaptureDevice) -> ClosedRange<Double> {
        let lower = Double(device.minExposureTargetBias)
        let upper = Double(device.maxExposureTargetBias)
        guard lower.isFinite, upper.isFinite, lower <= upper else { return 0...0 }
        return lower...upper
    }

    /// Whole nanoseconds of a valid, positive CMTime, or nil.
    static func seconds(_ time: CMTime, rounding: FloatingPointRoundingRule) -> Double? {
        guard time.isValid, time.isNumeric else { return nil }
        let value = time.seconds
        guard value.isFinite, value > 0 else { return nil }
        let nanoseconds = (value * 1_000_000_000).rounded(rounding)
        return max(nanoseconds, 1) / 1_000_000_000
    }

    struct ApertureInfo {
        var range: ClosedRange<Double>
        var variable: Bool
        var stops: [Double]
    }

    /// iOS 27 reports an f-number range per format. A range wider than a rounding error means a real iris;
    /// anything else, and every earlier system, is the fixed `lensAperture`.
    static func apertureInfo(device: AVCaptureDevice, format: AVCaptureDevice.Format) -> ApertureInfo {
        let fixedValue = Double(device.lensAperture)
        let fixed = fixedValue.isFinite && fixedValue > 0 ? fixedValue : 1.8
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let low = Double(format.minLensAperture)
            let high = Double(format.maxLensAperture)
            if low.isFinite, high.isFinite, low > 0, high > low + 0.01 {
                var stops: [Double] = []
                for stop in format.recommendedLensApertureStops.map(Double.init).sorted()
                where stop.isFinite && stop >= low - 0.001 && stop <= high + 0.001 {
                    if let last = stops.last, abs(last - stop) < 0.005 { continue }
                    stops.append(min(max(stop, low), high))
                }
                return ApertureInfo(range: low...high, variable: true, stops: stops)
            }
        }
        #endif
        return ApertureInfo(range: fixed...fixed, variable: false, stops: [])
    }

    /// Which priority modes the iOS 27 auto constants run in hardware. "Current" stands for "locked at some
    /// value", which is how Apple says to ask without picking arbitrary numbers.
    static func nativePriority(format: AVCaptureDevice.Format, variableAperture: Bool) -> PrioritySupport {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let shutter = format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.autoLensAperture,
                duration: AVCaptureDevice.currentExposureDuration,
                iso: AVCaptureDevice.autoISO
            )
            let iso = format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.autoLensAperture,
                duration: AVCaptureDevice.autoExposureDuration,
                iso: AVCaptureDevice.currentISO
            )
            let aperture = variableAperture && format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: AVCaptureDevice.autoExposureDuration,
                iso: AVCaptureDevice.autoISO
            )
            return PrioritySupport(shutter: shutter, iso: iso, aperture: aperture)
        }
        #endif
        return .none
    }

    /// Face-driven auto exposure exists wherever auto exposure does (iOS 15.4 and later); its setters raise on a
    /// device without it, so CameraService asks this same question before touching them.
    static func supportsAutoExposure(_ device: AVCaptureDevice) -> Bool {
        device.isExposureModeSupported(.continuousAutoExposure)
    }

    /// Same for face-driven autofocus. Fixed-focus front cameras answer false.
    static func supportsAutoFocus(_ device: AVCaptureDevice) -> Bool {
        device.isFocusModeSupported(.autoFocus) && device.isFocusModeSupported(.continuousAutoFocus)
    }

    // MARK: - Zoom

    /// The zoom factors that can't raise: at least 1 and the session's minimum, at most the session's and the
    /// format's maximum. Beyond 15x the image is mush, so the dial stops there.
    static func zoomRange(of device: AVCaptureDevice) -> ClosedRange<Double> {
        let lower = max(1, Double(device.minAvailableVideoZoomFactor))
        let upper = min(Double(device.maxAvailableVideoZoomFactor), Double(device.activeFormat.videoMaxZoomFactor), 15)
        guard lower.isFinite, upper.isFinite else { return 1...1 }
        return lower...max(lower, upper)
    }

    // MARK: - Photo output

    /// The sizes a photo actually comes out at. Apple only delivers 5712 x 4284 (24 MP) at that size with auto
    /// deferred photo delivery, which PhotoCaptureCoordinator keeps off; offering it would quietly give 12 MP.
    static func photoDimensions(of format: AVCaptureDevice.Format, output: AVCapturePhotoOutput?) -> [PixelSize] {
        let deferredDelivery = output?.isAutoDeferredPhotoDeliveryEnabled ?? false
        var sizes: [PixelSize] = []
        for dimensions in format.supportedMaxPhotoDimensions where dimensions.width > 0 && dimensions.height > 0 {
            if !deferredDelivery, dimensions.width == 5712, dimensions.height == 4284 { continue }
            let size = PixelSize(width: Int(dimensions.width), height: Int(dimensions.height))
            if !sizes.contains(size) { sizes.append(size) }
        }
        return sizes.sorted { $0.pixelCount != $1.pixelCount ? $0.pixelCount < $1.pixelCount : $0.width < $1.width }
    }

    /// `current` with every photo output feature taken from `photoMode`, the same lens's capabilities from when
    /// the photo output was in the session. The rest (ranges, formats, codecs) stays as the session is now.
    static func keepingPhotoFeatures(of photoMode: CameraCapabilities, in current: CameraCapabilities) -> CameraCapabilities {
        var merged = current
        merged.hasFlash = photoMode.hasFlash
        merged.photoDimensions = photoMode.photoDimensions
        merged.heifSupported = photoMode.heifSupported
        merged.rawSupported = photoMode.rawSupported
        merged.proRAWSupported = photoMode.proRAWSupported
        merged.livePhotoSupported = photoMode.livePhotoSupported
        merged.depthSupported = photoMode.depthSupported
        merged.constantColorSupported = photoMode.constantColorSupported
        merged.shutterSoundSuppressionSupported = photoMode.shutterSoundSuppressionSupported
        merged.maxBracketCount = photoMode.maxBracketCount
        merged.maxProcessing = photoMode.maxProcessing
        merged.contentAwareCorrectionSupported = photoMode.contentAwareCorrectionSupported
        return merged
    }

    /// Bayer RAW as the output reports it while ProRAW is off. Every ProRAW iPhone also shoots Bayer RAW,
    /// which covers the case where nothing was measured yet.
    static func bayerRAWSupported(_ output: AVCapturePhotoOutput?, hint: Bool?) -> Bool {
        guard let output else { return hint ?? false }
        if output.isAppleProRAWEnabled {
            return hint ?? output.isAppleProRAWSupported
        }
        return output.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    /// The processing levels that differ on this format. Formats without high photo quality support produce
    /// the same image at every prioritization, so only Minimal is honest there.
    static func maxProcessing(_ output: AVCapturePhotoOutput?, format: AVCaptureDevice.Format) -> ProcessingLevel {
        guard let output else { return .balanced }
        guard format.isHighPhotoQualitySupported || format.isHighestPhotoQualitySupported else { return .minimal }
        switch output.maxPhotoQualityPrioritization {
        case .speed: return .minimal
        case .balanced: return .balanced
        case .quality: return .maximum
        @unknown default: return .balanced
        }
    }

    // MARK: - Newer device features

    static func meteringAreaSupported(_ device: AVCaptureDevice) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return device.isExposureRectOfInterestSupported
        }
        #endif
        return false
    }

    static func smudgeDetectionSupported(_ format: AVCaptureDevice.Format) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return format.isCameraLensSmudgeDetectionSupported
        }
        #endif
        return false
    }

    static func continuousAFTrackingSupported(_ format: AVCaptureDevice.Format) -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return format.isContinuousAutoFocusTrackingSupported
        }
        #endif
        return false
    }

    static func lowLightVideoNoiseReductionSupported(_ format: AVCaptureDevice.Format) -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return format.isLowLightVideoNoiseReductionSupported
        }
        #endif
        return false
    }

    // MARK: - Video

    /// The movie output's own list once it is in the session. Before that, HEVC and H.264 plus ProRes on
    /// hardware that offers Apple Log, which on iPhone has always shipped together with ProRes.
    static func videoCodecs(movieOutput: AVCaptureMovieFileOutput?, formats: [FormatDescriptor]) -> [VideoCodecChoice] {
        var available: Set<VideoCodecChoice> = []
        if let movieOutput {
            available = Set(movieOutput.availableVideoCodecTypes.compactMap(codecChoice(for:)))
        }
        if available.isEmpty {
            available = [.hevc, .h264]
            if formats.contains(where: \.supportsAppleLog) {
                available.formUnion([.proRes422HQ, .proRes422])
            }
        }
        return VideoCodecChoice.allCases.filter { available.contains($0) }
    }

    static func codecChoice(for codec: AVVideoCodecType) -> VideoCodecChoice? {
        switch codec {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes4444: return .proRes4444
        default: return nil
        }
    }

    static func stabilizationModes(of format: AVCaptureDevice.Format) -> [StabilizationChoice] {
        var modes: [(AVCaptureVideoStabilizationMode, StabilizationChoice)] = [
            (.standard, .standard),
            (.cinematic, .cinematic),
            (.cinematicExtended, .cinematicExtended),
            (.cinematicExtendedEnhanced, .cinematicExtendedEnhanced),
            (.previewOptimized, .previewOptimized),
            (.auto, .automatic),
        ]
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            modes.append((.lowLatency, .lowLatency))
        }
        #endif
        // Off is always possible: it is simply not asking for stabilization.
        var supported: Set<StabilizationChoice> = [.off]
        for (mode, choice) in modes where format.isVideoStabilizationModeSupported(mode) {
            supported.insert(choice)
        }
        return StabilizationChoice.allCases.filter { supported.contains($0) }
    }

    /// Union over every format, because video mode picks the format to match the color mode chosen here.
    static func colorModes(of formats: [FormatDescriptor]) -> [VideoColorMode] {
        var modes: [VideoColorMode] = [.sdr]
        if formats.contains(where: { $0.supportsHLG || $0.supportsVideoHDR }) { modes.append(.hdr) }
        if formats.contains(where: \.supportsAppleLog) { modes.append(.appleLog) }
        if formats.contains(where: \.supportsAppleLog2) { modes.append(.appleLog2) }
        return modes
    }

    /// Apple Log 2 when the format lists it. The color space is new in iOS 26, so earlier systems never get it.
    static func appleLog2Space(in spaces: [AVCaptureColorSpace]) -> AVCaptureColorSpace? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), spaces.contains(.appleLog2) {
            return .appleLog2
        }
        #endif
        return nil
    }
}
