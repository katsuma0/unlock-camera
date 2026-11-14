import Foundation

// What "Remove metadata" in the photo info tool does to a copy, decided without ImageIO: the ways to write the copy
// for each file type, what a clean copy may still hold, the copy's name, and the sentence that says what went. The
// app turns each step into ImageIO calls and opens every copy again with `leftovers` before offering it. Group and key
// names here are ImageIO's own strings, so the app can assert once, against its constants, that they still match.

/// How much the photo info tool takes out of a copy.
public enum StripMode: String, CaseIterable, Sendable, Identifiable {
    /// Everything but the picture: place, camera and lens, settings, dates, names, Apple's camera data and the app's
    /// own fields (ShotXMP).
    case everything
    /// GPS and the IPTC and XMP place fields. The rest stays.
    case locationOnly

    public static let `default` = StripMode.everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everything: return "Everything"
        case .locationOnly: return "Location only"
        }
    }

    /// The line under the choice, when it needs one.
    public var note: String? {
        switch self {
        case .everything: return nil
        case .locationOnly:
            return "Some cameras also keep place details in their own notes. Choose Everything to be sure."
        }
    }
}

/// The ways to write a clean copy of one file, in the order to try them.
public struct MetadataStripPlan: Hashable, Sendable {
    public enum Method: String, Sendable {
        /// CGImageDestinationCopyImageSource into the source's type, so the image data stays as it is. Everything
        /// replaces all EXIF, IPTC and XMP with a metadata that holds only tiff:Orientation, with
        /// kCGImageMetadataShouldExcludeXMP and kCGImageMetadataShouldExcludeGPS. Location only merges
        /// (kCGImageDestinationMergeMetadata) a metadata that sets each of `locationXMPTags` to kCFNull, the names
        /// ImageIO also shows the IPTC place fields under, with kCGImageMetadataShouldExcludeGPS.
        case losslessCopy
        /// The primary image decoded and encoded again in the source's type. Everything adds it with only the
        /// orientation and the quality; Location only adds it from the source with {GPS} set to kCFNull and the
        /// `IPTCPlaceKey` fields left out of {IPTC}. Depth and portrait mattes stay out; the gain map comes back when
        /// the step `keepsGainMap`.
        case reencode
        /// Decoded, a RAW developed, and encoded as the step's `outputType` with the orientation drawn into the
        /// pixels. Location only carries the other metadata over.
        case convert
    }

    public struct Step: Hashable, Sendable {
        public var method: Method
        /// The copy's type identifier.
        public var outputType: String
        /// kCGImageDestinationLossyCompressionQuality; nil for a lossless copy and for lossless formats.
        public var quality: Double?
        /// Puts the source's HDR gain map back, so the copy keeps its look on an HDR screen.
        public var keepsGainMap: Bool
        /// False when the orientation is drawn into the pixels instead.
        public var keepsOrientationTag: Bool
        /// Only a lossless copy keeps every image of a file that holds several.
        public var keepsEveryImage: Bool
        /// What to tell the person when this step makes the copy.
        public var notes: [Note]
    }

    public enum Note: Hashable, Sendable {
        /// The source's type can't be written here; the copy is this type instead ("HEIF", "PNG" or "JPEG").
        case converted(to: String)
        /// A file with several pictures, copied without the lossless path.
        case firstImageOnly

        public var text: String {
            switch self {
            case .converted(let name): return "This format can't be saved here, so the copy is a \(name) image."
            case .firstImageOnly: return "This file holds several pictures. The copy keeps only the main one."
            }
        }
    }

    /// Type identifiers the plan names (UTCoreTypes.h).
    public enum TypeID {
        public static let jpeg = "public.jpeg"
        public static let png = "public.png"
        public static let tiff = "public.tiff"
        public static let gif = "com.compuserve.gif"
        public static let heic = "public.heic"
        public static let heif = "public.heif"
        public static let bmp = "com.microsoft.bmp"
        public static let ico = "com.microsoft.ico"
    }

