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

extension Image {
    /// The first of `names` this iOS has as a system symbol. A symbol newer than the phone's iOS draws nothing, so
    /// newer names come with older ones to fall back on.
    init(firstAvailableSystemName names: [String]) {
        let name = names.first(where: { UIImage(systemName: $0) != nil }) ?? names.last ?? "circle"
        self.init(systemName: name)
    }
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
    /// A press that lands on a layer above the button, such as its touch and hold menu.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isPressed
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .frame(width: size, height: size)
            .cameraGlass(in: Circle())
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(Theme.snappy, value: pressed)
            .contentShape(Circle())
    }
}

/// Capsule glass chip for values like "ISO 400" or "4:3".
struct GlassChipButtonStyle: ButtonStyle {
    var isActive = false
    /// A press that lands on a layer above the chip, such as its touch and hold menu.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isPressed
        configuration.label
            .font(Theme.chipFont)
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .cameraGlass(in: Capsule())
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(Theme.snappy, value: pressed)
            .contentShape(Capsule())
    }
}

/// Touch and hold for a control whose tap does something else: a tap runs `action`, a hold lists `options`.
///
/// A clear button to lay over the control, which stays the ordinary view it was: its icon still turns with the
/// phone, its value still rolls, and VoiceOver reads it with its own label, value and actions. Give the layer a
/// view of its own whose inputs never change, and the control's redraws never reach the system's menu button.
/// The control underneath keeps a tap of its own that does the same as `action`: only the top view gets a touch,
/// so the two never both run, and a layer that failed to take touches would cost the menu and not the control.
struct MenuOnHoldLayer<Options: View>: View {
    let press: PressTracker
    let action: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        // A clear colour has no size of its own. The label gets the control's, so a menu button that sizes itself
        // to its label's ideal size still covers the whole control.
        GeometryReader { proxy in
            Menu {
                options()
            } label: {
                Color.clear
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
            } primaryAction: {
                action()
            }
            .menuStyle(.button)
            .buttonStyle(MenuOnHoldPressStyle(press: press))
            .menuIndicator(.hidden)
            // Rows read top to bottom in the order they are written, whichever way the menu opens.
            .menuOrder(.fixed)
        }
        .accessibilityHidden(true)
        // A layer that goes away under a finger never reports the lift.
        .onDisappear { press.isPressed = false }
    }
}

/// Whether a finger is down on a control's touch and hold layer, for the control's press feedback. A reference, so
/// a press redraws the control and leaves the layer, with the menu button in it, as it was.
@MainActor
@Observable
final class PressTracker {
    var isPressed = false
}

/// Draws nothing of its own; it tells the control underneath when to look pressed.
private struct MenuOnHoldPressStyle: ButtonStyle {
    let press: PressTracker

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, pressed in
                press.isPressed = pressed
            }
    }
}
