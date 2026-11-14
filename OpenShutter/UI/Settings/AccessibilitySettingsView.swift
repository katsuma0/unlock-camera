import SwiftUI
import CameraCore

/// Small options that make the camera easier to see, reach and follow, at both levels. iOS's own Bold Text, Reduce
/// Transparency, Increase Contrast and VoiceOver apply without them.
struct AccessibilitySettingsView: View {
    let model: CameraModel

    var body: some View {
        let systemReducesMotion = AppearanceStore.shared.systemReducesMotion

        Form {
            Section {
                Toggle("Larger labels", isOn: model.settingBinding(\.accessibility.largerLabels))
            } footer: {
                Text("Makes the text on the camera screen bigger. Settings and the other lists follow the text size set in iOS.")
            }

            Section {
                Toggle("Solid buttons", isOn: model.settingBinding(\.accessibility.solidControls))
            } footer: {
                Text("Puts the camera's buttons on dark backgrounds instead of glass, so they stay readable over bright scenes.")
            }

            Section {
                Toggle("Reduce motion", isOn: model.settingBinding(\.accessibility.reduceMotion))
            } footer: {
                SettingsFooter([
                    "Keeps icons still when the phone turns and fades panels instead of sliding them.",
                    systemReducesMotion ? "Reduce Motion is on in iOS, so the camera moves less already." : nil,
                ])
            }

            Section {
                Toggle("Left-handed", isOn: model.settingBinding(\.accessibility.leftHanded))
            } footer: {
                Text("Puts the button that flips to the front camera on the left and your photos on the right, and the brightness control left of the zoom buttons.")
            }

            Section {
                Toggle("Speak status", isOn: model.settingBinding(\.accessibility.speakStatus))
            } footer: {
                Text("Says the countdown out loud, and when a night or long exposure shot starts and ends. It stays quiet while filming, so the video doesn't pick it up. With VoiceOver on, VoiceOver says it instead.")
            }

            Section {
            } footer: {
                Text("Bold Text, Reduce Transparency, Increase Contrast and VoiceOver in iOS Settings work in the camera too.")
            }
        }
        .navigationTitle("Accessibility")
        .navigationBarTitleDisplayMode(.inline)
    }
}
