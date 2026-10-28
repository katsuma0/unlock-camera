import XCTest
@testable import CameraCore

final class FormattingTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(Formatting.clock(0), "0:00")
        XCTAssertEqual(Formatting.clock(-3), "0:00")
        XCTAssertEqual(Formatting.clock(.nan), "0:00")
        XCTAssertEqual(Formatting.clock(4.2), "0:05")
        XCTAssertEqual(Formatting.clock(5), "0:05")
        XCTAssertEqual(Formatting.clock(90), "1:30")
        XCTAssertEqual(Formatting.clock(720), "12:00")
        XCTAssertEqual(Formatting.clock(3600), "1:00:00")
        XCTAssertEqual(Formatting.clock(3725), "1:02:05")
    }

    func testCompactDuration() {
        XCTAssertEqual(Formatting.compactDuration(1.5), "1.5s")
        XCTAssertEqual(Formatting.compactDuration(5), "5s")
        XCTAssertEqual(Formatting.compactDuration(12.4), "12s")
        XCTAssertEqual(Formatting.compactDuration(59.6), "1m")
        XCTAssertEqual(Formatting.compactDuration(120), "2m")
        XCTAssertEqual(Formatting.compactDuration(125), "2m 5s")
        XCTAssertEqual(Formatting.compactDuration(3600), "1h")
        XCTAssertEqual(Formatting.compactDuration(3900), "1h 5m")
        XCTAssertEqual(Formatting.compactDuration(0), "0s")
    }

    func testMegapixels() {
        XCTAssertEqual(Formatting.megapixels(width: 4032, height: 3024), "12 MP")
        XCTAssertEqual(Formatting.megapixels(width: 5712, height: 4284), "24 MP")
        XCTAssertEqual(Formatting.megapixels(width: 8064, height: 6048), "48 MP")
        XCTAssertEqual(Formatting.megapixels(width: 4224, height: 4224), "18 MP")
        XCTAssertEqual(Formatting.megapixels(width: 3840, height: 2160), "8.3 MP")
        XCTAssertEqual(Formatting.megapixels(width: 0, height: 10), "0 MP")
    }

    func testFileSize() {
        XCTAssertEqual(Formatting.fileSize(bytes: 0), "0 B")
        XCTAssertEqual(Formatting.fileSize(bytes: 512), "512 B")
        XCTAssertEqual(Formatting.fileSize(bytes: 512_000), "512 KB")
        XCTAssertEqual(Formatting.fileSize(bytes: 12_340_000), "12.3 MB")
        XCTAssertEqual(Formatting.fileSize(bytes: 2_000_000), "2 MB")
        XCTAssertEqual(Formatting.fileSize(bytes: 1_200_000_000), "1.2 GB")
    }

    func testPercent() {
        XCTAssertEqual(Formatting.percent(0), "0%")
        XCTAssertEqual(Formatting.percent(0.001), "<1%")
        XCTAssertEqual(Formatting.percent(0.123), "12%")
        XCTAssertEqual(Formatting.percent(1), "100%")
    }

    func testFrameRateAndResolution() {
        XCTAssertEqual(Formatting.frameRate(30), "30 fps")
        XCTAssertEqual(Formatting.frameRate(29.97), "29.97 fps")
        XCTAssertEqual(Formatting.frameRate(23.976), "23.98 fps")
        XCTAssertEqual(Formatting.resolution(width: 3840, height: 2160), "4K")
        XCTAssertEqual(Formatting.resolution(width: 2160, height: 3840), "4K")
        XCTAssertEqual(Formatting.resolution(width: 1920, height: 1080), "1080p")
        XCTAssertEqual(Formatting.resolution(width: 1280, height: 720), "720p")
        XCTAssertEqual(Formatting.resolution(width: 4096, height: 2160), "4K DCI")
        XCTAssertEqual(Formatting.resolution(width: 4032, height: 3024), "4032\u{00D7}3024")
    }

    func testKelvinTintAndLensPosition() {
        XCTAssertEqual(Formatting.kelvin(5603), "5600K")
        XCTAssertEqual(Formatting.kelvin(3205), "3210K")
        XCTAssertEqual(Formatting.tint(0.4), "0")
        XCTAssertEqual(Formatting.tint(12.2), "+12")
        XCTAssertEqual(Formatting.tint(-7.6), "-8")
        XCTAssertEqual(Formatting.lensPosition(0.42), "MF 42%")
        XCTAssertEqual(Formatting.lensPosition(1.7), "MF 100%")
        XCTAssertEqual(Formatting.lensPosition(-1), "MF 0%")
    }

    func testHugeValuesDoNotTrap() {
        XCTAssertFalse(Formatting.clock(1e300).isEmpty)
        XCTAssertFalse(Formatting.compactDuration(1e300).isEmpty)
        XCTAssertFalse(Formatting.percent(1e300).isEmpty)
        XCTAssertFalse(Formatting.frameRate(1e300).isEmpty)
        XCTAssertFalse(Formatting.kelvin(1e300).isEmpty)
        XCTAssertFalse(Formatting.tint(-1e300).isEmpty)
        XCTAssertFalse(Formatting.megapixels(width: Int.max, height: Int.max).isEmpty)
        XCTAssertEqual(Formatting.clampedInt(.nan), 0)
        XCTAssertEqual(Formatting.clampedInt(.infinity), 0)
        XCTAssertEqual(Formatting.clampedInt(12.0), 12)
    }

    func testTrimmed() {
        XCTAssertEqual(Formatting.trimmed(2.0, decimals: 1), "2")
        XCTAssertEqual(Formatting.trimmed(2.5, decimals: 1), "2.5")
        XCTAssertEqual(Formatting.trimmed(0.666, decimals: 1), "0.7")
        XCTAssertEqual(Formatting.trimmed(1.25, decimals: 2), "1.25")
    }
}
