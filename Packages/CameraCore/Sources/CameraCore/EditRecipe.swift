import Foundation

// The editor's settings for one photo, saved as Photos adjustment data next to the untouched original, and the
// numbers the renderer gives Core Image. Pure values, so the rules are tested here and the app only applies them.

/// One photo's edit. Every adjustment is 0 when unchanged. Values are clamped on every write, so a recipe read back
/// from Photos or set by the UI always renders.
public struct EditRecipe: Codable, Hashable, Sendable {
    /// The adjustment data's format. A fixed string rather than the bundle identifier: people who sign with a free
    /// Apple ID change the bundle identifier, and their edits must stay editable.
    public static let formatIdentifier = "ca.katsuma.openshutter.edit"
    /// Raise it only when a field changes meaning. A version this code can't read gets the rendered photo from
    /// Photos instead, and the earlier edit stays in the photo.
    public static let formatVersion = "1"

    public enum Look: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, mono, tonal, noir, fade, chrome, process, transfer, instant

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .none: return "Original"
            case .mono: return "Mono"
            case .tonal: return "Tonal"
            case .noir: return "Noir"
            case .fade: return "Fade"
            case .chrome: return "Chrome"
            case .process: return "Process"
            case .transfer: return "Transfer"
            case .instant: return "Instant"
            }
        }

        /// The CIPhotoEffect filter, nil for none.
        public var filterName: String? {
            switch self {
            case .none: return nil
            case .mono: return "CIPhotoEffectMono"
            case .tonal: return "CIPhotoEffectTonal"
            case .noir: return "CIPhotoEffectNoir"
            case .fade: return "CIPhotoEffectFade"
            case .chrome: return "CIPhotoEffectChrome"
            case .process: return "CIPhotoEffectProcess"
            case .transfer: return "CIPhotoEffectTransfer"
            case .instant: return "CIPhotoEffectInstant"
            }
        }

        // A look added by a later version shows the photo without one rather than losing the whole recipe.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = Look(rawValue: try container.decode(String.self)) ?? .none
        }
    }

    // -1...1, 0 leaves the photo as it is. Warmth +1 is warmer (more yellow), tint +1 more magenta.
    public var exposure: Double { didSet { exposure = Self.signedUnit(exposure) } }
    public var highlights: Double { didSet { highlights = Self.signedUnit(highlights) } }
    public var shadows: Double { didSet { shadows = Self.signedUnit(shadows) } }
    public var contrast: Double { didSet { contrast = Self.signedUnit(contrast) } }
    public var brightness: Double { didSet { brightness = Self.signedUnit(brightness) } }
    public var saturation: Double { didSet { saturation = Self.signedUnit(saturation) } }
    public var vibrance: Double { didSet { vibrance = Self.signedUnit(vibrance) } }
    public var warmth: Double { didSet { warmth = Self.signedUnit(warmth) } }
    public var tint: Double { didSet { tint = Self.signedUnit(tint) } }
    // 0...1.
    public var sharpness: Double { didSet { sharpness = Self.unit(sharpness) } }
    public var vignette: Double { didSet { vignette = Self.unit(vignette) } }
    public var look: Look

    /// Quarter turns counterclockwise, 0...3. Any count wraps, so a rotate button can add one each tap.
    public var quarterTurns: Int { didSet { quarterTurns = Self.wrappedTurns(quarterTurns) } }
    /// Mirrored left to right before the turns. To mirror the picture as it is shown, use `flipHorizontally()`.
    public var flipped: Bool
    /// -45...45 after the turns, positive counterclockwise. Core Image's straighten scales the turned picture up so
    /// it still fills its frame, so the frame's size doesn't change.
    public var straightenDegrees: Double { didSet { straightenDegrees = Self.straighten(straightenDegrees) } }
    /// The part kept, in 0...1 of the picture after the flip, turns and straighten, top-left origin (Core Image's y
    /// is 1 - maxY). nil keeps the whole picture: a crop outside the picture, smaller than `minimumCropSide` or
    /// covering all of it is stored as nil.
    public var crop: CropRect? { didSet { crop = Self.validCrop(crop) } }
    /// The preset that made `crop`, for the UI. It doesn't change the render.
    public var cropAspect: AspectRatio?

    /// The smallest crop side, as a share of the picture's side.
    public static let minimumCropSide = 0.01

    public init(exposure: Double = 0, highlights: Double = 0, shadows: Double = 0, contrast: Double = 0,
                brightness: Double = 0, saturation: Double = 0, vibrance: Double = 0, warmth: Double = 0,
                tint: Double = 0, sharpness: Double = 0, vignette: Double = 0, look: Look = .none,
                quarterTurns: Int = 0, flipped: Bool = false, straightenDegrees: Double = 0,
                crop: CropRect? = nil, cropAspect: AspectRatio? = nil) {
        self.exposure = Self.signedUnit(exposure)
        self.highlights = Self.signedUnit(highlights)
        self.shadows = Self.signedUnit(shadows)
        self.contrast = Self.signedUnit(contrast)
        self.brightness = Self.signedUnit(brightness)
        self.saturation = Self.signedUnit(saturation)
        self.vibrance = Self.signedUnit(vibrance)
        self.warmth = Self.signedUnit(warmth)
        self.tint = Self.signedUnit(tint)
        self.sharpness = Self.unit(sharpness)
        self.vignette = Self.unit(vignette)
        self.look = look
        self.quarterTurns = Self.wrappedTurns(quarterTurns)
        self.flipped = flipped
        self.straightenDegrees = Self.straighten(straightenDegrees)
        self.crop = Self.validCrop(crop)
        self.cropAspect = cropAspect
    }

    public static let identity = EditRecipe()

    /// Renders the photo exactly as it was. `cropAspect` alone doesn't count: it only names a preset.
    public var isIdentity: Bool {
        colorValues.allSatisfy { $0 == 0 } && look == .none && !hasGeometry
    }

    /// Turns, mirrors, straightens or crops the picture.
    public var hasGeometry: Bool {
        quarterTurns != 0 || flipped || straightenDegrees != 0 || crop != nil
    }

    /// The same colors with the geometry reset, for Live Photo frames, which can't be cropped or turned yet.
    public var colorOnly: EditRecipe {
        var recipe = self
        recipe.quarterTurns = 0
        recipe.flipped = false
        recipe.straightenDegrees = 0
        recipe.crop = nil
        recipe.cropAspect = nil
        return recipe
    }

    public var parameters: EditParameters { EditParameters(self) }

    // MARK: - Geometry as the person sees it

    /// Turns the picture a quarter turn counterclockwise as it is shown, its crop with it.
    public mutating func rotateCounterclockwise() {
        quarterTurns += 1
        if let rect = crop {
            crop = CropRect(x: rect.y, y: 1 - rect.x - rect.width, width: rect.height, height: rect.width)
        }
    }

    /// Mirrors the picture left to right as it is shown. The flip comes first in the render, so the turns and the
    /// straighten change direction and the crop is mirrored too.
    public mutating func flipHorizontally() {
        flipped.toggle()
        quarterTurns = -quarterTurns
        straightenDegrees = -straightenDegrees
        if let rect = crop {
            crop = CropRect(x: 1 - rect.x - rect.width, y: rect.y, width: rect.width, height: rect.height)
        }
    }

    /// The largest centred crop with `aspect`'s shape, standing (`portrait`) or lying, in a picture whose width /
    /// height is `imageAspect`, in 0...1 coordinates. Unlike `AspectRatio.normalizedCrop`, the crop can stand in a
    /// lying picture. An unusable aspect returns the whole picture.
    public static func centeredCrop(_ aspect: AspectRatio, portrait: Bool, imageAspect: Double) -> CropRect {
        guard imageAspect.isFinite, imageAspect > 0 else { return .unit }
        let shape = portrait ? 1 / aspect.ratio : aspect.ratio
        if shape >= imageAspect {
            let height = imageAspect / shape
            return CropRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = shape / imageAspect
        return CropRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    /// Crops to a centred `aspect`, standing or lying as shown, for a photo `imageWidth` x `imageHeight` upright
    /// (before this recipe's turns, which the crop follows). nil removes the crop.
    public mutating func setCropAspect(_ aspect: AspectRatio?, portrait: Bool, imageWidth: Double,
                                       imageHeight: Double) {
        guard let aspect else {
            crop = nil
            cropAspect = nil
            return
        }
        let turned = quarterTurns % 2 == 1
        let width = turned ? imageHeight : imageWidth
        let height = turned ? imageWidth : imageHeight
        cropAspect = aspect
        crop = Self.centeredCrop(aspect, portrait: portrait, imageAspect: width / height)
    }

    // MARK: - Adjustment data

    /// For PHContentEditingInputRequestOptions.canHandleAdjustmentData: true only for this format and version.
    public static func canRead(formatIdentifier: String, formatVersion: String) -> Bool {
        formatIdentifier == Self.formatIdentifier && formatVersion == Self.formatVersion
    }

    /// The adjustment data, a few hundred bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Never throws: unreadable data gives the identity recipe, so the editor starts from the original.
    public static func decoded(from data: Data) -> EditRecipe {
        (try? JSONDecoder().decode(EditRecipe.self, from: data)) ?? EditRecipe()
    }

    enum CodingKeys: String, CodingKey {
        case exposure, highlights, shadows, contrast, brightness, saturation, vibrance, warmth, tint
        case sharpness, vignette, look, quarterTurns, flipped, straightenDegrees, crop, cropAspect
    }

    // Missing or unreadable keys take their defaults, and everything goes through init's clamping.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(exposure: c.value(.exposure, default: 0),
                  highlights: c.value(.highlights, default: 0),
                  shadows: c.value(.shadows, default: 0),
                  contrast: c.value(.contrast, default: 0),
                  brightness: c.value(.brightness, default: 0),
                  saturation: c.value(.saturation, default: 0),
                  vibrance: c.value(.vibrance, default: 0),
                  warmth: c.value(.warmth, default: 0),
                  tint: c.value(.tint, default: 0),
                  sharpness: c.value(.sharpness, default: 0),
                  vignette: c.value(.vignette, default: 0),
                  look: c.value(.look, default: Look.none),
                  quarterTurns: c.value(.quarterTurns, default: 0),
                  flipped: c.value(.flipped, default: false),
                  straightenDegrees: c.value(.straightenDegrees, default: 0),
                  crop: c.value(.crop, default: nil),
                  cropAspect: c.value(.cropAspect, default: nil))
    }

    // MARK: - Helpers

    private var colorValues: [Double] {
        [exposure, highlights, shadows, contrast, brightness, saturation, vibrance, warmth, tint, sharpness, vignette]
    }

    // NaN means unchanged; plain min and max would let it through to the filters.
    private static func signedUnit(_ value: Double) -> Double {
        value.isNaN ? 0 : Swift.min(Swift.max(value, -1), 1)
    }

    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : Swift.min(Swift.max(value, 0), 1)
    }

    private static func straighten(_ degrees: Double) -> Double {
        degrees.isNaN ? 0 : Swift.min(Swift.max(degrees, -45), 45)
    }

    private static func wrappedTurns(_ turns: Int) -> Int {
        (turns % 4 + 4) % 4
    }

    private static func validCrop(_ rect: CropRect?) -> CropRect? {
        guard let rect, rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        let left = Swift.min(Swift.max(rect.x, 0), 1)
        let top = Swift.min(Swift.max(rect.y, 0), 1)
        let right = Swift.min(Swift.max(rect.maxX, 0), 1)
        let bottom = Swift.min(Swift.max(rect.maxY, 0), 1)
        guard right - left >= minimumCropSide, bottom - top >= minimumCropSide else { return nil }
        // Rounding in the crop math can leave a whole-picture crop a hair inside the edges.
        let edge = 1e-9
        if left <= edge, top <= edge, right >= 1 - edge, bottom >= 1 - edge { return nil }
        // A side that needed no clamping keeps its length as given: (x + width) - x can differ from width in the last
        // bit, and the editor compares the crops it sets with the ones it reads back.
        let width = left == rect.x && right == rect.maxX ? rect.width : right - left
        let height = top == rect.y && bottom == rect.maxY ? rect.height : bottom - top
        return CropRect(x: left, y: top, width: width, height: height)
    }
}

