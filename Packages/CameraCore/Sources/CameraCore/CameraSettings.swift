import Foundation

// Everything the user can set, persisted as JSON. Each type decodes missing or malformed keys as
// their defaults, so adding a setting in a later version never resets the rest.

extension KeyedDecodingContainer {
    /// The decoded value, or `fallback` when the key is missing or holds something unreadable.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public enum CaptureMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case night, long, photo, manual, video

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var usesStacking: Bool { self == .night || self == .long }
    /// Left to right in the mode carousel; PHOTO sits in the middle like the Camera app.
    public static let carouselOrder: [CaptureMode] = [.night, .long, .photo, .manual, .video]
}

public enum ProcessedFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case heif, jpeg, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .heif: return "HEIF"
        case .jpeg: return "JPEG"
        case .none: return "None"
        }
    }
}

public enum RawFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, bayer, proRAW
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "Off"
        case .bayer: return "RAW"
        case .proRAW: return "ProRAW"
        }
    }
}

public enum PhotoResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, mp12, mp24, mp48
    public var id: String { rawValue }
    /// The photo pipeline gives `.automatic` the largest size the camera delivers, and the title says so.
    public var title: String {
        switch self {
        case .automatic: return "Largest"
        case .mp12: return "12 MP"
        case .mp24: return "24 MP"
        case .mp48: return "48 MP"
        }
    }
    public var targetMegapixels: Int? {
        switch self {
        case .automatic: return nil
        case .mp12: return 12
        case .mp24: return 24
        case .mp48: return 48
        }
    }
}

public enum ProcessingLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case minimal, balanced, maximum
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .balanced: return "Balanced"
        case .maximum: return "Maximum"
        }
    }
    public var detail: String {
        switch self {
        case .minimal: return "One frame, no fusion. Respects manual shutter and ISO exactly."
        case .balanced: return "Apple's default mix of speed and quality."
        case .maximum: return "Deep Fusion and Smart HDR when available. Slower."
        }
    }
}

public enum FlashSetting: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, auto, on
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .on: return "On"
        }
    }
    public var symbolName: String {
        switch self {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.automatic"
        case .on: return "bolt"
        }
    }
}

public enum GridStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, thirds, goldenRatio, square, crosshair, diagonals
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .thirds: return "Thirds"
        case .goldenRatio: return "Golden ratio"
        case .square: return "Square"
        case .crosshair: return "Crosshair"
        case .diagonals: return "Diagonals"
        }
    }
}

public enum HistogramStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, luma, rgb
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .luma: return "Luma"
        case .rgb: return "RGB"
        }
    }
}

public enum TriState: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, on, off
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// The part of the frame auto exposure measures (iOS 26 exposure rectangles of interest).
public enum MeteringArea: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, spot, wholeFrame
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "Auto"
        case .spot: return "Spot"
        case .wholeFrame: return "Whole frame"
        }
    }

    /// The exposure rectangle of interest around a point of interest, both normalized 0...1 with the origin at the
    /// top left like a device point. nil for automatic, which keeps the camera's own rectangle around the point, and
    /// when no rectangle of the minimum size fits the frame. Spot is the smallest rectangle the camera takes, centred
    /// on the point and moved (not shrunk) to stay inside the frame; whole frame is the unit rectangle.
    public func rectOfInterest(centerX: Double, centerY: Double, minWidth: Double, minHeight: Double) -> CropRect? {
        guard minWidth.isFinite, minHeight.isFinite, minWidth <= 1, minHeight <= 1 else { return nil }
        switch self {
        case .automatic:
            return nil
        case .wholeFrame:
            return .unit
        case .spot:
            guard minWidth > 0, minHeight > 0 else { return nil }
            // A hair over the minimum: AVFoundation raises for anything smaller, and a size that only equals it is
            // one rounding step away from that.
            let width = min(minWidth * 1.01, 1)
            let height = min(minHeight * 1.01, 1)
            return CropRect(x: Self.start(centeredOn: centerX, length: width), y: Self.start(centeredOn: centerY, length: height),
                            width: width, height: height)
        }
    }

    /// Where a span of `length` centred on `center` starts, kept inside 0...1. A non-finite centre means the middle.
    private static func start(centeredOn center: Double, length: Double) -> Double {
        let middle = center.isFinite ? center : 0.5
        return min(max(middle - length / 2, 0), 1 - length)
    }
}

