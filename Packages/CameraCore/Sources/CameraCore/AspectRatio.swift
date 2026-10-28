import Foundation

/// A rectangle in pixels or in normalized 0...1 image coordinates, top-left origin.
public struct CropRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The whole image in normalized coordinates.
    public static let unit = CropRect(x: 0, y: 0, width: 1, height: 1)
}

/// A frame shape without an orientation: 4:3 covers both 4032x3024 and 3024x4032, and crops follow the image.
public struct AspectRatio: Hashable, Codable, Sendable, Identifiable {
    public var long: Double
    public var short: Double

    /// Order-agnostic: long = max(a, b), short = min(a, b). Non-positive or non-finite input falls back to 4:3,
    /// the shape of the sensor.
    public init(_ a: Double, _ b: Double) {
        let sides = Self.validSides(a, b)
        long = sides.long
        short = sides.short
    }

    // A stale or hand-edited settings file goes through the same rules as init.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(Double.self, forKey: .long), try container.decode(Double.self, forKey: .short))
    }

    public var id: String { label }

    /// long / short, so never below 1.
    public var ratio: Double {
        let sides = Self.validSides(long, short)
        return sides.long / sides.short
    }

    /// "4:3", "16:9", "65:24" when both sides are whole numbers, otherwise "x:1" with up to two decimals and
    /// trailing zeros dropped: "2.39:1", "1.85:1".
    public var label: String {
        let sides = Self.validSides(long, short)
        if let longText = Self.wholeNumber(sides.long), let shortText = Self.wholeNumber(sides.short) {
            return "\(longText):\(shortText)"
        }
        var text = String(format: "%.2f", sides.long / sides.short)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + ":1"
    }

    public static let fourThree = AspectRatio(4, 3)
    public static let threeTwo = AspectRatio(3, 2)
    public static let sixteenNine = AspectRatio(16, 9)
    public static let square = AspectRatio(1, 1)
    public static let fiveFour = AspectRatio(5, 4)
    public static let twoOne = AspectRatio(2, 1)
    /// Anamorphic widescreen is quoted as a decimal ratio, not a whole-number pair.
    public static let cinemaScope = AspectRatio(2.39, 1)
    /// The XPan panorama frame, 65 x 24 mm on 35 mm film.
    public static let xpan = AspectRatio(65, 24)

    /// Picker order.
    public static let presets: [AspectRatio] = [fourThree, square, sixteenNine, threeTwo, fiveFour, twoOne, cinemaScope, xpan]

    /// Largest centred crop of a width x height image with this ratio, in pixels (may be fractional). The crop's long
    /// side runs along the image's longer axis, and a square image counts as landscape.
    /// An empty or non-finite size returns a zero rect.
    public func centeredCrop(width: Double, height: Double) -> CropRect {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return CropRect(x: 0, y: 0, width: 0, height: 0)
        }
        let sides = Self.validSides(long, short)
        let cropWidth: Double
        let cropHeight: Double
        // Cross products instead of ratios keep whole-number cases exact: 4:3 of 4032x3024 is the full frame.
        if width >= height {
            if width * sides.short >= height * sides.long {
                cropHeight = height
                cropWidth = height * sides.long / sides.short
            } else {
                cropWidth = width
                cropHeight = width * sides.short / sides.long
            }
        } else {
            if height * sides.short >= width * sides.long {
                cropWidth = width
                cropHeight = width * sides.long / sides.short
            } else {
                cropHeight = height
                cropWidth = height * sides.short / sides.long
            }
        }
        // The products still round, so a crop that should fit exactly can come out an ulp past the image edge.
        let fittedWidth = Swift.min(cropWidth, width)
        let fittedHeight = Swift.min(cropHeight, height)
        return CropRect(x: (width - fittedWidth) / 2, y: (height - fittedHeight) / 2,
                        width: fittedWidth, height: fittedHeight)
    }

    /// `centeredCrop` of an image whose width / height is `imageAspect`, in 0...1 image coordinates.
    /// An unusable aspect returns the full frame, because cropping to nothing would lose the picture.
    public func normalizedCrop(imageAspect: Double) -> CropRect {
        guard imageAspect.isFinite, imageAspect > 0 else { return .unit }
        let crop = centeredCrop(width: imageAspect, height: 1)
        let width = crop.width / imageAspect
        // Centring again in 0...1 keeps x + width within 1; dividing x and width separately can round past it.
        return CropRect(x: (1 - width) / 2, y: crop.y, width: width, height: crop.height)
    }

    /// Same shape within 0.5% (each ratio within 0.5% of the other), so a 1.78:1 sensor mode counts as 16:9.
    public func matches(_ other: AspectRatio) -> Bool {
        let a = ratio
        let b = other.ratio
        return abs(a - b) <= 0.005 * Swift.min(a, b)
    }

    // MARK: - Helpers

    // The stored sides can also be assigned directly, so every reading applies the same rules as init.
    private static func validSides(_ a: Double, _ b: Double) -> (long: Double, short: Double) {
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { return (4, 3) }
        let long = Swift.max(a, b)
        let short = Swift.min(a, b)
        // A ratio that overflows to infinity is as unusable as a zero side.
        guard (long / short).isFinite else { return (4, 3) }
        return (long, short)
    }

    // The bound keeps Int(_:) from trapping; nobody writes a ratio with sides that large.
    private static func wholeNumber(_ value: Double) -> Int? {
        guard value == value.rounded(), value < 1e9 else { return nil }
        return Int(value)
    }
}
