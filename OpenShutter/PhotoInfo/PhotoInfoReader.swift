import Foundation
import ImageIO
import UniformTypeIdentifiers
import CameraCore

/// One line of the photo info list. The text is made once, off the main actor, so the list only lays it out.
struct PhotoInfoRow: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    /// The entries of a list or a group, shown folded under the row.
    var children: [PhotoInfoRow] = []
    /// The row can point at a person, a device or a place.
    var isPersonal = false

    /// OutlineGroup's children: nil for a row without any, so it draws no disclosure arrow.
    var nested: [PhotoInfoRow]? { children.isEmpty ? nil : children }
}

struct PhotoInfoSection: Identifiable, Sendable {
    let id: String
    let title: String
    var footer: String?
    let rows: [PhotoInfoRow]
}

/// Where a photo was taken, from its GPS fields.
struct PhotoInfoLocation: Equatable, Sendable {
    /// Signed degrees, south and west negative.
    let latitude: Double
    let longitude: Double
    /// "43.65320° N, 79.38320° W".
    let text: String

    /// Apple Maps at the spot. A link rather than a map item: the map item initializers moved in iOS 26.
    var mapsURL: URL? {
        let point = ExifFormat.decimal(latitude, maxDecimals: 6) + "," + ExifFormat.decimal(longitude, maxDecimals: 6)
        return URL(string: "https://maps.apple.com/?ll=" + point + "&q=Photo")
    }
}

/// Everything ImageIO can tell about one picture file, as text ready to show.
struct PhotoInfo: Sendable {
    let fileName: String
    let typeIdentifier: String
    /// "HEIF image".
    let typeName: String
    /// "4032 × 3024, 12 MP", as the picture shows once its orientation is applied.
    let sizeText: String?
    let fileSize: Int64?
    let imageCount: Int
    let isRAW: Bool
    let thumbnail: CGImage?
    let summary: [PhotoInfoRow]
    let location: PhotoInfoLocation?
    let locationRows: [PhotoInfoRow]
    /// Open Shutter's own fields (ShotXMP), named.
    let appRows: [PhotoInfoRow]
    /// One per property group, then the image's own properties, the file, its extra images and every XMP tag.
    let sections: [PhotoInfoSection]
    /// What "Everything" would take out, in the order the result sentence names them.
    let categories: [MetadataStripPlan.Category]
    let hasPersonalRows: Bool
    /// The whole list as plain text, for Copy all.
    let plainText: String
}

enum PhotoInfoError: LocalizedError {
    case unreadable

    var errorDescription: String? { "This file can't be read." }
}

