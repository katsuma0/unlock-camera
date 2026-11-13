import Foundation

/// Zoom for the lens buttons, the zoom wheel, pinch and VoiceOver, in display zoom: 1 is the back wide camera, 0.5 the
/// ultra wide, 4 a 4x telephoto. A value that isn't a finite positive number counts as 1, so every answer is a finite,
/// positive zoom whatever the readings were.
public enum ZoomMath {
    /// Wheel travel for one doubling. Lens to lens (0.5, 1, 2, 4, 8) is then one short stroke, and 1x to 2x matches
    /// the ruler dial's ten 10 pt ticks.
    public static let pointsPerStop: Double = 100
    /// The wheel lands on tenths below this and on whole numbers from it: tenths up there would sit under 1.5 pt
    /// apart, too close for a finger.
    public static let tenthsLimit: Double = 10
    /// Share of a step the raw zoom has to go past the midpoint before the shown value moves, so a finger resting
    /// between 1.4 and 1.5 doesn't flicker between them.
    public static let gridHysteresis: Double = 0.1
    /// While a finger is down the wider lens keeps the zoom until it is this share past the next lens's own value:
    /// every lens change freezes the picture, and a finger resting on 4.0 would otherwise swap back and forth.
    public static let lensHysteresis: Double = 0.05
    /// Doublings per second of the ramp that settles the camera on the shown value when the finger lifts. The
    /// landing is at most half a step, so it takes under 20 ms.
    public static let settleRate: Double = 4

    // MARK: - Wheel

    /// Wheel value after `translation` points from `start`; finger left (negative) zooms in. A translation that isn't
    /// finite moves nothing, and a non-positive or non-finite `pointsPerStop` is the default.
    public static func zoom(from start: Double, translation: Double,
                            pointsPerStop: Double = ZoomMath.pointsPerStop) -> Double {
        let base = usable(start) ? start : 1
        let scale = usable(pointsPerStop) ? pointsPerStop : ZoomMath.pointsPerStop
        guard translation.isFinite, translation != 0 else { return base }
        let stops = -translation / scale
        let value = base * pow(2, stops)
        if usable(value) { return value }
        // Past what a Double holds: the far end in the direction of travel.
        return stops > 0 ? .greatestFiniteMagnitude : .leastNormalMagnitude
    }

    /// Horizontal offset of `value` from the centre line while the wheel shows `center`: larger values sit to the
    /// right. A finger that drags the wheel by `t` brings the value at offset `-t` to the centre line.
    public static func offset(of value: Double, from center: Double,
                              pointsPerStop: Double = ZoomMath.pointsPerStop) -> Double {
        let scale = usable(pointsPerStop) ? pointsPerStop : ZoomMath.pointsPerStop
        // Each log2 of a finite positive number is finite, which a ratio of two extremes would not be.
        let travel = (log2(usable(value) ? value : 1) - log2(usable(center) ? center : 1)) * scale
        if travel.isFinite { return travel }
        return travel > 0 ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude
    }

    // MARK: - Grid

    /// Nearest grid value: tenths below `tenthsLimit`, whole numbers from it. The grid starts at 0.1. Halfway values
    /// go up (1.45 reads 1.5), like the labels.
    public static func snapped(_ zoom: Double) -> Double {
        gridValue(gridPosition(usable(zoom) ? zoom : 1).rounded())
    }

    /// Grid value with hysteresis: keeps `current` (snapped onto the grid first) until `raw` is past the midpoint to
    /// another grid value by `gridHysteresis` of a step, then takes the grid value nearest `raw`. A raw value that
    /// isn't usable keeps `current`; without a usable `current` this is `snapped(raw)`.
    public static func snapped(_ raw: Double, keeping current: Double) -> Double {
        guard usable(raw) else { return snapped(current) }
        let position = gridPosition(raw)
        guard usable(current) else { return gridValue(position.rounded()) }
        let held = Swift.max(gridPosition(current).rounded(), 1)
        // A billionth of a step of slack lets a raw value that lands right on the threshold move, however its
        // decimal rounds in binary (1.46 * 10 is a hair under 14.6).
        if abs(position - held) < 0.5 + gridHysteresis - 1e-9 { return gridValue(held) }
        return gridValue(position.rounded())
    }

    // MARK: - Lens button and VoiceOver ramps

    /// Distance between two zooms in doublings, either direction.
    public static func stops(from: Double, to: Double) -> Double {
        abs(log2(usable(to) ? to : 1) - log2(usable(from) ? from : 1))
    }

    /// How long a lens button's zoom takes over `stops` doublings: long enough to read as a zoom, short enough not to
    /// keep a shot waiting. The sign doesn't matter; NaN counts as no distance.
    public static func transitionDuration(stops: Double) -> Double {
        let distance = stops.isNaN ? 0 : abs(stops)
        return ExposureMath.clamp(baseDuration + durationPerStop * distance, to: durationRange)
    }

    /// Ramp rate in doublings per second (AVFoundation's unit) that covers `from` to `to` in `transitionDuration`,
    /// kept inside `rateRange`: below its floor a short step would crawl, above its ceiling the picture would jump.
    public static func rampRate(from: Double, to: Double) -> Double {
        let distance = stops(from: from, to: to)
        return ExposureMath.clamp(distance / transitionDuration(stops: distance), to: rateRange)
    }

