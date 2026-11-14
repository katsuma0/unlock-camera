import Foundation
import XCTest
@testable import CameraCore

final class MetadataStripPlanTests: XCTestCase {
    private typealias Plan = MetadataStripPlan
    private typealias Tag = MetadataStripPlan.XMPTag
    private typealias NS = MetadataStripPlan.XMPNamespace

    private let dng = "com.adobe.raw-image"
    private let webP = "org.webmproject.webp"
    /// Roughly what CGImageDestinationCopyTypeIdentifiers lists on a phone.
    private let writable: Set<String> = ["public.jpeg", "public.png", "public.tiff", "com.compuserve.gif",
                                         "public.heic", "public.heics", "com.microsoft.bmp", "com.microsoft.ico",
                                         "com.adobe.raw-image"]

    private func plan(_ type: String, writable: Set<String>? = nil, raw: Bool = false, alpha: Bool = false,
                      images: Int = 1, _ mode: StripMode) -> Plan {
        Plan(sourceType: type, writableTypes: writable ?? self.writable, isRAW: raw, hasAlpha: alpha,
             imageCount: images, mode: mode)
    }

    private func exif(_ name: String) -> Tag { Tag(namespace: NS.exif, name: name) }
    private func tiff(_ name: String) -> Tag { Tag(namespace: NS.tiff, name: name) }

    /// What ImageIO reports for a JPEG after a clean lossless copy: the picture's own facts only.
    private let cleanJPEG = MetadataStripPlan.Inventory(
        topLevel: ["ColorModel", "Depth", "DPIHeight", "DPIWidth", "Orientation", "PixelHeight", "PixelWidth",
                   "ProfileName"],
        groups: ["{Exif}": ["ColorSpace", "PixelXDimension", "PixelYDimension"],
                 "{TIFF}": ["Orientation", "ResolutionUnit", "XResolution", "YResolution"],
                 "{JFIF}": ["DensityUnit", "IsProgressive", "JFIFVersion", "XDensity", "YDensity"]],
        xmp: [Tag(namespace: MetadataStripPlan.XMPNamespace.tiff, name: "Orientation"),
              Tag(namespace: MetadataStripPlan.XMPNamespace.tiff, name: "XResolution"),
              Tag(namespace: MetadataStripPlan.XMPNamespace.tiff, name: "YResolution"),
              Tag(namespace: MetadataStripPlan.XMPNamespace.tiff, name: "ResolutionUnit"),
              Tag(namespace: MetadataStripPlan.XMPNamespace.exif, name: "PixelXDimension"),
              Tag(namespace: MetadataStripPlan.XMPNamespace.exif, name: "PixelYDimension"),
              Tag(namespace: MetadataStripPlan.XMPNamespace.exif, name: "ColorSpace")])

    /// A photo as the iPhone saves it, with location on and the app's own fields.
    private var iPhonePhoto: MetadataStripPlan.Inventory {
        MetadataStripPlan.Inventory(
            topLevel: ["ColorModel", "Depth", "Orientation", "PixelHeight", "PixelWidth", "ProfileName"],
            groups: ["{Exif}": ["ExposureTime", "FNumber", "ISOSpeedRatings", "DateTimeOriginal", "OffsetTimeOriginal",
                                "LensModel", "LensMake", "PixelXDimension", "PixelYDimension", "ColorSpace", "Flash"],
                     "{TIFF}": ["Make", "Model", "Software", "DateTime", "Orientation", "XResolution"],
                     "{GPS}": ["Latitude", "LatitudeRef", "Longitude", "LongitudeRef", "Altitude"],
                     "{MakerApple}": ["1", "14", "33"]],
            xmp: [Tag(namespace: NS.xmpBasic, name: "CreateDate"), Tag(namespace: NS.photoshop, name: "DateCreated"),
                  Tag(namespace: ShotXMP.namespace, name: "Mode"), Tag(namespace: NS.xmpBasic, name: "Rating"),
                  exif("GPSLatitude"), exif("ExposureTime"), tiff("Make"), tiff("Orientation")])
    }

