import Foundation

/// One exposure: shutter in seconds, ISO, and aperture as an f-number.
public struct ExposureValues: Hashable, Codable, Sendable {
    public var seconds: Double
    public var iso: Double
    public var aperture: Double

    public init(seconds: Double, iso: Double, aperture: Double) {
        self.seconds = seconds
        self.iso = iso
        self.aperture = aperture
    }
}

/// What the active device format allows, plus the longest shutter auto exposure may choose.
public struct ExposureRanges: Hashable, Codable, Sendable {
    /// Per-frame hardware shutter range.
    public var seconds: ClosedRange<Double>
    public var iso: ClosedRange<Double>
    /// lowerBound == upperBound for a fixed aperture.
    public var aperture: ClosedRange<Double>
    /// Longest shutter auto exposure may pick (AE limit), clamped into `seconds` by init.
    public var maxAutoSeconds: Double

    public init(seconds: ClosedRange<Double>, iso: ClosedRange<Double>, aperture: ClosedRange<Double>,
                maxAutoSeconds: Double? = nil) {
        self.seconds = seconds
        self.iso = iso
        self.aperture = aperture
        self.maxAutoSeconds = Self.autoLimit(maxAutoSeconds, within: seconds)
    }

    /// Goes through `init`, so a stored AE limit is clamped exactly like a fresh one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(seconds: container.decode(ClosedRange<Double>.self, forKey: .seconds),
                      iso: container.decode(ClosedRange<Double>.self, forKey: .iso),
                      aperture: container.decode(ClosedRange<Double>.self, forKey: .aperture),
                      maxAutoSeconds: container.decodeIfPresent(Double.self, forKey: .maxAutoSeconds))
    }

    /// Fixed lenses can report bounds a rounding error apart, hence the 1% margin.
    public var hasVariableAperture: Bool {
        aperture.upperBound > aperture.lowerBound * 1.01
    }

    /// Every value moved into its range. NaN lands on the lower bound so it never reaches the device.
    public func clamp(_ v: ExposureValues) -> ExposureValues {
        ExposureValues(seconds: ExposureMath.clamp(v.seconds, to: seconds),
                       iso: ExposureMath.clamp(v.iso, to: iso),
                       aperture: ExposureMath.clamp(v.aperture, to: aperture))
    }

    /// The AE limit clamped again where it is used, because `maxAutoSeconds` can be reassigned after init.
    var autoSecondsLimit: Double {
        Self.autoLimit(maxAutoSeconds, within: seconds)
    }

    /// NaN says nothing about a limit, so like nil it means the longest hardware shutter.
    private static func autoLimit(_ wanted: Double?, within seconds: ClosedRange<Double>) -> Double {
        guard let wanted, !wanted.isNaN else { return seconds.upperBound }
        return ExposureMath.clamp(wanted, to: seconds)
    }
}

/// Exposure arithmetic in stops and light products.
/// Where a positive value is needed, zero, negative, NaN or infinite input returns 0: a log or a division on it
/// has no physical meaning, and 0 is easy for callers to test.
public enum ExposureMath {
    /// EV at ISO 100: log2(N^2 / t) - log2(ISO / 100). Sunny 16 (f/16, 1/100 s, ISO 100) is about 15.
    public static func ev100(_ v: ExposureValues) -> Double {
        guard isUsable(v) else { return 0 }
        return finiteOrZero(log2(v.aperture * v.aperture / v.seconds) - log2(v.iso / 100))
    }

    /// Relative light reaching the image: t * ISO / N^2. Image brightness is proportional to this.
    public static func lightProduct(_ v: ExposureValues) -> Double {
        guard isUsable(v) else { return 0 }
        return finiteOrZero(v.seconds * v.iso / (v.aperture * v.aperture))
    }

    /// log2(product(b) / product(a)). Positive = b is brighter. 0 when either side is unusable.
    public static func stops(from a: ExposureValues, to b: ExposureValues) -> Double {
        let productA = lightProduct(a)
        let productB = lightProduct(b)
        guard productA > 0, productB > 0 else { return 0 }
        return finiteOrZero(log2(productB / productA))
    }

    /// Shutter that reaches light product `p`: p * N^2 / iso.
    public static func seconds(forProduct p: Double, iso: Double, aperture: Double) -> Double {
        guard isPositive(p), isPositive(iso), isPositive(aperture) else { return 0 }
        return finiteOrZero(p * aperture * aperture / iso)
    }

