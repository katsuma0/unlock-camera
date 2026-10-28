import Foundation

/// Focal length and zoom readouts for the lens picker.
public enum LensMath {
    /// Diagonal of a 36 x 24 mm frame. Equivalent focal lengths compare diagonals, so any sensor shape works.
    static let fullFrameDiagonal = 43.2666

    /// 35 mm equivalent focal length from the horizontal field of view in degrees of a sensor whose
    /// width/height is `aspect` (>= 1). Uses the diagonal: tan(d/2) = tan(h/2) * sqrt(1 + 1/aspect^2),
    /// f = 43.2666 / (2 * tan(d/2)). Invalid FOV (<= 0 or >= 180) returns 0.
    /// AVFoundation measures the field of view along the long side, so an aspect below 1 is read as
    /// height/width and flipped; a NaN, infinite or non-positive aspect falls back to 4:3.
    public static func equivalentFocalLength(horizontalFOV: Double, aspect: Double = 4.0 / 3.0) -> Double {
        guard horizontalFOV > 0, horizontalFOV < 180 else { return 0 }
        let ratio = landscapeAspect(aspect)
        let tanHalfDiagonal = tan(horizontalFOV * .pi / 360) * (1 + 1 / (ratio * ratio)).squareRoot()
        // A field so narrow that tan underflows to 0 would otherwise divide by zero.
        guard tanHalfDiagonal > 0, tanHalfDiagonal.isFinite else { return 0 }
        let focalLength = fullFrameDiagonal / (2 * tanHalfDiagonal)
        // Slightly wider fields (under about 1e-305 degrees) still overflow; callers treat 0 as unknown.
        return focalLength.isFinite ? focalLength : 0
    }

    /// focalLength / reference: how much tighter a lens frames than the reference lens. reference <= 0 -> 1.
    /// An unknown focal length (the 0 an invalid FOV gives) also reads as 1, so the lens still gets a usable button.
    public static func relativeZoom(focalLength: Double, reference: Double) -> Double {
        guard focalLength.isFinite, focalLength > 0, reference.isFinite, reference > 0 else { return 1 }
        let zoom = focalLength / reference
        return zoom.isFinite && zoom > 0 ? zoom : 1
    }

    /// iOS camera style: values < 1 drop the leading zero (".5"), whole numbers have no decimals ("1", "2", "5"),
    /// others one decimal ("1.2", "2.5"); `selected` appends "×" (U+00D7): ".5×", "1×", "2.5×".
    /// Round to 1 decimal first (0.49 -> ".5"). Non-finite or non-positive zoom reads "0".
    public static func zoomLabel(_ zoom: Double, selected: Bool) -> String {
        let value = zoom.isFinite && zoom > 0 ? zoom : 0
        let rounded = (value * 10).rounded() / 10
        var text: String
        if rounded == rounded.rounded() {
            text = String(saturatingInt(rounded))
        } else {
            text = String(format: "%.1f", rounded)
            if text.hasPrefix("0.") {
                text.removeFirst()
            }
        }
        return selected ? text + "\u{00D7}" : text
    }

    /// "24 mm" (rounded). Non-finite or non-positive input reads "0 mm".
    public static func focalLengthLabel(_ mm: Double) -> String {
        "\(saturatingInt(mm.isFinite && mm > 0 ? mm : 0)) mm"
    }

    // MARK: - Helpers

    private static func landscapeAspect(_ aspect: Double) -> Double {
        guard aspect.isFinite, aspect > 0 else { return 4.0 / 3.0 }
        let flipped = aspect >= 1 ? aspect : 1 / aspect
        return flipped.isFinite ? flipped : 4.0 / 3.0
    }

    /// Int(value.rounded()) that saturates instead of trapping past Int's range; NaN reads as 0.
    private static func saturatingInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(Swift.min(Swift.max(value, -1e15), 1e15).rounded())
    }
}