public enum FocusRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, near, far
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "Full"
        case .near: return "Near"
        case .far: return "Far"
        }
    }
}

public enum PeakingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, manualFocus, always
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .manualFocus: return "Manual focus"
        case .always: return "Always"
        }
    }
}

public enum NightStabilityChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, handheld, tripod
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "Auto"
        case .handheld: return "Handheld"
        case .tripod: return "Tripod"
        }
    }
}

public enum VideoCodecChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case hevc, h264, proRes422HQ, proRes422, proRes422LT, proRes422Proxy, proRes4444
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .proRes422HQ: return "ProRes 422 HQ"
        case .proRes422: return "ProRes 422"
        case .proRes422LT: return "ProRes 422 LT"
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .proRes4444: return "ProRes 4444"
        }
    }
    public var isProRes: Bool { self != .hevc && self != .h264 }
}

public enum StabilizationChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, standard, cinematic, cinematicExtended, cinematicExtendedEnhanced, previewOptimized, lowLatency, automatic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .standard: return "Standard"
        case .cinematic: return "Cinematic"
        case .cinematicExtended: return "Cinematic extended"
        case .cinematicExtendedEnhanced: return "Enhanced"
        case .previewOptimized: return "Preview optimized"
        case .lowLatency: return "Low latency"
        case .automatic: return "Auto"
        }
    }
}

public enum CameraControlItem: String, Codable, Sendable, CaseIterable, Identifiable {
    case zoom, lens, exposureBias, shutter, iso, aperture, whiteBalance, focus, mode
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .zoom: return "Zoom"
        case .lens: return "Lens"
        case .exposureBias: return "Exposure"
        case .shutter: return "Shutter"
        case .iso: return "ISO"
        case .aperture: return "Aperture"
        case .whiteBalance: return "White balance"
        case .focus: return "Focus"
        case .mode: return "Mode"
        }
    }
    public var symbolName: String {
        switch self {
        case .zoom: return "plus.magnifyingglass"
        case .lens: return "camera"
        case .exposureBias: return "plusminus.circle"
        case .shutter: return "camera.aperture"
        case .iso: return "camera.metering.matrix"
        case .aperture: return "camera.aperture"
        case .whiteBalance: return "thermometer.sun"
        case .focus: return "scope"
        case .mode: return "camera.on.rectangle"
        }
    }
    /// Zoom only moves within the current lens (Apple's slider drives one camera), so Lens comes next to it.
    public static let defaultSelection: [CameraControlItem] = [.zoom, .lens, .exposureBias, .shutter, .iso, .whiteBalance]
}

public enum WhiteBalanceSetting: Codable, Hashable, Sendable {
    case auto
    case preset(WhiteBalancePreset)
    case kelvin(Double, tint: Double)

    /// The preset's or custom Kelvin; nil for auto.
    public var kelvinValue: Double? {
        switch self {
        case .auto: return nil
        case .preset(let preset): return preset.kelvin
        case .kelvin(let k, _): return k
        }
    }

    public var tintValue: Double {
        if case .kelvin(_, let tint) = self { return tint }
        return 0
    }

    public var isAuto: Bool {
        switch self {
        case .auto: return true
        case .preset(let preset): return preset == .auto
        case .kelvin: return false
        }
    }
}

public enum FocusSetting: Codable, Hashable, Sendable {
    case auto
    case manual(lensPosition: Double)

    public var lensPosition: Double? {
        if case .manual(let p) = self { return p }
        return nil
    }
}

public struct ManualExposureSetting: Codable, Hashable, Sendable {
    public var shutter: Double?
    public var iso: Double?
    public var aperture: Double?
    public var bias: Double

    public init(shutter: Double? = nil, iso: Double? = nil, aperture: Double? = nil, bias: Double = 0) {
        self.shutter = shutter
        self.iso = iso
        self.aperture = aperture
        self.bias = bias
    }

