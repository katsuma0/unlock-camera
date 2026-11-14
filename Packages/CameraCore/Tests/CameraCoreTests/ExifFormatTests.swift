import XCTest
@testable import CameraCore

final class ExifFormatTests: XCTestCase {
    // Moments as seconds since 1970, worked out apart from Foundation so the tests don't check the calendar against
    // itself.
    /// 2026-11-13 22:04:05 UTC.
    private let evening = Date(timeIntervalSince1970: 1_794_607_445)
    /// 2026-11-14 06:04:05 UTC, which is 22:04:05 the evening before in Los Angeles.
    private let losAngelesEvening = Date(timeIntervalSince1970: 1_794_636_245)

    private func zone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier), "no time zone \(identifier)")
    }

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    // MARK: - Dates

    func testExifDateInUTC() {
        XCTAssertEqual(ExifFormat.exifDate(evening, timeZone: utc), "2026:11:13 22:04:05")
        XCTAssertEqual(ExifFormat.offset(evening, timeZone: utc), "+00:00")
    }

    func testExifDateIsTheWallClockOfTheGivenZone() throws {
        let kolkata = try zone("Asia/Kolkata")
        XCTAssertEqual(ExifFormat.exifDate(evening, timeZone: kolkata), "2026:11:14 03:34:05")
        XCTAssertEqual(ExifFormat.offset(evening, timeZone: kolkata), "+05:30")

        let kathmandu = try zone("Asia/Kathmandu")
        XCTAssertEqual(ExifFormat.exifDate(evening, timeZone: kathmandu), "2026:11:14 03:49:05")
        XCTAssertEqual(ExifFormat.offset(evening, timeZone: kathmandu), "+05:45")

        let losAngeles = try zone("America/Los_Angeles")
        XCTAssertEqual(ExifFormat.exifDate(losAngelesEvening, timeZone: losAngeles), "2026:11:13 22:04:05")
        XCTAssertEqual(ExifFormat.offset(losAngelesEvening, timeZone: losAngeles), "-08:00")
    }

    func testNewfoundlandHalfHourOffsetFollowsItsDaylightTime() throws {
        let stJohns = try zone("America/St_Johns")
        let january = Date(timeIntervalSince1970: 1_768_478_400)  // 2026-01-15 12:00 UTC
        let july = Date(timeIntervalSince1970: 1_784_116_800)  // 2026-07-15 12:00 UTC
        XCTAssertEqual(ExifFormat.exifDate(january, timeZone: stJohns), "2026:01:15 08:30:00")
        XCTAssertEqual(ExifFormat.offset(january, timeZone: stJohns), "-03:30")
        XCTAssertEqual(ExifFormat.exifDate(july, timeZone: stJohns), "2026:07:15 09:30:00")
        XCTAssertEqual(ExifFormat.offset(july, timeZone: stJohns), "-02:30")
    }

    func testOffsetChangesAtTheDaylightSavingSwitch() throws {
        let losAngeles = try zone("America/Los_Angeles")
        // Spring forward: 01:59:59 PST is followed by 03:00:00 PDT.
        let beforeSpring = Date(timeIntervalSince1970: 1_772_963_999)
        let afterSpring = Date(timeIntervalSince1970: 1_772_964_000)
        XCTAssertEqual(ExifFormat.exifDate(beforeSpring, timeZone: losAngeles), "2026:03:08 01:59:59")
        XCTAssertEqual(ExifFormat.offset(beforeSpring, timeZone: losAngeles), "-08:00")
        XCTAssertEqual(ExifFormat.exifDate(afterSpring, timeZone: losAngeles), "2026:03:08 03:00:00")
        XCTAssertEqual(ExifFormat.offset(afterSpring, timeZone: losAngeles), "-07:00")

        // Fall back: the hour from 01:00 happens twice, and only the offset tells them apart.
        let beforeFall = Date(timeIntervalSince1970: 1_793_523_599)
        let afterFall = Date(timeIntervalSince1970: 1_793_523_600)
        XCTAssertEqual(ExifFormat.exifDate(beforeFall, timeZone: losAngeles), "2026:11:01 01:59:59")
        XCTAssertEqual(ExifFormat.offset(beforeFall, timeZone: losAngeles), "-07:00")
        XCTAssertEqual(ExifFormat.exifDate(afterFall, timeZone: losAngeles), "2026:11:01 01:00:00")
        XCTAssertEqual(ExifFormat.offset(afterFall, timeZone: losAngeles), "-08:00")
    }

    func testOffsetOfFixedZones() {
        XCTAssertEqual(ExifFormat.offset(evening, timeZone: TimeZone(secondsFromGMT: -12_600)!), "-03:30")
        XCTAssertEqual(ExifFormat.offset(evening, timeZone: TimeZone(secondsFromGMT: 49_500)!), "+13:45")
        XCTAssertEqual(ExifFormat.offset(evening, timeZone: TimeZone(secondsFromGMT: -36_000)!), "-10:00")
    }

    func testTheDateNeverRoundsUpPastItsSubseconds() {
        let late = evening.addingTimeInterval(0.9996)
        XCTAssertEqual(ExifFormat.exifDate(late, timeZone: utc), "2026:11:13 22:04:05")
        XCTAssertEqual(ExifFormat.subseconds(late), "999")
        XCTAssertEqual(ExifFormat.quickTimeDate(late, timeZone: utc), "2026-11-13T22:04:05+0000")
    }

    func testSubseconds() {
        XCTAssertEqual(ExifFormat.subseconds(evening), "000")
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.007)), "007")
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.5)), "500")
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.532)), "532")
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.0004)), "000")
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.0016)), "002")
        // The last millisecond stays in its second: "1000" would be the next one.
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.9996)), "999")
        XCTAssertEqual(ExifFormat.subseconds(evening.addingTimeInterval(0.9994)), "999")
    }

    func testSubsecondsBeforeTheReferenceDateCountUpFromTheirSecond() {
        // A quarter second before 2001-01-01 00:00:00 UTC is 23:59:59.750 the evening before.
        let date = Date(timeIntervalSinceReferenceDate: -0.25)
        XCTAssertEqual(ExifFormat.exifDate(date, timeZone: utc), "2000:12:31 23:59:59")
        XCTAssertEqual(ExifFormat.subseconds(date), "750")
    }

    func testQuickTimeDate() throws {
        XCTAssertEqual(ExifFormat.quickTimeDate(losAngelesEvening, timeZone: try zone("America/Los_Angeles")),
                       "2026-11-13T22:04:05-0800")
        XCTAssertEqual(ExifFormat.quickTimeDate(evening, timeZone: try zone("Asia/Kolkata")),
                       "2026-11-14T03:34:05+0530")
        XCTAssertEqual(ExifFormat.quickTimeDate(evening, timeZone: utc), "2026-11-13T22:04:05+0000")
    }

    func testGPSStampsAreUTCEvenWhenTheLocalDayIsAnother() throws {
        // 07:30 UTC on the 14th is 23:30 on the 13th in Los Angeles.
        let fix = Date(timeIntervalSince1970: 1_794_641_400)
        XCTAssertEqual(ExifFormat.exifDate(fix, timeZone: try zone("America/Los_Angeles")), "2026:11:13 23:30:00")
        XCTAssertEqual(ExifFormat.gpsDateStamp(fix), "2026:11:14")
        XCTAssertEqual(ExifFormat.gpsTimeStamp(fix), "07:30:00")
        XCTAssertEqual(ExifFormat.gpsDateStamp(evening), "2026:11:13")
        XCTAssertEqual(ExifFormat.gpsTimeStamp(evening), "22:04:05")
    }

    // MARK: - ISO 6709

    private func geo(_ latitude: Double, _ longitude: Double, altitude: Double = 0,
                     verticalAccuracy: Double = -1) -> GeoTag {
        GeoTag(latitude: latitude, longitude: longitude, altitude: altitude, horizontalAccuracy: 5, timestamp: evening,
               verticalAccuracy: verticalAccuracy)
    }

    func testISO6709AsAppleWritesIt() {
        XCTAssertEqual(ExifFormat.iso6709(geo(37.3349, -122.0090, altitude: 12.3, verticalAccuracy: 3)),
                       "+37.3349-122.0090+012.300/")
    }

    func testISO6709LeavesAnUnknownAltitudeOut() {
        XCTAssertEqual(ExifFormat.iso6709(geo(37.3349, -122.0090, altitude: 0)), "+37.3349-122.0090/")
        XCTAssertEqual(ExifFormat.iso6709(geo(37.3349, -122.0090, altitude: 12.3, verticalAccuracy: -1)),
                       "+37.3349-122.0090/")
        XCTAssertEqual(ExifFormat.iso6709(geo(37.3349, -122.0090, altitude: .nan, verticalAccuracy: 3)),
                       "+37.3349-122.0090/")
    }

    func testISO6709SouthernWesternAndBelowSeaLevel() {
        XCTAssertEqual(ExifFormat.iso6709(geo(-33.8688, 151.2093, altitude: -5.25, verticalAccuracy: 2)),
                       "-33.8688+151.2093-005.250/")
        XCTAssertEqual(ExifFormat.iso6709(geo(51.5074, -0.1278)), "+51.5074-000.1278/")
        XCTAssertEqual(ExifFormat.iso6709(geo(-0.1807, -78.4678)), "-00.1807-078.4678/")
        XCTAssertEqual(ExifFormat.iso6709(geo(37.3349, -122.0090, altitude: 1234.5, verticalAccuracy: 3)),
                       "+37.3349-122.0090+1234.500/")
    }

    func testISO6709MatchesThePrintfWidths() {
        // "%+08.4f%+09.4f%+08.3f" is the form the comment in the old movie writer quotes from Apple.
        let fixes: [(Double, Double, Double)] = [(37.3349, -122.009, 12.3), (5.5, 5.5, 0.5),
                                                 (-89.99994, 179.99994, 999.9994),
                                                 (12.34567, -45.67891, -123.4567), (90, -180, 8848.86)]
        for (latitude, longitude, altitude) in fixes {
            let expected = String(format: "%+08.4f%+09.4f%+08.3f/", latitude, longitude, altitude)
            let tag = geo(latitude, longitude, altitude: altitude, verticalAccuracy: 1)
            XCTAssertEqual(ExifFormat.iso6709(tag), expected)
        }
    }

    func testISO6709NeverWritesMinusZero() {
        XCTAssertEqual(ExifFormat.iso6709(geo(-0.00001, -0.00004, altitude: -0.0001, verticalAccuracy: 1)),
                       "+00.0000+000.0000+000.000/")
    }

    func testISO6709RefusesAFixOffTheGlobe() {
        XCTAssertNil(ExifFormat.iso6709(geo(91, 0)))
        XCTAssertNil(ExifFormat.iso6709(geo(0, 181)))
        XCTAssertNil(ExifFormat.iso6709(geo(.nan, 0)))
        XCTAssertNil(ExifFormat.iso6709(geo(0, .infinity)))
    }

    // MARK: - APEX

    func testShutterSpeedValue() throws {
        XCTAssertEqual(try XCTUnwrap(ExifFormat.shutterSpeedValue(seconds: 1.0 / 30.0)), log2(30), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ExifFormat.shutterSpeedValue(seconds: 30)), -log2(30), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ExifFormat.shutterSpeedValue(seconds: 1.0 / 8000.0)), log2(8000), accuracy: 1e-12)
        let one = try XCTUnwrap(ExifFormat.shutterSpeedValue(seconds: 1))
        XCTAssertEqual(one, 0)
        XCTAssertEqual(one.sign, .plus)
    }

    func testApertureValue() throws {
        XCTAssertEqual(try XCTUnwrap(ExifFormat.apertureValue(fNumber: 1.78)), 2 * log2(1.78), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ExifFormat.apertureValue(fNumber: 2.8)), 2 * log2(2.8), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ExifFormat.apertureValue(fNumber: 4)), 4, accuracy: 1e-12)
        XCTAssertEqual(ExifFormat.apertureValue(fNumber: 1)?.sign, FloatingPointSign.plus)
    }

    func testBrightnessValue() throws {
        XCTAssertEqual(ExifFormat.brightnessValue(lightProduct: 3.125), 0)
        // 1/30 s at ISO 100 and f/1.78, what auto exposure picks indoors.
        let indoors = (1.0 / 30.0) * 100 / (1.78 * 1.78)
        XCTAssertEqual(try XCTUnwrap(ExifFormat.brightnessValue(lightProduct: indoors)), log2(3.125 / indoors),
                       accuracy: 1e-12)
        // Bv = Av + Tv - Sv with Sv = log2(ISO / 3.125).
        let av = 2 * log2(1.78), tv = log2(30.0), sv = log2(100 / 3.125)
        XCTAssertEqual(try XCTUnwrap(ExifFormat.brightnessValue(lightProduct: indoors)), av + tv - sv, accuracy: 1e-9)
        // Dark scenes need more light, and their brightness is below zero.
        XCTAssertLessThan(try XCTUnwrap(ExifFormat.brightnessValue(lightProduct: 1.0 * 3200 / (1.78 * 1.78))), 0)
    }

    func testAPEXLeavesUnusableInputOut() {
        for bad in [0, -1, -0.0, Double.nan, .infinity, -.infinity] {
            XCTAssertNil(ExifFormat.shutterSpeedValue(seconds: bad), "\(bad)")
            XCTAssertNil(ExifFormat.apertureValue(fNumber: bad), "\(bad)")
            XCTAssertNil(ExifFormat.brightnessValue(lightProduct: bad), "\(bad)")
        }
    }

    // MARK: - Numbers as text

    func testDecimalDropsTrailingZeros() {
        XCTAssertEqual(ExifFormat.decimal(1.0 / 30.0), "0.033333")
        XCTAssertEqual(ExifFormat.decimal(1.0 / 12.0), "0.083333")
        XCTAssertEqual(ExifFormat.decimal(30), "30")
        XCTAssertEqual(ExifFormat.decimal(-0.7), "-0.7")
        XCTAssertEqual(ExifFormat.decimal(1.4), "1.4")
        XCTAssertEqual(ExifFormat.decimal(0.000125), "0.000125")
        XCTAssertEqual(ExifFormat.decimal(1.0 / 3.0, maxDecimals: 2), "0.33")
        XCTAssertEqual(ExifFormat.decimal(5120.4, maxDecimals: 0), "5120")
        XCTAssertEqual(ExifFormat.decimal(2.5, maxDecimals: 0), "3")
        XCTAssertEqual(ExifFormat.decimal(-2.5, maxDecimals: 0), "-3")
        XCTAssertEqual(ExifFormat.decimal(216_000), "216000")
        XCTAssertEqual(ExifFormat.decimal(123_456_789.125, maxDecimals: 3), "123456789.125")
    }

    func testDecimalNeverWritesMinusZeroOrNotANumber() {
        XCTAssertEqual(ExifFormat.decimal(0), "0")
        XCTAssertEqual(ExifFormat.decimal(-0.0), "0")
        XCTAssertEqual(ExifFormat.decimal(-0.0000001), "0")
        XCTAssertEqual(ExifFormat.decimal(.nan), "0")
        XCTAssertEqual(ExifFormat.decimal(.infinity), "0")
    }

    func testFixedKeepsItsDecimals() {
        XCTAssertEqual(ExifFormat.fixed(180, decimals: 2), "180.00")
        XCTAssertEqual(ExifFormat.fixed(43.6532, decimals: 5), "43.65320")
        XCTAssertEqual(ExifFormat.fixed(0.5, decimals: 3), "0.500")
        XCTAssertEqual(ExifFormat.fixed(-1.25, decimals: 1), "-1.3")
        XCTAssertEqual(ExifFormat.fixed(7, decimals: 0), "7")
    }

    func testNumbersUseAPointAndNoGroupingWhateverTheRegion() {
        let german = Locale(identifier: "de_DE")
        // A region that writes a comma really does: otherwise this test would prove nothing.
        XCTAssertEqual(String(format: "%.6f", locale: german, 1.0 / 30.0), "0,033333")
        for value in [1.0 / 30.0, 1234.5, 1_800, -0.7, 8000, 65_535.25] {
            let text = ExifFormat.decimal(value)
            XCTAssertFalse(text.contains(","), text)
            XCTAssertTrue(text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }, text)
            XCTAssertEqual(try XCTUnwrap(Double(text)), value, accuracy: 1e-6)
        }
    }

    // MARK: - Subject area

    /// The middle 16:9 of a 4032 x 3024 picture.
    private let wideCrop = CropRect(x: 0, y: 378, width: 4032, height: 2268)
    /// The middle square of the same picture.
    private let squareCrop = CropRect(x: 504, y: 0, width: 3024, height: 3024)

    func testSubjectPointMovesWithTheCrop() {
        XCTAssertEqual(ExifFormat.subjectArea([2016, 1512], croppedTo: wideCrop), [2016, 1134])
        XCTAssertEqual(ExifFormat.subjectArea([2016, 1512], croppedTo: squareCrop), [1512, 1512])
    }

    func testSubjectPointOnTheCropsEdges() {
        // The first row and column are inside; the row just past the last one is not.
        XCTAssertEqual(ExifFormat.subjectArea([0, 378], croppedTo: wideCrop), [0, 0])
        XCTAssertEqual(ExifFormat.subjectArea([4031, 2645], croppedTo: wideCrop), [4031, 2267])
        XCTAssertNil(ExifFormat.subjectArea([100, 2646], croppedTo: wideCrop))
        XCTAssertEqual(ExifFormat.subjectArea([504, 0], croppedTo: squareCrop), [0, 0])
        XCTAssertNil(ExifFormat.subjectArea([503, 10], croppedTo: squareCrop))
        XCTAssertNil(ExifFormat.subjectArea([3528, 10], croppedTo: squareCrop))
    }

    func testSubjectPointOutsideTheCropIsDropped() {
        XCTAssertNil(ExifFormat.subjectArea([2016, 100], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([2016, 3000], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([100, 1512], croppedTo: squareCrop))
    }

    func testSubjectCircleKeepsItsDiameter() {
        XCTAssertEqual(ExifFormat.subjectArea([2016, 1512, 300], croppedTo: wideCrop), [2016, 1134, 300])
        // A circle is placed by its centre, even when part of it leaves the crop.
        XCTAssertEqual(ExifFormat.subjectArea([2016, 400, 300], croppedTo: wideCrop), [2016, 22, 300])
        XCTAssertNil(ExifFormat.subjectArea([2016, 3000, 300], croppedTo: wideCrop))
    }

    func testSubjectRectangleKeepsThePartInsideTheCrop() {
        XCTAssertEqual(ExifFormat.subjectArea([2016, 1512, 800, 600], croppedTo: wideCrop), [2016, 1134, 800, 600])
        // Over the top edge: 300...500 becomes 378...500.
        XCTAssertEqual(ExifFormat.subjectArea([2016, 400, 400, 200], croppedTo: wideCrop), [2016, 61, 400, 122])
        // Over the left edge of the square: 400...800 becomes 504...800.
        XCTAssertEqual(ExifFormat.subjectArea([600, 1512, 400, 400], croppedTo: squareCrop), [148, 1512, 296, 400])
        // Larger than the crop on every side: the whole crop.
        XCTAssertEqual(ExifFormat.subjectArea([2016, 1512, 5000, 4000], croppedTo: wideCrop), [2016, 1134, 4032, 2268])
    }

    func testSubjectRectangleOutsideOrOnlyTouchingTheCropIsDropped() {
        // 178...378 ends where the crop starts.
        XCTAssertNil(ExifFormat.subjectArea([2016, 278, 400, 200], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([2016, 100, 400, 100], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([200, 1512, 200, 200], croppedTo: squareCrop))
    }

    func testSubjectAreaRefusesWhatIsNotAShapeOrACrop() {
        XCTAssertNil(ExifFormat.subjectArea([], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([2016], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([1, 2, 3, 4, 5], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([-1, 1512], croppedTo: wideCrop))
        XCTAssertNil(ExifFormat.subjectArea([2016, 1512], croppedTo: CropRect(x: 0, y: 0, width: 0, height: 3024)))
        let notANumber = CropRect(x: .nan, y: 0, width: 4032, height: 3024)
        XCTAssertNil(ExifFormat.subjectArea([2016, 1512], croppedTo: notANumber))
    }
}
