import SwiftUI
import UIKit

/// The look of the app: Apple's Camera palette (black, white, the accent), SF Pro, glass controls. What follows a
/// setting (the accent, Larger labels, Solid buttons, Reduce motion, Increase Contrast) comes from AppearanceStore,
/// so those members belong to the main actor, as every view that draws with them does, and a body that reads one
/// redraws when it changes.
enum Theme {
    /// The accent the person picked: Apple Camera's yellow unless changed. On the camera it is the bright shade, in
    /// a light sheet a deeper one.
    @MainActor static var accent: Color { AppearanceStore.shared.accent }
    /// Text and glyphs on an accent fill: black on the camera, white in light sheets.
    @MainActor static var onAccent: Color { AppearanceStore.shared.onAccent }
    static let recording = Color(red: 1.0, green: 0.231, blue: 0.188)
    /// Orange for a warning that is not an error: the steady sign while the phone moves, star trails past the
    /// sharp limit, a warm phone.
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let background = Color.black
    static let primaryText = Color.white
    @MainActor static var secondaryText: Color {
        AppearanceStore.shared.increaseContrast ? Palette.strongSecondaryText : Palette.secondaryText
    }
    @MainActor static var tertiaryText: Color {
        AppearanceStore.shared.increaseContrast ? Palette.strongTertiaryText : Palette.tertiaryText
    }
    @MainActor static var hairline: Color {
        AppearanceStore.shared.increaseContrast ? Palette.strongHairline : Palette.hairline
    }

    /// The round wells inside glass, behind the quick settings' glyphs.
    @MainActor static var raisedFill: Color {
        AppearanceStore.shared.increaseContrast ? Palette.strongRaisedFill : Palette.raisedFill
    }
    /// A faint track or an empty well: behind the lens buttons, the thumbnail before the first photo.
    static let trackFill = Color.white.opacity(0.08)
    /// A dark backing for a line of numbers over the picture, such as the night plan and the zoom readout. Glass takes
    /// its tone from the scene; this reads over a white sky and a black one alike. Darker where the person asked for
    /// more contrast or less transparency.
    @MainActor static var scrim: Color {
        let store = AppearanceStore.shared
        let strong = store.increaseContrast || store.reduceTransparency || store.solidControls
        return Color.black.opacity(strong ? 0.85 : 0.6)
    }
    /// The hairline round a scrim.
    static let scrimEdge = Color.white.opacity(0.15)

    /// How far a control fades when it can't be used.
    enum Dim {
        /// Does nothing here: not in this mode, not on this camera, or blocked by another setting.
        static let off = 0.35
        /// Waits for the running shot and comes back by itself. Its value stays readable.
        static let held = 0.45
    }

    /// The margin of every row of controls over the shutter, so their outer edges line up.
    static let edge: CGFloat = 12

    /// Letter spacing for spaced small capitals: the modes, the dial's title, short status words.
    static let smallCapsTracking: CGFloat = 1.2
    /// The width of an instrument's edge: the chips' rim, the thumbnail's, the active lens's ring.
    static let hairlineWidth: CGFloat = 0.5
    /// Tick marks drawn on the controls, as on a lens barrel: the long ones bright, the short ones quieter.
    static let majorTick = Color.white.opacity(0.95)
    static let minorTick = Color.white.opacity(0.5)

    /// Messages and titles: toasts, the modes, the night plan.
    @MainActor static var labelFont: Font { larger ? Fonts.largeLabel : Fonts.label }
    @MainActor static var modeFont: Font { labelFont }
    /// Small capitals and badges: the dial's title, the corner badges, the quick settings' item names.
    @MainActor static var microFont: Font { larger ? Fonts.largeMicro : Fonts.micro }
    /// The small A beside a value the camera picks. It grows with Larger labels so it stays level with the top of the
    /// digits it marks.
    @MainActor static var markFont: Font { Font.system(size: 7 * labelScale, weight: .bold) }
    /// Furniture coming and going in place: badges, the level, a status, the lens buttons on a flip.
    static let fade = Animation.easeInOut(duration: 0.2)
    @MainActor static var chipFont: Font { larger ? Fonts.largeChip : Fonts.chip }
    @MainActor static var valueFont: Font { larger ? Fonts.largeValue : Fonts.value }
    @MainActor static var bigValueFont: Font { larger ? Fonts.largeBigValue : Fonts.bigValue }
    static let countdownFont = Font.system(size: 120, weight: .thin).monospacedDigit()
    @MainActor static var readoutFont: Font { larger ? Fonts.largeReadout : Fonts.readout }
    /// How much bigger Larger labels makes camera text, for text sized outside these fonts.
    @MainActor static var labelScale: CGFloat { larger ? Fonts.largerScale : 1 }