    private func adding(_ base: MetadataStripPlan.Inventory, groups: [String: Set<String>] = [:],
                        xmp: Set<Tag> = []) -> MetadataStripPlan.Inventory {
        var result = base
        for (name, keys) in groups { result.groups[name, default: []].formUnion(keys) }
        result.xmp.formUnion(xmp)
        return result
    }

    // MARK: - Modes

    func testModes() {
        XCTAssertEqual(StripMode.allCases, [.everything, .locationOnly])
        XCTAssertEqual(StripMode.default, .everything)
        XCTAssertEqual(StripMode.everything.title, "Everything")
        XCTAssertEqual(StripMode.locationOnly.title, "Location only")
        XCTAssertNil(StripMode.everything.note)
        XCTAssertEqual(StripMode.locationOnly.note,
                       "Some cameras also keep place details in their own notes. Choose Everything to be sure.")
    }

    // MARK: - Decision table

    func testJPEGEverythingIsLossless() {
        let steps = plan("public.jpeg", .everything).steps
        XCTAssertEqual(steps.map(\.method), [.losslessCopy, .reencode, .convert])
        let copy = steps[0]
        XCTAssertEqual(copy.outputType, "public.jpeg")
        XCTAssertNil(copy.quality)
        XCTAssertTrue(copy.keepsEveryImage)
        XCTAssertTrue(copy.keepsOrientationTag)
        XCTAssertTrue(copy.notes.isEmpty)
        XCTAssertEqual(steps[1].outputType, "public.jpeg")
        XCTAssertEqual(steps[1].quality, 0.95)
        XCTAssertTrue(steps[1].keepsGainMap)
        XCTAssertFalse(steps[1].keepsEveryImage)
        // The last resort makes a HEIF and says so.
        XCTAssertEqual(steps[2].outputType, "public.heic")
        XCTAssertFalse(steps[2].keepsOrientationTag)
        XCTAssertEqual(steps[2].notes, [.converted(to: "HEIF")])
        for type in ["public.png", "public.tiff", "com.compuserve.gif"] {
            XCTAssertEqual(plan(type, .everything).steps.first?.method, .losslessCopy, type)
            XCTAssertNil(plan(type, .everything).steps[1].quality, type)
        }
    }

    func testHEICEverythingReencodes() {
        let steps = plan("public.heic", .everything).steps
        XCTAssertEqual(steps.map(\.method), [.reencode])
        XCTAssertEqual(steps[0].outputType, "public.heic")
        XCTAssertEqual(steps[0].quality, MetadataStripPlan.quality)
        XCTAssertEqual(MetadataStripPlan.quality, 0.95)
        XCTAssertTrue(steps[0].keepsGainMap)
        XCTAssertTrue(steps[0].keepsOrientationTag)
        XCTAssertTrue(steps[0].notes.isEmpty)
        XCTAssertEqual(plan("public.heic", images: 4, .everything).steps[0].notes, [.firstImageOnly])
    }

    func testHEICLocationOnlyIsLossless() {
        let steps = plan("public.heic", images: 4, .locationOnly).steps
        XCTAssertEqual(steps.map(\.method), [.losslessCopy, .reencode])
        XCTAssertEqual(steps[0].outputType, "public.heic")
        XCTAssertNil(steps[0].quality)
        XCTAssertTrue(steps[0].keepsEveryImage)
        XCTAssertTrue(steps[0].keepsGainMap)
        XCTAssertTrue(steps[0].notes.isEmpty)
        XCTAssertEqual(steps[1].quality, 0.95)
        XCTAssertEqual(steps[1].notes, [.firstImageOnly])
        XCTAssertEqual(plan("public.jpeg", .locationOnly).steps.map(\.method), [.losslessCopy, .reencode, .convert])
    }

