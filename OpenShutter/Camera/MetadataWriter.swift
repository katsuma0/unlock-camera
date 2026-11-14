import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import os
import CameraCore

// What ShotMetadataBuilder decides, written into files: ImageIO property dictionaries for pictures the app encodes,
// the camera's own metadata plus the additions for files AVCapturePhotoOutput writes, an XMP packet merged in
// without re-encoding, and QuickTime items for movies. Each key maps to its ImageIO or AVFoundation constant through
// an exhaustive switch, so a key added in CameraCore fails the build here instead of quietly going missing.

// MARK: - Pictures

enum ImageIOMetadata {
    /// `{Exif}`, `{TIFF}`, `{GPS}` and `{IPTC}` for a picture the app encodes itself, plus the top-level orientation,
    /// which is the one readers honour.
    static func properties(_ metadata: ImageMetadata) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        let groups: [(CFString, [CFString: Any])] = [
            (kCGImagePropertyExifDictionary, dictionary(metadata.exif, key: exifKey)),
            (kCGImagePropertyTIFFDictionary, dictionary(metadata.tiff, key: tiffKey)),
            (kCGImagePropertyGPSDictionary, dictionary(metadata.gps, key: gpsKey)),
            (kCGImagePropertyIPTCDictionary, dictionary(metadata.iptc, key: iptcKey)),
        ]
        for (name, values) in groups where !values.isEmpty {
            result[name] = values
        }
        if case .integer(let orientation)? = metadata.tiff[.orientation] {
            result[kCGImagePropertyOrientation] = orientation
        }
        return result
    }

    /// The camera's metadata with the additions: every key the camera wrote stays as it is (its EXIF, TIFF and
    /// MakerApple, which holds the Live Photo pairing), missing ones are added, and GPS is the location gate's
    /// alone, so a fix appears only while location tags are on.
    static func merged(into base: [String: Any], adding additions: ImageMetadata) -> [String: Any] {
        var result = base
        addMissing(dictionary(additions.exif, key: exifKey), to: kCGImagePropertyExifDictionary, in: &result)
        addMissing(dictionary(additions.tiff, key: tiffKey), to: kCGImagePropertyTIFFDictionary, in: &result)
        addMissing(dictionary(additions.iptc, key: iptcKey), to: kCGImagePropertyIPTCDictionary, in: &result)
        let gps = dictionary(additions.gps, key: gpsKey)
        let gpsName = kCGImagePropertyGPSDictionary as String
        if gps.isEmpty {
            result.removeValue(forKey: gpsName)
        } else {
            result[gpsName] = stringKeyed(gps)
        }
        return result
    }

    /// `data` with the app's XMP packet merged in. The image is copied, not encoded again. When the copy would lose
    /// anything (Apple's maker note with the Live Photo pairing, GPS, a gain map, depth), the input comes back
    /// instead: the camera facts are in EXIF and the comment either way.
    static func addingXMP(to data: Data, _ metadata: ImageMetadata) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return data }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return data }
        // A DNG is the sensor record, and nothing has shown yet that copying its container keeps it whole.
        if UTType(type as String)?.conforms(to: .rawImage) == true { return data }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let packet = packet(metadata, skipping: CGImageSourceCopyMetadataAtIndex(source, index, nil)) else {
            return data
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, count, nil) else {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: packet.metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        // The copy is written as this returns; finalizing the destination afterwards is not allowed.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            log.error("XMP merge failed: \(describe(error), privacy: .public)")
            return data
        }
        let copy = output as Data
        if let lost = loss(from: source, index: index, to: copy, expecting: packet.firstPath) {
            log.error("XMP merge dropped \(lost, privacy: .public); the file is kept without the packet")
            return data
        }
        return copy
    }

    // MARK: Keys

    private static func exifKey(_ key: ExifKey) -> CFString {
        switch key {
        case .exposureTime: return kCGImagePropertyExifExposureTime
        case .fNumber: return kCGImagePropertyExifFNumber
        case .exposureProgram: return kCGImagePropertyExifExposureProgram
        case .isoSpeedRatings: return kCGImagePropertyExifISOSpeedRatings
        case .dateTimeOriginal: return kCGImagePropertyExifDateTimeOriginal
        case .dateTimeDigitized: return kCGImagePropertyExifDateTimeDigitized
        case .offsetTime: return kCGImagePropertyExifOffsetTime
        case .offsetTimeOriginal: return kCGImagePropertyExifOffsetTimeOriginal
        case .offsetTimeDigitized: return kCGImagePropertyExifOffsetTimeDigitized
        case .subsecTime: return kCGImagePropertyExifSubsecTime
        case .subsecTimeOriginal: return kCGImagePropertyExifSubsecTimeOriginal
        case .subsecTimeDigitized: return kCGImagePropertyExifSubsecTimeDigitized
        case .shutterSpeedValue: return kCGImagePropertyExifShutterSpeedValue
        case .apertureValue: return kCGImagePropertyExifApertureValue
        case .brightnessValue: return kCGImagePropertyExifBrightnessValue
        case .exposureBiasValue: return kCGImagePropertyExifExposureBiasValue
        case .meteringMode: return kCGImagePropertyExifMeteringMode
        case .lightSource: return kCGImagePropertyExifLightSource
        case .flash: return kCGImagePropertyExifFlash
        case .focalLength: return kCGImagePropertyExifFocalLength
        case .userComment: return kCGImagePropertyExifUserComment
        case .colorSpace: return kCGImagePropertyExifColorSpace
        case .pixelXDimension: return kCGImagePropertyExifPixelXDimension
        case .pixelYDimension: return kCGImagePropertyExifPixelYDimension
        case .sensingMethod: return kCGImagePropertyExifSensingMethod
        case .sceneType: return kCGImagePropertyExifSceneType
        case .customRendered: return kCGImagePropertyExifCustomRendered
        case .exposureMode: return kCGImagePropertyExifExposureMode
        case .whiteBalance: return kCGImagePropertyExifWhiteBalance
        case .digitalZoomRatio: return kCGImagePropertyExifDigitalZoomRatio
        case .focalLenIn35mmFilm: return kCGImagePropertyExifFocalLenIn35mmFilm
        case .sceneCaptureType: return kCGImagePropertyExifSceneCaptureType
        case .lensSpecification: return kCGImagePropertyExifLensSpecification
        case .lensMake: return kCGImagePropertyExifLensMake
        case .lensModel: return kCGImagePropertyExifLensModel
        case .compositeImage: return kCGImagePropertyExifCompositeImage
        case .sourceImageNumberOfCompositeImage: return kCGImagePropertyExifSourceImageNumberOfCompositeImage
        }
    }

    private static func tiffKey(_ key: TIFFKey) -> CFString {
        switch key {
        case .make: return kCGImagePropertyTIFFMake
        case .model: return kCGImagePropertyTIFFModel
        case .software: return kCGImagePropertyTIFFSoftware
        case .dateTime: return kCGImagePropertyTIFFDateTime
        case .hostComputer: return kCGImagePropertyTIFFHostComputer
        case .orientation: return kCGImagePropertyTIFFOrientation
        case .artist: return kCGImagePropertyTIFFArtist
        case .copyright: return kCGImagePropertyTIFFCopyright
        }
    }

    private static func gpsKey(_ key: GPSKey) -> CFString {
        switch key {
        case .latitude: return kCGImagePropertyGPSLatitude
        case .latitudeRef: return kCGImagePropertyGPSLatitudeRef
        case .longitude: return kCGImagePropertyGPSLongitude
        case .longitudeRef: return kCGImagePropertyGPSLongitudeRef
        case .altitude: return kCGImagePropertyGPSAltitude
        case .altitudeRef: return kCGImagePropertyGPSAltitudeRef
        case .timeStamp: return kCGImagePropertyGPSTimeStamp
        case .dateStamp: return kCGImagePropertyGPSDateStamp
        case .speed: return kCGImagePropertyGPSSpeed
        case .speedRef: return kCGImagePropertyGPSSpeedRef
        case .track: return kCGImagePropertyGPSTrack
        case .trackRef: return kCGImagePropertyGPSTrackRef
        case .imgDirection: return kCGImagePropertyGPSImgDirection
        case .imgDirectionRef: return kCGImagePropertyGPSImgDirectionRef
        case .destBearing: return kCGImagePropertyGPSDestBearing
        case .destBearingRef: return kCGImagePropertyGPSDestBearingRef
        case .hPositioningError: return kCGImagePropertyGPSHPositioningError
        }
    }

    private static func iptcKey(_ key: IPTCKey) -> CFString {
        switch key {
        case .originatingProgram: return kCGImagePropertyIPTCOriginatingProgram
        case .programVersion: return kCGImagePropertyIPTCProgramVersion
        }
    }

    // MARK: Helpers

    private static let log = Logger(subsystem: "ca.katsuma.openshutter", category: "Metadata")

    private static func dictionary<Key>(_ values: [Key: MetadataValue], key: (Key) -> CFString) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        for (name, value) in values {
            result[key(name)] = object(value)
        }
        return result
    }

    /// Strings, numbers and arrays of numbers, the property list types ImageIO takes.
    private static func object(_ value: MetadataValue) -> Any {
        switch value {
        case .text(let text): return text
        case .number(let number): return number
        case .integer(let integer): return integer
        case .numbers(let numbers): return numbers
        case .integers(let integers): return integers
        }
    }

    private static func stringKeyed(_ values: [CFString: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            result[key as String] = value
        }
        return result
    }

    private static func addMissing(_ values: [CFString: Any], to group: CFString, in metadata: inout [String: Any]) {
        guard !values.isEmpty else { return }
        let name = group as String
        var existing = metadata[name] as? [String: Any] ?? [:]
        for (key, value) in values where existing[key as String] == nil {
            existing[key as String] = value
        }
        metadata[name] = existing
    }

    /// The app's XMP tags, without any the file already carries, such as the camera's own creator tool: merged in,
    /// they would replace it. nil when nothing is left to add.
    private static func packet(_ metadata: ImageMetadata,
                               skipping existing: CGImageMetadata?) -> (metadata: CGMutableImageMetadata, firstPath: String)? {
        let packet = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(packet, ShotXMP.namespace as CFString, ShotXMP.prefix as CFString,
                                                        &error) else {
            log.error("XMP namespace refused: \(describe(error), privacy: .public)")
            return nil
        }
        func isNew(_ path: String) -> Bool {
            guard let existing else { return true }
            return CGImageMetadataCopyTagWithPath(existing, nil, path as CFString) == nil
        }
        var firstPath: String?
        func note(_ path: String, _ added: Bool) {
            if added, firstPath == nil { firstPath = path }
        }
        for entry in metadata.xmp where !entry.value.isEmpty && isNew(entry.field.path) {
            note(entry.field.path, CGImageMetadataSetValueWithPath(packet, nil, entry.field.path as CFString,
                                                                  entry.value as CFString))
        }
        let tool = metadata.creatorTool.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tool.isEmpty, isNew("xmp:CreatorTool") {
            note("xmp:CreatorTool", CGImageMetadataSetValueWithPath(packet, nil, "xmp:CreatorTool" as CFString,
                                                                   tool as CFString))
        }
        // dc:creator is an ordered list of names; one name goes in as a list of one.
        if let creator = metadata.creator, isNew("dc:creator"),
           let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                              "creator" as CFString, .arrayOrdered, [creator] as CFArray) {
            note("dc:creator", CGImageMetadataSetTagWithPath(packet, nil, "dc:creator" as CFString, tag))
        }
        // dc:rights is text with a language; x-default is the one readers fall back to.
        if let rights = metadata.rights, isNew("dc:rights") {
            var added = CGImageMetadataSetValueWithPath(packet, nil, "dc:rights[x-default]" as CFString,
                                                        rights as CFString)
            if !added, let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore,
                                                          kCGImageMetadataPrefixDublinCore, "rights" as CFString,
                                                          .alternateText, [rights] as CFArray) {
                added = CGImageMetadataSetTagWithPath(packet, nil, "dc:rights" as CFString, tag)
            }
            note("dc:rights", added)
        }
        guard let firstPath else { return nil }
        return (packet, firstPath)
    }

    /// Auxiliary images a photo can carry that a copy must keep.
    private static var auxiliaryTypes: [CFString] {
        [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeDepth,
         kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
    }

    /// What the copy lost compared with the source, or nil when it kept everything and carries the packet.
    /// Only properties and the small auxiliary images are read, never the photo's own pixels.
    private static func loss(from source: CGImageSource, index: Int, to copy: Data, expecting path: String) -> String? {
        guard let copied = CGImageSourceCreateWithData(copy as CFData, nil) else { return "the file" }
        guard CGImageSourceGetCount(copied) == CGImageSourceGetCount(source) else { return "images" }
        let before = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let after = CGImageSourceCopyPropertiesAtIndex(copied, index, nil) as? [CFString: Any] ?? [:]
        let groups = [kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                      kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary]
        for group in groups where before[group] != nil && after[group] == nil {
            return group as String
        }
        // Every key of these: the maker note holds the Live Photo pairing, and nothing here changes either.
        for group in [kCGImagePropertyMakerAppleDictionary, kCGImagePropertyGPSDictionary] {
            let kept = (after[group] as? [String: Any])?.count ?? 0
            if let had = (before[group] as? [String: Any])?.count, kept < had {
                return group as String
            }
        }
        let exifBefore = before[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAfter = after[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let facts = [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
                     kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel, kCGImagePropertyExifUserComment]
        for key in facts where exifBefore[key] != nil && exifAfter[key] == nil {
            return key as String
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation]
        where (before[key] as? NSNumber) != (after[key] as? NSNumber) {
            return key as String
        }
        for type in auxiliaryTypes where CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) != nil
            && CGImageSourceCopyAuxiliaryDataInfoAtIndex(copied, index, type) == nil {
            return type as String
        }
        guard let written = CGImageSourceCopyMetadataAtIndex(copied, index, nil),
              CGImageMetadataCopyTagWithPath(written, nil, path as CFString) != nil else { return "the XMP packet" }
        return nil
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "no reason given" }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}

// MARK: - Files the camera writes

/// Flattens an AVCapturePhoto with the additions merged into the metadata the camera wrote.
final class ShotMetadataCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    private let additions: ImageMetadata

    init(additions: ImageMetadata) {
        self.additions = additions
        super.init()
    }

    /// Never nil: nil would strip every tag the camera wrote.
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        ImageIOMetadata.merged(into: photo.metadata, adding: additions)
    }
}