    @MainActor private static var larger: Bool { AppearanceStore.shared.largerLabels }

    /// Gray text and hairlines on the camera's black and glass. Increase Contrast lifts each one.
    private enum Palette {
        static let secondaryText = Color.white.opacity(0.6)
        static let strongSecondaryText = Color.white.opacity(0.8)
        static let tertiaryText = Color.white.opacity(0.35)
        static let strongTertiaryText = Color.white.opacity(0.55)
        static let hairline = Color.white.opacity(0.18)
        static let strongHairline = Color.white.opacity(0.35)
        static let raisedFill = Color.white.opacity(0.12)
        static let strongRaisedFill = Color.white.opacity(0.2)
    }

    /// Camera labels have fixed sizes, because the system text size would push them out of their fixed-height rows.
    /// Larger labels makes each about a fifth bigger, which those rows still hold.
    private enum Fonts {
        static let largerScale: CGFloat = 1.2
        static let label = Font.system(size: 13, weight: .semibold).width(.standard)
        static let largeLabel = Font.system(size: 15.5, weight: .semibold).width(.standard)
        static let micro = Font.system(size: 10, weight: .semibold)
        static let largeMicro = Font.system(size: 12, weight: .semibold)
        static let chip = Font.system(size: 12, weight: .semibold).monospacedDigit()
        static let largeChip = Font.system(size: 14.5, weight: .semibold).monospacedDigit()
        static let value = Font.system(size: 15, weight: .semibold, design: .default).monospacedDigit()
        static let largeValue = Font.system(size: 18, weight: .semibold, design: .default).monospacedDigit()
        static let bigValue = Font.system(size: 20, weight: .semibold).monospacedDigit()
        static let largeBigValue = Font.system(size: 24, weight: .semibold).monospacedDigit()
        static let readout = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let largeReadout = Font.system(size: 13, weight: .medium).monospacedDigit()
    }

    /// The default spring for controls: quick, no visible bounce.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.9)

    /// A capture flying from the picture into the thumbnail: Theme.spring's pace, critically damped, so the copy
    /// settles into the square instead of overshooting its rim.
    static let flight = Animation.spring(response: 0.35, dampingFraction: 1)

    /// Every glass chip on the camera is this tall, with this much room either side of its text, so a row of chips
    /// from different controls reads as one instrument.
    static let chipHeight: CGFloat = 30
    static let chipPadding: CGFloat = 10

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
    /// Liquid Glass on iOS 26 and later, a material blur before that. Both read as the same control. With Solid
    /// buttons, a dark backing instead: over a white sky white text keeps 9.3:1 and the yellow 6.6:1 on it, where
    /// glass lets the sky through. It is also cheaper to draw.
    @MainActor
    @ViewBuilder
    func cameraGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if AppearanceStore.shared.solidControls {
            self.background {
                ZStack {
                    shape.fill(Color.black.opacity(0.72))
                    if let tint {
                        shape.fill(tint.opacity(0.3))
                    }
                }
            }
            .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
        } else {
            liquidGlass(in: shape, tint: tint, interactive: interactive)
        }
    }

    @ViewBuilder
    private func liquidGlass<S: Shape>(in shape: S, tint: Color?, interactive: Bool) -> some View {
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
/// right (-90) and upside down (180), where the phone only made a quarter turn. With Reduce motion, in the app or in
/// iOS, icons switch to the new angle instead of turning.
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
                // Read when the phone turns, not in the body, so the setting adds no redraws of its own.
                if AppearanceStore.shared.reduceMotion {
                    var still = Transaction(animation: nil)
                    still.disablesAnimations = true
                    withTransaction(still) { shown += delta }
                } else {
                    withAnimation(Theme.spring) { shown += delta }
                }
            }
    }
}

/// Round glass button, used beside the shutter and in the photo editor.
struct GlassCircleButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.controlSize
    var isActive = false
    /// A press that lands on a layer above the button, such as its touch and hold menu.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isPressed
        configuration.label
            // Medium: glass-backed glyphs carry one weight, a touch heavier than the bare ones on the picture.
            .font(.system(size: size * 0.42, weight: .medium))
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
            .padding(.horizontal, Theme.chipPadding)
            .frame(height: Theme.chipHeight)
            .cameraGlass(in: Capsule())
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(Theme.snappy, value: pressed)
            .contentShape(Capsule())
    }
}

