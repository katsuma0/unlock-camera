import Foundation

public enum VideoResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case hd720, hd1080, uhd4K

    public var id: String { rawValue }

    public var dimensions: (width: Int, height: Int) {
        switch self {
        case .hd720: return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }

    public var title: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }
}

public enum VideoColorMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case sdr, hdr, appleLog, appleLog2

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sdr: return "SDR"
        case .hdr: return "HDR"
        case .appleLog: return "Apple Log"
        case .appleLog2: return "Apple Log 2"
        }
    }

    /// What to record, in order, when no format has this mode at the chosen size and rate. Apple Log 2 steps down to
    /// Apple Log, still log footage to grade, before SDR.
    public var fallbacks: [VideoColorMode] {
        switch self {
        case .sdr: return [.sdr]
        case .hdr: return [.hdr, .sdr]
        case .appleLog: return [.appleLog, .sdr]
        case .appleLog2: return [.appleLog2, .appleLog, .sdr]
        }
    }
}

/// Plain-value copy of an AVCaptureDevice.Format, so format choice can be tested anywhere.
public struct FormatDescriptor: Hashable, Codable, Sendable {
    /// Index in AVCaptureDevice.formats.
    public var index: Int
    public var width: Int
    public var height: Int
    public var minFrameRate: Double
    public var maxFrameRate: Double
    /// FourCC such as "420f", "420v", "x420".
    public var pixelFormat: String
    public var supportsVideoHDR: Bool
    /// HLG_BT2020 color space.
    public var supportsHLG: Bool
    public var supportsAppleLog: Bool
    /// Apple Log 2 color space (iOS 26).
    public var supportsAppleLog2: Bool
    public var isBinned: Bool
    /// Largest supportedMaxPhotoDimensions, width * height.
    public var maxPhotoPixels: Int
    public var fieldOfView: Double
    public var minISO: Double
    public var maxISO: Double
    public var minExposure: Double
    public var maxExposure: Double

    public init(index: Int, width: Int, height: Int, minFrameRate: Double, maxFrameRate: Double, pixelFormat: String,
                supportsVideoHDR: Bool, supportsHLG: Bool, supportsAppleLog: Bool, supportsAppleLog2: Bool, isBinned: Bool,
                maxPhotoPixels: Int, fieldOfView: Double, minISO: Double, maxISO: Double, minExposure: Double, maxExposure: Double) {
        self.index = index
        self.width = width
        self.height = height
        self.minFrameRate = minFrameRate
        self.maxFrameRate = maxFrameRate
        self.pixelFormat = pixelFormat
        self.supportsVideoHDR = supportsVideoHDR
        self.supportsHLG = supportsHLG
        self.supportsAppleLog = supportsAppleLog
        self.supportsAppleLog2 = supportsAppleLog2
        self.isBinned = isBinned
        self.maxPhotoPixels = maxPhotoPixels
        self.fieldOfView = fieldOfView
        self.minISO = minISO
        self.maxISO = maxISO
        self.minExposure = minExposure
        self.maxExposure = maxExposure
    }

    /// 10-bit YCbCr formats carry HDR and Log without banding.
    public var is10Bit: Bool { pixelFormat.hasPrefix("x4") }
}

public struct VideoRequirement: Hashable, Sendable {
    public var resolution: VideoResolution
    public var frameRate: Double
    public var colorMode: VideoColorMode

    public init(resolution: VideoResolution, frameRate: Double, colorMode: VideoColorMode) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.colorMode = colorMode
    }
}

public enum FormatSelector {
    public static let standardFrameRates: [Double] = [24, 25, 30, 48, 50, 60, 100, 120, 240]

    public static func bestVideoFormat(for requirement: VideoRequirement, among formats: [FormatDescriptor]) -> FormatDescriptor? {
        let candidates = formats.filter { matches($0, resolution: requirement.resolution, colorMode: requirement.colorMode) && supports($0, frameRate: requirement.frameRate) }
        return candidates.min { a, b in videoRank(a, colorMode: requirement.colorMode) < videoRank(b, colorMode: requirement.colorMode) }
    }