// MARK: - Movies

enum MovieMetadata {
    /// Top-level QuickTime items. A key this system can't write (the iOS 26 camera keys on iOS 18) is left out.
    static func items(_ entries: [MovieMetadataEntry]) -> [AVMetadataItem] {
        entries.compactMap(item)
    }

    private static func item(_ entry: MovieMetadataEntry) -> AVMetadataItem? {
        let item = AVMutableMetadataItem()
        switch entry.key {
        case .make: item.identifier = .quickTimeMetadataMake
        case .model: item.identifier = .quickTimeMetadataModel
        case .software: item.identifier = .quickTimeMetadataSoftware
        case .creationDate: item.identifier = .quickTimeMetadataCreationDate
        case .locationISO6709: item.identifier = .quickTimeMetadataLocationISO6709
        case .author: item.identifier = .quickTimeMetadataAuthor
        case .copyright: item.identifier = .quickTimeMetadataCopyright
        case .locationHorizontalAccuracy:
            item.identifier = .quickTimeMetadataLocationHorizontalAccuracyInMeters
            return float32(item, entry.value)
        case .fullFrameRatePlaybackIntent:
            item.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
            return uint8(item, entry.value)
        case .cameraISOSensitivity, .cameraWhiteBalance, .cameraShutterSpeedTime, .cameraShutterSpeedAngle:
            guard let identifier = cameraIdentifier(entry.key) else { return nil }
            item.identifier = identifier
        case .app(let field):
            item.keySpace = .quickTimeMetadata
            item.key = field.quickTimeKey as NSString
        }
        return text(item, entry.value)
    }