/// Touch and hold for a control whose tap does something else: a tap runs `action`, a hold lists `options`. For a
/// control whose tap has nothing else to do but list its choices, MenuOnTapLayer.
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
            .buttonStyle(MenuLayerPressStyle(press: press))
            .menuIndicator(.hidden)
            // Rows read top to bottom in the order they are written, whichever way the menu opens.
            .menuOrder(.fixed)
        }
        .accessibilityHidden(true)
        // A layer that goes away under a finger never reports the lift.
        .onDisappear { press.isPressed = false }
    }
}

/// A tap lists a control's choices: a clear menu button laid over the control, as MenuOnHoldLayer is, so the
/// control's icon still turns with the phone and its value still rolls.
///
/// Build it inside a view of its own whose inputs compare equal between redraws (the model, an enum, the
/// PressTracker, strings), never straight in a body that reads the settings: its options closure never compares
/// equal, so the menu button would be rebuilt with every settings write, 120 a second while a dial turns. Unlike the
/// hold layer it is the control's VoiceOver element, carrying the control's label, value and hint, so a double tap
/// opens the same menu a tap does. Hide the control underneath from VoiceOver, before laying this over it.
struct MenuOnTapLayer<Options: View>: View {
    let press: PressTracker
    let label: String
    let value: String
    var hint: String = HoldMenuText.choicesHint
    @ViewBuilder let options: () -> Options

    var body: some View {
        // Sized to the control as the hold layer is.
        GeometryReader { proxy in
            Menu {
                options()
            } label: {
                Color.clear
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(MenuLayerPressStyle(press: press))
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
            // On the menu itself, as the scene button beside the shutter has them, so they land on the menu
            // button's own element.
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
        }
        .onDisappear { press.isPressed = false }
    }
}

/// Whether a finger is down on a control's menu layer, for the control's press feedback. A reference, so a press
/// redraws the control and leaves the layer, with the menu button in it, as it was.
@MainActor
@Observable
final class PressTracker {
    var isPressed = false
}

/// Draws nothing of its own; it tells the control underneath when to look pressed.
private struct MenuLayerPressStyle: ButtonStyle {
    let press: PressTracker

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, pressed in
                press.isPressed = pressed
            }
    }
}

extension View {
    /// Bare text and glyphs drawn on the picture: the shadow that keeps white apart from a white sky.
    func legibleShadow() -> some View {
        shadow(color: .black.opacity(0.5), radius: 3)
    }

    /// A faint bloom in the accent round whatever is active: the chosen mode, the lens in use, a lit bar glyph, the
    /// value an open dial turns. It sits beside legibleShadow, which still keeps the text apart from a white sky.
    /// The colour fades rather than the shadow coming and going, so the change animates and the view keeps its
    /// identity. Increase Contrast leaves it off: a crisp edge reads better there than a soft one.
    @MainActor
    func accentGlow(_ on: Bool) -> some View {
        let shown = on && !AppearanceStore.shared.increaseContrast
        return shadow(color: Theme.accent.opacity(shown ? 0.45 : 0), radius: 6)
    }

    /// Thin lines and ticks drawn on the picture.
    func lineShadow() -> some View {
        shadow(color: .black.opacity(0.4), radius: 1.5)
    }
}

/// The small accent dot that marks a message or a status as live, at its leading edge or under the active mode.
struct AccentDot: View {
    var size: CGFloat = 4

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A chip's rim: a hairline, so the chip reads as an instrument over any picture, and while its dial is open a
    /// short accent bar along the bottom. Solid buttons already draw a rim of their own.
    @MainActor
    func instrumentEdge(isActive: Bool) -> some View {
        overlay {
            if !AppearanceStore.shared.solidControls {
                Capsule().strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth)
            }
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Theme.accent)
                .frame(width: 12, height: 1.5)
                .padding(.bottom, 3)
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(true)
        }
    }
}

extension AnyTransition {
    /// Controls that change with the mode come into focus where they stand, a blur clearing as they fade in, and
    /// leave the same way, so a switch of modes reads as one change of focus instead of rows sliding about. With
    /// Reduce Transparency they only fade: the blur would soften the glass they sit on.
    @MainActor static var cameraFocus: AnyTransition {
        AppearanceStore.shared.reduceTransparency
            ? .opacity
            : .modifier(active: CameraFocus(isOut: true), identity: CameraFocus(isOut: false))
    }
}

private struct CameraFocus: ViewModifier {
    let isOut: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isOut ? 8 : 0)
            .opacity(isOut ? 0 : 1)
    }
}

/// The press look of a round control: a short shrink, as the flip button's.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}
