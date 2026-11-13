import Foundation

// How the app looks and handles, as opposed to how it takes pictures: the look of Settings, accessibility, the top
// bar's buttons, what the hardware buttons do, how haptics feel and what the camera opens on. Both interfaces share
// all of it (none of it is in copyAdvancedFields), so switching between simple and advanced never moves a button or
// changes a color.

// MARK: - Appearance

/// Light or dark for Settings and the lists it leads to. The camera stays dark either way.
public enum AppearanceScheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return "Match iPhone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The color that marks what is on or set by hand. Red is left out because it means recording and warnings, white
/// and gray because they would read as automatic, and indigo because no shade of it stays readable on the camera's
/// dark glass.
public enum AccentChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case yellow, orange, green, teal, blue, purple, pink

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// On black, on the camera's glass and in dark sheets. Each stays readable as small text on the lightest dark
    /// backing (#2C2C2E), and black text on it stays readable too, so text on an accent fill is black on the camera.
    /// Yellow is Apple Camera's, the color the app has always used. Blue, purple and pink are Apple's high contrast
    /// shades: the standard ones fall short on dark glass.
    public var camera: RGBA8 {
        switch self {
        case .yellow: return RGBA8(r: 0xFF, g: 0xD6, b: 0x0A)
        case .orange: return RGBA8(r: 0xFF, g: 0x9F, b: 0x0A)
        case .green: return RGBA8(r: 0x30, g: 0xD1, b: 0x58)
        case .teal: return RGBA8(r: 0x40, g: 0xC8, b: 0xE0)
        case .blue: return RGBA8(r: 0x40, g: 0x9C, b: 0xFF)
        case .purple: return RGBA8(r: 0xDA, g: 0x8F, b: 0xFF)
        case .pink: return RGBA8(r: 0xFF, g: 0x64, b: 0x82)
        }
    }

    /// In light sheets, where the camera shades wash out: readable on white cells and on the grouped gray
    /// background, with white text on its fills.
    public var lightSheet: RGBA8 {
        switch self {
        case .yellow: return RGBA8(r: 0x94, g: 0x6F, b: 0x00)
        case .orange: return RGBA8(r: 0xB3, g: 0x53, b: 0x00)
        case .green: return RGBA8(r: 0x1E, g: 0x7E, b: 0x34)
        case .teal: return RGBA8(r: 0x00, g: 0x7A, b: 0x8F)
        case .blue: return RGBA8(r: 0x00, g: 0x40, b: 0xDD)
        case .purple: return RGBA8(r: 0x89, g: 0x44, b: 0xAB)
        case .pink: return RGBA8(r: 0xD3, g: 0x0F, b: 0x45)
        }
    }
}

public struct AppearanceOptions: Codable, Hashable, Sendable {
    public var scheme: AppearanceScheme = .system
    public var accent: AccentChoice = .yellow

    public init() {}

    enum CodingKeys: String, CodingKey { case scheme, accent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceOptions()
        scheme = c.value(.scheme, default: d.scheme)
        accent = c.value(.accent, default: d.accent)
    }
}

// MARK: - Accessibility

/// Small options that make the camera easier to see, reach and follow. The system's Bold Text, Reduce Transparency
/// and VoiceOver apply without any of them.
public struct AccessibilityOptions: Codable, Hashable, Sendable {
    /// Text on the camera screen about a fifth bigger. Camera labels have fixed sizes, so the system text size
    /// doesn't reach them.
    public var largerLabels: Bool = false
    /// Camera buttons on a dark backing instead of glass, so they stay readable over a bright scene.
    public var solidControls: Bool = false
    /// Icons switch instead of turning and panels fade instead of sliding. The system's Reduce Motion does the same
    /// whatever this says.
    public var reduceMotion: Bool = false
    /// The flip button on the left and the thumbnail on the right, the brightness control left of the lenses.
    public var leftHanded: Bool = false
    /// Says the countdown out loud, and when a long shot starts and ends.
    public var speakStatus: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey { case largerLabels, solidControls, reduceMotion, leftHanded, speakStatus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AccessibilityOptions()
        largerLabels = c.value(.largerLabels, default: d.largerLabels)
        solidControls = c.value(.solidControls, default: d.solidControls)
        reduceMotion = c.value(.reduceMotion, default: d.reduceMotion)
        leftHanded = c.value(.leftHanded, default: d.leftHanded)
        speakStatus = c.value(.speakStatus, default: d.speakStatus)
    }
}

