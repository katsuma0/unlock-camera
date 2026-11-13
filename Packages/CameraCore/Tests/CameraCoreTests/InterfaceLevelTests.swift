import XCTest
@testable import CameraCore

final class InterfaceLevelTests: XCTestCase {
    /// Settings both interfaces show. Everything else in CameraSettings belongs to the advanced interface alone,
    /// apart from the switch between the two.
    private let shared: Set<String> = [
        "mode", "lensID", "zoom",
        "manual.bias",
        "capture.processedFormat", "capture.flash", "capture.aspect", "capture.livePhoto", "capture.silentShutter",
        "capture.mirrorFront", "capture.saveLocation", "capture.schedule",
        "capture.prioritizeSpeed", "capture.artist", "capture.copyright",
        "display.grid", "display.showLevel", "display.dimDuringLongShots",
        "night.seconds", "night.biasEV",
        "longExposure.scene", "longExposure.seconds", "longExposure.blend", "longExposure.bulb", "longExposure.align",
        "longExposure.frameSeconds",
        "video.resolution", "video.frameRate", "video.allowAudioPlayback",
        "controls.volumeShutter", "controls.haptics",
        "controls.volumeUpAction", "controls.volumeDownAction", "controls.hapticStrength", "controls.dialTicks",
        "controls.zoomTicks",
        "interface.welcomed",
        // How the app looks and handles.
        "appearance.scheme", "appearance.accent",
        "accessibility.largerLabels", "accessibility.solidControls", "accessibility.reduceMotion",
        "accessibility.leftHanded", "accessibility.speakStatus",
        "topBar.leading", "topBar.trailing",
        "startup.keepMode", "startup.keepLensAndZoom", "startup.keepBrightness",
    ]
    private let levelSwitch = "interface.advanced"

    // MARK: - Fixtures

    /// Every setting moved off its default. Where both interfaces show a setting, it holds a choice the simple one
    /// offers, so `simplified()` has nothing to narrow.
    private func everythingChanged() -> CameraSettings {
        var s = CameraSettings()
        s.mode = .night
        s.lensID = "com.apple.avfoundation.avcapturedevice.built-in_video:2"
        s.zoom = 2
        s.manual = ManualExposureSetting(shutter: 1.0 / 250, iso: 400, aperture: 2.8, bias: -0.7)
        s.whiteBalance = .kelvin(4300, tint: 12)
        s.focus = .manual(lensPosition: 0.42)
        s.capture.processedFormat = .jpeg
        s.capture.rawFormat = .proRAW
        s.capture.quality = 0.8
        s.capture.resolution = .mp48
        s.capture.processing = .minimal
        s.capture.flash = .auto
        // 16:9 is the default now; 4:3 is the simple interface's other full-width shape.
        s.capture.aspect = .fourThree
        s.capture.livePhoto = true
        s.capture.silentShutter = true
        s.capture.depth = true
        s.capture.constantColor = true
        s.capture.lensCorrection = false
        s.capture.mirrorFront = false
        s.capture.saveLocation = true
        s.capture.schedule = CaptureSchedule(delay: 10)
        s.capture.bracket = BracketPlan(kind: .exposure, count: 5, step: 1)
        s.capture.prioritizeSpeed = true
        s.capture.artist = "Sam Rivera"
        s.capture.copyright = "Copyright 2026 Sam Rivera"
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
        s.display.grid = .thirds
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
        // Light painting differs from Water in every value a scene loads.
        s.longExposure.apply(.lightPainting)
        s.longExposure.maxBulbSeconds = 600
        s.video.resolution = .hd1080
        s.video.frameRate = 60
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
        s.controls.volumeUpAction = .zoomIn
        s.controls.volumeDownAction = .darker
        s.controls.hapticStrength = .strong
        s.controls.dialTicks = false
        s.controls.zoomTicks = .lensValues
        s.interface.advanced = true
        s.interface.welcomed = true
        s.appearance.scheme = .light
        s.appearance.accent = .teal
        s.accessibility.largerLabels = true
        s.accessibility.solidControls = true
        s.accessibility.reduceMotion = true
        s.accessibility.leftHanded = true
        s.accessibility.speakStatus = true
        // An advanced-only button among them: the simple interface hides it from the bar but keeps it in the list.
        s.topBar = TopBarOptions(leading: [.timer, .grid, .histogram], trailing: [.level, .location])
        s.startup.keepMode = false
        s.startup.keepLensAndZoom = false
        s.startup.keepBrightness = false
        return s
    }

