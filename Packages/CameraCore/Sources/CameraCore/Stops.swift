import Foundation

/// How finely a dial divides one stop. The raw value is the number of steps per stop, so the math can divide by it.
public enum StopStep: Int, Codable, Sendable, CaseIterable {
    case full = 1, half = 2, third = 3
}

/// An exposure time in seconds, with the labels and dial values cameras use for it.
public struct ShutterSpeed: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var seconds: Double

    /// Non-finite or non-positive input becomes 1e-6 s, so `stops` and the labels never meet log2(0) or 1/0.
    public init(seconds: Double) {
        self.seconds = Self.usable(seconds)
    }

    /// Decodes through `init(seconds:)` so a stored zero or negative time cannot come back.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seconds: try container.decode(Double.self, forKey: .seconds))
    }

    /// 1/denominator seconds: `.fraction(250)` is 1/250 s.
    public static func fraction(_ denominator: Double) -> ShutterSpeed {
        ShutterSpeed(seconds: 1 / denominator)
    }

    public static func < (lhs: ShutterSpeed, rhs: ShutterSpeed) -> Bool {
        lhs.seconds < rhs.seconds
    }

    // MARK: - Nominal values

    /// Ascending seconds. The 0.3 s position is stored as exactly 1/3 because its label reads "1/3".
    public static let nominalThirdStops: [Double] = list(
        reciprocalsOf: [
            128000, 100000, 80000, 64000, 50000, 40000, 32000, 25000, 20000, 16000, 12800, 10000,
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400,
            320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3,
        ],
        then: [
            0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80,
            100, 120, 150, 180, 240, 300, 360, 480, 600, 720, 900, 1200, 1500, 1800, 2400, 3000, 3600,
        ]
    )

    /// Ascending seconds. 0.35 s keeps its true half-stop value and still reads "1/3".
    public static let nominalHalfStops: [Double] = list(
        reciprocalsOf: [
            128000, 96000, 64000, 48000, 32000, 24000, 16000, 12000, 8000, 6000, 4000, 3000, 2000, 1500,
            1000, 750, 500, 350, 250, 180, 125, 90, 60, 45, 30, 20, 15, 10, 8, 6, 4,
        ],
        then: [
            0.35, 0.5, 0.7, 1, 1.5, 2, 3, 4, 6, 8, 11, 15, 22, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720,
            960, 1440, 1800, 2700, 3600,
        ]
    )

    /// Ascending seconds.
    public static let nominalFullStops: [Double] = list(
        reciprocalsOf: [128000, 64000, 32000, 16000, 8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4],
        then: [0.5, 1, 2, 4, 8, 15, 30, 60, 120, 240, 480, 960, 1800, 3600]
    )

    public static func nominal(_ step: StopStep) -> [Double] {
        switch step {
        case .full: return nominalFullStops
        case .half: return nominalHalfStops
        case .third: return nominalThirdStops
        }
    }

    /// Nominal values of `step` inside [minSeconds, maxSeconds] (2% tolerance at both ends), plus the exact
    /// endpoints when the closest nominal value is more than 1/6 stop away from them. Ascending, no duplicates
    /// (values within 1% are the same). minSeconds > maxSeconds swaps them.
    /// "Closest" looks only at the nominal values kept, because only those can stand in for the limit on the dial.
    /// A NaN, infinite or non-positive limit leaves that side open.
    public static func scale(minSeconds: Double, maxSeconds: Double, step: StopStep = .third) -> [ShutterSpeed] {
        let limits = StopScaleRules.limits(minSeconds, maxSeconds)
        let values = StopScaleRules.scale(nominal: nominal(step), limits: limits, stopsPerDoubling: 1) { $0 }
        return values.map { ShutterSpeed(seconds: $0) }
    }

    /// Closest element by |log2 ratio|. Empty scale returns self. Ties keep the earlier element.
    public func nearest(in scale: [ShutterSpeed]) -> ShutterSpeed {
        let target = Self.usable(seconds)
        let found = StopScaleRules.nearestIndex(to: target, count: scale.count) { Self.usable(scale[$0].seconds) }
        guard let index = found else { return self }
        return scale[index]
    }

    // MARK: - Display

    /// log2(seconds), so one more stop of light is +1.
    public var stops: Double {
        log2(Self.usable(seconds))
    }

    /// Cameras write times below 0.4 s as 1/x.
    public var isFraction: Bool {
        Self.usable(seconds) < 0.4
    }

    /// < 0.4 s: "1/" + Int(round(1/seconds)) e.g. "1/8000", "1/250", "1/3".
    /// 0.4 ..< 10: one decimal, trailing ".0" dropped, then "s": "0.4s", "0.5s", "1s", "1.3s", "2.5s", "7.3s".
    /// 10 ..< 60: rounded integer + "s": "13s", "30s".
    /// >= 60: minutes and seconds, rounded to whole seconds: "1m", "1m30s", "2m", "10m"; >= 3600: "1h", "1h5m", "2h".
    public var label: String {
        let value = Self.usable(seconds)
        if value < 0.4 {
            return "1/" + String(StopScaleRules.roundedInt(1 / value))
        }
        if value < 10 {
            return Formatting.trimmed(value, decimals: 1) + "s"
        }
        // Round before picking the unit, so 59.6 s reads "1m" and never "60s".
        let whole = StopScaleRules.roundedInt(value)
        if whole < 60 {
            return "\(whole)s"
        }
        if whole < 3600 {
            let minutes = whole / 60
            let secs = whole % 60
            return secs == 0 ? "\(minutes)m" : "\(minutes)m\(secs)s"
        }
        // Past an hour single seconds no longer matter on a dial, so whole minutes it is.
        let totalMinutes = StopScaleRules.roundedInt(value / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
    }

    /// Dial tick label: fractions show the denominator only ("250"), longer speeds use `label` ("2.5s").
    public var compactLabel: String {
        let value = Self.usable(seconds)
        return value < 0.4 ? String(StopScaleRules.roundedInt(1 / value)) : label
    }

    public var description: String { label }

    // MARK: - Parsing

    /// Accepts "1/250", "1/250s", "0.5", "0.5s", "2s", "30", "90s", "2m", "1m30s", "1h", "1h5m",
    /// case-insensitive, whitespace ignored, also the unicode double prime ″ as seconds. nil if not > 0.
    /// Also takes the prime ′ for minutes ("2′30″"), the quote marks keyboards type for both marks, and a bare
    /// number after a unit as the next smaller unit ("1h30" is 1h30m), the way durations are said out loud.
    public init?(parsing text: String) {
        var cleaned = ""
        for character in text.lowercased() where !character.isWhitespace {
            switch character {
            case "\u{2033}", "\"", "\u{201D}": cleaned.append("s")
            case "\u{2032}", "'", "\u{2019}": cleaned.append("m")
            default: cleaned.append(character)
            }
        }
        guard let seconds = Self.parsedSeconds(cleaned), seconds.isFinite, seconds > 0 else { return nil }
        self.init(seconds: seconds)
    }

    // MARK: - Helpers

    private enum CodingKeys: String, CodingKey {
        case seconds
    }

    /// Seconds per unit, indexed by `unitIndex`.
    private static let unitSeconds: [Double] = [3600, 60, 1]

    /// `seconds` is a public var, so the computed properties clean it again instead of trusting init.
    private static func usable(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 1e-6
    }

    /// Building fractions from denominators keeps the literal lists short and each value exactly 1.0 / x.
    private static func list(reciprocalsOf denominators: [Double], then seconds: [Double]) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(denominators.count + seconds.count)
        for denominator in denominators {
            values.append(1 / denominator)
        }
        values.append(contentsOf: seconds)
        return values
    }

    /// Units must come in this order (h, m, s), each at most once.
    private static func unitIndex(_ character: Character) -> Int? {
        switch character {
        case "h": return 0
        case "m": return 1
        case "s": return 2
        default: return nil
        }
    }

    private static func parsedSeconds(_ text: String) -> Double? {
        if let slash = text.firstIndex(of: "/") {
            var denominator = text[text.index(after: slash)...]
            if denominator.hasSuffix("s") {
                denominator = denominator.dropLast()
            }
            guard let top = plainNumber(text[..<slash]), let bottom = plainNumber(denominator), bottom > 0 else {
                return nil
            }
            return top / bottom
        }
        var total = 0.0
        var pending = ""
        var lastUnit = -1
        for character in text {
            if character == "." || (character.isASCII && character.isNumber) {
                pending.append(character)
                continue
            }
            guard let unit = unitIndex(character), unit > lastUnit, let value = plainNumber(pending) else {
                return nil
            }
            total += value * unitSeconds[unit]
            lastUnit = unit
            pending = ""
        }
        if pending.isEmpty {
            return lastUnit >= 0 ? total : nil
        }
        // A bare number takes the unit after the last one, or seconds when no unit came before it.
        let unit = lastUnit < 0 ? 2 : lastUnit + 1
        guard unit < unitSeconds.count, let value = plainNumber(pending) else { return nil }
        return total + value * unitSeconds[unit]
    }

    /// ASCII digits with at most one decimal point. Double(_:) on its own would also take "1e3", "inf" or "nan".
    private static func plainNumber<S: StringProtocol>(_ text: S) -> Double? {
        var digits = 0
        var points = 0
        for character in text {
            if character == "." {
                points += 1
            } else if character.isASCII, character.isNumber {
                digits += 1
            } else {
                return nil
            }
        }
        guard digits > 0, points <= 1 else { return nil }
        return Double(text)
    }
}

