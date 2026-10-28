import Foundation

/// Per-channel gains in the shape AVCaptureDevice.WhiteBalanceGains takes them.
public struct WhiteBalanceGains: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Named light sources for the white balance picker.
public enum WhiteBalancePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, daylight, cloudy, shade, tungsten, fluorescent, flash, candle

    public var id: String { rawValue }

    /// Color temperature the preset locks to. nil for auto, where the camera keeps choosing.
    public var kelvin: Double? {
        switch self {
        case .auto: return nil
        case .daylight: return 5500
        case .cloudy: return 6500
        case .shade: return 7500
        case .tungsten: return 3200
        case .fluorescent: return 4000
        case .flash: return 5600
        case .candle: return 1900
        }
    }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .daylight: return "Daylight"
        case .cloudy: return "Cloudy"
        case .shade: return "Shade"
        case .tungsten: return "Tungsten"
        case .fluorescent: return "Fluorescent"
        case .flash: return "Flash"
        case .candle: return "Candle"
        }
    }

    /// SF Symbols name for the picker.
    public var symbolName: String {
        switch self {
        case .auto: return "a.circle"
        case .daylight: return "sun.max"
        case .cloudy: return "cloud"
        case .shade: return "building.2"
        case .tungsten: return "lightbulb"
        case .fluorescent: return "light.panel"
        case .flash: return "bolt"
        case .candle: return "flame"
        }
    }
}

/// Color temperature math for the white balance dial, the presets and the gains AVFoundation accepts.
public enum WhiteBalanceMath {
    public static let kelvinRange: ClosedRange<Double> = 2000...10000
    public static let tintRange: ClosedRange<Double> = -150...150

    /// 1e6 / K. Equal mired steps look like equal color shifts, which equal Kelvin steps do not.
    /// Non-positive or NaN Kelvin returns 0.
    public static func mired(_ kelvin: Double) -> Double {
        guard kelvin > 0 else { return 0 }
        return 1_000_000 / kelvin
    }

    /// 1e6 / mired. Non-positive or NaN mired returns `kelvinRange.upperBound`.
    public static func kelvin(mired: Double) -> Double {
        guard mired > 0 else { return kelvinRange.upperBound }
        return 1_000_000 / mired
    }

    /// AVFoundation needs every gain in [1, maxGain]. Dividing by the smallest channel makes it exactly 1 and keeps
    /// the color ratios; only then is each channel capped at `maxGain` (below 1 or NaN counts as 1).
    /// Non-finite or non-positive channels count as 1.
    public static func normalized(_ g: WhiteBalanceGains, maxGain: Double) -> WhiteBalanceGains {
        let red = usableGain(g.red)
        let green = usableGain(g.green)
        let blue = usableGain(g.blue)
        let smallest = Swift.min(red, green, blue)
        let cap = maxGain >= 1 ? maxGain : 1
        return WhiteBalanceGains(
            red: Swift.min(red / smallest, cap),
            green: Swift.min(green / smallest, cap),
            blue: Swift.min(blue / smallest, cap)
        )
    }

    /// `count` Kelvin values evenly spaced in mireds across `range`, rounded to 50 K, ascending, deduplicated.
    /// Mired spacing puts more ticks at the warm end, where a hundred Kelvin is a visible shift.
    /// The first value is always the rounded lower bound, so a count of 1 returns just that one.
    /// A count below 1, or an upper bound that is infinite or under 50 K, returns an empty scale.
    public static func kelvinScale(range: ClosedRange<Double> = kelvinRange, count: Int = 41) -> [Double] {
        let upper = range.upperBound
        guard count > 0, upper.isFinite, upper >= kelvinStep else { return [] }
        // 0 K and below have no mired value and anything under 25 K rounds to 0 K, so the warm end starts at one step.
        let lower = range.lowerBound > kelvinStep ? range.lowerBound : kelvinStep
        guard count > 1 else { return [roundedKelvin(lower)] }
        // Caps the loop for absurd counts; no dial needs anywhere near this many ticks.
        let n = Swift.min(count, 10_000)
        let warmMired = 1_000_000 / lower
        let coolMired = 1_000_000 / upper
        var values: [Double] = []
        values.reserveCapacity(n)
        for i in 0..<n {
            let k: Double
            // The ends use the bounds as given, so 1e6 / (1e6 / K) rounding can't push them across a 50 K step.
            switch i {
            case 0: k = lower
            case n - 1: k = upper
            default: k = 1_000_000 / (warmMired + (coolMired - warmMired) * Double(i) / Double(n - 1))
            }
            let rounded = roundedKelvin(k)
            if let last = values.last, rounded <= last { continue }
            values.append(rounded)
        }
        return values
    }

    /// Nearest preset within 100 K. Presets carry no tint, so a tint more than 5 from neutral matches none.
    /// Ties go to the earlier case: 5550 K reads as daylight, not flash.
    public static func matchingPreset(kelvin: Double, tint: Double) -> WhiteBalancePreset? {
        guard kelvin.isFinite, abs(tint) <= 5 else { return nil }
        var best: WhiteBalancePreset?
        var bestDistance = Double.infinity
        for preset in WhiteBalancePreset.allCases {
            guard let presetKelvin = preset.kelvin else { continue }
            let distance = abs(presetKelvin - kelvin)
            if distance < bestDistance {
                best = preset
                bestDistance = distance
            }
        }
        return bestDistance <= 100 ? best : nil
    }

    // MARK: - Helpers

    private static let kelvinStep = 50.0

    private static func roundedKelvin(_ k: Double) -> Double {
        (k / kelvinStep).rounded() * kelvinStep
    }

    private static func usableGain(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }
}
