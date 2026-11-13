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

    /// Every setting changed from its default.
    private func everyFieldCustomised() -> CameraSettings {
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
        s.capture.prioritizeSpeed = true
        s.capture.artist = "Ana Lucía Peña"
        s.capture.copyright = "\u{00A9} 2026 Ana Lucía Peña. \"All\" rights reserved."
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
        s.display.dimDuringLongShots = true
        s.night.seconds = 12.5
        s.night.stability = .tripod
        s.night.alignFrames = false
        s.night.maxISO = 1600
        s.night.biasEV = 0.3
        s.longExposure.scene = .custom
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
        s.video.allowAudioPlayback = true
        s.controls.volumeShutter = false
        s.controls.cameraControlItems = [.lens, .shutter, .aperture]
        s.controls.haptics = false
        s.controls.autoLensSwitching = false
        s.controls.volumeUpAction = .zoomOut
        s.controls.volumeDownAction = .nextLens
        s.controls.hapticStrength = .light
        s.controls.dialTicks = false
        s.controls.zoomTicks = .lensValues
        s.interface.advanced = true
        s.interface.welcomed = true
        s.appearance.scheme = .dark
        s.appearance.accent = .purple
        s.accessibility.largerLabels = true
        s.accessibility.solidControls = true
        s.accessibility.reduceMotion = true
        s.accessibility.leftHanded = true
        s.accessibility.speakStatus = true
        s.topBar = TopBarOptions(leading: [.timer, .aspect, .exposureLock, .grid], trailing: [])
        s.startup.keepMode = false
        s.startup.keepLensAndZoom = false
        s.startup.keepBrightness = false
        return s
    }

    func testEveryCustomisedFieldRoundTrips() throws {
        let s = everyFieldCustomised()
        let decoded = CameraSettings.decoded(from: try s.encoded())
        XCTAssertEqual(decoded, s)
    }

    // MARK: - Settings added since the last version

    /// What the last version saved on a fresh install, its defaults, with line breaks added.
    private let lastVersionDefaults = #"""
        {"capture":{"aspect":{"long":4,"short":3},"bracket":{"count":3,"kind":"off","step":1},"constantColor":false,
        "depth":false,"flash":"off","lensCorrection":true,"livePhoto":false,"mirrorFront":true,"processedFormat":"heif",
        "processing":"balanced","quality":0.9,"rawFormat":"none","resolution":"automatic","saveLocation":false,
        "schedule":{"delay":0,"interval":0,"shots":1},"silentShutter":false},
        "controls":{"autoLensSwitching":true,"cameraControlItems":["zoom","lens","exposureBias","shutter","iso",
        "whiteBalance"],"haptics":true,"volumeShutter":true},
        "display":{"clippingWarnings":true,"falseColor":false,"grid":"off","histogram":"luma","peaking":"manualFocus",
        "peakingColor":"red","peakingSensitivity":0.5,"showLevel":true,"showReadout":true,"zebraThreshold":0.95,
        "zebras":false},
        "exposure":{"faceDriven":"automatic","globalToneMapping":false,"lowLightBoost":false,
        "meteringArea":"automatic","videoHDR":"automatic"},
        "focus":{"auto":{}},"focusOptions":{"continuousTracking":false,"faceDriven":"automatic","range":"none",
        "smooth":false},
        "interface":{"advanced":false,"welcomed":false},
        "longExposure":{"align":true,"blend":"average","bulb":false,"maxBulbSeconds":1800,"scene":"water","seconds":2},
        "manual":{"bias":0},"mode":"photo",
        "night":{"alignFrames":true,"biasEV":0,"maxISO":3200,"stability":"automatic"},
        "video":{"audio":true,"codec":"hevc","colorMode":"sdr","frameRate":30,"lowLightNoiseReduction":false,
        "resolution":"uhd4K","showShutterAngle":true,"stabilization":"standard","windNoiseReduction":true},
        "whiteBalance":{"auto":{}},"zoom":1}
        """#

    /// Keys this version added, by path ("controls.dialTicks").
    private let addedKeys = [
        "appearance", "accessibility", "topBar", "startup",
        "capture.prioritizeSpeed", "capture.artist", "capture.copyright",
        "display.dimDuringLongShots",
        "video.allowAudioPlayback",
        "controls.volumeUpAction", "controls.volumeDownAction", "controls.hapticStrength", "controls.dialTicks",
        "controls.zoomTicks",
    ]

    /// `data` without the keys at `paths`, each of which has to be there.
    private func removing(_ paths: [String], from data: Data) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for path in paths {
            let keys = path.split(separator: ".").map(String.init)
            if keys.count == 1 {
                XCTAssertNotNil(root.removeValue(forKey: keys[0]), path)
            } else {
                var group = try XCTUnwrap(root[keys[0]] as? [String: Any], path)
                XCTAssertNotNil(group.removeValue(forKey: keys[1]), path)
                root[keys[0]] = group
            }
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testNewSettingsStartAsTheAppHasAlwaysWorked() {
        let settings = CameraSettings.default
        // Both volume buttons took the photo.
        XCTAssertEqual(settings.controls.volumeUpAction, .shutter)
        XCTAssertEqual(settings.controls.volumeDownAction, .shutter)
        XCTAssertEqual(settings.controls.hapticStrength, .normal)
        XCTAssertTrue(settings.controls.dialTicks)
        XCTAssertEqual(settings.controls.zoomTicks, .everyStep)
        XCTAssertFalse(settings.display.dimDuringLongShots)
        XCTAssertFalse(settings.capture.prioritizeSpeed)
        XCTAssertEqual(settings.capture.artist, "")
        XCTAssertEqual(settings.capture.copyright, "")
        XCTAssertFalse(settings.video.allowAudioPlayback)
        XCTAssertEqual(settings.appearance, AppearanceOptions())
        XCTAssertEqual(settings.accessibility, AccessibilityOptions())
        XCTAssertEqual(settings.topBar, TopBarOptions())
        XCTAssertEqual(settings.startup, StartupOptions())
        // Opening the camera changes nothing until an option says so.
        XCTAssertEqual(settings.applyingStartupOptions(), settings)
    }

    func testTheLastVersionsSaveLoadsWithTheNewSettingsAtTheirDefaults() {
        let loaded = CameraSettings.decoded(from: Data(lastVersionDefaults.utf8))
        // Its frame shape was saved with it, so it stays 4:3; everything added since starts at its default.
        var expected = CameraSettings.default
        expected.capture.aspect = .fourThree
        XCTAssertEqual(loaded, expected)
    }

    func testOldSavesKeepEveryValueAndGetTheNewSettingsAtTheirDefaults() throws {
        let customised = everyFieldCustomised()
        let older = CameraSettings.decoded(from: try removing(addedKeys, from: customised.encoded()))
        var expected = customised
        expected.capture.prioritizeSpeed = false
        expected.capture.artist = ""
        expected.capture.copyright = ""
        expected.display.dimDuringLongShots = false
        expected.video.allowAudioPlayback = false
        expected.controls.volumeUpAction = .shutter
        expected.controls.volumeDownAction = .shutter
        expected.controls.hapticStrength = .normal
        expected.controls.dialTicks = true
        expected.controls.zoomTicks = .everyStep
        expected.appearance = AppearanceOptions()
        expected.accessibility = AccessibilityOptions()
        expected.topBar = TopBarOptions()
        expected.startup = StartupOptions()
        XCTAssertEqual(older, expected)
    }

    func testTheNewSettingsDecodeTolerantly() {
        // A value from a later version, or of the wrong type, goes back to its default alone.
        let json = #"""
            {"controls":{"haptics":false,"volumeUpAction":"selfie","volumeDownAction":"zoomIn","hapticStrength":3,
            "dialTicks":"no","zoomTicks":"lensValues"},
            "display":{"grid":"thirds","dimDuringLongShots":"yes"},
            "capture":{"quality":0.75,"prioritizeSpeed":"yes","artist":42,"copyright":"Sam"},
            "video":{"audio":false,"allowAudioPlayback":{}},
            "appearance":"dark","accessibility":{"largerLabels":true,"reduceMotion":"on"},
            "topBar":7,"startup":{"keepMode":false,"keepBrightness":null},"zoom":2}
            """#
        let decoded = CameraSettings.decoded(from: Data(json.utf8))
        XCTAssertFalse(decoded.controls.haptics)
        XCTAssertEqual(decoded.controls.volumeUpAction, .shutter)
        XCTAssertEqual(decoded.controls.volumeDownAction, .zoomIn)
        XCTAssertEqual(decoded.controls.hapticStrength, .normal)
        XCTAssertTrue(decoded.controls.dialTicks)
        XCTAssertEqual(decoded.controls.zoomTicks, .lensValues)
        XCTAssertEqual(decoded.display.grid, .thirds)
        XCTAssertFalse(decoded.display.dimDuringLongShots)
        XCTAssertEqual(decoded.capture.quality, 0.75, accuracy: 1e-9)
        XCTAssertFalse(decoded.capture.prioritizeSpeed)
        XCTAssertEqual(decoded.capture.artist, "")
        XCTAssertEqual(decoded.capture.copyright, "Sam")
        XCTAssertFalse(decoded.video.audio)
        XCTAssertFalse(decoded.video.allowAudioPlayback)
        XCTAssertEqual(decoded.appearance, AppearanceOptions())
        XCTAssertTrue(decoded.accessibility.largerLabels)
        XCTAssertFalse(decoded.accessibility.reduceMotion)
        XCTAssertEqual(decoded.topBar, TopBarOptions())
        XCTAssertFalse(decoded.startup.keepMode)
        XCTAssertTrue(decoded.startup.keepLensAndZoom)
        XCTAssertTrue(decoded.startup.keepBrightness)
        XCTAssertEqual(decoded.zoom, 2)

        // Set values come back.
        let set = #"""
            {"controls":{"volumeUpAction":"brighter","volumeDownAction":"nextLens","hapticStrength":"strong",
            "dialTicks":false},"display":{"dimDuringLongShots":true},
            "capture":{"prioritizeSpeed":true,"artist":"Sam","copyright":""},"video":{"allowAudioPlayback":true},
            "appearance":{"scheme":"light","accent":"green"},"topBar":{"leading":["level"],"trailing":[]}}
            """#
        let chosen = CameraSettings.decoded(from: Data(set.utf8))
        XCTAssertEqual(chosen.controls.volumeUpAction, .brighter)
        XCTAssertEqual(chosen.controls.volumeDownAction, .nextLens)
        XCTAssertEqual(chosen.controls.hapticStrength, .strong)
        XCTAssertFalse(chosen.controls.dialTicks)
        XCTAssertTrue(chosen.display.dimDuringLongShots)
        XCTAssertTrue(chosen.capture.prioritizeSpeed)
        XCTAssertEqual(chosen.capture.artist, "Sam")
        XCTAssertTrue(chosen.video.allowAudioPlayback)
        XCTAssertEqual(chosen.appearance.scheme, .light)
        XCTAssertEqual(chosen.appearance.accent, .green)
        XCTAssertEqual(chosen.topBar, TopBarOptions(leading: [.level], trailing: []))
    }

    // MARK: - Default frame shape

    func testFreshSettingsFrameSixteenNine() throws {
        XCTAssertEqual(CaptureOptions().aspect, .sixteenNine)
        XCTAssertEqual(CameraSettings().capture.aspect, .sixteenNine)
        XCTAssertEqual(CameraSettings.default.capture.aspect, .sixteenNine)
        XCTAssertEqual(CameraSettings.decoded(from: Data("{}".utf8)).capture.aspect, .sixteenNine)
        XCTAssertEqual(CameraSettings.decoded(from: Data("not json".utf8)).capture.aspect, .sixteenNine)
        // A capture object without the key, or with one this version can't read, gets the default alone.
        let missing = CameraSettings.decoded(from: Data(#"{"capture":{"quality":0.8,"flash":"on"}}"#.utf8))
        XCTAssertEqual(missing.capture.aspect, .sixteenNine)
        XCTAssertEqual(missing.capture.quality, 0.8, accuracy: 1e-9)
        XCTAssertEqual(missing.capture.flash, .on)
        XCTAssertEqual(CameraSettings.decoded(from: Data(#"{"capture":{"aspect":"wide"}}"#.utf8)).capture.aspect,
                       .sixteenNine)

        // Saves carry their shape, so a saved 4:3 stays 4:3.
        let saved = CameraSettings.decoded(from: Data(#"{"capture":{"aspect":{"long":4,"short":3}}}"#.utf8))
        XCTAssertEqual(saved.capture.aspect, .fourThree)
        var fourThree = CameraSettings()
        fourThree.capture.aspect = .fourThree
        XCTAssertEqual(CameraSettings.decoded(from: try fourThree.encoded()).capture.aspect, .fourThree)

        // The simple interface offers 16:9, so a fresh start stays on it in either interface.
        XCTAssertEqual(CameraSettings.default.simplified().capture.aspect, .sixteenNine)
        XCTAssertEqual(CameraSettings.default.simplified().restoringAdvanced(from: nil).capture.aspect, .sixteenNine)
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

    func testCarouselOrderForEachInterface() {
        XCTAssertEqual(CaptureMode.carouselOrder(advanced: true), CaptureMode.carouselOrder)
        XCTAssertEqual(Set(CaptureMode.carouselOrder(advanced: true)), Set(CaptureMode.allCases))
        // The simple carousel is the same row without MANUAL, so the other modes keep their neighbours.
        XCTAssertEqual(CaptureMode.carouselOrder(advanced: false), [.night, .long, .photo, .video])
        XCTAssertEqual(CaptureMode.carouselOrder(advanced: false), CaptureMode.carouselOrder.filter { $0 != .manual })
        // Both start on the mode a fresh install opens in.
        for advanced in [false, true] {
            XCTAssertTrue(CaptureMode.carouselOrder(advanced: advanced).contains(CameraSettings.default.mode))
        }
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

    // MARK: - Interface level

    func testInterfaceStartsSimpleWithTheQuestionOpen() {
        let interface = InterfaceOptions()
        XCTAssertFalse(interface.advanced)
        XCTAssertFalse(interface.welcomed)
        XCTAssertEqual(CameraSettings.default.interface, interface)
        // Settings saved before the interface level existed: the first-launch question is still to be asked.
        let older = CameraSettings.decoded(from: Data(#"{"mode":"manual","manual":{"iso":400}}"#.utf8))
        XCTAssertEqual(older.interface, interface)
        XCTAssertEqual(older.mode, .manual)
        XCTAssertEqual(older.manual.iso, 400)
    }

    func testInterfaceOptionsRoundTripAndDecodeTolerantly() throws {
        for (advanced, welcomed) in [(false, false), (false, true), (true, false), (true, true)] {
            var settings = CameraSettings()
            settings.interface.advanced = advanced
            settings.interface.welcomed = welcomed
            XCTAssertEqual(CameraSettings.decoded(from: try settings.encoded()).interface, settings.interface)
        }

        let partial = CameraSettings.decoded(from: Data(#"{"interface":{"welcomed":true}}"#.utf8))
        XCTAssertFalse(partial.interface.advanced)
        XCTAssertTrue(partial.interface.welcomed)

        // A wrong type or a key from a later version costs that one value only.
        let odd = CameraSettings.decoded(from: Data(#"{"interface":{"advanced":"yes","welcomed":true,"level":3}}"#.utf8))
        XCTAssertFalse(odd.interface.advanced)
        XCTAssertTrue(odd.interface.welcomed)
        let unreadable = CameraSettings.decoded(from: Data(#"{"interface":"advanced","zoom":2}"#.utf8))
        XCTAssertEqual(unreadable.interface, InterfaceOptions())
        XCTAssertEqual(unreadable.zoom, 2)
    }

    // MARK: - Long exposure scenes

    func testFreshLongExposureIsWaterAsItsRecipeSetsIt() {
        let fresh = LongExposureSettings()
        XCTAssertEqual(fresh.scene, .water)
        XCTAssertEqual(fresh.recipe, LongExposureScene.water.recipe)
        var picked = fresh
        picked.apply(.water)
        XCTAssertEqual(picked, fresh)
        // A first long exposure in daylight can't come out white: Blur keeps one frame's brightness.
        XCTAssertEqual(fresh.blend, .average)
        XCTAssertFalse(fresh.bulb)
        XCTAssertEqual(CameraSettings.default.longExposure, fresh)
        XCTAssertEqual(CameraSettings.decoded(from: Data("{}".utf8)).longExposure, fresh)
        XCTAssertEqual(CameraSettings.decoded(from: Data(#"{"longExposure":{}}"#.utf8)).longExposure, fresh)
    }

    func testApplyLoadsEveryValueOfTheRecipe() {
        for scene in LongExposureScene.presets {
            guard let recipe = scene.recipe else { return XCTFail("\(scene.rawValue) has a recipe") }
            // Starts from values this recipe doesn't use, so each one has to be written.
            var long = LongExposureSettings()
            long.seconds = 77
            long.blend = recipe.blend == .lighten ? .average : .lighten
            long.bulb = !recipe.bulb
            long.align = !recipe.align
            long.frameSeconds = recipe.frameSeconds == nil ? 0.5 : nil
            long.maxBulbSeconds = 600
            long.apply(scene)

            XCTAssertEqual(long.scene, scene)
            XCTAssertEqual(long.recipe, recipe)
            XCTAssertEqual(long.blend, recipe.blend, scene.rawValue)
            XCTAssertEqual(long.seconds, recipe.seconds, scene.rawValue)
            XCTAssertEqual(long.bulb, recipe.bulb, scene.rawValue)
            XCTAssertEqual(long.frameSeconds, recipe.frameSeconds, scene.rawValue)
            XCTAssertEqual(long.align, recipe.align, scene.rawValue)
            // The bulb limit is the person's own, whatever the scene.
            XCTAssertEqual(long.maxBulbSeconds, 600, scene.rawValue)

            // Compared by name as well, so a value added to both types later can't be left out of apply(_:).
            let wanted = Dictionary(uniqueKeysWithValues: Mirror(reflecting: recipe).children.compactMap { child in
                child.label.map { ($0, String(reflecting: child.value)) }
            })
            var loaded: [String] = []
            for child in Mirror(reflecting: long).children {
                guard let name = child.label, let value = wanted[name] else { continue }
                XCTAssertEqual(String(reflecting: child.value), value, "\(scene.rawValue).\(name)")
                loaded.append(name)
            }
            XCTAssertEqual(loaded.sorted(), ["align", "blend", "bulb", "frameSeconds", "seconds"])
        }
    }

    func testApplyingCustomKeepsEveryValue() {
        var long = LongExposureSettings()
        long.apply(.starTrails)
        long.seconds = 900
        long.maxBulbSeconds = 600
        var expected = long
        expected.scene = .custom
        long.apply(.custom)
        XCTAssertEqual(long, expected)
        XCTAssertNil(long.recipe)

        // From the hand-set values of an older save, too.
        var manual = LongExposureSettings()
        manual.scene = .custom
        manual.blend = .additive
        manual.seconds = 240
        manual.bulb = true
        manual.align = false
        manual.frameSeconds = 0.25
        let before = manual
        manual.apply(.custom)
        XCTAssertEqual(manual, before)
    }

    /// What a saved `longExposure` object decodes to.
    private func longExposure(saved json: String) -> LongExposureSettings {
        CameraSettings.decoded(from: Data(#"{"longExposure":\#(json)}"#.utf8)).longExposure
    }

    func testLongExposureSavedBeforeScenesIsCustom() {
        // As a version without scenes wrote it: every value, no scene.
        let long = longExposure(saved: """
            {"align":false,"blend":"lighten","bulb":true,"frameSeconds":0.25,"maxBulbSeconds":600,"seconds":120}
            """)
        XCTAssertEqual(long.scene, .custom)
        XCTAssertNil(long.recipe)
        XCTAssertEqual(long.blend, .lighten)
        XCTAssertEqual(long.seconds, 120)
        XCTAssertTrue(long.bulb)
        XCTAssertFalse(long.align)
        XCTAssertEqual(long.frameSeconds, 0.25)
        XCTAssertEqual(long.maxBulbSeconds, 600)

        // That version's own defaults, Real for 4 s, are still what its owner had on screen.
        let old = longExposure(saved: """
            {"align":false,"blend":"additive","bulb":false,"maxBulbSeconds":1800,"seconds":4}
            """)
        XCTAssertEqual(old.scene, .custom)
        XCTAssertEqual(old.blend, .additive)
        XCTAssertEqual(old.seconds, 4)
        XCTAssertFalse(old.align)
        XCTAssertNil(old.frameSeconds)

        // Either value alone tells a save with a choice in it. Without one it is a fresh start.
        XCTAssertEqual(longExposure(saved: #"{"seconds":60}"#).scene, .custom)
        XCTAssertEqual(longExposure(saved: #"{"blend":"lighten"}"#).scene, .custom)
        XCTAssertEqual(longExposure(saved: #"{"maxBulbSeconds":600}"#).scene, .water)
        XCTAssertEqual(longExposure(saved: "{}"), LongExposureSettings())
    }

    func testAnUnreadableSceneKeepsItsSavedValuesAsCustom() {
        // A scene from a later version, saved with the blend and time it had loaded.
        let later = longExposure(saved: #"{"scene":"sunset","blend":"additive","seconds":8,"align":false}"#)
        XCTAssertEqual(later.scene, .custom)
        XCTAssertEqual(later.blend, .additive)
        XCTAssertEqual(later.seconds, 8)
        XCTAssertFalse(later.align)

        XCTAssertEqual(longExposure(saved: #"{"scene":7,"blend":"lighten","seconds":30}"#).scene, .custom)
        XCTAssertEqual(longExposure(saved: #"{"scene":null,"blend":"lighten","seconds":30}"#).scene, .custom)
        // With nothing saved beside it there is nothing to keep.
        XCTAssertEqual(longExposure(saved: #"{"scene":"sunset"}"#), LongExposureSettings())
    }

    func testASavedSceneComesBackWithItsValues() {
        let stars = longExposure(saved: """
            {"align":false,"blend":"additive","bulb":false,"maxBulbSeconds":1800,"scene":"stars","seconds":20}
            """)
        var picked = LongExposureSettings()
        picked.apply(.stars)
        picked.seconds = 20
        XCTAssertEqual(stars, picked)
        // Custom is a scene of its own in a save, not the lack of one.
        XCTAssertEqual(longExposure(saved: #"{"scene":"custom"}"#).scene, .custom)
    }

    func testASavedSceneTakesItsValuesFromTheRecipe() throws {
        // As a version with another Fireworks recipe saved it. The scene, its time and the bulb limit are the
        // save's; the rest is the recipe as it is now, so nothing reads as changed by hand and turns it into Custom.
        let older = longExposure(saved: """
            {"align":true,"blend":"average","bulb":true,"frameSeconds":0.25,"maxBulbSeconds":600,"scene":"fireworks","seconds":10}
            """)
        var expected = LongExposureSettings()
        expected.apply(.fireworks)
        expected.seconds = 10
        expected.maxBulbSeconds = 600
        XCTAssertEqual(older, expected)

        // Every scene, from values none of them uses.
        for scene in LongExposureScene.presets {
            guard let recipe = scene.recipe else { return XCTFail("\(scene.rawValue) has a recipe") }
            var settings = CameraSettings()
            settings.longExposure.apply(scene)
            settings.longExposure.seconds = 77
            settings.longExposure.maxBulbSeconds = 600
            settings.longExposure.blend = recipe.blend == .lighten ? .average : .lighten
            settings.longExposure.bulb = !recipe.bulb
            settings.longExposure.align = !recipe.align
            settings.longExposure.frameSeconds = recipe.frameSeconds == nil ? 0.5 : nil
            var wanted = LongExposureSettings()
            wanted.apply(scene)
            wanted.seconds = 77
            wanted.maxBulbSeconds = 600
            XCTAssertEqual(CameraSettings.decoded(from: try settings.encoded()).longExposure, wanted, scene.rawValue)
        }
    }

    func testEverySceneRoundTrips() throws {
        for scene in LongExposureScene.allCases {
            var settings = CameraSettings()
            settings.longExposure.apply(scene)
            let decoded = CameraSettings.decoded(from: try settings.encoded())
            XCTAssertEqual(decoded.longExposure.scene, scene)
            // Frame shutters like 1/30 s come back to the last bit, or the scene would read as changed.
            XCTAssertEqual(decoded, settings, scene.rawValue)
        }
        var custom = CameraSettings()
        custom.longExposure.apply(.fireworks)
        custom.longExposure.blend = .average
        custom.longExposure.scene = .custom
        XCTAssertEqual(CameraSettings.decoded(from: try custom.encoded()), custom)
    }
}