    /// The quality of every lossy encode: high enough that the copy looks like the original.
    public static let quality = 0.95

    public let mode: StripMode
    public let sourceType: String
    /// Try them in order and keep the first copy with no `leftovers`. Empty when nothing here can be written; when
    /// no step passes either, the copy couldn't be cleaned.
    public let steps: [Step]

    /// `sourceType` is CGImageSourceGetType's identifier, `writableTypes` CGImageDestinationCopyTypeIdentifiers(),
    /// `isRAW` true for camera RAW and DNG, `hasAlpha` the primary image's HasAlpha and `imageCount`
    /// CGImageSourceGetCount.
    public init(sourceType: String, writableTypes: Set<String>, isRAW: Bool, hasAlpha: Bool, imageCount: Int = 1,
                mode: StripMode) {
        self.mode = mode
        self.sourceType = sourceType
        // Re-encoding RAW data as RAW makes no sense, and its DNG tags name the camera, so Everything develops it.
        let writesSource = writableTypes.contains(sourceType) && !isRAW
        var steps: [Step] = []
        switch mode {
        case .everything:
            // HEIF is re-encoded rather than copied: that also drops the embedded thumbnails and extra items, which
            // can show an earlier, uncropped picture.
            if writesSource, Self.copiesLosslessly.contains(sourceType) {
                steps.append(Self.step(.losslessCopy, sourceType, from: sourceType, imageCount: imageCount))
            }
            if writesSource {
                steps.append(Self.step(.reencode, sourceType, from: sourceType, imageCount: imageCount))
            }
        case .locationOnly:
            if writableTypes.contains(sourceType) {
                steps.append(Self.step(.losslessCopy, sourceType, from: sourceType, imageCount: imageCount))
            }
            if writesSource {
                steps.append(Self.step(.reencode, sourceType, from: sourceType, imageCount: imageCount))
            }
        }
        if let target = Self.conversionType(writableTypes: writableTypes, hasAlpha: hasAlpha), target != sourceType {
            steps.append(Self.step(.convert, target, from: sourceType, imageCount: imageCount))
        }
        self.steps = steps
    }

    // MARK: - What a copy may still hold

    /// ImageIO's property dictionaries the rules name, by their kCGImageProperty...Dictionary value.
    public enum Group: String, CaseIterable, Sendable {
        case exif = "{Exif}"
        case exifAux = "{ExifAux}"
        case tiff = "{TIFF}"
        case gps = "{GPS}"
        case iptc = "{IPTC}"
        case makerApple = "{MakerApple}"
        case makerCanon = "{MakerCanon}"
        case makerNikon = "{MakerNikon}"
        case makerMinolta = "{MakerMinolta}"
        case makerFuji = "{MakerFuji}"
        case makerOlympus = "{MakerOlympus}"
        case makerPentax = "{MakerPentax}"
        case photoshop = "{8BIM}"
        case ciff = "{CIFF}"
        case dng = "{DNG}"
        case raw = "{Raw}"
        case openEXR = "{OpenEXR}"
        case jfif = "{JFIF}"
        case png = "{PNG}"
        case gif = "{GIF}"
        case heif = "{HEIF}"
        case heics = "{HEICS}"
        case webP = "{WebP}"
        case avis = "{AVIS}"
        case tga = "{TGA}"
    }

    /// One image's metadata by name only, as ImageIO reports it: enough to check a copy and to say what went.
    public struct Inventory: Hashable, Sendable {
        /// CGImageSourceCopyPropertiesAtIndex's keys whose values aren't dictionaries ("PixelWidth", "Orientation").
        public var topLevel: Set<String>
        /// Each dictionary-valued key ("{Exif}") with its keys.
        public var groups: [String: Set<String>]
        /// The top-level tags of CGImageSourceCopyMetadataAtIndex, enumerated without the recursive option.
        public var xmp: Set<XMPTag>

        public init(topLevel: Set<String> = [], groups: [String: Set<String>] = [:], xmp: Set<XMPTag> = []) {
            self.topLevel = topLevel
            self.groups = groups
            self.xmp = xmp
        }

