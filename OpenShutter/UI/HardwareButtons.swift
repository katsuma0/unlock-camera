import SwiftUI
import AVKit
// onCameraCaptureEvent lives in AVKit's SwiftUI overlay. Xcode loads it from the two imports above; naming it
// keeps the modifier visible to compilers that don't load cross-import overlays on their own.
import _AVKit_SwiftUI
import CameraCore

/// The volume buttons and a Camera Control click, while the camera can act on them. The camera screen decides when
/// that is and passes it in as `isEnabled`.
///
/// Each volume button does what Settings maps it to. iOS raises two events, primary and secondary, and says nothing
/// more about the source: the primary one is Volume down, which a Camera Control click and an AirPods click arrive
/// as too, and the secondary one is Volume up. While a countdown, a stack, an intervalometer or a bracket runs, any
/// button stops it whatever it is set to, so a shot can always be ended without touching the phone.
struct HardwareButtons: ViewModifier {
    let model: CameraModel
    let isEnabled: Bool

    /// What each press is doing. A reference, so a press changes it without redrawing anything.
    @State private var presses = HardwarePresses()

    func body(content: Content) -> some View {
        // Reads no settings, so the camera's many settings changes (a zoom, a dial turn) never touch the interaction
        // while a finger may be holding a button.
        captureEvents(content)
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { presses.endAll(model) }
            }
            .onDisappear { presses.endAll(model) }
    }

    @ViewBuilder
    private func captureEvents(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // The app plays an AirPods click's sound itself, so a click that zooms or changes the brightness doesn't
            // sound like a photo being taken.
            content.onCameraCaptureEvent(
                isEnabled: isEnabled,
                defaultSoundDisabled: true,
                primaryAction: { event in presses.handle(event, from: .volumeDown, model: model) },
                secondaryAction: { event in presses.handle(event, from: .volumeUp, model: model) }
            )
        } else {
            content.onCameraCaptureEvent(
                isEnabled: isEnabled,
                primaryAction: { event in presses.handle(event, from: .volumeDown, model: model) },
                secondaryAction: { event in presses.handle(event, from: .volumeUp, model: model) }
            )
        }
        #else
        content.onCameraCaptureEvent(
            isEnabled: isEnabled,
            primaryAction: { event in presses.handle(event, from: .volumeDown, model: model) },
            secondaryAction: { event in presses.handle(event, from: .volumeUp, model: model) }
        )
        #endif
    }
}

/// During an intervalometer run the shutter ends the whole sequence, like its Stop button. In the pauses between
/// shots the model is idle, so a plain press there would start a second sequence instead.
@MainActor
func pressShutter(_ model: CameraModel) {
    if model.intervalometer != nil {
        model.stopCapture()
    } else {
        model.shutterPressed()
    }
}

/// The presses in progress, one per button. A press keeps the role it began with until it ends, so a release does
/// what its press started even when the camera's state moved in between.
@MainActor
private final class HardwarePresses {
    enum Button: Hashable {
        case volumeUp, volumeDown
    }

    private enum Role {
        /// Ends what is running, whatever the button is set to.
        case stop
        case shutter
        /// A bulb exposure started by this press, so its release can end it.
        case bulb(started: Date)
        /// Zoom or brightness: a step at the press, then more while held.
        case repeating
        case nextLens
        /// Came while the camera couldn't take it, such as a zoom while a photo saves; its release does nothing.
        case ignored
    }

    /// What a held zoom or brightness button keeps doing.
    private enum Step {
        case zoom(up: Bool)
        case bias(up: Bool)

        var interval: UInt64 {
            switch self {
            // About a stop a second at every zoom: the zoom's steps are roughly even in stops.
            case .zoom: return 100_000_000
            case .bias: return 200_000_000
            }
        }
    }

    /// The sound an AirPods click should make for what it did.
    private enum PressSound {
        case shutter, recordingStart, recordingEnd
    }

    /// A press held this long keeps going; a shorter one did its one step.
    private static let holdDelay: UInt64 = 350_000_000
    /// A bulb exposure held at least this long ends on release; a quick click leaves it running for the next click.
    private static let bulbHold: TimeInterval = 0.5
    /// A third of a stop, as one detent of the brightness dial.
    private static let biasStep = 1.0 / 3.0