    /// An advanced setup the simple interface has no choices for: MANUAL, RAW only, a panorama frame, an
    /// intervalometer behind a long timer, a golden ratio grid and a long exposure set by hand.
    private func advancedSetup() -> CameraSettings {
        var s = everythingChanged()
        s.mode = .manual
        s.capture.processedFormat = .none
        s.capture.aspect = .xpan
        s.capture.schedule = CaptureSchedule(delay: 30, shots: 20, interval: 30)
        s.display.grid = .goldenRatio
        s.longExposure.scene = .custom
        s.longExposure.blend = .additive
        s.longExposure.seconds = 240
        s.longExposure.bulb = false
        s.longExposure.align = true
        s.longExposure.frameSeconds = 0.25
        return s
    }

    /// A scene left as picked, apart from a time off its list from the advanced dial. Any other value changed by
    /// hand would have made it Custom.
    private func adjustedScene() -> CameraSettings {
        var s = everythingChanged()
        s.mode = .long
        s.longExposure.apply(.stars)
        s.longExposure.seconds = 25
        return s
    }

    /// Every stored setting by path ("capture.rawFormat") with its value written out. The option groups are the
    /// structs directly inside CameraSettings; whatever a group holds, a schedule or a bracket included, is one
    /// value.
    private func leaves(of settings: CameraSettings) -> [String: String] {
        var values: [String: String] = [:]
        for child in Mirror(reflecting: settings).children {
            guard let name = child.label else { continue }
            let group = Mirror(reflecting: child.value)
            guard group.displayStyle == .struct else {
                values[name] = String(reflecting: child.value)
                continue
            }
            for member in group.children {
                guard let memberName = member.label else { continue }
                values["\(name).\(memberName)"] = String(reflecting: member.value)
            }
        }
        return values
    }

    /// `settings` as a version before scenes and the interface level saved them: the same JSON without the two.
    private func savedBeforeTheSimpleInterface(_ settings: CameraSettings) throws -> Data {
        let json = try XCTUnwrap(String(data: settings.encoded(), encoding: .utf8))
        let interface = #""interface":{"advanced":\#(settings.interface.advanced),"welcomed":\#(settings.interface.welcomed)},"#
        let scene = #""scene":"\#(settings.longExposure.scene.rawValue)","#
        XCTAssertTrue(json.contains(interface) && json.contains(scene), json)
        return Data(json.replacingOccurrences(of: interface, with: "").replacingOccurrences(of: scene, with: "").utf8)
    }

    // MARK: - Which settings are whose

    func testEverySettingIsAdvancedOrNamedShared() {
        let defaults = leaves(of: .default)
        let changed = leaves(of: everythingChanged())
        XCTAssertEqual(Set(changed.keys), Set(defaults.keys))
        // The mirror sees the settings: a few from either side by name.
        for path in ["mode", "capture.rawFormat", "exposure.meteringArea", "controls.cameraControlItems", levelSwitch] {
            XCTAssertNotNil(defaults[path], path)
        }
        // A setting the fixture leaves at its default can't show which way it goes. A new setting goes into
        // everythingChanged() first.
        for path in defaults.keys.sorted() {
            XCTAssertNotEqual(changed[path], defaults[path], "everythingChanged() leaves \(path) at its default")
        }
        XCTAssertEqual(shared.subtracting(defaults.keys).sorted(), [], "Listed as shared, but no such setting")
        XCTAssertFalse(shared.contains(levelSwitch))

        let restored = leaves(of: CameraSettings.default.restoringAdvanced(from: everythingChanged()))
        let simple = leaves(of: everythingChanged().simplified())
        let baseline = leaves(of: CameraSettings.default.simplified())
        for path in defaults.keys.sorted() where path != levelSwitch {
            if shared.contains(path) {
                XCTAssertEqual(restored[path], defaults[path],
                               "\(path) is listed as shared, but going advanced takes it from the snapshot")
                XCTAssertEqual(simple[path], changed[path], "\(path) is listed as shared, but going simple resets it")
            } else {
                XCTAssertEqual(restored[path], changed[path],
                               "\(path) is neither restored with the advanced settings nor listed as shared here")
                XCTAssertEqual(simple[path], baseline[path],
                               "\(path) is not listed as shared here, but going simple doesn't reset it")
            }
        }
        XCTAssertEqual(restored[levelSwitch], "true")
        XCTAssertEqual(simple[levelSwitch], "false")
    }

    func testEverySettingSurvivesBeingSaved() throws {
        // Every value is off its default (checked above), so a setting missing from the coding keys or from the
        // decoder shows here as a difference.
        for settings in [everythingChanged(), advancedSetup(), adjustedScene(), everythingChanged().simplified()] {
            XCTAssertEqual(CameraSettings.decoded(from: try settings.encoded()), settings)
        }
    }

