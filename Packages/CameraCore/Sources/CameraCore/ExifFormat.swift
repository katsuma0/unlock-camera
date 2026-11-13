import Foundation

/// The text and number forms EXIF, GPS and QuickTime metadata use. Text is built from integers: no formatter, locale
/// or calendar setting of the phone can turn a "." into a "," or a digit into another script, and no formatter is
/// shared between the capture queues that write files at the same time.
public enum ExifFormat {
    // MARK: - Dates

    /// "2026:11:13 22:04:05", the wall clock time in `timeZone`.
    public static func exifDate(_ date: Date, timeZone: TimeZone) -> String {
        let clock = clockFields(date, timeZone: timeZone)
        return datePart(clock, separator: ":") + " " + timePart(clock)
    }

    /// "+05:30": how far `timeZone` was from UTC at `date`. EXIF stores local times, and this says which zone.
    public static func offset(_ date: Date, timeZone: TimeZone) -> String {
        offsetText(seconds: timeZone.secondsFromGMT(for: date), separator: ":")
    }

    /// Milliseconds past the second, three digits: "007". Rounded to the nearest millisecond, except that the last
    /// one stays "999": rounding up to "1000" would belong to the next second, which the date already doesn't show.
    public static func subseconds(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else { return "000" }
        let milliseconds = Int(((seconds - seconds.rounded(.down)) * 1000).rounded())
        return padded(Swift.min(Swift.max(milliseconds, 0), 999), width: 3)
    }

    /// "2026-11-13T22:04:05-0800", the form QuickTime's creation date takes.
    public static func quickTimeDate(_ date: Date, timeZone: TimeZone) -> String {
        let clock = clockFields(date, timeZone: timeZone)
        return datePart(clock, separator: "-") + "T" + timePart(clock)
            + offsetText(seconds: timeZone.secondsFromGMT(for: date), separator: "")
    }

    /// GPS DateStamp, "2026:11:14": the day in UTC, which is not always the local day.
    public static func gpsDateStamp(_ date: Date) -> String {
        datePart(clockFields(date, timeZone: utc), separator: ":")
    }

    /// GPS TimeStamp, "04:30:00" in UTC.
    public static func gpsTimeStamp(_ date: Date) -> String {
        timePart(clockFields(date, timeZone: utc))
    }

    // MARK: - Location

    /// ISO 6709 as Apple's Camera writes it into movies: "+37.3349-122.0090+012.300/". The altitude goes in only
    /// when it is valid (Core Location reports 0 when it has none). nil for a fix off the globe.
    public static func iso6709(_ geo: GeoTag) -> String? {
        guard geo.hasValidCoordinates else { return nil }
        var text = signedFixed(geo.latitude, integerDigits: 2, decimals: 4)
            + signedFixed(geo.longitude, integerDigits: 3, decimals: 4)
        if geo.hasValidAltitude {
            text += signedFixed(geo.altitude, integerDigits: 3, decimals: 3)
        }
        return text + "/"
    }

    // MARK: - APEX

    /// ShutterSpeedValue, -log2(t). nil for a time that is not a positive number, so the key is left out.
    public static func shutterSpeedValue(seconds: Double) -> Double? {
        guard isPositive(seconds) else { return nil }
        return cleaned(-log2(seconds))
    }

    /// ApertureValue, 2 log2(N).
    public static func apertureValue(fNumber: Double) -> Double? {
        guard isPositive(fNumber) else { return nil }
        return cleaned(2 * log2(fNumber))
    }

    /// BrightnessValue from a light product P = t x ISO / N squared: log2(3.125 / P), which is APEX's Av + Tv - Sv
    /// with Sv = log2(ISO / 3.125). Negative in the dark.
    public static func brightnessValue(lightProduct: Double) -> Double? {
        guard isPositive(lightProduct) else { return nil }
        return cleaned(log2(3.125 / lightProduct))
    }

    // MARK: - Subject area