/// ISO dial values and labels. Sensor gain is linear in light, so one stop is a doubling.
public enum ISOScale {
    /// 1/3 stops: 12, 16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000,
    /// 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000,
    /// 51200, 64000, 80000, 102400
    public static let nominalThirdStops: [Double] = [
        12, 16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000,
        1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000,
        51200, 64000, 80000, 102400,
    ]

    /// half: 12, 17, 25, 35, 50, 70, 100, 140, 200, 280, 400, 560, 800, 1100, 1600, 2200, 3200, 4500, 6400, 9000,
    /// 12800, 18000, 25600, 36000, 51200, 72000, 102400
    public static let nominalHalfStops: [Double] = [
        12, 17, 25, 35, 50, 70, 100, 140, 200, 280, 400, 560, 800, 1100, 1600, 2200, 3200, 4500, 6400, 9000,
        12800, 18000, 25600, 36000, 51200, 72000, 102400,
    ]

    /// full: 12, 25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400
    public static let nominalFullStops: [Double] = [
        12, 25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400,
    ]

    /// Same endpoint rules as ShutterSpeed.scale; exact endpoints are rounded to whole numbers.
    public static func scale(min: Double, max: Double, step: StopStep = .third) -> [Double] {
        let limits = StopScaleRules.limits(min, max)
        // Sensors report limits like 33.6; the dial reads whole numbers and the camera clamps the rest.
        return StopScaleRules.scale(nominal: nominal(step), limits: limits, stopsPerDoubling: 1) { limit in
            Swift.max(1, limit.rounded())
        }
    }

