import XCTest
@testable import CameraCore

final class FormatSelectionTests: XCTestCase {
    private func format(_ index: Int, _ w: Int, _ h: Int, fps: ClosedRange<Double>, pixel: String = "420v",
                        hdr: Bool = false, hlg: Bool = false, log: Bool = false, log2: Bool = false, binned: Bool = false,
                        photo: Int = 12_000_000, maxExposure: Double = 1, minISO: Double = 50, maxISO: Double = 3200) -> FormatDescriptor {
        FormatDescriptor(index: index, width: w, height: h, minFrameRate: fps.lowerBound, maxFrameRate: fps.upperBound,
                         pixelFormat: pixel, supportsVideoHDR: hdr, supportsHLG: hlg, supportsAppleLog: log, supportsAppleLog2: log2,
                         isBinned: binned, maxPhotoPixels: photo, fieldOfView: 70, minISO: minISO, maxISO: maxISO,
                         minExposure: 1.0 / 16000, maxExposure: maxExposure)
    }

    private lazy var catalog: [FormatDescriptor] = [
        format(0, 1920, 1080, fps: 1...30, pixel: "420v"),
        format(1, 1920, 1080, fps: 1...30, pixel: "420f"),
        format(2, 1920, 1080, fps: 1...240, pixel: "420v", binned: true),
        format(3, 3840, 2160, fps: 1...30, pixel: "420v", photo: 8_300_000),
        format(4, 3840, 2160, fps: 1...60, pixel: "420v", photo: 8_300_000),
        format(5, 3840, 2160, fps: 1...60, pixel: "x420", hlg: true, log: true, photo: 8_300_000),
        format(6, 4032, 3024, fps: 1...30, pixel: "420f", photo: 48_000_000, maxExposure: 1),
        format(7, 4032, 3024, fps: 1...60, pixel: "420f", binned: true, photo: 12_000_000, maxExposure: 0.5),
        format(8, 1280, 720, fps: 1...240, pixel: "420v", binned: true),
    ]