    /// EXIF SubjectArea moved into a crop: a point (x, y), a circle (x, y, diameter) or a rectangle (centre x,
    /// centre y, width, height), and the crop, both in stored pixels of the uncropped image. A point or circle keeps
    /// its size and moves with the crop; a rectangle keeps the part inside it. nil when the subject falls outside the
    /// crop, or for anything that isn't one of the three shapes.
    public static func subjectArea(_ area: [Int], croppedTo crop: CropRect) -> [Int]? {
        guard crop.x.isFinite, crop.y.isFinite, crop.width.isFinite, crop.height.isFinite,
              crop.width > 0, crop.height > 0, area.allSatisfy({ $0 >= 0 }) else { return nil }
        switch area.count {
        case 2, 3:
            let x = Double(area[0]) - crop.x
            let y = Double(area[1]) - crop.y
            // Pixel positions run from 0 to one less than the size.
            guard x >= 0, y >= 0, x < crop.width, y < crop.height else { return nil }
            return [Int(x.rounded(.down)), Int(y.rounded(.down))] + area.dropFirst(2)
        case 4:
            let halfWidth = Double(area[2]) / 2
            let halfHeight = Double(area[3]) / 2
            let left = Swift.max(Double(area[0]) - halfWidth, crop.x)
            let right = Swift.min(Double(area[0]) + halfWidth, crop.maxX)
            let top = Swift.max(Double(area[1]) - halfHeight, crop.y)
            let bottom = Swift.min(Double(area[1]) + halfHeight, crop.maxY)
            guard right > left, bottom > top else { return nil }
            let centreX = Swift.max(Swift.min((left + right) / 2 - crop.x, crop.width - 1), 0)
            let centreY = Swift.max(Swift.min((top + bottom) / 2 - crop.y, crop.height - 1), 0)
            return [Int(centreX.rounded(.down)), Int(centreY.rounded(.down)),
                    Int((right - left).rounded()), Int((bottom - top).rounded())]
        default:
            return nil
        }
    }

    // MARK: - Numbers as text

    /// At most `maxDecimals` decimals, trailing zeros dropped: "0.033333", "30", "-0.7". Always a "." and no
    /// grouping, whatever the phone's region; what XMP, QuickTime and the comment need. Not a number reads "0".
    public static func decimal(_ value: Double, maxDecimals: Int = 6) -> String {
        digits(value, decimals: maxDecimals, keepZeros: false)
    }

    /// Exactly `decimals` decimals: "180.00", "43.65320". Same rules as `decimal`.
    public static func fixed(_ value: Double, decimals: Int) -> String {
        digits(value, decimals: decimals, keepZeros: true)
    }

    // MARK: - Shared with MetadataFormat (reading)

    /// A wall clock time as calendar fields.
    struct ClockFields: Equatable {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        /// Seconds after `second`, when the text had them.
        var fraction: Double = 0
    }

    static let utc = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func clockFields(_ date: Date, timeZone: TimeZone) -> ClockFields {
        let c = calendar(in: timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return ClockFields(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0,
                           minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// The moment `clock` names in `timeZone`; nil for a day that doesn't exist, such as 31 February.
    static func date(_ clock: ClockFields, timeZone: TimeZone) -> Date? {
        let gregorian = calendar(in: timeZone)
        let components = DateComponents(year: clock.year, month: clock.month, day: clock.day, hour: clock.hour,
                                        minute: clock.minute, second: clock.second)
        guard let date = gregorian.date(from: components) else { return nil }
        // The calendar rolls an impossible day into the next month; reading the fields back catches that.
        let back = clockFields(date, timeZone: timeZone)
        guard back.year == clock.year, back.month == clock.month, back.day == clock.day else { return nil }
        return date.addingTimeInterval(clock.fraction)
    }

    /// Reads "2026:11:13 10:41:12" as EXIF writes it, and the variants files carry: "-" between the date's parts,
    /// "T" before the time, a fraction of a second, trailing spaces or NULs. nil for an empty or zeroed date.
    static func parseClock(_ text: String) -> ClockFields? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "T" })
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(whereSeparator: { $0 == ":" || $0 == "-" })
        var time = parts[1].trimmingCharacters(in: .whitespaces)
        var fraction = 0.0
        if let dot = time.firstIndex(of: ".") {
            guard let value = fractionOfSecond(time[time.index(after: dot)...]) else { return nil }
            fraction = value
            time = String(time[..<dot])
        }
        let clock = time.split(separator: ":")
        guard day.count == 3, clock.count == 3 || clock.count == 2,
              let year = number(day[0]), let month = number(day[1]), let dayOfMonth = number(day[2]),
              let hour = number(clock[0]), let minute = number(clock[1]) else { return nil }
        let second = clock.count == 3 ? number(clock[2]) : 0
        guard let second, (1...9999).contains(year), (1...12).contains(month), (1...31).contains(dayOfMonth),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        // A leap second is shown as the last ordinary one; Foundation has no 60th second.
        return ClockFields(year: year, month: month, day: dayOfMonth, hour: hour, minute: minute,
                           second: Swift.min(second, 59), fraction: fraction)
    }