    public var locks: ExposureLocks { ExposureLocks(seconds: shutter, iso: iso, aperture: aperture) }

    enum CodingKeys: String, CodingKey { case shutter, iso, aperture, bias }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ManualExposureSetting()
        shutter = c.value(.shutter, default: d.shutter)
        iso = c.value(.iso, default: d.iso)
        aperture = c.value(.aperture, default: d.aperture)
        bias = c.value(.bias, default: d.bias)
    }
}

public struct CaptureOptions: Codable, Hashable, Sendable {
    public var processedFormat: ProcessedFormat = .heif
    public var rawFormat: RawFormat = .none
    /// HEIF / JPEG compression quality, 0.5...1.
    public var quality: Double = 0.9
    public var resolution: PhotoResolution = .automatic
    public var processing: ProcessingLevel = .balanced
    public var flash: FlashSetting = .off
    public var aspect: AspectRatio = .fourThree
    public var livePhoto: Bool = false
    public var silentShutter: Bool = false
    public var depth: Bool = false
    public var constantColor: Bool = false
    /// Distortion correction for the ultra wide (geometric and content aware).
    public var lensCorrection: Bool = true
    public var mirrorFront: Bool = true
    public var saveLocation: Bool = false
    public var schedule: CaptureSchedule = .off
    public var bracket: BracketPlan = .off

    public init() {}

    /// At least one output format has to be on.
    public var isValid: Bool { processedFormat != .none || rawFormat != .none }

    enum CodingKeys: String, CodingKey {
        case processedFormat, rawFormat, quality, resolution, processing, flash, aspect, livePhoto, silentShutter, depth
        case constantColor, lensCorrection, mirrorFront, saveLocation, schedule, bracket
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureOptions()
        processedFormat = c.value(.processedFormat, default: d.processedFormat)
        rawFormat = c.value(.rawFormat, default: d.rawFormat)
        quality = c.value(.quality, default: d.quality)
        resolution = c.value(.resolution, default: d.resolution)
        processing = c.value(.processing, default: d.processing)
        flash = c.value(.flash, default: d.flash)
        aspect = c.value(.aspect, default: d.aspect)
        livePhoto = c.value(.livePhoto, default: d.livePhoto)
        silentShutter = c.value(.silentShutter, default: d.silentShutter)
        depth = c.value(.depth, default: d.depth)
        constantColor = c.value(.constantColor, default: d.constantColor)
        lensCorrection = c.value(.lensCorrection, default: d.lensCorrection)
        mirrorFront = c.value(.mirrorFront, default: d.mirrorFront)
        saveLocation = c.value(.saveLocation, default: d.saveLocation)
        schedule = c.value(.schedule, default: d.schedule)
        bracket = c.value(.bracket, default: d.bracket)
        if !isValid { processedFormat = .heif }
    }
}

public struct ExposureOptions: Codable, Hashable, Sendable {
    /// Longest shutter auto exposure may use. nil = system default.
    public var aeMaxShutter: Double? = nil
    public var faceDriven: TriState = .automatic
    public var lowLightBoost: Bool = false
    public var globalToneMapping: Bool = false
    public var videoHDR: TriState = .automatic
    /// iOS 27 aperture speed limit under auto exposure; nil = system.
    public var apertureRateLimit: Double? = nil
    /// iOS 26: what auto exposure measures around the point of interest.
    public var meteringArea: MeteringArea = .automatic

    public init() {}

    enum CodingKeys: String, CodingKey {
        case aeMaxShutter, faceDriven, lowLightBoost, globalToneMapping, videoHDR, apertureRateLimit, meteringArea
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExposureOptions()
        aeMaxShutter = c.value(.aeMaxShutter, default: d.aeMaxShutter)
        faceDriven = c.value(.faceDriven, default: d.faceDriven)
        lowLightBoost = c.value(.lowLightBoost, default: d.lowLightBoost)
        globalToneMapping = c.value(.globalToneMapping, default: d.globalToneMapping)
        videoHDR = c.value(.videoHDR, default: d.videoHDR)
        apertureRateLimit = c.value(.apertureRateLimit, default: d.apertureRateLimit)
        meteringArea = c.value(.meteringArea, default: d.meteringArea)
    }
}

