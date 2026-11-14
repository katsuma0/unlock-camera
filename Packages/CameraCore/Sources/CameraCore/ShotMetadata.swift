import Foundation

// The metadata every file the app saves carries, decided from a ShotRecord. The app maps each key to its ImageIO or
// AVFoundation constant with an exhaustive switch, so the raw values here are documentation and nothing depends on
// ImageIO's own strings matching them.

/// A value in the shapes ImageIO and QuickTime take.
public enum MetadataValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case integer(Int)
    case numbers([Double])
    case integers([Int])
}

/// `{Exif}` keys the builder writes. The raw value is the tag's EXIF name.
public enum ExifKey: String, CaseIterable, Sendable {
    case exposureTime = "ExposureTime"
    case fNumber = "FNumber"
    case exposureProgram = "ExposureProgram"
    case isoSpeedRatings = "ISOSpeedRatings"
    case dateTimeOriginal = "DateTimeOriginal"
    case dateTimeDigitized = "DateTimeDigitized"
    /// Goes with TIFF DateTime.
    case offsetTime = "OffsetTime"
    case offsetTimeOriginal = "OffsetTimeOriginal"
    case offsetTimeDigitized = "OffsetTimeDigitized"
    /// Goes with TIFF DateTime.
    case subsecTime = "SubsecTime"
    case subsecTimeOriginal = "SubsecTimeOriginal"
    case subsecTimeDigitized = "SubsecTimeDigitized"
    case shutterSpeedValue = "ShutterSpeedValue"
    case apertureValue = "ApertureValue"
    case brightnessValue = "BrightnessValue"
    case exposureBiasValue = "ExposureBiasValue"
    case meteringMode = "MeteringMode"
    case lightSource = "LightSource"
    case flash = "Flash"
    case focalLength = "FocalLength"
    case userComment = "UserComment"
    case colorSpace = "ColorSpace"
    case pixelXDimension = "PixelXDimension"
    case pixelYDimension = "PixelYDimension"
    case sensingMethod = "SensingMethod"
    case sceneType = "SceneType"
    case customRendered = "CustomRendered"
    case exposureMode = "ExposureMode"
    case whiteBalance = "WhiteBalance"
    case digitalZoomRatio = "DigitalZoomRatio"
    case focalLenIn35mmFilm = "FocalLenIn35mmFilm"
    case sceneCaptureType = "SceneCaptureType"
    case lensSpecification = "LensSpecification"
    case lensMake = "LensMake"
    case lensModel = "LensModel"
    case compositeImage = "CompositeImage"
    case sourceImageNumberOfCompositeImage = "SourceImageNumberOfCompositeImage"
}

/// `{TIFF}` keys the builder writes. EXIF's Artist and Copyright tags live here in ImageIO.
public enum TIFFKey: String, CaseIterable, Sendable {
    case make = "Make"
    case model = "Model"
    case software = "Software"
    case dateTime = "DateTime"
    case hostComputer = "HostComputer"
    /// The app also sets the top-level orientation to the same value.
    case orientation = "Orientation"
    case artist = "Artist"
    case copyright = "Copyright"
}

/// `{GPS}` keys the builder writes.
public enum GPSKey: String, CaseIterable, Sendable {
    case latitude = "Latitude"
    case latitudeRef = "LatitudeRef"
    case longitude = "Longitude"
    case longitudeRef = "LongitudeRef"
    case altitude = "Altitude"
    case altitudeRef = "AltitudeRef"
    case timeStamp = "TimeStamp"
    case dateStamp = "DateStamp"
    case speed = "Speed"
    case speedRef = "SpeedRef"
    /// The direction the phone was moving.
    case track = "Track"
    case trackRef = "TrackRef"
    /// The direction the camera faced.
    case imgDirection = "ImgDirection"
    case imgDirectionRef = "ImgDirectionRef"
    case destBearing = "DestBearing"
    case destBearingRef = "DestBearingRef"
    case hPositioningError = "HPositioningError"
}

/// `{IPTC}` keys the builder writes.
public enum IPTCKey: String, CaseIterable, Sendable {
    case originatingProgram = "OriginatingProgram"
    case programVersion = "ProgramVersion"
}

/// The app's own XMP namespace. Never change the URI or the field names once shipped: readers find them by these.
public enum ShotXMP {
    public static let namespace = "http://ns.katsuma.ca/openshutter/1.0/"
    public static let prefix = "openshutter"
    /// Movies carry the same fields as QuickTime keys "ca.katsuma.openshutter.<Field>".
    public static let quickTimeKeyPrefix = "ca.katsuma.openshutter."
    /// The Version field's value. Raise it only when a field changes meaning.
    public static let version = "1"