    /// Seconds east of UTC from "+05:30", "-0330", "+01" or "Z". nil for anything else or past 18 hours.
    static func offsetSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Z" || trimmed == "z" { return 0 }
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter { $0 != ":" }
        guard digits.count == 2 || digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(digits.prefix(2)), let minutes = digits.count == 4 ? Int(digits.suffix(2)) : 0,
              minutes < 60 else { return nil }
        let total = hours * 3600 + minutes * 60
        guard total <= 18 * 3600 else { return nil }
        return sign == "-" ? -total : total
    }

    /// "532" as 0.532 s: the digits after a decimal point. nil when there are none, or anything but digits.
    static func fractionOfSecond<S: StringProtocol>(_ text: S) -> Double? {
        let digits = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Double("0." + digits) else { return nil }
        return value
    }

    /// "+05:30" or "+0530" from seconds east of UTC; seconds past the minute are dropped, as EXIF has no place for them.
    static func offsetText(seconds: Int, separator: String) -> String {
        let minutes = abs(seconds) / 60
        return (seconds < 0 ? "-" : "+") + padded(minutes / 60, width: 2) + separator + padded(minutes % 60, width: 2)
    }

    static func isPositive(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    // MARK: - Helpers

    private static func datePart(_ clock: ClockFields, separator: String) -> String {
        padded(clock.year, width: 4) + separator + padded(clock.month, width: 2) + separator + padded(clock.day, width: 2)
    }

    private static func timePart(_ clock: ClockFields) -> String {
        padded(clock.hour, width: 2) + ":" + padded(clock.minute, width: 2) + ":" + padded(clock.second, width: 2)
    }

    /// Zero padded on the left; String(Int) never groups digits or changes script.
    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(abs(value))
        let padding = String(repeating: "0", count: Swift.max(width - text.count, 0))
        return (value < 0 ? "-" : "") + padding + text
    }

    /// ASCII digits only, so a stray sign or space makes the whole field unreadable rather than half read.
    private static func number<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, text.count <= 4, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// "+37.3349", "-005.500": a sign, then at least `integerDigits` digits before the point.
    private static func signedFixed(_ value: Double, integerDigits: Int, decimals: Int) -> String {
        let text = digits(abs(value), decimals: decimals, keepZeros: true)
        let integerCount = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
        let padding = String(repeating: "0", count: Swift.max(integerDigits - integerCount, 0))
        // A value that rounds to zero has no side of the equator or of sea level to be on.
        let negative = value < 0 && text.contains(where: { $0 != "0" && $0 != "." })
        return (negative ? "-" : "+") + padding + text
    }

    private static func digits(_ value: Double, decimals: Int, keepZeros: Bool) -> String {
        let finite = value.isFinite ? value : 0
        var places = Swift.min(Swift.max(decimals, 0), 12)
        var scaled = (abs(finite) * pow(10, Double(places))).rounded()
        // Past 2^53 a Double stops holding every whole number, so decimals go before the digits do.
        while scaled >= 9e15 && places > 0 {
            places -= 1
            scaled = (abs(finite) * pow(10, Double(places))).rounded()
        }
        let units = UInt64(Swift.min(scaled, 9e15))
        var scale: UInt64 = 1
        for _ in 0..<places { scale *= 10 }
        var text = String(units / scale)
        if places > 0 {
            var fraction = String(units % scale)
            fraction = String(repeating: "0", count: places - fraction.count) + fraction
            if !keepZeros {
                while fraction.hasSuffix("0") { fraction.removeLast() }
            }
            if !fraction.isEmpty { text += "." + fraction }
        }
        // "-0" would read as a value below zero.
        return finite < 0 && units > 0 ? "-" + text : text
    }

    /// -0 becomes 0 and anything not finite nil, so a key is either a real number or left out.
    private static func cleaned(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return value == 0 ? 0 : value
    }
}
