import SwiftUI
import CameraCore

/// VIDEO's row: codec, color, stabilization and sound. The size and the frame rate are the top bar's chip. Every
/// menu offers only what the active lens's formats can record. The shutter, as a speed or an angle, has its one chip
/// beside the lens buttons (LensRowShutterChip).
struct VideoControls: View {
    @Bindable var model: CameraModel

    var body: some View {
        // Chips show what this lens records, since the saved settings can ask for more (ProRes on a format that
        // can't take it). Picks still go to the saved settings.
        let video = model.recordedVideo
        let caps = model.capabilities
        let codec = VideoOptions.recordedCodec(video.codec, among: caps.videoCodecs)
        let stabilization = VideoOptions.recordedStabilization(video.stabilization,
                                                               among: VideoOptions.stabilization(caps.stabilizationModes))
        // Changing the format reconfigures the session, which would end a recording. The camera screen already
        // dims this panel while filming, so it is only disabled here.
        let locked = model.activity.isBusy
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    VideoMenuChip(model: model, control: .codec, text: VideoText.codec(codec),
                                  label: "Codec", value: codec.title)
                    VideoMenuChip(model: model, control: .color, text: VideoText.color(video.colorMode),
                                  isActive: video.colorMode != .sdr, label: "Color", value: video.colorMode.title)
                    VideoMenuChip(model: model, control: .stabilization, text: VideoText.stabilization(stabilization),
                                  systemName: "figure.walk", label: "Stabilization", value: stabilization.title)
                    audioButton(video)
                }
                .padding(.horizontal, Theme.edge)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
        .frame(height: 44)
        .disabled(locked)
    }

    private func audioButton(_ video: VideoSettings) -> some View {
        Button {
            Haptics.tap()
            // Inside an animation, so the microphone swaps its symbol the way iOS's own toggles do.
            withAnimation(Theme.snappy) {
                model.updateSettings { $0.video.audio.toggle() }
            }
        } label: {
            UprightImage(model: model, systemName: video.audio ? "mic.fill" : "mic.slash.fill", replaces: true)
                .frame(width: 18)
        }
        .buttonStyle(VideoChipStyle(tint: video.audio ? Theme.primaryText : Theme.secondaryText))
        .accessibilityLabel(Text("Sound"))
        .accessibilityValue(Text(video.audio ? "On" : "Off"))
    }
}

/// The three menus of the row.
private enum VideoMenuControl {
    case codec, color, stabilization
}

/// A menu chip: the face, which turns its glyph with the phone, and the menu laid over it in a view of its own.
private struct VideoMenuChip: View {
    let model: CameraModel
    let control: VideoMenuControl
    let text: String
    var isActive = false
    var systemName: String? = nil
    let label: String
    let value: String
    @State private var press = PressTracker()

    var body: some View {
        MenuChip(text: text, isActive: isActive, systemName: systemName, model: model, isPressed: press.isPressed)
            .accessibilityHidden(true)
            .overlay {
                VideoMenuLayer(model: model, control: control, press: press, label: label, value: value)
            }
    }
}

/// The menu over a chip. Its inputs compare equal until the chip's own value changes, so the settings writes of a
/// dial or the Camera Control leave the system's menu button alone.
private struct VideoMenuLayer: View {
    let model: CameraModel
    let control: VideoMenuControl
    let press: PressTracker
    let label: String
    let value: String

    var body: some View {
        MenuOnTapLayer(press: press, label: label, value: value) {
            VideoMenuRows(model: model, control: control)
        }
    }
}

/// The rows of one menu. They read the settings and the formats themselves, so they follow them and the layer
/// above them doesn't.
private struct VideoMenuRows: View {
    let model: CameraModel
    let control: VideoMenuControl
    @State private var cache = VideoOptionsCache()

