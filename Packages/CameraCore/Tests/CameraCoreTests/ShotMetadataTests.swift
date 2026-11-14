import XCTest
@testable import CameraCore

final class ShotMetadataTests: XCTestCase {
    // MARK: - Fixtures

    /// 2026-11-14 06:04:05.532 UTC: 22:04:05.532 the evening before in Los Angeles.
    private let press = Date(timeIntervalSince1970: 1_794_636_245.532)
    /// 2026-11-14 07:30 UTC: 23:30 on the 13th in Los Angeles, the next day in UTC.
    private let fixTime = Date(timeIntervalSince1970: 1_794_641_400)
    private let group = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private var losAngeles: TimeZone { TimeZone(identifier: "America/Los_Angeles")! }

    private let phone = DeviceIdentity(model: "iPhone 16 Pro", systemVersion: "26.1", appVersion: "1.0")
    private let simulator = DeviceIdentity.simulatedCamera(systemVersion: "26.1", appVersion: "1.0")

    private let mainCamera = LensRecord(kind: .wide, name: "Back Camera",
                                        model: "iPhone 16 Pro back camera 6.765mm f/1.78",
                                        focalLength: 6.765, equivalentFocalLength: 24, zoomFactor: 1,
                                        specification: [6.765, 6.765, 1.78, 1.78], hasFlash: true)
    private let frontCamera = LensRecord(kind: .front, name: "Front Camera", equivalentFocalLength: 23, hasFlash: false)

    private func fix(latitude: Double = 43.6532, longitude: Double = -79.3832, altitude: Double = -12.5,
                     horizontalAccuracy: Double = 4.7, verticalAccuracy: Double = 3, speed: Double? = 10,
                     course: Double? = 95, heading: Double? = 370, trueNorth: Bool = true) -> GeoTag {
        GeoTag(latitude: latitude, longitude: longitude, altitude: altitude, horizontalAccuracy: horizontalAccuracy,
               timestamp: fixTime, verticalAccuracy: verticalAccuracy, speed: speed, course: course, heading: heading,
               headingIsTrueNorth: trueNorth)
    }

    private func photo(_ context: ShotContext = ShotContext(mode: .photo), lens: LensRecord? = nil,
                       device: DeviceIdentity? = nil, source: ShotRecord.Source = .camera,
                       exposure: ExposureValues = ExposureValues(seconds: 1.0 / 121.0, iso: 64, aperture: 1.78),
                       brightness: Double? = nil, isSRGB: Bool = false) -> ShotRecord {
        ShotRecord(source: source, context: context, device: device ?? phone, lens: lens ?? mainCamera,
                   exposure: exposure, brightness: brightness, date: press, timeZone: losAngeles, pixelWidth: 4032,
                   pixelHeight: 2268, isSRGB: isSRGB)
    }

    /// A stack whose frames ran back to back, written a second and a quarter after the last one.
    private func stack(_ mode: CaptureMode = .long, blend: StackBlend, frameSeconds: Double, iso: Double, used: Int,
                       seen: Int? = nil, planned: Int? = nil, gain: Double = 1, bulb: Bool = false,
                       aligned: Bool = false, rejectBlurry: Bool = false, noiseReduction: Double? = nil,
                       captureSeconds: Double? = nil, context: ShotContext? = nil, device: DeviceIdentity? = nil,
                       exposure: ExposureValues? = nil) -> ShotRecord {
        let record = StackRecord(purpose: mode == .night ? .night : .longExposure, blend: blend,
                                 frameSeconds: frameSeconds, sensorISO: iso, digitalGain: gain,
                                 framesPlanned: planned ?? used, framesSeen: seen ?? used, framesUsed: used,
                                 aligned: aligned, rejectBlurry: rejectBlurry, noiseReduction: noiseReduction,
                                 bulb: bulb, captureSeconds: captureSeconds)
        let duration = Double(used) * max(frameSeconds, 1.0 / 30.0)
        return ShotRecord(source: .rendered, context: context ?? ShotContext(mode: mode), device: device ?? phone,
                          lens: mainCamera,
                          exposure: exposure ?? ExposureValues(seconds: frameSeconds, iso: iso, aperture: 1.78),
                          stack: record, date: press, endDate: press.addingTimeInterval(duration),
                          writtenDate: press.addingTimeInterval(duration + 1.25), timeZone: losAngeles,
                          pixelWidth: 4032, pixelHeight: 2268)
    }

    /// The map's NIGHT example: 3 s handheld, 36 of 38 frames of 1/12 at ISO 640, brightened 1.4x.
    private func nightStack(context: ShotContext? = nil) -> ShotRecord {
        stack(.night, blend: .average, frameSeconds: 1.0 / 12.0, iso: 640, used: 36, seen: 38, planned: 40, gain: 1.4,
              aligned: true, rejectBlurry: true, noiseReduction: 0.5,
              context: context ?? ShotContext(mode: .night, stability: .handheld))
    }

    private func number(_ value: MetadataValue?) -> Double? {
        switch value {
        case .number(let number)?: return number
        case .integer(let integer)?: return Double(integer)
        default: return nil
        }
    }

    private func text(_ value: MetadataValue?) -> String? {
        if case .text(let text)? = value { return text }
        return nil
    }

    private func xmp(_ metadata: ImageMetadata) -> [ShotXMP.Field: String] {
        Dictionary(uniqueKeysWithValues: metadata.xmp.map { ($0.field, $0.value) })
    }

    private func movieValue(_ entries: [MovieMetadataEntry], _ key: MovieKey) -> MetadataValue? {
        entries.first { $0.key == key }?.value
    }

    /// Every piece of text a record's files would carry.
    private func allText(_ record: ShotRecord) -> [String] {
        var texts: [String] = []
        for metadata in [ShotMetadataBuilder.rendered(record), ShotMetadataBuilder.additions(record)] {
            let values = Array(metadata.exif.values) + Array(metadata.tiff.values) + Array(metadata.gps.values)
                + Array(metadata.iptc.values)
            texts += values.compactMap(text)
            texts += metadata.xmp.map(\.value)
            texts += [metadata.creatorTool, metadata.creator, metadata.rights].compactMap { $0 }
        }
        for livePhoto in [false, true] {
            texts += ShotMetadataBuilder.movie(record, livePhoto: livePhoto).compactMap { text($0.value) }
        }
        return texts + [ShotMetadataBuilder.comment(record)]
    }

    // MARK: - The location gate

    func testLocationTagsOffWritesNoLocationEvenWithAFix() {
        let withFix = photo(ShotContext(mode: .photo, locationTagsOn: false, location: fix()))
        let withoutFix = photo(ShotContext(mode: .photo, locationTagsOn: false))
        XCTAssertEqual(ShotMetadataBuilder.rendered(withFix).gps, [:])
        XCTAssertEqual(ShotMetadataBuilder.additions(withFix).gps, [:])
        for livePhoto in [false, true] {
            let keys = ShotMetadataBuilder.movie(withFix, livePhoto: livePhoto).map(\.key)
            XCTAssertFalse(keys.contains(.locationISO6709))
            XCTAssertFalse(keys.contains(.locationHorizontalAccuracy))
        }
        XCTAssertNil(withFix.context.taggedLocation)
        // Nothing else in the file changes either: the fix leaves no trace in the XMP or the comment.
        XCTAssertEqual(ShotMetadataBuilder.rendered(withFix), ShotMetadataBuilder.rendered(withoutFix))
        XCTAssertEqual(ShotMetadataBuilder.additions(withFix), ShotMetadataBuilder.additions(withoutFix))
    }

    func testLocationTagsOnWithoutAFixWritesNoLocation() {
        let record = photo(ShotContext(mode: .photo, locationTagsOn: true, location: nil))
        XCTAssertEqual(ShotMetadataBuilder.rendered(record).gps, [:])
        XCTAssertEqual(ShotMetadataBuilder.additions(record).gps, [:])
        XCTAssertFalse(ShotMetadataBuilder.movie(record, livePhoto: false).map(\.key).contains(.locationISO6709))
        XCTAssertFalse(ShotMetadataBuilder.movie(record, livePhoto: true).map(\.key).contains(.locationISO6709))
    }

    func testLocationTagsOnWithAFixWritesTheLocation() {
        let record = photo(ShotContext(mode: .photo, locationTagsOn: true, location: fix()))
        XCTAssertFalse(ShotMetadataBuilder.rendered(record).gps.isEmpty)
        XCTAssertEqual(ShotMetadataBuilder.additions(record).gps, ShotMetadataBuilder.rendered(record).gps)
        for livePhoto in [false, true] {
            let entries = ShotMetadataBuilder.movie(record, livePhoto: livePhoto)
            XCTAssertEqual(text(movieValue(entries, .locationISO6709)), "+43.6532-079.3832-012.500/")
            XCTAssertEqual(number(movieValue(entries, .locationHorizontalAccuracy)), 4.7)
        }
    }

    func testTheXMPNeverCarriesTheLocation() {
        let tagged = photo(ShotContext(mode: .photo, locationTagsOn: true, location: fix()))
        let untagged = photo(ShotContext(mode: .photo))
        XCTAssertEqual(ShotMetadataBuilder.rendered(tagged).xmp, ShotMetadataBuilder.rendered(untagged).xmp)
        XCTAssertEqual(ShotMetadataBuilder.comment(tagged), ShotMetadataBuilder.comment(untagged))
        let appKeys = ShotMetadataBuilder.movie(tagged, livePhoto: false).compactMap { entry -> String? in
            if case .app(let field) = entry.key { return field.rawValue }
            return nil
        }
        XCTAssertFalse(appKeys.isEmpty)
        for key in appKeys {
            XCTAssertFalse(["latitude", "longitude", "altitude", "gps", "location", "heading", "speed"]
                .contains { key.lowercased().contains($0) }, key)
        }
    }

    func testAFixOffTheGlobeNeverReachesAFile() {
        for bad in [fix(latitude: 91), fix(longitude: -181), fix(latitude: .nan), fix(longitude: .infinity)] {
            let record = photo(ShotContext(mode: .photo, locationTagsOn: true, location: bad))
            XCTAssertEqual(ShotMetadataBuilder.rendered(record).gps, [:])
            XCTAssertFalse(ShotMetadataBuilder.movie(record, livePhoto: false).map(\.key).contains(.locationISO6709))
        }
    }

    // MARK: - GPS fields

    private func gps(_ geo: GeoTag, lens: LensRecord? = nil) -> [GPSKey: MetadataValue] {
        ShotMetadataBuilder.rendered(photo(ShotContext(mode: .photo, locationTagsOn: true, location: geo),
                                           lens: lens)).gps
    }

