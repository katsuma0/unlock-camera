import SwiftUI
import UIKit

/// The look of the app: Apple's Camera palette (black, white, system yellow), SF Pro, glass controls.
enum Theme {
    /// iOS Camera's yellow (systemYellow in dark mode).
    static let accent = Color(red: 1.0, green: 0.839, blue: 0.039)
    static let recording = Color(red: 1.0, green: 0.231, blue: 0.188)
    static let background = Color.black
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.6)
    static let tertiaryText = Color.white.opacity(0.35)
    /// Darkens the parts of the sensor outside the chosen aspect ratio.
    static let maskDim = Color.black.opacity(0.55)
    static let hairline = Color.white.opacity(0.18)

    static let modeFont = Font.system(size: 13, weight: .semibold).width(.standard)
    static let chipFont = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let valueFont = Font.system(size: 15, weight: .semibold, design: .default).monospacedDigit()
    static let bigValueFont = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let countdownFont = Font.system(size: 120, weight: .thin).monospacedDigit()
    static let readoutFont = Font.system(size: 11, weight: .medium).monospacedDigit()

    /// The default spring for controls: quick, no visible bounce.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.9)

    static let shutterSize: CGFloat = 76
    static let controlSize: CGFloat = 38
    static let smallControlSize: CGFloat = 30
}

extension View {
    /// Liquid Glass on iOS 26 and later, a material blur before that. Both read as the same control.
    @ViewBuilder
    func cameraGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .environment(\.colorScheme, .dark)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .environment(\.colorScheme, .dark)
        #endif
    }

    /// Keeps icons and labels upright when the phone turns, like the Camera app, while the layout stays portrait.
    func uprightRotation(_ degrees: Double) -> some View {
        modifier(UprightRotation(degrees: degrees))
    }
}

/// Turns to each new angle the short way. Animating the raw angles would spin icons 270 degrees between landscape
/// right (-90) and upside down (180), where the phone only made a quarter turn.
private struct UprightRotation: ViewModifier {
    let degrees: Double
    /// The angle on screen. It may leave -180...180 after a few turns; only the change between angles matters.
    @State private var shown: Double

    init(degrees: Double) {
        self.degrees = degrees
        // Starts at the current angle, so a view that appears while the phone is turned doesn't spin into place.
        _shown = State(initialValue: degrees)
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(shown))
            .onChange(of: degrees) { _, target in
                var delta = (target - shown).truncatingRemainder(dividingBy: 360)
                if delta > 180 {
                    delta -= 360
                } else if delta <= -180 {
                    delta += 360
                }
                withAnimation(Theme.spring) { shown += delta }
            }
    }
}

/// Round glass button used across the top bar and beside the shutter.
struct GlassCircleButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.controlSize
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .frame(width: size, height: size)
            .cameraGlass(in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Capsule glass chip for values like "ISO 400" or "4:3".
struct GlassChipButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chipFont)
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .cameraGlass(in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