enum PhotoInfoReader {
    /// Reads the file's container, its main picture's properties, XMP and extra images. Only a small thumbnail is
    /// decoded. Call it off the main actor.
    static func read(url: URL) throws -> PhotoInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, readOptions),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { throw PhotoInfoError.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, readOptions) as? [String: Any] else {
            throw PhotoInfoError.unreadable
        }
        let container = CGImageSourceCopyProperties(source, readOptions) as? [String: Any] ?? [:]
        var groups: [String: [String: Any]] = [:]
        var topLevel: [String: Any] = [:]
        for (key, value) in properties {
            if let group = value as? [String: Any] {
                groups[key] = group
            } else {
                topLevel[key] = value
            }
        }
        let xmp = xmpTags(CGImageSourceCopyMetadataAtIndex(source, index, nil))
        let extraImages = auxiliaryImages(source, index: index)

        let width = topLevel[key(kCGImagePropertyPixelWidth)].flatMap(PhotoInfoNames.int) ?? 0
        let height = topLevel[key(kCGImagePropertyPixelHeight)].flatMap(PhotoInfoNames.int) ?? 0
        let orientation = topLevel[key(kCGImagePropertyOrientation)].flatMap(PhotoInfoNames.int) ?? 1
        let turned = orientation >= 5 && orientation <= 8
        let shownWidth = turned ? height : width
        let shownHeight = turned ? width : height
        let sizeText = shownWidth > 0 && shownHeight > 0
            ? "\(shownWidth) \u{00D7} \(shownHeight), " + Formatting.megapixels(width: shownWidth, height: shownHeight)
            : nil
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            ?? container[key(kCGImagePropertyFileSize)].flatMap(PhotoInfoNames.int).map(Int64.init)

        let place = placeTaken(groups[PhotoInfoNames.gps] ?? [:])
        let summary = summaryRows(groups: groups, topLevel: topLevel, app: xmp.app, extraImages: extraImages)
        let appRows = ShotXMP.Field.allCases.compactMap { field in
            xmp.app[field].map { PhotoInfoRow(id: "app/" + field.rawValue, title: PhotoInfoNames.appTitle(field),
                                              value: PhotoInfoNames.appValue(field, $0)) }
        }

        var sections: [PhotoInfoSection] = []
        for name in PhotoInfoNames.sortedGroups(groups.keys) {
            guard let group = groups[name], !group.isEmpty else { continue }
            sections.append(PhotoInfoSection(id: "group/" + name, title: PhotoInfoNames.groupTitle(name),
                                             rows: rows(group, group: name, id: "group/" + name)))
        }
        if !topLevel.isEmpty {
            sections.append(PhotoInfoSection(id: "image", title: "Image",
                                             rows: rows(topLevel, group: nil, id: "image")))
        }
        if !container.isEmpty {
            sections.append(PhotoInfoSection(id: "file", title: "File",
                                             rows: rows(container, group: nil, id: "file")))
        }
        if !extraImages.isEmpty {
            sections.append(PhotoInfoSection(id: "extra", title: "Extra images", footer: extraImagesFooter,
                                             rows: extraImages))
        }
        if !xmp.rows.isEmpty {
            // ImageIO repeats the EXIF and TIFF fields here under their XMP names, so the list opens folded.
            let all = PhotoInfoRow(id: "xmp", title: "All tags", value: count(xmp.rows.count, "tag", "tags"),
                                   children: xmp.rows, isPersonal: xmp.rows.contains(where: \.isPersonal))
            sections.append(PhotoInfoSection(id: "xmp", title: "XMP", rows: [all]))
        }

        let inventory = MetadataStripper.inventory(of: source, at: index)
        let held = MetadataStripPlan.categories(in: inventory)
        let categories = MetadataStripPlan.Category.allCases.filter { held.contains($0) }
        let hasPersonalRows = place != nil || sections.contains { $0.rows.contains(where: containsPersonal) }
        let typeName = UTType(type)?.localizedDescription ?? type
        let fileName = url.lastPathComponent

        let plainText = text(fileName: fileName, typeName: typeName, sizeText: sizeText, fileSize: fileSize,
                             summary: summary, locationRows: place?.rows ?? [], appRows: appRows,
                             sections: sections)
        return PhotoInfo(fileName: fileName, typeIdentifier: type, typeName: typeName, sizeText: sizeText,
                         fileSize: fileSize, imageCount: CGImageSourceGetCount(source),
                         isRAW: PhotoInfoFiles.isRAW(typeIdentifier: type),
                         thumbnail: thumbnail(source, index: index), summary: summary,
                         location: place?.place, locationRows: place?.rows ?? [], appRows: appRows,
                         sections: sections, categories: categories, hasPersonalRows: hasPersonalRows,
                         plainText: plainText)
    }

    private static let readOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    // MARK: - Summary

    private static func summaryRows(groups: [String: [String: Any]], topLevel: [String: Any],
                                    app: [ShotXMP.Field: String], extraImages: [PhotoInfoRow]) -> [PhotoInfoRow] {
        let exif = groups[key(kCGImagePropertyExifDictionary)] ?? [:]
        let tiff = groups[key(kCGImagePropertyTIFFDictionary)] ?? [:]
        let exifAux = groups[key(kCGImagePropertyExifAuxDictionary)] ?? [:]
        func value(_ group: [String: Any], _ name: CFString) -> Any? { group[key(name)] }
        func number(_ group: [String: Any], _ name: CFString) -> Double? {
            value(group, name).flatMap(PhotoInfoNames.number)
        }
        func integer(_ group: [String: Any], _ name: CFString) -> Int? {
            value(group, name).flatMap(PhotoInfoNames.int)
        }
        func text(_ group: [String: Any], _ name: CFString) -> String? {
            PhotoInfoNames.text(value(group, name)).flatMap { $0.isEmpty ? nil : $0 }
        }

        var rows: [PhotoInfoRow] = []
        func add(_ title: String, _ text: String?, personal: Bool = false) {
            guard let text, !text.isEmpty else { return }
            rows.append(PhotoInfoRow(id: "summary/" + title, title: title, value: text, isPersonal: personal))
        }

        if let taken = dateTaken(exif: exif, tiff: tiff) {
            add("Taken", taken.date)
            add("Time zone", taken.zone)
        }
        let make = text(tiff, kCGImagePropertyTIFFMake)
        let model = text(tiff, kCGImagePropertyTIFFModel)
        switch (make, model) {
        case let (make?, model?): add("Camera", model.hasPrefix(make) ? model : make + " " + model)
        case let (make?, nil): add("Camera", make)
        case let (nil, model?): add("Camera", model)
        case (nil, nil): break
        }
        add("Lens", text(exif, kCGImagePropertyExifLensModel) ?? text(exifAux, kCGImagePropertyExifAuxLensModel))
        if let mode = app[.mode] {
            let scene = app[.scene].map { PhotoInfoNames.appValue(.scene, $0) }
            add("Mode", [PhotoInfoNames.appValue(.mode, mode), scene].compactMap { $0 }.joined(separator: ", "))
        }
        add("Shutter speed", number(exif, kCGImagePropertyExifExposureTime).flatMap(PhotoInfoNames.shutterText))
        // EXIF holds one frame's time for a blended stack, so the stack's own duration comes from the app's fields.
        add("Duration", ShotXMP.stackSummary(app))
        add("Aperture", number(exif, kCGImagePropertyExifFNumber).flatMap { $0 > 0 ? ApertureScale.label($0) : nil })
        let iso = value(exif, kCGImagePropertyExifISOSpeedRatings).map(PhotoInfoNames.numbers)?.first
        add("ISO", iso.flatMap { $0 > 0 ? ISOScale.compactLabel($0) : nil })
        add("Focal length", focalLength(mm: number(exif, kCGImagePropertyExifFocalLength),
                                        equivalent: number(exif, kCGImagePropertyExifFocalLenIn35mmFilm)))
        add("Exposure compensation", number(exif, kCGImagePropertyExifExposureBiasValue).map(PhotoInfoNames.evText))
        add("Flash", integer(exif, kCGImagePropertyExifFlash).map(MetadataFormat.flash))
        if let balance = integer(exif, kCGImagePropertyExifWhiteBalance) {
            let light = integer(exif, kCGImagePropertyExifLightSource).flatMap {
                $0 == 0 ? nil : MetadataFormat.lightSource($0)
            }
            let balanceText = [MetadataFormat.whiteBalance(balance), light].compactMap { $0 }.joined(separator: ", ")
            add("White balance", balanceText)
        }
        add("Metering", integer(exif, kCGImagePropertyExifMeteringMode).map(MetadataFormat.meteringMode))
        add("Software", text(tiff, kCGImagePropertyTIFFSoftware))
        let profile = PhotoInfoNames.text(topLevel[key(kCGImagePropertyProfileName)])
        add("Color profile", profile ?? integer(exif, kCGImagePropertyExifColorSpace).map(MetadataFormat.colorSpace))
        add("Orientation", topLevel[key(kCGImagePropertyOrientation)].flatMap(PhotoInfoNames.int)
            .map(MetadataFormat.orientation))
        if !extraImages.isEmpty {
            add("Extra images", extraImages.map(\.title).joined(separator: ", "))
        }
        return rows
    }

    /// When the picture was taken, in the time zone it was taken in when the file names it.
    private static func dateTaken(exif: [String: Any], tiff: [String: Any]) -> (date: String, zone: String?)? {
        let pairs: [(CFString, CFString, CFString, [String: Any])] = [
            (kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal,
             kCGImagePropertyExifSubsecTimeOriginal, exif),
            (kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTimeDigitized,
             kCGImagePropertyExifSubsecTimeDigitized, exif),
            (kCGImagePropertyTIFFDateTime, kCGImagePropertyExifOffsetTime, kCGImagePropertyExifSubsecTime, tiff),
        ]
        for (dateKey, offsetKey, subsecondsKey, group) in pairs {
            guard let text = PhotoInfoNames.text(group[key(dateKey)]) else { continue }
            // The offset and subseconds of TIFF's DateTime live in the EXIF group.
            let offset = PhotoInfoNames.text(exif[key(offsetKey)]).flatMap { $0.isEmpty ? nil : $0 }
            let subseconds = PhotoInfoNames.text(exif[key(subsecondsKey)])
            let zone = offset.flatMap(MetadataFormat.timeZone(offset:))
            guard let date = MetadataFormat.date(fromExif: text, offset: offset, subseconds: subseconds,
                                                 assuming: .current) else { continue }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            // Without an offset the text is a wall clock time; shown in the phone's zone it reads as written.
            formatter.timeZone = zone ?? .current
            return (formatter.string(from: date), zone != nil ? offset.map { "UTC" + $0 } : nil)
        }
        return nil
    }

    /// "6.765 mm, 24 mm equivalent".
    private static func focalLength(mm: Double?, equivalent: Double?) -> String? {
        let real = mm.flatMap { $0 > 0 ? PhotoInfoNames.millimetres($0) : nil }
        let full = equivalent.flatMap { $0 > 0 ? LensMath.focalLengthLabel($0) + " equivalent" : nil }
        let parts = [real, full].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Location

    private static func placeTaken(_ gps: [String: Any]) -> (place: PhotoInfoLocation, rows: [PhotoInfoRow])? {
        func value(_ name: CFString) -> Any? { gps[key(name)] }
        func number(_ name: CFString) -> Double? { value(name).flatMap(PhotoInfoNames.number) }
        func text(_ name: CFString) -> String? { PhotoInfoNames.text(value(name)) }
        guard let latitude = number(kCGImagePropertyGPSLatitude), let longitude = number(kCGImagePropertyGPSLongitude),
              let north = MetadataFormat.signedDegrees(latitude, ref: text(kCGImagePropertyGPSLatitudeRef)),
              let east = MetadataFormat.signedDegrees(longitude, ref: text(kCGImagePropertyGPSLongitudeRef)),
              abs(north) <= 90,
              let coordinates = MetadataFormat.coordinates(latitude: latitude,
                                                           latitudeRef: text(kCGImagePropertyGPSLatitudeRef),
                                                           longitude: longitude,
                                                           longitudeRef: text(kCGImagePropertyGPSLongitudeRef))
        else { return nil }

        var rows: [PhotoInfoRow] = []
        func add(_ title: String, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            rows.append(PhotoInfoRow(id: "location/" + title, title: title, value: text, isPersonal: true))
        }
        add("Coordinates", coordinates)
        add("Altitude", number(kCGImagePropertyGPSAltitude).flatMap {
            MetadataFormat.altitude($0, ref: value(kCGImagePropertyGPSAltitudeRef).flatMap(PhotoInfoNames.int))
        })
        add("Facing", number(kCGImagePropertyGPSImgDirection).flatMap {
            MetadataFormat.direction($0, ref: text(kCGImagePropertyGPSImgDirectionRef))
        })
        add("Moving toward", number(kCGImagePropertyGPSTrack).flatMap {
            MetadataFormat.direction($0, ref: text(kCGImagePropertyGPSTrackRef))
        })
        add("Speed", number(kCGImagePropertyGPSSpeed).flatMap {
            MetadataFormat.speed($0, ref: text(kCGImagePropertyGPSSpeedRef))
        })
        add("Accuracy", number(kCGImagePropertyGPSHPositioningError).flatMap(MetadataFormat.positioningError)
            .map { "Within " + $0 })
        if let day = text(kCGImagePropertyGPSDateStamp), let time = text(kCGImagePropertyGPSTimeStamp),
           let date = MetadataFormat.gpsDate(dateStamp: day, timeStamp: time) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            add("GPS time", formatter.string(from: date))
        }
        return (PhotoInfoLocation(latitude: north, longitude: east, text: coordinates), rows)
    }

    // MARK: - Rows

    /// Arrays longer than this list their first values only; some tags hold hundreds of them.
    private static let shownListLength = 16
    private static let maxChildren = 200

    private static func rows(_ dictionary: [String: Any], group: String?, id: String,
                             personal: Bool = false) -> [PhotoInfoRow] {
        dictionary.map { name, value in
            row(key: name, value: value, group: group, siblings: dictionary, id: id + "/" + name, personal: personal)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func row(key name: String, value: Any, group: String?, siblings: [String: Any], id: String,
                            personal: Bool) -> PhotoInfoRow {
        let title = PhotoInfoNames.title(group: group, key: name)
        let isPersonal = personal || PhotoInfoNames.isPersonal(group: group, key: name)
        // Keys inside a nested dictionary have no table of their own, so they keep their split names.
        let nestedGroup = group == PhotoInfoNames.makerApple ? group : ""
        if let nested = value as? [String: Any] {
            return PhotoInfoRow(id: id, title: title, value: count(nested.count, "value", "values"),
                                children: rows(nested, group: nestedGroup, id: id, personal: isPersonal),
                                isPersonal: isPersonal)
        }
        if let array = value as? [Any], !array.allSatisfy(PhotoInfoNames.isScalar) {
            let children = array.prefix(maxChildren).enumerated().map { offset, element in
                row(key: String(offset + 1), value: element, group: nestedGroup, siblings: [:],
                    id: id + "/\(offset)", personal: isPersonal)
            }
            return PhotoInfoRow(id: id, title: title, value: count(array.count, "item", "items"),
                                children: children + more(array.count, id: id), isPersonal: isPersonal)
        }
        if let array = value as? [Any], array.count > shownListLength {
            let shown = array.prefix(shownListLength).map(PhotoInfoNames.describe).joined(separator: ", ")
            return PhotoInfoRow(id: id, title: title, value: shown + ", and \(array.count - shownListLength) more",
                                isPersonal: isPersonal)
        }
        let text = PhotoInfoNames.value(group: group, key: name, value: value, siblings: siblings)
            ?? PhotoInfoNames.describe(value)
        return PhotoInfoRow(id: id, title: title, value: text, isPersonal: isPersonal)
    }

    private static func more(_ total: Int, id: String) -> [PhotoInfoRow] {
        guard total > maxChildren else { return [] }
        return [PhotoInfoRow(id: id + "/more", title: "More", value: "\(total - maxChildren) not shown")]
    }

    // MARK: - XMP

    private static func xmpTags(_ metadata: CGImageMetadata?) -> (rows: [PhotoInfoRow], app: [ShotXMP.Field: String]) {
        guard let metadata else { return ([], [:]) }
        var rows: [PhotoInfoRow] = []
        var app: [ShotXMP.Field: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let title = path as String
            rows.append(xmpRow(tag, title: title, id: "xmp/" + title,
                               personal: PhotoInfoNames.isPersonal(xmpNamespace: namespace, name: name)))
            if namespace == ShotXMP.namespace, let field = ShotXMP.Field(rawValue: name),
               let value = CGImageMetadataTagCopyValue(tag) as? String {
                app[field] = value
            }
            return true
        }
        rows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (rows, app)
    }

    private static func xmpRow(_ tag: CGImageMetadataTag, title: String, id: String, personal: Bool) -> PhotoInfoRow {
        let value = CGImageMetadataTagCopyValue(tag)
        if let text = value as? String {
            return PhotoInfoRow(id: id, title: title, value: PhotoInfoNames.cleaned(text), isPersonal: personal)
        }
        if let array = value as? [AnyObject] {
            let elements = array.prefix(maxChildren).enumerated().map { offset, element in
                xmpElement(element, title: String(offset + 1), id: id + "/\(offset)", personal: personal)
            }
            // A text with one language reads as the text.
            if CGImageMetadataTagGetType(tag) == .alternateText, elements.count == 1, elements[0].children.isEmpty {
                return PhotoInfoRow(id: id, title: title, value: elements[0].value, isPersonal: personal)
            }
            return PhotoInfoRow(id: id, title: title, value: count(array.count, "item", "items"),
                                children: elements + more(array.count, id: id), isPersonal: personal)
        }
        if let fields = value as? [String: AnyObject] {
            let children = fields.sorted { $0.key < $1.key }.prefix(maxChildren).map { name, element in
                xmpElement(element, title: name, id: id + "/" + name, personal: personal)
            }
            return PhotoInfoRow(id: id, title: title, value: count(fields.count, "field", "fields"), children: children,
                                isPersonal: personal)
        }
        return PhotoInfoRow(id: id, title: title, value: value.map(PhotoInfoNames.describe) ?? "", isPersonal: personal)
    }

    /// A list entry or structure field, which ImageIO hands over as a tag of its own or as a plain value.
    private static func xmpElement(_ element: AnyObject, title: String, id: String, personal: Bool) -> PhotoInfoRow {
        guard CFGetTypeID(element) == CGImageMetadataTagGetTypeID() else {
            return PhotoInfoRow(id: id, title: title, value: PhotoInfoNames.describe(element), isPersonal: personal)
        }
        let tag = unsafeDowncast(element, to: CGImageMetadataTag.self)
        var name = title
        // Structure fields are named by their tags, list entries by their position.
        if Int(title) == nil, let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
           let tagName = CGImageMetadataTagCopyName(tag) as String? {
            name = prefix + ":" + tagName
        }
        return xmpRow(tag, title: name, id: id, personal: personal)
    }

    // MARK: - Extra images

    private static let auxiliaryTypes: [(CFString, String)] = [
        (kCGImageAuxiliaryDataTypeHDRGainMap, "HDR gain map"),
        (kCGImageAuxiliaryDataTypeISOGainMap, "ISO gain map"),
        (kCGImageAuxiliaryDataTypeDepth, "Depth map"),
        (kCGImageAuxiliaryDataTypeDisparity, "Disparity map"),
        (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "Portrait matte"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, "Skin matte"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, "Hair matte"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, "Teeth matte"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, "Glasses matte"),
        (kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, "Sky matte"),
    ]

    private static let extraImagesFooter = "Gain maps let an HDR screen show the photo brighter. Depth maps and mattes hold the shape of the scene and the outline of the people in it."

    private static func auxiliaryImages(_ source: CGImageSource, index: Int) -> [PhotoInfoRow] {
        auxiliaryTypes.compactMap { type, title in
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [String: Any] else {
                return nil
            }
            let description = info[key(kCGImageAuxiliaryDataInfoDataDescription)] as? [String: Any] ?? [:]
            let width = description[key(kCGImagePropertyWidth)].flatMap(PhotoInfoNames.int)
            let height = description[key(kCGImagePropertyHeight)].flatMap(PhotoInfoNames.int)
            let size = width.flatMap { w in height.map { h in "\(w) \u{00D7} \(h)" } } ?? "Included"
            return PhotoInfoRow(id: "extra/" + (type as String), title: title, value: size)
        }
    }

    // MARK: - Thumbnail

    /// Drawn from the picture itself with its orientation applied. The thumbnail a file embeds can be older than
    /// the picture, such as one made before a crop.
    private static func thumbnail(_ source: CGImageSource, index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    // MARK: - Copy all

    private static func text(fileName: String, typeName: String, sizeText: String?, fileSize: Int64?,
                             summary: [PhotoInfoRow], locationRows: [PhotoInfoRow], appRows: [PhotoInfoRow],
                             sections: [PhotoInfoSection]) -> String {
        var lines = [fileName]
        lines.append([typeName, sizeText, fileSize.map { Formatting.fileSize(bytes: $0) }]
            .compactMap { $0 }.joined(separator: ", "))
        func section(_ title: String, _ rows: [PhotoInfoRow]) {
            guard !rows.isEmpty else { return }
            lines.append("")
            lines.append(title)
            append(rows, depth: 0, to: &lines)
        }
        section("Summary", summary)
        section("Location", locationRows)
        section("Open Shutter", appRows)
        for item in sections {
            section(item.title, item.rows)
        }
        return lines.joined(separator: "\n")
    }

    private static func append(_ rows: [PhotoInfoRow], depth: Int, to lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for row in rows {
            lines.append(indent + row.title + ": " + row.value)
            append(row.children, depth: depth + 1, to: &lines)
        }
    }

    // MARK: - Helpers

    private static func key(_ constant: CFString) -> String {
        constant as String
    }

    private static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) " + (number == 1 ? one : many)
    }

    private static func containsPersonal(_ row: PhotoInfoRow) -> Bool {
        row.isPersonal || row.children.contains(where: containsPersonal)
    }
}