    /// Closest element by |log2 ratio|; an empty scale returns `iso`. Ties keep the earlier element.
    public static func nearest(_ iso: Double, in scale: [Double]) -> Double {
        guard let index = StopScaleRules.nearestIndex(to: iso, in: scale) else { return iso }
        return scale[index]
    }

    /// "ISO 400" (rounded integer). Non-finite or negative values read "ISO 0".
    public static func label(_ iso: Double) -> String {
        "ISO " + compactLabel(iso)
    }

    /// "400"
    public static func compactLabel(_ iso: Double) -> String {
        String(StopScaleRules.roundedInt(iso.isFinite && iso > 0 ? iso : 0))
    }

    private static func nominal(_ step: StopStep) -> [Double] {
        switch step {
        case .full: return nominalFullStops
        case .half: return nominalHalfStops
        case .third: return nominalThirdStops
        }
    }
}

/// Aperture dial values and labels. Light goes with 1/N^2, so one stop is a factor of sqrt(2) in f-number.
public enum ApertureScale {
    /// 1/3 stops: 0.95, 1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1,
    /// 8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22
    public static let nominalThirdStops: [Double] = [
        0.95, 1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1,
        8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22,
    ]

    /// half: 0.95, 1.0, 1.2, 1.4, 1.7, 2.0, 2.4, 2.8, 3.3, 4.0, 4.8, 5.6, 6.7, 8.0, 9.5, 11, 13, 16, 19, 22
    public static let nominalHalfStops: [Double] = [
        0.95, 1.0, 1.2, 1.4, 1.7, 2.0, 2.4, 2.8, 3.3, 4.0, 4.8, 5.6, 6.7, 8.0, 9.5, 11, 13, 16, 19, 22,
    ]

    /// full: 1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16, 22
    public static let nominalFullStops: [Double] = [1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16, 22]