/// A recipe as the inputs of Core Image's built-in filters, in the renderer's order: orientation, straighten, the
/// crop (from the recipe), exposure, highlights and shadows, tone curve, color controls, vibrance, temperature and
/// tint, look, sharpen, vignette. A filter whose `uses...` flag is false is at its neutral values and can be skipped.
public struct EditParameters: Hashable, Sendable {
    /// A CIToneCurve point, in the curve's perceptual 0...1 space.
    public struct CurvePoint: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// A CITemperatureAndTint white point: CIVector(x: temperature, y: tint).
    public struct WhitePoint: Hashable, Sendable {
        /// Kelvin.
        public var temperature: Double
        /// On the -150...150 scale white balance tint uses.
        public var tint: Double

        public init(temperature: Double, tint: Double) {
            self.temperature = temperature
            self.tint = tint
        }
    }

    /// The tone curve that changes nothing.
    public static let identityCurve = [0, 0.25, 0.5, 0.75, 1].map { CurvePoint(x: $0, y: $0) }
    /// CITemperatureAndTint's inputNeutral: the picture's own white.
    public static let neutral = WhitePoint(temperature: 6500, tint: 0)
    /// CIHighlightShadowAdjust inputRadius. 0 keeps the result the same at every render size.
    public static let highlightShadowRadius = 0.0
    /// CISharpenLuminance inputRadius for the full-size photo, in pixels: multiply by the render scale.
    public static let sharpenRadius = 1.69
    /// CIVignette inputRadius, the same at every render size.
    public static let vignetteRadius = 1.5