    /// The iOS 26 camera keys, nil on older systems.
    private static func cameraIdentifier(_ key: MovieKey) -> AVMetadataIdentifier? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            switch key {
            case .cameraISOSensitivity: return .quickTimeMetadataCameraISOSensitivity
            case .cameraWhiteBalance: return .quickTimeMetadataCameraWhiteBalance
            case .cameraShutterSpeedTime: return .quickTimeMetadataCameraShutterSpeedTime
            case .cameraShutterSpeedAngle: return .quickTimeMetadataCameraShutterSpeedAngle
            default: return nil
            }
        }
        #endif
        return nil
    }

    /// Every item carries a value; one without would only put an empty key in the file.
    private static func text(_ item: AVMutableMetadataItem, _ value: MetadataValue) -> AVMetadataItem? {
        let string: String
        switch value {
        case .text(let text): string = text
        case .number(let number): string = ExifFormat.decimal(number)
        case .integer(let integer): string = String(integer)
        case .numbers, .integers: return nil
        }
        guard !string.isEmpty else { return nil }
        item.value = string as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func float32(_ item: AVMutableMetadataItem, _ value: MetadataValue) -> AVMetadataItem? {
        let number: Double
        switch value {
        case .number(let value): number = value
        case .integer(let value): number = Double(value)
        default: return nil
        }
        guard number.isFinite else { return nil }
        item.value = NSNumber(value: Float(number))
        item.dataType = kCMMetadataBaseDataType_Float32 as String
        return item
    }

    private static func uint8(_ item: AVMutableMetadataItem, _ value: MetadataValue) -> AVMetadataItem? {
        guard case .integer(let integer) = value else { return nil }
        item.value = NSNumber(value: UInt8(clamping: integer))
        item.dataType = kCMMetadataBaseDataType_UInt8 as String
        return item
    }
}