    /// How long the ramp at `rampRate(from:to:)` takes: what a zoom that ends in a lens change waits before the
    /// change. Shorter than `transitionDuration` where the rate sits at its floor. AVFoundation eases rate changes,
    /// so the real ramp runs a little longer, and the lens change then starts a few frames early under the veil.
    public static func rampDuration(from: Double, to: Double) -> Double {
        stops(from: from, to: to) / rampRate(from: from, to: to)
    }

    // MARK: - Span and lenses

    /// Display zoom the controls offer, the same for pinch, the wheel and the dial.
    /// - Lenses may switch: the widest lens up to five times the longest button, or as far as the longest lens
    ///   reaches at the active lens's largest factor if that is less (25x with a 5x telephoto, 40x with 4x and its 8x
    ///   button, 15x with a 3x, 10x with only the wide's 2x button, 5x with one lens).
    /// - Otherwise: the active lens's own range in display zoom, up to five times its own longest button, the
    ///   buttons from its own value up to the next longer lens.
    /// Both ends move inward onto the wheel's grid, so the wheel, its ticks and VoiceOver reach them exactly. Lenses,
    /// buttons or factors that aren't finite and positive are left out; zoom factors start at 1.
    public static func span(lensZooms: [Double], buttonZooms: [Double], activeZoom: Double,
                            activeFactorRange: ClosedRange<Double>, switchesLenses: Bool) -> ClosedRange<Double> {
        let active = usable(activeZoom) ? activeZoom : 1
        let lowFactor = usable(activeFactorRange.lowerBound) ? Swift.max(activeFactorRange.lowerBound, 1) : 1
        // An infinite largest factor leaves the button rule to set the end.
        let highFactor = activeFactorRange.upperBound.isNaN
            ? lowFactor : Swift.max(activeFactorRange.upperBound, lowFactor)
        let lenses = lensZooms.filter(usable)
        let buttons = buttonZooms.filter(usable)

        var lower: Double
        var upper: Double
        if switchesLenses, let widest = lenses.min(), let longest = lenses.max() {
            lower = widest
            // Every lens has a button at its own value; a missing one can't make the longest lens unreachable.
            let longestButton = Swift.max(buttons.max() ?? longest, longest)
            upper = Swift.min(buttonReach * longestButton, longest * highFactor)
        } else {
            lower = active * lowFactor
            let next = lenses.filter { $0 > active * (1 + sameLens) }.min() ?? .infinity
            let own = buttons.filter { $0 >= active * (1 - sameLens) && $0 < next * (1 - sameLens) }
            upper = Swift.min(active * highFactor, buttonReach * Swift.max(own.max() ?? active, active))
        }
        lower = ExposureMath.clamp(lower, to: zoomDomain)
        upper = Swift.max(ExposureMath.clamp(upper, to: zoomDomain), lower)

        let gridLower = gridValue((gridPosition(lower) - 1e-9).rounded(.up))
        let gridUpper = gridValue((gridPosition(upper) + 1e-9).rounded(.down))
        // A span too narrow to hold a grid value stays as the camera can do it.
        return gridLower <= gridUpper ? gridLower...gridUpper : lower...upper
    }

    /// Index into `lensZooms` (relative zooms, ascending) of the lens for `zoom`, nil without a usable lens.
    /// Strict: the longest lens at or below the zoom, or the widest below every lens. `continuing` (a finger is
    /// still down) lets the `current` lens keep a zoom up to `lensHysteresis` past the next longer lens's own value,
    /// as long as its `currentMaxFactor` reaches it. Going down there is no choice: a lens can't zoom out past its
    /// own value. Entries that aren't finite and positive are never picked.
    public static func lensIndex(for zoom: Double, lensZooms: [Double], current: Int?, currentMaxFactor: Double,
                                 continuing: Bool) -> Int? {
        let target = usable(zoom) ? zoom : 1
        var strict: Int?
        var widest: Int?
        for (index, lens) in lensZooms.enumerated() where usable(lens) {
            if widest.map({ lens < lensZooms[$0] }) ?? true { widest = index }
            // The model's lens rule allows a thousandth, so a zoom read back as 3.9995 stays on the 4x lens.
            if lens <= target + lensTolerance, strict.map({ lens > lensZooms[$0] }) ?? true { strict = index }
        }
        guard let pick = strict ?? widest else { return nil }
        guard continuing, let current, lensZooms.indices.contains(current), usable(lensZooms[current]),
              lensZooms[pick] > lensZooms[current] else { return pick }
        let own = lensZooms[current]
        // pick is longer than the current lens, so a next longer lens exists.
        guard let next = lensZooms.filter({ usable($0) && $0 > own }).min() else { return pick }
        let maxFactor = usable(currentMaxFactor) ? currentMaxFactor : 1
        return target < next * (1 + lensHysteresis) && target <= own * maxFactor ? current : pick
    }

    // MARK: - Ticks and steps

