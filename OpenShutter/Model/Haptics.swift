import UIKit

/// Haptics shared by every control. Generators are kept warm so the first tick isn't late.
@MainActor
enum Haptics {
    static var isEnabled = true

    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        selection.prepare()
        medium.prepare()
    }

    /// One detent of a dial.
    static func tick() {
        guard isEnabled else { return }
        selection.selectionChanged()
        selection.prepare()
    }

    static func tap() {
        guard isEnabled else { return }
        light.impactOccurred()
    }

    static func shutter() {
        guard isEnabled else { return }
        medium.impactOccurred(intensity: 0.9)
        medium.prepare()
    }

    /// End stops and snaps, e.g. a dial hitting its last value.
    static func stop() {
        guard isEnabled else { return }
        rigid.impactOccurred(intensity: 0.7)
    }

    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }
}
