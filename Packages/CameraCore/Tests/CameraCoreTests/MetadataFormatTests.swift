import XCTest
@testable import CameraCore

final class MetadataFormatTests: XCTestCase {
    /// 2026-11-13 09:41:12 UTC, worked out apart from Foundation.
    private let morningUTC = Date(timeIntervalSince1970: 1_794_562_872)

    // MARK: - Location

    func testCoordinatesFromValueAndReference() throws {
        XCTAssertEqual(MetadataFormat.coordinates(latitude: 43.6532, latitudeRef: "N", longitude: 79.3832,
                                                  longitudeRef: "W"),
                       "43.65320\u{00B0} N, 79.38320\u{00B0} W")
        XCTAssertEqual(MetadataFormat.coordinates(latitude: 33.8688, latitudeRef: "S", longitude: 151.2093,
                                                  longitudeRef: "E"),
                       "33.86880\u{00B0} S, 151.20930\u{00B0} E")
        XCTAssertEqual(try XCTUnwrap(MetadataFormat.signedDegrees(43.6532, ref: "N")), 43.6532, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(MetadataFormat.signedDegrees(79.3832, ref: "W")), -79.3832, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(MetadataFormat.signedDegrees(33.8688, ref: "S")), -33.8688, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(MetadataFormat.signedDegrees(151.2093, ref: "E")), 151.2093, accuracy: 1e-12)
    }

    func testReferencesAreReadLoosely() throws {
        // Lower case, padding and the NUL some writers leave behind all mean the same reference.
        XCTAssertEqual(MetadataFormat.signedDegrees(79.3832, ref: "w"), -79.3832)
        XCTAssertEqual(MetadataFormat.signedDegrees(79.3832, ref: " W\0"), -79.3832)
        // A reference says which side; a sign stored with it doesn't change that.
        XCTAssertEqual(MetadataFormat.signedDegrees(-43.6532, ref: "N"), 43.6532)
        // No reference, or one that isn't a side: the value's own sign.
        XCTAssertEqual(MetadataFormat.signedDegrees(-43.6532, ref: nil), -43.6532)
        XCTAssertEqual(MetadataFormat.signedDegrees(43.6532, ref: "Q"), 43.6532)
        XCTAssertEqual(MetadataFormat.latitude(-43.6532, ref: nil), "43.65320\u{00B0} S")
    }

    func testCoordinatesOffTheGlobeAreNotShown() {
        XCTAssertNil(MetadataFormat.latitude(91, ref: "N"))
        XCTAssertNil(MetadataFormat.longitude(181, ref: "E"))
        XCTAssertNil(MetadataFormat.signedDegrees(.nan, ref: "N"))
        XCTAssertNil(MetadataFormat.coordinates(latitude: .infinity, latitudeRef: "N", longitude: 0, longitudeRef: "E"))
    }

    func testAltitudeAboveAndBelowSeaLevel() {
        XCTAssertEqual(MetadataFormat.altitude(12.3, ref: 0), "12.3 m above sea level")
        XCTAssertEqual(MetadataFormat.altitude(5, ref: 1), "5 m below sea level")
        XCTAssertEqual(MetadataFormat.signedAltitude(5, ref: 1), -5)
        XCTAssertEqual(MetadataFormat.signedAltitude(5, ref: 0), 5)
        // Some files store the sign instead of the reference.
        XCTAssertEqual(MetadataFormat.altitude(-5, ref: nil), "5 m below sea level")
        XCTAssertEqual(MetadataFormat.altitude(120.04, ref: nil), "120 m above sea level")
        XCTAssertNil(MetadataFormat.altitude(.nan, ref: 0))
    }