// MARK: - Buttons and haptics

/// How firm the taps feel. Haptics off stays the `haptics` switch, so a save from before means the same.
public enum HapticStrength: String, Codable, Sendable, CaseIterable, Identifiable {
    case light, normal, strong

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .light: return "Light"
        case .normal: return "Normal"
        case .strong: return "Strong"
        }
    }
}

/// Where turning the zoom ticks under the finger.
public enum ZoomTickStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case everyStep, lensValues

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .everyStep: return "Every step"
        case .lensValues: return "Lens values only"
        }
    }
}

/// What a volume button does in the camera. During a timer, a long exposure, an intervalometer or a bracket, any
/// button stops the shot whatever it is set to, so a shot can always be ended without touching the phone.
public enum HardwareButtonAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case shutter, zoomIn, zoomOut, brighter, darker, nextLens

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .shutter: return "Shutter"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .brighter: return "Brighter"
        case .darker: return "Darker"
        case .nextLens: return "Next lens"
        }
    }
}

// MARK: - Top bar

/// A button the top bar can carry beside the chevron, picked and ordered in Settings.
public enum TopBarItem: String, Codable, Sendable, CaseIterable, Identifiable {
    case flash, livePhoto, timer, aspect, grid, level, location, quietShutter, batterySaver, nightDuration
    case raw, exposureLock, format, resolution, processing, histogram, zebras, peaking, falseColor
    case whiteBalance, stabilization, sound

    public var id: String { rawValue }

    /// Sets something the simple interface keeps on automatic or doesn't show.
    public var isAdvancedOnly: Bool {
        switch self {
        case .flash, .livePhoto, .timer, .aspect, .grid, .level, .location, .quietShutter, .batterySaver,
             .nightDuration:
            return false
        case .raw, .exposureLock, .format, .resolution, .processing, .histogram, .zebras, .peaking, .falseColor,
             .whiteBalance, .stabilization, .sound:
            return true
        }
    }

    /// The modes where it has something to do. What depends on the camera or on other settings at the moment
    /// (a flash on this lens, Live Photo support, a bulb shot) is for the app's `isAvailable` to say.
    public func applies(in mode: CaptureMode) -> Bool {
        switch self {
        case .flash:
            // In VIDEO it works the flashlight.
            return mode == .photo || mode == .manual || mode == .video
        case .livePhoto:
            return mode == .photo
        case .quietShutter, .raw, .resolution, .processing:
            return mode == .photo || mode == .manual
        case .timer, .aspect, .format:
            return mode != .video
        case .batterySaver:
            return mode == .night || mode == .long
        case .nightDuration:
            return mode == .night
        case .stabilization, .sound:
            return mode == .video
        case .grid, .level, .location, .exposureLock, .histogram, .zebras, .peaking, .falseColor, .whiteBalance:
            return true
        }
    }

    /// Its name in Settings and for VoiceOver. Where the interfaces word a setting differently, each keeps its own,
    /// and the simple one's words carry no camera jargon. An advanced-only button has the one name.
    public func title(advanced: Bool) -> String {
        switch self {
        case .flash: return "Flash"
        case .livePhoto: return "Live Photo"
        case .timer: return "Timer"
        case .aspect: return "Aspect ratio"
        case .grid: return "Grid"
        case .level: return "Level"
        case .location: return "Location tags"
        case .quietShutter: return advanced ? "Silent shutter" : "Quiet shutter"
        case .batterySaver: return "Battery saver"
        case .nightDuration: return advanced ? "Night duration" : "Night time"
        case .raw: return "RAW"
        case .exposureLock: return "AE lock"
        case .format: return "Format"
        case .resolution: return "Resolution"
        case .processing: return "Processing"
        case .histogram: return "Histogram"
        case .zebras: return "Zebras"
        case .peaking: return "Focus peaking"
        case .falseColor: return "False color"
        case .whiteBalance: return "White balance"
        case .stabilization: return "Stabilization"
        case .sound: return "Sound"
        }
    }

