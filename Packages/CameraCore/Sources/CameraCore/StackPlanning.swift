import Foundation

/// Why frames are being stacked.
public enum StackPurpose: String, Codable, Sendable { case longExposure, night }

/// One stacked capture: what the device locks to for every frame and how the engine merges the frames.
public struct StackPlan: Hashable, Codable, Sendable {
    public var purpose: StackPurpose
    public var blend: StackBlend
    /// Per-frame exposure the device locks to.
    public var frameSeconds: Double
    public var iso: Double
    public var aperture: Double
    /// Frames to accumulate (>= 1); for bulb it is an upper bound.
    public var frameCount: Int
    public var align: Bool
    public var rejectBlurryFrames: Bool
    /// Extra brightening applied at the end (>= 1 for night mode, 1 otherwise).
    public var digitalGain: Double

    /// `frameCount` below 1 becomes 1, because the engine loops over and divides by it.
    public init(purpose: StackPurpose, blend: StackBlend, frameSeconds: Double, iso: Double, aperture: Double,
                frameCount: Int, align: Bool, rejectBlurryFrames: Bool, digitalGain: Double) {
        self.purpose = purpose
        self.blend = blend
        self.frameSeconds = frameSeconds
        self.iso = iso
        self.aperture = aperture
        self.frameCount = Swift.max(1, frameCount)
        self.align = align
        self.rejectBlurryFrames = rejectBlurryFrames
        self.digitalGain = digitalGain
    }

    /// Light-equivalent exposure time: frameSeconds * frameCount for additive, frameSeconds otherwise.
    public var effectiveExposureSeconds: Double {
        blend == .additive ? frameSeconds * Double(frames) : frameSeconds
    }

    /// Wall-clock estimate: frameCount * max(frameSeconds, minFrameInterval).
    /// Negative or non-finite inputs count as 0 so the estimate never goes negative.
    public func estimatedDuration(minFrameInterval: Double = 1.0 / 30.0) -> Double {
        let frame = frameSeconds.isFinite ? Swift.max(frameSeconds, 0) : 0
        let interval = minFrameInterval.isFinite ? Swift.max(minFrameInterval, 0) : 0
        return Double(frames) * Swift.max(frame, interval)
    }

    /// Multiplier for the RUNNING MEAN the engine keeps: additive -> Double(n) * digitalGain,
    /// average -> digitalGain, lighten -> 1. Uses the frames actually accumulated (n), so stopping early works.
    /// n below 0 counts as 0.
    public func outputScale(framesAccumulated n: Int) -> Double {
        // A gain that is not finite and positive would blank or blow out the image; treat it as no extra gain.
        let gain = ExposureMath.isPositive(digitalGain) ? digitalGain : 1
        switch blend {
        case .additive: return Double(Swift.max(n, 0)) * gain
        case .average: return gain
        case .lighten: return 1
        }
    }

    /// `frameCount` can be reassigned below 1 after init.
    private var frames: Int { Swift.max(1, frameCount) }
}

extension StackPlan {
    /// Converts a frame count to Int inside 1...maxFrames. Clamps while still a Double, because Int(_:) traps
    /// on NaN and on values past Int.max.
    fileprivate static func boundedFrameCount(_ value: Double, maxFrames: Int) -> Int {
        let cap = Swift.max(1, maxFrames)
        if value.isNaN || value <= 1 { return 1 }
        if value >= Double(cap) { return cap }
        return Int(value)
    }
}

