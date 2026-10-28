import Foundation

/// Display strings shared by the UI, kept in one place so every screen reads the same way.
public enum Formatting {
    /// Countdown clock: "0:05", "1:30", "12:00", "1:00:00".
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        // Ceil so a countdown never shows 0:00 while time is left; the epsilon stops 5.0000001 showing 0:06.
        let total = clampedInt((seconds - 1e-9).rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// "1.5s", "5s", "12s", "2m", "2m 5s", "1h", "1h 5m".
    public static func compactDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        if seconds < 9.95 {
            return trimmed(seconds, decimals: 1) + "s"
        }
        let total = clampedInt(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let minutes = total / 60
            let secs = total % 60
            return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
        }
        let totalMinutes = clampedInt((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// "12 MP", "48 MP", "8.3 MP". Sensors sold as 48 MP are 48.8 MP, so large values round down
    /// unless they are within 0.2 of the next whole number.
    public static func megapixels(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "0 MP" }
        let value = Double(width) * Double(height) / 1_000_000
        if value < 10 {
            return trimmed(value, decimals: 1) + " MP"
        }
        let whole = value.rounded(.down)
        let shown = value - whole >= 0.8 ? whole + 1 : whole
        return "\(clampedInt(shown)) MP"
    }

    /// Decimal units (1 MB = 1,000,000 bytes), matching what Files and Photos show.
    public static func fileSize(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let b = Double(bytes)
        if b < 1_000 { return "\(bytes) B" }
        if b < 1_000_000 { return "\(clampedInt((b / 1_000).rounded())) KB" }
        if b < 1_000_000_000 { return trimmed(b / 1_000_000, decimals: 1) + " MB" }
        return trimmed(b / 1_000_000_000, decimals: 1) + " GB"
    }

    /// "12%", "<1%" for tiny non-zero fractions, "0%".
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        if fraction < 0.005 { return "<1%" }
        return "\(clampedInt((fraction * 100).rounded()))%"
    }

    /// "30 fps", "29.97 fps".
    public static func frameRate(_ fps: Double) -> String {
        guard fps.isFinite, fps > 0 else { return "0 fps" }
        if abs(fps - fps.rounded()) < 0.01 {
            return "\(clampedInt(fps.rounded())) fps"
        }
        return String(format: "%.2f fps", fps)
    }

    /// Named sizes for the common video resolutions, "4032×3024" for everything else.
    public static func resolution(width: Int, height: Int) -> String {
        let long = max(width, height)
        let short = min(width, height)
        switch (long, short) {
        case (3840, 2160): return "4K"
        case (4096, 2160): return "4K DCI"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return "\(width)\u{00D7}\(height)"
        }
    }

    /// "5600K", rounded to 10 K because the sensor can't tell 5603 K from 5600 K.
    public static func kelvin(_ k: Double) -> String {
        guard k.isFinite, k > 0 else { return "0K" }
        return "\(clampedInt((k / 10).rounded()) * 10)K"
    }

    /// "0", "+12", "-8".
    public static func tint(_ t: Double) -> String {
        guard t.isFinite else { return "0" }
        let value = clampedInt(t.rounded())
        if value == 0 { return "0" }
        return value > 0 ? "+\(value)" : "\(value)"
    }

    /// Manual focus readout. AVFoundation's lens position has no distance unit, so a percentage is the honest label.
    public static func lensPosition(_ p: Double) -> String {
        let clamped = p.isFinite ? min(max(p, 0), 1) : 0
        return "MF \(clampedInt((clamped * 100).rounded()))%"
    }

    // MARK: - Helpers

    /// Int(_:) traps on values past Int's range; a corrupted setting or reading must not crash a label.
    static func clampedInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -9e15), 9e15))
    }

    static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Rounds to `decimals` places and drops trailing zeros: 2.0 -> "2", 2.50 -> "2.5".
    static func trimmed(_ value: Double, decimals: Int) -> String {
        let factor = pow(10.0, Double(decimals))
        let rounded = (value * factor).rounded() / factor
        if rounded == rounded.rounded() {
            return "\(clampedInt(rounded))"
        }
        var text = String(format: "%.\(decimals)f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
