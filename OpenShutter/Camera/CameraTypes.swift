import Foundation
import CoreGraphics
import CameraCore

// Value types shared by the camera backends (real and simulated), the model and the UI.
// No AVFoundation types cross this boundary, so the UI never touches capture objects
// and the simulator backend can stand in for the real one.

/// One physical camera.
struct LensInfo: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case ultraWide, wide, telephoto, front, external
    }

    /// AVCaptureDevice.uniqueID.
    let id: String
    let kind: Kind
    /// AVCaptureDevice.localizedName, e.g. "Back Ultra Wide Camera".
    let name: String
    /// 35 mm equivalent focal length at zoom 1.
    let equivalentFocalLength: Double
    /// Zoom relative to the back wide camera: 0.5, 1, 4, 5. The front camera is 1.
    let relativeZoom: Double
    /// lensAperture at the default aperture, f-number.
    let aperture: Double

    var isFront: Bool { kind == .front }
}

/// A button in the lens picker: a physical lens at a given device zoom factor.
/// The "2×" button on a 48 MP main camera is the wide lens at factor 2.
struct LensPreset: Identifiable, Hashable, Sendable {
    let lensID: String
    /// Value for AVCaptureDevice.videoZoomFactor on that lens.
    let zoomFactor: Double
    /// What the button says, relative to the back wide camera.
    let displayZoom: Double

    var id: String { "\(lensID)@\(zoomFactor)" }
    var label: String { LensMath.zoomLabel(displayZoom, selected: false) }
    var selectedLabel: String { LensMath.zoomLabel(displayZoom, selected: true) }
}

struct PixelSize: Hashable, Sendable, Comparable {
    var width: Int
    var height: Int

    var pixelCount: Int { width * height }
    var megapixelLabel: String { Formatting.megapixels(width: width, height: height) }

    static func < (lhs: PixelSize, rhs: PixelSize) -> Bool { lhs.pixelCount < rhs.pixelCount }
}

/// Which exposure priority modes the hardware runs natively (iOS 27 auto constants).
/// Anything unsupported falls back to the software loop in CameraCore.SoftwareAE.
struct PrioritySupport: Equatable, Sendable {
    var shutter: Bool
    var iso: Bool
    var aperture: Bool

    static let none = PrioritySupport(shutter: false, iso: false, aperture: false)
}

/// Everything the active camera and format can do. Rebuilt after every lens or format change.
struct CameraCapabilities: Equatable, Sendable {
    var lens: LensInfo
    /// "4032×3024 · 1–30 fps" for the settings screen.
    var formatSummary: String
    /// Per-frame hardware limits plus the AE shutter limit, from CameraCore.
    var exposure: ExposureRanges
    /// exposureTargetBias range in EV.
    var biasRange: ClosedRange<Double>
    var supportsCustomExposure: Bool
    var supportsVariableAperture: Bool
    /// Apple's recommended stops on variable-aperture lenses (iOS 27), else empty.
    var apertureStops: [Double]
    var nativePriority: PrioritySupport
    var supportsManualFocus: Bool
    var supportsFocusPointOfInterest: Bool
    var supportsExposurePointOfInterest: Bool
    /// iOS 26 exposure rectangles of interest, which spot and whole frame metering need.
    var supportsMeteringArea: Bool
    /// Closest focus distance in millimetres, nil when the device reports none.
    var minimumFocusDistance: Int?
    var supportsCustomWhiteBalance: Bool
    var maxWhiteBalanceGain: Double
    /// Usable videoZoomFactor range on this lens.
    var zoomRange: ClosedRange<Double>
    var hasFlash: Bool
    var hasTorch: Bool
    /// Supported maximum photo dimensions, ascending.
    var photoDimensions: [PixelSize]
    var heifSupported: Bool
    var rawSupported: Bool
    var proRAWSupported: Bool
    var livePhotoSupported: Bool
    var depthSupported: Bool
    var constantColorSupported: Bool
    var shutterSoundSuppressionSupported: Bool
    var maxBracketCount: Int
    var maxProcessing: ProcessingLevel
    var lowLightBoostSupported: Bool
    var geometricCorrectionSupported: Bool
    var contentAwareCorrectionSupported: Bool
    var globalToneMappingSupported: Bool
    var videoHDRSupported: Bool
    var focusRangeRestrictionSupported: Bool
    var smoothFocusSupported: Bool
    var faceDrivenAutoExposureSupported: Bool
    var faceDrivenAutoFocusSupported: Bool
    /// iOS 26 lens smudge detection.
    var smudgeDetectionSupported: Bool
    /// iOS 27 continuous autofocus tracking.
    var continuousAFTrackingSupported: Bool
    /// iOS 27 low light video noise reduction.
    var lowLightVideoNoiseReductionSupported: Bool
    /// Every format of this lens, for video format choice and the capabilities screen.
    var formats: [FormatDescriptor]
    var videoCodecs: [VideoCodecChoice]
    var stabilizationModes: [StabilizationChoice]
    var colorModes: [VideoColorMode]
    /// The phone has a Camera Control button that can carry the app's own controls.
    var supportsCameraControls: Bool = false
    /// What VIDEO records on this lens; nil outside video mode.
    var activeVideo: ActiveVideoFormat? = nil