    /// If `recommended` is non-empty (iOS 27 Format.recommendedLensApertureStops): those values inside
    /// [min, max] (2% tolerance), sorted ascending, deduplicated (1%), plus exact min and max endpoints if absent.
    /// Otherwise nominal values of `step` inside the range plus exact endpoints (same 1/6-stop rule; aperture
    /// stops use log2(N^2), i.e. 1 stop = factor sqrt(2) in f-number). min == max returns [min].
    /// A limit counts as present when a kept value lies within the same 2% band that let values in.
    /// Recommended entries that are not f-numbers (NaN, infinite, <= 0) are ignored; a list of only those is empty.
    public static func scale(min: Double, max: Double, recommended: [Double] = [], step: StopStep = .third) -> [Double] {
        let limits = StopScaleRules.limits(min, max)
        // Within 1% is one aperture, the same test ExposureRanges.hasVariableAperture applies.
        if let lower = limits.lower, let upper = limits.upper,
           StopScaleRules.isNear(lower, upper, slack: StopScaleRules.sameValueSlack) {
            return [lower]
        }
        var usable: [Double] = []
        for value in recommended where value.isFinite && value > 0 {
            usable.append(value)
        }
        guard !usable.isEmpty else {
            return StopScaleRules.scale(nominal: nominal(step), limits: limits, stopsPerDoubling: 2) { $0 }
        }
        var values: [Double] = []
        for value in usable where StopScaleRules.contains(value, limits) {
            values.append(value)
        }
        for limit in [limits.lower, limits.upper] {
            guard let limit else { continue }
            let present = values.contains { StopScaleRules.isNear($0, limit, slack: StopScaleRules.rangeSlack) }
            if !present {
                values.append(limit)
            }
        }
        return StopScaleRules.sortedUnique(values)
    }

    /// Closest element by |log2 ratio|; an empty scale returns `f`. Ties keep the earlier element.
    public static func nearest(_ f: Double, in scale: [Double]) -> Double {
        guard let index = StopScaleRules.nearestIndex(to: f, in: scale) else { return f }
        return scale[index]
    }

    /// "ƒ/1.8": below 10, one decimal if f is within 0.005 of a one-decimal value, else two decimals ("ƒ/1.78");
    /// >= 10: whole number ("ƒ/11"). Uses the ƒ character (U+0192). Non-finite or non-positive input reads "ƒ/0.0".
    public static func label(_ f: Double) -> String {
        "\u{0192}/" + compactLabel(f)
    }

    /// Same number without "ƒ/": "1.8", "1.78", "11".
    public static func compactLabel(_ f: Double) -> String {
        let value = f.isFinite && f > 0 ? f : 0
        let oneDecimal = (value * 10).rounded() / 10
        // The epsilon keeps decimal boundary values such as 1.795 on the one-decimal side despite binary rounding.
        let isOneDecimal = abs(value - oneDecimal) <= 0.005 + 1e-9
        // 9.997 rounds to 10.0, which belongs with the whole numbers.
        if value >= 10 || (isOneDecimal && oneDecimal >= 10) {
            return String(StopScaleRules.roundedInt(value))
        }
        return isOneDecimal ? String(format: "%.1f", oneDecimal) : String(format: "%.2f", value)
    }

    private static func nominal(_ step: StopStep) -> [Double] {
        switch step {
        case .full: return nominalFullStops
        case .half: return nominalHalfStops
        case .third: return nominalThirdStops
        }
    }
}

/// Exposure compensation text and dial values.
public enum EVFormat {
    /// Real bias ranges are a few EV; the cap keeps a bad range from allocating a huge array.
    static let maxScaleRange = 100.0

    /// Round to 0.1. "0" when |ev| < 0.05. Otherwise always signed, ".0" dropped: "+1", "+0.3", "-1.7", "+2.3".
    /// Use the ASCII hyphen-minus for negative numbers. A non-finite value reads "0".
    public static func label(_ ev: Double) -> String {
        guard ev.isFinite, abs(ev) >= 0.05 else { return "0" }
        // The cap keeps the Int conversion inside Formatting.trimmed in range for absurd input.
        let tenths = (Swift.min(abs(ev), 1e9) * 10).rounded()
        guard tenths > 0 else { return "0" }
        return (ev > 0 ? "+" : "-") + Formatting.trimmed(tenths / 10, decimals: 1)
    }

    /// Snap to nearest multiple of 1/step (third: 1/3, half: 1/2, full: 1). Halfway values round away from zero.
    /// A non-finite value has no nearest stop and returns 0.
    public static func snap(_ ev: Double, step: StopStep) -> Double {
        guard ev.isFinite else { return 0 }
        let divisions = Double(step.rawValue)
        let snapped = (ev * divisions).rounded() / divisions
        guard snapped.isFinite else { return ev }
        // -0.0 would print as "-0.0" and look like a negative bias.
        return snapped == 0 ? 0 : snapped
    }

