import SwiftUI
import UIKit
import CameraCore

/// The look the person picked in Settings, the accessibility options the camera draws differently, and the system
/// settings that go with them. The model copies the settings in through `update`; views read it through Theme, so
/// every body that draws with the accent redraws when it changes, the camera behind the Settings sheet included.
///
/// Each property is written only when its value really changes: Observation notifies on every write, and the accent
/// alone has dozens of readers that would otherwise redraw with each settings change.
@MainActor
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    /// The accent as one dynamic color: the camera shade on black, on glass and in dark sheets, and a deeper shade in
    /// light sheets, where the camera shade washes out.
    private(set) var accent: Color
    /// Text and glyphs on an accent fill. Black reads on every camera shade and white on every light-sheet shade, so
    /// this depends on light or dark alone: black on the camera and in dark sheets, white in light sheets.
    let onAccent = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .light ? .white : .black })
    /// Light or dark for Settings and the lists it leads to. Always set: Match iPhone resolves to the phone's own
    /// look, because the app holds itself dark and a sheet that asked for nothing would come out dark too.
    private(set) var sheetScheme: ColorScheme? = .dark
    private(set) var largerLabels = false
    private(set) var solidControls = false
    /// The in-app switch or the system's Reduce Motion: either one keeps the camera still.
    private(set) var reduceMotion: Bool
    private(set) var leftHanded = false
    private(set) var speakStatus = false
    /// The system's Increase Contrast. The camera draws its own gray text and hairlines, which the system can't
    /// strengthen by itself.
    private(set) var increaseContrast: Bool
    /// The system's Reduce Motion on its own, for the Settings page that explains the in-app switch.
    private(set) var systemReducesMotion: Bool

    @ObservationIgnored private var appearance = AppearanceOptions()
    @ObservationIgnored private var accessibility = AccessibilityOptions()
    @ObservationIgnored private var accentChoice = AccentChoice.yellow
    /// The phone's look is read through UIApplication, which exists only once the app runs. The store can be made
    /// before that, with the model the app builds at launch.
    @ObservationIgnored private var canAskPhone = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        accent = AccentPalette.color(.yellow)
        let systemReduce = UIAccessibility.isReduceMotionEnabled
        systemReducesMotion = systemReduce
        reduceMotion = systemReduce
        increaseContrast = UIAccessibility.isDarkerSystemColorsEnabled
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        })
        observers.append(center.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        })
        // Switching light or dark in Control Center makes the app inactive and active again, so this catches it
        // before any sheet opens. A switch at sunset while the app stays in front is caught by the next sheet.
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemScheme() }
        })
        // The main queue first runs once the app does, so by then the phone can be asked.
        Task { [weak self] in
            self?.refreshSystemScheme()
        }
    }

    /// Takes the settings as they are now. The model calls it at launch and after every settings change.
    func update(appearance: AppearanceOptions, accessibility: AccessibilityOptions) {
        self.appearance = appearance
        self.accessibility = accessibility
        apply()
    }

    /// Reads the phone's light or dark again, for Match iPhone. Sheets call it as they appear.
    func refreshSystemScheme() {
        canAskPhone = true
        apply()
    }

    private func apply() {
        if accentChoice != appearance.accent {
            accentChoice = appearance.accent
            accent = AccentPalette.color(appearance.accent)
        }
        let scheme = resolvedScheme()
        if sheetScheme != scheme { sheetScheme = scheme }
        let systemReduce = UIAccessibility.isReduceMotionEnabled
        if systemReducesMotion != systemReduce { systemReducesMotion = systemReduce }
        let reduce = accessibility.reduceMotion || systemReduce
        if reduceMotion != reduce { reduceMotion = reduce }
        let contrast = UIAccessibility.isDarkerSystemColorsEnabled
        if increaseContrast != contrast { increaseContrast = contrast }
        if largerLabels != accessibility.largerLabels { largerLabels = accessibility.largerLabels }
        if solidControls != accessibility.solidControls { solidControls = accessibility.solidControls }
        if leftHanded != accessibility.leftHanded { leftHanded = accessibility.leftHanded }
        if speakStatus != accessibility.speakStatus { speakStatus = accessibility.speakStatus }
    }

    /// Match iPhone keeps the last known look while the phone can't be asked, which before the app runs is the
    /// dark it has always had.
    private func resolvedScheme() -> ColorScheme? {
        switch appearance.scheme {
        case .light: return .light
        case .dark: return .dark
        case .system: return (canAskPhone ? Self.phoneScheme() : nil) ?? sheetScheme ?? .dark
        }
    }

    /// The phone's own light or dark. The app is held dark by its Info.plist and its window root, and every window
    /// and view inherits that, so the style is read from the screen, which sits outside those overrides.
    private static func phoneScheme() -> ColorScheme? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        switch scene.screen.traitCollection.userInterfaceStyle {
        case .light: return .light
        case .dark: return .dark
        default: return nil
        }
    }
}

/// One dynamic color per accent choice, made once, so reading the accent never builds a color.
@MainActor
private enum AccentPalette {
    private static let colors: [AccentChoice: Color] = Dictionary(
        uniqueKeysWithValues: AccentChoice.allCases.map { ($0, make($0)) }
    )

    static func color(_ choice: AccentChoice) -> Color {
        colors[choice] ?? make(choice)
    }

    private static func make(_ choice: AccentChoice) -> Color {
        let camera = uiColor(choice.camera)
        let lightSheet = uiColor(choice.lightSheet)
        return Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .light ? lightSheet : camera })
    }

    private static func uiColor(_ rgba: RGBA8) -> UIColor {
        UIColor(red: CGFloat(rgba.r) / 255, green: CGFloat(rgba.g) / 255, blue: CGFloat(rgba.b) / 255,
                alpha: CGFloat(rgba.a) / 255)
    }
}

extension AppearanceStore {
    /// An accent choice as the accent color would draw it, for the swatches that pick one.
    static func color(for choice: AccentChoice) -> Color {
        AccentPalette.color(choice)
    }
}

extension View {
    /// The look of a sheet or page that follows the appearance setting: light or dark as picked, tinted with the
    /// accent's shade for that look. It sets the nearest presentation only, so the camera stays dark.
    @MainActor
    func sheetAppearance() -> some View {
        modifier(SheetAppearance())
    }
}

private struct SheetAppearance: ViewModifier {
    func body(content: Content) -> some View {
        let store = AppearanceStore.shared
        content
            .tint(store.accent)
            .preferredColorScheme(store.sheetScheme)
            .onAppear { store.refreshSystemScheme() }
    }
}

/// Switches in Settings are the system's green, as in iOS Settings, so the accent marks only values, buttons and
/// sliders instead of every row of the form.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .tint(.green)
    }
}