    // Full-strength steps of each slider, in the filters' units.
    static let evPerUnit = 2.0
    static let highlightRecovery = 0.75
    static let highlightLift = 0.1
    static let contrastPerUnit = 0.3
    static let brightnessPerUnit = 0.15
    static let warmthMireds = 75.0
    static let tintPerUnit = 50.0
    static let sharpnessPerUnit = 0.8

    /// EXIF orientation 1...8 for CIImage.oriented(_:) on the upright photo: the flip, then the turns.
    public var orientation: Int
    /// CIStraighten inputAngle in radians, positive counterclockwise.
    public var straightenAngle: Double
    /// CIExposureAdjust inputEV.
    public var ev: Double
    /// CIHighlightShadowAdjust inputHighlightAmount: 1 leaves highlights alone, lower pulls them down. Highlights
    /// above 0 brighten through `toneCurve` instead, which this filter can't do.
    public var highlightAmount: Double
    /// CIHighlightShadowAdjust inputShadowAmount: 0 leaves shadows alone, above 0 lifts them.
    public var shadowAmount: Double
    /// CIToneCurve inputPoint0 to inputPoint4, applied after CIHighlightShadowAdjust.
    public var toneCurve: [CurvePoint]
    /// CIColorControls inputContrast, inputBrightness, inputSaturation. The filter pivots contrast at 0.5 and adds
    /// brightness as a bias, which suits perceptual values: in a linear working space, run it between
    /// CIFilter.linearToSRGBToneCurve() and sRGBToneCurveToLinear().
    public var contrast: Double
    public var brightness: Double
    public var saturation: Double
    /// CIVibrance inputAmount.
    public var vibrance: Double
    /// CITemperatureAndTint inputTargetNeutral, with inputNeutral `EditParameters.neutral`. The header calls them the
    /// source and the desired white point, so the picture's white moves to this one: a lower temperature warms the
    /// picture and a lower tint turns it magenta. If warmth +1 turns a gray patch blue instead, the filter reads them
    /// the other way round: pass this as inputNeutral and `neutral` as the target.
    public var targetNeutral: WhitePoint
    /// The CIPhotoEffect filter, nil for no look.
    public var lookFilterName: String?
    /// CISharpenLuminance inputSharpness.
    public var sharpness: Double
    /// CIVignette inputIntensity.
    public var vignetteIntensity: Double