    func testTypesThatCantBeWrittenConvert() {
        let opaque = plan(webP, .everything).steps
        XCTAssertEqual(opaque.map(\.method), [.convert])
        XCTAssertEqual(opaque[0].outputType, "public.heic")
        XCTAssertEqual(opaque[0].quality, 0.95)
        XCTAssertEqual(opaque[0].notes.map(\.text), ["This format can't be saved here, so the copy is a HEIF image."])

        let transparent = plan(webP, alpha: true, .everything).steps
        XCTAssertEqual(transparent.map(\.outputType), ["public.png"])
        XCTAssertNil(transparent[0].quality)
        XCTAssertFalse(transparent[0].keepsGainMap)
        XCTAssertEqual(transparent[0].notes.map(\.text),
                       ["This format can't be saved here, so the copy is a PNG image."])

        let noHEIF = plan(webP, writable: ["public.jpeg", "public.png"], .everything).steps
        XCTAssertEqual(noHEIF.map(\.outputType), ["public.jpeg"])
        XCTAssertEqual(noHEIF[0].notes, [.converted(to: "JPEG")])
        XCTAssertEqual(plan(webP, writable: ["public.heic"], alpha: true, .everything).steps.map(\.outputType),
                       ["public.heic"])
        XCTAssertTrue(plan(webP, writable: [], .everything).steps.isEmpty)
        XCTAssertEqual(plan(webP, .locationOnly).steps.map(\.method), [.convert])
        XCTAssertEqual(plan(webP, images: 2, .everything).steps[0].notes, [.converted(to: "HEIF"), .firstImageOnly])
    }

    func testRAWIsDevelopedUnlessOnlyThePlaceGoes() {
        let everything = plan(dng, raw: true, .everything).steps
        XCTAssertEqual(everything.map(\.method), [.convert])
        XCTAssertEqual(everything[0].outputType, "public.heic")
        XCTAssertEqual(everything[0].notes, [.converted(to: "HEIF")])

        // Location only keeps the RAW data when the type can be written, and never re-encodes it.
        let location = plan(dng, raw: true, .locationOnly).steps
        XCTAssertEqual(location.map(\.method), [.losslessCopy, .convert])
        XCTAssertEqual(location[0].outputType, dng)

        let canon = plan("com.canon.cr3-raw-image", raw: true, .locationOnly).steps
        XCTAssertEqual(canon.map(\.method), [.convert])
    }

    func testHEIFFamilyConversionsNeedNoNote() {
        let steps = plan("public.heif", .everything).steps
        XCTAssertEqual(steps.map(\.method), [.convert])
        XCTAssertEqual(steps[0].outputType, "public.heic")
        XCTAssertTrue(steps[0].notes.isEmpty)
    }

    func testNoStepConvertsToTheSourceType() {
        XCTAssertEqual(plan("public.png", alpha: true, .everything).steps.map(\.method), [.losslessCopy, .reencode])
        let gif = plan("com.compuserve.gif", alpha: true, images: 12, .everything).steps
        XCTAssertEqual(gif.map(\.method), [.losslessCopy, .reencode, .convert])
        XCTAssertEqual(gif.map(\.outputType), ["com.compuserve.gif", "com.compuserve.gif", "public.png"])
        XCTAssertEqual(gif.map(\.notes), [[], [.firstImageOnly], [.converted(to: "PNG"), .firstImageOnly]])
        XCTAssertEqual(gif.map(\.keepsEveryImage), [true, false, false])
    }

    // MARK: - Names

