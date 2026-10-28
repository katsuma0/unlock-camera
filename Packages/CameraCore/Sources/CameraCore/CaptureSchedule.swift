import Foundation

/// Self timer, burst and intervalometer in one model.
/// Every way in (init, assignment, decoding) clamps, so the shutter loop never sees 0 shots or a negative wait.
public struct CaptureSchedule: Hashable, Codable, Sendable {
    /// Seconds before the first shot, 0...600.
    public var delay: Double { didSet { delay = Self.clampedDelay(delay) } }
    /// Number of shots, 1...9999.
    public var shots: Int { didSet { shots = Self.clampedShots(shots) } }
    /// Minimum seconds between shot starts, 0...3600. 0 shoots back to back.
    public var interval: Double { didSet { interval = Self.clampedInterval(interval) } }

    public init(delay: Double = 0, shots: Int = 1, interval: Double = 0) {
        self.delay = Self.clampedDelay(delay)
        self.shots = Self.clampedShots(shots)
        self.interval = Self.clampedInterval(interval)
    }

    // Property observers don't run during decoding, so stale or edited settings go through init instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            delay: try container.decode(Double.self, forKey: .delay),
            shots: try container.decode(Int.self, forKey: .shots),
            interval: try container.decode(Double.self, forKey: .interval)
        )
    }

    public static let off = CaptureSchedule()

    /// Self timer choices in seconds.
    public static let delayPresets: [Double] = [0, 3, 5, 10, 30]

    /// A single shot without a timer. The interval is ignored because nothing follows the first shot.
    public var isOff: Bool { delay == 0 && shots == 1 }

    public var isIntervalometer: Bool { shots > 1 && interval > 0 }

    /// Planned start of every shot in seconds from the trigger: delay + i * interval.
    public func plannedStartTimes() -> [Double] {
        var times: [Double] = []
        times.reserveCapacity(shots)
        for i in 0..<shots {
            times.append(delay + Double(i) * interval)
        }
        return times
    }

    /// When the shot after `index` (0-based) should start, in seconds from the trigger: its planned start, or as
    /// soon as shot `index` finished if that ran late. nil after the last shot or for a negative index.
    public func nextStartTime(afterShot index: Int, finishedAt: Double) -> Double? {
        guard index >= 0, index < shots - 1 else { return nil }
        let planned = delay + Double(index + 1) * interval
        // Written as a comparison so a NaN finish time falls back to the plan.
        return finishedAt > planned ? finishedAt : planned
    }

    /// Seconds from the trigger to the start of the last shot.
    public var plannedDuration: Double { delay + Double(shots - 1) * interval }

    /// "Off", "3s", "10s · 5 shots", "5 shots", "5 shots every 2s", "10s · 100 shots every 30s".
    public var summary: String {
        if isOff { return "Off" }
        var parts: [String] = []
        if delay > 0 {
            parts.append(Formatting.compactDuration(delay))
        }
        if shots > 1 {
            var burst = "\(shots) shots"
            if interval > 0 {
                burst += " every " + Formatting.compactDuration(interval)
            }
            parts.append(burst)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Helpers

    private static func clampedDelay(_ value: Double) -> Double { clamped(value, 0, 600) }
    private static func clampedInterval(_ value: Double) -> Double { clamped(value, 0, 3600) }
    private static func clampedShots(_ value: Int) -> Int { Swift.min(Swift.max(value, 1), 9999) }

    // NaN means "no wait" rather than a start time nobody can compare against.
    private static func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard !value.isNaN else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }
}