public struct FocusOptions: Codable, Hashable, Sendable {
    public var range: FocusRange = .none
    public var smooth: Bool = false
    public var faceDriven: TriState = .automatic
    /// iOS 27 subject tracking autofocus.
    public var continuousTracking: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey { case range, smooth, faceDriven, continuousTracking }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FocusOptions()
        range = c.value(.range, default: d.range)
        smooth = c.value(.smooth, default: d.smooth)
        faceDriven = c.value(.faceDriven, default: d.faceDriven)
        continuousTracking = c.value(.continuousTracking, default: d.continuousTracking)
    }
}

public struct DisplaySettings: Codable, Hashable, Sendable {
    public var grid: GridStyle = .off
    public var showLevel: Bool = true
    public var histogram: HistogramStyle = .luma
    public var zebras: Bool = false
    /// Luma level (0...1) where zebra stripes start.
    public var zebraThreshold: Double = 0.95
    public var peaking: PeakingMode = .manualFocus
    public var peakingColor: PeakingColor = .red
    /// 0...1, see OverlayOptions.peakingThreshold(sensitivity:).
    public var peakingSensitivity: Double = 0.5
    public var falseColor: Bool = false
    public var showReadout: Bool = true
    public var clippingWarnings: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case grid, showLevel, histogram, zebras, zebraThreshold, peaking, peakingColor, peakingSensitivity, falseColor, showReadout, clippingWarnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        grid = c.value(.grid, default: d.grid)
        showLevel = c.value(.showLevel, default: d.showLevel)
        histogram = c.value(.histogram, default: d.histogram)
        zebras = c.value(.zebras, default: d.zebras)
        zebraThreshold = c.value(.zebraThreshold, default: d.zebraThreshold)
        peaking = c.value(.peaking, default: d.peaking)
        peakingColor = c.value(.peakingColor, default: d.peakingColor)
        peakingSensitivity = c.value(.peakingSensitivity, default: d.peakingSensitivity)
        falseColor = c.value(.falseColor, default: d.falseColor)
        showReadout = c.value(.showReadout, default: d.showReadout)
        clippingWarnings = c.value(.clippingWarnings, default: d.clippingWarnings)
    }
}

public struct NightSettings: Codable, Hashable, Sendable {
    /// nil = automatic duration from the light level.
    public var seconds: Double? = nil
    public var stability: NightStabilityChoice = .automatic
    public var alignFrames: Bool = true
    public var maxISO: Double = 3200
    public var biasEV: Double = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case seconds, stability, alignFrames, maxISO, biasEV }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NightSettings()
        seconds = c.value(.seconds, default: d.seconds)
        stability = c.value(.stability, default: d.stability)
        alignFrames = c.value(.alignFrames, default: d.alignFrames)
        maxISO = c.value(.maxISO, default: d.maxISO)
        biasEV = c.value(.biasEV, default: d.biasEV)
    }
}

public struct LongExposureSettings: Codable, Hashable, Sendable {
    public var seconds: Double = 4
    public var blend: StackBlend = .additive
    /// Hold the shutter (or tap to start and stop) instead of a fixed time.
    public var bulb: Bool = false
    public var align: Bool = false
    public var maxBulbSeconds: Double = 1800
    /// Shutter for each frame of a Blur or Trails stack; nil leaves it to auto exposure. Real ignores it, since its
    /// frames are as long as the sensor allows.
    public var frameSeconds: Double? = nil

    public init() {}

    enum CodingKeys: String, CodingKey { case seconds, blend, bulb, align, maxBulbSeconds, frameSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LongExposureSettings()
        seconds = c.value(.seconds, default: d.seconds)
        blend = c.value(.blend, default: d.blend)
        bulb = c.value(.bulb, default: d.bulb)
        align = c.value(.align, default: d.align)
        maxBulbSeconds = c.value(.maxBulbSeconds, default: d.maxBulbSeconds)
        frameSeconds = c.value(.frameSeconds, default: d.frameSeconds)
    }
}