    // MARK: - Simple choices

    func testSimpleChoicesComeFromTheFullLists() {
        XCTAssertEqual(CameraSettings.simpleAspects.map(\.label), ["4:3", "1:1", "16:9"])
        for aspect in CameraSettings.simpleAspects {
            XCTAssertTrue(AspectRatio.presets.contains(aspect), aspect.label)
        }
        XCTAssertEqual(CameraSettings.simpleDelays, [0, 3, 5, 10])
        for delay in CameraSettings.simpleDelays {
            XCTAssertTrue(CaptureSchedule.delayPresets.contains(delay), "\(delay)")
        }
        XCTAssertEqual(CameraSettings.simpleGrids, [.off, .thirds])
        // What a fresh install starts on is among them.
        XCTAssertTrue(CameraSettings.simpleAspects.contains(CameraSettings.default.capture.aspect))
        XCTAssertTrue(CameraSettings.simpleDelays.contains(CameraSettings.default.capture.schedule.delay))
        XCTAssertTrue(CameraSettings.simpleGrids.contains(CameraSettings.default.display.grid))
    }

    func testSimpleCameraControlLeadsNowhereManual() {
        XCTAssertEqual(CameraSettings.simpleCameraControlItems, [.zoom, .lens, .exposureBias])
        // The mode item would offer MANUAL, and the others set what the simple interface keeps on auto.
        for item in [CameraControlItem.shutter, .iso, .aperture, .whiteBalance, .focus, .mode] {
            XCTAssertFalse(CameraSettings.simpleCameraControlItems.contains(item), item.rawValue)
        }
        // The same first three as the advanced default, so the Camera Control opens on the same thing.
        XCTAssertEqual(Array(CameraControlItem.defaultSelection.prefix(3)), CameraSettings.simpleCameraControlItems)
    }

    // MARK: - Going simple

    func testDefaultsGoSimpleByTurningTheMeasuringToolsOff() {
        var expected = CameraSettings.default
        expected.display.histogram = .off
        expected.display.peaking = .off
        expected.display.showReadout = false
        expected.display.clippingWarnings = false
        let simple = CameraSettings.default.simplified()
        XCTAssertEqual(simple, expected)
        XCTAssertFalse(simple.display.zebras)
        XCTAssertFalse(simple.display.falseColor)
        XCTAssertFalse(simple.interface.advanced)
    }

    func testGoingSimpleResetsWhatOnlyAdvancedShows() {
        let baseline = leaves(of: CameraSettings.default.simplified())
        for settings in [everythingChanged(), advancedSetup(), adjustedScene()] {
            let simple = leaves(of: settings.simplified())
            for path in baseline.keys.sorted() where !shared.contains(path) && path != levelSwitch {
                XCTAssertEqual(simple[path], baseline[path], path)
            }
            XCTAssertEqual(simple[levelSwitch], "false")
        }
        // Spelled out for the ones a picture depends on.
        let simple = advancedSetup().simplified()
        XCTAssertEqual(simple.manual.locks, ExposureLocks())
        XCTAssertEqual(simple.whiteBalance, .auto)
        XCTAssertEqual(simple.focus, .auto)
        XCTAssertEqual(simple.capture.rawFormat, .none)
        XCTAssertEqual(simple.capture.bracket, .off)
        XCTAssertEqual(simple.exposure, ExposureOptions())
        XCTAssertEqual(simple.focusOptions, FocusOptions())
        XCTAssertEqual(simple.controls.cameraControlItems, CameraControlItem.defaultSelection)
    }

    func testGoingSimpleKeepsWhatBothInterfacesShow() {
        let before = leaves(of: everythingChanged())
        let after = leaves(of: everythingChanged().simplified())
        for path in shared.sorted() {
            XCTAssertEqual(after[path], before[path], path)
        }
        // The answer to the first-launch question is not a setting to reset.
        XCTAssertTrue(everythingChanged().simplified().interface.welcomed)
        XCTAssertFalse(CameraSettings.default.simplified().interface.welcomed)
    }

    func testGoingSimpleTwiceChangesNothingMore() throws {
        let saved = CameraSettings.decoded(from: try savedBeforeTheSimpleInterface(advancedSetup()))
        for settings in [CameraSettings.default, everythingChanged(), advancedSetup(), adjustedScene(), saved] {
            let once = settings.simplified()
            XCTAssertEqual(once.simplified(), once)
            // Through a save as well: the model simplifies what it loads on every launch.
            XCTAssertEqual(CameraSettings.decoded(from: try once.encoded()).simplified(), once)
        }
    }