    /// Shown before the first real capabilities arrive. Ranges match a typical recent iPhone main camera,
    /// so dials have something sensible to draw for a split second.
    static let placeholder = CameraCapabilities(
        lens: LensInfo(id: "placeholder", kind: .wide, name: "Camera", equivalentFocalLength: 24, relativeZoom: 1, aperture: 1.78),
        formatSummary: "",
        exposure: ExposureRanges(seconds: (1.0 / 16000)...1.0, iso: 50...3200, aperture: 1.78...1.78, maxAutoSeconds: 1.0 / 3),
        biasRange: -8...8,
        supportsCustomExposure: true,
        supportsVariableAperture: false,
        apertureStops: [],
        nativePriority: .none,
        supportsManualFocus: true,
        supportsFocusPointOfInterest: true,
        supportsExposurePointOfInterest: true,
        supportsMeteringArea: false,
        minimumFocusDistance: nil,
        supportsCustomWhiteBalance: true,
        maxWhiteBalanceGain: 4,
        zoomRange: 1...10,
        hasFlash: false,
        hasTorch: false,
        photoDimensions: [PixelSize(width: 4032, height: 3024)],
        heifSupported: true,
        rawSupported: false,
        proRAWSupported: false,
        livePhotoSupported: false,
        depthSupported: false,
        constantColorSupported: false,
        shutterSoundSuppressionSupported: false,
        maxBracketCount: 3,
        maxProcessing: .balanced,
        lowLightBoostSupported: false,
        geometricCorrectionSupported: false,
        contentAwareCorrectionSupported: false,
        globalToneMappingSupported: false,
        videoHDRSupported: false,
        focusRangeRestrictionSupported: false,
        smoothFocusSupported: false,
        faceDrivenAutoExposureSupported: false,
        faceDrivenAutoFocusSupported: false,
        smudgeDetectionSupported: false,
        continuousAFTrackingSupported: false,
        lowLightVideoNoiseReductionSupported: false,
        formats: [],
        videoCodecs: [.hevc, .h264],
        stabilizationModes: [.off, .standard],
        colorModes: [.sdr]
    )
}

/// The video format a backend set up. A lens that can't record the saved settings records the nearest format it
/// has, and the settings keep asking for theirs, so a lens that can record them gets them back.
struct ActiveVideoFormat: Equatable, Sendable {
    /// The saved resolution, frame rate and color this format answers. Settings changed since are still being set up.
    var requested: VideoRequirement
    var recorded: VideoRequirement
}

enum PressureLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical, shutdown

    static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the camera is doing right now, polled about 10 times a second.
struct LiveReadings: Equatable, Sendable {
    var exposureSeconds: Double
    var iso: Double
    var aperture: Double
    var bias: Double
    /// exposureTargetOffset in EV. Positive means the image is brighter than the meter's target.
    var meterOffset: Double
    var lensPosition: Double
    var kelvin: Double
    var tint: Double
    /// AVCaptureDevice.videoZoomFactor on the active lens.
    var zoomFactor: Double
    /// Zoom relative to the back wide camera, for the zoom label.
    var displayZoom: Double
    var isAdjustingFocus: Bool
    var isAdjustingExposure: Bool
    var isAdjustingWhiteBalance: Bool
    var pressure: PressureLevel
    var lensSmudged: Bool

    static let initial = LiveReadings(
        exposureSeconds: 1.0 / 60, iso: 100, aperture: 1.78, bias: 0, meterOffset: 0, lensPosition: 0.5,
        kelvin: 5500, tint: 0, zoomFactor: 1, displayZoom: 1, isAdjustingFocus: false, isAdjustingExposure: false,
        isAdjustingWhiteBalance: false, pressure: .nominal, lensSmudged: false
    )
}

