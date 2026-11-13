import Foundation

// What one capture was, in plain values. The camera layer fills these in; ShotMetadataBuilder turns them into the
// EXIF, TIFF, GPS, IPTC, XMP and QuickTime fields every file carries, so what a file says is decided in one tested
// place and the writers only write.

/// A GPS fix as it goes into a file. What the fix doesn't have is nil, or a negative accuracy.
public struct GeoTag: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level. Core Location reports 0 when it has no altitude, so it is written only while
    /// `verticalAccuracy` is 0 or more.
    public var altitude: Double
    /// Metres; negative when unknown.
    public var horizontalAccuracy: Double
    public var timestamp: Date
    /// Metres; negative when the altitude is unknown.
    public var verticalAccuracy: Double
    /// Metres per second; nil when the fix has no valid speed.
    public var speed: Double?
    /// Degrees clockwise from true north the phone is moving toward; nil when unknown.
    public var course: Double?
    /// Degrees clockwise from north that the back of the phone faces, as Core Location reports it for a phone held
    /// upright; nil when unknown. The builder turns it around for the front camera, so the provider must not.
    public var heading: Double?
    /// The heading is measured from true north; false means magnetic north.
    public var headingIsTrueNorth: Bool

    /// The first five arguments are the old LocationStamp's, in its order, so code written for it keeps compiling.
    /// A fix made that way has no altitude until the caller passes its vertical accuracy.
    public init(latitude: Double, longitude: Double, altitude: Double, horizontalAccuracy: Double, timestamp: Date,
                verticalAccuracy: Double = -1, speed: Double? = nil, course: Double? = nil, heading: Double? = nil,
                headingIsTrueNorth: Bool = true) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.heading = heading
        self.headingIsTrueNorth = headingIsTrueNorth
    }

    /// Latitude and longitude are numbers on the globe. Anything else would put a file in the wrong place.
    public var hasValidCoordinates: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    /// The altitude means something.
    public var hasValidAltitude: Bool {
        altitude.isFinite && verticalAccuracy.isFinite && verticalAccuracy >= 0
    }
}

/// Who made a file: the phone, its system and the app.
public struct DeviceIdentity: Equatable, Sendable {
    /// The app's name as files carry it (TIFF Software, IPTC, XMP CreatorTool, the comment).
    public static let appName = "Open Shutter"
    /// The model the simulated camera writes. It runs on real phones too and saves into the real library, so its
    /// files say what made them and never claim an Apple camera.
    public static let simulatedModel = "Simulated camera"

    /// "Apple"; the app's name for the simulated camera.
    public var make: String
    /// "iPhone 16 Pro"; "Simulated camera".
    public var model: String
    /// The system version, "26.1".
    public var systemVersion: String
    /// The app version, "1.0".
    public var appVersion: String
    public var isSimulated: Bool

    public init(make: String = "Apple", model: String, systemVersion: String, appVersion: String,
                isSimulated: Bool = false) {
        self.make = make
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.isSimulated = isSimulated
    }

    /// The identity of the simulated camera: make "Open Shutter", model "Simulated camera".
    public static func simulatedCamera(systemVersion: String, appVersion: String) -> DeviceIdentity {
        DeviceIdentity(make: appName, model: simulatedModel, systemVersion: systemVersion, appVersion: appVersion,
                       isSimulated: true)
    }

    /// "Open Shutter 1.0", or the bare name when the version is unknown.
    public var appSignature: String {
        let version = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? Self.appName : Self.appName + " " + version
    }
}

/// Who chose the exposure, in the terms EXIF's ExposureProgram uses.
public enum ExposureControl: String, Sendable, CaseIterable {
    case auto, shutterPriority, isoPriority, aperturePriority, manual

    /// What a person or a scene fixed, from the model's auto flags. Everything auto is auto; shutter and ISO fixed is
    /// manual when the aperture is fixed too or the lens has no iris; otherwise a fixed shutter is shutter priority,
    /// a fixed aperture aperture priority and a fixed ISO alone ISO priority. A lens without an iris has no aperture
    /// to choose, whatever `apertureAuto` says.
    public static func from(shutterAuto: Bool, isoAuto: Bool, apertureAuto: Bool, variableAperture: Bool) -> ExposureControl {
        let apertureFixed = variableAperture && !apertureAuto
        if !shutterAuto && !isoAuto && (apertureFixed || !variableAperture) { return .manual }
        if !shutterAuto { return .shutterPriority }
        if apertureFixed { return .aperturePriority }
        if !isoAuto { return .isoPriority }
        return .auto
    }