    /// In the order files list them. Values are C-locale strings, "True" or "False", or raw values that stay put
    /// when the interface renames something.
    public enum Field: String, CaseIterable, Sendable {
        case version = "Version"
        case mode = "Mode"
        case interface = "Interface"
        case scene = "Scene"
        case exposureControl = "ExposureControl"
        case bias = "Bias"
        case aeLock = "AELock"
        case meteringArea = "MeteringArea"
        case whiteBalance = "WhiteBalance"
        case whiteBalanceFromScene = "WhiteBalanceFromScene"
        case kelvin = "Kelvin"
        case tint = "Tint"
        case focus = "Focus"
        case lensPosition = "LensPosition"
        case lens = "Lens"
        case lensName = "LensName"
        case zoom = "Zoom"
        case zoomFactor = "ZoomFactor"
        case aspect = "Aspect"
        case processing = "Processing"
        case flash = "Flash"
        case livePhoto = "LivePhoto"
        case timer = "Timer"
        case intervalShot = "IntervalShot"
        case intervalCount = "IntervalCount"
        case bracket = "Bracket"
        case bracketIndex = "BracketIndex"
        case bracketCount = "BracketCount"
        case bracketStep = "BracketStep"
        case bracketValue = "BracketValue"
        case bracketGroup = "BracketGroup"
        case blend = "Blend"
        case frameSeconds = "FrameSeconds"
        case frameCount = "FrameCount"
        case framesCaptured = "FramesCaptured"
        case framesPlanned = "FramesPlanned"
        case lightSeconds = "LightSeconds"
        case captureSeconds = "CaptureSeconds"
        case sensorISO = "SensorISO"
        case digitalGain = "DigitalGain"
        case aligned = "Aligned"
        case blurRejection = "BlurRejection"
        case noiseReduction = "NoiseReduction"
        case bulb = "Bulb"
        case stability = "Stability"
        case steadyAtStart = "SteadyAtStart"
        case stabilization = "Stabilization"
        case codec = "Codec"
        case colorMode = "ColorMode"
        case frameRate = "FrameRate"
        case resolution = "Resolution"
        case audio = "Audio"
        case windNoiseReduction = "WindNoiseReduction"
        case lowLightNoiseReduction = "LowLightNoiseReduction"
        case osVersion = "OSVersion"
        case simulated = "Simulated"

        /// "openshutter:Mode", the path ImageIO's XMP functions take once the namespace is registered.
        public var path: String { ShotXMP.prefix + ":" + rawValue }
        /// "ca.katsuma.openshutter.Mode".
        public var quickTimeKey: String { ShotXMP.quickTimeKeyPrefix + rawValue }
    }

    public struct Entry: Equatable, Sendable {
        public var field: Field
        public var value: String

        public init(field: Field, value: String) {
            self.field = field
            self.value = value
        }
    }

    /// A stack's time as the gallery and the photo info tool show it: "30s, 900 frames of 1/30". EXIF's
    /// ExposureTime holds one frame's time for Blur, Trails and NIGHT, so the duration comes from these fields.
    /// nil without a frame count.
    public static func stackSummary(_ values: [Field: String]) -> String? {
        guard let countText = values[.frameCount], let count = Int(countText), count > 0 else { return nil }
        let frame = values[.frameSeconds].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let duration = Double(count) * Swift.max(frame ?? 0, ShotMetadataBuilder.minimumFrameInterval)
        var text = Formatting.compactDuration(duration) + ", \(count) " + (count == 1 ? "frame" : "frames")
        if let frame { text += " of " + ShutterSpeed(seconds: frame).label }
        return text
    }
}

/// Image metadata for one file, as typed fields.
public struct ImageMetadata: Equatable, Sendable {
    public var exif: [ExifKey: MetadataValue]
    public var tiff: [TIFFKey: MetadataValue]
    /// Empty unless location tags are on and a fix exists.
    public var gps: [GPSKey: MetadataValue]
    public var iptc: [IPTCKey: MetadataValue]
    /// The app's XMP fields, in Field order.
    public var xmp: [ShotXMP.Entry]
    /// xmp:CreatorTool, "Open Shutter 1.0".
    public var creatorTool: String
    /// XMP dc:creator (one name, from "Your name"); nil when empty.
    public var creator: String?
    /// XMP dc:rights (from "Copyright"); nil when empty.
    public var rights: String?

    public init(exif: [ExifKey: MetadataValue] = [:], tiff: [TIFFKey: MetadataValue] = [:],
                gps: [GPSKey: MetadataValue] = [:], iptc: [IPTCKey: MetadataValue] = [:], xmp: [ShotXMP.Entry] = [],
                creatorTool: String, creator: String? = nil, rights: String? = nil) {
        self.exif = exif
        self.tiff = tiff
        self.gps = gps
        self.iptc = iptc
        self.xmp = xmp
        self.creatorTool = creatorTool
        self.creator = creator
        self.rights = rights
    }

    /// The value of one of the app's XMP fields, if the file has it.
    public func xmpValue(_ field: ShotXMP.Field) -> String? {
        xmp.first { $0.field == field }?.value
    }
}