        public func keys(in group: Group) -> Set<String> {
            groups[group.rawValue] ?? []
        }
    }

    public struct XMPTag: Hashable, Sendable {
        /// The namespace URI. It names the schema whatever prefix a file uses.
        public var namespace: String
        public var name: String

        public init(namespace: String, name: String) {
            self.namespace = namespace
            self.name = name
        }

        /// "photoshop:City", with ImageIO's prefix for the namespace, for CGImageMetadataSetValueWithPath. nil for a
        /// namespace without a known prefix.
        public var path: String? {
            XMPNamespace.prefix(for: namespace).map { $0 + ":" + name }
        }

        var label: String { path ?? namespace + " " + name }
    }

    /// The XMP namespaces the rules name.
    public enum XMPNamespace {
        public static let exif = "http://ns.adobe.com/exif/1.0/"
        public static let exifEX = "http://cipa.jp/exif/1.0/"
        public static let exifAux = "http://ns.adobe.com/exif/1.0/aux/"
        public static let tiff = "http://ns.adobe.com/tiff/1.0/"
        public static let xmpBasic = "http://ns.adobe.com/xap/1.0/"
        public static let xmpRights = "http://ns.adobe.com/xap/1.0/rights/"
        public static let dublinCore = "http://purl.org/dc/elements/1.1/"
        public static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        public static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        public static let iptcExtension = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        /// Apple's HDR gain map fields, which describe how bright the HDR version gets.
        public static let hdrGainMap = "http://ns.apple.com/HDRGainMap/1.0/"

        /// The prefix ImageIO uses (kCGImageMetadataPrefix...), and the app's own for ShotXMP.
        public static func prefix(for namespace: String) -> String? {
            prefixes[namespace]
        }

        static let prefixes: [String: String] = [
            exif: "exif", exifEX: "exifEX", exifAux: "aux", tiff: "tiff", xmpBasic: "xmp", xmpRights: "xmpRights",
            dublinCore: "dc", photoshop: "photoshop", iptcCore: "Iptc4xmpCore", iptcExtension: "Iptc4xmpExt",
            hdrGainMap: "HDRGainMap", ShotXMP.namespace: ShotXMP.prefix,
        ]
    }

    /// IPTC fields that name the place a photo shows or was taken in, by ImageIO's key names. The app maps each case
    /// to its kCGImagePropertyIPTC constant.
    public enum IPTCPlaceKey: String, CaseIterable, Sendable {
        case city = "City"
        case subLocation = "SubLocation"
        case provinceState = "Province/State"
        case countryCode = "Country/PrimaryLocationCode"
        case countryName = "Country/PrimaryLocationName"
        case contentLocationCode = "ContentLocationCode"
        case contentLocationName = "ContentLocationName"
        case locationCreated = "LocationCreated"
        case locationShown = "LocationShown"
    }

    /// XMP place fields that Location only removes, besides exif:GPS, which kCGImageMetadataShouldExcludeGPS covers.
    public static let locationXMPTags: [XMPTag] = [
        XMPTag(namespace: XMPNamespace.photoshop, name: "City"),
        XMPTag(namespace: XMPNamespace.photoshop, name: "State"),
        XMPTag(namespace: XMPNamespace.photoshop, name: "Country"),
        XMPTag(namespace: XMPNamespace.iptcCore, name: "Location"),
        XMPTag(namespace: XMPNamespace.iptcCore, name: "CountryCode"),
        XMPTag(namespace: XMPNamespace.iptcExtension, name: "LocationCreated"),
        XMPTag(namespace: XMPNamespace.iptcExtension, name: "LocationShown"),
    ]

    /// {Exif} keys a clean copy may hold: the picture's size and color space, and the version fields ImageIO writes
    /// with them.
    public static let allowedExifKeys: Set<String> = [
        "ColorSpace", "PixelXDimension", "PixelYDimension", "ExifVersion", "FlashPixVersion",
        "ComponentsConfiguration", "Gamma", "CompressedBitsPerPixel",
    ]