    /// SF Symbols for the button where it is listed, newest first: a name newer than the phone's iOS draws nothing,
    /// so the next one stands in. On the bar, a button that shows its state draws that instead (bolt.slash, "16:9",
    /// the zebra stripes SF Symbols doesn't have).
    public var symbolNames: [String] {
        switch self {
        case .flash: return ["bolt"]
        case .livePhoto: return ["livephoto"]
        case .timer: return ["timer"]
        case .aspect: return ["aspectratio", "rectangle"]
        case .grid: return ["square.grid.3x3", "grid"]
        case .level: return ["level"]
        case .location: return ["location"]
        case .quietShutter: return ["speaker.slash"]
        case .batterySaver: return ["moon.zzz", "battery.100percent", "battery.100"]
        case .nightDuration: return ["moon.fill"]
        case .raw: return ["r.square"]
        case .exposureLock: return ["lock"]
        case .format: return ["photo"]
        case .resolution: return ["arrow.up.left.and.arrow.down.right"]
        case .processing: return ["wand.and.stars"]
        case .histogram: return ["chart.bar.fill"]
        case .zebras: return ["line.diagonal"]
        case .peaking: return ["scope"]
        case .falseColor: return ["paintpalette"]
        case .whiteBalance: return ["thermometer.sun", "sun.max"]
        case .stabilization: return ["figure.walk"]
        case .sound: return ["mic"]
        }
    }
}

/// The top bar's own buttons. The bar has seven equal slots on every iPhone: three for the left side, the chevron,
/// two for the right side and the gear. Fixed slots keep each button where the thumb expects it, the same from phone
/// to phone, and never let the bar crowd.
public struct TopBarOptions: Codable, Hashable, Sendable {
    /// Slots left of the chevron.
    public static let leadingRoom = 3
    /// Slots between the chevron and the gear.
    public static let trailingRoom = 2
    /// The most a side keeps. A side may hold more than its room: buttons that only the advanced interface or
    /// another mode shows wait their turn in the list. Capped all the same, so a damaged save can't grow without end.
    public static let storedLimit = 8

    /// Left of the chevron, the first nearest the edge.
    public var leading: [TopBarItem] = [.flash]
    /// Between the chevron and the gear. With Flash on the left, the bar as it was before it could be changed.
    public var trailing: [TopBarItem] = [.raw, .livePhoto]

    public init() {}

    /// The sides as given, cleaned as a save is: each button once, on the side where it comes first (the left
    /// counts first), at most `storedLimit` a side.
    public init(leading: [TopBarItem], trailing: [TopBarItem]) {
        (self.leading, self.trailing) = Self.cleaned(leading, trailing)
    }

    enum CodingKeys: String, CodingKey { case leading, trailing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TopBarOptions()
        (leading, trailing) = Self.cleaned(Self.items(c, .leading) ?? d.leading, Self.items(c, .trailing) ?? d.trailing)
    }