    func testOutputNamesKeepOrChangeTheExtension() {
        func name(_ original: String, _ source: String, _ output: String, _ ext: String) -> String {
            MetadataStripPlan.outputName(original: original, sourceType: source, outputType: output, fileExtension: ext)
        }
        XCTAssertEqual(name("IMG_0001.HEIC", "public.heic", "public.heic", "heic"), "IMG_0001 no metadata.HEIC")
        XCTAssertEqual(name("IMG_0001.DNG", dng, "public.heic", "heic"), "IMG_0001 no metadata.heic")
        XCTAssertEqual(name("Beach day.jpeg", "public.jpeg", "public.jpeg", "jpg"), "Beach day no metadata.jpeg")
        XCTAssertEqual(name("/private/var/tmp/PhotoInfo/A1/IMG_2.PNG", "public.png", "public.png", "png"),
                       "IMG_2 no metadata.PNG")
        XCTAssertEqual(name("photo", "public.jpeg", "public.jpeg", "jpg"), "photo no metadata.jpg")
        XCTAssertEqual(name("Screenshot 2026-11-13 at 10.41.12", "public.png", "public.png", "png"),
                       "Screenshot 2026-11-13 at 10.41.12 no metadata.png")
        XCTAssertEqual(name("", "public.heic", "public.heic", "heic"), "Photo no metadata.heic")
        XCTAssertEqual(name(".jpg", "public.jpeg", "public.jpeg", "jpg"), "jpg no metadata.jpg")
        XCTAssertEqual(name("photo.", "public.jpeg", "public.jpeg", "jpg"), "photo no metadata.jpg")
        XCTAssertEqual(name("  holiday .webp", webP, "public.heic", "heic"), "holiday no metadata.heic")
        XCTAssertEqual(name("scan", "public.tiff", "public.tiff", ""), "scan no metadata")

        let long = name(String(repeating: "\u{00E9}", count: 200) + ".jpg", "public.jpeg", "public.jpeg", "jpg")
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertGreaterThan(long.utf8.count, 250)
        XCTAssertTrue(long.hasPrefix("\u{00E9}"))
        XCTAssertTrue(long.hasSuffix(" no metadata.jpg"))
    }

    // MARK: - Checking a copy