    /// EXIF ExposureProgram: 1 manual, 2 normal program, 3 aperture priority, 4 shutter priority. EXIF has no ISO
    /// priority, and with the shutter left to the camera it is a normal program.
    public var exifProgram: Int {
        switch self {
        case .auto, .isoPriority: return 2
        case .shutterPriority: return 4
        case .aperturePriority: return 3
        case .manual: return 1
        }
    }

    /// EXIF ExposureMode: 1 manual, 0 auto exposure.
    public var exifMode: Int { self == .manual ? 1 : 0 }

    /// The shutter stays where it was set for as long as the capture runs.
    public var fixesShutter: Bool { self == .manual || self == .shutterPriority }

    /// The ISO stays where it was set for as long as the capture runs.
    public var fixesISO: Bool { self == .manual || self == .isoPriority }
}

/// Where one frame sits in a bracket.
public struct BracketPosition: Equatable, Sendable {
    public var kind: BracketKind
    /// 1-based. nil until known: an exposure bracket learns it per photo from the camera.
    public var index: Int?
    public var count: Int
    /// The bracket's step: EV, lens position or mireds, as BracketPlan has it.
    public var step: Double
    /// This frame's EV offset, lens position or Kelvin; nil until known.
    public var value: Double?
    /// Shared by every frame of one bracket, so a reader can put the set back together.
    public var group: UUID

    public init(kind: BracketKind, index: Int? = nil, count: Int, step: Double = 0, value: Double? = nil, group: UUID) {
        self.kind = kind
        self.index = index
        self.count = count
        self.step = step
        self.value = value
        self.group = group
    }
}

/// Shot `index` of `count` in an intervalometer run, 1-based.
public struct SequencePosition: Equatable, Sendable {
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

/// The kind of camera, with the same raw values as the app's LensInfo.Kind.
public enum LensKind: String, Sendable, CaseIterable {
    case ultraWide, wide, telephoto, front, external

    public var isFront: Bool { self == .front }
}

/// The camera a shot came through.
public struct LensRecord: Equatable, Sendable {
    public var kind: LensKind
    /// The device's localized name, "Back Camera".
    public var name: String
    /// "Apple".
    public var make: String
    /// Apple's lens model, "iPhone 16 Pro back camera 6.765mm f/1.78", when a frame reported it; nil otherwise.
    public var model: String?
    /// The lens's real focal length in mm, when a frame reported it.
    public var focalLength: Double?
    /// 35 mm equivalent focal length at zoom factor 1.
    public var equivalentFocalLength: Double
    /// The device's videoZoomFactor at the capture, so a zoom still ramping is recorded as it was.
    public var zoomFactor: Double
    /// EXIF LensSpecification: shortest and longest focal length in mm, then the f-number at each.
    public var specification: [Double]?
    public var hasFlash: Bool

    public init(kind: LensKind, name: String, make: String = "Apple", model: String? = nil, focalLength: Double? = nil,
                equivalentFocalLength: Double, zoomFactor: Double = 1, specification: [Double]? = nil,
                hasFlash: Bool = false) {
        self.kind = kind
        self.name = name
        self.make = make
        self.model = model
        self.focalLength = focalLength
        self.equivalentFocalLength = equivalentFocalLength
        self.zoomFactor = zoomFactor
        self.specification = specification
        self.hasFlash = hasFlash
    }
}

/// How a stacked capture ran: the plan and what the engine did with it.
public struct StackRecord: Equatable, Sendable {
    public var purpose: StackPurpose
    public var blend: StackBlend
    /// Planned shutter of each frame. The builder takes the frame's own reading from ShotRecord.exposure and falls
    /// back to this.
    public var frameSeconds: Double
    /// Planned ISO of each frame, the same fallback.
    public var sensorISO: Double
    /// Brightening applied at the end (NIGHT), 1 otherwise.
    public var digitalGain: Double
    /// Frames the plan asked for; for bulb, the cap.
    public var framesPlanned: Int
    /// Frames that arrived.
    public var framesSeen: Int
    /// Frames merged into the picture.
    public var framesUsed: Int
    public var aligned: Bool
    public var rejectBlurry: Bool
    /// 0...1 (NIGHT); nil when the stack has none.
    public var noiseReduction: Double?
    public var bulb: Bool
    /// Measured from the first merged frame to the last; nil when not measured.
    public var captureSeconds: Double?

