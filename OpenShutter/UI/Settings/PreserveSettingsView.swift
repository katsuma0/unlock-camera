import SwiftUI
import CameraCore

/// What the camera keeps from last time when Open Shutter starts, as in iOS's Camera settings. Each switch off starts
/// its part where a fresh install does.
struct PreserveSettingsView: View {
    let model: CameraModel

    var body: some View {
        // The simple interface calls exposure compensation brightness, as on its chip and dial.
        let advanced = model.isAdvanced

        Form {
            Section {
                Toggle("Camera mode", isOn: model.settingBinding(\.startup.keepMode))
            } footer: {
                Text("Opens in the mode you used last instead of Photo.")
            }

            Section {
                Toggle("Lens and zoom", isOn: model.settingBinding(\.startup.keepLensAndZoom))
            } footer: {
                Text("Opens on the lens and zoom you used last instead of the main lens at 1x.")
            }

            Section {
                Toggle(advanced ? "Exposure" : "Brightness", isOn: model.settingBinding(\.startup.keepBrightness))
            } footer: {
                Text(advanced
                    ? "Keeps the exposure compensation you set, Night mode's too, instead of going back to 0."
                    : "Keeps the brightness you set, Night mode's too, instead of going back to normal.")
            }

            Section {
            } footer: {
                Text("These apply each time Open Shutter starts. Coming back to it from another app keeps everything as it was.")
            }
        }
        .navigationTitle("Preserve settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