    func testGPSFieldsOfAFullFix() throws {
        let fields = gps(fix())
        XCTAssertEqual(Set(fields.keys), [.latitude, .latitudeRef, .longitude, .longitudeRef, .altitude, .altitudeRef,
                                          .timeStamp, .dateStamp, .speed, .speedRef, .track, .trackRef, .imgDirection,
                                          .imgDirectionRef, .destBearing, .destBearingRef, .hPositioningError])
        XCTAssertEqual(number(fields[.latitude]), 43.6532)
        XCTAssertEqual(text(fields[.latitudeRef]), "N")
        XCTAssertEqual(number(fields[.longitude]), 79.3832)
        XCTAssertEqual(text(fields[.longitudeRef]), "W")
        XCTAssertEqual(number(fields[.altitude]), 12.5)
        XCTAssertEqual(number(fields[.altitudeRef]), 1)
        XCTAssertEqual(number(fields[.hPositioningError]), 4.7)
        XCTAssertEqual(try XCTUnwrap(number(fields[.speed])), 36, accuracy: 1e-9)
        XCTAssertEqual(text(fields[.speedRef]), "K")
        XCTAssertEqual(number(fields[.track]), 95)
        XCTAssertEqual(text(fields[.trackRef]), "T")
        XCTAssertEqual(number(fields[.imgDirection]), 10)
        XCTAssertEqual(text(fields[.imgDirectionRef]), "T")
        XCTAssertEqual(number(fields[.destBearing]), 10)
        XCTAssertEqual(text(fields[.destBearingRef]), "T")
        // UTC, so the 14th, though it was still the 13th where the photo was taken.
        XCTAssertEqual(text(fields[.dateStamp]), "2026:11:14")
        XCTAssertEqual(text(fields[.timeStamp]), "07:30:00")
    }

    func testGPSReferencesFollowTheSigns() {
        let south = gps(fix(latitude: -33.8688, longitude: 151.2093, altitude: 58, verticalAccuracy: 2))
        XCTAssertEqual(number(south[.latitude]), 33.8688)
        XCTAssertEqual(text(south[.latitudeRef]), "S")
        XCTAssertEqual(number(south[.longitude]), 151.2093)
        XCTAssertEqual(text(south[.longitudeRef]), "E")
        XCTAssertEqual(number(south[.altitude]), 58)
        XCTAssertEqual(number(south[.altitudeRef]), 0)
    }

    func testAnUnknownAltitudeIsLeftOut() {
        // Core Location says 0 metres when it has no altitude; only the vertical accuracy tells.
        let fields = gps(fix(altitude: 0, verticalAccuracy: -1))
        XCTAssertNil(fields[.altitude])
        XCTAssertNil(fields[.altitudeRef])
        XCTAssertNotNil(fields[.latitude])
        // The five-argument init of the old LocationStamp has no altitude either.
        let old = GeoTag(latitude: 43.6532, longitude: -79.3832, altitude: 87, horizontalAccuracy: 5,
                         timestamp: fixTime)
        XCTAssertNil(gps(old)[.altitude])
    }

    func testSpeedOnlyWhenTheFixHasOne() {
        XCTAssertNil(gps(fix(speed: nil))[.speed])
        XCTAssertNil(gps(fix(speed: -1))[.speed])
        XCTAssertNil(gps(fix(speed: .nan))[.speedRef])
        XCTAssertEqual(number(gps(fix(speed: 0))[.speed]), 0)
    }

    func testDirectionsWrapIntoACompass() throws {
        let magnetic = gps(fix(course: -5, heading: -10, trueNorth: false))
        XCTAssertEqual(try XCTUnwrap(number(magnetic[.imgDirection])), 350, accuracy: 1e-9)
        XCTAssertEqual(text(magnetic[.imgDirectionRef]), "M")
        XCTAssertEqual(text(magnetic[.destBearingRef]), "M")
        XCTAssertEqual(try XCTUnwrap(number(magnetic[.track])), 355, accuracy: 1e-9)
        // Course is measured from true north whatever the compass uses.
        XCTAssertEqual(text(magnetic[.trackRef]), "T")
        XCTAssertEqual(number(gps(fix(heading: 720))[.imgDirection]), 0)
        // A sliver below north wraps to a value that rounds to 360, which is north again.
        XCTAssertEqual(number(gps(fix(heading: -1e-15))[.imgDirection]), 0)
    }

    func testTheFrontCameraLooksTheOtherWay() throws {
        let fields = gps(fix(heading: 10), lens: frontCamera)
        XCTAssertEqual(try XCTUnwrap(number(fields[.imgDirection])), 190, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(number(gps(fix(heading: 300), lens: frontCamera)[.imgDirection])), 120,
                       accuracy: 1e-9)
    }

    func testNoDirectionWithoutAHeadingOrCourse() {
        let fields = gps(fix(course: nil, heading: nil))
        for key in [GPSKey.imgDirection, .imgDirectionRef, .destBearing, .destBearingRef, .track, .trackRef] {
            XCTAssertNil(fields[key], key.rawValue)
        }
        XCTAssertNil(gps(fix(heading: .nan))[.imgDirection])
        XCTAssertNil(gps(fix(horizontalAccuracy: -1))[.hPositioningError])
    }

    // MARK: - Camera files get only what they lack

    /// Keys AVCapturePhotoOutput writes into every photo (map section 2).
    private let cameraExifKeys: [ExifKey] = [
        .exposureTime, .fNumber, .exposureProgram, .isoSpeedRatings, .dateTimeOriginal, .dateTimeDigitized,
        .offsetTime, .offsetTimeOriginal, .offsetTimeDigitized, .subsecTimeOriginal, .subsecTimeDigitized,
        .shutterSpeedValue, .apertureValue, .brightnessValue, .exposureBiasValue, .meteringMode, .flash, .focalLength,
        .colorSpace, .pixelXDimension, .pixelYDimension, .sensingMethod, .sceneType, .exposureMode, .whiteBalance,
        .digitalZoomRatio, .focalLenIn35mmFilm, .lensSpecification, .lensMake, .lensModel, .compositeImage,
    ]
    private let cameraTIFFKeys: [TIFFKey] = [.make, .model, .software, .dateTime, .hostComputer, .orientation]

    private func everyKindOfCameraFile() -> [ShotRecord] {
        var contexts: [ShotContext] = []
        for mode in CaptureMode.allCases {
            contexts.append(ShotContext(mode: mode))
            contexts.append(ShotContext(mode: mode, advanced: true, scene: .stars, exposureControl: .manual, bias: -0.7,
                                        aeLocked: true, meteringArea: .spot, whiteBalance: .preset(.tungsten),
                                        kelvin: 3200, tint: 0, focus: .manual(lensPosition: 0.4), lensPosition: 0.4,
                                        processing: .minimal, flash: .on, livePhoto: true, displayZoom: 2,
                                        timerSeconds: 3, interval: SequencePosition(index: 2, count: 9),
                                        bracket: BracketPosition(kind: .exposure, index: 2, count: 5, step: 1,
                                                                 value: -1, group: group),
                                        stability: .tripod, steadyAtStart: true, locationTagsOn: true, location: fix(),
                                        artist: "Ada Lovelace", copyright: "Copyright 2026 Ada Lovelace"))
        }
        let focusFrame = BracketPosition(kind: .focus, index: 3, count: 10, value: 0.42, group: group)
        contexts.append(ShotContext(mode: .photo, bracket: focusFrame))
        contexts.append(ShotContext(mode: .photo, whiteBalance: .kelvin(4800, tint: 0),
                                    bracket: BracketPosition(kind: .whiteBalance, index: 1, count: 3, step: 20,
                                                             value: 4800, group: group)))
        return contexts.flatMap { context in
            [photo(context), photo(context, lens: frontCamera), photo(context, device: simulator)]
        }
    }

    func testAdditionsNeverContainAKeyTheCameraWrites() {
        for record in everyKindOfCameraFile() {
            let additions = ShotMetadataBuilder.additions(record)
            XCTAssertTrue(Set(additions.exif.keys).isSubset(of: [.userComment, .lightSource]), "\(additions.exif.keys)")
            XCTAssertTrue(Set(additions.tiff.keys).isSubset(of: [.artist, .copyright]), "\(additions.tiff.keys)")
            for key in cameraExifKeys {
                XCTAssertNil(additions.exif[key], key.rawValue)
            }
            for key in cameraTIFFKeys {
                XCTAssertNil(additions.tiff[key], key.rawValue)
            }
        }
    }

    func testAdditionsCarryTheCommentProgramAndAppFields() {
        let record = photo(ShotContext(mode: .photo, whiteBalance: .preset(.daylight)))
        let additions = ShotMetadataBuilder.additions(record)
        XCTAssertEqual(text(additions.exif[.userComment]), ShotMetadataBuilder.comment(record))
        XCTAssertEqual(number(additions.exif[.lightSource]), 1)
        XCTAssertEqual(text(additions.iptc[.originatingProgram]), "Open Shutter")
        XCTAssertEqual(text(additions.iptc[.programVersion]), "1.0")
        XCTAssertEqual(additions.creatorTool, "Open Shutter 1.0")
        XCTAssertEqual(additions.xmpValue(.mode), "photo")
        XCTAssertEqual(additions.xmp, ShotMetadataBuilder.rendered(record).xmp)
    }

    // MARK: - Stacks