    public init(purpose: StackPurpose, blend: StackBlend, frameSeconds: Double, sensorISO: Double,
                digitalGain: Double = 1, framesPlanned: Int, framesSeen: Int, framesUsed: Int, aligned: Bool = false,
                rejectBlurry: Bool = false, noiseReduction: Double? = nil, bulb: Bool = false,
                captureSeconds: Double? = nil) {
        self.purpose = purpose
        self.blend = blend
        self.frameSeconds = frameSeconds
        self.sensorISO = sensorISO
        self.digitalGain = digitalGain
        self.framesPlanned = framesPlanned
        self.framesSeen = framesSeen
        self.framesUsed = framesUsed
        self.aligned = aligned
        self.rejectBlurry = rejectBlurry
        self.noiseReduction = noiseReduction
        self.bulb = bulb
        self.captureSeconds = captureSeconds
    }

    /// The plan's purpose, blend, frame, ISO, gain, frame count, alignment and blur rejection, with what the engine
    /// counted.
    public init(plan: StackPlan, framesSeen: Int, framesUsed: Int, bulb: Bool = false, noiseReduction: Double? = nil,
                captureSeconds: Double? = nil) {
        self.init(purpose: plan.purpose, blend: plan.blend, frameSeconds: plan.frameSeconds, sensorISO: plan.iso,
                  digitalGain: plan.digitalGain, framesPlanned: plan.frameCount, framesSeen: framesSeen,
                  framesUsed: framesUsed, aligned: plan.align, rejectBlurry: plan.rejectBlurryFrames,
                  noiseReduction: noiseReduction, bulb: bulb, captureSeconds: captureSeconds)
    }
}

/// What the model knows at the press. Built by the model and carried in every request.
public struct ShotContext: Equatable, Sendable {
    public var mode: CaptureMode
    /// The advanced interface was on.
    public var advanced: Bool
    /// LONG only, custom included.
    public var scene: LongExposureScene?
    public var exposureControl: ExposureControl
    /// The exposure compensation the camera was given, in EV.
    public var bias: Double
    public var aeLocked: Bool
    public var meteringArea: MeteringArea
    /// What auto exposure wanted, t x ISO / N squared, for BrightnessValue when the frames report none.
    public var meteredProduct: Double?
    /// White balance as the camera ran it.
    public var whiteBalance: WhiteBalanceSetting
    /// The white balance came from a LONG scene.
    public var whiteBalanceFromScene: Bool
    /// As run: the live reading under auto. nil when unknown.
    public var kelvin: Double?
    public var tint: Double?
    /// Focus as the camera ran it.
    public var focus: FocusSetting
    /// The focus came from a LONG scene (infinity).
    public var focusFromScene: Bool
    /// Autofocus held by a long press.
    public var focusHeld: Bool
    /// 0...1 as run; nil when unknown.
    public var lensPosition: Double?
    public var aspect: AspectRatio
    /// Photos: the processing the photo ran with.
    public var processing: ProcessingLevel?
    /// Photos.
    public var flash: FlashSetting?
    public var livePhoto: Bool
    /// The zoom the lens buttons show, relative to the back wide camera: 0.5, 1, 1.4.
    public var displayZoom: Double
    /// The self timer or scene settle wait that ran before the shot, in seconds.
    public var timerSeconds: Double?
    /// Intervalometer shot n of m.
    public var interval: SequencePosition?
    public var bracket: BracketPosition?
    /// NIGHT and LONG: how steady the plan took the phone to be.
    public var stability: NightStability?
    /// Whether the motion sensor called the phone steady at the press.
    public var steadyAtStart: Bool?
    /// The location setting. The builder checks it again, so a fix that slipped through never reaches a file.
    public var locationTagsOn: Bool
    public var location: GeoTag?
    /// VIDEO: what was asked. The recorded format comes from the file itself.
    public var video: VideoSettings?
    /// "Your name" from Settings; written only when not empty.
    public var artist: String
    /// "Copyright" from Settings; written only when not empty.
    public var copyright: String