    /// ISO that reaches light product `p`: p * N^2 / t.
    public static func iso(forProduct p: Double, seconds: Double, aperture: Double) -> Double {
        guard isPositive(p), isPositive(seconds), isPositive(aperture) else { return 0 }
        return finiteOrZero(p * aperture * aperture / seconds)
    }

    /// f-number that reaches light product `p`: sqrt(t * iso / p).
    public static func aperture(forProduct p: Double, seconds: Double, iso: Double) -> Double {
        guard isPositive(p), isPositive(seconds), isPositive(iso) else { return 0 }
        return finiteOrZero((seconds * iso / p).squareRoot())
    }

    /// angle / 360 / fps: 180 degrees at 24 fps is 1/48 s. 0 for a negative or non-finite angle or an unusable fps.
    public static func seconds(shutterAngle: Double, fps: Double) -> Double {
        guard shutterAngle.isFinite, shutterAngle >= 0, isPositive(fps) else { return 0 }
        return shutterAngle / 360 / fps
    }

    /// seconds * fps * 360. 0 for negative or non-finite seconds or an unusable fps.
    public static func shutterAngle(seconds: Double, fps: Double) -> Double {
        guard seconds.isFinite, seconds >= 0, isPositive(fps) else { return 0 }
        return finiteOrZero(seconds * fps * 360)
    }

    /// Slowest shutter that is usually sharp handheld: (1 / equivalentFocalLength) * 2^stabilizationStops.
    /// A focal length <= 0 or not finite is treated as 24; non-finite stops count as no stabilization.
    public static func handheldLimit(equivalentFocalLength: Double, stabilizationStops: Double = 2) -> Double {
        // 24 mm is the usual iPhone main camera, the best guess when the lens is unknown.
        let focalLength = isPositive(equivalentFocalLength) ? equivalentFocalLength : 24
        let stops = stabilizationStops.isFinite ? stabilizationStops : 0
        return (1 / focalLength) * pow(2, stops)
    }

    // MARK: - Helpers shared with the planners

    static func isPositive(_ x: Double) -> Bool {
        x.isFinite && x > 0
    }

    static func isUsable(_ v: ExposureValues) -> Bool {
        isPositive(v.seconds) && isPositive(v.iso) && isPositive(v.aperture)
    }

    static func finiteOrZero(_ x: Double) -> Double {
        x.isFinite ? x : 0
    }

    /// NaN goes to `lower`; plain min/max would pass it straight through to the device.
    static func clamp(_ x: Double, _ lower: Double, _ upper: Double) -> Double {
        guard !x.isNaN else { return lower }
        return Swift.min(Swift.max(x, lower), upper)
    }

    static func clamp(_ x: Double, to range: ClosedRange<Double>) -> Double {
        clamp(x, range.lowerBound, range.upperBound)
    }
}

/// Which exposure parameters the user has fixed. nil = automatic.
public struct ExposureLocks: Hashable, Codable, Sendable {
    public var seconds: Double?
    public var iso: Double?
    public var aperture: Double?

    public init(seconds: Double? = nil, iso: Double? = nil, aperture: Double? = nil) {
        self.seconds = seconds
        self.iso = iso
        self.aperture = aperture
    }

    public var isAllAuto: Bool {
        seconds == nil && iso == nil && aperture == nil
    }

    /// True when nothing is left for auto exposure to change. With a fixed aperture, aperture counts as locked.
    public func isFullyManual(variableAperture: Bool) -> Bool {
        seconds != nil && iso != nil && (aperture != nil || !variableAperture)
    }
}

