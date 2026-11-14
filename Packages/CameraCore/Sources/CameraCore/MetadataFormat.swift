import Foundation

/// Readable text for the values a photo file stores, for the photo info tool. It shows any file's own data under the
/// standard names, so these are the EXIF terms, in sentence case. Dates and offsets are read with the same rules
/// ExifFormat writes them by.
public enum MetadataFormat {
    // MARK: - Location

    /// Decimal degrees with the sign the reference gives: south and west are negative. A missing or unknown
    /// reference keeps the value's own sign. nil for a value that is not a number or not on the globe.
    public static func signedDegrees(_ value: Double, ref: String?) -> Double? {
        guard value.isFinite, abs(value) <= 180 else { return nil }
        switch normalized(ref) {
        case "S", "W": return -abs(value)
        case "N", "E": return abs(value)
        default: return value
        }
    }

    /// "43.65320° N".
    public static func latitude(_ value: Double, ref: String?) -> String? {
        guard let degrees = signedDegrees(value, ref: ref), abs(degrees) <= 90 else { return nil }
        return ExifFormat.fixed(abs(degrees), decimals: 5) + "\u{00B0} " + (degrees < 0 ? "S" : "N")
    }

    /// "79.38320° W".
    public static func longitude(_ value: Double, ref: String?) -> String? {
        guard let degrees = signedDegrees(value, ref: ref) else { return nil }
        return ExifFormat.fixed(abs(degrees), decimals: 5) + "\u{00B0} " + (degrees < 0 ? "W" : "E")
    }

    /// "43.65320° N, 79.38320° W".
    public static func coordinates(latitude: Double, latitudeRef: String?, longitude: Double,
                                   longitudeRef: String?) -> String? {
        guard let north = Self.latitude(latitude, ref: latitudeRef),
              let east = Self.longitude(longitude, ref: longitudeRef) else { return nil }
        return north + ", " + east
    }

    /// Metres, negative below sea level. AltitudeRef 1 means below; some files store the sign instead.
    public static func signedAltitude(_ value: Double, ref: Int?) -> Double? {
        guard value.isFinite else { return nil }
        return ref == 1 ? -abs(value) : value
    }

    /// "12.3 m above sea level", "5 m below sea level".
    public static func altitude(_ value: Double, ref: Int?) -> String? {
        guard let metres = signedAltitude(value, ref: ref) else { return nil }
        return ExifFormat.decimal(abs(metres), maxDecimals: 1) + " m " + (metres < 0 ? "below" : "above") + " sea level"
    }