    public init(_ recipe: EditRecipe) {
        orientation = Self.orientation(quarterTurns: recipe.quarterTurns, flipped: recipe.flipped)
        straightenAngle = recipe.straightenDegrees * .pi / 180
        ev = Self.evPerUnit * recipe.exposure
        highlightAmount = 1 + Self.highlightRecovery * Swift.min(recipe.highlights, 0)
        shadowAmount = recipe.shadows
        var curve = Self.identityCurve
        curve[3].y += Self.highlightLift * Swift.max(recipe.highlights, 0)
        toneCurve = curve
        contrast = 1 + Self.contrastPerUnit * recipe.contrast
        brightness = Self.brightnessPerUnit * recipe.brightness
        saturation = 1 + recipe.saturation
        vibrance = recipe.vibrance
        // Mired steps look even across the slider, which kelvin steps don't.
        let neutralMireds = 1_000_000 / Self.neutral.temperature
        targetNeutral = WhitePoint(temperature: 1_000_000 / (neutralMireds + Self.warmthMireds * recipe.warmth),
                                   tint: Self.neutral.tint - Self.tintPerUnit * recipe.tint)
        lookFilterName = recipe.look.filterName
        sharpness = Self.sharpnessPerUnit * recipe.sharpness
        vignetteIntensity = recipe.vignette
    }

    public var usesOrientation: Bool { orientation != 1 }
    public var usesStraighten: Bool { straightenAngle != 0 }
    public var usesExposure: Bool { ev != 0 }
    public var usesHighlightShadow: Bool { highlightAmount != 1 || shadowAmount != 0 }
    public var usesToneCurve: Bool { toneCurve != Self.identityCurve }
    public var usesColorControls: Bool { contrast != 1 || brightness != 0 || saturation != 1 }
    public var usesVibrance: Bool { vibrance != 0 }
    public var usesTemperatureAndTint: Bool { targetNeutral != Self.neutral }
    public var usesLook: Bool { lookFilterName != nil }
    public var usesSharpen: Bool { sharpness != 0 }
    public var usesVignette: Bool { vignetteIntensity != 0 }

    /// No filter needs to run. The crop is the recipe's, not a filter.
    public var isNeutral: Bool {
        !(usesOrientation || usesStraighten || usesExposure || usesHighlightShadow || usesToneCurve
          || usesColorControls || usesVibrance || usesTemperatureAndTint || usesLook || usesSharpen || usesVignette)
    }

    // The flip comes first, so a mirrored picture uses the mirrored orientations: 2, 5, 4 and 7 for 0 to 3 turns.
    static func orientation(quarterTurns: Int, flipped: Bool) -> Int {
        let plain = [1, 8, 3, 6]
        let mirrored = [2, 5, 4, 7]
        let turns = (quarterTurns % 4 + 4) % 4
        return flipped ? mirrored[turns] : plain[turns]
    }
}
