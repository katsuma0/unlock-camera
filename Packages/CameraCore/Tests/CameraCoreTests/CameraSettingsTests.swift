import XCTest
@testable import CameraCore

final class CameraSettingsTests: XCTestCase {
    func testDefaultsRoundTrip() throws {
        let settings = CameraSettings.default
        let data = try settings.encoded()
        XCTAssertEqual(CameraSettings.decoded(from: data), settings)
    }

    func testEmptyObjectDecodesToDefaults() {
        let decoded = CameraSettings.decoded(from: Data("{}".utf8))
        XCTAssertEqual(decoded, .default)
    }

    func testGarbageDecodesToDefaults() {
        XCTAssertEqual(CameraSettings.decoded(from: Data("not json".utf8)), .default)
        XCTAssertEqual(CameraSettings.decoded(from: Data()), .default)
    }

    func testUnknownKeysAreIgnored() {
        let json = #"{"mode":"night","somethingFromTheFuture":42,"capture":{"quality":0.75,"newKnob":true}}"#
        let decoded = CameraSettings.decoded(from: Data(json.utf8))
        XCTAssertEqual(decoded.mode, .night)
        XCTAssertEqual(decoded.capture.quality, 0.75, accuracy: 1e-9)
        XCTAssertEqual(decoded.capture.processedFormat, .heif)
    }

    func testWrongTypedFieldKeepsTheRest() {
        let json = #"{"mode":12,"zoom":2.5,"display":{"grid":"thirds","zebraThreshold":"high"}}"#
        let decoded = CameraSettings.decoded(from: Data(json.utf8))
        XCTAssertEqual(decoded.mode, .photo)
        XCTAssertEqual(decoded.zoom, 2.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.display.grid, .thirds)
        XCTAssertEqual(decoded.display.zebraThreshold, DisplaySettings().zebraThreshold, accuracy: 1e-9)
    }

    func testEveryCustomisedFieldRoundTrips() throws {
        var s = CameraSettings()
        s.mode = .long
        s.lensID = "com.apple.avfoundation.avcapturedevice.built-in_video:2"
        s.zoom = 2
        s.manual = ManualExposureSetting(shutter: 30, iso: 64, aperture: 2.8, bias: -0.7)
        s.whiteBalance = .kelvin(4300, tint: 12)
        s.focus = .manual(lensPosition: 0.42)
        s.capture.processedFormat = .jpeg
        s.capture.rawFormat = .proRAW
        s.capture.quality = 0.8
        s.capture.resolution = .mp48
        s.capture.processing = .minimal
        s.capture.flash = .auto
        s.capture.aspect = .xpan
        s.capture.livePhoto = true
        s.capture.silentShutter = true
        s.capture.depth = true
        s.capture.constantColor = true
        s.capture.lensCorrection = false
        s.capture.mirrorFront = false
        s.capture.saveLocation = true
        s.capture.schedule = CaptureSchedule(delay: 10, shots: 20, interval: 30)
        s.capture.bracket = BracketPlan(kind: .exposure, count: 5, step: 1)
        s.exposure.aeMaxShutter = 1.0 / 60
        s.exposure.faceDriven = .off
        s.exposure.lowLightBoost = true
        s.exposure.globalToneMapping = true
        s.exposure.videoHDR = .on
        s.exposure.apertureRateLimit = 1.2
        s.exposure.meteringArea = .spot
        s.focusOptions.range = .near
        s.focusOptions.smooth = true
        s.focusOptions.faceDriven = .on
        s.focusOptions.continuousTracking = true
        s.display.grid = .goldenRatio
        s.display.showLevel = false
        s.display.histogram = .rgb
        s.display.zebras = true
        s.display.zebraThreshold = 0.9
        s.display.peaking = .always
        s.display.peakingColor = .yellow
        s.display.peakingSensitivity = 0.8
        s.display.falseColor = true
        s.display.showReadout = false
        s.display.clippingWarnings = false
        s.night.seconds = 12.5
        s.night.stability = .tripod
        s.night.alignFrames = false
        s.night.maxISO = 1600
        s.night.biasEV = 0.3
        s.longExposure.seconds = 120
        s.longExposure.blend = .lighten
        s.longExposure.bulb = true
        s.longExposure.align = true
        s.longExposure.maxBulbSeconds = 600
        s.longExposure.frameSeconds = 0.25
        s.video.resolution = .hd1080
        s.video.frameRate = 120
        s.video.codec = .proRes422HQ
        s.video.colorMode = .appleLog
        s.video.stabilization = .cinematicExtended
        s.video.audio = false
        s.video.windNoiseReduction = false
        s.video.lowLightNoiseReduction = true
        s.video.showShutterAngle = false
        s.controls.volumeShutter = false
        s.controls.cameraControlItems = [.lens, .shutter, .aperture]
        s.controls.haptics = false
        s.controls.autoLensSwitching = false

        let decoded = CameraSettings.decoded(from: try s.encoded())
        XCTAssertEqual(decoded, s)
    }