    func testEveryChoiceOfTheSimpleInterfaceIsLeftAlone() {
        let base = everythingChanged().simplified()
        var choices = [base, CameraSettings.default.simplified()]
        func add(_ change: (inout CameraSettings) -> Void) {
            var settings = base
            change(&settings)
            choices.append(settings)
        }
        for mode in CaptureMode.carouselOrder(advanced: false) {
            add { $0.mode = mode }
        }
        for aspect in CameraSettings.simpleAspects {
            add { $0.capture.aspect = aspect }
        }
        for delay in CameraSettings.simpleDelays {
            add { $0.capture.schedule = CaptureSchedule(delay: delay) }
        }
        for grid in CameraSettings.simpleGrids {
            add { $0.display.grid = grid }
        }
        for format in [ProcessedFormat.heif, .jpeg] {
            add { $0.capture.processedFormat = format }
        }
        for scene in LongExposureScene.presets {
            guard let recipe = scene.recipe else { return XCTFail("\(scene.rawValue) has a recipe") }
            for seconds in recipe.durations.isEmpty ? [recipe.seconds] : recipe.durations {
                add {
                    $0.longExposure.apply(scene)
                    $0.longExposure.seconds = seconds
                }
            }
        }
        for seconds in [nil, 1, 7.5, 30] as [Double?] {
            add { $0.night.seconds = seconds }
        }
        for bias in [-2, 0, 1.3] {
            add {
                $0.manual.bias = bias
                $0.night.biasEV = -bias
            }
        }
        add {
            $0.zoom = 0.5
            $0.lensID = nil
            $0.capture.flash = .on
            $0.capture.livePhoto = false
            $0.video.resolution = .uhd4K
            $0.video.frameRate = 24
            $0.display.showLevel = true
        }
        for choice in choices {
            XCTAssertEqual(choice.simplified(), choice)
        }
    }

    func testGoingSimpleLeavesManualModeForPhoto() {
        var settings = CameraSettings()
        for mode in CaptureMode.allCases {
            settings.mode = mode
            let simple = settings.simplified().mode
            XCTAssertEqual(simple, mode == .manual ? .photo : mode, mode.rawValue)
            XCTAssertTrue(CaptureMode.carouselOrder(advanced: false).contains(simple), mode.rawValue)
        }
    }

    func testGoingSimpleGivesARawOnlySetupAProcessedFormat() {
        var settings = CameraSettings()
        settings.capture.processedFormat = .none
        settings.capture.rawFormat = .bayer
        XCTAssertTrue(settings.capture.isValid)
        let simple = settings.simplified()
        XCTAssertEqual(simple.capture.rawFormat, .none)
        XCTAssertEqual(simple.capture.processedFormat, .heif)
        XCTAssertTrue(simple.capture.isValid)
        // RAW next to a processed format: the format stays.
        settings.capture.processedFormat = .jpeg
        XCTAssertEqual(settings.simplified().capture.processedFormat, .jpeg)
        XCTAssertEqual(settings.simplified().capture.rawFormat, .none)
    }

    func testGoingSimpleNarrowsTheAspectToFourThree() {
        var settings = CameraSettings()
        for aspect in AspectRatio.presets + [AspectRatio(7, 5)] {
            settings.capture.aspect = aspect
            let offered = CameraSettings.simpleAspects.contains(aspect)
            XCTAssertEqual(settings.simplified().capture.aspect, offered ? aspect : .fourThree, aspect.label)
        }
        // A sensor mode's 1.78:1 is 16:9 to every aspect picker, so it stays.
        settings.capture.aspect = AspectRatio(1.78, 1)
        XCTAssertEqual(settings.simplified().capture.aspect, AspectRatio(1.78, 1))
    }

