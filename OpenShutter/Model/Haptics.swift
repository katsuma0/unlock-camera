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
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    /// When the steady sign last said the phone was still, so a hand that keeps settling isn't tapped every second.
    private static var lastSettle: Date?
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

    /// A lens figure coming to rest at the end of its glide: softer than the press's tap that started it.
    static func land() {
        guard canPlay else { return }
        switch strength {
        case .light: soft.impactOccurred(intensity: 0.4)
        case .normal: soft.impactOccurred(intensity: 0.65)
        case .strong: soft.impactOccurred(intensity: 0.95)
        }
    }

    /// The steady sign's wave lying flat and green: the phone is still enough to shoot. At most once every few
    /// seconds, since a hand-held phone settles and stirs again and again.
    static func settle() {
        guard canPlay else { return }
        let now = Date()
        if let lastSettle, now.timeIntervalSince(lastSettle) < 4 { return }
        lastSettle = now
        switch strength {
        case .light: light.impactOccurred(intensity: 0.3)
        case .normal: light.impactOccurred(intensity: 0.5)
        case .strong: light.impactOccurred(intensity: 0.8)
        }
    }

    /// A value going from the camera's own to one set by hand: a firm click, so the change of who holds it is felt.
    static func takeOver() {
        guard canPlay else { return }
        switch strength {
        case .light: rigid.impactOccurred(intensity: 0.45)
        case .normal: rigid.impactOccurred(intensity: 0.65)
        case .strong: rigid.impactOccurred(intensity: 0.9)
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