    private var roles: [Button: Role] = [:]
    private var repeats: [Button: Task<Void, Never>] = [:]

    func handle(_ event: AVCaptureEvent, from button: Button, model: CameraModel) {
        switch event.phase {
        case .began:
            began(event, button: button, model: model)
        case .ended:
            ended(event, button: button, model: model)
        case .cancelled:
            cancelled(button, model: model)
        @unknown default:
            break
        }
    }

    /// The buttons went back to iOS or the camera went away: nothing may keep running for a release that won't come.
    func endAll(_ model: CameraModel) {
        for button in Array(roles.keys) {
            cancelled(button, model: model)
        }
        for task in repeats.values {
            task.cancel()
        }
        repeats.removeAll()
    }

    // MARK: Phases

    private func began(_ event: AVCaptureEvent, button: Button, model: CameraModel) {
        stopRepeating(button)
        if Self.isRunningShot(model) {
            roles[button] = .stop
            return
        }
        switch Self.action(for: button, model: model) {
        case .shutter:
            let isBulb = model.settings.mode == .long && model.settings.longExposure.bulb
            // The conditions the model starts a bulb hold on, so the AirPods sound only plays for one that starts.
            if isBulb, model.activity == .idle, model.intervalometer == nil, model.photosInFlight == 0,
               model.canCapture {
                roles[button] = .bulb(started: Date())
                model.shutterHoldBegan()
                play(.shutter, for: event)
            } else {
                roles[button] = .shutter
            }
        case .zoomIn:
            startRepeating(.zoom(up: true), button: button, model: model)
        case .zoomOut:
            startRepeating(.zoom(up: false), button: button, model: model)
        case .brighter:
            startRepeating(.bias(up: true), button: button, model: model)
        case .darker:
            startRepeating(.bias(up: false), button: button, model: model)
        case .nextLens:
            roles[button] = .nextLens
        }
    }

    private func ended(_ event: AVCaptureEvent, button: Button, model: CameraModel) {
        let role = roles.removeValue(forKey: button)
        switch role {
        case .stop:
            // The one role checked again: the shot can end on its own while the button is down, and the release
            // must not start another, least of all from a button set to zoom.
            if Self.isRunningShot(model) {
                stop(event, model: model)
            }
        case .shutter:
            shutter(event, model: model)
        case .bulb(let started):
            // A quick click starts the bulb like a tap on the shutter and the next click ends it; only a real hold
            // ends the exposure on release.
            if Date().timeIntervalSince(started) >= Self.bulbHold {
                model.shutterHoldEnded()
            }
        case .repeating:
            stopRepeating(button)
        case .nextLens:
            model.selectNextLens()
        case .ignored:
            break
        case nil:
            // A release whose press came before the buttons were the camera's: a quick press of the mapping.
            if Self.isRunningShot(model) {
                stop(event, model: model)
                return
            }
            switch Self.action(for: button, model: model) {
            case .shutter: shutter(event, model: model)
            case .zoomIn where Self.canAdjust(model): _ = step(.zoom(up: true), model: model)
            case .zoomOut where Self.canAdjust(model): _ = step(.zoom(up: false), model: model)
            case .brighter where Self.canAdjust(model): _ = step(.bias(up: true), model: model)
            case .darker where Self.canAdjust(model): _ = step(.bias(up: false), model: model)
            case .zoomIn, .zoomOut, .brighter, .darker: break
            case .nextLens: model.selectNextLens()
            }
        }
    }

    private func cancelled(_ button: Button, model: CameraModel) {
        let role = roles.removeValue(forKey: button)
        stopRepeating(button)
        if case .bulb = role {
            model.shutterHoldEnded()
        }
    }

    // MARK: Actions

    /// Today's shutter press, with the AirPods sound for what it starts or ends.
    private func shutter(_ event: AVCaptureEvent, model: CameraModel) {
        // Worked out before the press changes the state it depends on.
        let sound = model.shutterAcceptsPress ? Self.sound(model) : nil
        pressShutter(model)
        if let sound {
            play(sound, for: event)
        }
    }

