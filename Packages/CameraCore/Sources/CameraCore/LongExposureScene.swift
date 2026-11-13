import Foundation

/// How a scene picks the ISO of its frames.
public enum SceneISO: Hashable, Sendable {
    /// Metered, like any auto ISO.
    case auto
    /// Metered, but never above this, so a dark sky doesn't turn to grain.
    case autoUpTo(Double)
    /// The camera's lowest ISO. With the frame shutter on auto that is ISO priority: the longest frame the light
    /// allows, which keeps moving lights drawing unbroken lines.
    case lowest
    case fixed(Double)
}

/// What a photographer would dial in for one long exposure subject. LONG mode writes the blend, time, frame and
/// alignment into its own settings when a scene is picked; the ISO, exposure compensation, focus, white balance and
/// aperture are shared with other modes, so those apply only while the scene is on and only where the person has
/// not set a value of their own.
public struct LongExposureRecipe: Hashable, Sendable {
    public var blend: StackBlend
    /// Total times the simple interface offers, shortest first. Empty for a bulb scene.
    public var durations: [Double]
    /// The time a fresh pick of the scene starts with.
    public var seconds: Double
    /// Runs until the shutter is tapped again.
    public var bulb: Bool
    /// Shutter of each Blur or Trails frame; nil leaves it to auto exposure.
    public var frameSeconds: Double?
    public var iso: SceneISO
    /// Added to the person's own exposure compensation.
    public var biasEV: Double
    /// Longest frame auto exposure may pick while the scene is on; nil keeps the setting.
    public var maxAutoSeconds: Double?
    /// Stars and fireworks are too far and too dim for autofocus to find.
    public var focusAtInfinity: Bool
    /// Fixed white balance; nil stays automatic.
    public var kelvin: Double?
    /// Stop down as far as the lens goes, on lenses with an iris.
    public var prefersSmallestAperture: Bool
    public var align: Bool
    /// Wait before the exposure starts, so the tap on the shutter isn't in the picture.
    public var settleSeconds: Double
    public var needsTripod: Bool

    public init(blend: StackBlend, durations: [Double], seconds: Double, bulb: Bool = false, frameSeconds: Double? = nil,
                iso: SceneISO = .auto, biasEV: Double = 0, maxAutoSeconds: Double? = nil, focusAtInfinity: Bool = false,
                kelvin: Double? = nil, prefersSmallestAperture: Bool = false, align: Bool = false,
                settleSeconds: Double = 0, needsTripod: Bool = true) {
        self.blend = blend
        self.durations = durations
        self.seconds = seconds
        self.bulb = bulb
        self.frameSeconds = frameSeconds
        self.iso = iso
        self.biasEV = biasEV
        self.maxAutoSeconds = maxAutoSeconds
        self.focusAtInfinity = focusAtInfinity
        self.kelvin = kelvin
        self.prefersSmallestAperture = prefersSmallestAperture
        self.align = align
        self.settleSeconds = settleSeconds
        self.needsTripod = needsTripod
    }

    /// The ISO the preview and every Blur or Trails frame are locked to; nil leaves it to auto exposure.
    public func isoLock(in range: ClosedRange<Double>) -> Double? {
        switch iso {
        case .auto, .autoUpTo: return nil
        case .lowest: return range.lowerBound
        case .fixed(let value): return ExposureMath.clamp(value, to: range)
        }
    }

    /// The highest ISO the scene's auto ISO may reach on this camera.
    public func isoCeiling(in range: ClosedRange<Double>) -> Double {
        if case .autoUpTo(let cap) = iso, cap.isFinite {
            return ExposureMath.clamp(cap, to: range)
        }
        return range.upperBound
    }

    /// The ISO of a Real (additive) stack, given the ISO the meter asks for over the whole time.
    public func stackISO(metered: Double, in range: ClosedRange<Double>) -> Double {
        switch iso {
        case .auto, .autoUpTo:
            let wanted = metered.isFinite ? metered : range.lowerBound
            return Swift.min(Swift.max(wanted, range.lowerBound), isoCeiling(in: range))
        case .lowest:
            return range.lowerBound
        case .fixed(let value):
            return ExposureMath.clamp(value, to: range)
        }
    }

    /// The aperture the scene asks for: the smallest opening on a lens with an iris, nil (auto) otherwise.
    public func aperture(in range: ClosedRange<Double>, variable: Bool) -> Double? {
        prefersSmallestAperture && variable ? range.upperBound : nil
    }

    /// The scene's limit for auto exposure frames, inside what the sensor can do. NaN says nothing about a limit,
    /// so like nil it keeps the setting; clamped, it would hold auto exposure to the shortest shutter.
    public func maxAutoSeconds(in range: ClosedRange<Double>) -> Double? {
        guard let limit = maxAutoSeconds, !limit.isNaN else { return nil }
        return ExposureMath.clamp(limit, to: range)
    }

    /// The offered time closest to `seconds`: the shorter one halfway between two, the first or last past either
    /// end. The scene's own time when it offers none or `seconds` is NaN.
    public func nearestDuration(to seconds: Double) -> Double {
        guard !seconds.isNaN, let shortest = durations.first, let longest = durations.last else { return self.seconds }
        // Decided before any subtraction: far enough out, every difference rounds to the same number.
        if seconds <= shortest { return shortest }
        if seconds >= longest { return longest }
        return durations.reduce(shortest) { abs($1 - seconds) < abs($0 - seconds) ? $1 : $0 }
    }
}