/// Movie-level QuickTime metadata keys.
public enum MovieKey: Hashable, Sendable {
    case make, model, software, creationDate, locationISO6709, locationHorizontalAccuracy, fullFrameRatePlaybackIntent
    /// iOS 26 identifiers; the app drops them on older systems.
    case cameraISOSensitivity, cameraWhiteBalance, cameraShutterSpeedTime, cameraShutterSpeedAngle
    /// "Your name" and "Copyright" from Settings (com.apple.quicktime.author and .copyright).
    case author, copyright
    /// "ca.katsuma.openshutter.<Field>", the same vocabulary as the XMP.
    case app(ShotXMP.Field)
}

public struct MovieMetadataEntry: Equatable, Sendable {
    public var key: MovieKey
    public var value: MetadataValue

    public init(key: MovieKey, value: MetadataValue) {
        self.key = key
        self.value = value
    }
}

/// Decides every metadata field from a ShotRecord.
public enum ShotMetadataBuilder {
    /// Frames shorter than this still arrive one preview frame apart, so a stack's time counts each as this long:
    /// the planner's own measure (StackPlan.estimatedDuration).
    static let minimumFrameInterval = 1.0 / 30.0

    /// Pictures the app renders (stacks, the simulated camera): the full set.
    public static func rendered(_ record: ShotRecord) -> ImageMetadata {
        let context = record.context
        let device = record.device
        let lens = record.lens
        var exif: [ExifKey: MetadataValue] = [:]
        var tiff: [TIFFKey: MetadataValue] = [:]

        // Who made the file. The simulated camera names no host phone: its model is not a phone's.
        if let make = nonEmpty(device.make) {
            tiff[.make] = .text(make)
        }
        if let model = nonEmpty(device.model) {
            tiff[.model] = .text(model)
            if !device.isSimulated {
                tiff[.hostComputer] = .text(model)
            }
        }
        // The app made these pixels, so Software names it; the system version goes into the XMP instead.
        tiff[.software] = .text(device.appSignature)
        // Rendered pictures are drawn upright.
        tiff[.orientation] = .integer(1)
        addOwner(context, to: &tiff)

        // When. A stack was taken when its first frame was, however long it ran.
        tiff[.dateTime] = .text(ExifFormat.exifDate(record.writtenDate, timeZone: record.timeZone))
        exif[.subsecTime] = .text(ExifFormat.subseconds(record.writtenDate))
        exif[.offsetTime] = .text(ExifFormat.offset(record.writtenDate, timeZone: record.timeZone))
        exif[.dateTimeOriginal] = .text(ExifFormat.exifDate(record.date, timeZone: record.timeZone))
        exif[.subsecTimeOriginal] = .text(ExifFormat.subseconds(record.date))
        exif[.offsetTimeOriginal] = .text(ExifFormat.offset(record.date, timeZone: record.timeZone))
        let lastFrame = record.endDate ?? record.date
        exif[.dateTimeDigitized] = .text(ExifFormat.exifDate(lastFrame, timeZone: record.timeZone))
        exif[.subsecTimeDigitized] = .text(ExifFormat.subseconds(lastFrame))
        exif[.offsetTimeDigitized] = .text(ExifFormat.offset(lastFrame, timeZone: record.timeZone))

        // The lens. Photos names a lens from Apple's model string; the device name is the fallback.
        let lensMake = device.isSimulated ? device.make : trimmed(lens.make)
        if !lensMake.isEmpty {
            exif[.lensMake] = .text(lensMake)
        }
        if let model = nonEmpty(lens.model ?? "") ?? nonEmpty(lens.name) {
            exif[.lensModel] = .text(model)
        }
        if let specification = lens.specification, specification.count == 4,
           specification.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            exif[.lensSpecification] = .numbers(specification)
        }
        if let focalLength = lens.focalLength, ExifFormat.isPositive(focalLength) {
            exif[.focalLength] = .number(focalLength)
        }
        let zoom = zoomFactor(lens)
        if ExifFormat.isPositive(lens.equivalentFocalLength) {
            exif[.focalLenIn35mmFilm] = .integer(short(lens.equivalentFocalLength * zoom, minimum: 1))
        }
        if zoom > 1.001 {
            exif[.digitalZoomRatio] = .number(zoom)
        }

        // The exposure.
        if let seconds = exposureSeconds(record) {
            exif[.exposureTime] = .number(seconds)
            if let value = ExifFormat.shutterSpeedValue(seconds: seconds) {
                exif[.shutterSpeedValue] = .number(value)
            }
        }
        let aperture = record.exposure.aperture
        if ExifFormat.isPositive(aperture) {
            exif[.fNumber] = .number(aperture)
            if let value = ExifFormat.apertureValue(fNumber: aperture) {
                exif[.apertureValue] = .number(value)
            }
        }
        if let iso = isoSpeed(record) {
            exif[.isoSpeedRatings] = .integers([iso])
        }
        if context.bias.isFinite {
            exif[.exposureBiasValue] = .number(context.bias == 0 ? 0 : context.bias)
        }
        exif[.exposureProgram] = .integer(context.exposureControl.exifProgram)
        exif[.exposureMode] = .integer(context.exposureControl.exifMode)
        exif[.meteringMode] = .integer(meteringMode(context.meteringArea))
        exif[.whiteBalance] = .integer(context.whiteBalance.isAuto ? 0 : 1)
        if let source = lightSource(context.whiteBalance) {
            exif[.lightSource] = .integer(source)
        }
        // Nothing the app renders fires a flash: 16 is "off, did not fire", 32 "no flash function".
        exif[.flash] = .integer(lens.hasFlash ? 16 : 32)
        if let value = brightness(record) {
            exif[.brightnessValue] = .number(value)
        }