    /// Ends what is running. A stack ended early still saves what it has, so an AirPods click hears the shutter for
    /// it. A cancelled countdown or a stopped sequence takes no picture, and the shutter would say it did.
    private func stop(_ event: AVCaptureEvent, model: CameraModel) {
        // The model marks every finish that keeps a picture, one before the first frame included (the backends wait
        // for that frame), and never a cancel, such as a press just as a countdown ran out. One already finishing
        // had its sound.
        let wasFinishing = model.isFinishingStack
        pressShutter(model)
        if !wasFinishing, model.isFinishingStack {
            play(.shutter, for: event)
        }
    }

    private func startRepeating(_ kind: Step, button: Button, model: CameraModel) {
        guard Self.canAdjust(model) else {
            roles[button] = .ignored
            return
        }
        roles[button] = .repeating
        guard step(kind, model: model) else { return }
        repeats[button] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.holdDelay)
            while !Task.isCancelled {
                guard let self, Self.canAdjust(model), self.step(kind, model: model) else { return }
                try? await Task.sleep(nanoseconds: kind.interval)
            }
        }
    }

    private func stopRepeating(_ button: Button) {
        repeats.removeValue(forKey: button)?.cancel()
    }

    /// One step; false once nothing moves, at the end of the range or when the camera won't take it, which ends a
    /// held button's run.
    private func step(_ kind: Step, model: CameraModel) -> Bool {
        switch kind {
        case .zoom(let up):
            let before = model.requestedZoom
            model.nudgeZoom(by: up ? 1 : -1)
            let after = model.requestedZoom
            guard abs(after - before) > 1e-6 else {
                Haptics.stop()
                return false
            }
            // Firmer at a lens button's value, as on the zoom wheel; the other steps follow the zoom ticks setting.
            Haptics.zoomTick(atLensValue: model.zoomMarks.contains(where: { abs($0 - after) < 0.005 }))
            return true
        case .bias(let up):
            // The model says where it landed in a toast, which VoiceOver reads out too.
            let before = Self.bias(model)
            model.stepBias(by: up ? Self.biasStep : -Self.biasStep)
            let after = Self.bias(model)
            guard abs(after - before) > 1e-6 else {
                Haptics.stop()
                return false
            }
            Haptics.tick()
            return true
        }
    }

    private func play(_ sound: PressSound, for event: AVCaptureEvent) {
        #if compiler(>=6.2)
        // Only an AirPods click asks for a sound, and only because the default one is off.
        if #available(iOS 26.0, *), event.shouldPlaySound {
            switch sound {
            case .shutter: _ = event.play(.cameraShutter)
            case .recordingStart: _ = event.play(.beginVideoRecording)
            case .recordingEnd: _ = event.play(.endVideoRecording)
            }
        }
        #endif
    }

    // MARK: Rules

    private static func action(for button: Button, model: CameraModel) -> HardwareButtonAction {
        let controls = model.settings.controls
        return button == .volumeUp ? controls.volumeUpAction : controls.volumeDownAction
    }

    /// A shot that a press ends: a countdown, a stack, an intervalometer run between its shots, or a bracket.
    private static func isRunningShot(_ model: CameraModel) -> Bool {
        switch model.activity {
        case .countdown, .stacking: return true
        case .idle, .capturing, .recording, .saving: return model.intervalometer != nil || model.bracketInProgress
        }
    }

    /// Zoom and brightness stay put while frames are captured or saved, as on the screen.
    private static func canAdjust(_ model: CameraModel) -> Bool {
        guard model.sessionState == .running else { return false }
        switch model.activity {
        case .idle, .recording: return true
        case .countdown, .capturing, .stacking, .saving: return false
        }
    }

    /// NIGHT keeps its own compensation, as setBias does.
    private static func bias(_ model: CameraModel) -> Double {
        model.settings.mode == .night ? model.settings.night.biasEV : model.settings.manual.bias
    }

    /// What the shutter press is about to do, as the AirPods sound for it: a photo or the start of a shot, the start
    /// or end of a recording, and nothing for a press that stops a shot (a stop press has its own, in stop(_:model:)).
    private static func sound(_ model: CameraModel) -> PressSound? {
        switch model.activity {
        case .recording:
            return .recordingEnd
        case .idle:
            guard model.intervalometer == nil else { return nil }
            return model.settings.mode == .video ? .recordingStart : .shutter
        case .countdown, .capturing, .stacking, .saving:
            return nil
        }
    }
}
