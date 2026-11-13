import SwiftUI
import AVKit
// onCameraCaptureEvent lives in AVKit's SwiftUI overlay. Xcode loads it from the two imports above; naming it
// keeps the modifier visible to compilers that don't load cross-import overlays on their own.
import _AVKit_SwiftUI
import CameraCore

/// The volume buttons and a Camera Control click, while the camera can act on them. The camera screen decides when
/// that is and passes it in as `isEnabled`.
struct HardwareButtons: ViewModifier {
    let model: CameraModel
    let isEnabled: Bool

    /// Set while a hardware button press is running a bulb exposure, so its release can end it.
    @State private var bulbPressStart: Date?

    func body(content: Content) -> some View {
        content.onCameraCaptureEvent(
            isEnabled: isEnabled,
            primaryAction: { event in handle(event) },
            secondaryAction: { event in handle(event) }
        )
    }

    private func handle(_ event: AVCaptureEvent) {
        switch event.phase {
        case .began:
            let isBulb = model.settings.mode == .long && model.settings.longExposure.bulb
            if isBulb, model.activity == .idle, model.intervalometer == nil, model.canCapture {
                bulbPressStart = Date()
                model.shutterHoldBegan()
            } else {
                bulbPressStart = nil
            }
        case .ended:
            if let start = bulbPressStart {
                bulbPressStart = nil
                // A quick click starts the bulb like a tap on the shutter and the next click ends it;
                // only a real hold ends the exposure on release.
                if Date().timeIntervalSince(start) >= 0.5 {
                    model.shutterHoldEnded()
                }
            } else {
                pressShutter(model)
            }
        case .cancelled:
            if bulbPressStart != nil {
                bulbPressStart = nil
                model.shutterHoldEnded()
            }
        @unknown default:
            break
        }
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