    func testGoingSimpleShortensTheTimerAndDropsTheIntervalometer() {
        func simple(_ schedule: CaptureSchedule) -> CaptureSchedule {
            var settings = CameraSettings()
            settings.capture.schedule = schedule
            return settings.simplified().capture.schedule
        }
        XCTAssertEqual(simple(CaptureSchedule(delay: 30)), CaptureSchedule(delay: 10))
        XCTAssertEqual(simple(CaptureSchedule(delay: 600)), CaptureSchedule(delay: 10))
        // A delay the simple interface doesn't list goes down to one it does, never up: nobody waits longer than
        // they asked to.
        XCTAssertEqual(simple(CaptureSchedule(delay: 7)), CaptureSchedule(delay: 5))
        XCTAssertEqual(simple(CaptureSchedule(delay: 5)), CaptureSchedule(delay: 5))
        XCTAssertEqual(simple(CaptureSchedule(delay: 4)), CaptureSchedule(delay: 3))
        XCTAssertEqual(simple(CaptureSchedule(delay: 2)), .off)
        // An intervalometer becomes one shot and keeps its timer.
        XCTAssertEqual(simple(CaptureSchedule(shots: 20, interval: 30)), .off)
        XCTAssertEqual(simple(CaptureSchedule(delay: 10, shots: 20, interval: 30)), CaptureSchedule(delay: 10))
        XCTAssertEqual(simple(CaptureSchedule(delay: 30, shots: 5)), CaptureSchedule(delay: 10))
        for delay in CaptureSchedule.delayPresets + [1, 4, 45] {
            let kept = simple(CaptureSchedule(delay: delay, shots: 3, interval: 2))
            XCTAssertEqual(kept, CaptureSchedule(delay: kept.delay), "\(delay)")
            // The longest listed delay that is no longer than the one asked for.
            XCTAssertTrue(CameraSettings.simpleDelays.contains(kept.delay), "\(delay)")
            XCTAssertLessThanOrEqual(kept.delay, delay, "\(delay)")
            XCTAssertFalse(CameraSettings.simpleDelays.contains { $0 > kept.delay && $0 <= delay }, "\(delay)")
        }
    }

    func testGoingSimpleTurnsEveryOtherGridIntoThirds() {
        var settings = CameraSettings()
        for grid in GridStyle.allCases {
            settings.display.grid = grid
            XCTAssertEqual(settings.simplified().display.grid, grid == .off ? .off : .thirds, grid.rawValue)
        }
    }

    func testGoingSimplePutsACustomLongExposureOnWater() {
        let simple = advancedSetup().simplified()
        XCTAssertEqual(simple.longExposure.scene, .water)
        XCTAssertEqual(simple.longExposure, LongExposureSettings())
        // Whatever the hand-set values were, a time Water offers included.
        var custom = CameraSettings()
        custom.longExposure.scene = .custom
        custom.longExposure.blend = .lighten
        custom.longExposure.seconds = 8
        custom.longExposure.bulb = true
        XCTAssertEqual(custom.simplified().longExposure, LongExposureSettings())
    }

    func testGoingSimpleKeepsASceneAndNarrowsItsTime() {
        var settings = CameraSettings()
        settings.longExposure.apply(.stars)
        settings.longExposure.seconds = 20
        XCTAssertEqual(settings.simplified().longExposure, settings.longExposure)

        // A time off the scene's list, from the advanced dial, becomes the closest one on it.
        for (set, offered) in [(27.0, 30.0), (120, 30), (1, 10), (12, 10), (13, 15), (25, 20)] {
            settings.longExposure.seconds = set
            let long = settings.simplified().longExposure
            XCTAssertEqual(long.seconds, offered, "\(set)")
            XCTAssertEqual(long.scene, .stars)
        }

        // The rest follows the recipe again, alignment turned on in Settings included.
        settings.longExposure.seconds = 15
        settings.longExposure.align = true
        var picked = LongExposureSettings()
        picked.apply(.stars)
        XCTAssertEqual(settings.simplified().longExposure, picked)

        // A scene without times keeps running until the second tap.
        settings.longExposure.apply(.lightPainting)
        XCTAssertEqual(settings.simplified().longExposure, settings.longExposure)

        // Whatever the time was, every scene ends on one of the times its row of chips shows.
        for scene in LongExposureScene.presets {
            guard let recipe = scene.recipe else { return XCTFail("\(scene.rawValue) has a recipe") }
            for seconds in [0.25, 3, 25, 90, 700, 1800] {
                settings.longExposure.apply(scene)
                settings.longExposure.seconds = seconds
                let kept = settings.simplified().longExposure.seconds
                XCTAssertTrue(recipe.durations.contains(kept) || (recipe.durations.isEmpty && kept == recipe.seconds),
                              "\(scene.rawValue) \(seconds)")
            }
        }
    }

    // MARK: - Going advanced

    func testGoingAdvancedTakesEveryAdvancedSettingFromTheSnapshot() {
        let snapshot = everythingChanged()
        let wanted = leaves(of: snapshot)
        for current in [CameraSettings.default, CameraSettings.default.simplified(), advancedSetup().simplified()] {
            let restored = leaves(of: current.restoringAdvanced(from: snapshot))
            for path in wanted.keys.sorted() where !shared.contains(path) && path != levelSwitch {
                XCTAssertEqual(restored[path], wanted[path], path)
            }
            XCTAssertEqual(restored[levelSwitch], "true")
        }
    }