    func testSpeedDirectionAndAccuracy() {
        XCTAssertEqual(MetadataFormat.speed(36, ref: "K"), "36 km/h")
        XCTAssertEqual(MetadataFormat.speed(36.04, ref: nil), "36 km/h")
        XCTAssertEqual(MetadataFormat.speed(10, ref: "M"), "10 mph")
        XCTAssertEqual(MetadataFormat.speed(5.5, ref: "N"), "5.5 knots")
        XCTAssertNil(MetadataFormat.speed(-1, ref: "K"))

        XCTAssertEqual(MetadataFormat.direction(190.4, ref: "T"), "190\u{00B0} from true north")
        XCTAssertEqual(MetadataFormat.direction(12, ref: "M"), "12\u{00B0} from magnetic north")
        XCTAssertEqual(MetadataFormat.direction(370, ref: "T"), "10\u{00B0} from true north")
        XCTAssertEqual(MetadataFormat.direction(-10, ref: nil), "350\u{00B0} from true north")
        XCTAssertEqual(MetadataFormat.direction(359.6, ref: "T"), "0\u{00B0} from true north")
        XCTAssertNil(MetadataFormat.direction(.nan, ref: "T"))

        XCTAssertEqual(MetadataFormat.positioningError(4.73), "4.7 m")
        XCTAssertEqual(MetadataFormat.positioningError(5), "5 m")
        XCTAssertNil(MetadataFormat.positioningError(-1))
    }

    func testGPSDateIsUTC() throws {
        let fix = Date(timeIntervalSince1970: 1_794_641_400)  // 2026-11-14 07:30 UTC
        XCTAssertEqual(MetadataFormat.gpsDate(dateStamp: "2026:11:14", timeStamp: "07:30:00"), fix)
        XCTAssertEqual(try XCTUnwrap(MetadataFormat.gpsDate(dateStamp: "2026:11:14", timeStamp: "07:30:00.50"))
            .timeIntervalSince(fix), 0.5, accuracy: 1e-6)
        XCTAssertNil(MetadataFormat.gpsDate(dateStamp: "", timeStamp: "07:30:00"))
        XCTAssertNil(MetadataFormat.gpsDate(dateStamp: "2026:11:14", timeStamp: "25:00:00"))
    }