    func testACleanImageIOOutputPasses() {
        XCTAssertEqual(MetadataStripPlan.leftovers(in: cleanJPEG, mode: .everything), [])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: cleanJPEG, mode: .locationOnly), [])

        let cleanPNG = MetadataStripPlan.Inventory(
            topLevel: ["PixelWidth", "PixelHeight", "HasAlpha", "Depth", "ColorModel"],
            groups: ["{PNG}": ["Gamma", "sRGBIntent", "XPixelsPerMeter", "YPixelsPerMeter", "InterlaceType"],
                     "{Exif}": ["PixelXDimension", "PixelYDimension"]])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: cleanPNG, mode: .everything), [])

        let cleanHEIC = MetadataStripPlan.Inventory(
            topLevel: ["PixelWidth", "PixelHeight", "Orientation", "ProfileName", "Depth", "PrimaryImage"],
            groups: ["{TIFF}": ["Orientation"], "{HEIF}": ["CanvasPixelWidth"], "{GPS}": [], "{IPTC}": []],
            xmp: [tiff("Orientation"), exif("FlashpixVersion"),
                  Tag(namespace: NS.hdrGainMap, name: "HDRGainMapVersion"),
                  Tag(namespace: NS.hdrGainMap, name: "HDRGainMapHeadroom")])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: cleanHEIC, mode: .everything), [])
        XCTAssertEqual(MetadataStripPlan.categories(in: cleanHEIC), [])
        // Only those two gain map fields pass.
        let otherAppleField = adding(cleanHEIC, xmp: [Tag(namespace: NS.hdrGainMap, name: "Owner")])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: otherAppleField, mode: .everything), ["XMP HDRGainMap:Owner"])
    }

    func testACopyWithGPSFails() {
        let located = adding(cleanJPEG, groups: ["{GPS}": ["Latitude", "Longitude"]])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: located, mode: .everything), ["{GPS}"])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: located, mode: .locationOnly), ["{GPS}"])
        let inXMP = adding(cleanJPEG, xmp: [exif("GPSLatitude")])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: inXMP, mode: .everything), ["XMP exif:GPSLatitude"])
        XCTAssertEqual(MetadataStripPlan.leftovers(in: inXMP, mode: .locationOnly), ["XMP exif:GPSLatitude"])
    }

    func testEverythingRejectsEveryOtherKindOfMetadata() {
        let cases: [(MetadataStripPlan.Inventory, [String])] = [
            (adding(cleanJPEG, groups: ["{MakerApple}": ["14"]]), ["{MakerApple}"]),
            (adding(cleanJPEG, groups: ["{ExifAux}": ["SerialNumber"]]), ["{ExifAux}"]),
            (adding(cleanJPEG, groups: ["{IPTC}": ["Keywords"]]), ["{IPTC}"]),
            (adding(cleanJPEG, groups: ["{MakerNikon}": ["1"]]), ["{MakerNikon}"]),
            (adding(cleanJPEG, groups: ["{MakerLeica}": ["1"]]), ["{MakerLeica}"]),
            (adding(cleanJPEG, groups: ["{8BIM}": ["Layers"]]), ["{8BIM}"]),
            (adding(cleanJPEG, groups: ["{DNG}": ["UniqueCameraModel"]]), ["{DNG}"]),
            (adding(cleanJPEG, groups: ["{Raw}": ["1"]]), ["{Raw}"]),
            (adding(cleanJPEG, groups: ["{OpenEXR}": ["owner"]]), ["{OpenEXR}"]),
            (adding(cleanJPEG, groups: ["{SomethingNew}": ["Field"]]), ["{SomethingNew}"]),
            (adding(cleanJPEG, groups: ["{Exif}": ["DateTimeOriginal", "BodySerialNumber"]]),
             ["{Exif} BodySerialNumber", "{Exif} DateTimeOriginal"]),
            (adding(cleanJPEG, groups: ["{TIFF}": ["Make", "Artist"]]), ["{TIFF} Artist", "{TIFF} Make"]),
            (adding(cleanJPEG, groups: ["{PNG}": ["Gamma", "Author", "Comment"]]), ["{PNG} Author", "{PNG} Comment"]),
            (adding(cleanJPEG, xmp: [Tag(namespace: NS.dublinCore, name: "creator")]), ["XMP dc:creator"]),
            (adding(cleanJPEG, xmp: [Tag(namespace: "http://example.com/ns/", name: "Owner")]),
             ["XMP http://example.com/ns/ Owner"]),
            (adding(cleanJPEG, xmp: [exif("ExposureTime")]), ["XMP exif:ExposureTime"]),
        ]
        for (inventory, expected) in cases {
            XCTAssertEqual(MetadataStripPlan.leftovers(in: inventory, mode: .everything), expected)
        }
    }

    func testEverythingRemovesTheAppsOwnFields() {
        let tags = Set(ShotXMP.Field.allCases.map { Tag(namespace: ShotXMP.namespace, name: $0.rawValue) })
        let withAppFields = adding(cleanJPEG, xmp: tags)
        let found = MetadataStripPlan.leftovers(in: withAppFields, mode: .everything)
        XCTAssertEqual(found.count, ShotXMP.Field.allCases.count)
        XCTAssertTrue(found.contains("XMP openshutter:Mode"))
        XCTAssertTrue(found.contains("XMP openshutter:LightSeconds"))
        // They hold no place, so Location only keeps them.
        XCTAssertEqual(MetadataStripPlan.leftovers(in: withAppFields, mode: .locationOnly), [])
    }

    func testLocationOnlyLooksForThePlaceAlone() {
        let detailed = adding(iPhonePhoto, groups: ["{GPS}": []])
        var withoutGPS = detailed
        withoutGPS.groups["{GPS}"] = nil
        withoutGPS.xmp.remove(exif("GPSLatitude"))
        XCTAssertEqual(MetadataStripPlan.leftovers(in: withoutGPS, mode: .locationOnly), [])
        XCTAssertFalse(MetadataStripPlan.leftovers(in: withoutGPS, mode: .everything).isEmpty)

        let places = adding(withoutGPS, groups: ["{IPTC}": ["City", "Province/State", "Keywords", "By-line"]],
                            xmp: [Tag(namespace: NS.photoshop, name: "City"),
                                  Tag(namespace: NS.iptcExtension, name: "LocationShown"),
                                  Tag(namespace: NS.photoshop, name: "Headline")])
        // Groups by name, then XMP tags by namespace URI.
        XCTAssertEqual(MetadataStripPlan.leftovers(in: places, mode: .locationOnly),
                       ["{IPTC} City", "{IPTC} Province/State", "XMP Iptc4xmpExt:LocationShown", "XMP photoshop:City"])
    }

    func testPlaceNamesAndPaths() {
        XCTAssertEqual(MetadataStripPlan.IPTCPlaceKey.allCases.map(\.rawValue),
                       ["City", "SubLocation", "Province/State", "Country/PrimaryLocationCode",
                        "Country/PrimaryLocationName", "ContentLocationCode", "ContentLocationName", "LocationCreated",
                        "LocationShown"])
        XCTAssertEqual(MetadataStripPlan.locationXMPTags.compactMap(\.path),
                       ["photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location",
                        "Iptc4xmpCore:CountryCode", "Iptc4xmpExt:LocationCreated", "Iptc4xmpExt:LocationShown"])
        XCTAssertEqual(Tag(namespace: ShotXMP.namespace, name: "Mode").path, "openshutter:Mode")
        XCTAssertEqual(exif("ColorSpace").path, "exif:ColorSpace")
        XCTAssertNil(Tag(namespace: "http://example.com/ns/", name: "Owner").path)
        XCTAssertEqual(MetadataStripPlan.Group.gps.rawValue, "{GPS}")
        XCTAssertEqual(MetadataStripPlan.Group.photoshop.rawValue, "{8BIM}")
    }

    // MARK: - What was removed

    func testCategories() {
        func categories(_ groups: [String: Set<String>] = [:], xmp: Set<Tag> = []) -> Set<MetadataStripPlan.Category> {
            MetadataStripPlan.categories(in: MetadataStripPlan.Inventory(groups: groups, xmp: xmp))
        }
        XCTAssertEqual(MetadataStripPlan.categories(in: cleanJPEG), [])
        XCTAssertEqual(categories(["{Exif}": ["ExposureTime", "ISOSpeedRatings"]]), [.settings])
        XCTAssertEqual(categories(["{Exif}": ["SubsecTimeOriginal"]]), [.dateAndTime])
        XCTAssertEqual(categories(["{Exif}": ["LensModel"]]), [.cameraAndLens])
        XCTAssertEqual(categories(["{Exif}": ["CameraOwnerName"]]), [.authorship])
        XCTAssertEqual(categories(["{Exif}": ["UserComment"]]), [.extraTags])
        XCTAssertEqual(categories(["{TIFF}": ["Artist", "Copyright"]]), [.authorship])
        XCTAssertEqual(categories(["{TIFF}": ["Model"]]), [.cameraAndLens])
        XCTAssertEqual(categories(["{TIFF}": ["DateTime"]]), [.dateAndTime])
        XCTAssertEqual(categories(["{TIFF}": ["ImageDescription"]]), [.extraTags])
        XCTAssertEqual(categories(["{GPS}": ["Speed"]]), [.location])
        XCTAssertEqual(categories(["{GPS}": []]), [])
        XCTAssertEqual(categories(["{IPTC}": ["Province/State"]]), [.location])
        XCTAssertEqual(categories(["{IPTC}": ["DateCreated"]]), [.dateAndTime])
        XCTAssertEqual(categories(["{IPTC}": ["CopyrightNotice"]]), [.authorship])
        XCTAssertEqual(categories(["{IPTC}": ["Keywords"]]), [.extraTags])
        XCTAssertEqual(categories(["{PNG}": ["Author"]]), [.authorship])
        XCTAssertEqual(categories(["{PNG}": ["CreationTime"]]), [.dateAndTime])
        XCTAssertEqual(categories(["{PNG}": ["Comment", "Gamma"]]), [.extraTags])
        XCTAssertEqual(categories(["{MakerApple}": ["14"]]), [.appleCameraData])
        XCTAssertEqual(categories(["{MakerLeica}": ["1"], "{ExifAux}": ["LensInfo"]]), [.cameraAndLens])
        XCTAssertEqual(categories(["{SomethingNew}": ["Field"], "{8BIM}": ["Layers"]]), [.extraTags])
        XCTAssertEqual(categories(["{JFIF}": ["XDensity"], "{HEIF}": ["CanvasPixelWidth"]]), [])
        XCTAssertEqual(categories(xmp: [Tag(namespace: ShotXMP.namespace, name: "Blend")]), [.settings])
        XCTAssertEqual(categories(xmp: [Tag(namespace: NS.exifEX, name: "LensModel")]), [.cameraAndLens])
        XCTAssertEqual(categories(xmp: [Tag(namespace: NS.dublinCore, name: "rights")]), [.authorship])
        XCTAssertEqual(categories(xmp: [Tag(namespace: NS.dublinCore, name: "title")]), [.extraTags])
        XCTAssertEqual(categories(xmp: [Tag(namespace: NS.xmpBasic, name: "ModifyDate")]), [.dateAndTime])
        XCTAssertEqual(categories(xmp: [Tag(namespace: NS.iptcCore, name: "CountryCode")]), [.location])
        XCTAssertEqual(categories(xmp: [exif("GPSAltitude")]), [.location])
        XCTAssertEqual(categories(xmp: [exif("PixelXDimension"), tiff("Orientation")]), [])
    }

    func testSummaryAfterEverything() {
        let summary = MetadataStripPlan.summary(before: iPhonePhoto, after: cleanJPEG)
        XCTAssertEqual(summary.removed,
                       [.location, .cameraAndLens, .dateAndTime, .settings, .appleCameraData, .extraTags])
        XCTAssertEqual(summary.kept, [.picture, .size, .colorProfile, .orientation])
        XCTAssertEqual(summary.text, "The copy is ready. Removed: location, camera and lens, date and time, settings, "
                       + "Apple camera data, extra tags. Kept: the picture, its size, color profile and orientation.")

        let signed = adding(iPhonePhoto, groups: ["{TIFF}": ["Artist"]],
                            xmp: [Tag(namespace: NS.dublinCore, name: "creator")])
        let signedText = MetadataStripPlan.summary(before: signed, after: cleanJPEG).text
        XCTAssertTrue(signedText.contains("settings, name and copyright, Apple camera data"), signedText)
    }

    func testSummaryAfterLocationOnly() {
        var after = iPhonePhoto
        after.groups["{GPS}"] = nil
        after.xmp.remove(exif("GPSLatitude"))
        let summary = MetadataStripPlan.summary(before: iPhonePhoto, after: after)
        XCTAssertEqual(summary.removed, [.location])
        XCTAssertEqual(summary.kept, [.picture, .size, .colorProfile, .orientation, .category(.cameraAndLens),
                                      .category(.dateAndTime), .category(.settings), .category(.appleCameraData),
                                      .category(.extraTags)])
        XCTAssertEqual(summary.text, "The copy is ready. Removed: location. Kept: the picture, its size, "
                       + "color profile, orientation, camera and lens, date and time, settings, "
                       + "Apple camera data and extra tags.")
    }

    func testSummaryWithNothingToRemove() {
        let summary = MetadataStripPlan.summary(before: cleanJPEG, after: cleanJPEG)
        XCTAssertEqual(summary.removed, [])
        XCTAssertEqual(summary.text, "The copy is ready. There was nothing to remove.")

        let bare = MetadataStripPlan.Inventory(topLevel: ["PixelWidth", "PixelHeight"])
        let fromBare = MetadataStripPlan.summary(before: iPhonePhoto, after: bare)
        XCTAssertEqual(fromBare.kept, [.picture, .size])
        XCTAssertTrue(fromBare.text.hasSuffix(" Kept: the picture and its size."))

        // The color space and the orientation can also live only in their groups.
        let grouped = MetadataStripPlan.Inventory(topLevel: ["PixelWidth"],
                                                  groups: ["{Exif}": ["ColorSpace"], "{TIFF}": ["Orientation"]])
        XCTAssertEqual(MetadataStripPlan.summary(before: iPhonePhoto, after: grouped).kept,
                       [.picture, .size, .colorProfile, .orientation])
    }
}
