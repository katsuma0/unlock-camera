import UIKit
import CameraCore

/// Haptics shared by every control. Generators are kept warm so the first tick isn't late.
@MainActor
enum Haptics {
    static var isEnabled = true
    /// How firm every tap feels, from Settings.
    static var strength: HapticStrength = .normal
    /// The selection ticks of dials, the mode carousel, menu choices and the level. Off leaves taps and stops.
    static var dialTicks = true
    /// Where the zoom wheel ticks as it turns (zoomTick(atLensValue:)).
    static var zoomTicks: ZoomTickStyle = .everyStep
    /// Held by the model while a stack runs and during a settle countdown: a tap of the Taptic Engine shakes a phone
    /// on a tripod, and the shake ends up in the picture.
    static var isSuppressed = false

    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    private static var canPlay: Bool { isEnabled && !isSuppressed }

    static func prepare() {
        selection.prepare()
        medium.prepare()
    }

    /// One detent of a dial.
    static func tick() {
        guard dialTicks else { return }
        detent()
    }

    /// One step of the zoom wheel. A lens value always lands with a tap; the steps between tick only when
    /// Settings asks for every step.
    static func zoomTick(atLensValue: Bool) {
        if atLensValue {
            tap()
        } else if zoomTicks == .everyStep {
            detent()
        }
    }

    static func tap() {
        guard canPlay else { return }
        switch strength {
        case .light: light.impactOccurred(intensity: 0.5)
        case .normal: light.impactOccurred()
        case .strong: medium.impactOccurred()
        }
    }

    static func shutter() {
        guard canPlay else { return }
        switch strength {
        case .light: medium.impactOccurred(intensity: 0.5)
        case .normal: medium.impactOccurred(intensity: 0.9)
        case .strong: heavy.impactOccurred(intensity: 1)
        }
        medium.prepare()
    }

    /// End stops and snaps, e.g. a dial hitting its last value.
    static func stop() {
        guard canPlay else { return }
        switch strength {
        case .light: rigid.impactOccurred(intensity: 0.4)
        case .normal: rigid.impactOccurred(intensity: 0.7)
        case .strong: rigid.impactOccurred(intensity: 1)
        }
    }

    // Notifications have no intensity to scale, so every strength plays them the same.

    static func success() {
        guard canPlay else { return }
        notification.notificationOccurred(.success)
    }

    static func warning() {
        guard canPlay else { return }
        notification.notificationOccurred(.warning)
    }

    /// The selection feel has no strength of its own, so the light and strong settings use impacts in its place.
    private static func detent() {
        guard canPlay else { return }
        switch strength {
        case .light: light.impactOccurred(intensity: 0.45)
        case .normal:
            selection.selectionChanged()
            selection.prepare()
        case .strong: rigid.impactOccurred(intensity: 0.85)
        }
    }
}