// MARK: - Device identity

/// Who made the files. iOS has no API for the phone's name as Apple writes it ("iPhone 16 Pro"), so it is learned from
/// what the camera writes itself: a photo's TIFF model, the movie metadata the capture pipeline recommends (iOS 26), or
/// the start of a stack frame's lens model. The name is kept for the next launch, until the app runs on another kind
/// of phone.
final class DeviceIdentityResolver: @unchecked Sendable {
    static let shared = DeviceIdentityResolver()

    /// "26.1", what Apple's Camera writes as a movie's software.
    let systemVersion: String
    /// "1.0".
    let appVersion: String

    /// How much a name can be trusted, lowest first. A saved name came from a photo or the pipeline in an earlier
    /// launch, so it outranks this launch's pipeline guess, and only a photo replaces it.
    private enum Source: Int {
        case machine, lensModel, recommended, saved, photo
    }

    private static let savedKey = "ca.katsuma.openshutter.deviceModel"

    private let machine: String
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var model: String
    private var source: Source

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var system = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            system += ".\(version.patchVersion)"
        }
        systemVersion = system
        appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let machine = Self.machineIdentifier()
        self.machine = machine
        // A name saved on another kind of phone (a backup restored to a new one) describes that phone.
        if let saved = defaults.stringArray(forKey: Self.savedKey), saved.count == 2, saved[0] == machine,
           !saved[1].isEmpty {
            model = saved[1]
            source = .saved
        } else {
            model = machine.hasPrefix("iPhone") ? machine : "iPhone"
            source = .machine
        }
    }

    /// The real camera's files.
    var identity: DeviceIdentity {
        let model = lock.withLock { self.model }
        return DeviceIdentity(model: model, systemVersion: systemVersion, appVersion: appVersion)
    }

    /// The simulated camera's files, which never claim an Apple camera: it runs on real phones too.
    var simulatedIdentity: DeviceIdentity {
        DeviceIdentity.simulatedCamera(systemVersion: systemVersion, appVersion: appVersion)
    }

    /// Nothing better than a guess from a lens model is known yet.
    var wantsRecommendedModel: Bool {
        lock.withLock { source.rawValue < Source.recommended.rawValue }
    }

    /// A camera photo's metadata: its TIFF model is exactly what Apple writes.
    func learn(photoMetadata: [String: Any]) {
        let tiff = photoMetadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        guard let name = tiff?[kCGImagePropertyTIFFModel as String] as? String else { return }
        adopt(name, from: .photo)
    }

    /// A frame's lens model, "iPhone 16 Pro back camera 6.765mm f/1.78": the phone's name comes first.
    func learn(lensModel: String?) {
        guard let lensModel else { return }
        for marker in [" back ", " front "] {
            if let range = lensModel.range(of: marker) {
                adopt(String(lensModel[..<range.lowerBound]), from: .lensModel)
                return
            }
        }
    }

    /// The movie metadata an iOS 26 capture pipeline recommends, read once its session runs.
    func learn(recommendedMetadata items: [AVMetadataItem]) {
        guard let item = items.first(where: { $0.identifier == .quickTimeMetadataModel }) else { return }
        let pending = PendingItem(item: item)
        Task.detached(priority: .utility) {
            guard let name = try? await pending.item.load(.stringValue) else { return }
            self.adopt(name, from: .recommended)
        }
    }

    private func adopt(_ name: String, from newSource: Source) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { return }
        let adopted: Bool = lock.withLock {
            guard newSource.rawValue >= source.rawValue, name != model || newSource != source else { return false }
            model = name
            source = newSource
            return true
        }
        // A guess from a lens model isn't worth keeping past this launch.
        if adopted, newSource.rawValue >= Source.recommended.rawValue {
            defaults.set([machine, name], forKey: Self.savedKey)
        }
    }

    /// "iPhone17,1".
    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Read once on its own task; nothing else touches the item after it is handed over.
    private struct PendingItem: @unchecked Sendable {
        let item: AVMetadataItem
    }
}