    func testPicksLowestSufficientFrameRateForSDR() {
        let best = FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .sdr), among: catalog)
        XCTAssertEqual(best?.index, 3)
    }

    func testHighFrameRateNeedsCapableFormat() {
        let best = FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 60, colorMode: .sdr), among: catalog)
        XCTAssertEqual(best?.index, 4)
        let slowMo = FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .hd1080, frameRate: 240, colorMode: .sdr), among: catalog)
        XCTAssertEqual(slowMo?.index, 2)
    }

    func testLogAndHDRPrefer10Bit() {
        let log = FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .appleLog), among: catalog)
        XCTAssertEqual(log?.index, 5)
        let hdr = FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 24, colorMode: .hdr), among: catalog)
        XCTAssertEqual(hdr?.index, 5)
        XCTAssertNil(FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .hd1080, frameRate: 30, colorMode: .appleLog), among: catalog))
    }

    func testAppleLog2NeedsAFormatThatListsIt() {
        let formats = [
            format(0, 3840, 2160, fps: 1...60, pixel: "x420", log: true),
            format(1, 3840, 2160, fps: 1...30, pixel: "x420", log: true, log2: true),
            format(2, 1920, 1080, fps: 1...60, pixel: "x420", log: true),
        ]
        let log2 = FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .appleLog2), among: formats)
        XCTAssertEqual(log2?.index, 1)
        XCTAssertNil(FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 60, colorMode: .appleLog2), among: formats))
        XCTAssertNil(FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .hd1080, frameRate: 30, colorMode: .appleLog2), among: formats))
        XCTAssertEqual(FormatSelector.availableResolutions(colorMode: .appleLog2, among: formats), [.uhd4K])
        XCTAssertEqual(FormatSelector.availableFrameRates(resolution: .uhd4K, colorMode: .appleLog2, among: formats), [24, 25, 30])
        // Apple Log alone is not Apple Log 2, so a phone without it never offers it.
        XCTAssertEqual(FormatSelector.availableResolutions(colorMode: .appleLog, among: formats), [.hd1080, .uhd4K])
        XCTAssertEqual(FormatSelector.availableResolutions(colorMode: .appleLog2, among: catalog), [])
    }

    func testColorFallbacksStartWithTheModeAndEndInSDR() {
        XCTAssertEqual(VideoColorMode.appleLog2.fallbacks, [.appleLog2, .appleLog, .sdr])
        XCTAssertEqual(VideoColorMode.sdr.fallbacks, [.sdr])
        for mode in VideoColorMode.allCases {
            XCTAssertEqual(mode.fallbacks.first, mode)
            XCTAssertEqual(mode.fallbacks.last, .sdr)
        }
    }

    func testNearestVideoFormatKeepsAnExactMatch() {
        let wanted = VideoRequirement(resolution: .uhd4K, frameRate: 60, colorMode: .sdr)
        let choice = FormatSelector.nearestVideoFormat(for: wanted, among: catalog)
        XCTAssertEqual(choice?.format.index, 4)
        XCTAssertEqual(choice?.recorded, wanted)
    }

    func testNearestVideoFormatStepsToTheClosestRate() {
        // No 4K format reaches 120, so 4K records at its fastest rate rather than dropping to a smaller size.
        let fast = FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 120, colorMode: .sdr), among: catalog)
        XCTAssertEqual(fast?.recorded, VideoRequirement(resolution: .uhd4K, frameRate: 60, colorMode: .sdr))
        XCTAssertEqual(fast?.format.index, 4)
        let slow = [format(0, 3840, 2160, fps: 1...30)]
        let between = FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 48, colorMode: .sdr), among: slow)
        XCTAssertEqual(between?.recorded.frameRate, 30)
    }

    func testNearestVideoFormatTriesEverySizeBeforeTheColorFallback() {
        // Log only exists at 4K here, which beats 1080p in SDR.
        let log = FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .hd1080, frameRate: 30, colorMode: .appleLog), among: catalog)
        XCTAssertEqual(log?.recorded, VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .appleLog))
        XCTAssertEqual(log?.format.index, 5)
        let logs = [
            format(0, 1920, 1080, fps: 1...30, pixel: "x420", log: true),
            format(1, 3840, 2160, fps: 1...30, pixel: "x420", log: true),
        ]
        let small = FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .hd720, frameRate: 30, colorMode: .appleLog), among: logs)
        XCTAssertEqual(small?.recorded.resolution, .uhd4K)
    }

    func testNearestVideoFormatStepsDownThroughTheColors() {
        let formats = [
            format(0, 3840, 2160, fps: 1...60, pixel: "x420", log: true),
            format(1, 3840, 2160, fps: 1...60, pixel: "420v"),
        ]
        let log2 = FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .appleLog2), among: formats)
        XCTAssertEqual(log2?.recorded.colorMode, .appleLog)
        XCTAssertEqual(log2?.format.index, 0)
        let hdr = FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .hdr), among: [formats[1]])
        XCTAssertEqual(hdr?.recorded, VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .sdr))
        XCTAssertNil(FormatSelector.nearestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .sdr), among: []))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 120, colorMode: .sdr), among: catalog))
        XCTAssertNil(FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .hd720, frameRate: 30, colorMode: .sdr), among: []))
    }

    func testPortraitDimensionsMatchToo() {
        let rotated = [format(0, 2160, 3840, fps: 1...30)]
        XCTAssertEqual(FormatSelector.bestVideoFormat(for: VideoRequirement(resolution: .uhd4K, frameRate: 30, colorMode: .sdr), among: rotated)?.index, 0)
    }

    func testAvailableFrameRatesAndResolutions() {
        XCTAssertEqual(FormatSelector.availableFrameRates(resolution: .uhd4K, colorMode: .sdr, among: catalog), [24, 25, 30, 48, 50, 60])
        XCTAssertEqual(FormatSelector.availableFrameRates(resolution: .hd1080, colorMode: .sdr, among: catalog), [24, 25, 30, 48, 50, 60, 100, 120, 240])
        XCTAssertEqual(FormatSelector.availableFrameRates(resolution: .uhd4K, colorMode: .appleLog, among: catalog), [24, 25, 30, 48, 50, 60])
        XCTAssertEqual(FormatSelector.availableResolutions(colorMode: .sdr, among: catalog), [.hd720, .hd1080, .uhd4K])
        XCTAssertEqual(FormatSelector.availableResolutions(colorMode: .appleLog, among: catalog), [.uhd4K])
    }

    func testBestPhotoFormatPrefersPixelsThenExposure() {
        XCTAssertEqual(FormatSelector.bestPhotoFormat(among: catalog)?.index, 6)
        let tie = [
            format(0, 4032, 3024, fps: 1...30, pixel: "420v", photo: 12_000_000, maxExposure: 0.5),
            format(1, 4032, 3024, fps: 1...30, pixel: "420f", photo: 12_000_000, maxExposure: 1),
        ]
        XCTAssertEqual(FormatSelector.bestPhotoFormat(among: tie)?.index, 1)
        XCTAssertNil(FormatSelector.bestPhotoFormat(among: []))
    }

    func testDescriptorHelpers() {
        XCTAssertTrue(format(0, 1, 1, fps: 1...30, pixel: "x420").is10Bit)
        XCTAssertFalse(format(0, 1, 1, fps: 1...30, pixel: "420f").is10Bit)
        XCTAssertEqual(VideoResolution.uhd4K.dimensions.width, 3840)
        XCTAssertEqual(VideoResolution.hd720.title, "720p")
        XCTAssertEqual(VideoColorMode.appleLog.title, "Apple Log")
        XCTAssertEqual(VideoColorMode.appleLog2.title, "Apple Log 2")
    }
}
