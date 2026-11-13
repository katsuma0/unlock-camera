import SwiftUI
import CameraCore

/// The look the person picked in Settings: the accent, the sheets' light or dark, and the accessibility options the
/// camera draws differently. The model copies the settings in; views read it through Theme. Stub: the settings
/// builder fills it in.
@MainActor
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    private(set) var accent = Color(red: 1.0, green: 0.839, blue: 0.039)
    /// Text and glyphs on an accent fill.
    private(set) var onAccent = Color.black
    /// nil follows the phone.
    private(set) var sheetScheme: ColorScheme? = .dark
    private(set) var largerLabels = false
    private(set) var solidControls = false
    private(set) var reduceMotion = false
    private(set) var leftHanded = false
    private(set) var speakStatus = false

    func update(appearance: AppearanceOptions, accessibility: AccessibilityOptions) {}
}

extension View {
    /// The look of a sheet or page that follows the appearance setting. The camera itself stays dark.
    func sheetAppearance() -> some View {
        preferredColorScheme(.dark)
            .tint(Theme.accent)
    }
}