    /// {TIFF} keys a clean copy may hold: orientation, resolution and how the pixels are stored.
    public static let allowedTIFFKeys: Set<String> = [
        "Orientation", "XResolution", "YResolution", "ResolutionUnit", "Compression", "PhotometricInterpretation",
        "TileWidth", "TileLength", "WhitePoint", "PrimaryChromaticities", "TransferFunction", "XPosition", "YPosition",
    ]

    /// {PNG} keys a clean copy may hold. The text chunks (Author, Comment, Copyright, Software and the like) may not.
    public static let allowedPNGKeys: Set<String> = [
        "Gamma", "InterlaceType", "XPixelsPerMeter", "YPixelsPerMeter", "sRGBIntent", "Chromaticities",
        "CompressionFilter", "PixelsAspectRatio", "Transparency", "LoopCount", "DelayTime", "UnclampedDelayTime",
        "FrameInfoArray", "CanvasPixelWidth", "CanvasPixelHeight",
    ]

    /// XMP tags a clean copy may hold: ImageIO repeats the allowed {Exif} and {TIFF} keys there, under the XMP
    /// spelling, and a HEIF that keeps its gain map may carry Apple's two gain map fields. Everything else, the app's
    /// own fields included, has to go.
    public static let allowedXMPTags: Set<XMPTag> = Set(
        ["ColorSpace", "PixelXDimension", "PixelYDimension", "ExifVersion", "FlashpixVersion", "FlashPixVersion",
         "ComponentsConfiguration", "Gamma", "CompressedBitsPerPixel"]
            .map { XMPTag(namespace: XMPNamespace.exif, name: $0) }
        + ["Orientation", "XResolution", "YResolution", "ResolutionUnit", "Compression", "PhotometricInterpretation",
           "ImageWidth", "ImageLength", "BitsPerSample", "SamplesPerPixel", "PlanarConfiguration", "YCbCrSubSampling",
           "YCbCrPositioning", "WhitePoint", "PrimaryChromaticities", "TransferFunction"]
            .map { XMPTag(namespace: XMPNamespace.tiff, name: $0) }
        + ["HDRGainMapVersion", "HDRGainMapHeadroom"].map { XMPTag(namespace: XMPNamespace.hdrGainMap, name: $0) })

    /// Groups that only describe how the pixels are stored, so any of their keys may stay.
    static let structuralGroups: Set<String> = Set([Group.jfif, .gif, .heif, .heics, .webP, .avis, .tga]
        .map(\.rawValue))

    /// What keeps `copy` from counting as clean for `mode`, as short labels ("{GPS}", "{Exif} DateTimeOriginal",
    /// "XMP openshutter:Mode"), sorted; empty when it passes. Everything accepts only the allow lists and the
    /// structural groups, so a group nobody listed fails too. Location only looks for the place fields alone.
    public static func leftovers(in copy: Inventory, mode: StripMode) -> [String] {
        var found: [String] = []
        switch mode {
        case .everything:
            for name in copy.groups.keys.sorted() {
                guard let keys = copy.groups[name], !keys.isEmpty else { continue }
                if let allowed = allowedKeys(group: name) {
                    found += keys.subtracting(allowed).sorted().map { name + " " + $0 }
                } else if !structuralGroups.contains(name) {
                    found.append(name)
                }
            }
            found += sorted(copy.xmp.subtracting(allowedXMPTags)).map { "XMP " + $0.label }
        case .locationOnly:
            if !copy.keys(in: .gps).isEmpty { found.append(Group.gps.rawValue) }
            let places = Set(IPTCPlaceKey.allCases.map(\.rawValue))
            found += copy.keys(in: .iptc).intersection(places).sorted().map { Group.iptc.rawValue + " " + $0 }
            found += sorted(copy.xmp.filter(isLocation)).map { "XMP " + $0.label }
        }
        return found
    }

    // MARK: - What was removed