// MARK: - What a frame says

/// What one frame's own `{Exif}` says: the exposure the hardware really ran and the lens it came through.
struct FrameExif: Equatable, Sendable {
    var exposureSeconds: Double?
    var iso: Double?
    var fNumber: Double?
    var focalLength: Double?
    var brightness: Double?
    var lensMake: String?
    var lensModel: String?
    var lensSpecification: [Double]?

    init(exif: [String: Any]) {
        exposureSeconds = Self.positive(exif[kCGImagePropertyExifExposureTime as String])
        iso = Self.positive((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first)
        fNumber = Self.positive(exif[kCGImagePropertyExifFNumber as String])
        focalLength = Self.positive(exif[kCGImagePropertyExifFocalLength as String])
        // Negative in the dark, so any finite value counts.
        let brightness = (exif[kCGImagePropertyExifBrightnessValue as String] as? NSNumber)?.doubleValue
        self.brightness = brightness.flatMap { $0.isFinite ? $0 : nil }
        lensMake = Self.text(exif[kCGImagePropertyExifLensMake as String])
        lensModel = Self.text(exif[kCGImagePropertyExifLensModel as String])
        let specification = (exif[kCGImagePropertyExifLensSpecification as String] as? [NSNumber])?.map(\.doubleValue)
        lensSpecification = specification?.count == 4 ? specification : nil
    }

    /// A video frame's `{Exif}` attachment; nil when the frame carries none.
    init?(sampleBuffer: CMSampleBuffer) {
        let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer,
                                                        attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any]
        guard let exif = attachments?[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        self.init(exif: exif)
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

// MARK: - A shot as the backend records it

/// A ShotRecord and where its context came from. The model describes every shot; a request that came without that
/// description gets one built from what the request and the camera know, and its files leave out every setting that
/// would otherwise be a guess.
struct RecordedShot: Sendable {
    var record: ShotRecord
    /// nil when the model described the shot. Otherwise the app's XMP fields the request and the camera vouch for.
    var knownFields: Set<ShotXMP.Field>?

    /// Pictures the app renders: stacks and every simulated photo.
    var rendered: ImageMetadata { limited(ShotMetadataBuilder.rendered(record)) }

    /// What files AVCapturePhotoOutput wrote lack.
    var additions: ImageMetadata { limited(ShotMetadataBuilder.additions(record)) }

    func movie(livePhoto: Bool) -> [MovieMetadataEntry] {
        let entries = ShotMetadataBuilder.movie(record, livePhoto: livePhoto)
        guard let knownFields else { return entries }
        return entries.filter { entry in
            guard case .app(let field) = entry.key else { return true }
            return knownFields.contains(field)
        }
    }

    /// The Photos asset location, through the same gate as every file's GPS.
    var assetLocation: GeoTag? { record.context.taggedLocation }

    /// EXIF keys that state a setting rather than measure the shot.
    private static let settingKeys: [ExifKey] = [.exposureProgram, .exposureMode, .meteringMode, .whiteBalance,
                                                 .lightSource, .exposureBiasValue, .sceneCaptureType]

    private func limited(_ metadata: ImageMetadata) -> ImageMetadata {
        guard let knownFields else { return metadata }
        var result = metadata
        result.xmp = metadata.xmp.filter { knownFields.contains($0.field) }
        for key in Self.settingKeys {
            result.exif.removeValue(forKey: key)
        }
        return result
    }
}

extension RecordedShot {
    /// The context of a photo request: the model's, or what the request says when the model sent none.
    static func context(of request: PhotoRequest, displayZoom: Double) -> (context: ShotContext, knownFields: Set<ShotXMP.Field>?) {
        var described = describe(request.shot, location: request.location, displayZoom: displayZoom) {
            ShotContext(mode: .photo, aspect: request.aspect, processing: request.processing, flash: request.flash,
                        livePhoto: request.livePhoto, displayZoom: displayZoom)
        }
        // An exposure bracket is one request; which photo of it each file is, the camera says as they arrive.
        if request.bracket.kind == .exposure, described.context.bracket == nil {
            described.context.bracket = BracketPosition(kind: .exposure, count: request.bracket.exposureOffsets().count,
                                                        step: request.bracket.step, group: UUID())
        }
        return (described.context, described.isFallback ? photoFields : nil)
    }

    static func context(of request: StackRequest, displayZoom: Double) -> (context: ShotContext, knownFields: Set<ShotXMP.Field>?) {
        let described = describe(request.shot, location: request.location, displayZoom: displayZoom) {
            ShotContext(mode: request.plan.purpose == .night ? .night : .long, aspect: request.aspect,
                        displayZoom: displayZoom)
        }
        return (described.context, described.isFallback ? stackFields : nil)
    }

    static func context(of request: VideoRequest, displayZoom: Double) -> (context: ShotContext, knownFields: Set<ShotXMP.Field>?) {
        var described = describe(request.shot, location: request.location, displayZoom: displayZoom) {
            ShotContext(mode: .video, displayZoom: displayZoom, video: request.settings)
        }
        if described.context.video == nil {
            described.context.video = request.settings
        }
        return (described.context, described.isFallback ? movieFields : nil)
    }

    /// The model's context, or `fallback` built from the request. A context with location tags on but no fix takes
    /// the request's, which came through the same gate in the model. `displayZoom` is the device's at the press,
    /// which beats the model's last reading while a zoom still ramps.
    private static func describe(_ shot: ShotContext?, location: GeoTag?, displayZoom: Double,
                                 fallback: () -> ShotContext) -> (context: ShotContext, isFallback: Bool) {
        guard var context = shot else {
            var context = fallback()
            context.locationTagsOn = location != nil
            context.location = location
            return (context, true)
        }
        if context.locationTagsOn, context.location == nil {
            context.location = location
        }
        if displayZoom.isFinite, displayZoom > 0 {
            context.displayZoom = displayZoom
        }
        return (context, false)
    }

    private static let photoFields: Set<ShotXMP.Field> = [
        .version, .lens, .lensName, .zoom, .zoomFactor, .aspect, .processing, .flash, .livePhoto, .bracket,
        .bracketIndex, .bracketCount, .bracketStep, .bracketValue, .bracketGroup, .osVersion, .simulated,
    ]

    private static let stackFields: Set<ShotXMP.Field> = [
        .version, .lens, .lensName, .zoom, .zoomFactor, .aspect, .blend, .frameSeconds, .frameCount, .framesCaptured,
        .framesPlanned, .lightSeconds, .captureSeconds, .sensorISO, .digitalGain, .aligned, .blurRejection,
        .noiseReduction, .bulb, .osVersion, .simulated,
    ]

    private static let movieFields: Set<ShotXMP.Field> = [
        .version, .lens, .lensName, .zoom, .zoomFactor, .stabilization, .codec, .colorMode, .frameRate, .resolution,
        .audio, .windNoiseReduction, .lowLightNoiseReduction, .simulated,
    ]
}

extension LensRecord {
    /// The lens as the app knows it, at the shot's zoom, with whatever a frame reported about it.
    init(_ lens: LensInfo, zoomFactor: Double, hasFlash: Bool, frame: FrameExif? = nil, make: String = "Apple") {
        self.init(kind: LensKind(rawValue: lens.kind.rawValue) ?? .wide, name: lens.name, make: frame?.lensMake ?? make,
                  model: frame?.lensModel, focalLength: frame?.focalLength,
                  equivalentFocalLength: lens.equivalentFocalLength, zoomFactor: zoomFactor,
                  specification: frame?.lensSpecification, hasFlash: hasFlash)
    }
}