/// A subject for LONG mode. Each one stands for the settings a photographer would dial in for it.
public enum LongExposureScene: String, Codable, Sendable, CaseIterable, Identifiable {
    case water, lightTrails, stars, northernLights, starTrails, fireworks, lightPainting
    /// No recipe: the blend, frame and exposure are whatever the person set.
    case custom

    public var id: String { rawValue }

    /// Every scene with a recipe, in picker order.
    public static let presets: [LongExposureScene] = [.water, .lightTrails, .stars, .northernLights, .starTrails, .fireworks, .lightPainting]

    public var title: String {
        switch self {
        case .water: return "Water"
        case .lightTrails: return "Light trails"
        case .stars: return "Stars"
        case .northernLights: return "Northern lights"
        case .starTrails: return "Star trails"
        case .fireworks: return "Fireworks"
        case .lightPainting: return "Light painting"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol names, best first. Not every name exists on every iOS version, so the interface takes the first
    /// one the system has.
    public var symbolNames: [String] {
        switch self {
        case .water: return ["water.waves", "drop.fill"]
        case .lightTrails: return ["car.rear.road.lane", "car.fill"]
        case .stars: return ["moon.stars.fill", "star.fill"]
        case .northernLights: return ["sparkles", "star.fill"]
        case .starTrails: return ["timelapse", "star.circle"]
        case .fireworks: return ["fireworks", "sparkle", "star.fill"]
        case .lightPainting: return ["scribble.variable", "scribble", "flashlight.on.fill"]
        case .custom: return ["slider.horizontal.3"]
        }
    }

    /// One line under the scene picker: what the scene does and what it needs.
    public var tip: String {
        switch self {
        case .water: return "Smooths moving water and clouds. Hold still or use a tripod."
        case .lightTrails: return "Draws car lights into lines. Needs a tripod."
        case .stars: return "Gathers light for a sky full of stars. Tripod, somewhere dark."
        case .northernLights: return "Short enough to keep the shapes in the sky. Needs a tripod."
        case .starTrails: return "Stars draw arcs across the sky. Tripod, and keep the phone charging."
        case .fireworks: return "Start as the rocket goes up. Needs a tripod."
        case .lightPainting: return "Tap to start, draw with a light, tap to stop. Needs a tripod."
        case .custom: return "Your own blend, frame and exposure."
        }
    }

    /// nil for custom.
    public var recipe: LongExposureRecipe? {
        switch self {
        case .water:
            // Averaging keeps one frame's brightness, so it works at noon. Aligned, because two seconds by hand
            // is possible and the still parts of the picture should stay sharp.
            return LongExposureRecipe(blend: .average, durations: [1, 2, 4, 8], seconds: 2, align: true, needsTripod: false)
        case .lightTrails:
            // Lowest ISO with the frame on auto runs frames as long as the light allows, up to a second, so lights
            // draw lines without gaps. A little dark, the way a night street should read.
            return LongExposureRecipe(blend: .lighten, durations: [5, 10, 15, 30], seconds: 10, iso: .lowest, biasEV: -0.5,
                                      maxAutoSeconds: 1)
        case .stars:
            // Fifteen seconds is about where stars start to streak on the main camera. The meter wants a grey sky,
            // so a stop under; 3200 is where the grain takes over. 4000 K keeps city glow from turning the sky brown.
            return LongExposureRecipe(blend: .additive, durations: [10, 15, 20, 30], seconds: 15, iso: .autoUpTo(3200),
                                      biasEV: -1, focusAtInfinity: true, kelvin: 4000, settleSeconds: 2)
        case .northernLights:
            // The aurora moves; past about eight seconds its curtains smear into a glow.
            return LongExposureRecipe(blend: .additive, durations: [4, 8, 15], seconds: 8, iso: .autoUpTo(3200),
                                      biasEV: -1, focusAtInfinity: true, kelvin: 3800, settleSeconds: 2)
        case .starTrails:
            // Each frame has to hold the stars on its own, hence one second at a fixed ISO. Brightest-pixel stacking
            // also keeps the brightest noise, so the ISO stays moderate.
            return LongExposureRecipe(blend: .lighten, durations: [300, 600, 1200, 1800], seconds: 600, frameSeconds: 1,
                                      iso: .fixed(800), focusAtInfinity: true, kelvin: 4000, settleSeconds: 2)
        case .fireworks:
            // A burst's streaks are exposed by aperture and ISO, not time, so both go as low as the phone allows.
            // 1/30 s frames sit back to back at 30 frames a second. Daylight balance keeps the colours as fired.
            return LongExposureRecipe(blend: .lighten, durations: [3, 6, 10, 15], seconds: 6, frameSeconds: 1.0 / 30.0,
                                      iso: .lowest, focusAtInfinity: true, kelvin: 5200, prefersSmallestAperture: true)
        case .lightPainting:
            return LongExposureRecipe(blend: .lighten, durations: [], seconds: 30, bulb: true, frameSeconds: 1.0 / 15.0,
                                      iso: .lowest)
        case .custom:
            return nil
        }
    }
}