    /// Values from -range to +range (inclusive) at 1/step spacing, ascending. range <= 0 returns [0].
    /// Ranges past 100 EV are capped.
    public static func scale(range: Double, step: StopStep = .third) -> [Double] {
        guard range > 0 else { return [0] }
        let divisions = Double(step.rawValue)
        // Bias limits arrive as Float, and Float(7.0 / 3.0) sits just below 7/3. A millionth of slack absorbs that
        // rounding without letting in a value that is really past the range, as 1/3 is for a range of 0.33.
        let count = Int((Swift.min(range, maxScaleRange) * divisions * (1 + 1e-6)).rounded(.down))
        var values: [Double] = []
        values.reserveCapacity(2 * count + 1)
        for index in -count...count {
            // Computed from the index rather than accumulated, so 8 EV in thirds ends at exactly 8.
            values.append(Double(index) / divisions)
        }
        return values
    }
}

// MARK: - Shared scale rules

/// Range rules shared by the shutter, ISO and aperture dials, so all three end at the hardware limits the same way.
private enum StopScaleRules {
    /// Hardware limits come back with float noise (1/8000 s as 0.000125000001), so a value this close to a limit
    /// still counts as inside it.
    static let rangeSlack = 0.02
    /// Values closer than this would be the same dial position.
    static let sameValueSlack = 0.01
    /// An exact limit only earns its own dial position when no kept value is near it.
    static let endpointGap = 1.0 / 6.0

    struct Limits {
        var lower: Double?
        var upper: Double?
    }

    /// A NaN, infinite or non-positive limit carries no information, so that side stays open.
    static func limits(_ a: Double, _ b: Double) -> Limits {
        let first: Double? = a.isFinite && a > 0 ? a : nil
        let second: Double? = b.isFinite && b > 0 ? b : nil
        if let first, let second, first > second {
            return Limits(lower: second, upper: first)
        }
        return Limits(lower: first, upper: second)
    }

    static func contains(_ value: Double, _ limits: Limits) -> Bool {
        if let lower = limits.lower, value < lower * (1 - rangeSlack) { return false }
        if let upper = limits.upper, value > upper * (1 + rangeSlack) { return false }
        return true
    }

    /// Nominal values inside the limits, plus each limit (passed through `endpoint`) that is more than 1/6 stop
    /// from every kept value. `stopsPerDoubling` is 2 for f-numbers, where one stop is a factor of sqrt(2).
    static func scale(nominal: [Double], limits: Limits, stopsPerDoubling: Double, endpoint: (Double) -> Double) -> [Double] {
        var values: [Double] = []
        for value in nominal where contains(value, limits) {
            values.append(value)
        }
        // Both limits are judged against the nominal values only, so two limits close together both survive.
        var added: [Double] = []
        for limit in [limits.lower, limits.upper] {
            guard let limit else { continue }
            if closestGap(to: limit, in: values) * stopsPerDoubling > endpointGap {
                added.append(endpoint(limit))
            }
        }
        return sortedUnique(values + added)
    }

    /// Distance in doublings from `value` to the closest of `values`; infinity when there are none.
    static func closestGap(to value: Double, in values: [Double]) -> Double {
        var best = Double.infinity
        for candidate in values {
            best = Swift.min(best, abs(log2(value) - log2(candidate)))
        }
        return best
    }

    static func isNear(_ a: Double, _ b: Double, slack: Double) -> Bool {
        Swift.max(a, b) <= Swift.min(a, b) * (1 + slack)
    }

    /// Ascending, keeping the first of any run of values within 1% of each other.
    static func sortedUnique(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for value in values.sorted() {
            if let last = result.last, isNear(last, value, slack: sameValueSlack) { continue }
            result.append(value)
        }
        return result
    }

    /// Index of the element closest in stops, ties keep the earlier element; nil for an empty scale.
    static func nearestIndex(to target: Double, count: Int, value: (Int) -> Double) -> Int? {
        guard count > 0 else { return nil }
        let goal = finiteLog2(target)
        var bestIndex = 0
        var bestGap = Double.infinity
        for index in 0..<count {
            let gap = abs(finiteLog2(value(index)) - goal)
            if gap < bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        return bestIndex
    }

    static func nearestIndex(to target: Double, in values: [Double]) -> Int? {
        nearestIndex(to: target, count: values.count) { values[$0] }
    }

    /// log2 that stays finite: zero, negative and NaN act as the smallest positive value and infinity as the
    /// largest, so a bad value still lands on an end of the scale instead of an arbitrary element.
    static func finiteLog2(_ x: Double) -> Double {
        guard x > 0 else { return log2(Double.leastNonzeroMagnitude) }
        return x.isFinite ? log2(x) : log2(Double.greatestFiniteMagnitude)
    }

    /// Int(value.rounded()) for labels that saturates instead of trapping on huge values; NaN reads as 0.
    static func roundedInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(Swift.min(Swift.max(value, -1e15), 1e15).rounded())
    }
}
