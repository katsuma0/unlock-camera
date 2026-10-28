import Foundation

/// What a bracket varies from frame to frame.
public enum BracketKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, exposure, focus, whiteBalance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .exposure: return "Exposure"
        case .focus: return "Focus"
        case .whiteBalance: return "White balance"
        }
    }
}

/// A burst of frames that differ in exposure, focus or white balance.
/// The methods apply the limits of `kind` again, because the properties stay mutable after init.
public struct BracketPlan: Hashable, Codable, Sendable {
    public var kind: BracketKind
    /// exposure / whiteBalance: odd, 3...9 (even rounds up, clamped). focus: 2...30. Kept as given for .off.
    public var count: Int
    /// exposure: EV per step, clamped 0.3...3. focus: lens position step, 0.005...0.5. white balance: mireds, 5...100.
    public var step: Double

    /// Applies the clamps for `kind`. `.off` keeps count and step so the bracket comes back as it was when the
    /// user turns it on again; only a non-finite step is replaced, because JSON cannot store it.
    public init(kind: BracketKind = .off, count: Int = 3, step: Double = 1) {
        self.kind = kind
        self.count = Self.limitedCount(count, for: kind)
        self.step = Self.limitedStep(step, for: kind)
    }

    /// Missing or unreadable fields fall back to the defaults and the clamps run again,
    /// so settings saved by another app version still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try? container.decodeIfPresent(BracketKind.self, forKey: .kind)
        let count = try? container.decodeIfPresent(Int.self, forKey: .count)
        let step = try? container.decodeIfPresent(Double.self, forKey: .step)
        self.init(kind: kind ?? .off, count: count ?? 3, step: step ?? 1)
    }

    public static let off = BracketPlan()

    public var isOff: Bool { kind == .off }

    /// Center first, then alternating below/above: count 5, step 1 -> [0, -1, 1, -2, 2]. .off -> [0].
    /// Focus and white balance brackets keep one exposure, so they also return [0].
    public func exposureOffsets() -> [Double] {
        guard kind == .exposure else { return [0] }
        let step = Self.limitedStep(self.step, for: kind)
        var offsets: [Double] = []
        for multiple in Self.centerFirstMultiples(Self.limitedCount(count, for: kind)) {
            offsets.append(Double(multiple) * step)
        }
        return offsets
    }

    /// Manual bracket around `base`: for each offset change shutter first (seconds * 2^offset) keeping ISO and
    /// aperture; if seconds leaves ranges.seconds, clamp it and put the remaining stops into ISO; clamp ISO.
    /// `base` is clamped into `ranges` first. Kinds other than exposure return the single clamped base.
    public func exposures(around base: ExposureValues, ranges: ExposureRanges) -> [ExposureValues] {
        let start = ranges.clamp(base)
        var result: [ExposureValues] = []
        for offset in exposureOffsets() {
            let wanted = start.seconds * pow(2, offset)
            let seconds = ExposureMath.clamp(wanted, to: ranges.seconds)
            // The stops the shutter could not take move to ISO, so the spacing survives at the shutter limits.
            let leftover = seconds > 0 ? wanted / seconds : 1
            let iso = ExposureMath.clamp(start.iso * leftover, to: ranges.iso)
            result.append(ExposureValues(seconds: seconds, iso: iso, aperture: start.aperture))
        }
        return result
    }

    /// `count` positions evenly spaced by `step`, centred on `center`, shifted (not squashed) to stay inside
    /// 0...1 when possible, then clamped; ascending; duplicates removed. .off (and any kind but focus) -> [center].
    /// `center` is clamped to 0...1 first, since AVFoundation rejects lens positions outside it.
    public func focusPositions(center: Double) -> [Double] {
        let middle = ExposureMath.clamp(center, 0, 1)
        guard kind == .focus else { return [middle] }
        let count = Self.limitedCount(self.count, for: kind)
        let step = Self.limitedStep(self.step, for: kind)
        let span = Double(count - 1) * step
        var start = middle - span / 2
        // Shifting keeps the spacing the user picked; squashing would silently change the step.
        if span <= 1 {
            if start < 0 {
                start = 0
            } else if start + span > 1 {
                start = 1 - span
            }
        }
        var positions: [Double] = []
        positions.reserveCapacity(count)
        for i in 0..<count {
            let position = ExposureMath.clamp(start + Double(i) * step, 0, 1)
            // A run wider than 0...1 piles frames on the ends; one frame per position is enough.
            if let last = positions.last, position - last < 1e-9 { continue }
            positions.append(position)
        }
        return positions
    }

    /// Kelvin values at mired offsets in the exposureOffsets order (0, -s, +s, ...) where mired = 1e6 / K,
    /// each clamped to 1000...40000 K. .off (and any kind but white balance) -> [center].
    /// `center` is clamped into 1000...40000 K first, so an out-of-range center still gives a usable spread.
    public func kelvinValues(center: Double) -> [Double] {
        let middle = ExposureMath.clamp(center, to: Self.kelvinLimits)
        guard kind == .whiteBalance else { return [middle] }
        // Equal mired steps look like equal color shifts at any temperature; equal Kelvin steps would not.
        let centerMired = 1e6 / middle
        let step = Self.limitedStep(self.step, for: kind)
        var values: [Double] = []
        for multiple in Self.centerFirstMultiples(Self.limitedCount(count, for: kind)) {
            let mired = centerMired + Double(multiple) * step
            // Zero or negative mireds would be bluer than any light, so they pin to the top of the range.
            let kelvin = mired > 0 ? 1e6 / mired : Self.kelvinLimits.upperBound
            values.append(ExposureMath.clamp(kelvin, to: Self.kelvinLimits))
        }
        return values
    }

    /// "Off", "3 × ±1 EV", "5 × ±0.7 EV", "Focus × 8", "WB 3 × ±10 mired".
    public var summary: String {
        let count = Self.limitedCount(self.count, for: kind)
        let step = Self.trimmed(Self.limitedStep(self.step, for: kind))
        switch kind {
        case .off: return "Off"
        case .exposure: return "\(count) \u{00D7} \u{00B1}\(step) EV"
        case .focus: return "Focus \u{00D7} \(count)"
        case .whiteBalance: return "WB \(count) \u{00D7} \u{00B1}\(step) mired"
        }
    }

    // MARK: - Helpers

    /// What the device's temperature conversion is given. Wider than the dial, so Candle (1900 K) and the dial's
    /// ends bracket around their own value instead of repeating a clamped frame.
    private static let kelvinLimits: ClosedRange<Double> = 1000...40000

    private static func limitedCount(_ count: Int, for kind: BracketKind) -> Int {
        switch kind {
        case .off:
            return count
        case .exposure, .whiteBalance:
            // Odd so the base frame sits in the middle with as many frames on each side.
            let clamped = Swift.min(Swift.max(count, 3), 9)
            return clamped % 2 == 0 ? clamped + 1 : clamped
        case .focus:
            return Swift.min(Swift.max(count, 2), 30)
        }
    }

    private static func limitedStep(_ step: Double, for kind: BracketKind) -> Double {
        // NaN gets the default step instead of a bound: it says nothing about which end the user wanted.
        let value = step.isNaN ? 1 : step
        switch kind {
        case .off: return value.isFinite ? value : 1
        case .exposure: return ExposureMath.clamp(value, 0.3, 3)
        case .focus: return ExposureMath.clamp(value, 0.005, 0.5)
        case .whiteBalance: return ExposureMath.clamp(value, 5, 100)
        }
    }

    /// 0, -1, 1, -2, 2, ...: the unchanged frame comes first, so a burst cut short still has the metered shot.
    private static func centerFirstMultiples(_ count: Int) -> [Int] {
        let total = Swift.max(count, 0)
        var multiples: [Int] = []
        multiples.reserveCapacity(total)
        for i in 0..<total {
            let k = (i + 1) / 2
            multiples.append(i % 2 == 1 ? -k : k)
        }
        return multiples
    }

    /// One decimal with ".0" dropped: 1.0 -> "1", 0.67 -> "0.7".
    private static func trimmed(_ value: Double) -> String {
        guard value.isFinite, value.magnitude < 1e15 else { return "\(value)" }
        let tenths = Int((value * 10).rounded())
        let whole = tenths / 10
        let fraction = abs(tenths % 10)
        if fraction == 0 { return "\(whole)" }
        let sign = tenths < 0 && whole == 0 ? "-" : ""
        return "\(sign)\(whole).\(fraction)"
    }
}