    /// The format to record the requirement with, and the size, rate and color it records: an exact match, else the
    /// nearest. Log or HDR at another size is still footage to grade, so every size in the color comes before the
    /// color's fallbacks (Apple Log 2 steps down to Apple Log, everything ends at SDR). Sizes start with the chosen one,
    /// then go from the largest down, and the rate is the closest one offered.
    public static func nearestVideoFormat(for requirement: VideoRequirement, among formats: [FormatDescriptor])
        -> (format: FormatDescriptor, recorded: VideoRequirement)? {
        if let format = bestVideoFormat(for: requirement, among: formats) { return (format, requirement) }
        let resolutions = [requirement.resolution] + VideoResolution.allCases.reversed().filter { $0 != requirement.resolution }
        for color in requirement.colorMode.fallbacks {
            for resolution in resolutions {
                let rates = availableFrameRates(resolution: resolution, colorMode: color, among: formats)
                for rate in rates.sorted(by: { abs($0 - requirement.frameRate) < abs($1 - requirement.frameRate) }) {
                    let recorded = VideoRequirement(resolution: resolution, frameRate: rate, colorMode: color)
                    if let format = bestVideoFormat(for: recorded, among: formats) { return (format, recorded) }
                }
            }
        }
        return nil
    }

    public static func availableFrameRates(resolution: VideoResolution, colorMode: VideoColorMode, among formats: [FormatDescriptor]) -> [Double] {
        let candidates = formats.filter { matches($0, resolution: resolution, colorMode: colorMode) }
        return standardFrameRates.filter { rate in candidates.contains { supports($0, frameRate: rate) } }
    }

    public static func availableResolutions(colorMode: VideoColorMode, among formats: [FormatDescriptor]) -> [VideoResolution] {
        VideoResolution.allCases.filter { resolution in formats.contains { matches($0, resolution: resolution, colorMode: colorMode) } }
    }

    public static func bestPhotoFormat(among formats: [FormatDescriptor]) -> FormatDescriptor? {
        formats.min { a, b in photoRank(a) < photoRank(b) }
    }

    // MARK: - Helpers

    static func matches(_ format: FormatDescriptor, resolution: VideoResolution, colorMode: VideoColorMode) -> Bool {
        let size = resolution.dimensions
        let sizeMatches = (format.width == size.width && format.height == size.height)
            || (format.width == size.height && format.height == size.width)
        guard sizeMatches else { return false }
        switch colorMode {
        case .sdr: return true
        case .hdr: return format.supportsHLG || format.supportsVideoHDR
        case .appleLog: return format.supportsAppleLog
        case .appleLog2: return format.supportsAppleLog2
        }
    }

    static func supports(_ format: FormatDescriptor, frameRate: Double) -> Bool {
        format.maxFrameRate >= frameRate - 0.01 && format.minFrameRate <= frameRate + 0.01
    }

    /// Lexicographic rank, smaller is better. Tuples compare element by element.
    private static func videoRank(_ f: FormatDescriptor, colorMode: VideoColorMode) -> (Int, Int, Double, Int, Int) {
        let wantsTenBit = colorMode != .sdr
        let bitDepthPenalty: Int
        if wantsTenBit {
            bitDepthPenalty = f.is10Bit ? 0 : 1
        } else {
            bitDepthPenalty = (f.pixelFormat == "420v" || f.pixelFormat == "420f") ? 0 : 1
        }
        return (bitDepthPenalty, f.isBinned ? 1 : 0, f.maxFrameRate, -f.maxPhotoPixels, f.index)
    }

    private static func photoRank(_ f: FormatDescriptor) -> (Int, Double, Double, Int, Int, Int) {
        let isoRatio = f.minISO > 0 ? f.maxISO / f.minISO : 0
        let pixelPenalty = f.pixelFormat == "420f" ? 0 : 1
        return (-f.maxPhotoPixels, -f.maxExposure, -isoRatio, f.isBinned ? 1 : 0, pixelPenalty, f.index)
    }
}