        // How the picture was made. The simulated camera has no sensor to describe.
        if !device.isSimulated {
            exif[.sensingMethod] = .integer(2)
            exif[.sceneType] = .integer(1)
        }
        exif[.customRendered] = .integer(1)
        exif[.sceneCaptureType] = .integer(sceneCaptureType(context))
        exif[.colorSpace] = .integer(record.isSRGB ? 1 : 65535)
        if let width = record.pixelWidth, let height = record.pixelHeight, width > 0, height > 0 {
            exif[.pixelXDimension] = .integer(width)
            exif[.pixelYDimension] = .integer(height)
        }
        if let stack = record.stack {
            if stack.framesUsed > 1 {
                // 3 is "composite image captured while shooting". A two hour bulb at 30 fps is 216,000 frames,
                // past what the tag's SHORT values hold.
                exif[.compositeImage] = .integer(3)
                exif[.sourceImageNumberOfCompositeImage] = .integers([
                    short(Double(Swift.max(stack.framesSeen, stack.framesUsed)), minimum: 0),
                    short(Double(stack.framesUsed), minimum: 0),
                ])
            } else {
                exif[.compositeImage] = .integer(1)
            }
        }
        exif[.userComment] = .text(comment(record))

        return ImageMetadata(exif: exif, tiff: tiff, gps: gps(record), iptc: iptc(device),
                             xmp: xmpEntries(record, movie: false), creatorTool: device.appSignature,
                             creator: nonEmpty(context.artist), rights: nonEmpty(context.copyright))
    }

    /// Files AVCapturePhotoOutput wrote (single, cropped, RAW, Live still, every bracket frame): only what they
    /// lack. Never contains a key the camera writes, so merging it in can't replace what the hardware recorded.
    public static func additions(_ record: ShotRecord) -> ImageMetadata {
        let context = record.context
        var exif: [ExifKey: MetadataValue] = [.userComment: .text(comment(record))]
        if let source = lightSource(context.whiteBalance) {
            exif[.lightSource] = .integer(source)
        }
        var tiff: [TIFFKey: MetadataValue] = [:]
        addOwner(context, to: &tiff)
        return ImageMetadata(exif: exif, tiff: tiff, gps: gps(record), iptc: iptc(record.device),
                             xmp: xmpEntries(record, movie: false), creatorTool: record.device.appSignature,
                             creator: nonEmpty(context.artist), rights: nonEmpty(context.copyright))
    }

    /// Movie-level items for a recording or a simulated movie, or (`livePhoto`) a Live Photo's movie, which keeps
    /// only the location, the owner and the app's Mode and Version: the photo output writes the rest of that movie.
    public static func movie(_ record: ShotRecord, livePhoto: Bool) -> [MovieMetadataEntry] {
        let context = record.context
        let device = record.device
        var entries: [MovieMetadataEntry] = []
        func add(_ key: MovieKey, _ value: MetadataValue) {
            entries.append(MovieMetadataEntry(key: key, value: value))
        }
        func addText(_ key: MovieKey, _ text: String) {
            if let value = nonEmpty(text) { add(key, .text(value)) }
        }

        if !livePhoto {
            addText(.make, device.make)
            addText(.model, device.model)
            // Apple's Camera writes the system version here, not the app.
            addText(.software, device.systemVersion)
            addText(.creationDate, ExifFormat.quickTimeDate(record.date, timeZone: record.timeZone))
        }
        if let geo = context.taggedLocation, let place = ExifFormat.iso6709(geo) {
            add(.locationISO6709, .text(place))
            if geo.horizontalAccuracy.isFinite, geo.horizontalAccuracy >= 0 {
                add(.locationHorizontalAccuracy, .number(geo.horizontalAccuracy))
            }
        }
        if !livePhoto, let video = context.video {
            // VIDEO is not a slow motion mode: a 120 fps clip plays at normal speed.
            if video.frameRate.isFinite, video.frameRate >= 100 {
                add(.fullFrameRatePlaybackIntent, .integer(1))
            }
            // Only a value that stayed fixed for the whole recording: an auto value would be one moment of a
            // changing exposure.
            let control = context.exposureControl
            if control.fixesISO, ExifFormat.isPositive(record.exposure.iso) {
                add(.cameraISOSensitivity, .text(ISOScale.compactLabel(record.exposure.iso)))
            }
            if !context.whiteBalance.isAuto, let kelvin = context.whiteBalance.kelvinValue,
               ExifFormat.isPositive(kelvin) {
                add(.cameraWhiteBalance, .text(ExifFormat.decimal(kelvin.rounded(), maxDecimals: 0) + "K"))
            }
            if control.fixesShutter, ExifFormat.isPositive(record.exposure.seconds) {
                add(.cameraShutterSpeedTime, .text(ExifFormat.decimal(record.exposure.seconds)))
                let angle = ExposureMath.shutterAngle(seconds: record.exposure.seconds, fps: video.frameRate)
                if angle > 0 {
                    add(.cameraShutterSpeedAngle, .text(ExifFormat.fixed(angle, decimals: 2) + "deg"))
                }
            }
        }
        addText(.author, context.artist)
        addText(.copyright, context.copyright)

        let fields: [ShotXMP.Entry]
        if livePhoto {
            fields = [ShotXMP.Entry(field: .version, value: ShotXMP.version),
                      ShotXMP.Entry(field: .mode, value: context.mode.rawValue)]
        } else {
            fields = xmpEntries(record, movie: true)
        }
        for entry in fields {
            add(.app(entry.field), .text(entry.value))
        }
        return entries
    }

    /// The readable line that goes into EXIF UserComment: plain ASCII sentences, so every reader shows it.
    /// "Night mode, 3s from 36 frames of 1/12 at ISO 640, brightened 1.4x. Handheld. Taken with Open Shutter 1.0."
    public static func comment(_ record: ShotRecord) -> String {
        let context = record.context
        var sentences = [leadSentence(record)]
        if let bracket = context.bracket, let sentence = bracketSentence(bracket) {
            sentences.append(sentence)
        }
        if let interval = context.interval, interval.index > 0, interval.count > 0 {
            sentences.append("Shot \(interval.index) of \(interval.count).")
        }
        if holdsStill(record), let stability = context.stability {
            switch stability {
            case .handheld: sentences.append("Handheld.")
            case .steady: sentences.append("Steady.")
            case .tripod: sentences.append("On a tripod.")
            }
        }
        if record.device.isSimulated {
            sentences.append("Simulated camera.")
        }
        sentences.append("Taken with " + record.device.appSignature + ".")
        return sentences.joined(separator: " ")
    }

    // MARK: - Location

    /// The `{GPS}` fields, through the one location gate.
    static func gps(_ record: ShotRecord) -> [GPSKey: MetadataValue] {
        guard let geo = record.context.taggedLocation else { return [:] }
        var gps: [GPSKey: MetadataValue] = [
            .latitude: .number(abs(geo.latitude)),
            .latitudeRef: .text(geo.latitude < 0 ? "S" : "N"),
            .longitude: .number(abs(geo.longitude)),
            .longitudeRef: .text(geo.longitude < 0 ? "W" : "E"),
            // GPS stamps are UTC by definition: the fix's own time.
            .dateStamp: .text(ExifFormat.gpsDateStamp(geo.timestamp)),
            .timeStamp: .text(ExifFormat.gpsTimeStamp(geo.timestamp)),
        ]
        if geo.hasValidAltitude {
            gps[.altitude] = .number(abs(geo.altitude))
            gps[.altitudeRef] = .integer(geo.altitude < 0 ? 1 : 0)
        }
        if geo.horizontalAccuracy.isFinite, geo.horizontalAccuracy >= 0 {
            gps[.hPositioningError] = .number(geo.horizontalAccuracy)
        }
        if let speed = geo.speed, speed.isFinite, speed >= 0 {
            gps[.speed] = .number(speed * 3.6)
            gps[.speedRef] = .text("K")
        }
        if let course = geo.course.flatMap(compassDegrees) {
            // Core Location measures course from true north.
            gps[.track] = .number(course)
            gps[.trackRef] = .text("T")
        }
        if let heading = geo.heading, heading.isFinite,
           let facing = compassDegrees(record.lens.kind.isFront ? heading + 180 : heading) {
            // The heading is where the back of the phone points; the front camera looks the other way.
            let reference = geo.headingIsTrueNorth ? "T" : "M"
            gps[.imgDirection] = .number(facing)
            gps[.imgDirectionRef] = .text(reference)
            gps[.destBearing] = .number(facing)
            gps[.destBearingRef] = .text(reference)
        }
        return gps
    }

    /// 0 ..< 360; nil when not a number.
    static func compassDegrees(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        var degrees = value.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        // A sliver below zero plus 360 rounds to 360, which is north again.
        return degrees >= 360 ? 0 : degrees
    }

    // MARK: - XMP

    /// The app's fields, in Field order. Never anything about location: that stays behind the location switch.
    static func xmpEntries(_ record: ShotRecord, movie: Bool) -> [ShotXMP.Entry] {
        let context = record.context
        let lens = record.lens
        var values: [ShotXMP.Field: String] = [:]

        values[.version] = ShotXMP.version
        values[.mode] = context.mode.rawValue
        values[.interface] = context.advanced ? "advanced" : "simple"
        if context.mode == .long, let scene = context.scene {
            values[.scene] = scene.rawValue
        }
        values[.exposureControl] = context.exposureControl.rawValue
        if context.bias.isFinite {
            values[.bias] = ExifFormat.decimal(context.bias)
        }
        if context.aeLocked {
            values[.aeLock] = "True"
        }
        values[.meteringArea] = context.meteringArea.rawValue
        values[.whiteBalance] = whiteBalanceName(context.whiteBalance)
        if context.whiteBalanceFromScene {
            values[.whiteBalanceFromScene] = "True"
        }
        if let kelvin = context.kelvin, ExifFormat.isPositive(kelvin) {
            values[.kelvin] = ExifFormat.decimal(kelvin, maxDecimals: 0)
        }
        if let tint = context.tint, tint.isFinite {
            values[.tint] = ExifFormat.decimal(tint, maxDecimals: 1)
        }
        values[.focus] = focusName(context)
        if let position = context.lensPosition, position.isFinite {
            values[.lensPosition] = ExifFormat.decimal(Swift.min(Swift.max(position, 0), 1))
        }
        values[.lens] = lens.kind.rawValue
        if let name = nonEmpty(lens.name) {
            values[.lensName] = name
        }
        if ExifFormat.isPositive(context.displayZoom) {
            values[.zoom] = ExifFormat.decimal(context.displayZoom)
        }
        values[.zoomFactor] = ExifFormat.decimal(zoomFactor(lens))

        let isVideo = context.mode == .video
        if !movie, !isVideo {
            values[.aspect] = context.aspect.label
        }
        // What the photo output was asked for means nothing for a stack or a movie.
        if !movie, !isVideo, record.stack == nil {
            if let processing = context.processing {
                values[.processing] = processing.rawValue
            }
            if let flash = context.flash {
                values[.flash] = flash.rawValue
            }
            if context.livePhoto {
                values[.livePhoto] = "True"
            }
        }
        if let timer = context.timerSeconds, ExifFormat.isPositive(timer) {
            values[.timer] = ExifFormat.decimal(timer)
        }
        if let interval = context.interval, interval.index > 0, interval.count > 0 {
            values[.intervalShot] = String(interval.index)
            values[.intervalCount] = String(interval.count)
        }
        if !movie, let bracket = context.bracket, bracket.kind != .off {
            values[.bracket] = bracket.kind.rawValue
            if let index = bracket.index, index > 0 {
                values[.bracketIndex] = String(index)
            }
            if bracket.count > 0 {
                values[.bracketCount] = String(bracket.count)
            }
            // Every bracket steps by something; 0 is a step nobody passed.
            if ExifFormat.isPositive(bracket.step) {
                values[.bracketStep] = ExifFormat.decimal(bracket.step)
            }
            if let value = bracket.value, value.isFinite {
                values[.bracketValue] = ExifFormat.decimal(value, maxDecimals: bracket.kind == .whiteBalance ? 0 : 6)
            }
            values[.bracketGroup] = bracket.group.uuidString
        }
        if !movie, let stack = record.stack {
            let used = Swift.max(stack.framesUsed, 0)
            let frame = frameSeconds(record)
            values[.blend] = stack.blend.rawValue
            if let frame {
                values[.frameSeconds] = ExifFormat.decimal(frame)
                values[.lightSeconds] = ExifFormat.decimal(Double(used) * frame)
            }
            values[.frameCount] = String(used)
            values[.framesCaptured] = String(Swift.max(stack.framesSeen, used))
            values[.framesPlanned] = String(Swift.max(stack.framesPlanned, 0))
            if let seconds = captureSeconds(record) {
                values[.captureSeconds] = ExifFormat.decimal(seconds, maxDecimals: 3)
            }
            if let iso = frameISO(record) {
                values[.sensorISO] = ExifFormat.decimal(iso, maxDecimals: 1)
            }
            if stack.digitalGain.isFinite, stack.purpose == .night || stack.digitalGain != 1 {
                values[.digitalGain] = ExifFormat.decimal(stack.digitalGain, maxDecimals: 3)
            }
            values[.aligned] = stack.aligned ? "True" : "False"
            values[.blurRejection] = stack.rejectBlurry ? "True" : "False"
            if let amount = stack.noiseReduction, amount.isFinite {
                values[.noiseReduction] = ExifFormat.decimal(Swift.min(Swift.max(amount, 0), 1), maxDecimals: 3)
            }
            if stack.bulb {
                values[.bulb] = "True"
            }
        }
        if holdsStill(record) {
            if let stability = context.stability {
                values[.stability] = stability.rawValue
            }
            if let steady = context.steadyAtStart {
                values[.steadyAtStart] = steady ? "True" : "False"
            }
        }
        if movie, let video = context.video {
            values[.stabilization] = video.stabilization.rawValue
            values[.codec] = video.codec.rawValue
            values[.colorMode] = video.colorMode.rawValue
            if ExifFormat.isPositive(video.frameRate) {
                values[.frameRate] = ExifFormat.decimal(video.frameRate, maxDecimals: 3)
            }
            values[.resolution] = video.resolution.rawValue
            values[.audio] = video.audio ? "True" : "False"
            values[.windNoiseReduction] = video.windNoiseReduction ? "True" : "False"
            values[.lowLightNoiseReduction] = video.lowLightNoiseReduction ? "True" : "False"
        }
        // TIFF Software names the app in a rendered file, so the system version needs a place of its own.
        if !movie, record.source == .rendered, let version = nonEmpty(record.device.systemVersion) {
            values[.osVersion] = version
        }
        if record.device.isSimulated {
            values[.simulated] = "True"
        }
        return ShotXMP.Field.allCases.compactMap { field in
            values[field].map { ShotXMP.Entry(field: field, value: $0) }
        }
    }

    /// NIGHT, LONG and any stack: the shots that ask the phone to hold still, so how steady it was belongs in the
    /// file. A photo or a movie carries none of it, whatever the context says.
    static func holdsStill(_ record: ShotRecord) -> Bool {
        record.context.mode == .night || record.context.mode == .long || record.stack != nil
    }

    static func whiteBalanceName(_ whiteBalance: WhiteBalanceSetting) -> String {
        switch whiteBalance {
        case .auto: return "auto"
        case .preset(let preset): return preset.rawValue
        case .kelvin: return "kelvin"
        }
    }

    /// auto, manual, held (a long press), infinity (a scene that focuses on the sky).
    static func focusName(_ context: ShotContext) -> String {
        if case .manual = context.focus {
            return context.focusFromScene ? "infinity" : "manual"
        }
        return context.focusHeld ? "held" : "auto"
    }

    // MARK: - EXIF values

    /// MeteringMode: 5 pattern, 3 spot, 1 average.
    static func meteringMode(_ area: MeteringArea) -> Int {
        switch area {
        case .automatic: return 5
        case .spot: return 3
        case .wholeFrame: return 1
        }
    }

    /// LightSource for a named preset; nil for auto and a Kelvin value, which name no light.
    static func lightSource(_ whiteBalance: WhiteBalanceSetting) -> Int? {
        guard case .preset(let preset) = whiteBalance else { return nil }
        switch preset {
        case .auto: return nil
        case .daylight: return 1
        case .fluorescent: return 2
        case .tungsten: return 3
        case .flash: return 4
        case .cloudy: return 10
        case .shade: return 11
        // EXIF has no candle; 255 is "other light source".
        case .candle: return 255
        }
    }

    /// SceneCaptureType: 3 (night scene) for NIGHT and for the LONG scenes shot at the night sky, 0 otherwise.
    static func sceneCaptureType(_ context: ShotContext) -> Int {
        switch context.mode {
        case .night: return 3
        case .long: return context.scene?.recipe?.focusAtInfinity == true ? 3 : 0
        case .photo, .manual, .video: return 0
        }
    }

    /// One frame's shutter: the frame's own reading, else the plan's.
    static func frameSeconds(_ record: ShotRecord) -> Double? {
        if ExifFormat.isPositive(record.exposure.seconds) { return record.exposure.seconds }
        if let planned = record.stack?.frameSeconds, ExifFormat.isPositive(planned) { return planned }
        return nil
    }

    /// One frame's ISO: the frame's own reading, else the plan's.
    static func frameISO(_ record: ShotRecord) -> Double? {
        if ExifFormat.isPositive(record.exposure.iso) { return record.exposure.iso }
        if let planned = record.stack?.sensorISO, ExifFormat.isPositive(planned) { return planned }
        return nil
    }

    /// ExposureTime is light time, the exposure that with FNumber and ISO gives the picture's brightness. Real adds
    /// its frames' light, so it is every frame's time together, exactly what one long shutter would record. Blur,
    /// Trails and NIGHT keep one frame's brightness, so they record one frame's time; the duration goes into the
    /// composite tags, the XMP and the comment.
    static func exposureSeconds(_ record: ShotRecord) -> Double? {
        guard let frame = frameSeconds(record) else { return nil }
        guard let stack = record.stack, stack.blend == .additive else { return frame }
        return frame * Double(Swift.max(stack.framesUsed, 1))
    }

    /// The sensitivity the picture's brightness corresponds to: a frame's ISO times NIGHT's digital gain, as
    /// cameras record a pushed ISO. EXIF holds 16 bits.
    static func isoSpeed(_ record: ShotRecord) -> Int? {
        guard let iso = frameISO(record) else { return nil }
        var value = iso
        if let gain = record.stack?.digitalGain, ExifFormat.isPositive(gain) {
            value *= gain
        }
        return short(value, minimum: 1)
    }

    /// The camera's own reading, else one worked out from what auto exposure wanted.
    static func brightness(_ record: ShotRecord) -> Double? {
        if let reported = record.brightness, reported.isFinite {
            return reported == 0 ? 0 : reported
        }
        guard let product = record.context.meteredProduct else { return nil }
        return ExifFormat.brightnessValue(lightProduct: product)
    }

    static func captureSeconds(_ record: ShotRecord) -> Double? {
        if let measured = record.stack?.captureSeconds, measured.isFinite, measured >= 0 { return measured }
        guard let end = record.endDate else { return nil }
        let seconds = end.timeIntervalSince(record.date)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    static func zoomFactor(_ lens: LensRecord) -> Double {
        ExifFormat.isPositive(lens.zoomFactor) ? lens.zoomFactor : 1
    }

    // MARK: - Comment

    static func leadSentence(_ record: ShotRecord) -> String {
        let context = record.context
        guard let stack = record.stack else {
            switch context.mode {
            case .photo: return "Photo."
            case .night: return "Night mode."
            case .long: return "Long exposure."
            case .manual: return "Manual exposure."
            case .video: return "Video."
            }
        }
        let details = stackDetails(record, stack)
        switch context.mode {
        case .night:
            // NIGHT averages its frames, but calling it Blur would describe a LONG blend it never offered.
            var text = "Night mode, " + details
            if let gain = brightening(stack.digitalGain) {
                text += ", brightened " + gain + "x"
            }
            return text + "."
        case .long:
            var parts = ["Long exposure"]
            if let scene = context.scene, scene != .custom {
                parts.append(scene.title)
            }
            parts.append(details)
            parts.append(stack.blend.title)
            return parts.joined(separator: ", ") + "."
        case .manual:
            return "Manual exposure, " + details + "."
        case .photo, .video:
            return "Stacked, " + details + ", " + stack.blend.title + "."
        }
    }

    /// "3s from 36 frames of 1/12 at ISO 640".
    static func stackDetails(_ record: ShotRecord, _ stack: StackRecord) -> String {
        let used = Swift.max(stack.framesUsed, 0)
        let frame = frameSeconds(record)
        let duration = Double(used) * Swift.max(frame ?? 0, minimumFrameInterval)
        var text = Formatting.compactDuration(duration) + " from \(used) " + (used == 1 ? "frame" : "frames")
        if let frame {
            text += " of " + ShutterSpeed(seconds: frame).label
        }
        if let iso = frameISO(record) {
            text += " at " + ISOScale.label(iso)
        }
        return text
    }

    /// "1.4" for a gain worth mentioning, to a tenth; nil when it rounds to no brightening at all.
    static func brightening(_ gain: Double) -> String? {
        guard gain.isFinite else { return nil }
        let tenths = (gain * 10).rounded() / 10
        guard tenths > 1 else { return nil }
        return ExifFormat.decimal(tenths, maxDecimals: 1)
    }

    /// "Exposure bracket, photo 2 of 5, -1 EV.", "Focus bracket, photo 3 of 10.", "White balance bracket, photo 1
    /// of 3, 4800K."
    static func bracketSentence(_ bracket: BracketPosition) -> String? {
        var parts: [String]
        switch bracket.kind {
        case .off: return nil
        case .exposure: parts = ["Exposure bracket"]
        case .focus: parts = ["Focus bracket"]
        case .whiteBalance: parts = ["White balance bracket"]
        }
        if let index = bracket.index, index > 0, bracket.count > 0 {
            parts.append("photo \(index) of \(bracket.count)")
        } else if bracket.count > 0 {
            parts.append("\(bracket.count) photos")
        }
        if let value = bracket.value, value.isFinite {
            switch bracket.kind {
            case .exposure: parts.append(EVFormat.label(value) + " EV")
            case .whiteBalance: parts.append(Formatting.kelvin(value))
            case .focus, .off: break
            }
        }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Helpers

    static func iptc(_ device: DeviceIdentity) -> [IPTCKey: MetadataValue] {
        var iptc: [IPTCKey: MetadataValue] = [.originatingProgram: .text(DeviceIdentity.appName)]
        if let version = nonEmpty(device.appVersion) {
            iptc[.programVersion] = .text(version)
        }
        return iptc
    }

    /// TIFF Artist and Copyright, only when Settings has them.
    static func addOwner(_ context: ShotContext, to tiff: inout [TIFFKey: MetadataValue]) {
        if let artist = nonEmpty(context.artist) {
            tiff[.artist] = .text(artist)
        }
        if let copyright = nonEmpty(context.copyright) {
            tiff[.copyright] = .text(copyright)
        }
    }

    /// Rounded into EXIF's 16-bit SHORT range.
    static func short(_ value: Double, minimum: Int) -> Int {
        guard !value.isNaN else { return minimum }
        return Int(Swift.min(Swift.max(value.rounded(), Double(minimum)), 65535))
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text without surrounding spaces, or nil when nothing is left.
    static func nonEmpty(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}