    func testGoingAdvancedKeepsWhatWasSetInTheSimpleInterface() {
        var current = CameraSettings.default.simplified()
        current.mode = .video
        current.lensID = "back.telephoto"
        current.zoom = 3
        current.manual.bias = 1
        current.capture.processedFormat = .jpeg
        current.capture.flash = .on
        current.capture.aspect = .square
        current.capture.livePhoto = true
        current.capture.silentShutter = true
        current.capture.mirrorFront = false
        current.capture.saveLocation = true
        current.capture.schedule = CaptureSchedule(delay: 3)
        current.display.grid = .off
        current.display.showLevel = false
        current.night.seconds = 5
        current.night.biasEV = -1
        current.longExposure.apply(.fireworks)
        current.longExposure.seconds = 10
        current.video.resolution = .hd720
        current.video.frameRate = 24
        current.controls.volumeShutter = false
        current.controls.haptics = false
        current.interface.welcomed = true
        // Off their defaults, and off the snapshots' values wherever a setting has a third one, so taking a value
        // from either would show.
        current.capture.prioritizeSpeed = true
        current.capture.artist = "Kim"
        current.capture.copyright = "Kim, all rights reserved"
        current.display.dimDuringLongShots = true
        current.video.allowAudioPlayback = true
        current.controls.volumeUpAction = .brighter
        current.controls.volumeDownAction = .nextLens
        current.controls.hapticStrength = .light
        current.controls.dialTicks = false
        current.controls.zoomTicks = .lensValues
        current.appearance.scheme = .dark
        current.appearance.accent = .pink
        current.accessibility.leftHanded = true
        current.accessibility.speakStatus = true
        current.topBar = TopBarOptions(leading: [.level], trailing: [.batterySaver])
        current.startup.keepMode = false
        let before = leaves(of: current)
        for snapshot in [everythingChanged(), advancedSetup(), adjustedScene(), nil] {
            let after = leaves(of: current.restoringAdvanced(from: snapshot))
            // Apart from a long exposure set by hand, which only the advanced interface makes (tested below).
            let handMade = snapshot?.longExposure.scene == .custom
            for path in shared.sorted() where !(handMade && path.hasPrefix("longExposure.")) {
                XCTAssertEqual(after[path], before[path], path)
            }
        }
    }

    func testGoingAdvancedWithoutASnapshotStartsFromTheDefaults() {
        let simple = everythingChanged().simplified()
        let restored = simple.restoringAdvanced(from: nil)
        let before = leaves(of: simple)
        let after = leaves(of: restored)
        let defaults = leaves(of: .default)
        for path in defaults.keys.sorted() where path != levelSwitch {
            XCTAssertEqual(after[path], shared.contains(path) ? before[path] : defaults[path], path)
        }
        XCTAssertTrue(restored.interface.advanced)

        // From a fresh install: the defaults as they are, measuring tools on.
        var advancedDefaults = CameraSettings.default
        advancedDefaults.interface.advanced = true
        XCTAssertEqual(CameraSettings.default.simplified().restoringAdvanced(from: nil), advancedDefaults)
        XCTAssertEqual(CameraSettings.default.simplified().restoringAdvanced(from: .default), advancedDefaults)
    }

    func testGoingAdvancedTwiceChangesNothingMore() {
        let setups = [CameraSettings.default, everythingChanged(), advancedSetup(), adjustedScene()]
        for snapshot in setups + [nil] {
            // From the simple interface, as the model does it, and from settings that never were simple.
            for current in setups.map({ $0.simplified() }) + setups {
                let once = current.restoringAdvanced(from: snapshot)
                XCTAssertTrue(once.interface.advanced)
                XCTAssertTrue(once.capture.isValid)
                XCTAssertEqual(once.restoringAdvanced(from: snapshot), once)
            }
        }
    }

    func testTheBulbLimitHasNoSayInWhatComesBack() {
        // The limit is an advanced setting kept among the long exposure's values. Settings holding another limit
        // than the simple interface runs still count as untouched, the first time and every time after. On a
        // scene, since a long exposure set by hand comes back either way.
        var snapshot = adjustedScene()
        snapshot.longExposure.maxBulbSeconds = 1800
        var current = snapshot.simplified()
        current.longExposure.maxBulbSeconds = 600
        let restored = current.restoringAdvanced(from: snapshot)
        XCTAssertEqual(restored.longExposure, snapshot.longExposure)
        XCTAssertEqual(restored.restoringAdvanced(from: snapshot), restored)
    }