    /// The kinds of metadata the result sentence names, in its order.
    public enum Category: String, CaseIterable, Sendable {
        case location, cameraAndLens, dateAndTime, settings, authorship, appleCameraData, extraTags

        public var label: String {
            switch self {
            case .location: return "location"
            case .cameraAndLens: return "camera and lens"
            case .dateAndTime: return "date and time"
            case .settings: return "settings"
            case .authorship: return "name and copyright"
            case .appleCameraData: return "Apple camera data"
            case .extraTags: return "extra tags"
            }
        }
    }

    public enum Kept: Hashable, Sendable {
        case picture, size, colorProfile, orientation
        case category(Category)

        public var label: String {
            switch self {
            case .picture: return "the picture"
            case .size: return "its size"
            case .colorProfile: return "color profile"
            case .orientation: return "orientation"
            case .category(let category): return category.label
            }
        }
    }

    public struct Summary: Hashable, Sendable {
        public var removed: [Category]
        public var kept: [Kept]
        /// "The copy is ready. Removed: location, camera and lens, date and time, settings, Apple camera data, extra
        /// tags. Kept: the picture, its size, color profile and orientation."
        public var text: String
    }

    /// The kinds of metadata an image holds. Structural fields (size, color space, orientation, how the pixels are
    /// stored) belong to none.
    public static func categories(in inventory: Inventory) -> Set<Category> {
        var found = Set<Category>()
        for (group, keys) in inventory.groups {
            for key in keys {
                if let category = category(group: group, key: key) { found.insert(category) }
            }
        }
        for tag in inventory.xmp {
            if let category = category(xmp: tag) { found.insert(category) }
        }
        return found
    }

    /// The result sentence, from the source before and the copy after.
    public static func summary(before: Inventory, after: Inventory) -> Summary {
        let had = categories(in: before)
        let has = categories(in: after)
        let removed = Category.allCases.filter { had.contains($0) && !has.contains($0) }
        var kept: [Kept] = [.picture, .size]
        if after.topLevel.contains("ProfileName") || after.keys(in: .exif).contains("ColorSpace") {
            kept.append(.colorProfile)
        }
        if after.topLevel.contains("Orientation") || after.keys(in: .tiff).contains("Orientation") {
            kept.append(.orientation)
        }
        kept += Category.allCases.filter { has.contains($0) }.map { Kept.category($0) }
        let text: String
        if removed.isEmpty {
            text = "The copy is ready. There was nothing to remove."
        } else {
            // The removed labels have "and" inside them, so only the kept list ends with one.
            text = "The copy is ready. Removed: " + removed.map(\.label).joined(separator: ", ")
                + ". Kept: " + listed(kept.map(\.label)) + "."
        }
        return Summary(removed: removed, kept: kept, text: text)
    }

    // MARK: - The copy's name

