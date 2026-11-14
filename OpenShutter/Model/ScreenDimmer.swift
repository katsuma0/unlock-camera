import Foundation
import UIKit
import CameraCore

/// The battery saver: darkens the screen during a long shot and puts the brightness back. A black overlay turns
/// most of an OLED panel off; the lower brightness under it saves on LCD phones, whose backlight lights black too.
/// The model decides when (DimPolicy); this keeps the screen's own brightness and gives it back on every way out,
/// because a brightness the app sets stays after it leaves, until the phone locks.
@MainActor
@Observable
final class ScreenDimmer {
    /// The black layer is up. The brightness goes down once the layer has faded in.
    private(set) var isDimmed = false

    /// Called when isDimmed flips, so the model can stop publishing what nobody sees under the layer.
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    /// How long DimOverlay takes to fade in. The backlight only steps down after it, on black, so the step never
    /// shows on the picture.
    static let fadeInSeconds = 0.6

    /// The person's brightness, kept while it is lowered.
    @ObservationIgnored private var savedBrightness: CGFloat?
    @ObservationIgnored private weak var screen: UIScreen?
    @ObservationIgnored private var lowerTask: Task<Void, Never>?
    @ObservationIgnored private var wokeAt: Date?
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Control Center, the notification shade, a call or Siri make the app inactive while the shot goes on: the
        // person has to see their screen there. Leaving for another app ends with the same restore.
        let leaving = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification]
        for name in leaving {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appStoppedBeingActive() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        // No deinit restore: the model owns the dimmer for the whole run of the app, and if the app is killed while
        // dim, iOS gives the brightness back at the next lock.
    }

    /// Seconds since a touch (or a return to the app) last lit the screen; nil when nothing did since resetWake.
    var secondsSinceWake: Double? {
        wokeAt.map { Date().timeIntervalSince($0) }
    }

    /// Dims or restores to match the model's rule. Never dims while the app isn't the active one.
    func update(shouldDim: Bool) {
        if shouldDim {
            guard isAppActive, !isDimmed else { return }
            dim()
        } else {
            restore()
        }
    }

    /// A touch on the overlay: the screen lights up and stays lit a while (DimPolicy.wakeSeconds).
    func wake() {
        guard isDimmed else { return }
        wokeAt = Date()
        restore()
    }

    /// A new shot starts with no wake of its own.
    func resetWake() {
        wokeAt = nil
    }

    /// Brightness first, then the layer, so the picture never shows at the lowered brightness.
    func restore() {
        lowerTask?.cancel()
        lowerTask = nil
        if let saved = savedBrightness, let screen, screen.brightness != saved {
            screen.brightness = saved
        }
        savedBrightness = nil
        screen = nil
        setDimmed(false)
    }

    private func dim() {
        // UIScreen.main is deprecated in iOS 26; the scene in front knows its screen. Without one the layer still
        // turns the panel's pixels off.
        screen = Self.activeScreen()
        setDimmed(true)
        lowerTask?.cancel()
        lowerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeInSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isDimmed, let screen = self.screen else { return }
            let current = screen.brightness
            let lowered = CGFloat(DimPolicy.brightness(whileDimming: Double(current)))
            // Never brighter than the person had it.
            guard lowered < current else { return }
            self.savedBrightness = current
            screen.brightness = lowered
        }
    }

    private func setDimmed(_ dimmed: Bool) {
        guard isDimmed != dimmed else { return }
        isDimmed = dimmed
        onChange?(dimmed)
    }

    private func appStoppedBeingActive() {
        isAppActive = false
        restore()
    }

    private func appBecameActive() {
        isAppActive = true
        // Coming back to the app is a look at the shot, like a touch.
        wokeAt = Date()
    }

    private static func activeScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}