/// Turns a long exposure request into frames the hardware can shoot.
public enum LongExposurePlanner {
    /// additive: if totalSeconds <= ranges.seconds.upperBound -> 1 frame of totalSeconds. Else
    ///   N = ceil(total / upper), frameSeconds = total / N. iso = given (clamped).
    /// average / lighten: frameSeconds = (frameSeconds ?? 1/30) clamped to ranges.seconds;
    ///   N = max(1, ceil(totalSeconds / max(frameSeconds, 1/frameRate))).
    /// N clamped to 1...maxFrames. align as given, rejectBlurryFrames false, digitalGain 1, purpose .longExposure.
    /// totalSeconds <= 0 treated as the shortest hardware shutter.
    /// When maxFrames cuts an additive plan short, frames stay at the longest shutter, as close to the total as
    /// the cap allows. Aperture is clamped into its range; frameRate <= 0 counts as 30; NaN frameSeconds as nil.
    /// The default cap is two hours of 30 fps frames: the engine merges every frame into one accumulator, so a
    /// frame costs time rather than memory, and a lower cap would end Blur and Trails before their set time.
    public static func plan(totalSeconds: Double, blend: StackBlend, iso: Double, aperture: Double,
                            frameSeconds: Double?, ranges: ExposureRanges, frameRate: Double = 30,
                            align: Bool = false, maxFrames: Int = 216_000) -> StackPlan {
        let longest = ranges.seconds.upperBound
        // NaN fails the test too, so it also becomes one shortest frame.
        let total = totalSeconds > 0 ? totalSeconds : ranges.seconds.lowerBound
        let frame: Double
        let count: Int
        switch blend {
        case .additive:
            if total <= longest {
                count = 1
                frame = ExposureMath.clamp(total, to: ranges.seconds)
            } else {
                count = StackPlan.boundedFrameCount(roundedUp(total / longest), maxFrames: maxFrames)
                frame = ExposureMath.clamp(total / Double(count), to: ranges.seconds)
            }
        case .average, .lighten:
            let wanted = frameSeconds.flatMap { $0.isNaN ? nil : $0 } ?? 1.0 / 30.0
            frame = ExposureMath.clamp(wanted, to: ranges.seconds)
            let rate = ExposureMath.isPositive(frameRate) ? frameRate : 30
            // Frames cannot arrive faster than the frame rate, so a short frame still costs 1/frameRate.
            count = StackPlan.boundedFrameCount(roundedUp(total / Swift.max(frame, 1 / rate)), maxFrames: maxFrames)
        }
        return StackPlan(purpose: .longExposure, blend: blend, frameSeconds: frame,
                         iso: ExposureMath.clamp(iso, to: ranges.iso),
                         aperture: ExposureMath.clamp(aperture, to: ranges.aperture),
                         frameCount: count, align: align, rejectBlurryFrames: false, digitalGain: 1)
    }

    /// ceil, but a ratio within a billionth of a whole number counts as that number, so rounding noise such as
    /// 0.30000000000000004 / 0.1 does not add a frame. Snapping to the nearest whole number instead of scaling the
    /// ratio down keeps large exact counts exact.
    private static func roundedUp(_ ratio: Double) -> Double {
        let nearest = ratio.rounded()
        return abs(ratio - nearest) <= nearest * 1e-9 ? nearest : ratio.rounded(.up)
    }
}

/// How steady the phone is during a night shot.
public enum NightStability: String, Codable, Sendable, CaseIterable { case handheld, steady, tripod }

/// What the night planner needs to know about the scene, the device and the user's choices.
public struct NightModeInput: Hashable, Sendable {
    /// Light product auto exposure wants right now (t*ISO/N^2). Darker scenes want more.
    public var meteredProduct: Double
    /// User EV compensation for night shots.
    public var biasEV: Double
    /// nil = automatic duration.
    public var requestedSeconds: Double?
    public var stability: NightStability
    public var ranges: ExposureRanges
    public var aperture: Double
    /// e.g. 1/8 s from the lens focal length.
    public var handheldFrameLimit: Double
    /// Noise cap, clamped into ranges.iso by the planner.
    public var maxISO: Double

    public init(meteredProduct: Double, biasEV: Double = 0, requestedSeconds: Double? = nil, stability: NightStability,
                ranges: ExposureRanges, aperture: Double, handheldFrameLimit: Double, maxISO: Double) {
        self.meteredProduct = meteredProduct
        self.biasEV = biasEV
        self.requestedSeconds = requestedSeconds
        self.stability = stability
        self.ranges = ranges
        self.aperture = aperture
        self.handheldFrameLimit = handheldFrameLimit
        self.maxISO = maxISO
    }
}

/// Night mode: many short, sharp frames averaged into one clean exposure.
public enum NightModePlanner {
    /// The longest dial setting, 30 s, at the 30 fps the preview delivers. Frames merge into one accumulator, so
    /// the cap is not there for memory; past it, frames get longer instead of the shot ending early.
    public static let maxFrames = 900
    /// Frames shorter than this still arrive one preview frame apart.
    static let frameInterval = 1.0 / 30
    /// What the UI dial offers, any value.
    public static let secondsRange: ClosedRange<Double> = 1...30

    /// Reference "normal" scene product = 1/30 s at ISO 400 at the given aperture.
    /// darkness = log2(metered / reference). darkness <= 0 -> 1 s.
    /// Otherwise 2^(darkness * 0.75) seconds, rounded to 0.5 s, clamped to 1 ... cap,
    /// where cap = handheld 3, steady 10, tripod 30. Non-finite or <= 0 metered product (or aperture) -> cap.
    public static func suggestedSeconds(meteredProduct: Double, aperture: Double, stability: NightStability) -> Double {
        let cap = recommendedMaxSeconds(for: stability)
        guard ExposureMath.isPositive(meteredProduct), ExposureMath.isPositive(aperture) else { return cap }
        let reference = ExposureMath.lightProduct(ExposureValues(seconds: 1.0 / 30.0, iso: 400, aperture: aperture))
        guard reference > 0 else { return cap }
        // metered / reference, not the inverse: auto exposure wants a larger product in a darker scene.
        let darkness = log2(meteredProduct / reference)
        guard darkness > 0 else { return 1 }
        let seconds = (pow(2, darkness * 0.75) * 2).rounded() / 2
        return ExposureMath.clamp(seconds, 1, cap)
    }