    /// "IMG_0001 no metadata.HEIC": the original's name and " no metadata", with the original's extension while the
    /// copy keeps the source's type, and `fileExtension` (the copy type's preferred one) otherwise or when there was
    /// none. At most 255 bytes, the longest name the file system takes.
    public static func outputName(original: String, sourceType: String, outputType: String,
                                  fileExtension: String) -> String {
        var base = original.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var originalExtension: String?
        if let dot = base.lastIndex(of: "."), dot != base.startIndex {
            let candidate = String(base[base.index(after: dot)...])
            if looksLikeExtension(candidate) {
                originalExtension = candidate
                base = String(base[..<dot])
            }
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file, and a trailing one would sit before " no metadata".
        while base.hasPrefix(".") { base.removeFirst() }
        while base.hasSuffix(".") { base.removeLast() }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Photo" }
        let ext = (sourceType == outputType ? originalExtension : nil) ?? fileExtension
        let tail = " no metadata" + (ext.isEmpty ? "" : "." + ext)
        while base.utf8.count + tail.utf8.count > 255, base.count > 1 { base.removeLast() }
        return base + tail
    }

    // MARK: - Helpers

    /// Written losslessly first under Everything; other types are re-encoded.
    static let copiesLosslessly: Set<String> = [TypeID.jpeg, TypeID.png, TypeID.tiff, TypeID.gif]
    /// Formats without a lossy quality.
    static let losslessFormats: Set<String> = [TypeID.png, TypeID.tiff, TypeID.gif, TypeID.bmp, TypeID.ico]
    /// Formats ImageIO writes an HDR gain map into.
    static let gainMapFormats: Set<String> = [TypeID.heic, TypeID.heif, TypeID.jpeg]
    static let heifFamily: Set<String> = [TypeID.heic, TypeID.heif]

    // HEIF keeps the picture's look in the least space; PNG is the one choice that keeps transparency everywhere.
    static func conversionType(writableTypes: Set<String>, hasAlpha: Bool) -> String? {
        let order = hasAlpha ? [TypeID.png, TypeID.heic] : [TypeID.heic, TypeID.jpeg, TypeID.png]
        return order.first { writableTypes.contains($0) }
    }

    private static func step(_ method: Method, _ outputType: String, from sourceType: String, imageCount: Int) -> Step {
        let lossless = method == .losslessCopy
        var notes: [Note] = []
        // HEIF written as HEIC is still HEIF to the person, so it needs no explanation.
        if method == .convert, !(heifFamily.contains(sourceType) && heifFamily.contains(outputType)) {
            notes.append(.converted(to: typeName(outputType)))
        }
        if !lossless, imageCount > 1 { notes.append(.firstImageOnly) }
        return Step(method: method, outputType: outputType,
                    quality: lossless || losslessFormats.contains(outputType) ? nil : quality,
                    keepsGainMap: lossless || gainMapFormats.contains(outputType),
                    keepsOrientationTag: method != .convert,
                    keepsEveryImage: lossless,
                    notes: notes)
    }

    private static func typeName(_ type: String) -> String {
        switch type {
        case TypeID.png: return "PNG"
        case TypeID.jpeg: return "JPEG"
        default: return "HEIF"
        }
    }

    private static func allowedKeys(group: String) -> Set<String>? {
        switch group {
        case Group.exif.rawValue: return allowedExifKeys
        case Group.tiff.rawValue: return allowedTIFFKeys
        case Group.png.rawValue: return allowedPNGKeys
        default: return nil
        }
    }

    private static func isLocation(_ tag: XMPTag) -> Bool {
        (tag.namespace == XMPNamespace.exif && tag.name.hasPrefix("GPS")) || locationXMPTags.contains(tag)
    }

    private static func sorted(_ tags: Set<XMPTag>) -> [XMPTag] {
        tags.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    // "a, b and c"
    private static func listed(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // Up to five ASCII letters and digits starting with a letter: "HEIC", "jpeg", "cr3", but not the "12" of
    // "Screenshot at 10.41.12".
    private static func looksLikeExtension(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...5).contains(scalars.count), isASCIILetter(scalars[0]) else { return false }
        return scalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static let exifDateKeys: Set<String> = [
        "DateTimeOriginal", "DateTimeDigitized", "SubsecTime", "SubsecTimeOriginal", "SubsecTimeDigitized",
        "OffsetTime", "OffsetTimeOriginal", "OffsetTimeDigitized",
    ]
    private static let exifCameraKeys: Set<String> = [
        "LensMake", "LensModel", "LensSpecification", "LensSerialNumber", "BodySerialNumber",
    ]
    private static let exifExtraKeys: Set<String> = ["UserComment", "MakerNote", "ImageUniqueID", "RelatedSoundFile"]
    private static let tiffCameraKeys: Set<String> = ["Make", "Model", "Software", "HostComputer"]
    private static let tiffAuthorKeys: Set<String> = ["Artist", "Copyright"]
    private static let iptcDateKeys: Set<String> = [
        "DateCreated", "TimeCreated", "DigitalCreationDate", "DigitalCreationTime", "ReleaseDate", "ReleaseTime",
        "ExpirationDate", "ExpirationTime", "ReferenceDate",
    ]
    private static let iptcAuthorKeys: Set<String> = [
        "By-line", "By-lineTitle", "CopyrightNotice", "Credit", "Source", "Writer/Editor", "Contact",
        "CreatorContactInfo", "RightsUsageTerms",
    ]

    private static func category(group: String, key: String) -> Category? {
        guard let known = Group(rawValue: group) else {
            return group.hasPrefix("{Maker") ? .cameraAndLens : .extraTags
        }
        switch known {
        case .exif:
            if allowedExifKeys.contains(key) { return nil }
            if exifDateKeys.contains(key) { return .dateAndTime }
            if exifCameraKeys.contains(key) { return .cameraAndLens }
            if key == "CameraOwnerName" { return .authorship }
            if exifExtraKeys.contains(key) { return .extraTags }
            return .settings
        case .tiff:
            if allowedTIFFKeys.contains(key) { return nil }
            if tiffCameraKeys.contains(key) { return .cameraAndLens }
            if key == "DateTime" { return .dateAndTime }
            if tiffAuthorKeys.contains(key) { return .authorship }
            return .extraTags
        case .gps:
            return .location
        case .iptc:
            if IPTCPlaceKey(rawValue: key) != nil { return .location }
            if iptcDateKeys.contains(key) { return .dateAndTime }
            if iptcAuthorKeys.contains(key) { return .authorship }
            return .extraTags
        case .png:
            if allowedPNGKeys.contains(key) { return nil }
            if key == "CreationTime" || key == "ModificationTime" { return .dateAndTime }
            if key == "Author" || key == "Copyright" { return .authorship }
            if key == "Software" { return .cameraAndLens }
            return .extraTags
        case .makerApple:
            return .appleCameraData
        case .exifAux, .makerCanon, .makerNikon, .makerMinolta, .makerFuji, .makerOlympus, .makerPentax, .ciff, .dng,
             .raw:
            return .cameraAndLens
        case .photoshop, .openEXR:
            return .extraTags
        case .jfif, .gif, .heif, .heics, .webP, .avis, .tga:
            return nil
        }
    }

    private static func category(xmp tag: XMPTag) -> Category? {
        if isLocation(tag) { return .location }
        if allowedXMPTags.contains(tag) { return nil }
        let name = tag.name
        switch tag.namespace {
        case XMPNamespace.exif:
            if exifDateKeys.contains(name) { return .dateAndTime }
            if exifExtraKeys.contains(name) { return .extraTags }
            return .settings
        case XMPNamespace.exifEX:
            if exifCameraKeys.contains(name) { return .cameraAndLens }
            if name == "CameraOwnerName" { return .authorship }
            if exifDateKeys.contains(name) { return .dateAndTime }
            return .settings
        case XMPNamespace.exifAux:
            return .cameraAndLens
        case XMPNamespace.tiff:
            if tiffCameraKeys.contains(name) { return .cameraAndLens }
            if name == "DateTime" { return .dateAndTime }
            if tiffAuthorKeys.contains(name) { return .authorship }
            return .extraTags
        case XMPNamespace.xmpBasic:
            if ["CreateDate", "ModifyDate", "MetadataDate"].contains(name) { return .dateAndTime }
            if name == "CreatorTool" { return .cameraAndLens }
            return .extraTags
        case XMPNamespace.dublinCore:
            return name == "creator" || name == "rights" ? .authorship : .extraTags
        case XMPNamespace.xmpRights:
            return .authorship
        case XMPNamespace.photoshop:
            if name == "DateCreated" { return .dateAndTime }
            if ["Credit", "AuthorsPosition", "CaptionWriter", "Source"].contains(name) { return .authorship }
            return .extraTags
        case XMPNamespace.iptcCore:
            return name == "CreatorContactInfo" ? .authorship : .extraTags
        case ShotXMP.namespace:
            // How the shot was taken: mode, lens, stack, stability.
            return .settings
        default:
            return .extraTags
        }
    }
}