enum CameraAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

enum SessionState: Equatable, Sendable {
    case idle
    case starting
    case running
    /// Another app took the camera, a phone call, multitasking, or thermal shutdown.
    case interrupted(String)
    case failed(String)
}

/// Histogram plus overlay for the viewfinder, produced about 12 times a second.
struct AnalysisFrame: @unchecked Sendable {
    var histogram: Histogram
    var stats: ExposureStats
    /// Peaking, zebras and false color, already rotated and mirrored to sit exactly over the preview.
    /// nil when no overlay is enabled.
    var overlay: CGImage?
}

struct AnalysisOptions: Equatable, Sendable {
    var histogram: Bool
    var rgbHistogram: Bool
    var zebraThreshold: Double?
    var peakingThreshold: Double?
    var peakingColor: PeakingColor
    var falseColor: Bool
    /// Only the clipped-highlight share is wanted, for the clipping warning.
    var clipping: Bool = false

    var isOff: Bool { !histogram && zebraThreshold == nil && peakingThreshold == nil && !falseColor && !clipping }

    static let off = AnalysisOptions(histogram: false, rgbHistogram: false, zebraThreshold: nil, peakingThreshold: nil, peakingColor: .red, falseColor: false)
}

// MARK: - Requests

struct ExposureRequest: Equatable, Sendable {
    /// Fixed parameters; nil means auto exposure owns it.
    var locks: ExposureLocks
    /// EV compensation. In fully manual exposure it only moves the meter, like a real camera.
    var bias: Double
    /// Freeze auto exposure at its current values.
    var aeLocked: Bool
    /// Longest shutter auto exposure may use. nil = system default.
    var maxAutoSeconds: Double?

    static let auto = ExposureRequest(locks: ExposureLocks(), bias: 0, aeLocked: false, maxAutoSeconds: nil)
}

enum FocusRequest: Equatable, Sendable {
    case continuousAuto
    /// Focus once at the current point of interest, then hold.
    case autoOnce
    /// Hold the lens where it is.
    case locked
    /// Lens position 0 (closest) ... 1 (farthest).
    case manual(Double)
}

enum WhiteBalanceRequest: Equatable, Sendable {
    case auto
    /// Hold the current gains.
    case locked
    case temperature(kelvin: Double, tint: Double)
    /// Lock to the gray world estimate of the current frame, a quick custom white balance.
    case grayWorld
}

/// Device-level preferences from Settings, re-applied after every lens or format change.
struct DeviceOptions: Equatable, Sendable {
    var faceDrivenAE: TriState
    var faceDrivenAF: TriState
    var lowLightBoost: Bool
    var globalToneMapping: Bool
    var videoHDR: TriState
    var focusRange: FocusRange
    var smoothFocus: Bool
    var geometricCorrection: Bool
    var smudgeDetection: Bool
    var continuousAFTracking: Bool
    var apertureRateLimit: Double?
    /// What auto exposure measures around the point of interest (iOS 26).
    var meteringArea: MeteringArea
    /// Photo output features that need a session reconfiguration, so they are set up ahead of the shot.
    var rawFormat: RawFormat
    var livePhoto: Bool
    var depth: Bool
    var constantColor: Bool
    var photoResolution: PhotoResolution
    /// Front camera photos saved the way the preview shows them (mirrored) or the way others see you.
    var mirrorFront: Bool

    init(settings: CameraSettings) {
        faceDrivenAE = settings.exposure.faceDriven
        faceDrivenAF = settings.focusOptions.faceDriven
        lowLightBoost = settings.exposure.lowLightBoost
        globalToneMapping = settings.exposure.globalToneMapping
        videoHDR = settings.exposure.videoHDR
        focusRange = settings.focusOptions.range
        smoothFocus = settings.focusOptions.smooth
        geometricCorrection = settings.capture.lensCorrection
        smudgeDetection = true
        continuousAFTracking = settings.focusOptions.continuousTracking
        apertureRateLimit = settings.exposure.apertureRateLimit
        meteringArea = settings.exposure.meteringArea
        rawFormat = settings.capture.rawFormat
        livePhoto = settings.capture.livePhoto
        depth = settings.capture.depth
        constantColor = settings.capture.constantColor
        photoResolution = settings.capture.resolution
        mirrorFront = settings.capture.mirrorFront
    }
}