    // MARK: - Dates

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    func testExifDateWithItsOffset() {
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 10:41:12", offset: "+01:00"), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 05:11:12", offset: "-04:30"), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 15:11:12", offset: "+0530"), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 09:41:12", offset: "Z"), morningUTC)
    }

    func testExifDateWithSubseconds() throws {
        let date = try XCTUnwrap(MetadataFormat.date(fromExif: "2026:11:13 10:41:12", offset: "+01:00",
                                                     subseconds: "532"))
        XCTAssertEqual(date.timeIntervalSince(morningUTC), 0.532, accuracy: 1e-6)
        let short = try XCTUnwrap(MetadataFormat.date(fromExif: "2026:11:13 10:41:12", offset: "+01:00",
                                                      subseconds: "5"))
        XCTAssertEqual(short.timeIntervalSince(morningUTC), 0.5, accuracy: 1e-6)
        // Subseconds that aren't digits are ignored, not guessed at.
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 10:41:12", offset: "+01:00", subseconds: "abc"),
                       morningUTC)
    }

    func testExifDateWithoutAnOffsetUsesTheZoneItIsGiven() {
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 09:41:12", assuming: utc), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 10:41:12", assuming: TimeZone(secondsFromGMT: 3600)!),
                       morningUTC)
        // An unreadable offset is no offset.
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 09:41:12", offset: "later", assuming: utc), morningUTC)
    }

    func testExifDateVariantsFilesCarry() {
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026-11-13T10:41:12", offset: "+01:00"), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 10:41:12\0", offset: "+01:00"), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: " 2026:11:13 10:41:12 ", offset: "+01:00"), morningUTC)
        XCTAssertEqual(MetadataFormat.date(fromExif: "2026:11:13 10:41", offset: "+01:00"),
                       morningUTC.addingTimeInterval(-12))
    }

    func testUnreadableExifDates() {
        for text in ["", "    ", "0000:00:00 00:00:00", "2026:11:13", "2026:02:31 10:00:00", "2026:13:01 10:00:00",
                     "2026:11:13 24:00:00", "2026:11:13 10:61:00", "20261113 104112", "2026:11:13 +10:41:12"] {
            XCTAssertNil(MetadataFormat.date(fromExif: text, offset: "+01:00"), text)
        }
    }

    func testWrittenDatesReadBackAsTheSameMoment() throws {
        let zones = try ["America/Los_Angeles", "Asia/Kolkata", "America/St_Johns", "Australia/Lord_Howe", "UTC"]
            .map { try XCTUnwrap(TimeZone(identifier: $0), $0) }
        let moments = [morningUTC.addingTimeInterval(0.532), Date(timeIntervalSince1970: 1_772_963_999.25),
                       Date(timeIntervalSince1970: 1_793_523_600.9996), Date(timeIntervalSince1970: 1_784_116_800.007)]
        for zone in zones {
            for moment in moments {
                let read = try XCTUnwrap(MetadataFormat.date(fromExif: ExifFormat.exifDate(moment, timeZone: zone),
                                                             offset: ExifFormat.offset(moment, timeZone: zone),
                                                             subseconds: ExifFormat.subseconds(moment)))
                // Subseconds keep milliseconds, and the last one rounds down.
                XCTAssertEqual(read.timeIntervalSince(moment), 0, accuracy: 0.001, "\(zone.identifier) \(moment)")
            }
        }
    }

    func testTimeZoneFromAnOffset() {
        XCTAssertEqual(MetadataFormat.timeZone(offset: "+05:30")?.secondsFromGMT(), 19_800)
        XCTAssertEqual(MetadataFormat.timeZone(offset: "-0330")?.secondsFromGMT(), -12_600)
        XCTAssertEqual(MetadataFormat.timeZone(offset: "+01")?.secondsFromGMT(), 3600)
        XCTAssertEqual(MetadataFormat.timeZone(offset: "Z")?.secondsFromGMT(), 0)
        for bad in ["05:30", "+25:00", "+05:60", "+5:30", "", "+05:3"] {
            XCTAssertNil(MetadataFormat.timeZone(offset: bad), bad)
        }
    }

    // MARK: - EXIF values

    func testFlashBits() {
        XCTAssertEqual(MetadataFormat.flash(0x00), "Did not fire")
        XCTAssertEqual(MetadataFormat.flash(0x01), "Fired")
        XCTAssertEqual(MetadataFormat.flash(0x10), "Off, did not fire")
        XCTAssertEqual(MetadataFormat.flash(0x18), "Auto, did not fire")
        XCTAssertEqual(MetadataFormat.flash(0x19), "Auto, fired")
        XCTAssertEqual(MetadataFormat.flash(0x09), "On, fired")
        XCTAssertEqual(MetadataFormat.flash(0x05), "Fired, return not detected")
        XCTAssertEqual(MetadataFormat.flash(0x07), "Fired, return detected")
        XCTAssertEqual(MetadataFormat.flash(0x0D), "On, fired, return not detected")
        XCTAssertEqual(MetadataFormat.flash(0x41), "Fired, red-eye reduction")
        XCTAssertEqual(MetadataFormat.flash(0x59), "Auto, fired, red-eye reduction")
        XCTAssertEqual(MetadataFormat.flash(0x20), "No flash function")
        XCTAssertEqual(MetadataFormat.flash(0x30), "No flash function")
    }

    func testExposureProgramNames() {
        let names = ["Not defined", "Manual", "Normal program", "Aperture priority", "Shutter priority",
                     "Creative program", "Action program", "Portrait mode", "Landscape mode"]
        for (value, name) in names.enumerated() {
            XCTAssertEqual(MetadataFormat.exposureProgram(value), name)
        }
        XCTAssertEqual(MetadataFormat.exposureProgram(9), "Unknown (9)")
        XCTAssertEqual(MetadataFormat.exposureProgram(-1), "Unknown (-1)")
    }

    func testMeteringModeNames() {
        let names = [0: "Unknown", 1: "Average", 2: "Center-weighted average", 3: "Spot", 4: "Multi-spot", 5: "Pattern",
                     6: "Partial", 255: "Other"]
        for (value, name) in names {
            XCTAssertEqual(MetadataFormat.meteringMode(value), name)
        }
        XCTAssertEqual(MetadataFormat.meteringMode(7), "Unknown (7)")
    }

    func testOrientationNames() {
        let names = [1: "Normal", 2: "Mirrored horizontally", 3: "Rotated 180\u{00B0}", 4: "Mirrored vertically",
                     5: "Mirrored horizontally, rotated 90\u{00B0} counterclockwise", 6: "Rotated 90\u{00B0} clockwise",
                     7: "Mirrored horizontally, rotated 90\u{00B0} clockwise", 8: "Rotated 90\u{00B0} counterclockwise"]
        for (value, name) in names {
            XCTAssertEqual(MetadataFormat.orientation(value), name)
        }
        XCTAssertEqual(MetadataFormat.orientation(0), "Unknown (0)")
        XCTAssertEqual(MetadataFormat.orientation(9), "Unknown (9)")
    }

    func testOtherEnumeratedValues() {
        XCTAssertEqual(MetadataFormat.whiteBalance(0), "Auto")
        XCTAssertEqual(MetadataFormat.whiteBalance(1), "Manual")
        XCTAssertEqual(MetadataFormat.whiteBalance(2), "Unknown (2)")
        XCTAssertEqual(MetadataFormat.exposureMode(0), "Auto")
        XCTAssertEqual(MetadataFormat.exposureMode(1), "Manual")
        XCTAssertEqual(MetadataFormat.exposureMode(2), "Auto bracket")

        XCTAssertEqual(MetadataFormat.lightSource(1), "Daylight")
        XCTAssertEqual(MetadataFormat.lightSource(3), "Tungsten")
        XCTAssertEqual(MetadataFormat.lightSource(10), "Cloudy")
        XCTAssertEqual(MetadataFormat.lightSource(11), "Shade")
        XCTAssertEqual(MetadataFormat.lightSource(21), "D65")
        XCTAssertEqual(MetadataFormat.lightSource(255), "Other")
        XCTAssertEqual(MetadataFormat.lightSource(5), "Unknown (5)")

        XCTAssertEqual(MetadataFormat.sceneCaptureType(0), "Standard")
        XCTAssertEqual(MetadataFormat.sceneCaptureType(3), "Night scene")
        XCTAssertEqual(MetadataFormat.sceneCaptureType(4), "Unknown (4)")
        XCTAssertEqual(MetadataFormat.sceneType(1), "Directly photographed")
        XCTAssertEqual(MetadataFormat.sensingMethod(2), "One-chip color area")
        XCTAssertEqual(MetadataFormat.sensingMethod(6), "Unknown (6)")

        XCTAssertEqual(MetadataFormat.colorSpace(1), "sRGB")
        XCTAssertEqual(MetadataFormat.colorSpace(65535), "Uncalibrated")
        XCTAssertEqual(MetadataFormat.colorSpace(3), "Unknown (3)")

        XCTAssertEqual(MetadataFormat.customRendered(0), "Normal")
        XCTAssertEqual(MetadataFormat.customRendered(1), "Custom")
        XCTAssertEqual(MetadataFormat.customRendered(6), "Panorama")
        XCTAssertEqual(MetadataFormat.customRendered(8), "Portrait")
        XCTAssertEqual(MetadataFormat.customRendered(5), "Unknown (5)")

        XCTAssertEqual(MetadataFormat.compositeImage(1), "Not a composite")
        XCTAssertEqual(MetadataFormat.compositeImage(2), "General composite")
        XCTAssertEqual(MetadataFormat.compositeImage(3), "Composite captured while shooting")
    }

    func testTheBuildersOwnValuesReadAsWhatTheyMean() {
        // What ShotMetadataBuilder writes comes back as the words the photo info tool shows.
        XCTAssertEqual(MetadataFormat.flash(16), "Off, did not fire")
        XCTAssertEqual(MetadataFormat.flash(32), "No flash function")
        XCTAssertEqual(MetadataFormat.exposureProgram(ExposureControl.shutterPriority.exifProgram), "Shutter priority")
        XCTAssertEqual(MetadataFormat.exposureProgram(ExposureControl.aperturePriority.exifProgram),
                       "Aperture priority")
        XCTAssertEqual(MetadataFormat.exposureProgram(ExposureControl.manual.exifProgram), "Manual")
        XCTAssertEqual(MetadataFormat.exposureProgram(ExposureControl.auto.exifProgram), "Normal program")
    }

    func testLensSpecification() {
        XCTAssertEqual(MetadataFormat.lensSpecification([1.54, 6.86, 1.78, 2.2]), "1.54-6.86 mm f/1.78-2.2")
        XCTAssertEqual(MetadataFormat.lensSpecification([6.765, 6.765, 1.78, 1.78]), "6.765 mm f/1.78")
        // EXIF writes 0 for what it doesn't know.
        XCTAssertEqual(MetadataFormat.lensSpecification([24, 70, 0, 0]), "24-70 mm")
        XCTAssertEqual(MetadataFormat.lensSpecification([0, 0, 2.8, 0]), "f/2.8")
        XCTAssertNil(MetadataFormat.lensSpecification([0, 0, 0, 0]))
        XCTAssertNil(MetadataFormat.lensSpecification([6.765, 1.78]))
        XCTAssertNil(MetadataFormat.lensSpecification([.nan, .nan, .nan, .nan]))
    }

    // MARK: - Names

    func testReadableKeys() {
        XCTAssertEqual(MetadataFormat.readableKey("SubsecTimeOriginal"), "Subsec time original")
        XCTAssertEqual(MetadataFormat.readableKey("ISOSpeedRatings"), "ISO speed ratings")
        XCTAssertEqual(MetadataFormat.readableKey("FocalLenIn35mmFilm"), "Focal len in 35mm film")
        XCTAssertEqual(MetadataFormat.readableKey("PixelXDimension"), "Pixel X dimension")
        XCTAssertEqual(MetadataFormat.readableKey("ExposureTime"), "Exposure time")
        XCTAssertEqual(MetadataFormat.readableKey("GPSVersion"), "GPS version")
        XCTAssertEqual(MetadataFormat.readableKey("DNGBackwardVersion"), "DNG backward version")
        XCTAssertEqual(MetadataFormat.readableKey("HPositioningError"), "H positioning error")
        XCTAssertEqual(MetadataFormat.readableKey("LensSerialNumber"), "Lens serial number")
        XCTAssertEqual(MetadataFormat.readableKey("Model"), "Model")
        XCTAssertEqual(MetadataFormat.readableKey("brightness"), "Brightness")
        XCTAssertEqual(MetadataFormat.readableKey("Camera_owner name"), "Camera owner name")
        XCTAssertEqual(MetadataFormat.readableKey("14"), "14")
        XCTAssertEqual(MetadataFormat.readableKey(""), "")
    }

    // MARK: - Text rules

    func testNoTextUsesADash() {
        var texts: [String] = []
        texts += (-1...300).map(MetadataFormat.flash)
        texts += (-1...10).map(MetadataFormat.exposureProgram)
        texts += (-1...10).map(MetadataFormat.orientation)
        for value in Array(0...24) + [255, 65535] {
            texts += [MetadataFormat.meteringMode(value), MetadataFormat.lightSource(value),
                      MetadataFormat.whiteBalance(value), MetadataFormat.exposureMode(value),
                      MetadataFormat.sceneCaptureType(value), MetadataFormat.sceneType(value),
                      MetadataFormat.sensingMethod(value), MetadataFormat.customRendered(value),
                      MetadataFormat.compositeImage(value), MetadataFormat.colorSpace(value)]
        }
        texts += [MetadataFormat.lensSpecification([1.54, 6.86, 1.78, 2.2]), MetadataFormat.altitude(-5, ref: nil),
                  MetadataFormat.coordinates(latitude: 43.6532, latitudeRef: "N", longitude: 79.3832,
                                             longitudeRef: "W"),
                  MetadataFormat.direction(190, ref: "M"), MetadataFormat.speed(36, ref: "K")].compactMap { $0 }
        for text in texts {
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("\u{2013}"), text)
        }
    }
}