public struct VideoSettings: Codable, Hashable, Sendable {
    public var resolution: VideoResolution = .uhd4K
    public var frameRate: Double = 30
    public var codec: VideoCodecChoice = .hevc
    public var colorMode: VideoColorMode = .sdr
    public var stabilization: StabilizationChoice = .standard
    public var audio: Bool = true
    /// Takes wind noise out of the sound where the microphone supports it.
    public var windNoiseReduction: Bool = true
    /// iOS 27.
    public var lowLightNoiseReduction: Bool = false
    /// Show shutter as an angle (180°) instead of a fraction while filming.
    public var showShutterAngle: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case resolution, frameRate, codec, colorMode, stabilization, audio, windNoiseReduction, lowLightNoiseReduction, showShutterAngle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoSettings()
        resolution = c.value(.resolution, default: d.resolution)
        frameRate = c.value(.frameRate, default: d.frameRate)
        codec = c.value(.codec, default: d.codec)
        colorMode = c.value(.colorMode, default: d.colorMode)
        stabilization = c.value(.stabilization, default: d.stabilization)
        audio = c.value(.audio, default: d.audio)
        windNoiseReduction = c.value(.windNoiseReduction, default: d.windNoiseReduction)
        lowLightNoiseReduction = c.value(.lowLightNoiseReduction, default: d.lowLightNoiseReduction)
        showShutterAngle = c.value(.showShutterAngle, default: d.showShutterAngle)
    }
}

public struct ControlOptions: Codable, Hashable, Sendable {
    /// Volume buttons and the Camera Control press take the photo.
    public var volumeShutter: Bool = true
    public var cameraControlItems: [CameraControlItem] = CameraControlItem.defaultSelection
    public var haptics: Bool = true
    /// Pinching past a lens switches to the next one, like the Camera app.
    public var autoLensSwitching: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case volumeShutter, cameraControlItems, haptics, autoLensSwitching }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlOptions()
        volumeShutter = c.value(.volumeShutter, default: d.volumeShutter)
        cameraControlItems = c.value(.cameraControlItems, default: d.cameraControlItems)
        haptics = c.value(.haptics, default: d.haptics)
        autoLensSwitching = c.value(.autoLensSwitching, default: d.autoLensSwitching)
    }
}

public struct CameraSettings: Codable, Hashable, Sendable {
    public var mode: CaptureMode = .photo
    public var lensID: String? = nil
    public var zoom: Double = 1
    public var manual: ManualExposureSetting = .init()
    public var whiteBalance: WhiteBalanceSetting = .auto
    public var focus: FocusSetting = .auto
    public var capture: CaptureOptions = .init()
    public var exposure: ExposureOptions = .init()
    public var focusOptions: FocusOptions = .init()
    public var display: DisplaySettings = .init()
    public var night: NightSettings = .init()
    public var longExposure: LongExposureSettings = .init()
    public var video: VideoSettings = .init()
    public var controls: ControlOptions = .init()

    public init() {}

    public static let `default` = CameraSettings()

    enum CodingKeys: String, CodingKey {
        case mode, lensID, zoom, manual, whiteBalance, focus, capture, exposure, focusOptions, display, night, longExposure, video, controls
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraSettings()
        mode = c.value(.mode, default: d.mode)
        lensID = c.value(.lensID, default: d.lensID)
        zoom = c.value(.zoom, default: d.zoom)
        manual = c.value(.manual, default: d.manual)
        whiteBalance = c.value(.whiteBalance, default: d.whiteBalance)
        focus = c.value(.focus, default: d.focus)
        capture = c.value(.capture, default: d.capture)
        exposure = c.value(.exposure, default: d.exposure)
        focusOptions = c.value(.focusOptions, default: d.focusOptions)
        display = c.value(.display, default: d.display)
        night = c.value(.night, default: d.night)
        longExposure = c.value(.longExposure, default: d.longExposure)
        video = c.value(.video, default: d.video)
        controls = c.value(.controls, default: d.controls)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Never throws: anything unreadable comes back as the defaults.
    public static func decoded(from data: Data) -> CameraSettings {
        (try? JSONDecoder().decode(CameraSettings.self, from: data)) ?? .default
    }
}
