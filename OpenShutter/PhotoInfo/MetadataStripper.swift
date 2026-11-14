import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import os
import CameraCore

/// Writes a copy of a picture without its metadata, the ways MetadataStripPlan lists, and opens every copy again to
/// check it before handing it over. A copy that still holds something it shouldn't is thrown away and the next way
/// is tried. The original file is never changed.
enum MetadataStripper {
    struct CleanCopy: Sendable {
        let url: URL
        let typeIdentifier: String
        /// "The copy is ready. Removed: location, camera and lens ... Kept: the picture, its size ..."
        let summary: String
        /// Anything the person should know about how the copy differs, such as a format change.
        let notes: [String]
        let byteCount: Int64?

        var fileName: String { url.lastPathComponent }
    }

    enum Failure: LocalizedError {
        case unreadable
        case notWritable
        case notCleaned

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file can't be read."
            case .notWritable: return "This format can't be saved here."
            case .notCleaned: return "The copy couldn't be cleaned."
            }
        }
    }

    /// Writes the clean copy into `folder`, named after `originalName` ("IMG_0001 no metadata.HEIC"). It decodes and
    /// encodes the full picture, which takes a moment and a lot of memory for a large photo: call it off the main
    /// actor, one at a time.
    static func cleanCopy(of url: URL, mode: StripMode, into folder: URL, originalName: String? = nil) throws -> CleanCopy {
        _ = namesMatchImageIO
        guard let facts = SourceFacts(url: url) else { throw Failure.unreadable }
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        let plan = MetadataStripPlan(sourceType: facts.type, writableTypes: writable, isRAW: facts.isRAW,
                                     hasAlpha: facts.hasAlpha, imageCount: facts.count, mode: mode)
        guard !plan.steps.isEmpty else { throw Failure.notWritable }
        let before = inventory(of: facts.source, at: facts.primary)
        let name = originalName ?? url.lastPathComponent

        for (number, step) in plan.steps.enumerated() {
            for variant in variants(of: step, mode: mode, facts: facts) {
                let attempt = folder.appendingPathComponent(
                    "attempt-\(number)-\(variant.tag).\(fileExtension(step.outputType))", isDirectory: false)
                let problems: [String] = autoreleasepool {
                    do {
                        try write(step, variant: variant, mode: mode, facts: facts, to: attempt)
                        return self.problems(in: attempt, step: step, mode: mode, facts: facts)
                    } catch {
                        return ["writing failed: \(error.localizedDescription)"]
                    }
                }
                guard problems.isEmpty else {
                    log.error("Clean copy, \(step.method.rawValue, privacy: .public) \(variant.tag, privacy: .public) into \(step.outputType, privacy: .public): \(problems.joined(separator: "; "), privacy: .public)")
                    try? FileManager.default.removeItem(at: attempt)
                    continue
                }
                let finalName = MetadataStripPlan.outputName(original: name, sourceType: facts.type,
                                                             outputType: step.outputType,
                                                             fileExtension: fileExtension(step.outputType))
                let target = folder.appendingPathComponent(finalName, isDirectory: false)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.moveItem(at: attempt, to: target)
                } catch {
                    try? FileManager.default.removeItem(at: attempt)
                    throw error
                }
                guard let copy = CGImageSourceCreateWithURL(target as CFURL, readOptions) else {
                    throw Failure.notCleaned
                }
                let after = inventory(of: copy, at: CGImageSourceGetPrimaryImageIndex(copy))
                var notes = step.notes.map(\.text)
                if facts.hasGainMap, !variant.gainMap, step.method != .losslessCopy {
                    notes.append("The copy doesn't keep the photo's HDR look.")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?
                    .int64Value
                return CleanCopy(url: target, typeIdentifier: step.outputType,
                                 summary: MetadataStripPlan.summary(before: before, after: after).text,
                                 notes: notes, byteCount: size)
            }
        }
        throw Failure.notCleaned
    }

    /// One image's metadata by name, as MetadataStripPlan checks it: the top-level properties, each dictionary's
    /// keys, and the top-level XMP tags.
    static func inventory(of source: CGImageSource, at index: Int) -> MetadataStripPlan.Inventory {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, readOptions) as? [String: Any] ?? [:]
        var topLevel = Set<String>()
        var groups: [String: Set<String>] = [:]
        for (key, value) in properties {
            if let dictionary = value as? [String: Any] {
                groups[key] = Set(dictionary.keys)
            } else {
                topLevel.insert(key)
            }
        }
        var tags = Set<MetadataStripPlan.XMPTag>()
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
                if let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                   let name = CGImageMetadataTagCopyName(tag) as String? {
                    tags.insert(MetadataStripPlan.XMPTag(namespace: namespace, name: name))
                }
                return true
            }
        }
        return MetadataStripPlan.Inventory(topLevel: topLevel, groups: groups, xmp: tags)
    }

    // MARK: - What is known about the source

    private static let readOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    private struct SourceFacts {
        let url: URL
        let source: CGImageSource
        let type: String
        let count: Int
        let primary: Int
        let properties: [CFString: Any]
        let width: Int
        let height: Int
        let orientation: Int
        let hasAlpha: Bool
        let isRAW: Bool
        let hasGainMap: Bool

        init?(url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, MetadataStripper.readOptions),
                  let type = CGImageSourceGetType(source) as String? else { return nil }
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { return nil }
            let primary = CGImageSourceGetPrimaryImageIndex(source)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, MetadataStripper.readOptions)
                as? [CFString: Any] ?? [:]
            self.url = url
            self.source = source
            self.type = type
            self.count = count
            self.primary = primary
            self.properties = properties
            width = MetadataStripper.integer(properties[kCGImagePropertyPixelWidth]) ?? 0
            height = MetadataStripper.integer(properties[kCGImagePropertyPixelHeight]) ?? 0
            let stored = MetadataStripper.integer(properties[kCGImagePropertyOrientation]) ?? 1
            orientation = (1...8).contains(stored) ? stored : 1
            hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
            isRAW = PhotoInfoFiles.isRAW(typeIdentifier: type)
            hasGainMap = MetadataStripper.gainMapTypes.contains {
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, primary, $0) != nil
            }
        }

        /// The size as shown, after the orientation turns it.
        var uprightWidth: Int { orientation >= 5 ? height : width }
        var uprightHeight: Int { orientation >= 5 ? width : height }
    }

    // MARK: - Writing

    /// How one step is tried. A re-encode first puts the HDR gain map back, then, if the copy fails its check, goes
    /// without it; Location only re-encodes first from the source's own properties, then from its XMP with the
    /// place fields taken out.
    private struct Variant {
        var gainMap: Bool
        var fromMetadata = false

        var tag: String { (gainMap ? "hdr" : "sdr") + (fromMetadata ? "-xmp" : "") }
    }

    private static func variants(of step: MetadataStripPlan.Step, mode: StripMode, facts: SourceFacts) -> [Variant] {
        switch step.method {
        case .losslessCopy:
            return [Variant(gainMap: true)]
        case .reencode, .convert:
            // A gain map drawn for the stored orientation would sit wrong on a converted copy, whose pixels are
            // turned upright.
            let canKeep = facts.hasGainMap && step.keepsGainMap && (step.method == .reencode || facts.orientation == 1)
            var tries = (canKeep ? [true, false] : [false]).map { Variant(gainMap: $0) }
            if step.method == .reencode, mode == .locationOnly {
                tries += tries.map { Variant(gainMap: $0.gainMap, fromMetadata: true) }
            }
            return tries
        }
    }

    private static func write(_ step: MetadataStripPlan.Step, variant: Variant, mode: StripMode, facts: SourceFacts,
                              to target: URL) throws {
        switch step.method {
        case .losslessCopy:
            try copyLosslessly(mode: mode, facts: facts, to: target)
        case .reencode:
            try reencode(step, variant: variant, mode: mode, facts: facts, to: target)
        case .convert:
            try convert(step, variant: variant, mode: mode, facts: facts, to: target)
        }
    }

    /// The image data as it is, with new metadata. Everything replaces all EXIF, IPTC and XMP with the orientation
    /// alone (which can't be passed on its own next to new metadata) and writes no XMP packet; Location only merges
    /// the place fields away and drops GPS.
    private static func copyLosslessly(mode: StripMode, facts: SourceFacts, to target: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, facts.type as CFString, facts.count,
                                                                nil) else { throw Failure.notWritable }
        let metadata = CGImageMetadataCreateMutable()
        var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageMetadataShouldExcludeGPS: true]
        switch mode {
        case .everything:
            if facts.orientation != 1 {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                                 kCGImagePropertyTIFFOrientation,
                                                                 NSNumber(value: facts.orientation))
            }
            options[kCGImageMetadataShouldExcludeXMP] = true
        case .locationOnly:
            for tag in MetadataStripPlan.locationXMPTags {
                clear(tag, in: metadata)
            }
            options[kCGImageDestinationMergeMetadata] = true
        }
        var error: Unmanaged<CFError>?
        // The copy is written as this returns; finalizing afterwards is not allowed.
        guard CGImageDestinationCopyImageSource(destination, facts.source, options as CFDictionary, &error) else {
            throw imageIOError(error)
        }
    }

    /// A merged metadata removes a tag whose value is null.
    private static func clear(_ tag: MetadataStripPlan.XMPTag, in metadata: CGMutableImageMetadata) {
        guard let path = tag.path else { return }
        if CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, kCFNull) { return }
        guard let prefix = MetadataStripPlan.XMPNamespace.prefix(for: tag.namespace),
              let null = CGImageMetadataTagCreate(tag.namespace as CFString, prefix as CFString, tag.name as CFString,
                                                  .string, kCFNull) else { return }
        _ = CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, null)
    }

    /// The main picture decoded and encoded again in its own format. Depth and portrait mattes stay out.
    private static func reencode(_ step: MetadataStripPlan.Step, variant: Variant, mode: StripMode,
                                 facts: SourceFacts, to target: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, facts.type as CFString, 1, nil) else {
            throw Failure.notWritable
        }
        var options: [CFString: Any] = [:]
        if let quality = step.quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        switch (mode, variant.fromMetadata) {
        case (.everything, _):
            let image = try decoded(facts)
            if step.keepsOrientationTag, facts.orientation != 1 {
                options[kCGImagePropertyOrientation] = facts.orientation
            }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            if variant.gainMap {
                addGainMaps(from: facts, to: destination)
            }
        case (.locationOnly, false):
            options[kCGImagePropertyGPSDictionary] = kCFNull
            if let iptc = facts.properties[kCGImagePropertyIPTCDictionary] as? [String: Any] {
                options[kCGImagePropertyIPTCDictionary] = withoutPlaces(iptc)
            }
            options[kCGImageDestinationPreserveGainMap] = variant.gainMap
            CGImageDestinationAddImageFromSource(destination, facts.source, facts.primary, options as CFDictionary)
        case (.locationOnly, true):
            let image = try decoded(facts)
            let original = CGImageSourceCopyMetadataAtIndex(facts.source, facts.primary, nil)
            let metadata = original.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            removeLocation(from: metadata)
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
            if variant.gainMap {
                addGainMaps(from: facts, to: destination)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.notWritable }
    }

    /// Decoded, a RAW developed, and written in another format with the orientation drawn into the pixels.
    /// Location only takes the other metadata along.
    private static func convert(_ step: MetadataStripPlan.Step, variant: Variant, mode: StripMode,
                                facts: SourceFacts, to target: URL) throws {
        let image = try facts.isRAW ? developed(facts) : upright(facts)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, step.outputType as CFString, 1,
                                                                nil) else { throw Failure.notWritable }
        var options: [CFString: Any] = [:]
        if mode == .locationOnly {
            options = carriedProperties(facts, width: image.width, height: image.height)
        }
        if let quality = step.quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if variant.gainMap {
            addGainMaps(from: facts, to: destination)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.notWritable }
    }

    private static func decoded(_ facts: SourceFacts) throws -> CGImage {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(facts.source, facts.primary, options) else {
            throw Failure.unreadable
        }
        return image
    }

    /// The full picture turned upright: ImageIO draws the orientation while it makes a thumbnail, and a thumbnail
    /// as large as the picture is the picture.
    private static func upright(_ facts: SourceFacts) throws -> CGImage {
        let side = max(facts.width, facts.height)
        guard side > 0 else { return try decoded(facts) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(facts.source, facts.primary, options as CFDictionary) else {
            throw Failure.unreadable
        }
        return image
    }

    /// A RAW file with Core Image's default development, upright, in Display P3.
    private static func developed(_ facts: SourceFacts) throws -> CGImage {
        guard let image = CIImage(contentsOf: facts.url, options: [.applyOrientationProperty: true]) else {
            throw Failure.unreadable
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else {
            throw Failure.unreadable
        }
        return rendered
    }

    private static let gainMapTypes: [CFString] = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]

    /// Depth and the portrait and segmentation mattes: images of the scene's shape and of the people in it.
    private static let strayAuxiliaryTypes: [CFString] = [
        kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
        kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
    ]

    /// Puts the gain map back so the copy keeps its look on an HDR screen.
    private static func addGainMaps(from facts: SourceFacts, to destination: CGImageDestination) {
        for type in gainMapTypes {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(facts.source, facts.primary, type) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, type, info)
            }
        }
    }

    // MARK: - Location only

    /// The IPTC place fields, by ImageIO's real constants. MetadataStripPlan names the same fields by their string
    /// values, which the SDK doesn't spell out, so the app does its own removal and check with these.
    private static let placeKeys: [String] = MetadataStripPlan.IPTCPlaceKey.allCases.map { constant(for: $0) as String }

    private static func withoutPlaces(_ iptc: [String: Any]) -> Any {
        var kept = iptc
        for key in placeKeys {
            kept.removeValue(forKey: key)
        }
        return kept.isEmpty ? kCFNull as Any : kept
    }

    /// The other metadata of the source for a converted copy: no GPS, no place fields, upright, at the new size.
    private static func carriedProperties(_ facts: SourceFacts, width: Int, height: Int) -> [CFString: Any] {
        var carried: [CFString: Any] = [:]
        for group in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary,
                      kCGImagePropertyMakerAppleDictionary] {
            if let values = facts.properties[group] {
                carried[group] = values
            }
        }
        if let iptc = facts.properties[kCGImagePropertyIPTCDictionary] as? [String: Any] {
            let kept = withoutPlaces(iptc)
            if kept is [String: Any] {
                carried[kCGImagePropertyIPTCDictionary] = kept
            }
        }
        if var exif = carried[kCGImagePropertyExifDictionary] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = width
            exif[kCGImagePropertyExifPixelYDimension as String] = height
            // The subject area names stored pixels, which turning the picture moves.
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea as String)
            exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation as String)
            carried[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = carried[kCGImagePropertyTIFFDictionary] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            carried[kCGImagePropertyTIFFDictionary] = tiff
        }
        carried[kCGImagePropertyOrientation] = 1
        return carried
    }

    /// Takes the GPS and place tags out of a copy of the source's XMP, for a copy written from it.
    private static func removeLocation(from metadata: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let tagName = MetadataStripPlan.XMPTag(namespace: namespace, name: name)
            if (namespace == MetadataStripPlan.XMPNamespace.exif && name.hasPrefix("GPS"))
                || MetadataStripPlan.locationXMPTags.contains(tagName) {
                paths.append(path as String)
            }
            return true
        }
        for path in paths {
            _ = CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
    }

    // MARK: - Checking a copy

    /// What keeps the copy at `url` from being handed over, empty when nothing does. Every image of the file is
    /// checked against MetadataStripPlan's rules, the place fields again by ImageIO's own constants, and the
    /// picture's size and orientation against the source's. Everything also allows no embedded thumbnail (it can
    /// show an earlier, uncropped picture) and no depth or matte images.
    private static func problems(in url: URL, step: MetadataStripPlan.Step, mode: StripMode,
                                 facts: SourceFacts) -> [String] {
        guard let copy = CGImageSourceCreateWithURL(url as CFURL, readOptions),
              CGImageSourceGetStatus(copy) == .statusComplete else { return ["the copy can't be opened"] }
        let count = CGImageSourceGetCount(copy)
        guard count > 0 else { return ["the copy holds no picture"] }
        var found: [String] = []
        if step.keepsEveryImage, count != facts.count {
            found.append("\(count) of \(facts.count) pictures")
        }
        for index in 0..<count {
            found += MetadataStripPlan.leftovers(in: inventory(of: copy, at: index), mode: mode)
            let properties = CGImageSourceCopyPropertiesAtIndex(copy, index, readOptions) as? [CFString: Any] ?? [:]
            if properties[kCGImagePropertyGPSDictionary] != nil {
                found.append("GPS")
            }
            if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [String: Any] {
                found += placeKeys.filter { iptc[$0] != nil }.map { "IPTC " + $0 }
            }
        }

        let primary = CGImageSourceGetPrimaryImageIndex(copy)
        let properties = CGImageSourceCopyPropertiesAtIndex(copy, primary, readOptions) as? [CFString: Any] ?? [:]
        let width = integer(properties[kCGImagePropertyPixelWidth]) ?? 0
        let height = integer(properties[kCGImagePropertyPixelHeight]) ?? 0
        let orientation = integer(properties[kCGImagePropertyOrientation]) ?? 1
        switch step.method {
        case .losslessCopy, .reencode:
            if facts.width > 0, width != facts.width || height != facts.height {
                found.append("size \(width)x\(height)")
            }
            if orientation != facts.orientation {
                found.append("orientation \(orientation)")
            }
        case .convert:
            if orientation != 1 {
                found.append("orientation \(orientation)")
            }
            // A RAW develops to its default crop, which can differ from the sensor size the file reports.
            if !facts.isRAW, facts.width > 0, width != facts.uprightWidth || height != facts.uprightHeight {
                found.append("size \(width)x\(height)")
            }
        }

        if mode == .everything {
            let container = CGImageSourceCopyProperties(copy, readOptions) as? [String: Any] ?? [:]
            if holdsThumbnail(container) {
                found.append("embedded thumbnail")
            }
            for type in strayAuxiliaryTypes where CGImageSourceCopyAuxiliaryDataInfoAtIndex(copy, primary, type) != nil {
                found.append(type as String)
            }
        }
        return found
    }

    /// Whether the container lists an embedded thumbnail anywhere in its description of the file.
    private static func holdsThumbnail(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let thumbnails = dictionary[kCGImagePropertyThumbnailImages as String] as? [Any], !thumbnails.isEmpty {
                return true
            }
            return dictionary.values.contains(where: holdsThumbnail)
        }
        if let array = value as? [Any] {
            return array.contains(where: holdsThumbnail)
        }
        return false
    }

    // MARK: - Helpers

    private static func fileExtension(_ type: String) -> String {
        UTType(type)?.preferredFilenameExtension ?? "img"
    }

    fileprivate static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 1e9 else { return nil }
        return Int(double.rounded())
    }

    private static func imageIOError(_ error: Unmanaged<CFError>?) -> Error {
        guard let error else { return Failure.notWritable }
        return error.takeRetainedValue() as Error
    }

    private static let log = Logger(subsystem: "ca.katsuma.openshutter", category: "PhotoInfo")

    // MARK: - Names against ImageIO's constants

    private static func constant(for group: MetadataStripPlan.Group) -> CFString {
        switch group {
        case .exif: return kCGImagePropertyExifDictionary
        case .exifAux: return kCGImagePropertyExifAuxDictionary
        case .tiff: return kCGImagePropertyTIFFDictionary
        case .gps: return kCGImagePropertyGPSDictionary
        case .iptc: return kCGImagePropertyIPTCDictionary
        case .makerApple: return kCGImagePropertyMakerAppleDictionary
        case .makerCanon: return kCGImagePropertyMakerCanonDictionary
        case .makerNikon: return kCGImagePropertyMakerNikonDictionary
        case .makerMinolta: return kCGImagePropertyMakerMinoltaDictionary
        case .makerFuji: return kCGImagePropertyMakerFujiDictionary
        case .makerOlympus: return kCGImagePropertyMakerOlympusDictionary
        case .makerPentax: return kCGImagePropertyMakerPentaxDictionary
        case .photoshop: return kCGImageProperty8BIMDictionary
        case .ciff: return kCGImagePropertyCIFFDictionary
        case .dng: return kCGImagePropertyDNGDictionary
        case .raw: return kCGImagePropertyRawDictionary
        case .openEXR: return kCGImagePropertyOpenEXRDictionary
        case .jfif: return kCGImagePropertyJFIFDictionary
        case .png: return kCGImagePropertyPNGDictionary
        case .gif: return kCGImagePropertyGIFDictionary
        case .heif: return kCGImagePropertyHEIFDictionary
        case .heics: return kCGImagePropertyHEICSDictionary
        case .webP: return kCGImagePropertyWebPDictionary
        case .avis: return kCGImagePropertyAVISDictionary
        case .tga: return kCGImagePropertyTGADictionary
        }
    }

    private static func constant(for key: MetadataStripPlan.IPTCPlaceKey) -> CFString {
        switch key {
        case .city: return kCGImagePropertyIPTCCity
        case .subLocation: return kCGImagePropertyIPTCSubLocation
        case .provinceState: return kCGImagePropertyIPTCProvinceState
        case .countryCode: return kCGImagePropertyIPTCCountryPrimaryLocationCode
        case .countryName: return kCGImagePropertyIPTCCountryPrimaryLocationName
        case .contentLocationCode: return kCGImagePropertyIPTCContentLocationCode
        case .contentLocationName: return kCGImagePropertyIPTCContentLocationName
        case .locationCreated: return kCGImagePropertyIPTCExtLocationCreated
        case .locationShown: return kCGImagePropertyIPTCExtLocationShown
        }
    }

    /// MetadataStripPlan names ImageIO's groups, keys and namespaces by their string values, which the SDK headers
    /// leave out. They are compared with the real constants once per run and a mismatch is logged as a fault. A
    /// mismatch fails safe: an unknown group or key makes Everything refuse the copy, and the place fields are
    /// checked by the constants above as well.
    private static let namesMatchImageIO: Bool = {
        var wrong: [String] = []
        for group in MetadataStripPlan.Group.allCases where group.rawValue != constant(for: group) as String {
            wrong.append(group.rawValue)
        }
        for key in MetadataStripPlan.IPTCPlaceKey.allCases where key.rawValue != constant(for: key) as String {
            wrong.append(key.rawValue)
        }
        let allowed: [(Set<String>, [CFString])] = [
            (MetadataStripPlan.allowedExifKeys, [
                kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
                kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifVersion, kCGImagePropertyExifFlashPixVersion,
                kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifGamma,
                kCGImagePropertyExifCompressedBitsPerPixel,
            ]),
            (MetadataStripPlan.allowedTIFFKeys, [
                kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFCompression,
                kCGImagePropertyTIFFPhotometricInterpretation, kCGImagePropertyTIFFTileWidth,
                kCGImagePropertyTIFFTileLength, kCGImagePropertyTIFFWhitePoint,
                kCGImagePropertyTIFFPrimaryChromaticities, kCGImagePropertyTIFFTransferFunction,
                kCGImagePropertyTIFFXPosition, kCGImagePropertyTIFFYPosition,
            ]),
            (MetadataStripPlan.allowedPNGKeys, [
                kCGImagePropertyPNGGamma, kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGXPixelsPerMeter,
                kCGImagePropertyPNGYPixelsPerMeter, kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGChromaticities,
                kCGImagePropertyPNGCompressionFilter, kCGImagePropertyPNGPixelsAspectRatio,
                kCGImagePropertyPNGTransparency, kCGImagePropertyAPNGLoopCount, kCGImagePropertyAPNGDelayTime,
                kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGFrameInfoArray,
                kCGImagePropertyAPNGCanvasPixelWidth, kCGImagePropertyAPNGCanvasPixelHeight,
            ]),
        ]
        for (names, constants) in allowed {
            wrong += constants.map { $0 as String }.filter { !names.contains($0) }
        }
        typealias Namespace = MetadataStripPlan.XMPNamespace
        let namespaces: [(String, CFString, CFString)] = [
            (Namespace.exif, kCGImageMetadataNamespaceExif, kCGImageMetadataPrefixExif),
            (Namespace.exifEX, kCGImageMetadataNamespaceExifEX, kCGImageMetadataPrefixExifEX),
            (Namespace.exifAux, kCGImageMetadataNamespaceExifAux, kCGImageMetadataPrefixExifAux),
            (Namespace.tiff, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF),
            (Namespace.xmpBasic, kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic),
            (Namespace.xmpRights, kCGImageMetadataNamespaceXMPRights, kCGImageMetadataPrefixXMPRights),
            (Namespace.dublinCore, kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore),
            (Namespace.photoshop, kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop),
            (Namespace.iptcCore, kCGImageMetadataNamespaceIPTCCore, kCGImageMetadataPrefixIPTCCore),
            (Namespace.iptcExtension, kCGImageMetadataNamespaceIPTCExtension, kCGImageMetadataPrefixIPTCExtension),
        ]
        for (uri, namespace, prefix) in namespaces
        where uri != namespace as String || Namespace.prefix(for: uri) != prefix as String {
            wrong.append(uri)
        }
        if !wrong.isEmpty {
            log.fault("MetadataStripPlan names differ from ImageIO: \(wrong.joined(separator: ", "), privacy: .public)")
        }
        return wrong.isEmpty
    }()
}