    var body: some View {
        let video = model.recordedVideo
        let caps = model.capabilities
        switch control {
        case .codec:
            let recorded = VideoOptions.recordedCodec(video.codec, among: caps.videoCodecs)
            let choices = caps.videoCodecs.isEmpty ? [video.codec] : caps.videoCodecs
            Picker("Codec", selection: Binding(get: { recorded }, set: setCodec)) {
                ForEach(choices) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            .pickerStyle(.inline)
        case .color:
            // Worked out again only when the formats change, not with every settings write.
            let modes = cache.colorModes(for: VideoOptionsKey(formats: caps.formats, colorModes: caps.colorModes))
            let choices = modes.isEmpty ? [video.colorMode] : modes
            Picker("Color", selection: Binding(get: { video.colorMode }, set: setColorMode)) {
                ForEach(choices) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        case .stabilization:
            let available = VideoOptions.stabilization(caps.stabilizationModes)
            let recorded = VideoOptions.recordedStabilization(video.stabilization, among: available)
            let choices = available.isEmpty ? [recorded] : available
            Picker("Stabilization", selection: Binding(get: { recorded }, set: setStabilization)) {
                ForEach(choices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private func setCodec(_ codec: VideoCodecChoice) {
        Haptics.tick()
        model.updateSettings { $0.video.codec = codec }
    }

    /// HDR and Log can live on fewer sizes and rates than SDR, so the size and rate follow to ones that exist.
    private func setColorMode(_ mode: VideoColorMode) {
        Haptics.tick()
        let formats = model.capabilities.formats
        model.updateSettings { settings in
            settings.video.colorMode = mode
            let resolutions = FormatSelector.availableResolutions(colorMode: mode, among: formats)
            if !resolutions.contains(settings.video.resolution), let largest = resolutions.last {
                settings.video.resolution = largest
            }
            let rates = FormatSelector.availableFrameRates(resolution: settings.video.resolution, colorMode: mode, among: formats)
            settings.video.frameRate = VideoOptions.closestRate(to: settings.video.frameRate, in: rates)
        }
    }

    private func setStabilization(_ choice: StabilizationChoice) {
        Haptics.tick()
        model.updateSettings { $0.video.stabilization = choice }
    }
}

/// Short chip titles; the menus use the full ones.
private enum VideoText {
    static func codec(_ codec: VideoCodecChoice) -> String {
        switch codec {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .proRes422HQ: return "ProRes HQ"
        case .proRes422: return "ProRes"
        case .proRes422LT: return "ProRes LT"
        case .proRes422Proxy: return "ProRes Proxy"
        case .proRes4444: return "ProRes 4444"
        }
    }

    static func color(_ mode: VideoColorMode) -> String {
        switch mode {
        case .sdr: return "SDR"
        case .hdr: return "HDR"
        case .appleLog: return "Log"
        case .appleLog2: return "Log 2"
        }
    }

    static func stabilization(_ choice: StabilizationChoice) -> String {
        switch choice {
        case .off: return "Off"
        case .standard: return "Standard"
        case .cinematic: return "Cinematic"
        case .cinematicExtended: return "Extended"
        case .cinematicExtendedEnhanced: return "Enhanced"
        case .previewOptimized: return "Preview"
        case .lowLatency: return "Low latency"
        case .automatic: return "Auto"
        }
    }
}

// MARK: - Chip looks

private struct MenuChip: View {
    let text: String
    var isActive = false
    var systemName: String? = nil
    var model: CameraModel? = nil
    var isPressed = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemName, let model {
                UprightImage(model: model, systemName: systemName)
            }
            Text(text)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.6)
        }
        .font(Theme.chipFont)
        .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.chipPadding)
        .frame(height: Theme.chipHeight)
        .cameraGlass(in: Capsule())
        .scaleEffect(isPressed ? 0.94 : 1)
        .animation(Theme.snappy, value: isPressed)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct UprightImage: View {
    let model: CameraModel
    let systemName: String
    /// Swaps the symbol as iOS's own toggles do, where the change comes inside an animation.
    var replaces = false

    var body: some View {
        Image(systemName: systemName)
            .contentTransition(replaces ? .symbolEffect(.replace) : .identity)
            .uprightRotation(model.motion.iconRotationDegrees)
    }
}

private struct VideoChipStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chipFont)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.chipPadding)
            .frame(height: Theme.chipHeight)
            .cameraGlass(in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Options

private struct VideoOptionsKey: Equatable {
    var formats: [FormatDescriptor]
    var colorModes: [VideoColorMode]
}

private enum VideoOptions {
    /// The color modes some format of this lens records. Before the formats arrive there is nothing to check
    /// against, so every reported mode stays.
    static func colorModes(_ key: VideoOptionsKey) -> [VideoColorMode] {
        guard !key.formats.isEmpty else { return key.colorModes }
        return key.colorModes.filter { !FormatSelector.availableResolutions(colorMode: $0, among: key.formats).isEmpty }
    }

    /// Preview optimized runs only on preview connections; a movie gets standard, so it would be a second
    /// "Standard" in the menu.
    static func stabilization(_ modes: [StabilizationChoice]) -> [StabilizationChoice] {
        modes.filter { $0 != .previewOptimized }
    }

    /// The same rate when the new size or color still has it, else the nearest one it does have.
    static func closestRate(to rate: Double, in rates: [Double]) -> Double {
        guard !rates.isEmpty else { return rate }
        if rates.contains(where: { abs($0 - rate) < 0.01 }) { return rate }
        return rates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? rate
    }

    /// The codec the movie will use. MovieRecorder falls back to HEVC, then H.264, when the format can't record
    /// the chosen one, and the setting keeps the choice for formats that can, so the chip shows the fallback.
    static func recordedCodec(_ chosen: VideoCodecChoice, among available: [VideoCodecChoice]) -> VideoCodecChoice {
        guard !available.isEmpty else { return chosen }
        return [chosen, .hevc, .h264].first(where: available.contains) ?? chosen
    }

    /// The stabilization the movie will get, following MovieRecorder's walk to milder modes this format supports.
    static func recordedStabilization(_ chosen: StabilizationChoice, among available: [StabilizationChoice]) -> StabilizationChoice {
        guard !available.isEmpty else { return chosen }
        let fallbacks: [StabilizationChoice]
        switch chosen {
        // Off asks for nothing; auto lets the system pick, which MovieRecorder doesn't second-guess.
        case .off, .automatic: return chosen
        case .standard, .previewOptimized: fallbacks = [.standard]
        case .cinematic: fallbacks = [.cinematic, .standard]
        case .cinematicExtended: fallbacks = [.cinematicExtended, .cinematic, .standard]
        case .cinematicExtendedEnhanced: fallbacks = [.cinematicExtendedEnhanced, .cinematicExtended, .cinematic, .standard]
        case .lowLatency: fallbacks = [.lowLatency, .standard]
        }
        return fallbacks.first(where: available.contains) ?? .off
    }
}

/// A plain class: filling it in during body must not invalidate the view.
private final class VideoOptionsCache {
    private var key: VideoOptionsKey?
    private var value: [VideoColorMode] = []

    func colorModes(for key: VideoOptionsKey) -> [VideoColorMode] {
        if key != self.key {
            self.key = key
            value = VideoOptions.colorModes(key)
        }
        return value
    }
}
