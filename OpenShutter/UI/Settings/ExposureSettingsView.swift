import SwiftUI
import CameraCore

/// The Exposure page of the full list: how far auto exposure may go, what it measures and how it treats faces,
/// dim light and bright video.
struct ExposureSettingsView: View {
    let model: CameraModel

    /// Slowest first, the way the limit reads on a camera menu.
    private static let autoExposureLimits: [Double] = [
        1, 1.0 / 2, 1.0 / 4, 1.0 / 8, 1.0 / 15, 1.0 / 30, 1.0 / 60, 1.0 / 125, 1.0 / 250, 1.0 / 500,
    ]

    /// Ratios of aperture area between frames (AVFoundation's unit). At 30 fps, 1.25 crosses an f/1.5 to f/4 iris
    /// in about a third of a second, 1.05 in about one and a half, 1.02 in about three.
    private static let apertureSpeeds: [(ratio: Double, title: String)] = [
        (1.25, "Fast"), (1.05, "Smooth"), (1.02, "Very smooth"),
    ]

    var body: some View {
        let exposure = model.settings.exposure
        let caps = model.capabilities

        Form {
            Section {
                Picker("Slowest auto shutter", selection: model.settingBinding(\.exposure.aeMaxShutter)) {
                    Text("Auto").tag(Double?.none)
                    ForEach(Self.limitOptions(current: exposure.aeMaxShutter, longest: caps.exposure.seconds.upperBound),
                            id: \.self) { seconds in
                        Text(ShutterSpeed(seconds: seconds).label).tag(Double?.some(seconds))
                    }
                }
                SettingsPicker("Metering area", selection: model.settingBinding(\.exposure.meteringArea),
                             options: MeteringArea.allCases, label: \.title)
                    .disabled(!caps.supportsMeteringArea)
                SettingsPicker("Face-driven exposure", selection: model.settingBinding(\.exposure.faceDriven),
                             options: TriState.allCases, label: \.title)
                    .disabled(!caps.faceDrivenAutoExposureSupported)
                Toggle("Low light boost", isOn: model.settingBinding(\.exposure.lowLightBoost))
                    .disabled(!caps.lowLightBoostSupported)
                Toggle("Global tone mapping", isOn: model.settingBinding(\.exposure.globalToneMapping))
                    .disabled(!caps.globalToneMappingSupported)
                SettingsPicker("Video HDR", selection: model.settingBinding(\.exposure.videoHDR),
                             options: TriState.allCases, label: \.title)
                    .disabled(!Self.videoHDRAvailable(caps))
                Picker("Aperture speed", selection: model.settingBinding(\.exposure.apertureRateLimit)) {
                    Text("Auto").tag(Double?.none)
                    ForEach(Self.speedOptions(current: exposure.apertureRateLimit), id: \.ratio) { option in
                        Text(option.title).tag(Double?.some(option.ratio))
                    }
                }
                .disabled(!caps.supportsVariableAperture)
            } footer: {
                SettingsFooter(Self.notes(caps: caps, toneMapping: exposure.globalToneMapping))
            }
        }
        .navigationTitle("Exposure")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Limits the current camera can expose for, plus the saved one so the menu always shows a selection.
    private static func limitOptions(current: Double?, longest: Double) -> [Double] {
        // The same 2% slack as the shutter dials, so a camera that reports a hair under 1 s still offers 1 s.
        let reachable = autoExposureLimits.filter { $0 <= longest * 1.02 }
        guard let current, !reachable.contains(current) else { return reachable }
        return (reachable + [current]).sorted(by: >)
    }

    private static func speedOptions(current: Double?) -> [(ratio: Double, title: String)] {
        guard let current, !apertureSpeeds.contains(where: { $0.ratio == current }) else { return apertureSpeeds }
        // A saved ratio from elsewhere still needs a row, or the menu would show nothing selected.
        let custom = (ratio: current, title: String(format: "%.2f\u{00D7} per frame", current))
        return (apertureSpeeds + [custom]).sorted { $0.ratio > $1.ratio }
    }

    /// The active format's flag alone would gray this out in photo modes, where a photo format is active even
    /// though the lens records HDR video. Any HDR-capable format of the lens makes the setting worth having.
    private static func videoHDRAvailable(_ caps: CameraCapabilities) -> Bool {
        caps.videoHDRSupported || caps.formats.contains(where: \.supportsVideoHDR)
    }

    private static func notes(caps: CameraCapabilities, toneMapping: Bool) -> [String?] {
        var notes: [String?] = []
        if toneMapping, caps.globalToneMappingSupported {
            notes.append("Global tone mapping turns off multi-frame fusion.")
        }
        if !caps.supportsVariableAperture {
            if !UnavailableFeatures.runsIOS27 {
                notes.append("Aperture speed needs iOS 27 and a lens with a variable aperture.")
            } else if !UnavailableFeatures.hasIOS27Code {
                notes.append("Aperture speed needs a newer version of Open Shutter and a lens with a variable aperture.")
            } else {
                notes.append("Aperture speed needs a lens with a variable aperture.")
            }
        }
        var unavailable = UnavailableFeatures()
        unavailable.noteFromIOS26("metering area", supported: caps.supportsMeteringArea)
        unavailable.note("face-driven exposure", supported: caps.faceDrivenAutoExposureSupported)
        unavailable.note("low light boost", supported: caps.lowLightBoostSupported)
        unavailable.note("global tone mapping", supported: caps.globalToneMappingSupported)
        unavailable.note("video HDR", supported: videoHDRAvailable(caps))
        notes.append(unavailable.text)
        return notes
    }
}
