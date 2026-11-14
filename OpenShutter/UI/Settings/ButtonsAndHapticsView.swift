import SwiftUI
import CameraCore

/// What the volume buttons do in the camera, and how the controls feel, at both levels.
struct ButtonsAndHapticsView: View {
    let model: CameraModel

    /// Which press raises which of iOS's two button events is for a phone to confirm. If a Camera Control click
    /// turns out to follow Volume up, this sentence is the one to change.
    static let cameraControlNote = "A Camera Control click does what Volume down does."

    var body: some View {
        let controls = model.settings.controls
        let advanced = model.isAdvanced
        let hasCameraControl = model.capabilities.supportsCameraControls

        Form {
            Section {
                // One system interaction carries the volume buttons and the Camera Control click, with one switch
                // for all of them, so a single switch here covers both.
                Toggle("Use hardware buttons", isOn: model.settingBinding(\.controls.volumeShutter))
            } footer: {
                Text(hasCameraControl ? Self.switchNote : Self.volumeOnlySwitchNote)
            }

            Section {
                SettingsPicker("Volume up", selection: model.settingBinding(\.controls.volumeUpAction),
                               options: HardwareButtonAction.allCases, label: \.title)
                SettingsPicker("Volume down", selection: model.settingBinding(\.controls.volumeDownAction),
                               options: HardwareButtonAction.allCases, label: \.title)
            } header: {
                Text("Volume buttons")
            } footer: {
                SettingsFooter([
                    hasCameraControl ? Self.cameraControlNote : nil,
                    advanced
                        ? "During a countdown, a night or long exposure shot, an intervalometer or a bracket, either button stops it, whatever it is set to."
                        : "During a countdown or a night or long exposure shot, either button stops it, whatever it is set to.",
                    "Holding Zoom in, Zoom out, Brighter or Darker keeps going until you let go.",
                ])
            }
            .disabled(!controls.volumeShutter)

            Section {
                SettingsPicker("Haptics", selection: hapticsBinding, options: HapticsChoice.allCases, label: \.title)
                Toggle("Selection ticks", isOn: model.settingBinding(\.controls.dialTicks))
                    .disabled(!controls.haptics)
                SettingsPicker("Zoom ticks", selection: model.settingBinding(\.controls.zoomTicks),
                               options: ZoomTickStyle.allCases, label: \.title)
                    .disabled(!controls.haptics)
            } header: {
                Text("Haptics")
            } footer: {
                SettingsFooter([
                    "Haptics are the small taps you feel when you use the controls. They pause during night and long exposure shots so they don't shake the phone, and iOS mutes them while a video records sound.",
                    "Selection ticks are the clicks you feel as a dial turns, the mode changes or you step through choices, and when the phone comes level. With them off, you still feel taps, the shutter and zoom ticks.",
                    "Touch and hold a zoom button and drag to zoom. Zoom ticks sets whether it ticks at every step or only at the zoom buttons' values.",
                ])
            }
        }
        .navigationTitle("Buttons and haptics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let switchNote = "The volume buttons and a Camera Control click do what you pick below. When this is off, they go back to iOS: the volume buttons change the volume and a Camera Control click opens the camera app chosen in iOS Settings."
    private static let volumeOnlySwitchNote = "The volume buttons do what you pick below. When this is off, they change the volume."

    /// Off is the old haptics switch and the strength is kept beside it, so a save from before means the same, and
    /// turning haptics back on brings the strength back.
    private var hapticsBinding: Binding<HapticsChoice> {
        Binding(
            get: {
                let controls = model.settings.controls
                return controls.haptics ? HapticsChoice(controls.hapticStrength) : .off
            },
            set: { choice in
                model.updateSettings { settings in
                    if let strength = choice.strength {
                        settings.controls.haptics = true
                        settings.controls.hapticStrength = strength
                    } else {
                        settings.controls.haptics = false
                    }
                }
                // The new strength, felt at once.
                Haptics.tap()
            }
        )
    }
}

/// The Haptics menu: off, or on at a strength.
private enum HapticsChoice: Hashable, CaseIterable {
    case off, light, normal, strong

    init(_ strength: HapticStrength) {
        switch strength {
        case .light: self = .light
        case .normal: self = .normal
        case .strong: self = .strong
        }
    }

    var strength: HapticStrength? {
        switch self {
        case .off: return nil
        case .light: return .light
        case .normal: return .normal
        case .strong: return .strong
        }
    }

    var title: String {
        strength?.title ?? "Off"
    }
}