/// How a camera's P mode turns one light product into a shutter and an ISO.
public enum ProgramLine {
    /// Split a light product into (seconds, iso) at a fixed aperture, like a camera's P mode:
    /// 1. at min ISO, t = p*N^2/minISO; if t <= min(handheldLimit, maxAutoSeconds) use it (clamped to >= min seconds).
    /// 2. otherwise hold t = min(handheldLimit, maxAutoSeconds) and raise ISO to reach p, up to max ISO.
    /// 3. if still short at max ISO, lengthen t up to maxAutoSeconds.
    /// 4. clamp everything to ranges (under/over exposure is allowed at the extremes).
    /// The aperture is clamped into `ranges.aperture` first, because that is the opening the device will use.
    /// A product that is NaN or <= 0 gives the shortest shutter at min ISO; NaN `handheldLimit` means no limit.
    public static func split(product: Double, aperture: Double, ranges: ExposureRanges,
                             handheldLimit: Double) -> (seconds: Double, iso: Double) {
        let minSeconds = ranges.seconds.lowerBound
        let maxAuto = ranges.autoSecondsLimit
        let minISO = ranges.iso.lowerBound
        let maxISO = ranges.iso.upperBound
        // NaN fails this test too and gets the brightest-scene answer; the next meter reading corrects it.
        guard product > 0 else { return (minSeconds, minISO) }
        let n = ExposureMath.clamp(aperture, to: ranges.aperture)
        let light = product * n * n
        let handheld = handheldLimit.isNaN ? maxAuto : handheldLimit
        // The device cannot hold a shutter shorter than its minimum, so ISO is solved for the one it will use.
        let hold = Swift.max(minSeconds, Swift.min(handheld, maxAuto))

        let atMinISO = light / minISO
        if atMinISO <= hold {
            return (ExposureMath.clamp(atMinISO, to: ranges.seconds), minISO)
        }
        let isoAtHold = light / hold
        if isoAtHold <= maxISO {
            return (hold, ExposureMath.clamp(isoAtHold, to: ranges.iso))
        }
        // Past max ISO only a slower shutter helps, and only up to the AE limit; darker than wanted beyond it.
        let atMaxISO = light / maxISO
        return (ExposureMath.clamp(atMaxISO, minSeconds, maxAuto), maxISO)
    }
}

/// Priority exposure in software, for devices or OS versions without native priority modes.
public enum SoftwareAE {
    /// One step of a software priority-exposure loop, for devices or OS versions without native priority modes.
    /// `meterOffset` is AVCaptureDevice.exposureTargetOffset in EV: positive = image is brighter than target.
    /// - |meterOffset| < deadband: return `current` (with locks applied and clamped).
    /// - wanted product = product(current) * 2^(-meterOffset * gain).
    /// - locked parameters keep their locked value (clamped to range).
    /// - only ISO auto: iso = iso(forProduct:) clamped.
    /// - only seconds auto: seconds = seconds(forProduct:) clamped to [ranges.seconds.lowerBound, maxAutoSeconds].
    /// - seconds and ISO auto: ProgramLine.split at the current (or locked) aperture.
    /// - only aperture auto (and variable): aperture = aperture(forProduct:) clamped.
    /// - aperture auto plus others auto: keep aperture as is, solve the others as above.
    /// - all locked: return locks clamped.
    /// A non-finite offset, or a gain that is not finite and positive, also returns `current` with locks applied.
    public static func step(current: ExposureValues, meterOffset: Double, locks: ExposureLocks, ranges: ExposureRanges,
                            handheldLimit: Double, gain: Double = 0.7, deadband: Double = 0.1) -> ExposureValues {
        // The device can only have been running inside its ranges, so measure from the clamped values.
        let now = ranges.clamp(current)
        let held = ranges.clamp(ExposureValues(seconds: locks.seconds ?? now.seconds,
                                               iso: locks.iso ?? now.iso,
                                               aperture: locks.aperture ?? now.aperture))
        guard meterOffset.isFinite, gain.isFinite, gain > 0, !(abs(meterOffset) < deadband) else { return held }

        // Capped so a wild reading drives to an extreme instead of overflowing the product to 0 or infinity.
        let correction = ExposureMath.clamp(-meterOffset * gain, -maxCorrectionEV, maxCorrectionEV)
        let wanted = ExposureMath.lightProduct(now) * pow(2, correction)
        var next = held
        switch (locks.seconds == nil, locks.iso == nil) {
        case (true, true):
            let split = ProgramLine.split(product: wanted, aperture: held.aperture, ranges: ranges,
                                          handheldLimit: handheldLimit)
            next.seconds = split.seconds
            next.iso = split.iso
        case (true, false):
            let seconds = ExposureMath.seconds(forProduct: wanted, iso: held.iso, aperture: held.aperture)
            next.seconds = ExposureMath.clamp(seconds, ranges.seconds.lowerBound, ranges.autoSecondsLimit)
        case (false, true):
            let iso = ExposureMath.iso(forProduct: wanted, seconds: held.seconds, aperture: held.aperture)
            next.iso = ExposureMath.clamp(iso, to: ranges.iso)
        case (false, false):
            // A fixed lens leaves nothing to adjust, so the locks stand.
            if locks.aperture == nil && ranges.hasVariableAperture {
                let aperture = ExposureMath.aperture(forProduct: wanted, seconds: held.seconds, iso: held.iso)
                next.aperture = ExposureMath.clamp(aperture, to: ranges.aperture)
            }
        }
        return ranges.clamp(next)
    }

    /// Far beyond any real meter reading (iOS reports a few EV); it only stops runaway input.
    private static let maxCorrectionEV = 32.0
}