/// GPS position for EXIF and Photos, as a value type so CoreLocation stays out of the camera layer.
struct LocationStamp: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var timestamp: Date
}

struct PhotoRequest: Sendable {
    var processedFormat: ProcessedFormat
    var rawFormat: RawFormat
    var quality: Double
    var resolution: PhotoResolution
    /// Already resolved by the model: manual exposure forces .minimal so the device values are honoured.
    var processing: ProcessingLevel
    var flash: FlashSetting
    var aspect: AspectRatio
    var livePhoto: Bool
    var silentShutter: Bool
    var depth: Bool
    var constantColor: Bool
    var contentAwareCorrection: Bool
    var location: LocationStamp?
    /// .off for a single photo.
    var bracket: BracketPlan
    /// Exposure to bracket around for manual brackets (current readings).
    var bracketBase: ExposureValues?
}

struct StackRequest: Sendable {
    var plan: StackPlan
    /// Run until finishStackEarly(); plan.frameCount is then only a cap.
    var isBulb: Bool
    /// .none is treated as HEIF.
    var processedFormat: ProcessedFormat
    var quality: Double
    var aspect: AspectRatio
    var location: LocationStamp?
    /// 0...1, night mode only.
    var noiseReduction: Double
}

struct StackProgress: @unchecked Sendable {
    var framesCaptured: Int
    /// 0 for bulb.
    var framesPlanned: Int
    var elapsed: TimeInterval
    /// nil for bulb.
    var estimatedTotal: TimeInterval?
    /// The running result, downscaled and oriented for display over the preview.
    var preview: CGImage?

    var fraction: Double {
        if let total = estimatedTotal, total > 0 { return min(1, elapsed / total) }
        if framesPlanned > 0 { return min(1, Double(framesCaptured) / Double(framesPlanned)) }
        return 0
    }
}

struct VideoRequest: Sendable {
    var settings: VideoSettings
    var location: LocationStamp?
}

struct CaptureResult: @unchecked Sendable, Identifiable {
    enum Kind: String, Sendable {
        case photo, raw, bracket, stack, video
    }

    let id = UUID()
    var kind: Kind
    /// PHAsset.localIdentifier once saved.
    var assetIdentifier: String?
    var thumbnail: CGImage?
    /// "1/250 · ISO 100 · ƒ/1.8".
    var summary: String
    var date: Date
    var savedToLibrary: Bool
}

enum CameraError: LocalizedError, Equatable {
    case notAuthorized
    case noCamera
    case busy
    case unsupported(String)
    case configurationFailed(String)
    case captureFailed(String)
    case saveFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access is off. Turn it on in Settings."
        case .noCamera: return "No camera found."
        case .busy: return "The camera is still busy with the last shot."
        case .unsupported(let what): return "\(what) isn't supported on this camera."
        case .configurationFailed(let why): return "Couldn't set up the camera. \(why)"
        case .captureFailed(let why): return "The shot failed. \(why)"
        case .saveFailed(let why): return "Couldn't save to Photos. \(why)"
        case .cancelled: return "Cancelled."
        }
    }
}

// MARK: - Camera Control button (iOS 18)

/// Current values the Camera Control overlay should show.
struct CameraControlState: Equatable, Sendable {
    var items: [CameraControlItem]
    var shutterStops: [Double]
    /// nil = auto. The pickers put "Auto" at index 0.
    var shutter: Double?
    var isoStops: [Double]
    var iso: Double?
    var apertureStops: [Double]
    var aperture: Double?
    var kelvin: Double?
    var lensPosition: Double?
    var mode: CaptureMode
    /// "0.5×", "1×", "2×", "4×": the back lens buttons, for the Lens picker.
    var lensTitles: [String] = []
    /// Index into lensTitles of the active lens button, nil on the selfie camera.
    var lensIndex: Int? = nil
}

/// A value the user picked on the Camera Control. Zoom and EV use Apple's system controls,
/// which drive the device directly, so they don't appear here.
enum CameraControlChange: Equatable, Sendable {
    case shutter(Double?)
    case iso(Double?)
    case aperture(Double?)
    case kelvin(Double?)
    case focus(Double?)
    case mode(CaptureMode)
    /// Index into CameraControlState.lensTitles.
    case lens(Int)
}
