import SwiftUI
import CameraCore

/// VIDEO mode quick settings: resolution, frame rate, codec, color, stabilization, sound and the shutter angle.
/// Every menu only offers what the active lens's formats can record.
struct VideoControls: View {
    @Bindable var model: CameraModel
    @State private var cache = VideoOptionsCache()

    var body: some View {
        // Chips and checkmarks show what this lens records, since the saved settings can ask for more (4K 120 on a lens
        // that stops at 4K 60). Picks still go to the saved settings.
        let video = model.recordedVideo
        let caps = model.capabilities
        // Option lists are rebuilt only when formats or the color and size they depend on change, not on every
        // settings write from a dial drag.
        let options = cache.options(for: VideoOptionsKey(
            formats: caps.formats,
            codecs: caps.videoCodecs,
            colorModes: caps.colorModes,
            stabilization: caps.stabilizationModes,
            resolution: video.resolution,
            colorMode: video.colorMode
        ))
        // Changing the format reconfigures the session, which would end a recording. The camera screen already
        // dims this panel while filming, so it is only disabled here.
        let locked = model.activity.isBusy
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    resolutionMenu(video, options: options)
                    frameRateMenu(video, options: options)
                    codecMenu(video, options: options)
                    colorMenu(video, options: options)
                    stabilizationMenu(video, options: options)
                    audioButton(video)
                    ShutterAngleChip(model: model, isSelected: model.activeDial == .shutter)
                }
                .padding(.horizontal, 16)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
        .frame(height: 44)
        .disabled(locked)
    }

    // MARK: Menus

    private func resolutionMenu(_ video: VideoSettings, options: VideoOptions) -> some View {
        let choices = options.resolutions.isEmpty ? [video.resolution] : options.resolutions
        return Menu {
            Picker("Resolution", selection: Binding(get: { video.resolution }, set: setResolution)) {
                ForEach(choices) { resolution in
                    Text(resolution.title).tag(resolution)
                }
            }
            .pickerStyle(.inline)
        } label: {
            MenuChip(text: video.resolution.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Resolution"))
        .accessibilityValue(Text(video.resolution.title))
    }

    private func frameRateMenu(_ video: VideoSettings, options: VideoOptions) -> some View {
        let choices = options.frameRates.isEmpty ? [video.frameRate] : options.frameRates
        return Menu {
            Picker("Frame rate", selection: Binding(get: { video.frameRate }, set: setFrameRate)) {
                ForEach(choices, id: \.self) { rate in
                    Text(Formatting.frameRate(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            MenuChip(text: Formatting.frameRate(video.frameRate))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Frame rate"))
        .accessibilityValue(Text(Formatting.frameRate(video.frameRate)))
    }

    private func codecMenu(_ video: VideoSettings, options: VideoOptions) -> some View {
        let choices = options.codecs.isEmpty ? [video.codec] : options.codecs
        let recorded = VideoOptions.recordedCodec(video.codec, among: options.codecs)
        return Menu {
            Picker("Codec", selection: Binding(get: { recorded }, set: setCodec)) {
                ForEach(choices) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            .pickerStyle(.inline)
        } label: {
            MenuChip(text: codec(recorded))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Codec"))
        .accessibilityValue(Text(recorded.title))
    }

    private func colorMenu(_ video: VideoSettings, options: VideoOptions) -> some View {
        let choices = options.colorModes.isEmpty ? [video.colorMode] : options.colorModes
        return Menu {
            Picker("Color", selection: Binding(get: { video.colorMode }, set: setColorMode)) {
                ForEach(choices) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            MenuChip(text: color(video.colorMode), isActive: video.colorMode != .sdr)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Color"))
        .accessibilityValue(Text(video.colorMode.title))
    }

    private func stabilizationMenu(_ video: VideoSettings, options: VideoOptions) -> some View {
        let recorded = VideoOptions.recordedStabilization(video.stabilization, among: options.stabilization)
        let choices = options.stabilization.isEmpty ? [recorded] : options.stabilization
        return Menu {
            Picker("Stabilization", selection: Binding(get: { recorded }, set: setStabilization)) {
                ForEach(choices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            MenuChip(text: stabilization(recorded), systemName: "figure.walk", model: model)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Stabilization"))
        .accessibilityValue(Text(recorded.title))
    }

    private func audioButton(_ video: VideoSettings) -> some View {
        Button {
            Haptics.tap()
            model.updateSettings { $0.video.audio.toggle() }
        } label: {
            UprightImage(model: model, systemName: video.audio ? "mic.fill" : "mic.slash.fill")
                .frame(width: 18)
        }
        .buttonStyle(VideoChipStyle(tint: video.audio ? Theme.primaryText : Theme.secondaryText, isSelected: false))
        .accessibilityLabel(Text("Sound"))
        .accessibilityValue(Text(video.audio ? "On" : "Off"))
    }

    // MARK: Changes

    private func setResolution(_ resolution: VideoResolution) {
        Haptics.tick()
        let formats = model.capabilities.formats
        model.updateSettings { settings in
            settings.video.resolution = resolution
            let rates = FormatSelector.availableFrameRates(resolution: resolution, colorMode: settings.video.colorMode, among: formats)
            settings.video.frameRate = VideoOptions.closestRate(to: settings.video.frameRate, in: rates)
        }
    }

    private func setFrameRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        Haptics.tick()
        model.updateSettings { $0.video.frameRate = rate }
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

    // MARK: Short chip titles; the menus use the full ones.

    private func codec(_ codec: VideoCodecChoice) -> String {
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

    private func color(_ mode: VideoColorMode) -> String {
        switch mode {
        case .sdr: return "SDR"
        case .hdr: return "HDR"
        case .appleLog: return "Log"
        case .appleLog2: return "Log 2"
        }
    }

    private func stabilization(_ choice: StabilizationChoice) -> String {
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

// MARK: - Shutter angle

/// Reads the live shutter on its own, so the 10 Hz readings only redraw this chip.
private struct ShutterAngleChip: View {
    let model: CameraModel
    let isSelected: Bool

    var body: some View {
        let fps = model.recordedVideo.frameRate
        // The shared manual shutter can be longer than a frame (it comes from MANUAL); the camera clamps it to
        // 1/fps, so the angle never reads past 360°.
        let seconds = fps.isFinite ? min(model.displayShutter, 1 / max(fps, 1)) : model.displayShutter
        let angle = ExposureMath.shutterAngle(seconds: seconds, fps: fps)
        // Checked and bounded before the Int conversion, which traps on NaN and on huge values.
        let degrees = angle.isFinite ? Int(min(max(angle, 0), 3600).rounded()) : 0
        let auto = model.isShutterAuto
        Button {
            Haptics.tick()
            withAnimation(Theme.spring) {
                model.activeDial = model.activeDial == .shutter ? nil : .shutter
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(degrees)\u{00B0}")
                    .contentTransition(.numericText(value: Double(degrees)))
                if auto {
                    AutoBadge()
                }
            }
        }
        .buttonStyle(VideoChipStyle(tint: auto ? Theme.primaryText : Theme.accent, isSelected: isSelected))
        // Keyed to auto, not the angle: auto exposure moves the angle with every 10 Hz reading.
        .animation(Theme.snappy, value: auto)
        .accessibilityLabel(Text("Shutter angle"))
        .accessibilityValue(Text("\(degrees) degrees" + (auto ? ", auto" : "")))
        .accessibilityHint(Text("Shows the shutter dial."))
    }
}

private struct AutoBadge: View {
    var body: some View {
        Text("A")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(Color.black)
            .frame(width: 11, height: 11)
            .background(Circle().fill(Theme.primaryText.opacity(0.85)))
            .accessibilityHidden(true)
    }
}

// MARK: - Chip looks

private struct MenuChip: View {
    let text: String
    var isActive = false
    var systemName: String? = nil
    var model: CameraModel? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemName, let model {
                UprightImage(model: model, systemName: systemName)
            }
            Text(text)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.6)
        }
        .font(Theme.chipFont)
        .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .cameraGlass(in: Capsule())
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct UprightImage: View {
    let model: CameraModel
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .uprightRotation(model.motion.iconRotationDegrees)
    }
}

private struct VideoChipStyle: ButtonStyle {
    var tint: Color
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chipFont)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .cameraGlass(in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Theme.accent.opacity(isSelected ? 0.8 : 0), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .animation(Theme.spring, value: isSelected)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Options

private struct VideoOptionsKey: Equatable {
    var formats: [FormatDescriptor]
    var codecs: [VideoCodecChoice]
    var colorModes: [VideoColorMode]
    var stabilization: [StabilizationChoice]
    var resolution: VideoResolution
    var colorMode: VideoColorMode
}

private struct VideoOptions {
    var resolutions: [VideoResolution]
    var frameRates: [Double]
    var codecs: [VideoCodecChoice]
    var colorModes: [VideoColorMode]
    var stabilization: [StabilizationChoice]

    static let empty = VideoOptions(resolutions: [], frameRates: [], codecs: [], colorModes: [], stabilization: [])

    init(resolutions: [VideoResolution], frameRates: [Double], codecs: [VideoCodecChoice],
         colorModes: [VideoColorMode], stabilization: [StabilizationChoice]) {
        self.resolutions = resolutions
        self.frameRates = frameRates
        self.codecs = codecs
        self.colorModes = colorModes
        self.stabilization = stabilization
    }

    init(_ key: VideoOptionsKey) {
        let formats = key.formats
        resolutions = FormatSelector.availableResolutions(colorMode: key.colorMode, among: formats)
        frameRates = FormatSelector.availableFrameRates(resolution: key.resolution, colorMode: key.colorMode, among: formats)
        codecs = key.codecs
        // Before the formats arrive there is nothing to check against, so every reported mode stays.
        colorModes = formats.isEmpty
            ? key.colorModes
            : key.colorModes.filter { !FormatSelector.availableResolutions(colorMode: $0, among: formats).isEmpty }
        // Preview optimized runs only on preview connections; a movie gets standard, so it would be a second
        // "Standard" in the menu.
        stabilization = key.stabilization.filter { $0 != .previewOptimized }
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
    private var value = VideoOptions.empty

    func options(for key: VideoOptionsKey) -> VideoOptions {
        if key != self.key {
            self.key = key
            value = VideoOptions(key)
        }
        return value
    }
}