    func testGoingAdvancedAlwaysLeavesAFormatToSave() {
        // RAW only, and the snapshot has no RAW to bring back.
        var current = CameraSettings()
        current.capture.processedFormat = .none
        current.capture.rawFormat = .bayer
        for snapshot in [nil, CameraSettings.default, everythingChanged().simplified()] {
            let restored = current.restoringAdvanced(from: snapshot)
            XCTAssertTrue(restored.capture.isValid)
            XCTAssertEqual(restored.capture.processedFormat, .heif)
            XCTAssertEqual(restored.capture.rawFormat, .none)
        }
    }

    // MARK: - There and back

    func testOffAndOnAgainBringsEverythingBack() {
        var advancedDefaults = CameraSettings.default
        advancedDefaults.interface.advanced = true
        for settings in [everythingChanged(), advancedSetup(), adjustedScene(), advancedDefaults] {
            // MANUAL included: the simple interface put it on PHOTO, and nothing has moved it since.
            XCTAssertEqual(settings.simplified().restoringAdvanced(from: settings), settings)
        }
        XCTAssertEqual(advancedSetup().simplified().mode, .photo)
    }

    func testOnAndOffAgainLeavesTheSimpleInterfaceAsItWas() {
        let setups = [CameraSettings.default, everythingChanged(), advancedSetup(), adjustedScene()]
        for simple in setups.map({ $0.simplified() }) {
            // Whatever the snapshot holds, its own or someone else's or none.
            for snapshot in setups + [nil] {
                var expected = simple
                // Apart from a long exposure set by hand: it comes back over the simple interface's own, and going
                // simple again puts it on Water, as the first time.
                if let snapshot, snapshot.longExposure.scene == .custom {
                    expected.longExposure = snapshot.simplified().longExposure
                }
                XCTAssertEqual(simple.restoringAdvanced(from: snapshot).simplified(), expected)
            }
        }
    }

    func testWhatGoingSimpleNarrowedComesBack() {
        let snapshot = advancedSetup()
        let simple = snapshot.simplified()
        XCTAssertEqual(simple.mode, .photo)
        XCTAssertEqual(simple.capture.aspect, .fourThree)
        XCTAssertEqual(simple.capture.schedule, CaptureSchedule(delay: 10))
        XCTAssertEqual(simple.display.grid, .thirds)
        XCTAssertEqual(simple.longExposure.scene, .water)
        XCTAssertEqual(simple.capture.processedFormat, .heif)

        let restored = simple.restoringAdvanced(from: snapshot)
        XCTAssertEqual(restored.mode, .manual)
        XCTAssertEqual(restored.capture.aspect, .xpan)
        XCTAssertEqual(restored.capture.schedule, CaptureSchedule(delay: 30, shots: 20, interval: 30))
        XCTAssertEqual(restored.display.grid, .goldenRatio)
        XCTAssertEqual(restored.longExposure, snapshot.longExposure)
        // RAW only again, as it was.
        XCTAssertEqual(restored.capture.processedFormat, .none)
        XCTAssertEqual(restored.capture.rawFormat, .proRAW)

        // A scene's own time too.
        let scene = adjustedScene()
        XCTAssertEqual(scene.simplified().longExposure.seconds, 20)
        XCTAssertEqual(scene.simplified().restoringAdvanced(from: scene).longExposure, scene.longExposure)
    }

    func testWhatWasChangedInTheSimpleInterfaceStaysChanged() {
        let snapshot = advancedSetup()
        var simple = snapshot.simplified()
        simple.capture.aspect = .square
        let partly = simple.restoringAdvanced(from: snapshot)
        XCTAssertEqual(partly.capture.aspect, .square)
        // The ones left alone still come back.
        XCTAssertEqual(partly.mode, .manual)
        XCTAssertEqual(partly.display.grid, .goldenRatio)
        XCTAssertEqual(partly.capture.schedule, snapshot.capture.schedule)
        XCTAssertEqual(partly.longExposure, snapshot.longExposure)
        XCTAssertEqual(partly.capture.processedFormat, .none)

        simple.mode = .night
        simple.capture.processedFormat = .jpeg
        simple.capture.schedule = .off
        simple.display.grid = .off
        simple.longExposure.apply(.stars)
        let changed = simple.restoringAdvanced(from: snapshot)
        XCTAssertEqual(changed.mode, .night)
        XCTAssertEqual(changed.capture.aspect, .square)
        XCTAssertEqual(changed.capture.processedFormat, .jpeg)
        XCTAssertEqual(changed.capture.rawFormat, .proRAW)
        XCTAssertEqual(changed.capture.schedule, .off)
        XCTAssertEqual(changed.display.grid, .off)
        // Except the long exposure set by hand, which the simple interface has no way to make: it comes back over
        // the scene picked since.
        XCTAssertEqual(changed.longExposure, snapshot.longExposure)
    }