    /// The recommended maximum for a stability level (3 / 10 / 30). The user may still pick up to 30.
    public static func recommendedMaxSeconds(for stability: NightStability) -> Double {
        switch stability {
        case .handheld: return 3
        case .steady: return 10
        case .tripod: return 30
        }
    }

    /// frameLimit: handheld = handheldFrameLimit, steady = min(4 * handheldFrameLimit, 0.5), tripod = ranges.seconds.upperBound.
    /// duration = clamp(requestedSeconds ?? suggestedSeconds(...), 0.1...3600). target = meteredProduct * 2^biasEV.
    /// frameSeconds = min(frameLimit, duration, ranges.seconds.upperBound), lengthened to
    ///   min(duration / maxFrames, ranges.seconds.upperBound) when the duration needs more than maxFrames frames;
    ///   then, if the scene is bright enough that t = target * N^2 / minISO is shorter, use t (but
    ///   >= ranges.seconds.lowerBound), since an overexposed frame is worse than a shot that ends early.
    /// frameCount = clamp(round(duration / max(frameSeconds, frameInterval)), 1, maxFrames).
    /// iso = clamp(target * N^2 / frameSeconds, minISO, min(maxISO, maxISO of range)).
    /// digitalGain = clamp(target / lightProduct(frameSeconds, iso, N), 1, 16).
    /// blend .average, align = stability != .tripod, rejectBlurryFrames = stability == .handheld, purpose .night.
    /// N is the aperture clamped into its range. A metered product that is not finite and positive plans the
    /// longest allowed frame at the ISO cap with no digital gain; a handheld limit that is not finite and positive
    /// uses the 24 mm rule from ExposureMath.handheldLimit; NaN requestedSeconds counts as nil.
    public static func plan(_ input: NightModeInput) -> StackPlan {
        let ranges = input.ranges
        let aperture = ExposureMath.clamp(input.aperture, to: ranges.aperture)
        let area = aperture * aperture
        let minISO = ranges.iso.lowerBound
        let isoCap = ExposureMath.clamp(input.maxISO, to: ranges.iso)
        let handheld = ExposureMath.isPositive(input.handheldFrameLimit)
            ? input.handheldFrameLimit
            : ExposureMath.handheldLimit(equivalentFocalLength: 24)
        let frameLimit: Double
        switch input.stability {
        case .handheld: frameLimit = handheld
        case .steady: frameLimit = Swift.min(4 * handheld, 0.5)
        case .tripod: frameLimit = ranges.seconds.upperBound
        }

        let requested = input.requestedSeconds.flatMap { $0.isNaN ? nil : $0 }
        let automatic = suggestedSeconds(meteredProduct: input.meteredProduct, aperture: aperture,
                                         stability: input.stability)
        let duration = ExposureMath.clamp(requested ?? automatic, 0.1, 3600)
        var frameSeconds = Swift.min(frameLimit, duration, ranges.seconds.upperBound)
        // Past the cap, longer frames keep the whole duration. Rounded the way frameCount is, so rounding noise just
        // over the cap does not stretch the frames.
        if (duration / Swift.max(frameSeconds, frameInterval)).rounded() > Double(maxFrames) {
            frameSeconds = Swift.min(duration / Double(maxFrames), ranges.seconds.upperBound)
        }

        let target: Double
        if ExposureMath.isPositive(input.meteredProduct) {
            let bias = input.biasEV.isFinite ? input.biasEV : 0
            target = input.meteredProduct * pow(2, bias)
        } else {
            // With no usable meter, guessing a brightness and amplifying it would only add noise.
            target = frameSeconds * isoCap / area
        }
        let atMinISO = target * area / minISO
        if atMinISO < frameSeconds {
            frameSeconds = Swift.max(atMinISO, ranges.seconds.lowerBound)
        }
        frameSeconds = ExposureMath.clamp(frameSeconds, to: ranges.seconds)

        let frameCount = StackPlan.boundedFrameCount((duration / Swift.max(frameSeconds, frameInterval)).rounded(),
                                                     maxFrames: maxFrames)
        let iso = ExposureMath.clamp(target * area / frameSeconds, minISO, isoCap)
        let reached = ExposureMath.lightProduct(ExposureValues(seconds: frameSeconds, iso: iso, aperture: aperture))
        let digitalGain = reached > 0 ? ExposureMath.clamp(target / reached, 1, 16) : 1
        return StackPlan(purpose: .night, blend: .average, frameSeconds: frameSeconds, iso: iso, aperture: aperture,
                         frameCount: frameCount, align: input.stability != .tripod,
                         rejectBlurryFrames: input.stability == .handheld, digitalGain: digitalGain)
    }
}