    func testNewerSettingsDecodeTolerantly() {
        // Saved before metering area, wind noise reduction and the Blur/Trails frame shutter existed.
        let saved = #"{"exposure":{"lowLightBoost":true},"video":{"audio":false},"longExposure":{"seconds":60}}"#
        let older = CameraSettings.decoded(from: Data(saved.utf8))
        XCTAssertEqual(older.exposure.meteringArea, .automatic)
        XCTAssertTrue(older.exposure.lowLightBoost)
        XCTAssertTrue(older.video.windNoiseReduction)
        XCTAssertFalse(older.video.audio)
        XCTAssertNil(older.longExposure.frameSeconds)
        XCTAssertEqual(older.longExposure.seconds, 60, accuracy: 1e-9)

        let json = #"{"exposure":{"meteringArea":"wholeFrame"},"video":{"colorMode":"appleLog2","windNoiseReduction":false}}"#
        let decoded = CameraSettings.decoded(from: Data(json.utf8))
        XCTAssertEqual(decoded.exposure.meteringArea, .wholeFrame)
        XCTAssertEqual(decoded.video.colorMode, .appleLog2)
        XCTAssertFalse(decoded.video.windNoiseReduction)

        // A value from a later version, or of the wrong type, goes back to its default alone.
        let odd = #"{"exposure":{"meteringArea":"matrix","videoHDR":"on"},"video":{"windNoiseReduction":"yes","codec":"h264"}}"#
        let tolerant = CameraSettings.decoded(from: Data(odd.utf8))
        XCTAssertEqual(tolerant.exposure.meteringArea, .automatic)
        XCTAssertEqual(tolerant.exposure.videoHDR, .on)
        XCTAssertTrue(tolerant.video.windNoiseReduction)
        XCTAssertEqual(tolerant.video.codec, .h264)
        let fast = CameraSettings.decoded(from: Data(#"{"longExposure":{"frameSeconds":"fast","seconds":60}}"#.utf8))
        XCTAssertNil(fast.longExposure.frameSeconds)
        XCTAssertEqual(fast.longExposure.seconds, 60, accuracy: 1e-9)
    }

    func testMeteringAreaRects() {
        XCTAssertNil(MeteringArea.automatic.rectOfInterest(centerX: 0.3, centerY: 0.6, minWidth: 0.1, minHeight: 0.1))
        XCTAssertEqual(MeteringArea.wholeFrame.rectOfInterest(centerX: 0.3, centerY: 0.6, minWidth: 0.1, minHeight: 0.1), .unit)

        guard let spot = MeteringArea.spot.rectOfInterest(centerX: 0.3, centerY: 0.6, minWidth: 0.1, minHeight: 0.05) else {
            return XCTFail("A spot fits the frame")
        }
        // One percent over the minimum, since AVFoundation raises below it and a size equal to it is one rounding
        // step away; centred on the point.
        XCTAssertEqual(spot.width, 0.101, accuracy: 1e-12)
        XCTAssertEqual(spot.height, 0.0505, accuracy: 1e-12)
        XCTAssertEqual(spot.x + spot.width / 2, 0.3, accuracy: 1e-9)
        XCTAssertEqual(spot.y + spot.height / 2, 0.6, accuracy: 1e-9)
    }

    func testSpotMovesInsideTheFrameWithoutShrinking() {
        guard let corner = MeteringArea.spot.rectOfInterest(centerX: 0.99, centerY: 0.01, minWidth: 0.2, minHeight: 0.2) else {
            return XCTFail("A spot fits the frame")
        }
        XCTAssertGreaterThan(corner.width, 0.2)
        XCTAssertGreaterThan(corner.height, 0.2)
        XCTAssertEqual(corner.y, 0, accuracy: 1e-12)
        XCTAssertEqual(corner.maxX, 1, accuracy: 1e-12)

        // An unusable point means the middle of the frame.
        let middle = MeteringArea.spot.rectOfInterest(centerX: .nan, centerY: .infinity, minWidth: 0.1, minHeight: 0.1)
        XCTAssertEqual(middle.map { $0.x + $0.width / 2 } ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(middle.map { $0.y + $0.height / 2 } ?? 0, 0.5, accuracy: 1e-9)

        // A minimum as large as the frame gives the whole frame; anything that can't fit, or no minimum, gives nothing.
        XCTAssertEqual(MeteringArea.spot.rectOfInterest(centerX: 0.2, centerY: 0.8, minWidth: 1, minHeight: 1), .unit)
        XCTAssertNil(MeteringArea.spot.rectOfInterest(centerX: 0.5, centerY: 0.5, minWidth: 0, minHeight: 0))
        XCTAssertNil(MeteringArea.spot.rectOfInterest(centerX: 0.5, centerY: 0.5, minWidth: 1.2, minHeight: 0.1))
        XCTAssertNil(MeteringArea.wholeFrame.rectOfInterest(centerX: 0.5, centerY: 0.5, minWidth: .nan, minHeight: 0.1))
    }

    func testInvalidCaptureOptionsFallBackToHEIF() {
        let json = #"{"capture":{"processedFormat":"none","rawFormat":"none"}}"#
        let decoded = CameraSettings.decoded(from: Data(json.utf8))
        XCTAssertTrue(decoded.capture.isValid)
        XCTAssertEqual(decoded.capture.processedFormat, .heif)
    }

    func testRawOnlyIsValid() {
        var options = CaptureOptions()
        options.processedFormat = .none
        options.rawFormat = .bayer
        XCTAssertTrue(options.isValid)
        options.rawFormat = .none
        XCTAssertFalse(options.isValid)
    }

    func testWhiteBalanceSettingHelpers() {
        XCTAssertNil(WhiteBalanceSetting.auto.kelvinValue)
        XCTAssertTrue(WhiteBalanceSetting.auto.isAuto)
        XCTAssertEqual(WhiteBalanceSetting.preset(.tungsten).kelvinValue, 3200)
        XCTAssertFalse(WhiteBalanceSetting.preset(.tungsten).isAuto)
        XCTAssertTrue(WhiteBalanceSetting.preset(.auto).isAuto)
        XCTAssertEqual(WhiteBalanceSetting.kelvin(5000, tint: -7).kelvinValue, 5000)
        XCTAssertEqual(WhiteBalanceSetting.kelvin(5000, tint: -7).tintValue, -7)
        XCTAssertEqual(WhiteBalanceSetting.preset(.daylight).tintValue, 0)
    }

    func testFocusAndManualHelpers() {
        XCTAssertNil(FocusSetting.auto.lensPosition)
        XCTAssertEqual(FocusSetting.manual(lensPosition: 0.3).lensPosition, 0.3)
        let manual = ManualExposureSetting(shutter: 2, iso: nil, aperture: 4, bias: 0)
        XCTAssertEqual(manual.locks, ExposureLocks(seconds: 2, iso: nil, aperture: 4))
    }

    func testCaptureModeOrderAndTitles() {
        XCTAssertEqual(CaptureMode.carouselOrder, [.night, .long, .photo, .manual, .video])
        XCTAssertEqual(CaptureMode.photo.title, "PHOTO")
        XCTAssertTrue(CaptureMode.night.usesStacking)
        XCTAssertTrue(CaptureMode.long.usesStacking)
        XCTAssertFalse(CaptureMode.manual.usesStacking)
    }

    func testEnumsHaveTitlesAndUniqueIDs() {
        func check<T: CaseIterable & Identifiable>(_ type: T.Type, title: (T) -> String) where T.ID == String {
            let ids = T.allCases.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count)
            for value in T.allCases { XCTAssertFalse(title(value).isEmpty) }
        }
        check(ProcessedFormat.self) { $0.title }
        check(RawFormat.self) { $0.title }
        check(PhotoResolution.self) { $0.title }
        check(ProcessingLevel.self) { $0.title }
        check(FlashSetting.self) { $0.title }
        check(GridStyle.self) { $0.title }
        check(HistogramStyle.self) { $0.title }
        check(TriState.self) { $0.title }
        check(MeteringArea.self) { $0.title }
        check(FocusRange.self) { $0.title }
        check(PeakingMode.self) { $0.title }
        check(NightStabilityChoice.self) { $0.title }
        check(VideoCodecChoice.self) { $0.title }
        check(StabilizationChoice.self) { $0.title }
        check(CameraControlItem.self) { $0.title }
    }

    func testTitlesUseSentenceCase() {
        XCTAssertEqual(GridStyle.goldenRatio.title, "Golden ratio")
        XCTAssertEqual(PeakingMode.manualFocus.title, "Manual focus")
        XCTAssertEqual(StabilizationChoice.allCases.map(\.title),
                       ["Off", "Standard", "Cinematic", "Cinematic extended", "Enhanced", "Preview optimized",
                        "Low latency", "Auto"])
        XCTAssertEqual(CameraControlItem.whiteBalance.title, "White balance")
        XCTAssertEqual(MeteringArea.allCases.map(\.title), ["Auto", "Spot", "Whole frame"])
    }

    func testDefaultCameraControlSelectionFitsTheHardwareLimit() {
        // AVCaptureSession.maxControlsCount is 6 on current iPhones.
        XCTAssertLessThanOrEqual(CameraControlItem.defaultSelection.count, 6)
        // Zoom only moves within the current lens, so Lens comes next to it.
        XCTAssertEqual(Array(CameraControlItem.defaultSelection.prefix(2)), [.zoom, .lens])
        XCTAssertEqual(PhotoResolution.mp48.targetMegapixels, 48)
        XCTAssertNil(PhotoResolution.automatic.targetMegapixels)
        // Automatic always takes the largest size, so its title names that.
        XCTAssertEqual(PhotoResolution.automatic.title, "Largest")
        XCTAssertTrue(VideoCodecChoice.proRes422.isProRes)
        XCTAssertFalse(VideoCodecChoice.hevc.isProRes)
    }
}