    func testManualComesBackWhileTheModeIsStillPhoto() {
        // Going simple put MANUAL on PHOTO. Another mode picked since is where the person is now, and stays.
        let snapshot = advancedSetup()
        for mode in CaptureMode.carouselOrder(advanced: false) {
            var simple = snapshot.simplified()
            simple.mode = mode
            XCTAssertEqual(simple.restoringAdvanced(from: snapshot).mode, mode == .photo ? .manual : mode, mode.rawValue)
        }
        // A snapshot in any other mode leaves the mode where it is.
        for saved in CaptureMode.allCases where saved != .manual {
            var other = snapshot
            other.mode = saved
            for mode in CaptureMode.carouselOrder(advanced: false) {
                var simple = other.simplified()
                simple.mode = mode
                XCTAssertEqual(simple.restoringAdvanced(from: other).mode, mode, "\(saved.rawValue) \(mode.rawValue)")
            }
        }
    }

    func testALongExposureComesBackWholeOrNotAtAll() {
        let snapshot = adjustedScene()
        var simple = snapshot.simplified()
        // Another time picked on the scene's chips: the scene is the simple interface's now.
        simple.longExposure.seconds = 30
        let restored = simple.restoringAdvanced(from: snapshot).longExposure
        XCTAssertEqual(restored.scene, .stars)
        XCTAssertEqual(restored.seconds, 30)

        // Another scene on the time narrowing left: bringing back the time alone would give Fireworks the 12 s
        // that Light trails had.
        var trails = everythingChanged()
        trails.longExposure.apply(.lightTrails)
        trails.longExposure.seconds = 12
        var fireworks = trails.simplified()
        XCTAssertEqual(fireworks.longExposure.seconds, 10)
        fireworks.longExposure.apply(.fireworks)
        fireworks.longExposure.seconds = 10
        let picked = fireworks.restoringAdvanced(from: trails).longExposure
        XCTAssertEqual(picked.scene, .fireworks)
        XCTAssertEqual(picked.seconds, 10)
    }

    func testALongExposureSetByHandComesBackWhateverWasPickedSince() {
        // Trails for twenty minutes, one second frames, no alignment: five controls on the advanced panel, where a
        // scene or a time on the simple one takes a tap to have again.
        var snapshot = everythingChanged()
        snapshot.mode = .long
        snapshot.longExposure.scene = .custom
        snapshot.longExposure.blend = .lighten
        snapshot.longExposure.seconds = 1200
        snapshot.longExposure.bulb = false
        snapshot.longExposure.frameSeconds = 1
        snapshot.longExposure.align = false
        let simple = snapshot.simplified()
        XCTAssertEqual(simple.longExposure.scene, .water)
        var longer = simple
        longer.longExposure.seconds = 4
        var stars = simple
        stars.longExposure.apply(.stars)
        for current in [simple, longer, stars] {
            let restored = current.restoringAdvanced(from: snapshot)
            XCTAssertEqual(restored.longExposure, snapshot.longExposure)
            XCTAssertEqual(restored.restoringAdvanced(from: snapshot), restored)
        }

        // A scene the advanced interface was left on is the simple interface's to change, and the change stays.
        let scene = adjustedScene()
        var picked = scene.simplified()
        picked.longExposure.apply(.fireworks)
        let kept = picked.restoringAdvanced(from: scene).longExposure
        XCTAssertEqual(kept.scene, .fireworks)
        XCTAssertEqual(kept.seconds, LongExposureScene.fireworks.recipe?.seconds)
    }

    func testASaveFromBeforeTheSimpleInterfaceComesBackWhole() throws {
        // Someone who answers the first-launch question with Simple and turns Advanced on later: the model keeps
        // the old save as the snapshot and restores from it.
        let loaded = CameraSettings.decoded(from: try savedBeforeTheSimpleInterface(advancedSetup()))
        XCTAssertEqual(loaded.interface, InterfaceOptions())
        XCTAssertEqual(loaded.longExposure.scene, .custom)
        XCTAssertEqual(loaded.longExposure.blend, .additive)
        XCTAssertEqual(loaded.longExposure.seconds, 240)

        var answered = loaded
        answered.interface.welcomed = true
        let simple = answered.simplified()
        XCTAssertEqual(simple.longExposure, LongExposureSettings())

        var expected = loaded
        expected.interface.advanced = true
        expected.interface.welcomed = true
        XCTAssertEqual(simple.restoringAdvanced(from: loaded), expected)
    }
}