    /// "36 km/h". The reference is K (km/h, the default), M (mph) or N (knots).
    public static func speed(_ value: Double, ref: String?) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        let unit: String
        switch normalized(ref) {
        case "M": unit = "mph"
        case "N": unit = "knots"
        default: unit = "km/h"
        }
        return ExifFormat.decimal(value, maxDecimals: 1) + " " + unit
    }

    /// "190° from true north", "12° from magnetic north".
    public static func direction(_ value: Double, ref: String?) -> String? {
        guard value.isFinite else { return nil }
        var degrees = value.rounded().truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        let north = normalized(ref) == "M" ? "magnetic north" : "true north"
        return ExifFormat.decimal(degrees, maxDecimals: 0) + "\u{00B0} from " + north
    }

    /// "5 m", "4.7 m": how far off the position may be (HPositioningError).
    public static func positioningError(_ metres: Double) -> String? {
        guard metres.isFinite, metres >= 0 else { return nil }
        return ExifFormat.decimal(metres, maxDecimals: 1) + " m"
    }

    /// The moment a GPS DateStamp ("2026:11:14") and TimeStamp ("04:30:00", maybe with a fraction) name, in UTC.
    public static func gpsDate(dateStamp: String, timeStamp: String) -> Date? {
        guard let clock = ExifFormat.parseClock(dateStamp + " " + timeStamp) else { return nil }
        return ExifFormat.date(clock, timeZone: ExifFormat.utc)
    }

    // MARK: - Dates

    /// The moment an EXIF date ("2026:11:13 10:41:12") names, with its offset ("+01:00") and subseconds ("532") when
    /// the file has them. Without an offset the date is a wall clock time in an unknown zone; `assuming` stands in.
    public static func date(fromExif text: String, offset: String? = nil, subseconds: String? = nil,
                            assuming zone: TimeZone = .current) -> Date? {
        guard var clock = ExifFormat.parseClock(text) else { return nil }
        if let subseconds, let fraction = ExifFormat.fractionOfSecond(subseconds) {
            clock.fraction = fraction
        }
        return ExifFormat.date(clock, timeZone: offset.flatMap(timeZone(offset:)) ?? zone)
    }

    /// The fixed zone an EXIF offset ("+05:30") names, for showing a date in the time it was taken.
    public static func timeZone(offset: String) -> TimeZone? {
        ExifFormat.offsetSeconds(offset).flatMap { TimeZone(secondsFromGMT: $0) }
    }

    // MARK: - EXIF values

    /// The Flash tag's bits as text: "Auto, did not fire", "On, fired, return detected", "No flash function".
    public static func flash(_ value: Int) -> String {
        // Bit 5: the camera has no flash, which says all there is.
        if value & 0x20 != 0 { return "No flash function" }
        var parts: [String] = []
        switch (value >> 3) & 0x3 {
        case 1: parts.append("On")
        case 2: parts.append("Off")
        case 3: parts.append("Auto")
        default: break
        }
        parts.append(value & 0x1 != 0 ? "fired" : "did not fire")
        switch (value >> 1) & 0x3 {
        case 2: parts.append("return not detected")
        case 3: parts.append("return detected")
        default: break
        }
        if value & 0x40 != 0 { parts.append("red-eye reduction") }
        return sentence(parts.joined(separator: ", "))
    }

    public static func exposureProgram(_ value: Int) -> String {
        name(value, [0: "Not defined", 1: "Manual", 2: "Normal program", 3: "Aperture priority",
                     4: "Shutter priority", 5: "Creative program", 6: "Action program", 7: "Portrait mode",
                     8: "Landscape mode"])
    }

    public static func exposureMode(_ value: Int) -> String {
        name(value, [0: "Auto", 1: "Manual", 2: "Auto bracket"])
    }

    public static func meteringMode(_ value: Int) -> String {
        name(value, [0: "Unknown", 1: "Average", 2: "Center-weighted average", 3: "Spot", 4: "Multi-spot",
                     5: "Pattern", 6: "Partial", 255: "Other"])
    }

    public static func whiteBalance(_ value: Int) -> String {
        name(value, [0: "Auto", 1: "Manual"])
    }

    public static func lightSource(_ value: Int) -> String {
        name(value, [0: "Unknown", 1: "Daylight", 2: "Fluorescent", 3: "Tungsten", 4: "Flash", 9: "Fine weather",
                     10: "Cloudy", 11: "Shade", 12: "Daylight fluorescent", 13: "Day white fluorescent",
                     14: "Cool white fluorescent", 15: "White fluorescent", 16: "Warm white fluorescent",
                     17: "Standard light A", 18: "Standard light B", 19: "Standard light C", 20: "D55", 21: "D65",
                     22: "D75", 23: "D50", 24: "ISO studio tungsten", 255: "Other"])
    }

    public static func sceneCaptureType(_ value: Int) -> String {
        name(value, [0: "Standard", 1: "Landscape", 2: "Portrait", 3: "Night scene"])
    }

    public static func sceneType(_ value: Int) -> String {
        name(value, [1: "Directly photographed"])
    }

    public static func sensingMethod(_ value: Int) -> String {
        name(value, [1: "Not defined", 2: "One-chip color area", 3: "Two-chip color area", 4: "Three-chip color area",
                     5: "Color sequential area", 7: "Trilinear", 8: "Color sequential linear"])
    }

    /// 0 and 1 are the standard's; iPhones also mark their HDR, panorama and portrait pictures here.
    public static func customRendered(_ value: Int) -> String {
        name(value, [0: "Normal", 1: "Custom", 2: "HDR, original not saved", 3: "HDR, original saved",
                     4: "Original for HDR", 6: "Panorama", 7: "Portrait HDR", 8: "Portrait"])
    }

    public static func compositeImage(_ value: Int) -> String {
        name(value, [0: "Unknown", 1: "Not a composite", 2: "General composite",
                     3: "Composite captured while shooting"])
    }

    /// The eight EXIF orientations, as what a viewer does to show the picture upright.
    public static func orientation(_ value: Int) -> String {
        name(value, [1: "Normal", 2: "Mirrored horizontally", 3: "Rotated 180\u{00B0}", 4: "Mirrored vertically",
                     5: "Mirrored horizontally, rotated 90\u{00B0} counterclockwise",
                     6: "Rotated 90\u{00B0} clockwise",
                     7: "Mirrored horizontally, rotated 90\u{00B0} clockwise",
                     8: "Rotated 90\u{00B0} counterclockwise"])
    }

    /// EXIF ColorSpace: 1 sRGB; 65535 "uncalibrated", which is what a Display P3 photo says.
    public static func colorSpace(_ value: Int) -> String {
        name(value, [1: "sRGB", 2: "Adobe RGB", 65535: "Uncalibrated"])
    }

    /// LensSpecification [shortest mm, longest mm, f-number at shortest, f-number at longest] as
    /// "1.54-6.86 mm f/1.78-2.2", "6.765 mm f/1.78". EXIF stores 0 for a value it doesn't know.
    public static func lensSpecification(_ values: [Double]) -> String? {
        guard values.count == 4 else { return nil }
        let known = values.map { $0.isFinite && $0 > 0 ? $0 : nil }
        var parts: [String] = []
        if let range = range(known[0], known[1]) { parts.append(range + " mm") }
        if let range = range(known[2], known[3]) { parts.append("f/" + range) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Names

    /// A key's name as words: "SubsecTimeOriginal" reads "Subsec time original", "ISOSpeedRatings" "ISO speed
    /// ratings", "FocalLenIn35mmFilm" "Focal len in 35mm film". For keys the readable names table doesn't have.
    public static func readableKey(_ key: String) -> String {
        let characters = Array(key)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character == "_" || character == " " || character == "-" {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let previous = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let startsWord = (previous.isLowercase && character.isUppercase)
                    || (previous.isLetter && character.isNumber)
                    || (previous.isNumber && character.isUppercase)
                    // The last capital of a run starts the next word: "ISOSpeed" is "ISO" and "Speed".
                    || (previous.isUppercase && character.isUppercase && (next?.isLowercase ?? false))
                if startsWord {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return key }

        return words.enumerated().map { index, word in
            // Acronyms and single capitals stay as they are ("ISO", "GPS", "X"); other words are lower case after
            // the first, which takes a capital.
            let isAcronym = word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber }
                && word.contains(where: \.isLetter)
            if isAcronym || (word.count == 1 && word.first?.isUppercase == true) { return word }
            let lower = word.lowercased()
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }.joined(separator: " ")
    }

    // MARK: - Helpers

    /// A value's name, or "Unknown (n)" for one the standard doesn't list.
    private static func name(_ value: Int, _ names: [Int: String]) -> String {
        names[value] ?? "Unknown (\(value))"
    }

    private static func normalized(_ ref: String?) -> String {
        (ref ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            .uppercased()
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "1.54-6.86", or one value when both ends are the same or only one is known.
    private static func range(_ low: Double?, _ high: Double?) -> String? {
        switch (low, high) {
        case let (low?, high?):
            let lowText = ExifFormat.decimal(low, maxDecimals: 3)
            let highText = ExifFormat.decimal(high, maxDecimals: 3)
            return lowText == highText ? lowText : lowText + "-" + highText
        case let (low?, nil): return ExifFormat.decimal(low, maxDecimals: 3)
        case let (nil, high?): return ExifFormat.decimal(high, maxDecimals: 3)
        case (nil, nil): return nil
        }
    }
}