    func testRealStackRecordsTheLightOfEveryFrame() throws {
        let metadata = ShotMetadataBuilder.rendered(stack(blend: .additive, frameSeconds: 1, iso: 100, used: 30))
        XCTAssertEqual(number(metadata.exif[.exposureTime]), 30)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.shutterSpeedValue])), -log2(30), accuracy: 1e-12)
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([100]))
        XCTAssertEqual(metadata.exif[.compositeImage], .integer(3))
        XCTAssertEqual(metadata.exif[.sourceImageNumberOfCompositeImage], .integers([30, 30]))
        let fields = xmp(metadata)
        XCTAssertEqual(fields[.blend], "additive")
        XCTAssertEqual(fields[.frameSeconds], "1")
        XCTAssertEqual(fields[.frameCount], "30")
        XCTAssertEqual(fields[.lightSeconds], "30")
    }

    func testManualStackIsAdditiveToo() {
        let metadata = ShotMetadataBuilder.rendered(stack(.manual, blend: .additive, frameSeconds: 1, iso: 100,
                                                          used: 8))
        XCTAssertEqual(number(metadata.exif[.exposureTime]), 8)
        XCTAssertEqual(metadata.exif[.sourceImageNumberOfCompositeImage], .integers([8, 8]))
        XCTAssertEqual(metadata.xmpValue(.mode), "manual")
        XCTAssertEqual(metadata.xmpValue(.blend), "additive")
    }

    func testBlurStackRecordsOneFramesTime() throws {
        let metadata = ShotMetadataBuilder.rendered(stack(blend: .average, frameSeconds: 1.0 / 30.0, iso: 50,
                                                          used: 900))
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.exposureTime])), 1.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.shutterSpeedValue])), log2(30), accuracy: 1e-9)
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([50]))
        XCTAssertEqual(metadata.exif[.compositeImage], .integer(3))
        XCTAssertEqual(metadata.exif[.sourceImageNumberOfCompositeImage], .integers([900, 900]))
        XCTAssertEqual(metadata.xmpValue(.lightSeconds), "30")
    }

    func testTrailsStackRecordsOneFramesTime() {
        let metadata = ShotMetadataBuilder.rendered(stack(blend: .lighten, frameSeconds: 1, iso: 800, used: 1800))
        XCTAssertEqual(number(metadata.exif[.exposureTime]), 1)
        XCTAssertEqual(number(metadata.exif[.shutterSpeedValue]), 0)
        XCTAssertEqual(metadata.xmpValue(.blend), "lighten")
        XCTAssertEqual(metadata.xmpValue(.lightSeconds), "1800")
    }

    func testNightRecordsOneFrameAndThePushedISO() throws {
        let metadata = ShotMetadataBuilder.rendered(nightStack())
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.exposureTime])), 1.0 / 12.0, accuracy: 1e-12)
        // 640 brightened 1.4 times reads as ISO 896.
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([896]))
        XCTAssertEqual(metadata.exif[.sourceImageNumberOfCompositeImage], .integers([38, 36]))
        XCTAssertEqual(metadata.xmpValue(.sensorISO), "640")
        XCTAssertEqual(metadata.xmpValue(.digitalGain), "1.4")

        let pushed = ShotMetadataBuilder.rendered(stack(.night, blend: .average, frameSeconds: 0.25, iso: 3200,
                                                        used: 12, gain: 2.5))
        XCTAssertEqual(pushed.exif[.isoSpeedRatings], .integers([8000]))
        XCTAssertEqual(pushed.xmpValue(.sensorISO), "3200")
        XCTAssertEqual(pushed.xmpValue(.digitalGain), "2.5")
    }

    func testISOStopsAtWhatSixteenBitsHold() {
        let metadata = ShotMetadataBuilder.rendered(stack(.night, blend: .average, frameSeconds: 0.5, iso: 30_000,
                                                          used: 6, gain: 16))
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([65535]))
        // The XMP keeps what really happened.
        XCTAssertEqual(metadata.xmpValue(.sensorISO), "30000")
        XCTAssertEqual(metadata.xmpValue(.digitalGain), "16")
    }

    func testStoppedBulbCountsTheFramesItUsed() {
        let record = stack(blend: .additive, frameSeconds: 1, iso: 50, used: 47, seen: 47, planned: 1800, bulb: true)
        let metadata = ShotMetadataBuilder.rendered(record)
        XCTAssertEqual(number(metadata.exif[.exposureTime]), 47)
        XCTAssertEqual(metadata.exif[.sourceImageNumberOfCompositeImage], .integers([47, 47]))
        let fields = xmp(metadata)
        XCTAssertEqual(fields[.bulb], "True")
        XCTAssertEqual(fields[.framesPlanned], "1800")
        XCTAssertEqual(fields[.frameCount], "47")
        XCTAssertEqual(fields[.lightSeconds], "47")
        XCTAssertEqual(ShotMetadataBuilder.comment(record),
                       "Long exposure, 47s from 47 frames of 1s at ISO 50, Real. Taken with Open Shutter 1.0.")
    }

    func testFrameCountsStopAtWhatSixteenBitsHold() {
        // Two hours of 30 fps frames.
        let long = ShotMetadataBuilder.rendered(stack(blend: .lighten, frameSeconds: 1.0 / 30.0, iso: 100,
                                                      used: 215_000, seen: 216_000))
        XCTAssertEqual(long.exif[.sourceImageNumberOfCompositeImage], .integers([65535, 65535]))
        XCTAssertEqual(long.xmpValue(.framesCaptured), "216000")
        XCTAssertEqual(long.xmpValue(.frameCount), "215000")
        let mixed = ShotMetadataBuilder.rendered(stack(blend: .average, frameSeconds: 1.0 / 30.0, iso: 100,
                                                       used: 60_000, seen: 70_000))
        XCTAssertEqual(mixed.exif[.sourceImageNumberOfCompositeImage], .integers([65535, 60000]))
    }

    func testFramesSeenIsNeverFewerThanFramesUsed() {
        let metadata = ShotMetadataBuilder.rendered(stack(blend: .additive, frameSeconds: 1, iso: 100, used: 12,
                                                          seen: 10))
        XCTAssertEqual(metadata.exif[.sourceImageNumberOfCompositeImage], .integers([12, 12]))
        XCTAssertEqual(metadata.xmpValue(.framesCaptured), "12")
    }

    func testAStackOfOneFrameIsNotAComposite() {
        let metadata = ShotMetadataBuilder.rendered(stack(blend: .additive, frameSeconds: 4, iso: 100, used: 1,
                                                          seen: 3))
        XCTAssertEqual(metadata.exif[.compositeImage], .integer(1))
        XCTAssertNil(metadata.exif[.sourceImageNumberOfCompositeImage])
        XCTAssertEqual(number(metadata.exif[.exposureTime]), 4)
    }

    func testStackDatesComeFromTheFirstAndLastFrames() {
        // 30 frames of 1 s from 22:04:05.532, written at 22:04:36.782.
        let metadata = ShotMetadataBuilder.rendered(stack(blend: .additive, frameSeconds: 1, iso: 100, used: 30))
        XCTAssertEqual(text(metadata.exif[.dateTimeOriginal]), "2026:11:13 22:04:05")
        XCTAssertEqual(text(metadata.exif[.subsecTimeOriginal]), "532")
        XCTAssertEqual(text(metadata.exif[.offsetTimeOriginal]), "-08:00")
        XCTAssertEqual(text(metadata.exif[.dateTimeDigitized]), "2026:11:13 22:04:35")
        XCTAssertEqual(text(metadata.exif[.subsecTimeDigitized]), "532")
        XCTAssertEqual(text(metadata.exif[.offsetTimeDigitized]), "-08:00")
        XCTAssertEqual(text(metadata.tiff[.dateTime]), "2026:11:13 22:04:36")
        XCTAssertEqual(text(metadata.exif[.subsecTime]), "782")
        XCTAssertEqual(text(metadata.exif[.offsetTime]), "-08:00")
        XCTAssertEqual(metadata.xmpValue(.captureSeconds), "30")
    }

    func testMeasuredCaptureTimeWinsOverTheFrameDates() {
        let record = stack(blend: .average, frameSeconds: 1.0 / 30.0, iso: 100, used: 60, captureSeconds: 2.1234)
        XCTAssertEqual(ShotMetadataBuilder.rendered(record).xmpValue(.captureSeconds), "2.123")
    }

    func testStackFallsBackToThePlanWhenTheFramesReportNothing() throws {
        let record = stack(.night, blend: .average, frameSeconds: 0.125, iso: 1600, used: 20, gain: 2,
                           exposure: ExposureValues(seconds: 0, iso: 0, aperture: 1.78))
        let metadata = ShotMetadataBuilder.rendered(record)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.exposureTime])), 0.125, accuracy: 1e-12)
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([3200]))
        XCTAssertEqual(metadata.xmpValue(.frameSeconds), "0.125")
        XCTAssertEqual(metadata.xmpValue(.sensorISO), "1600")
    }

    func testTheFramesOwnReadingWinsOverThePlan() throws {
        // The hardware ran 1/15 at ISO 500 where the plan asked for 1/12 at 640.
        let record = stack(.night, blend: .average, frameSeconds: 1.0 / 12.0, iso: 640, used: 36, gain: 1.4,
                           exposure: ExposureValues(seconds: 1.0 / 15.0, iso: 500, aperture: 1.78))
        let metadata = ShotMetadataBuilder.rendered(record)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.exposureTime])), 1.0 / 15.0, accuracy: 1e-12)
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([700]))
        XCTAssertEqual(metadata.xmpValue(.sensorISO), "500")
    }

    // MARK: - Who chose the exposure

    func testExposureControlFromEveryLockCombination() {
        // (shutter auto, ISO auto, aperture auto) on a lens with an iris.
        let withIris: [(Bool, Bool, Bool, ExposureControl)] = [
            (true, true, true, .auto),
            (true, true, false, .aperturePriority),
            (true, false, true, .isoPriority),
            (true, false, false, .aperturePriority),
            (false, true, true, .shutterPriority),
            (false, true, false, .shutterPriority),
            (false, false, true, .shutterPriority),
            (false, false, false, .manual),
        ]
        for (shutter, iso, aperture, expected) in withIris {
            XCTAssertEqual(ExposureControl.from(shutterAuto: shutter, isoAuto: iso, apertureAuto: aperture,
                                                variableAperture: true), expected, "\(shutter) \(iso) \(aperture)")
        }
        // Without an iris there is no aperture to choose, whatever its flag says.
        for aperture in [true, false] {
            XCTAssertEqual(ExposureControl.from(shutterAuto: true, isoAuto: true, apertureAuto: aperture,
                                                variableAperture: false), .auto)
            XCTAssertEqual(ExposureControl.from(shutterAuto: true, isoAuto: false, apertureAuto: aperture,
                                                variableAperture: false), .isoPriority)
            XCTAssertEqual(ExposureControl.from(shutterAuto: false, isoAuto: true, apertureAuto: aperture,
                                                variableAperture: false), .shutterPriority)
            XCTAssertEqual(ExposureControl.from(shutterAuto: false, isoAuto: false, apertureAuto: aperture,
                                                variableAperture: false), .manual)
        }
    }

    func testExposureProgramAndModeInTheFile() {
        let expected: [ExposureControl: (program: Int, mode: Int)] = [
            .auto: (2, 0), .shutterPriority: (4, 0), .aperturePriority: (3, 0), .isoPriority: (2, 0), .manual: (1, 1),
        ]
        for control in ExposureControl.allCases {
            let record = photo(ShotContext(mode: .manual, exposureControl: control), source: .rendered)
            let metadata = ShotMetadataBuilder.rendered(record)
            XCTAssertEqual(metadata.exif[.exposureProgram], .integer(expected[control]!.program), control.rawValue)
            XCTAssertEqual(metadata.exif[.exposureMode], .integer(expected[control]!.mode), control.rawValue)
            XCTAssertEqual(metadata.xmpValue(.exposureControl), control.rawValue)
        }
    }

    func testWhichValuesStayFixedForAMovie() {
        XCTAssertTrue(ExposureControl.manual.fixesShutter && ExposureControl.manual.fixesISO)
        XCTAssertTrue(ExposureControl.shutterPriority.fixesShutter)
        XCTAssertFalse(ExposureControl.shutterPriority.fixesISO)
        XCTAssertTrue(ExposureControl.isoPriority.fixesISO)
        XCTAssertFalse(ExposureControl.isoPriority.fixesShutter)
        XCTAssertFalse(ExposureControl.auto.fixesShutter || ExposureControl.auto.fixesISO)
        XCTAssertFalse(ExposureControl.aperturePriority.fixesShutter || ExposureControl.aperturePriority.fixesISO)
    }

    // MARK: - EXIF values from the settings

    func testMeteringMode() {
        let expected: [MeteringArea: Int] = [.automatic: 5, .spot: 3, .wholeFrame: 1]
        for area in MeteringArea.allCases {
            let metadata = ShotMetadataBuilder.rendered(photo(ShotContext(mode: .photo, meteringArea: area),
                                                              source: .rendered))
            XCTAssertEqual(metadata.exif[.meteringMode], .integer(expected[area]!), area.rawValue)
            XCTAssertEqual(metadata.xmpValue(.meteringArea), area.rawValue)
        }
    }

    func testWhiteBalanceAndLightSource() {
        let cases: [(WhiteBalanceSetting, Int, Int?, String)] = [
            (.auto, 0, nil, "auto"),
            (.preset(.auto), 0, nil, "auto"),
            (.preset(.daylight), 1, 1, "daylight"),
            (.preset(.fluorescent), 1, 2, "fluorescent"),
            (.preset(.tungsten), 1, 3, "tungsten"),
            (.preset(.flash), 1, 4, "flash"),
            (.preset(.cloudy), 1, 10, "cloudy"),
            (.preset(.shade), 1, 11, "shade"),
            (.preset(.candle), 1, 255, "candle"),
            (.kelvin(4800, tint: 5), 1, nil, "kelvin"),
        ]
        // One row for every preset, so a new one can't go unmapped.
        XCTAssertEqual(Set(cases.compactMap { setting, _, _, _ -> WhiteBalancePreset? in
            if case .preset(let preset) = setting { return preset }
            return nil
        }), Set(WhiteBalancePreset.allCases))
        for (setting, whiteBalance, lightSource, name) in cases {
            let record = photo(ShotContext(mode: .photo, whiteBalance: setting), source: .rendered)
            let rendered = ShotMetadataBuilder.rendered(record)
            XCTAssertEqual(rendered.exif[.whiteBalance], .integer(whiteBalance), name)
            XCTAssertEqual(rendered.exif[.lightSource], lightSource.map(MetadataValue.integer), name)
            XCTAssertEqual(ShotMetadataBuilder.additions(record).exif[.lightSource],
                           lightSource.map(MetadataValue.integer),
                           name)
            XCTAssertEqual(rendered.xmpValue(.whiteBalance), name)
        }
    }

    func testFlashOnALensWithAndWithoutOne() {
        XCTAssertEqual(ShotMetadataBuilder.rendered(nightStack()).exif[.flash], .integer(16))
        let front = photo(ShotContext(mode: .photo), lens: frontCamera, source: .rendered)
        XCTAssertEqual(ShotMetadataBuilder.rendered(front).exif[.flash], .integer(32))
    }

    private func sceneCaptureType(_ mode: CaptureMode, _ scene: LongExposureScene?) -> MetadataValue? {
        ShotMetadataBuilder.rendered(photo(ShotContext(mode: mode, scene: scene),
                                           source: .rendered)).exif[.sceneCaptureType]
    }

    func testSceneCaptureType() {
        XCTAssertEqual(sceneCaptureType(.night, nil), .integer(3))
        for scene in [LongExposureScene.stars, .northernLights, .starTrails, .fireworks] {
            XCTAssertEqual(sceneCaptureType(.long, scene), .integer(3), scene.rawValue)
        }
        for scene in [LongExposureScene.water, .lightTrails, .lightPainting, .custom] {
            XCTAssertEqual(sceneCaptureType(.long, scene), .integer(0), scene.rawValue)
        }
        XCTAssertEqual(sceneCaptureType(.long, nil), .integer(0))
        for mode in [CaptureMode.photo, .manual, .video] {
            XCTAssertEqual(sceneCaptureType(mode, .stars), .integer(0), mode.rawValue)
        }
    }

    // MARK: - APEX and unusable readings

    func testAPEXValuesInTheFile() throws {
        let metadata = ShotMetadataBuilder.rendered(photo(source: .rendered))
        XCTAssertEqual(number(metadata.exif[.fNumber]), 1.78)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.apertureValue])), 2 * log2(1.78), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.exposureTime])), 1.0 / 121.0, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(number(metadata.exif[.shutterSpeedValue])), log2(121), accuracy: 1e-12)
        XCTAssertEqual(metadata.exif[.isoSpeedRatings], .integers([64]))
    }

    func testBrightnessFromTheCameraElseFromTheMeter() throws {
        let product = (1.0 / 30.0) * 400 / (1.78 * 1.78)
        let reported = photo(ShotContext(mode: .photo, meteredProduct: product), source: .rendered, brightness: -2.5)
        XCTAssertEqual(number(ShotMetadataBuilder.rendered(reported).exif[.brightnessValue]), -2.5)
        let metered = photo(ShotContext(mode: .photo, meteredProduct: product), source: .rendered)
        XCTAssertEqual(try XCTUnwrap(number(ShotMetadataBuilder.rendered(metered).exif[.brightnessValue])),
                       log2(3.125 / product), accuracy: 1e-12)
    }

    func testUnusableReadingsLeaveTheirKeysOut() {
        for bad in [0, -1, Double.nan, .infinity] {
            let noProduct = photo(ShotContext(mode: .photo, meteredProduct: bad), source: .rendered)
            XCTAssertNil(ShotMetadataBuilder.rendered(noProduct).exif[.brightnessValue], "\(bad)")
            let noTime = photo(source: .rendered, exposure: ExposureValues(seconds: bad, iso: 64, aperture: 1.78))
            XCTAssertNil(ShotMetadataBuilder.rendered(noTime).exif[.exposureTime], "\(bad)")
            XCTAssertNil(ShotMetadataBuilder.rendered(noTime).exif[.shutterSpeedValue], "\(bad)")
            let noAperture = photo(source: .rendered, exposure: ExposureValues(seconds: 0.01, iso: 64, aperture: bad))
            XCTAssertNil(ShotMetadataBuilder.rendered(noAperture).exif[.fNumber], "\(bad)")
            XCTAssertNil(ShotMetadataBuilder.rendered(noAperture).exif[.apertureValue], "\(bad)")
            let noISO = photo(source: .rendered, exposure: ExposureValues(seconds: 0.01, iso: bad, aperture: 1.78))
            XCTAssertNil(ShotMetadataBuilder.rendered(noISO).exif[.isoSpeedRatings], "\(bad)")
        }
        XCTAssertNil(ShotMetadataBuilder.rendered(photo(source: .rendered, brightness: .nan)).exif[.brightnessValue])
        let noBias = photo(ShotContext(mode: .photo, bias: .nan), source: .rendered)
        XCTAssertNil(ShotMetadataBuilder.rendered(noBias).exif[.exposureBiasValue])
        XCTAssertNil(ShotMetadataBuilder.rendered(noBias).xmpValue(.bias))
    }

    // MARK: - Everything a rendered picture says

    func testRenderedNightStackCarriesTheFullSet() {
        let metadata = ShotMetadataBuilder.rendered(nightStack())
        XCTAssertEqual(Set(metadata.exif.keys), [
            .dateTimeOriginal, .subsecTimeOriginal, .offsetTimeOriginal, .dateTimeDigitized, .subsecTimeDigitized,
            .offsetTimeDigitized, .subsecTime, .offsetTime, .lensMake, .lensModel, .lensSpecification, .focalLength,
            .focalLenIn35mmFilm, .exposureTime, .shutterSpeedValue, .fNumber, .apertureValue, .isoSpeedRatings,
            .exposureBiasValue, .exposureProgram, .exposureMode, .meteringMode, .whiteBalance, .flash, .sensingMethod,
            .sceneType, .customRendered, .sceneCaptureType, .colorSpace, .pixelXDimension, .pixelYDimension,
            .compositeImage, .sourceImageNumberOfCompositeImage, .userComment,
        ])
        // Written 1.25 s after the last of 36 frames of 1/12 from 22:04:05.532.
        XCTAssertEqual(metadata.tiff, [
            .make: .text("Apple"), .model: .text("iPhone 16 Pro"), .hostComputer: .text("iPhone 16 Pro"),
            .software: .text("Open Shutter 1.0"), .orientation: .integer(1), .dateTime: .text("2026:11:13 22:04:09"),
        ])
        XCTAssertEqual(text(metadata.exif[.lensMake]), "Apple")
        XCTAssertEqual(text(metadata.exif[.lensModel]), "iPhone 16 Pro back camera 6.765mm f/1.78")
        XCTAssertEqual(metadata.exif[.lensSpecification], .numbers([6.765, 6.765, 1.78, 1.78]))
        XCTAssertEqual(number(metadata.exif[.focalLength]), 6.765)
        XCTAssertEqual(metadata.exif[.focalLenIn35mmFilm], .integer(24))
        XCTAssertEqual(metadata.exif[.exposureBiasValue], .number(0))
        XCTAssertEqual(metadata.exif[.exposureProgram], .integer(2))
        XCTAssertEqual(metadata.exif[.exposureMode], .integer(0))
        XCTAssertEqual(metadata.exif[.meteringMode], .integer(5))
        XCTAssertEqual(metadata.exif[.whiteBalance], .integer(0))
        XCTAssertEqual(metadata.exif[.sensingMethod], .integer(2))
        XCTAssertEqual(metadata.exif[.sceneType], .integer(1))
        XCTAssertEqual(metadata.exif[.customRendered], .integer(1))
        XCTAssertEqual(metadata.exif[.sceneCaptureType], .integer(3))
        XCTAssertEqual(metadata.exif[.colorSpace], .integer(65535))
        XCTAssertEqual(metadata.exif[.pixelXDimension], .integer(4032))
        XCTAssertEqual(metadata.exif[.pixelYDimension], .integer(2268))
        XCTAssertEqual(text(metadata.exif[.userComment]), ShotMetadataBuilder.comment(nightStack()))
        XCTAssertEqual(metadata.iptc, [.originatingProgram: .text("Open Shutter"), .programVersion: .text("1.0")])
        XCTAssertEqual(metadata.creatorTool, "Open Shutter 1.0")
        XCTAssertNil(metadata.creator)
        XCTAssertNil(metadata.rights)
        XCTAssertEqual(metadata.gps, [:])
    }

    func testSRGBPicturesSaySo() {
        XCTAssertEqual(ShotMetadataBuilder.rendered(photo(source: .rendered, isSRGB: true)).exif[.colorSpace],
                       .integer(1))
    }

    func testLensFallsBackToTheDeviceName() {
        let ultraWide = LensRecord(kind: .ultraWide, name: "Back Ultra Wide Camera", equivalentFocalLength: 13)
        let metadata = ShotMetadataBuilder.rendered(photo(lens: ultraWide, source: .rendered))
        XCTAssertEqual(text(metadata.exif[.lensMake]), "Apple")
        XCTAssertEqual(text(metadata.exif[.lensModel]), "Back Ultra Wide Camera")
        XCTAssertNil(metadata.exif[.lensSpecification])
        XCTAssertNil(metadata.exif[.focalLength])
        XCTAssertEqual(metadata.exif[.focalLenIn35mmFilm], .integer(13))
        XCTAssertEqual(metadata.xmpValue(.lens), "ultraWide")
        XCTAssertEqual(metadata.xmpValue(.lensName), "Back Ultra Wide Camera")

        // A blank model is no model, and a specification needs all four of its numbers.
        let odd = LensRecord(kind: .telephoto, name: "Back Telephoto Camera", model: "  ", equivalentFocalLength: 120,
                             specification: [15.66, 2.8])
        let oddMetadata = ShotMetadataBuilder.rendered(photo(lens: odd, source: .rendered))
        XCTAssertEqual(text(oddMetadata.exif[.lensModel]), "Back Telephoto Camera")
        XCTAssertNil(oddMetadata.exif[.lensSpecification])
        let broken = LensRecord(kind: .wide, name: "Back Camera", equivalentFocalLength: 24,
                                specification: [6.765, .nan, 1.78, 1.78])
        XCTAssertNil(ShotMetadataBuilder.rendered(photo(lens: broken, source: .rendered)).exif[.lensSpecification])
    }

    func testZoomShowsInTheFocalLengthAndTheDigitalZoom() {
        func metadata(zoom: Double) -> ImageMetadata {
            var lens = mainCamera
            lens.zoomFactor = zoom
            return ShotMetadataBuilder.rendered(photo(lens: lens, source: .rendered))
        }
        XCTAssertEqual(metadata(zoom: 2).exif[.focalLenIn35mmFilm], .integer(48))
        XCTAssertEqual(metadata(zoom: 2).exif[.digitalZoomRatio], .number(2))
        XCTAssertEqual(metadata(zoom: 2).xmpValue(.zoomFactor), "2")
        // A zoom still ramping is recorded where it was.
        XCTAssertEqual(metadata(zoom: 1.4).exif[.focalLenIn35mmFilm], .integer(34))
        XCTAssertEqual(metadata(zoom: 1.4).xmpValue(.zoomFactor), "1.4")
        XCTAssertNil(metadata(zoom: 1.0005).exif[.digitalZoomRatio])
        XCTAssertEqual(metadata(zoom: 1.0005).exif[.focalLenIn35mmFilm], .integer(24))
        for unusable in [0, -2, Double.nan] {
            XCTAssertNil(metadata(zoom: unusable).exif[.digitalZoomRatio])
            XCTAssertEqual(metadata(zoom: unusable).exif[.focalLenIn35mmFilm], .integer(24))
            XCTAssertEqual(metadata(zoom: unusable).xmpValue(.zoomFactor), "1")
        }
    }

    // MARK: - XMP

    func testPhotoXMPExactly() {
        var lens = mainCamera
        lens.zoomFactor = 1.4
        let context = ShotContext(mode: .photo, exposureControl: .auto, bias: 0, meteringArea: .automatic,
                                  whiteBalance: .auto, kelvin: 5120.4, tint: 3.42, focus: .auto, lensPosition: 0.8,
                                  aspect: .sixteenNine, processing: .balanced, flash: .off, livePhoto: true,
                                  displayZoom: 1.4)
        let entries = ShotMetadataBuilder.additions(photo(context, lens: lens)).xmp
        XCTAssertEqual(entries.map(\.field), [.version, .mode, .interface, .exposureControl, .bias, .meteringArea,
                                              .whiteBalance, .kelvin, .tint, .focus, .lensPosition, .lens, .lensName,
                                              .zoom, .zoomFactor, .aspect, .processing, .flash, .livePhoto])
        XCTAssertEqual(entries.map(\.value), ["1", "photo", "simple", "auto", "0", "automatic", "auto", "5120", "3.4",
                                              "auto", "0.8", "wide", "Back Camera", "1.4", "1.4", "16:9", "balanced",
                                              "off", "True"])
    }

    func testNightXMPExactly() {
        // The scene, processing, flash and Live setting were left over from other modes and mean nothing here.
        let context = ShotContext(mode: .night, advanced: true, scene: .stars, bias: -0.7, aeLocked: true, kelvin: 3900,
                                  tint: -2, lensPosition: 0.62, aspect: .fourThree, processing: .maximum, flash: .auto,
                                  livePhoto: true, stability: .handheld, steadyAtStart: false)
        let record = stack(.night, blend: .average, frameSeconds: 1.0 / 12.0, iso: 640, used: 36, seen: 38, planned: 40,
                           gain: 1.4, aligned: true, rejectBlurry: true, noiseReduction: 0.5, captureSeconds: 3.214,
                           context: context)
        let entries = ShotMetadataBuilder.rendered(record).xmp
        XCTAssertEqual(entries.map(\.field), [.version, .mode, .interface, .exposureControl, .bias, .aeLock,
                                              .meteringArea, .whiteBalance, .kelvin, .tint, .focus, .lensPosition,
                                              .lens, .lensName, .zoom, .zoomFactor, .aspect, .blend, .frameSeconds,
                                              .frameCount, .framesCaptured, .framesPlanned, .lightSeconds,
                                              .captureSeconds, .sensorISO, .digitalGain, .aligned, .blurRejection,
                                              .noiseReduction, .stability, .steadyAtStart, .osVersion])
        XCTAssertEqual(entries.map(\.value), ["1", "night", "advanced", "auto", "-0.7", "True", "automatic", "auto",
                                              "3900", "-2", "auto", "0.62", "wide", "Back Camera", "1", "1", "4:3",
                                              "average", "0.083333", "36", "38", "40", "3", "3.214", "640", "1.4",
                                              "True", "True", "0.5", "handheld", "False", "26.1"])
    }

    func testLongXMPNamesTheScene() {
        let context = ShotContext(mode: .long, scene: .water, whiteBalanceFromScene: true,
                                  focus: .manual(lensPosition: 1),
                                  focusFromScene: true, stability: .tripod, steadyAtStart: true)
        let record = stack(.long, blend: .average, frameSeconds: 1.0 / 30.0, iso: 50, used: 60, aligned: true,
                           context: context)
        let fields = xmp(ShotMetadataBuilder.rendered(record))
        XCTAssertEqual(fields[.scene], "water")
        XCTAssertEqual(fields[.whiteBalanceFromScene], "True")
        XCTAssertEqual(fields[.focus], "infinity")
        XCTAssertEqual(fields[.blend], "average")
        XCTAssertEqual(fields[.aligned], "True")
        XCTAssertEqual(fields[.blurRejection], "False")
        XCTAssertEqual(fields[.stability], "tripod")
        XCTAssertEqual(fields[.steadyAtStart], "True")
        // Gain and noise reduction are NIGHT's; a bulb is only marked when it was one.
        XCTAssertNil(fields[.digitalGain])
        XCTAssertNil(fields[.noiseReduction])
        XCTAssertNil(fields[.bulb])
        let custom = stack(.long, blend: .additive, frameSeconds: 0.5, iso: 50, used: 4,
                           context: ShotContext(mode: .long, scene: .custom))
        XCTAssertEqual(ShotMetadataBuilder.rendered(custom).xmpValue(.scene), "custom")
    }

    func testNoSceneOutsideLONG() {
        for mode in [CaptureMode.photo, .night, .manual, .video] {
            let record = photo(ShotContext(mode: mode, scene: .stars), source: .rendered)
            XCTAssertNil(ShotMetadataBuilder.rendered(record).xmpValue(.scene), mode.rawValue)
            XCTAssertFalse(ShotMetadataBuilder.movie(record, livePhoto: false).contains { $0.key == .app(.scene) })
        }
    }

    private let stackFields: [ShotXMP.Field] = [.blend, .frameSeconds, .frameCount, .framesCaptured, .framesPlanned,
                                                .lightSeconds, .captureSeconds, .sensorISO, .digitalGain, .aligned,
                                                .blurRejection, .noiseReduction, .bulb]

    func testNoStackFieldsOnPhotos() {
        for mode in CaptureMode.allCases {
            let record = photo(ShotContext(mode: mode, stability: .tripod, steadyAtStart: true))
            for metadata in [ShotMetadataBuilder.additions(record), ShotMetadataBuilder.rendered(record)] {
                let fields = xmp(metadata)
                for field in stackFields {
                    XCTAssertNil(fields[field], "\(mode.rawValue) \(field.rawValue)")
                }
            }
        }
    }

    func testSteadinessOnlyWhereThePhoneHoldsStill() {
        let context = ShotContext(mode: .photo, stability: .tripod, steadyAtStart: true)
        XCTAssertNil(ShotMetadataBuilder.additions(photo(context)).xmpValue(.stability))
        XCTAssertNil(ShotMetadataBuilder.additions(photo(context)).xmpValue(.steadyAtStart))
        XCTAssertFalse(ShotMetadataBuilder.comment(photo(context)).contains("tripod"))
        for mode in [CaptureMode.night, .long] {
            var holding = context
            holding.mode = mode
            XCTAssertEqual(ShotMetadataBuilder.additions(photo(holding)).xmpValue(.stability), "tripod")
            XCTAssertEqual(ShotMetadataBuilder.additions(photo(holding)).xmpValue(.steadyAtStart), "True")
            XCTAssertTrue(ShotMetadataBuilder.comment(photo(holding)).contains("On a tripod."))
        }
        // A MANUAL shutter past the hardware's longest is a stack, and holds still like one.
        var manual = context
        manual.mode = .manual
        let manualStack = stack(.manual, blend: .additive, frameSeconds: 1, iso: 100, used: 8, context: manual)
        XCTAssertEqual(ShotMetadataBuilder.rendered(manualStack).xmpValue(.stability), "tripod")
        XCTAssertTrue(ShotMetadataBuilder.comment(manualStack).contains("On a tripod."))
        XCTAssertNil(ShotMetadataBuilder.additions(photo(manual)).xmpValue(.stability))
    }

    func testBracketFieldsOnlyOnBracketFrames() {
        let exposure = BracketPosition(kind: .exposure, index: 2, count: 5, step: 1, value: -1, group: group)
        let fields = xmp(ShotMetadataBuilder.additions(photo(ShotContext(mode: .photo, bracket: exposure))))
        XCTAssertEqual(fields[.bracket], "exposure")
        XCTAssertEqual(fields[.bracketIndex], "2")
        XCTAssertEqual(fields[.bracketCount], "5")
        XCTAssertEqual(fields[.bracketStep], "1")
        XCTAssertEqual(fields[.bracketValue], "-1")
        XCTAssertEqual(fields[.bracketGroup], "6F9619FF-8B86-D011-B42D-00C04FC964FF")

        let focusPosition = BracketPosition(kind: .focus, index: 3, count: 10, value: 0.42, group: group)
        let focus = xmp(ShotMetadataBuilder.additions(photo(ShotContext(mode: .photo, bracket: focusPosition))))
        XCTAssertEqual(focus[.bracket], "focus")
        XCTAssertEqual(focus[.bracketValue], "0.42")
        // No step was passed, so none is made up.
        XCTAssertNil(focus[.bracketStep])

        let kelvinPosition = BracketPosition(kind: .whiteBalance, index: 1, count: 3, step: 20, value: 4800.4,
                                             group: group)
        let whiteBalance = xmp(ShotMetadataBuilder.additions(photo(ShotContext(mode: .photo, bracket: kelvinPosition))))
        XCTAssertEqual(whiteBalance[.bracket], "whiteBalance")
        XCTAssertEqual(whiteBalance[.bracketStep], "20")
        XCTAssertEqual(whiteBalance[.bracketValue], "4800")

        // The camera numbers an exposure bracket's photos as they arrive; until then the index stays out.
        let unnumbered = BracketPosition(kind: .exposure, count: 3, step: 1, group: group)
        let waiting = xmp(ShotMetadataBuilder.additions(photo(ShotContext(mode: .photo, bracket: unnumbered))))
        XCTAssertNil(waiting[.bracketIndex])
        XCTAssertNil(waiting[.bracketValue])
        XCTAssertEqual(waiting[.bracketCount], "3")

        let bracketFields: [ShotXMP.Field] = [.bracket, .bracketIndex, .bracketCount, .bracketStep, .bracketValue,
                                              .bracketGroup]
        let plain = xmp(ShotMetadataBuilder.additions(photo()))
        let offPosition = BracketPosition(kind: .off, index: 1, count: 3, step: 1, value: 0, group: group)
        let off = xmp(ShotMetadataBuilder.additions(photo(ShotContext(mode: .photo, bracket: offPosition))))
        for field in bracketFields {
            XCTAssertNil(plain[field], field.rawValue)
            XCTAssertNil(off[field], field.rawValue)
        }
    }

    func testTimerIntervalFocusAndLocks() {
        let context = ShotContext(mode: .photo, aeLocked: false, focus: .auto, focusHeld: true, timerSeconds: 3,
                                  interval: SequencePosition(index: 3, count: 20))
        let fields = xmp(ShotMetadataBuilder.additions(photo(context)))
        XCTAssertEqual(fields[.timer], "3")
        XCTAssertEqual(fields[.intervalShot], "3")
        XCTAssertEqual(fields[.intervalCount], "20")
        XCTAssertEqual(fields[.focus], "held")
        XCTAssertNil(fields[.aeLock])
        XCTAssertNil(fields[.whiteBalanceFromScene])
        XCTAssertNil(fields[.livePhoto])
        let plain = xmp(ShotMetadataBuilder.additions(photo()))
        XCTAssertNil(plain[.timer])
        XCTAssertNil(plain[.intervalShot])
        XCTAssertNil(plain[.intervalCount])
        XCTAssertEqual(plain[.focus], "auto")
        let manualFocus = ShotContext(mode: .photo, focus: .manual(lensPosition: 0.3), lensPosition: 0.3)
        XCTAssertEqual(xmp(ShotMetadataBuilder.additions(photo(manualFocus)))[.focus], "manual")
    }

    func testOnlyRenderedFilesNameTheSystemAndOnlyTheSimulatorSaysSimulated() {
        XCTAssertNil(ShotMetadataBuilder.additions(photo()).xmpValue(.osVersion))
        XCTAssertEqual(ShotMetadataBuilder.rendered(photo(source: .rendered)).xmpValue(.osVersion), "26.1")
        XCTAssertNil(ShotMetadataBuilder.rendered(photo(source: .rendered)).xmpValue(.simulated))
        XCTAssertEqual(ShotMetadataBuilder.rendered(photo(device: simulator, source: .rendered)).xmpValue(.simulated),
                       "True")
    }

    private func videoRecord(_ configure: (inout ShotContext) -> Void = { _ in },
                             frameRate: Double = 24) -> ShotRecord {
        var video = VideoSettings()
        video.frameRate = frameRate
        var context = ShotContext(mode: .video, video: video)
        configure(&context)
        return photo(context, exposure: ExposureValues(seconds: 1.0 / 48.0, iso: 800, aperture: 1.78))
    }

    func testXMPBooleansAreTrueOrFalse() {
        let booleans: Set<ShotXMP.Field> = [.aeLock, .whiteBalanceFromScene, .livePhoto, .aligned, .blurRejection,
                                            .bulb, .steadyAtStart, .audio, .windNoiseReduction,
                                            .lowLightNoiseReduction, .simulated]
        let records = [nightStack(), stack(blend: .additive, frameSeconds: 1, iso: 50, used: 47, bulb: true),
                       photo(ShotContext(mode: .photo, aeLocked: true, whiteBalanceFromScene: true, livePhoto: true)),
                       photo(device: simulator, source: .rendered),
                       photo(ShotContext(mode: .long, steadyAtStart: false))]
        var seen: Set<ShotXMP.Field> = []
        var values: [(ShotXMP.Field, String)] = []
        for record in records {
            values += ShotMetadataBuilder.rendered(record).xmp.map { ($0.field, $0.value) }
        }
        for entry in ShotMetadataBuilder.movie(videoRecord(), livePhoto: false) {
            if case .app(let field) = entry.key, let value = text(entry.value) {
                values.append((field, value))
            }
        }
        for (field, value) in values where booleans.contains(field) {
            XCTAssertTrue(value == "True" || value == "False", "\(field.rawValue) \(value)")
            seen.insert(field)
        }
        XCTAssertEqual(seen, booleans)
    }

    func testNumbersAreWrittenTheSameInEveryRegion() throws {
        // A German phone writes a comma; the files must not.
        XCTAssertEqual(String(format: "%.6f", locale: Locale(identifier: "de_DE"), 1.0 / 12.0), "0,083333")
        let context = ShotContext(mode: .night, bias: -0.7, kelvin: 3900, tint: -2.5, lensPosition: 0.62,
                                  stability: .handheld)
        let record = stack(.night, blend: .average, frameSeconds: 1.0 / 12.0, iso: 1250, used: 1200, seen: 1250,
                           planned: 1800, gain: 1.4, noiseReduction: 0.25, context: context)
        let fields = xmp(ShotMetadataBuilder.rendered(record))
        XCTAssertEqual(fields[.frameSeconds], "0.083333")
        XCTAssertEqual(fields[.bias], "-0.7")
        XCTAssertEqual(fields[.digitalGain], "1.4")
        XCTAssertEqual(fields[.noiseReduction], "0.25")
        XCTAssertEqual(fields[.tint], "-2.5")
        // No grouping either: "1,800" would read as a different number.
        XCTAssertEqual(fields[.kelvin], "3900")
        XCTAssertEqual(fields[.framesPlanned], "1800")
        XCTAssertEqual(fields[.framesCaptured], "1250")
        XCTAssertEqual(fields[.sensorISO], "1250")
        XCTAssertEqual(fields[.lightSeconds], "100")
        let numeric: [ShotXMP.Field] = [.bias, .kelvin, .tint, .lensPosition, .zoom, .zoomFactor, .frameSeconds,
                                        .frameCount, .framesCaptured, .framesPlanned, .lightSeconds, .captureSeconds,
                                        .sensorISO, .digitalGain, .noiseReduction]
        for field in numeric {
            let value = try XCTUnwrap(fields[field], field.rawValue)
            XCTAssertNotNil(Double(value), "\(field.rawValue) \(value)")
            XCTAssertFalse(value.contains(","), "\(field.rawValue) \(value)")
        }
        XCTAssertTrue(ShotMetadataBuilder.comment(record).contains("brightened 1.4x."))
        let movie = ShotMetadataBuilder.movie(videoRecord({ $0.exposureControl = .manual }, frameRate: 29.97),
                                              livePhoto: false)
        XCTAssertEqual(text(movieValue(movie, .app(.frameRate))), "29.97")
        XCTAssertEqual(text(movieValue(movie, .cameraShutterSpeedTime)), "0.020833")
    }

    // MARK: - The comment

    func testCommentLeadsWithTheMode() {
        XCTAssertEqual(ShotMetadataBuilder.comment(photo()), "Photo. Taken with Open Shutter 1.0.")
        XCTAssertEqual(ShotMetadataBuilder.comment(photo(ShotContext(mode: .manual))),
                       "Manual exposure. Taken with Open Shutter 1.0.")
        XCTAssertEqual(ShotMetadataBuilder.comment(photo(ShotContext(mode: .video))),
                       "Video. Taken with Open Shutter 1.0.")
        XCTAssertEqual(ShotMetadataBuilder.comment(photo(ShotContext(mode: .night))),
                       "Night mode. Taken with Open Shutter 1.0.")
        XCTAssertEqual(ShotMetadataBuilder.comment(photo(ShotContext(mode: .long))),
                       "Long exposure. Taken with Open Shutter 1.0.")
    }

    func testCommentsOfTheMapsWorkedExamples() {
        XCTAssertEqual(ShotMetadataBuilder.comment(nightStack()),
                       "Night mode, 3s from 36 frames of 1/12 at ISO 640, brightened 1.4x. Handheld."
                           + " Taken with Open Shutter 1.0.")
        XCTAssertEqual(ShotMetadataBuilder.comment(stack(blend: .additive, frameSeconds: 1, iso: 100, used: 30)),
                       "Long exposure, 30s from 30 frames of 1s at ISO 100, Real. Taken with Open Shutter 1.0.")
        let water = stack(blend: .average, frameSeconds: 1.0 / 30.0, iso: 50, used: 60,
                          context: ShotContext(mode: .long, scene: .water))
        XCTAssertEqual(ShotMetadataBuilder.comment(water),
                       "Long exposure, Water, 2s from 60 frames of 1/30 at ISO 50, Blur. Taken with Open Shutter 1.0.")
        let stars = stack(blend: .additive, frameSeconds: 1, iso: 1600, used: 15,
                          context: ShotContext(mode: .long, scene: .stars, stability: .tripod))
        XCTAssertEqual(ShotMetadataBuilder.comment(stars),
                       "Long exposure, Stars, 15s from 15 frames of 1s at ISO 1600, Real. On a tripod."
                           + " Taken with Open Shutter 1.0.")
        let manual = stack(.manual, blend: .additive, frameSeconds: 1, iso: 100, used: 8)
        XCTAssertEqual(ShotMetadataBuilder.comment(manual),
                       "Manual exposure, 8s from 8 frames of 1s at ISO 100. Taken with Open Shutter 1.0.")
    }

    func testCommentOfALongExposureWithItsOwnSettingsNamesNoScene() {
        let custom = stack(blend: .lighten, frameSeconds: 0.5, iso: 200, used: 20,
                           context: ShotContext(mode: .long, scene: .custom, stability: .steady))
        XCTAssertEqual(ShotMetadataBuilder.comment(custom),
                       "Long exposure, 10s from 20 frames of 0.5s at ISO 200, Trails. Steady."
                           + " Taken with Open Shutter 1.0.")
    }

    func testCommentSentencesForBracketsAndIntervals() {
        func comment(_ context: ShotContext) -> String { ShotMetadataBuilder.comment(photo(context)) }
        let darker = BracketPosition(kind: .exposure, index: 2, count: 5, step: 1, value: -1, group: group)
        XCTAssertEqual(comment(ShotContext(mode: .photo, bracket: darker)),
                       "Photo. Exposure bracket, photo 2 of 5, -1 EV. Taken with Open Shutter 1.0.")
        let brighter = BracketPosition(kind: .exposure, index: 3, count: 5, step: 0.7, value: 0.7, group: group)
        XCTAssertEqual(comment(ShotContext(mode: .photo, bracket: brighter)),
                       "Photo. Exposure bracket, photo 3 of 5, +0.7 EV. Taken with Open Shutter 1.0.")
        let focus = BracketPosition(kind: .focus, index: 3, count: 10, value: 0.42, group: group)
        XCTAssertEqual(comment(ShotContext(mode: .photo, bracket: focus)),
                       "Photo. Focus bracket, photo 3 of 10. Taken with Open Shutter 1.0.")
        let warmth = BracketPosition(kind: .whiteBalance, index: 1, count: 3, step: 20, value: 4800, group: group)
        XCTAssertEqual(comment(ShotContext(mode: .photo, bracket: warmth)),
                       "Photo. White balance bracket, photo 1 of 3, 4800K. Taken with Open Shutter 1.0.")
        XCTAssertEqual(comment(ShotContext(mode: .photo, interval: SequencePosition(index: 3, count: 20))),
                       "Photo. Shot 3 of 20. Taken with Open Shutter 1.0.")
        XCTAssertEqual(comment(ShotContext(mode: .photo, interval: SequencePosition(index: 3, count: 20),
                                           bracket: darker)),
                       "Photo. Exposure bracket, photo 2 of 5, -1 EV. Shot 3 of 20. Taken with Open Shutter 1.0.")
        let off = BracketPosition(kind: .off, index: 1, count: 3, group: group)
        XCTAssertEqual(comment(ShotContext(mode: .photo, bracket: off)), "Photo. Taken with Open Shutter 1.0.")
    }

    func testTheSimulatedCameraSaysSoInTheComment() {
        XCTAssertEqual(ShotMetadataBuilder.comment(photo(device: simulator, source: .rendered)),
                       "Photo. Simulated camera. Taken with Open Shutter 1.0.")
    }

    func testNightNeverCallsItselfBlur() {
        for gain in [1, 1.04, 1.4, 16] {
            for stability in NightStability.allCases {
                let record = stack(.night, blend: .average, frameSeconds: 0.25, iso: 800, used: 12, gain: gain,
                                   context: ShotContext(mode: .night, stability: stability))
                let comment = ShotMetadataBuilder.comment(record)
                for word in ["Blur", "Trails", "Real", "Stacked"] {
                    XCTAssertFalse(comment.contains(word), comment)
                }
                XCTAssertTrue(comment.hasPrefix("Night mode, 3s from 12 frames of 1/4 at ISO 800"), comment)
            }
        }
        // Brightening that rounds to nothing isn't mentioned.
        let barely = stack(.night, blend: .average, frameSeconds: 0.25, iso: 800, used: 12, gain: 1.04)
        XCTAssertFalse(ShotMetadataBuilder.comment(barely).contains("brightened"))
        let pushed = stack(.night, blend: .average, frameSeconds: 0.25, iso: 800, used: 12, gain: 2.5)
        XCTAssertTrue(ShotMetadataBuilder.comment(pushed).contains(", brightened 2.5x."))
    }

    func testCommentsArePlainASCII() {
        var records = everyKindOfCameraFile()
        records += [nightStack(), stack(blend: .additive, frameSeconds: 1, iso: 50, used: 47, bulb: true)]
        for scene in LongExposureScene.allCases {
            let blend = scene.recipe?.blend ?? .additive
            records.append(stack(blend: blend, frameSeconds: scene.recipe?.frameSeconds ?? 1, iso: 100, used: 10,
                                 context: ShotContext(mode: .long, scene: scene, stability: .tripod)))
        }
        for record in records {
            let comment = ShotMetadataBuilder.comment(record)
            XCTAssertTrue(comment.unicodeScalars.allSatisfy(\.isASCII), comment)
            XCTAssertFalse(comment.contains("\u{0192}"), comment)
            XCTAssertTrue(comment.hasSuffix(" Taken with Open Shutter 1.0."), comment)
        }
    }

    // MARK: - Movies

    func testMovieIdentityAndDateComeFirst() {
        let entries = ShotMetadataBuilder.movie(videoRecord(), livePhoto: false)
        XCTAssertEqual(Array(entries.prefix(4)), [
            MovieMetadataEntry(key: .make, value: .text("Apple")),
            MovieMetadataEntry(key: .model, value: .text("iPhone 16 Pro")),
            // Apple's Camera writes the system version here.
            MovieMetadataEntry(key: .software, value: .text("26.1")),
            MovieMetadataEntry(key: .creationDate, value: .text("2026-11-13T22:04:05-0800")),
        ])
        // Every entry has a value worth writing.
        for entry in entries {
            if case .text(let value) = entry.value {
                XCTAssertFalse(value.isEmpty, "\(entry.key)")
            }
        }
        let appFields = entries.compactMap { entry -> ShotXMP.Field? in
            if case .app(let field) = entry.key { return field }
            return nil
        }
        XCTAssertEqual(appFields, ShotXMP.Field.allCases.filter(appFields.contains))
    }

    func testMovieLocationOnlyWithTagsOn() {
        let off = ShotMetadataBuilder.movie(videoRecord { $0.location = fix() }, livePhoto: false)
        XCTAssertNil(movieValue(off, .locationISO6709))
        XCTAssertNil(movieValue(off, .locationHorizontalAccuracy))
        let on = ShotMetadataBuilder.movie(videoRecord {
            $0.locationTagsOn = true
            $0.location = fix()
        }, livePhoto: false)
        XCTAssertEqual(text(movieValue(on, .locationISO6709)), "+43.6532-079.3832-012.500/")
        XCTAssertEqual(number(movieValue(on, .locationHorizontalAccuracy)), 4.7)
        let vague = ShotMetadataBuilder.movie(videoRecord {
            $0.locationTagsOn = true
            $0.location = fix(horizontalAccuracy: -1)
        }, livePhoto: false)
        XCTAssertNotNil(movieValue(vague, .locationISO6709))
        XCTAssertNil(movieValue(vague, .locationHorizontalAccuracy))
    }

    func testCameraKeysOnlyForValuesFixedForTheWholeRecording() {
        let cameraKeys: [MovieKey] = [.cameraISOSensitivity, .cameraWhiteBalance, .cameraShutterSpeedTime,
                                      .cameraShutterSpeedAngle]
        let automatic = ShotMetadataBuilder.movie(videoRecord(), livePhoto: false)
        for key in cameraKeys {
            XCTAssertNil(movieValue(automatic, key), "\(key)")
        }
        let manual = ShotMetadataBuilder.movie(videoRecord {
            $0.exposureControl = .manual
            $0.whiteBalance = .kelvin(5500, tint: 0)
        }, livePhoto: false)
        XCTAssertEqual(text(movieValue(manual, .cameraISOSensitivity)), "800")
        XCTAssertEqual(text(movieValue(manual, .cameraWhiteBalance)), "5500K")
        XCTAssertEqual(text(movieValue(manual, .cameraShutterSpeedTime)), "0.020833")
        // 1/48 s at 24 fps is half of each frame.
        XCTAssertEqual(text(movieValue(manual, .cameraShutterSpeedAngle)), "180.00deg")

        let isoOnly = ShotMetadataBuilder.movie(videoRecord { $0.exposureControl = .isoPriority }, livePhoto: false)
        XCTAssertEqual(text(movieValue(isoOnly, .cameraISOSensitivity)), "800")
        XCTAssertNil(movieValue(isoOnly, .cameraShutterSpeedTime))
        XCTAssertNil(movieValue(isoOnly, .cameraShutterSpeedAngle))
        let shutterOnly = ShotMetadataBuilder.movie(videoRecord { $0.exposureControl = .shutterPriority },
                                                    livePhoto: false)
        XCTAssertNil(movieValue(shutterOnly, .cameraISOSensitivity))
        XCTAssertEqual(text(movieValue(shutterOnly, .cameraShutterSpeedTime)), "0.020833")
        // A preset holds its light for the whole recording; auto does not.
        let daylight = ShotMetadataBuilder.movie(videoRecord { $0.whiteBalance = .preset(.daylight) }, livePhoto: false)
        XCTAssertEqual(text(movieValue(daylight, .cameraWhiteBalance)), "5500K")
        let autoPreset = ShotMetadataBuilder.movie(videoRecord { $0.whiteBalance = .preset(.auto) }, livePhoto: false)
        XCTAssertNil(movieValue(autoPreset, .cameraWhiteBalance))
    }

    func testFullFrameRatePlaybackFromOneHundredFramesASecond() {
        for (rate, plays) in [(24.0, false), (60, false), (99.9, false), (100, true), (120, true), (240, true)] {
            let entries = ShotMetadataBuilder.movie(videoRecord(frameRate: rate), livePhoto: false)
            XCTAssertEqual(movieValue(entries, .fullFrameRatePlaybackIntent), plays ? .integer(1) : nil, "\(rate)")
        }
    }

    func testLivePhotoMovieKeepsOnlyTheLocationTheOwnerAndTheMode() {
        let context = ShotContext(mode: .photo, livePhoto: true, locationTagsOn: true, location: fix(),
                                  artist: "Ada Lovelace")
        let entries = ShotMetadataBuilder.movie(photo(context), livePhoto: true)
        XCTAssertEqual(entries.map(\.key), [.locationISO6709, .locationHorizontalAccuracy, .author, .app(.version),
                                            .app(.mode)])
        XCTAssertEqual(text(movieValue(entries, .app(.version))), "1")
        XCTAssertEqual(text(movieValue(entries, .app(.mode))), "photo")
        let untagged = ShotMetadataBuilder.movie(photo(ShotContext(mode: .photo, livePhoto: true)), livePhoto: true)
        XCTAssertEqual(untagged.map(\.key), [.app(.version), .app(.mode)])
    }

    func testVideoAppKeysDescribeTheRecording() {
        let entries = ShotMetadataBuilder.movie(videoRecord(), livePhoto: false)
        var fields: [ShotXMP.Field: String] = [:]
        for entry in entries {
            guard case .app(let field) = entry.key else { continue }
            // QuickTime's app items are UTF-8 text.
            guard case .text(let value) = entry.value else {
                XCTFail("\(field.rawValue) is not text")
                continue
            }
            fields[field] = value
        }
        XCTAssertEqual(fields[.mode], "video")
        XCTAssertEqual(fields[.stabilization], "standard")
        XCTAssertEqual(fields[.codec], "hevc")
        XCTAssertEqual(fields[.colorMode], "sdr")
        XCTAssertEqual(fields[.frameRate], "24")
        XCTAssertEqual(fields[.resolution], "uhd4K")
        XCTAssertEqual(fields[.audio], "True")
        XCTAssertEqual(fields[.windNoiseReduction], "True")
        XCTAssertEqual(fields[.lowLightNoiseReduction], "False")
        for field in stackFields + [.aspect, .processing, .flash, .livePhoto, .bracket, .osVersion, .scene] {
            XCTAssertNil(fields[field], field.rawValue)
        }
        // Image files never carry the recording's fields.
        XCTAssertNil(ShotMetadataBuilder.additions(videoRecord()).xmpValue(.codec))
    }

    // MARK: - Who made the file

    func testTheSimulatedCameraNeverClaimsAnAppleCamera() {
        let simulatedVideo = photo(ShotContext(mode: .video, video: VideoSettings()), device: simulator,
                                   source: .rendered)
        let records = [photo(device: simulator, source: .rendered), simulatedVideo,
                       stack(blend: .average, frameSeconds: 1.0 / 30.0, iso: 100, used: 60, device: simulator),
                       stack(.night, blend: .average, frameSeconds: 0.25, iso: 800, used: 12, gain: 2,
                             device: simulator)]
        for record in records {
            for text in allText(record) {
                XCTAssertFalse(text.contains("Apple"), text)
            }
        }
        let metadata = ShotMetadataBuilder.rendered(photo(device: simulator, source: .rendered))
        XCTAssertEqual(text(metadata.tiff[.make]), "Open Shutter")
        XCTAssertEqual(text(metadata.tiff[.model]), "Simulated camera")
        XCTAssertNil(metadata.tiff[.hostComputer])
        // The lens record says Apple by default; a simulated lens is the app's.
        XCTAssertEqual(text(metadata.exif[.lensMake]), "Open Shutter")
        // No sensor to describe.
        XCTAssertNil(metadata.exif[.sensingMethod])
        XCTAssertNil(metadata.exif[.sceneType])
        XCTAssertEqual(metadata.xmpValue(.simulated), "True")
        let movie = ShotMetadataBuilder.movie(simulatedVideo, livePhoto: false)
        XCTAssertEqual(text(movieValue(movie, .make)), "Open Shutter")
        XCTAssertEqual(text(movieValue(movie, .model)), "Simulated camera")
    }

    func testDeviceIdentity() {
        XCTAssertEqual(phone.make, "Apple")
        XCTAssertFalse(phone.isSimulated)
        XCTAssertEqual(phone.appSignature, "Open Shutter 1.0")
        XCTAssertEqual(simulator.make, "Open Shutter")
        XCTAssertEqual(simulator.model, "Simulated camera")
        XCTAssertEqual(simulator.systemVersion, "26.1")
        XCTAssertTrue(simulator.isSimulated)
        XCTAssertEqual(DeviceIdentity(model: "iPhone", systemVersion: "26.1", appVersion: " ").appSignature,
                       "Open Shutter")
    }

    func testAnUnknownModelIsLeftOutRatherThanWrittenBlank() {
        let blank = DeviceIdentity(model: " ", systemVersion: "", appVersion: "1.0")
        let metadata = ShotMetadataBuilder.rendered(photo(device: blank, source: .rendered))
        XCTAssertNil(metadata.tiff[.model])
        XCTAssertNil(metadata.tiff[.hostComputer])
        XCTAssertEqual(text(metadata.tiff[.make]), "Apple")
        XCTAssertNil(metadata.xmpValue(.osVersion))
        let movie = ShotMetadataBuilder.movie(photo(device: blank), livePhoto: false)
        XCTAssertNil(movieValue(movie, .model))
        XCTAssertNil(movieValue(movie, .software))
    }

    // MARK: - Your name and copyright

    func testOwnerIsWrittenWhenSettingsHaveIt() {
        let context = ShotContext(mode: .photo, artist: " Ada Lovelace ", copyright: "\u{00A9} 2026 Ada Lovelace")
        let files = [ShotMetadataBuilder.rendered(photo(context, source: .rendered)),
                     ShotMetadataBuilder.additions(photo(context))]
        for metadata in files {
            XCTAssertEqual(text(metadata.tiff[.artist]), "Ada Lovelace")
            XCTAssertEqual(text(metadata.tiff[.copyright]), "\u{00A9} 2026 Ada Lovelace")
            XCTAssertEqual(metadata.creator, "Ada Lovelace")
            XCTAssertEqual(metadata.rights, "\u{00A9} 2026 Ada Lovelace")
        }
        for livePhoto in [false, true] {
            let movie = ShotMetadataBuilder.movie(photo(context), livePhoto: livePhoto)
            XCTAssertEqual(text(movieValue(movie, .author)), "Ada Lovelace")
            XCTAssertEqual(text(movieValue(movie, .copyright)), "\u{00A9} 2026 Ada Lovelace")
        }
        // The comment stays ASCII; the owner has fields of its own.
        XCTAssertFalse(ShotMetadataBuilder.comment(photo(context)).contains("Ada"))
    }

    func testEmptyOwnerWritesNothing() {
        for (artist, copyright) in [("", ""), ("   ", "\n"), ("", " \t ")] {
            let context = ShotContext(mode: .photo, artist: artist, copyright: copyright)
            let files = [ShotMetadataBuilder.rendered(photo(context, source: .rendered)),
                         ShotMetadataBuilder.additions(photo(context))]
            for metadata in files {
                XCTAssertNil(metadata.tiff[.artist])
                XCTAssertNil(metadata.tiff[.copyright])
                XCTAssertNil(metadata.creator)
                XCTAssertNil(metadata.rights)
            }
            for livePhoto in [false, true] {
                let keys = ShotMetadataBuilder.movie(photo(context), livePhoto: livePhoto).map(\.key)
                XCTAssertFalse(keys.contains(.author))
                XCTAssertFalse(keys.contains(.copyright))
            }
        }
        // Each one is written on its own.
        let nameOnly = ShotMetadataBuilder.additions(photo(ShotContext(mode: .photo, artist: "Ada Lovelace")))
        XCTAssertEqual(text(nameOnly.tiff[.artist]), "Ada Lovelace")
        XCTAssertNil(nameOnly.tiff[.copyright])
        XCTAssertEqual(nameOnly.creator, "Ada Lovelace")
        XCTAssertNil(nameOnly.rights)
    }

    // MARK: - The app's namespace

    func testNamespaceAndNamesAreFixed() {
        XCTAssertEqual(ShotXMP.namespace, "http://ns.katsuma.ca/openshutter/1.0/")
        XCTAssertEqual(ShotXMP.prefix, "openshutter")
        XCTAssertEqual(ShotXMP.version, "1")
        XCTAssertEqual(ShotXMP.Field.frameCount.path, "openshutter:FrameCount")
        XCTAssertEqual(ShotXMP.Field.mode.quickTimeKey, "ca.katsuma.openshutter.Mode")
        XCTAssertEqual(ShotXMP.Field.lightSeconds.rawValue, "LightSeconds")
        XCTAssertEqual(ShotXMP.Field.captureSeconds.rawValue, "CaptureSeconds")
        let names = ShotXMP.Field.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            // XML names: a capital first, then letters and digits.
            XCTAssertEqual(name.first?.isUppercase, true, name)
            XCTAssertTrue(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, name)
        }
    }

    func testStackSummaryFromTheXMP() {
        func summary(_ record: ShotRecord) -> String? {
            ShotXMP.stackSummary(xmp(ShotMetadataBuilder.rendered(record)))
        }
        XCTAssertEqual(summary(stack(blend: .average, frameSeconds: 1.0 / 30.0, iso: 50, used: 900)),
                       "30s, 900 frames of 1/30")
        XCTAssertEqual(summary(stack(blend: .additive, frameSeconds: 1, iso: 100, used: 30)), "30s, 30 frames of 1s")
        XCTAssertEqual(summary(nightStack()), "3s, 36 frames of 1/12")
        XCTAssertEqual(summary(stack(blend: .additive, frameSeconds: 1, iso: 50, used: 47, planned: 1800, bulb: true)),
                       "47s, 47 frames of 1s")
        XCTAssertEqual(summary(stack(blend: .additive, frameSeconds: 2, iso: 50, used: 1)), "2s, 1 frame of 2s")
        XCTAssertNil(summary(photo()))
        XCTAssertNil(ShotXMP.stackSummary([:]))
        XCTAssertNil(ShotXMP.stackSummary([.frameCount: "0"]))
        XCTAssertNil(ShotXMP.stackSummary([.frameCount: "many"]))
        XCTAssertEqual(ShotXMP.stackSummary([.frameCount: "60"]), "2s, 60 frames")
    }

    // MARK: - The record types

    func testGeoTagKeepsTheOldLocationStampsShape() {
        let tag = GeoTag(latitude: 43.6532, longitude: -79.3832, altitude: 87, horizontalAccuracy: 5,
                         timestamp: fixTime)
        XCTAssertEqual(tag.verticalAccuracy, -1)
        XCTAssertNil(tag.speed)
        XCTAssertNil(tag.course)
        XCTAssertNil(tag.heading)
        XCTAssertTrue(tag.headingIsTrueNorth)
        XCTAssertTrue(tag.hasValidCoordinates)
        XCTAssertFalse(tag.hasValidAltitude)
        XCTAssertTrue(fix().hasValidAltitude)
    }

    func testTheLocationGateNeedsTheSettingAndAFix() {
        XCTAssertNil(ShotContext(mode: .photo, locationTagsOn: false, location: fix()).taggedLocation)
        XCTAssertNil(ShotContext(mode: .photo, locationTagsOn: true, location: nil).taggedLocation)
        XCTAssertNil(ShotContext(mode: .photo, locationTagsOn: true, location: fix(latitude: 95)).taggedLocation)
        XCTAssertEqual(ShotContext(mode: .photo, locationTagsOn: true, location: fix()).taggedLocation, fix())
    }

    func testStackRecordFromAPlan() {
        let plan = StackPlan(purpose: .night, blend: .average, frameSeconds: 1.0 / 12.0, iso: 640, aperture: 1.78,
                             frameCount: 40, align: true, rejectBlurryFrames: true, digitalGain: 1.4)
        let record = StackRecord(plan: plan, framesSeen: 38, framesUsed: 36, noiseReduction: 0.5, captureSeconds: 3.2)
        XCTAssertEqual(record, StackRecord(purpose: .night, blend: .average, frameSeconds: 1.0 / 12.0, sensorISO: 640,
                                           digitalGain: 1.4, framesPlanned: 40, framesSeen: 38, framesUsed: 36,
                                           aligned: true, rejectBlurry: true, noiseReduction: 0.5, bulb: false,
                                           captureSeconds: 3.2))
    }

    func testRecordDefaultsAndLensKinds() {
        let record = ShotRecord(source: .camera, context: ShotContext(mode: .photo), device: phone, lens: mainCamera,
                                exposure: ExposureValues(seconds: 0.01, iso: 100, aperture: 1.78), date: press)
        XCTAssertEqual(record.writtenDate, press)
        XCTAssertNil(record.endDate)
        XCTAssertNil(record.stack)
        // The same raw values as the app's LensInfo.Kind, so one maps to the other by name.
        XCTAssertEqual(LensKind.allCases.map(\.rawValue), ["ultraWide", "wide", "telephoto", "front", "external"])
        XCTAssertTrue(LensKind.front.isFront)
        XCTAssertFalse(LensKind.wide.isFront)
    }

    // MARK: - Text rules

    func testNoTextUsesADash() {
        var records = everyKindOfCameraFile()
        records += [nightStack(), videoRecord { $0.exposureControl = .manual },
                    photo(device: simulator, source: .rendered)]
        for scene in LongExposureScene.allCases {
            records.append(stack(blend: .lighten, frameSeconds: 0.5, iso: 100, used: 10,
                                 context: ShotContext(mode: .long, scene: scene, stability: .steady)))
        }
        for record in records {
            let summary = ShotXMP.stackSummary(xmp(ShotMetadataBuilder.rendered(record))) ?? ""
            for text in allText(record) + [summary] {
                XCTAssertFalse(text.contains("\u{2014}"), text)
                XCTAssertFalse(text.contains("\u{2013}"), text)
            }
        }
    }
}