    /// One saved side, read by name: a button from a later version, or renamed since, drops out alone instead of
    /// costing the whole side. nil when the side is missing or isn't a list, which leaves it at its default.
    private static func items(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [TopBarItem]? {
        guard let names = try? c.decodeIfPresent([StoredName].self, forKey: key) else { return nil }
        return names.compactMap(\.item)
    }

    private static func cleaned(_ leading: [TopBarItem], _ trailing: [TopBarItem]) -> ([TopBarItem], [TopBarItem]) {
        var placed = Set<TopBarItem>()
        var sides: [[TopBarItem]] = []
        for items in [leading, trailing] {
            var kept: [TopBarItem] = []
            for item in items where kept.count < storedLimit && placed.insert(item).inserted {
                kept.append(item)
            }
            sides.append(kept)
        }
        return (sides[0], sides[1])
    }

    /// What the bar shows: on each side, the first buttons that work at this level, in this mode and on this
    /// camera, as many as the side has room for. One that doesn't work steps aside and the next moves up, so the
    /// bar never shows a dead button or a gap.
    /// - Parameters:
    ///   - leadingRoom: Left slots free of furniture; `layout` works out both rooms.
    ///   - trailingRoom: Right slots free of furniture.
    ///   - isAvailable: What only the app knows: a flash on this camera, Live Photo support, a bulb shot.
    public func shown(advanced: Bool, mode: CaptureMode, leadingRoom: Int = TopBarOptions.leadingRoom,
                      trailingRoom: Int = TopBarOptions.trailingRoom,
                      isAvailable: (TopBarItem) -> Bool) -> (leading: [TopBarItem], trailing: [TopBarItem]) {
        var placed = Set<TopBarItem>()
        var sides: [[TopBarItem]] = []
        for (items, room) in [(leading, leadingRoom), (trailing, trailingRoom)] {
            var picked: [TopBarItem] = []
            // A button can be on both sides when the lists were changed directly; it shows once.
            for item in items where picked.count < room {
                guard advanced || !item.isAdvancedOnly, item.applies(in: mode), !placed.contains(item),
                      isAvailable(item) else { continue }
                placed.insert(item)
                picked.append(item)
            }
            sides.append(picked)
        }
        return (sides[0], sides[1])
    }

    /// The bar in `mode` with its furniture in place. In VIDEO the format chip takes the right side. When a timer,
    /// intervalometer or bracket is set, its badge takes the last left slot, unless a Timer button on the bar
    /// already shows it: the button then stands in for the badge.
    /// - Parameters:
    ///   - wantsBadge: A timer, intervalometer or bracket is set and the badge belongs in this mode.
    ///   - isAvailable: As for `shown`.
    public func layout(advanced: Bool, mode: CaptureMode, wantsBadge: Bool,
                       isAvailable: (TopBarItem) -> Bool) -> TopBarLayout {
        let trailingRoom = mode == .video ? 0 : Self.trailingRoom
        let full = shown(advanced: advanced, mode: mode, trailingRoom: trailingRoom, isAvailable: isAvailable)
        guard wantsBadge, !full.leading.contains(.timer), !full.trailing.contains(.timer) else {
            return TopBarLayout(leading: full.leading, trailing: full.trailing, showsBadge: false)
        }
        let rest = shown(advanced: advanced, mode: mode, leadingRoom: Self.leadingRoom - 1, trailingRoom: trailingRoom,
                         isAvailable: isAvailable)
        return TopBarLayout(leading: rest.leading, trailing: rest.trailing, showsBadge: true)
    }
}

/// The top bar's buttons as placed in one mode.
public struct TopBarLayout: Equatable, Sendable {
    public var leading: [TopBarItem]
    public var trailing: [TopBarItem]
    /// The timer badge holds one of the left slots, so `leading` has a slot fewer.
    public var showsBadge: Bool
}

/// One entry of a saved list of buttons: the button, or nil for anything this version can't read.
private struct StoredName: Decodable {
    let item: TopBarItem?

    init(from decoder: Decoder) throws {
        item = (try? decoder.singleValueContainer().decode(String.self)).flatMap(TopBarItem.init(rawValue:))
    }
}

// MARK: - Startup

/// What the camera keeps from last time when it opens. All on is how it has always worked; each one off starts its
/// part where a fresh install does: PHOTO, the main lens at 1x, brightness at zero.
public struct StartupOptions: Codable, Hashable, Sendable {
    /// Opens in the mode it was left in.
    public var keepMode: Bool = true
    /// Opens on the lens and zoom it was left on.
    public var keepLensAndZoom: Bool = true
    /// Keeps the brightness it was left at, NIGHT's included.
    public var keepBrightness: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case keepMode, keepLensAndZoom, keepBrightness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StartupOptions()
        keepMode = c.value(.keepMode, default: d.keepMode)
        keepLensAndZoom = c.value(.keepLensAndZoom, default: d.keepLensAndZoom)
        keepBrightness = c.value(.keepBrightness, default: d.keepBrightness)
    }
}

extension CameraSettings {
    /// These settings as the camera opens with them: what the startup options don't keep goes back to where a fresh
    /// install starts.
    public func applyingStartupOptions() -> CameraSettings {
        var settings = self
        let fresh = CameraSettings.default
        if !startup.keepMode {
            settings.mode = fresh.mode
        }
        if !startup.keepLensAndZoom {
            settings.lensID = fresh.lensID
            settings.zoom = fresh.zoom
        }
        if !startup.keepBrightness {
            settings.manual.bias = fresh.manual.bias
            settings.night.biasEV = fresh.night.biasEV
        }
        return settings
    }
}
