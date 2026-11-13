import SwiftUI
import CameraCore

/// Touch and hold for a control whose tap does something else: a tap runs `action`, a hold lists the choices.
///
/// Laid over the control as a clear button, with the face an ordinary view underneath. A face that redraws many
/// times a second (a chip showing a live reading) then never rebuilds the system's menu button, and VoiceOver
/// reads the face, with its own label, value and actions, instead of this layer.
struct HoldMenuLayer<Options: View>: View {
    /// True while a finger is down on the layer, for the face's press feedback.
    @Binding var isPressed: Bool
    let action: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        Menu {
            options()
        } label: {
            Color.clear
                .contentShape(Rectangle())
        } primaryAction: {
            action()
        }
        .menuStyle(.button)
        .buttonStyle(HoldMenuPressStyle(isPressed: $isPressed))
        .menuIndicator(.hidden)
        // Values run top to bottom the way their dial runs left to right, whichever way the menu opens.
        .menuOrder(.fixed)
        .accessibilityHidden(true)
    }
}

/// Draws nothing of its own; it only tells the face underneath when to look pressed.
private struct HoldMenuPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

/// One row of a menu of choices. The current choice carries the checkmark.
struct HoldMenuChoice: View {
    let title: String
    var icon: Image? = nil
    let isOn: Bool
    let action: () -> Void

    init(_ title: String, icon: Image? = nil, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        // A toggle is what a menu draws with a checkmark. Picking the checked row again picks it again.
        Toggle(isOn: Binding(get: { isOn }, set: { _ in choose() })) {
            if let icon {
                Label {
                    Text(title)
                } icon: {
                    icon
                }
            } else {
                Text(title)
            }
        }
    }

    private func choose() {
        Haptics.tick()
        action()
    }
}

/// Words for menu rows, which have room for a unit a chip leaves out.
enum HoldMenuText {
    /// The hint every control with a touch and hold menu adds to what its tap does.
    static let hint = "Touch and hold for more options."

    /// "1/250", "4 s", "5 min".
    static func time(_ seconds: Double) -> String {
        let speed = ShutterSpeed(seconds: seconds)
        if speed.isFraction { return speed.label }
        // The values on offer are whole seconds and whole minutes; anything else falls back to the dial's label.
        guard seconds.isFinite, seconds < 86_400, seconds == seconds.rounded() else { return speed.label }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole) s" }
        return whole % 60 == 0 ? "\(whole / 60) min" : speed.label
    }

    /// "1 second", "30 seconds", "5 minutes": for VoiceOver, which would read "5m" as metres.
    static func spokenTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 1, seconds < 86_400, seconds == seconds.rounded() else {
            return ShutterSpeed(seconds: seconds).label
        }
        let whole = Int(seconds)
        if whole < 60 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        guard whole % 60 == 0 else { return "\(whole / 60) minutes \(whole % 60) seconds" }
        return whole == 60 ? "1 minute" : "\(whole / 60) minutes"
    }
}
