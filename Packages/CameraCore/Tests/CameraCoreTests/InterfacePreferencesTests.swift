import XCTest
@testable import CameraCore

final class InterfacePreferencesTests: XCTestCase {
    private let anything: (TopBarItem) -> Bool = { _ in true }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func rgb(_ hex: UInt32) -> RGBA8 {
        RGBA8(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF))
    }

    // MARK: - Stored names

    func testStoredNamesStayTheSame() {
        // Saves hold these names: renaming one would quietly drop the choices people made with it.
        XCTAssertEqual(AppearanceScheme.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AccentChoice.allCases.map(\.rawValue),
                       ["yellow", "orange", "green", "teal", "blue", "purple", "pink"])
        XCTAssertEqual(HapticStrength.allCases.map(\.rawValue), ["light", "normal", "strong"])
        XCTAssertEqual(ZoomTickStyle.allCases.map(\.rawValue), ["everyStep", "lensValues"])
        XCTAssertEqual(HardwareButtonAction.allCases.map(\.rawValue),
                       ["shutter", "zoomIn", "zoomOut", "brighter", "darker", "nextLens"])
        XCTAssertEqual(TopBarItem.allCases.map(\.rawValue),
                       ["flash", "livePhoto", "timer", "aspect", "grid", "level", "location", "quietShutter",
                        "batterySaver", "nightDuration", "raw", "exposureLock", "format", "resolution", "processing",
                        "histogram", "zebras", "peaking", "falseColor", "whiteBalance", "stabilization", "sound"])
        XCTAssertEqual(AppearanceScheme.allCases.map(\.id), AppearanceScheme.allCases.map(\.rawValue))
        XCTAssertEqual(AccentChoice.allCases.map(\.id), AccentChoice.allCases.map(\.rawValue))
        XCTAssertEqual(HapticStrength.allCases.map(\.id), HapticStrength.allCases.map(\.rawValue))
        XCTAssertEqual(ZoomTickStyle.allCases.map(\.id), ZoomTickStyle.allCases.map(\.rawValue))
        XCTAssertEqual(HardwareButtonAction.allCases.map(\.id), HardwareButtonAction.allCases.map(\.rawValue))
        XCTAssertEqual(TopBarItem.allCases.map(\.id), TopBarItem.allCases.map(\.rawValue))
    }

    // MARK: - Appearance

    func testAppearanceStartsOnMatchIPhoneWithTheCameraYellow() throws {
        let appearance = AppearanceOptions()
        XCTAssertEqual(appearance.scheme, .system)
        XCTAssertEqual(appearance.accent, .yellow)
        // The yellow the app has always drawn with (Theme.accent and the AccentColor asset: 1.0, 0.839, 0.039).
        XCTAssertEqual(appearance.accent.camera, RGBA8(r: 255, g: 214, b: 10))
        XCTAssertEqual(try decode(AppearanceOptions.self, "{}"), appearance)

        for scheme in AppearanceScheme.allCases {
            for accent in AccentChoice.allCases {
                var options = AppearanceOptions()
                options.scheme = scheme
                options.accent = accent
                XCTAssertEqual(try roundTrip(options), options)
            }
        }
        // A choice from a later version, red included, costs that one value.
        let later = try decode(AppearanceOptions.self, #"{"scheme":"sepia","accent":"blue"}"#)
        XCTAssertEqual(later.scheme, .system)
        XCTAssertEqual(later.accent, .blue)
        let red = try decode(AppearanceOptions.self, #"{"scheme":"light","accent":"red"}"#)
        XCTAssertEqual(red.scheme, .light)
        XCTAssertEqual(red.accent, .yellow)
    }

    func testAppearanceTitles() {
        XCTAssertEqual(AppearanceScheme.allCases.map(\.title), ["Match iPhone", "Light", "Dark"])
        XCTAssertEqual(AccentChoice.allCases.map(\.title),
                       ["Yellow", "Orange", "Green", "Teal", "Blue", "Purple", "Pink"])
    }

    func testThePaletteHasItsDesignedShades() {
        // The swatch row in order, each with its camera and light sheet shade.
        let table: [(AccentChoice, UInt32, UInt32)] = [
            (.yellow, 0xFFD60A, 0x946F00), (.orange, 0xFF9F0A, 0xB35300), (.green, 0x30D158, 0x1E7E34),
            (.teal, 0x40C8E0, 0x007A8F), (.blue, 0x409CFF, 0x0040DD), (.purple, 0xDA8FFF, 0x8944AB),
            (.pink, 0xFF6482, 0xD30F45),
        ]
        XCTAssertEqual(AccentChoice.allCases, table.map { $0.0 })
        for (accent, camera, lightSheet) in table {
            XCTAssertEqual(accent.camera, rgb(camera), accent.rawValue)
            XCTAssertEqual(accent.lightSheet, rgb(lightSheet), accent.rawValue)
        }
    }

    // MARK: - Contrast (WCAG 2.x)

    /// Relative luminance of an opaque sRGB color.
    private func luminance(_ color: RGBA8) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    /// Contrast ratio, 1 to 21.
    private func contrast(_ a: RGBA8, _ b: RGBA8) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `color` at `opacity` over an opaque `backdrop`, as sRGB compositing draws it.
    private func composite(_ color: RGBA8, opacity: Double, over backdrop: RGBA8) -> RGBA8 {
        func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8((Double(top) * opacity + Double(bottom) * (1 - opacity)).rounded())
        }
        return RGBA8(r: mix(color.r, backdrop.r), g: mix(color.g, backdrop.g), b: mix(color.b, backdrop.b))
    }

    func testTheContrastHelperFollowsWCAG() {
        XCTAssertEqual(contrast(.white, .black), 21, accuracy: 1e-9)
        XCTAssertEqual(contrast(.black, .white), 21, accuracy: 1e-9)
        XCTAssertEqual(contrast(rgb(0x2C2C2E), rgb(0x2C2C2E)), 1, accuracy: 1e-12)
        // #767676 is the lightest gray that passes 4.5:1 on white, and #777777 just fails.
        XCTAssertEqual(contrast(rgb(0x767676), .white), 4.54, accuracy: 0.005)
        XCTAssertLessThan(contrast(rgb(0x777777), .white), 4.5)
        XCTAssertEqual(composite(.white, opacity: 0.2, over: .black), RGBA8(r: 51, g: 51, b: 51))
        XCTAssertEqual(composite(rgb(0xFFD60A), opacity: 0.2, over: .black), RGBA8(r: 51, g: 43, b: 2))
    }

    func testEveryAccentIsReadableWhereItIsUsed() {
        // The lightest dark backing on the camera (glass or a chip over black), and a light sheet's grouped gray.
        let darkGlass = rgb(0x2C2C2E)
        let groupedGray = rgb(0xF2F2F7)
        for accent in AccentChoice.allCases {
            let name = accent.rawValue
            XCTAssertEqual(accent.camera.a, 255, name)
            XCTAssertEqual(accent.lightSheet.a, 255, name)
            // Small labels on the camera.
            XCTAssertGreaterThanOrEqual(contrast(accent.camera, darkGlass), 4.5, name)
            // Black text on an accent fill. White would be unreadable on every shade, so on the camera the text on
            // a fill stays black whatever the choice.
            XCTAssertGreaterThanOrEqual(contrast(accent.camera, .black), 4.5, name)
            XCTAssertLessThan(contrast(accent.camera, .white), 3, name)
            // An active drawer item: the accent glyph on its own 20 percent tint over black.
            let tint = composite(accent.camera, opacity: 0.2, over: .black)
            XCTAssertGreaterThanOrEqual(contrast(accent.camera, tint), 3, name)
            // Light sheets: text on white cells and on the grouped background, and white text on a fill.
            XCTAssertGreaterThanOrEqual(contrast(accent.lightSheet, .white), 4.5, name)
            XCTAssertGreaterThanOrEqual(contrast(accent.lightSheet, groupedGray), 4.0, name)
        }
    }

    // MARK: - Accessibility

    func testAccessibilityOptionsStartOff() throws {
        let options = AccessibilityOptions()
        // A new option goes into this list and starts off like the rest.
        let flags = Mirror(reflecting: options).children
        XCTAssertEqual(flags.compactMap { $0.label },
                       ["largerLabels", "solidControls", "reduceMotion", "leftHanded", "speakStatus"])
        for flag in flags {
            XCTAssertEqual(flag.value as? Bool, false, flag.label ?? "")
        }
        XCTAssertEqual(try decode(AccessibilityOptions.self, "{}"), options)

        // Each one is saved under its own name.
        let paths: [WritableKeyPath<AccessibilityOptions, Bool>] = [
            \.largerLabels, \.solidControls, \.reduceMotion, \.leftHanded, \.speakStatus,
        ]
        for path in paths {
            var one = AccessibilityOptions()
            one[keyPath: path] = true
            XCTAssertEqual(try roundTrip(one), one)
        }
        // A wrong value costs that one option.
        let odd = try decode(AccessibilityOptions.self, #"{"solidControls":true,"leftHanded":"left","speakStatus":true}"#)
        XCTAssertTrue(odd.solidControls)
        XCTAssertFalse(odd.leftHanded)
        XCTAssertTrue(odd.speakStatus)
        XCTAssertFalse(odd.largerLabels)
        XCTAssertFalse(odd.reduceMotion)
    }

    // MARK: - Buttons and haptics

    func testButtonsAndHapticsStartAsTheyAlwaysWorked() {
        let controls = ControlOptions()
        XCTAssertEqual(controls.volumeUpAction, .shutter)
        XCTAssertEqual(controls.volumeDownAction, .shutter)
        XCTAssertEqual(controls.hapticStrength, .normal)
        XCTAssertTrue(controls.dialTicks)
        XCTAssertEqual(controls.zoomTicks, .everyStep)
        XCTAssertTrue(controls.haptics)
        XCTAssertTrue(controls.volumeShutter)

        XCTAssertEqual(HardwareButtonAction.allCases.map(\.title),
                       ["Shutter", "Zoom in", "Zoom out", "Brighter", "Darker", "Next lens"])
        XCTAssertEqual(HapticStrength.allCases.map(\.title), ["Light", "Normal", "Strong"])
        XCTAssertEqual(ZoomTickStyle.allCases.map(\.title), ["Every step", "Lens values only"])
    }

    func testEachButtonKeepsItsOwnAction() throws {
        for up in HardwareButtonAction.allCases {
            for down in HardwareButtonAction.allCases {
                var controls = ControlOptions()
                controls.volumeUpAction = up
                controls.volumeDownAction = down
                let back = try roundTrip(controls)
                XCTAssertEqual(back.volumeUpAction, up)
                XCTAssertEqual(back.volumeDownAction, down)
            }
        }
        for strength in HapticStrength.allCases {
            var controls = ControlOptions()
            controls.hapticStrength = strength
            XCTAssertEqual(try roundTrip(controls), controls)
        }
        for ticks in ZoomTickStyle.allCases {
            var controls = ControlOptions()
            controls.zoomTicks = ticks
            XCTAssertEqual(try roundTrip(controls), controls)
        }
    }

    // MARK: - Startup

    func testStartupKeepsEverythingUnlessToldOtherwise() throws {
        let options = StartupOptions()
        XCTAssertTrue(options.keepMode)
        XCTAssertTrue(options.keepLensAndZoom)
        XCTAssertTrue(options.keepBrightness)
        XCTAssertEqual(Mirror(reflecting: options).children.count, 3)
        XCTAssertEqual(try decode(StartupOptions.self, "{}"), options)
        let paths: [WritableKeyPath<StartupOptions, Bool>] = [\.keepMode, \.keepLensAndZoom, \.keepBrightness]
        for path in paths {
            var one = StartupOptions()
            one[keyPath: path] = false
            XCTAssertEqual(try roundTrip(one), one)
        }
        let odd = try decode(StartupOptions.self, #"{"keepMode":false,"keepLensAndZoom":"no"}"#)
        XCTAssertFalse(odd.keepMode)
        XCTAssertTrue(odd.keepLensAndZoom)
        XCTAssertTrue(odd.keepBrightness)
    }

    func testOpeningTheCameraStartsFreshWhereNothingIsKept() {
        var left = CameraSettings()
        left.mode = .long
        left.lensID = "com.apple.avfoundation.avcapturedevice.built-in_video:2"
        left.zoom = 5
        left.manual.bias = -1.3
        left.night.biasEV = 0.7
        left.capture.flash = .on
        left.longExposure.apply(.stars)
        // Everything kept: it opens as it was left.
        XCTAssertEqual(left.applyingStartupOptions(), left)

        var mode = left
        mode.startup.keepMode = false
        var expected = mode
        expected.mode = .photo
        XCTAssertEqual(mode.applyingStartupOptions(), expected)

        var lens = left
        lens.startup.keepLensAndZoom = false
        expected = lens
        expected.lensID = nil
        expected.zoom = 1
        XCTAssertEqual(lens.applyingStartupOptions(), expected)

        var brightness = left
        brightness.startup.keepBrightness = false
        expected = brightness
        expected.manual.bias = 0
        expected.night.biasEV = 0
        XCTAssertEqual(brightness.applyingStartupOptions(), expected)

        // Nothing kept: where a fresh install starts, with every other setting as it was.
        var none = left
        none.startup.keepMode = false
        none.startup.keepLensAndZoom = false
        none.startup.keepBrightness = false
        let fresh = none.applyingStartupOptions()
        XCTAssertEqual(fresh.mode, CameraSettings.default.mode)
        XCTAssertEqual(fresh.lensID, CameraSettings.default.lensID)
        XCTAssertEqual(fresh.zoom, CameraSettings.default.zoom)
        XCTAssertEqual(fresh.manual, CameraSettings.default.manual)
        XCTAssertEqual(fresh.night.biasEV, CameraSettings.default.night.biasEV)
        XCTAssertEqual(fresh.capture, left.capture)
        XCTAssertEqual(fresh.longExposure, left.longExposure)
        XCTAssertEqual(fresh.startup, none.startup)
        XCTAssertEqual(fresh.applyingStartupOptions(), fresh)
    }

    // MARK: - Top bar buttons

    func testWhichButtonsOnlyTheAdvancedInterfaceOffers() {
        let advancedOnly: Set<TopBarItem> = [
            .raw, .exposureLock, .format, .resolution, .processing, .histogram, .zebras, .peaking, .falseColor,
            .whiteBalance, .stabilization, .sound,
        ]
        for item in TopBarItem.allCases {
            XCTAssertEqual(item.isAdvancedOnly, advancedOnly.contains(item), item.rawValue)
        }
    }

    func testWhereEachButtonApplies() {
        let every = Set(CaptureMode.allCases)
        let stills: Set<CaptureMode> = [.night, .long, .photo, .manual]
        let single: Set<CaptureMode> = [.photo, .manual]
        let modes: [TopBarItem: Set<CaptureMode>] = [
            // In VIDEO, Flash is the flashlight.
            .flash: [.photo, .manual, .video], .livePhoto: [.photo], .timer: stills, .aspect: stills, .grid: every,
            .level: every, .location: every, .quietShutter: single, .batterySaver: [.night, .long],
            .nightDuration: [.night], .raw: single, .exposureLock: every, .format: stills, .resolution: single,
            .processing: single, .histogram: every, .zebras: every, .peaking: every, .falseColor: every,
            .whiteBalance: every, .stabilization: [.video], .sound: [.video],
        ]
        XCTAssertEqual(Set(modes.keys), Set(TopBarItem.allCases))
        for item in TopBarItem.allCases {
            for mode in CaptureMode.allCases {
                XCTAssertEqual(item.applies(in: mode), modes[item]?.contains(mode) ?? false,
                               "\(item.rawValue) in \(mode.rawValue)")
            }
        }
        // Each mode of the simple interface has buttons to offer.
        for mode in CaptureMode.carouselOrder(advanced: false) {
            XCTAssertTrue(TopBarItem.allCases.contains { !$0.isAdvancedOnly && $0.applies(in: mode) }, mode.rawValue)
        }
    }

    func testTopBarTitlesAndSymbols() {
        XCTAssertEqual(TopBarItem.allCases.map { $0.title(advanced: true) },
                       ["Flash", "Live Photo", "Timer", "Aspect ratio", "Grid", "Level", "Location tags",
                        "Silent shutter", "Battery saver", "Night duration", "RAW", "AE lock", "Format", "Resolution",
                        "Processing", "Histogram", "Zebras", "Focus peaking", "False color", "White balance",
                        "Stabilization", "Sound"])
        // The simple interface's own words where they differ, the same names elsewhere.
        for item in TopBarItem.allCases {
            let simple = item.title(advanced: false)
            switch item {
            case .quietShutter: XCTAssertEqual(simple, "Quiet shutter")
            case .nightDuration: XCTAssertEqual(simple, "Night time")
            default: XCTAssertEqual(simple, item.title(advanced: true), item.rawValue)
            }
        }
        // The names tell the buttons apart at either level.
        for advanced in [false, true] {
            let titles = TopBarItem.allCases.filter { advanced || !$0.isAdvancedOnly }.map { $0.title(advanced: advanced) }
            XCTAssertEqual(Set(titles).count, titles.count)
        }
        for item in TopBarItem.allCases {
            XCTAssertFalse(item.symbolNames.isEmpty, item.rawValue)
            XCTAssertFalse(item.symbolNames.contains(""), item.rawValue)
            XCTAssertEqual(Set(item.symbolNames).count, item.symbolNames.count, item.rawValue)
        }
    }

    // MARK: - Top bar: the saved lists

    func testTheDefaultBarIsTheBarAsItWas() {
        let bar = TopBarOptions()
        XCTAssertEqual(bar.leading, [.flash])
        XCTAssertEqual(bar.trailing, [.raw, .livePhoto])
        func shown(_ mode: CaptureMode, advanced: Bool, has: Set<TopBarItem> = Set(TopBarItem.allCases)) -> [[TopBarItem]] {
            let sides = bar.shown(advanced: advanced, mode: mode) { has.contains($0) }
            return [sides.leading, sides.trailing]
        }
        // Flash on the left; RAW (advanced) and Live on the right of PHOTO; RAW alone in MANUAL; nothing in NIGHT
        // and LONG; the flashlight in VIDEO.
        XCTAssertEqual(shown(.photo, advanced: false), [[.flash], [.livePhoto]])
        XCTAssertEqual(shown(.photo, advanced: true), [[.flash], [.raw, .livePhoto]])
        XCTAssertEqual(shown(.manual, advanced: true), [[.flash], [.raw]])
        for mode in [CaptureMode.night, .long] {
            for advanced in [false, true] {
                XCTAssertEqual(shown(mode, advanced: advanced), [[], []], mode.rawValue)
            }
        }
        XCTAssertEqual(shown(.video, advanced: false), [[.flash], []])
        XCTAssertEqual(shown(.video, advanced: true), [[.flash], []])
        // A camera without a flash or RAW shows what it has.
        XCTAssertEqual(shown(.photo, advanced: true, has: [.livePhoto]), [[], [.livePhoto]])
        XCTAssertEqual(shown(.photo, advanced: true, has: []), [[], []])
    }

    func testUnknownButtonsDropOutAlone() throws {
        // From a later version, or renamed since; names are exact.
        let later = try decode(TopBarOptions.self,
                               #"{"leading":["flash","selfieMirror","grid"],"trailing":["histogram","Flash"]}"#)
        XCTAssertEqual(later.leading, [.flash, .grid])
        XCTAssertEqual(later.trailing, [.histogram])
        // Entries that aren't names at all drop out the same way.
        let mixed = try decode(TopBarOptions.self,
                               #"{"leading":["timer",3,null,{"item":"grid"},["level"],true,"grid"],"trailing":["level"]}"#)
        XCTAssertEqual(mixed.leading, [.timer, .grid])
        XCTAssertEqual(mixed.trailing, [.level])
        // Nothing readable left is an empty side, not the default.
        XCTAssertEqual(try decode(TopBarOptions.self, #"{"leading":["selfieMirror"]}"#).leading, [])
    }

    func testEachButtonIsPlacedOnce() throws {
        let doubled = try decode(TopBarOptions.self,
                                 #"{"leading":["grid","timer","grid"],"trailing":["timer","level","level","grid","flash"]}"#)
        // Where it comes first, and the left side counts first.
        XCTAssertEqual(doubled.leading, [.grid, .timer])
        XCTAssertEqual(doubled.trailing, [.level, .flash])
        // Built in code, the same.
        XCTAssertEqual(TopBarOptions(leading: [.grid, .timer, .grid], trailing: [.timer, .level, .level, .grid, .flash]),
                       doubled)
    }

    func testASideKeepsAtMostEight() throws {
        XCTAssertEqual(TopBarOptions.storedLimit, 8)
        // A side may hold more than it shows, for buttons waiting on another interface or mode.
        XCTAssertGreaterThan(TopBarOptions.storedLimit, TopBarOptions.leadingRoom)
        let names = TopBarItem.allCases.map { #""\#($0.rawValue)""# }.joined(separator: ",")
        let long = try decode(TopBarOptions.self, #"{"leading":[\#(names)],"trailing":[\#(names)]}"#)
        XCTAssertEqual(long.leading, Array(TopBarItem.allCases.prefix(8)))
        // The right side keeps the next eight: the first eight are on the left already.
        XCTAssertEqual(long.trailing, Array(TopBarItem.allCases.dropFirst(8).prefix(8)))
        XCTAssertEqual(TopBarOptions(leading: TopBarItem.allCases, trailing: []).leading,
                       Array(TopBarItem.allCases.prefix(8)))
    }

    func testAnUnreadableSideKeepsTheOther() throws {
        let leftOdd = try decode(TopBarOptions.self, #"{"leading":"flash","trailing":["timer"]}"#)
        XCTAssertEqual(leftOdd.leading, TopBarOptions().leading)
        XCTAssertEqual(leftOdd.trailing, [.timer])
        let rightOdd = try decode(TopBarOptions.self, #"{"leading":["livePhoto","grid"],"trailing":{"raw":true}}"#)
        XCTAssertEqual(rightOdd.leading, [.livePhoto, .grid])
        // Its default, less the button the left side holds already.
        XCTAssertEqual(rightOdd.trailing, [.raw])
        // A missing or null side is its default too. An empty one stays empty: the person cleared it.
        let missing = try decode(TopBarOptions.self, #"{"trailing":["level"]}"#)
        XCTAssertEqual(missing.leading, [.flash])
        XCTAssertEqual(missing.trailing, [.level])
        XCTAssertEqual(try decode(TopBarOptions.self, #"{"leading":null,"trailing":[]}"#),
                       TopBarOptions(leading: [.flash], trailing: []))
        XCTAssertEqual(try decode(TopBarOptions.self, "{}"), TopBarOptions())
        // In a whole save, an unreadable bar costs only the bar.
        let settings = CameraSettings.decoded(from: Data(#"{"topBar":[1,2],"mode":"night"}"#.utf8))
        XCTAssertEqual(settings.topBar, TopBarOptions())
        XCTAssertEqual(settings.mode, .night)
    }

    func testTheBarRoundTrips() throws {
        let bars = [
            TopBarOptions(), TopBarOptions(leading: [], trailing: []),
            TopBarOptions(leading: [.sound, .timer, .zebras, .flash], trailing: [.batterySaver, .whiteBalance]),
        ]
        for bar in bars {
            XCTAssertEqual(try roundTrip(bar), bar)
        }
        // Saved by name, so a later version reads the same buttons.
        let json = String(decoding: try JSONEncoder().encode(TopBarOptions(leading: [.timer], trailing: [.livePhoto])),
                          as: UTF8.self)
        XCTAssertTrue(json.contains(#""leading":["timer"]"#), json)
        XCTAssertTrue(json.contains(#""trailing":["livePhoto"]"#), json)
    }

    // MARK: - Top bar: what it shows

    func testEachSideShowsItsFirstButtonsUpToItsRoom() {
        XCTAssertEqual(TopBarOptions.leadingRoom, 3)
        XCTAssertEqual(TopBarOptions.trailingRoom, 2)
        let bar = TopBarOptions(leading: [.timer, .grid, .level, .location, .aspect],
                                trailing: [.livePhoto, .quietShutter, .flash])
        let photo = bar.shown(advanced: false, mode: .photo, isAvailable: anything)
        XCTAssertEqual(photo.leading, [.timer, .grid, .level])
        XCTAssertEqual(photo.trailing, [.livePhoto, .quietShutter])
        // Less room shows the first ones, none shows nothing, and more shows more, in order.
        let narrow = bar.shown(advanced: false, mode: .photo, leadingRoom: 1, trailingRoom: 0, isAvailable: anything)
        XCTAssertEqual(narrow.leading, [.timer])
        XCTAssertEqual(narrow.trailing, [])
        let none = bar.shown(advanced: false, mode: .photo, leadingRoom: -2, trailingRoom: -1, isAvailable: anything)
        XCTAssertEqual(none.leading, [])
        XCTAssertEqual(none.trailing, [])
        let wide = bar.shown(advanced: false, mode: .photo, leadingRoom: 9, trailingRoom: 9, isAvailable: anything)
        XCTAssertEqual(wide.leading, [.timer, .grid, .level, .location, .aspect])
        XCTAssertEqual(wide.trailing, [.livePhoto, .quietShutter, .flash])
    }

    func testButtonsThatDontApplyStepAside() {
        let bar = TopBarOptions(leading: [.timer, .flash, .aspect, .grid, .level],
                                trailing: [.livePhoto, .nightDuration, .batterySaver, .sound])
        func shown(_ mode: CaptureMode) -> [[TopBarItem]] {
            let sides = bar.shown(advanced: true, mode: mode, isAvailable: anything)
            return [sides.leading, sides.trailing]
        }
        XCTAssertEqual(shown(.photo), [[.timer, .flash, .aspect], [.livePhoto]])
        // No flash in NIGHT or LONG: the next button moves up.
        XCTAssertEqual(shown(.night), [[.timer, .aspect, .grid], [.nightDuration, .batterySaver]])
        XCTAssertEqual(shown(.long), [[.timer, .aspect, .grid], [.batterySaver]])
        // Live only in PHOTO.
        XCTAssertEqual(shown(.manual), [[.timer, .flash, .aspect], []])
        // No timer or frame shape in VIDEO; sound only there.
        XCTAssertEqual(shown(.video), [[.flash, .grid, .level], [.sound]])
    }

    func testAdvancedButtonsWaitInTheSimpleInterface() {
        let bar = TopBarOptions(leading: [.histogram, .flash, .zebras, .grid, .level],
                                trailing: [.raw, .whiteBalance, .livePhoto])
        let simple = bar.shown(advanced: false, mode: .photo, isAvailable: anything)
        XCTAssertEqual(simple.leading, [.flash, .grid, .level])
        XCTAssertEqual(simple.trailing, [.livePhoto])
        let advanced = bar.shown(advanced: true, mode: .photo, isAvailable: anything)
        XCTAssertEqual(advanced.leading, [.histogram, .flash, .zebras])
        XCTAssertEqual(advanced.trailing, [.raw, .whiteBalance])
    }

    func testTheAppSaysWhatTheCameraHas() {
        let bar = TopBarOptions(leading: [.flash, .timer, .quietShutter, .grid], trailing: [.livePhoto, .location])
        // No flash on this camera, and its shutter sound can't be turned off: the next buttons move up.
        let sides = bar.shown(advanced: false, mode: .photo) { $0 != .flash && $0 != .quietShutter }
        XCTAssertEqual(sides.leading, [.timer, .grid])
        XCTAssertEqual(sides.trailing, [.livePhoto, .location])
    }

    func testAButtonShowsOnceWhateverTheLists() {
        // Lists changed directly are not cleaned, so the bar keeps each button to one place itself.
        var bar = TopBarOptions()
        bar.trailing = [.flash, .livePhoto]
        let once = bar.shown(advanced: false, mode: .photo, isAvailable: anything)
        XCTAssertEqual(once.leading, [.flash])
        XCTAssertEqual(once.trailing, [.livePhoto])
        bar.leading = [.grid, .grid, .level]
        let again = bar.shown(advanced: false, mode: .photo, isAvailable: anything)
        XCTAssertEqual(again.leading, [.grid, .level])
        XCTAssertEqual(again.trailing, [.flash, .livePhoto])
    }

    func testTheFurnitureTakesItsPlace() {
        let bar = TopBarOptions(leading: [.grid, .level, .location, .timer], trailing: [.histogram, .sound])
        // In VIDEO the format chip fills the right side.
        XCTAssertEqual(bar.shown(advanced: true, mode: .video, isAvailable: anything).trailing, [.histogram, .sound])
        XCTAssertEqual(bar.layout(advanced: true, mode: .video, wantsBadge: false, isAvailable: anything),
                       TopBarLayout(leading: [.grid, .level, .location], trailing: [], showsBadge: false))
        XCTAssertEqual(bar.layout(advanced: true, mode: .photo, wantsBadge: false, isAvailable: anything),
                       TopBarLayout(leading: [.grid, .level, .location], trailing: [.histogram], showsBadge: false))
        // A set timer's badge takes the last left slot. The Timer button is fourth, so it isn't there to stand in.
        XCTAssertEqual(bar.layout(advanced: true, mode: .photo, wantsBadge: true, isAvailable: anything),
                       TopBarLayout(leading: [.grid, .level], trailing: [.histogram], showsBadge: true))

        // A Timer button on the bar shows the timer itself: no badge, and nothing gives way.
        let timerFirst = TopBarOptions(leading: [.timer, .grid, .level], trailing: [.histogram])
        XCTAssertEqual(timerFirst.layout(advanced: true, mode: .photo, wantsBadge: true, isAvailable: anything),
                       TopBarLayout(leading: [.timer, .grid, .level], trailing: [.histogram], showsBadge: false))
        let timerRight = TopBarOptions(leading: [.grid, .level, .location], trailing: [.timer])
        XCTAssertEqual(timerRight.layout(advanced: false, mode: .night, wantsBadge: true, isAvailable: anything),
                       TopBarLayout(leading: [.grid, .level, .location], trailing: [.timer], showsBadge: false))
        // One that can't show doesn't stand in.
        XCTAssertEqual(timerFirst.layout(advanced: true, mode: .photo, wantsBadge: true) { $0 != .timer },
                       TopBarLayout(leading: [.grid, .level], trailing: [.histogram], showsBadge: true))

        // The default bar with a timer set: the badge after Flash in PHOTO, alone in NIGHT, as before.
        XCTAssertEqual(TopBarOptions().layout(advanced: true, mode: .photo, wantsBadge: true, isAvailable: anything),
                       TopBarLayout(leading: [.flash], trailing: [.raw, .livePhoto], showsBadge: true))
        XCTAssertEqual(TopBarOptions().layout(advanced: false, mode: .night, wantsBadge: true, isAvailable: anything),
                       TopBarLayout(leading: [], trailing: [], showsBadge: true))
    }

    // MARK: - Words

    /// Camera jargon the simple interface doesn't show.
    private let jargon: Set<String> = ["iso", "ev", "kelvin", "raw", "histogram", "stack", "blend", "frames", "bulb",
                                       "ae", "mm"]
    private let bannedWords = ["delve", "leverage", "utilize", "robust", "seamless", "elevate", "unlock", "harness",
                               "curated", "bespoke", "crafted", "journey", "realm", "tapestry", "testament",
                               "underscore", "pivotal", "meticulous", "boasts", "nestled", "game changer",
                               "deep dive"]

    private func words(_ title: String) -> Set<String> {
        Set(title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// A capital first letter and lower case after it, apart from names and abbreviations.
    private func isSentenceCase(_ title: String) -> Bool {
        let names: Set<Substring> = ["iPhone", "Photo", "RAW", "AE"]
        let words = title.split(separator: " ")
        guard let initial = words.first?.first, initial.isUppercase else { return false }
        return words.dropFirst().allSatisfy { names.contains($0) || $0 == $0.lowercased() }
    }

    func testTitlesAreShortSentenceCaseAndPlain() {
        let shared = AppearanceScheme.allCases.map(\.title) + AccentChoice.allCases.map(\.title)
            + HapticStrength.allCases.map(\.title) + ZoomTickStyle.allCases.map(\.title)
            + HardwareButtonAction.allCases.map(\.title)
        let simpleBar = TopBarItem.allCases.filter { !$0.isAdvancedOnly }.map { $0.title(advanced: false) }
        let advancedBar = TopBarItem.allCases.map { $0.title(advanced: true) }
        for title in shared + simpleBar + advancedBar {
            XCTAssertFalse(title.contains("\u{2014}"), title)
            XCTAssertTrue(isSentenceCase(title), title)
            XCTAssertLessThanOrEqual(title.count, 20, title)
            for banned in bannedWords {
                XCTAssertFalse(title.lowercased().contains(banned), "\(title): \(banned)")
            }
        }
        // Both interfaces show these, so no jargon.
        for title in shared + simpleBar {
            XCTAssertTrue(words(title).isDisjoint(with: jargon), title)
            XCTAssertFalse(title.lowercased().contains("f-number"), title)
        }
        // The checks see what they look for.
        XCTAssertFalse(words(TopBarItem.exposureLock.title(advanced: true)).isDisjoint(with: jargon))
        XCTAssertFalse(isSentenceCase("Zoom In"))
        XCTAssertFalse(isSentenceCase("zoom in"))
        XCTAssertTrue(isSentenceCase("Match iPhone"))
    }

    // MARK: - Both interfaces

    /// Everything this version added, read out of `settings`.
    private func preferences(_ settings: CameraSettings) -> [String] {
        let values: [Any] = [
            settings.appearance, settings.accessibility, settings.topBar, settings.startup,
            settings.controls.volumeUpAction, settings.controls.volumeDownAction, settings.controls.hapticStrength,
            settings.controls.dialTicks, settings.controls.zoomTicks, settings.display.dimDuringLongShots,
            settings.capture.prioritizeSpeed, settings.capture.artist, settings.capture.copyright,
            settings.video.allowAudioPlayback,
        ]
        return values.map { String(reflecting: $0) }
    }

    func testTheInterfaceSwitchLeavesThePreferencesAlone() {
        var settings = CameraSettings()
        settings.interface.advanced = true
        settings.mode = .manual
        settings.capture.rawFormat = .proRAW
        settings.appearance.scheme = .dark
        settings.appearance.accent = .orange
        settings.accessibility.largerLabels = true
        settings.accessibility.leftHanded = true
        settings.topBar = TopBarOptions(leading: [.histogram, .timer], trailing: [.raw])
        settings.startup.keepLensAndZoom = false
        settings.controls.volumeUpAction = .zoomIn
        settings.controls.volumeDownAction = .zoomOut
        settings.controls.hapticStrength = .strong
        settings.controls.dialTicks = false
        settings.controls.zoomTicks = .lensValues
        settings.display.dimDuringLongShots = true
        settings.capture.prioritizeSpeed = true
        settings.capture.artist = "Sam"
        settings.capture.copyright = "Sam 2026"
        settings.video.allowAudioPlayback = true
        let wanted = preferences(settings)

        // Going simple resets the advanced settings and keeps these, the advanced-only buttons in the bar's lists
        // included; twice changes nothing more.
        let simple = settings.simplified()
        XCTAssertEqual(simple.capture.rawFormat, .none)
        XCTAssertEqual(preferences(simple), wanted)
        XCTAssertEqual(simple.simplified(), simple)

        // Back to advanced: whatever the snapshot holds, or none, these stay as they are now.
        var other = CameraSettings()
        other.appearance.accent = .blue
        other.accessibility.speakStatus = true
        other.topBar = TopBarOptions(leading: [], trailing: [.level])
        other.startup.keepMode = false
        other.controls.volumeUpAction = .darker
        other.controls.hapticStrength = .light
        other.capture.artist = "Someone else"
        for snapshot in [other, settings, nil] {
            let restored = simple.restoringAdvanced(from: snapshot)
            XCTAssertEqual(preferences(restored), wanted)
            XCTAssertEqual(restored.restoringAdvanced(from: snapshot), restored)
        }
        XCTAssertEqual(simple.restoringAdvanced(from: settings), settings)
    }
}