    public init(mode: CaptureMode, advanced: Bool = false, scene: LongExposureScene? = nil,
                exposureControl: ExposureControl = .auto, bias: Double = 0, aeLocked: Bool = false,
                meteringArea: MeteringArea = .automatic, meteredProduct: Double? = nil,
                whiteBalance: WhiteBalanceSetting = .auto, whiteBalanceFromScene: Bool = false, kelvin: Double? = nil,
                tint: Double? = nil, focus: FocusSetting = .auto, focusFromScene: Bool = false, focusHeld: Bool = false,
                lensPosition: Double? = nil, aspect: AspectRatio = .fourThree, processing: ProcessingLevel? = nil,
                flash: FlashSetting? = nil, livePhoto: Bool = false, displayZoom: Double = 1,
                timerSeconds: Double? = nil, interval: SequencePosition? = nil, bracket: BracketPosition? = nil,
                stability: NightStability? = nil, steadyAtStart: Bool? = nil, locationTagsOn: Bool = false,
                location: GeoTag? = nil, video: VideoSettings? = nil, artist: String = "", copyright: String = "") {
        self.mode = mode
        self.advanced = advanced
        self.scene = scene
        self.exposureControl = exposureControl
        self.bias = bias
        self.aeLocked = aeLocked
        self.meteringArea = meteringArea
        self.meteredProduct = meteredProduct
        self.whiteBalance = whiteBalance
        self.whiteBalanceFromScene = whiteBalanceFromScene
        self.kelvin = kelvin
        self.tint = tint
        self.focus = focus
        self.focusFromScene = focusFromScene
        self.focusHeld = focusHeld
        self.lensPosition = lensPosition
        self.aspect = aspect
        self.processing = processing
        self.flash = flash
        self.livePhoto = livePhoto
        self.displayZoom = displayZoom
        self.timerSeconds = timerSeconds
        self.interval = interval
        self.bracket = bracket
        self.stability = stability
        self.steadyAtStart = steadyAtStart
        self.locationTagsOn = locationTagsOn
        self.location = location
        self.video = video
        self.artist = artist
        self.copyright = copyright
    }

    /// The location gate, in one place: the fix only while location tags are on, and only a fix on the globe.
    /// Every GPS field, QuickTime location item and asset location comes through here.
    public var taggedLocation: GeoTag? {
        guard locationTagsOn, let location, location.hasValidCoordinates else { return nil }
        return location
    }
}

/// Everything the builder needs: the context from the model plus what the backend learned from the capture.
public struct ShotRecord: Equatable, Sendable {
    /// camera: AVCapturePhotoOutput wrote the file, so it already has the camera's own EXIF. rendered: the app made
    /// the pixels (stacks, the simulated camera).
    public enum Source: String, Sendable {
        case camera, rendered
    }

    public var source: Source
    public var context: ShotContext
    public var device: DeviceIdentity
    public var lens: LensRecord
    /// The exposure that goes into EXIF. For a stack, one frame as the hardware ran it (the first frame's own
    /// reading, else the plan); the builder works out the stack's values from it.
    public var exposure: ExposureValues
    /// APEX BrightnessValue when the camera reported one.
    public var brightness: Double?
    public var stack: StackRecord?
    /// The press, or a stack's first merged frame.
    public var date: Date
    /// A stack's last merged frame.
    public var endDate: Date?
    /// When the file was written.
    public var writtenDate: Date
    /// The zone EXIF's local times are in.
    public var timeZone: TimeZone
    /// The stored size; separate fields rather than a tuple, so the record stays Equatable.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// The picture is sRGB; false means Display P3.
    public var isSRGB: Bool

    /// `writtenDate` defaults to `date`.
    public init(source: Source, context: ShotContext, device: DeviceIdentity, lens: LensRecord, exposure: ExposureValues,
                brightness: Double? = nil, stack: StackRecord? = nil, date: Date, endDate: Date? = nil,
                writtenDate: Date? = nil, timeZone: TimeZone = .current, pixelWidth: Int? = nil,
                pixelHeight: Int? = nil, isSRGB: Bool = false) {
        self.source = source
        self.context = context
        self.device = device
        self.lens = lens
        self.exposure = exposure
        self.brightness = brightness
        self.stack = stack
        self.date = date
        self.endDate = endDate
        self.writtenDate = writtenDate ?? date
        self.timeZone = timeZone
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isSRGB = isSRGB
    }
}