    /// Wheel ticks and VoiceOver steps inside `span`, ascending: every 0.1 to 2, 0.2 to 5, 0.5 to 10, 1 to 25 and 5 to
    /// 100, then 10, 20 and 50 a step up to 1000, so neighbours stay at least 5.8 pt apart at 100 pt per doubling.
    /// The span is read inside 0.1...1000, a NaN end as 1.
    public static func ticks(in span: ClosedRange<Double>) -> [Double] {
        let (low, high) = bounds(of: span)
        // Counting in whole tenths keeps long runs of steps exact: 14 tenths reads back as exactly 1.4.
        var tenths = Int((low * 10 - 1e-6).rounded(.up))
        let last = Int((high * 10 + 1e-6).rounded(.down))
        let firstStep = tickStep(tenths)
        tenths = (tenths + firstStep - 1) / firstStep * firstStep
        var result: [Double] = []
        while tenths <= last {
            result.append(Double(tenths) / 10)
            tenths += tickStep(tenths)
        }
        return result
    }

    /// `zoom` moved `steps` ticks (up for positive), with the span's ends as stops too, so VoiceOver reaches both.
    /// Stops at the ends. Steps count from the zoom as read out to a tenth: 1.46 is read as 1.5x, so one step up is
    /// 1.6 and one down is 1.4. Zero steps returns the zoom inside the span.
    public static func nudged(_ zoom: Double, by steps: Int, in span: ClosedRange<Double>) -> Double {
        let (low, high) = bounds(of: span)
        let value = usable(zoom) ? zoom : 1
        guard steps != 0 else { return ExposureMath.clamp(value, low, high) }
        var stops = ticks(in: low...high)
        if stops.first.map({ $0 > low * (1 + 1e-9) }) ?? true { stops.insert(low, at: 0) }
        if stops.last.map({ $0 < high * (1 - 1e-9) }) ?? true { stops.append(high) }
        let shown = (value * 10).rounded() / 10
        // magnitude handles Int.min, whose negation would overflow.
        let count = Int(Swift.min(steps.magnitude, UInt(stops.count)))
        if steps > 0 {
            guard let first = stops.firstIndex(where: { $0 > shown * (1 + 1e-9) }) else { return high }
            return stops[Swift.min(first + count - 1, stops.count - 1)]
        }
        guard let first = stops.lastIndex(where: { $0 < shown * (1 - 1e-9) }) else { return low }
        return stops[Swift.max(first - (count - 1), 0)]
    }

    // MARK: - Tuning

    /// A one-stop lens button zoom takes 0.28 s; Apple's Camera takes about a third of a second.
    static let baseDuration = 0.24
    static let durationPerStop = 0.04
    static let durationRange: ClosedRange<Double> = 0.20...0.45
    /// Doublings per second.
    static let rateRange: ClosedRange<Double> = 1.5...14
    /// The controls reach this many times past the longest button: Apple's limit on each of these phones.
    static let buttonReach = 5.0
    /// Lens values a hundredth apart are the same lens; real ones are at least 20 percent apart.
    static let sameLens = 0.01
    /// How far over the zoom a lens's own value may sit and still be picked, as in the model's lens rule.
    static let lensTolerance = 0.001
    /// No phone comes near either end; it only keeps absurd input finite and the tick loop short.
    static let zoomDomain: ClosedRange<Double> = 0.1...1000

    // MARK: - Helpers

    private static func usable(_ x: Double) -> Bool {
        ExposureMath.isPositive(x)
    }

    /// The grid as consecutive whole numbers, so snapping and hysteresis work in equal steps on both sides of the
    /// limit: tenths count one each below it (0.1 is 1, 9.9 is 99), whole numbers one each from it (10 is 100,
    /// 11 is 101).
    private static func gridPosition(_ zoom: Double) -> Double {
        zoom < tenthsLimit ? zoom * 10 : tenthsLimit * 10 + (zoom - tenthsLimit)
    }

    /// The grid value at a whole position; positions below 1 are the grid's first value, 0.1.
    private static func gridValue(_ position: Double) -> Double {
        let p = Swift.max(position, 1)
        let limit = tenthsLimit * 10
        // A whole number over ten is the Double nearest the decimal, so 14 reads back as exactly 1.4.
        return p < limit ? p / 10 : tenthsLimit + (p - limit)
    }

    /// Tick spacing in tenths at a position in tenths.
    private static func tickStep(_ tenths: Int) -> Int {
        switch tenths {
        case ..<20: return 1
        case ..<50: return 2
        case ..<100: return 5
        case ..<250: return 10
        case ..<1000: return 50
        case ..<2000: return 100
        case ..<5000: return 200
        default: return 500
        }
    }

    /// A span's ends inside `zoomDomain`, lower first.
    private static func bounds(of span: ClosedRange<Double>) -> (Double, Double) {
        let low = ExposureMath.clamp(span.lowerBound.isNaN ? 1 : span.lowerBound, to: zoomDomain)
        let high = ExposureMath.clamp(span.upperBound.isNaN ? low : span.upperBound, to: zoomDomain)
        return (low, Swift.max(high, low))
    }
}
