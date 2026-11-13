import SwiftUI
import CameraCore

/// Flash or video light, timer, drawer chevron, RAW, Live Photo, video format and settings, in a row above the
/// viewfinder. A tap does a button's main thing; touch and hold lists its choices.
struct TopBar: View {
    @Bindable var model: CameraModel
    /// Set to ask the quick settings drawer for its timer sheet.
    @Binding var timerSheetRequested: Bool

    var body: some View {
        let mode = model.settings.mode
        let activity = model.activity
        let isRecording = activity == .recording
        // A focus or white balance bracket is one long capture that reads the settings again for every frame.
        let isHeld = Self.holdsControls(activity) || model.bracketInProgress

        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    FlashButton(model: model, mode: mode)
                    ScheduleBadge(model: model, mode: mode, timerSheetRequested: $timerSheetRequested)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    RawButton(model: model, mode: mode)
                    LivePhotoButton(model: model, mode: mode)
                    VideoFormatChip(model: model, mode: mode)
                    SettingsButton(model: model)
                }
            }
            .opacity(isRecording ? 0 : (isHeld ? 0.35 : 1))
            .allowsHitTesting(!isRecording && !isHeld)
            .accessibilityHidden(isRecording)

            // Outside the row that hides while filming: the light is wanted most once the recording runs. It takes
            // the flash button's place, which VIDEO leaves empty.
            TorchButton(model: model, mode: mode)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isHeld ? 0.35 : 1)
                .allowsHitTesting(!isHeld)

            if isRecording {
                RecordingCapsule(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                DrawerToggle(model: model)
                    .opacity(isHeld ? 0.35 : 1)
                    .allowsHitTesting(!isHeld)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        // Opaque so the quick settings drawer can slide out from underneath.
        .background(Theme.background)
        .animation(Theme.snappy, value: mode)
        .animation(Theme.snappy, value: isRecording)
        .animation(Theme.snappy, value: isHeld)
    }

    /// Countdown, stacks and saving keep the bar visible but inert, so nothing changes under a running shot.
    /// A single photo in flight is short enough that dimming would only flicker.
    private static func holdsControls(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .countdown, .stacking, .saving: return true
        case .idle, .capturing, .recording: return false
        }
    }
}

// MARK: - Touch and hold

/// A button's tap and its touch and hold menu, laid over the button. Its own view with inputs that never change, so
/// the button's redraws with every settings change leave the system's menu button alone.
private struct BarTouchLayer: View {
    enum Control {
        case flash, torch, raw, resolution, frameRate, settings
    }

    let model: CameraModel
    let control: Control
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            switch control {
            case .flash: FlashButton.step(model)
            case .torch: TorchButton.toggle(model)
            case .raw: RawButton.step(model)
            case .resolution: VideoFormatChip.stepResolution(model)
            case .frameRate: VideoFormatChip.stepFrameRate(model)
            case .settings: SettingsButton.open(model)
            }
        } options: {
            switch control {
            case .flash: FlashOptions(model: model)
            case .torch: TorchOptions(model: model)
            case .raw: RawOptions(model: model)
            case .resolution, .frameRate: VideoFormatOptions(model: model)
            case .settings: SettingsButtonOptions(model: model)
            }
        }
    }
}

// MARK: - Buttons

private struct FlashButton: View {
    let model: CameraModel
    let mode: CaptureMode
    @State private var press = PressTracker()

    var body: some View {
        // Stacks and video never fire the flash, so the button only shows where it does something.
        if model.capabilities.hasFlash, mode == .photo || mode == .manual {
            let flash = model.settings.capture.flash
            // A MANUAL shutter past the hardware limit is shot as a stack. Dimmed rather than hidden, so the bar
            // doesn't reshuffle while the shutter dial crosses the limit.
            let stacked = mode == .manual && model.shutterIsStacked
            Button {
                Self.step(model)
            } label: {
                Upright(model: model) {
                    Image(systemName: flash.symbolName)
                }
            }
            .buttonStyle(BarCircleStyle(isActive: flash == .on && !stacked, isPressed: press.isPressed))
            .accessibilityLabel("Flash")
            .accessibilityValue(flash.title)
            .accessibilityHint(stacked ? "Stacked exposures don't use the flash." : "Touch and hold for more options.")
            .overlay {
                BarTouchLayer(model: model, control: .flash, press: press)
            }
            .disabled(stacked)
            .opacity(stacked ? 0.35 : 1)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    fileprivate static func step(_ model: CameraModel) {
        Haptics.tap()
        model.updateSettings { $0.capture.flash = $0.capture.flash.nextInCycle }
    }
}

/// Off, Auto, On: the order the tap steps through.
private struct FlashOptions: View {
    let model: CameraModel

    var body: some View {
        let flash = model.settings.capture.flash
        Picker("Flash", selection: Binding(get: { flash }, set: { choose($0) })) {
            ForEach(FlashSetting.allCases) { setting in
                Label(setting.title, systemImage: setting.symbolName).tag(setting)
            }
        }
        .pickerStyle(.inline)
    }

    private func choose(_ flash: FlashSetting) {
        Haptics.tick()
        model.updateSettings { $0.capture.flash = flash }
    }
}

/// The video light, where the flash button sits in the photo modes. The front camera has none, so it hides there.
private struct TorchButton: View {
    let model: CameraModel
    let mode: CaptureMode
    @State private var press = PressTracker()

    var body: some View {
        if model.capabilities.hasTorch, mode == .video {
            let isOn = model.torchOn
            Button {
                Self.toggle(model)
            } label: {
                Upright(model: model) {
                    Image(systemName: isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                }
            }
            .buttonStyle(BarCircleStyle(isActive: isOn, isPressed: press.isPressed))
            .accessibilityLabel("Flashlight")
            .accessibilityValue(TorchBrightness.current(isOn: isOn, level: model.torchLevel).spokenValue)
            .accessibilityHint("Touch and hold for more options.")
            .overlay {
                BarTouchLayer(model: model, control: .torch, press: press)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    fileprivate static func toggle(_ model: CameraModel) {
        // setTorch plays its own click.
        model.setTorch(!model.torchOn)
    }
}

private struct TorchOptions: View {
    let model: CameraModel

    var body: some View {
        let brightness = TorchBrightness.current(isOn: model.torchOn, level: model.torchLevel)
        Picker("Flashlight", selection: Binding(get: { brightness }, set: { choose($0) })) {
            ForEach(TorchBrightness.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.inline)
    }

    /// The model clicks for both.
    private func choose(_ brightness: TorchBrightness) {
        if let level = brightness.level {
            model.setTorchLevel(level)
        } else {
            model.setTorch(false)
        }
    }
}

/// The flashlight's touch and hold choices.
private enum TorchBrightness: CaseIterable, Identifiable {
    case off, low, medium, full

    var id: Self { self }

    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .full: return "Full"
        }
    }

    /// Torch level, 0...1; nil is off.
    var level: Double? {
        switch self {
        case .off: return nil
        case .low: return 0.25
        case .medium: return 0.6
        case .full: return 1
        }
    }

    var spokenValue: String {
        switch self {
        case .off: return "Off"
        case .low: return "On, low"
        case .medium: return "On, medium"
        case .full: return "On"
        }
    }

    /// The choice closest to what the light is doing.
    static func current(isOn: Bool, level: Double) -> TorchBrightness {
        guard isOn, level.isFinite else { return .off }
        let lit: [TorchBrightness] = [.low, .medium, .full]
        return lit.min(by: { abs(($0.level ?? 0) - level) < abs(($1.level ?? 0) - level) }) ?? .full
    }
}

private struct RawButton: View {
    let model: CameraModel
    let mode: CaptureMode
    @State private var press = PressTracker()

    var body: some View {
        let choices = Self.choices(for: model.capabilities)
        // RAW belongs to single photos; stacks and video write HEIF, JPEG or movies. The simple interface keeps
        // RAW off, so it has no chip for it.
        if model.isAdvanced, choices.count > 1, mode == .photo || mode == .manual {
            let raw = model.settings.capture.rawFormat
            let isOn = raw != RawFormat.none
            // A MANUAL shutter past the hardware limit is shot as a stack, which writes HEIF or JPEG only.
            let stacked = mode == .manual && model.shutterIsStacked
            // The photo output leaves Bayer RAW out of zoomed shots. Still a button, so RAW can be turned off.
            let zoomed = !stacked && isOn && model.rawBlockedByZoom
            Upright(model: model) {
                Button {
                    Self.step(model)
                } label: {
                    Text(raw == .proRAW ? "ProRAW" : "RAW")
                        .strikethrough(!isOn, color: Theme.primaryText)
                }
                .buttonStyle(BarChipStyle(isActive: isOn && !stacked && !zoomed, isPressed: press.isPressed))
            }
            .accessibilityLabel("RAW")
            .accessibilityValue(raw.title)
            .accessibilityHint(Self.hint(stacked: stacked, zoomed: zoomed))
            // Over the chip's level frame, not turned with it: the menu opens from where the chip sits.
            .overlay {
                BarTouchLayer(model: model, control: .raw, press: press)
            }
            .disabled(stacked)
            .opacity(stacked || zoomed ? 0.35 : 1)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    fileprivate static func step(_ model: CameraModel) {
        let choices = choices(for: model.capabilities)
        let index = choices.firstIndex(of: model.settings.capture.rawFormat)
        // Spelled out: a bare .none next to an optional reads as nil.
        let next: RawFormat = index.map { choices[($0 + 1) % choices.count] } ?? RawFormat.none
        Haptics.tap()
        model.updateSettings { $0.capture.rawFormat = next }
    }

    private static func hint(stacked: Bool, zoomed: Bool) -> String {
        if stacked { return "Stacked exposures are saved without RAW." }
        // Each lens's own zoom works, so a telephoto keeps RAW at its button's value and loses it zoomed past that.
        if zoomed { return "RAW needs a lens at its own zoom, such as 1\u{00D7}. Zoomed photos are saved without it." }
        return "Touch and hold for more options."
    }

    fileprivate static func choices(for capabilities: CameraCapabilities) -> [RawFormat] {
        var choices: [RawFormat] = [RawFormat.none]
        if capabilities.rawSupported { choices.append(.bayer) }
        if capabilities.proRAWSupported { choices.append(.proRAW) }
        return choices
    }
}

/// Off, RAW and ProRAW, as far as this camera has them.
private struct RawOptions: View {
    let model: CameraModel

    var body: some View {
        let choices = RawButton.choices(for: model.capabilities)
        let raw = model.settings.capture.rawFormat
        Picker("RAW", selection: Binding(get: { Self.shown(raw, among: choices) }, set: { choose($0) })) {
            ForEach(choices) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.inline)
    }

    private func choose(_ raw: RawFormat) {
        Haptics.tick()
        model.updateSettings { $0.capture.rawFormat = raw }
    }

    /// The row to mark. ProRAW saved on a lens without it is shot as a Bayer DNG, so RAW is the row in use.
    private static func shown(_ raw: RawFormat, among choices: [RawFormat]) -> RawFormat {
        if choices.contains(raw) { return raw }
        return choices.contains(.bayer) ? .bayer : RawFormat.none
    }
}

private struct LivePhotoButton: View {
    let model: CameraModel
    let mode: CaptureMode

    var body: some View {
        if model.capabilities.livePhotoSupported, mode == .photo {
            let capture = model.settings.capture
            // The photo output can't record the movie part while it delivers RAW.
            let blockedByRaw = capture.rawFormat != RawFormat.none
            let isOn = capture.livePhoto && !blockedByRaw
            Button {
                Haptics.tap()
                model.updateSettings { $0.capture.livePhoto.toggle() }
            } label: {
                Upright(model: model) {
                    Image(systemName: isOn ? "livephoto" : "livephoto.slash")
                }
            }
            .buttonStyle(BarCircleStyle(isActive: isOn))
            .disabled(blockedByRaw)
            .opacity(blockedByRaw ? 0.4 : 1)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityLabel("Live Photo")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint(blockedByRaw ? "Turn off RAW to use Live Photos." : "")
        }
    }
}

/// Shows that the next press starts a timer, an intervalometer or a bracket, and opens the drawer to change it.
/// Touch and hold sets the self timer without the drawer.
private struct ScheduleBadge: View {
    let model: CameraModel
    let mode: CaptureMode
    @Binding var timerSheetRequested: Bool
    @State private var press = PressTracker()

    var body: some View {
        let capture = model.settings.capture
        let schedule = capture.schedule
        let isBulb = mode == .long && model.settings.longExposure.bulb
        // A focus bracket is centered on the manual focus distance. Under autofocus it is wherever the lens is at the
        // press, which would move this count while framing and through the bracket, so it counts around the middle.
        let bracketFrames = Self.frameCount(capture.bracket, maxBurst: model.capabilities.maxBracketCount,
                                            focusCenter: model.effectiveFocus.lensPosition ?? 0.5)
        // Video and bulb start on the press itself and stacks ignore brackets, so the badge only shows where it
        // applies. A bracket the photo output can't shoot comes out as a single photo, so it gets no badge either.
        let showsSchedule = !schedule.isOff && mode != .video && !isBulb
        let showsBracket = !capture.bracket.isOff && bracketFrames > 1
            && (mode == .photo || (mode == .manual && !model.shutterIsStacked))
        if showsSchedule || showsBracket {
            // Only the glyphs turn with the phone, as on the strip's chips. The whole chip turned upright would
            // hang out of the bar over the picture and catch taps meant for it.
            Button {
                Self.openDrawer(model)
            } label: {
                HStack(spacing: 6) {
                    if showsSchedule {
                        HStack(spacing: 3) {
                            Upright(model: model) { Image(systemName: "timer") }
                            Text(Self.scheduleLabel(schedule))
                        }
                    }
                    if showsBracket {
                        HStack(spacing: 3) {
                            Upright(model: model) { Image(systemName: "square.stack.3d.up") }
                            Text("\(bracketFrames)")
                        }
                    }
                }
            }
            .buttonStyle(BarChipStyle(isActive: true, isPressed: press.isPressed))
            // The simple interface has the self timer only.
            .accessibilityLabel(model.isAdvanced ? "Timer and brackets" : "Timer")
            .accessibilityValue(Self.accessibilityValue(schedule: showsSchedule ? schedule : nil,
                                                        bracket: showsBracket ? capture.bracket : nil))
            .accessibilityHint("Opens quick settings. Touch and hold for more options.")
            .overlay {
                TimerTouchLayer(model: model, press: press, timerSheetRequested: $timerSheetRequested)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    fileprivate static func openDrawer(_ model: CameraModel) {
        Haptics.tap()
        withAnimation(Theme.spring) { model.isDrawerOpen = true }
    }

    /// "3s" for a timer, "×20" for a burst or an intervalometer. With a bracket beside it, anything longer would
    /// reach the centred chevron on a 375 pt wide phone; the drawer and the timer sheet show the rest.
    private static func scheduleLabel(_ schedule: CaptureSchedule) -> String {
        if schedule.shots > 1 {
            return "\u{00D7}\(schedule.shots)"
        }
        return Formatting.compactDuration(schedule.delay)
    }

    /// The frames the bracket really takes. The photo output caps an exposure bracket at its burst limit and keeps
    /// the count odd so the metered frame stays in the middle; under two frames it takes a single photo. A focus
    /// spread wider than the lens travel piles frames on its ends, so that count depends on the center.
    private static func frameCount(_ bracket: BracketPlan, maxBurst: Int, focusCenter: Double) -> Int {
        switch bracket.kind {
        case .off:
            return 1
        case .exposure:
            let planned = bracket.exposureOffsets().count
            var count = min(planned, max(maxBurst, 1))
            if count < planned && count % 2 == 0 { count -= 1 }
            return max(count, 1)
        case .focus:
            return bracket.focusPositions(center: focusCenter).count
        case .whiteBalance:
            return bracket.kelvinValues(center: 5500).count
        }
    }

    private static func accessibilityValue(schedule: CaptureSchedule?, bracket: BracketPlan?) -> String {
        var parts: [String] = []
        if let schedule { parts.append(schedule.summary) }
        if let bracket { parts.append(bracket.summary) }
        return parts.joined(separator: ", ")
    }
}

/// The badge's tap and its touch and hold menu. Its own view with inputs that never change, like the other buttons'.
private struct TimerTouchLayer: View {
    let model: CameraModel
    let press: PressTracker
    @Binding var timerSheetRequested: Bool

    var body: some View {
        MenuOnHoldLayer(press: press) {
            ScheduleBadge.openDrawer(model)
        } options: {
            TimerBadgeOptions(model: model, timerSheetRequested: $timerSheetRequested)
        }
    }
}

/// The self timer's delays. The simple interface offers the ones its drawer steps through; the advanced one adds
/// the rest and the way into the timer sheet.
private struct TimerBadgeOptions: View {
    let model: CameraModel
    @Binding var timerSheetRequested: Bool

    var body: some View {
        let advanced = model.isAdvanced
        let schedule = model.settings.capture.schedule
        let delays = advanced ? CaptureSchedule.delayPresets : CameraSettings.simpleDelays
        ForEach(delays, id: \.self) { delay in
            // A burst or an intervalometer is none of the plain delays, so no row is marked for it.
            let isCurrent = schedule.shots == 1 && abs(schedule.delay - delay) < 0.01
            Toggle(isOn: Binding(get: { isCurrent }, set: { _ in choose(delay) })) {
                Text(delay > 0 ? Formatting.compactDuration(delay) : "Off")
            }
        }
        if advanced {
            Section {
                Button(action: showSheet) {
                    Label("More\u{2026}", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private func choose(_ delay: Double) {
        Haptics.tick()
        model.updateSettings { $0.capture.schedule = CaptureSchedule(delay: delay) }
    }

    /// The sheet belongs to the drawer, which opens for it and presents it.
    private func showSheet() {
        timerSheetRequested = true
        withAnimation(Theme.spring) { model.isDrawerOpen = true }
    }
}

/// "4K · 30" like the Camera app: tap the resolution or the frame rate to step through what this lens can record.
/// Touch and hold either one lists every size and rate together.
private struct VideoFormatChip: View {
    let model: CameraModel
    let mode: CaptureMode
    @State private var resolutionPress = PressTracker()
    @State private var frameRatePress = PressTracker()

    var body: some View {
        if mode == .video {
            // What this lens records: a lens without the saved 4K 120 shows 4K 60 here, and a tap steps from that.
            let video = model.recordedVideo
            let formats = model.capabilities.formats
            let resolutions = FormatSelector.availableResolutions(colorMode: video.colorMode, among: formats)
            let rates = FormatSelector.availableFrameRates(resolution: video.resolution, colorMode: video.colorMode,
                                                           among: formats)
            // Stays level when the phone turns, like the strip's text chips: turned upright, the chip would hang
            // out of the bar and its two buttons would sit over the picture.
            HStack(spacing: 0) {
                Button {
                    Self.stepResolution(model)
                } label: {
                    Text(video.resolution.title)
                        .padding(.leading, 12)
                        .padding(.trailing, 5)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Video resolution")
                .accessibilityValue(video.resolution.title)
                .accessibilityHint("Touch and hold for more options.")
                // The touch lands on the menu layer, so the plain style's dimming is done by hand.
                .opacity(resolutionPress.isPressed ? 0.5 : 1)
                .overlay {
                    BarTouchLayer(model: model, control: .resolution, press: resolutionPress)
                }
                .disabled(!Self.canStep(resolutions, from: video.resolution, matches: ==))

                Text("\u{00B7}")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)

                Button {
                    Self.stepFrameRate(model)
                } label: {
                    Text(Self.rateLabel(video.frameRate))
                        .padding(.leading, 5)
                        .padding(.trailing, 12)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Frame rate")
                .accessibilityValue(Formatting.frameRate(video.frameRate))
                .accessibilityHint("Touch and hold for more options.")
                .opacity(frameRatePress.isPressed ? 0.5 : 1)
                .overlay {
                    BarTouchLayer(model: model, control: .frameRate, press: frameRatePress)
                }
                .disabled(!Self.canStep(rates, from: video.frameRate, matches: Self.sameRate))
            }
            .buttonStyle(.plain)
            .font(Theme.chipFont)
            .foregroundStyle(Theme.primaryText)
            .background {
                Color.clear
                    .frame(height: 28)
                    .cameraGlass(in: Capsule())
            }
            .contentTransition(.numericText())
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    fileprivate static func stepResolution(_ model: CameraModel) {
        let video = model.recordedVideo
        let formats = model.capabilities.formats
        let resolutions = FormatSelector.availableResolutions(colorMode: video.colorMode, among: formats)
        guard !resolutions.isEmpty else { return }
        let index = resolutions.firstIndex(of: video.resolution)
        // A size this lens can't record steps to the first one it can.
        let next = index.map { resolutions[($0 + 1) % resolutions.count] } ?? resolutions[0]
        guard next != video.resolution else { return }
        // Not every size records at every rate, so the rate moves to the closest one the new size supports. Closest to
        // the saved rate rather than the one shown, so a size that has the saved rate gets it back.
        let rates = FormatSelector.availableFrameRates(resolution: next, colorMode: video.colorMode, among: formats)
        let saved = model.settings.video.frameRate
        let rate = nearest(to: saved, in: rates) ?? saved
        Haptics.tick()
        withAnimation(Theme.snappy) {
            model.updateSettings {
                $0.video.resolution = next
                $0.video.frameRate = rate
            }
        }
    }

    fileprivate static func stepFrameRate(_ model: CameraModel) {
        let video = model.recordedVideo
        let rates = FormatSelector.availableFrameRates(resolution: video.resolution, colorMode: video.colorMode,
                                                       among: model.capabilities.formats)
        guard !rates.isEmpty else { return }
        let index = rates.firstIndex(where: { sameRate($0, video.frameRate) })
        let next = index.map { rates[($0 + 1) % rates.count] } ?? rates[0]
        guard !sameRate(next, video.frameRate) else { return }
        Haptics.tick()
        withAnimation(Theme.snappy) {
            model.updateSettings { $0.video.frameRate = next }
        }
    }

    private static func nearest(to rate: Double, in rates: [Double]) -> Double? {
        rates.min(by: { abs($0 - rate) < abs($1 - rate) })
    }

    /// A tap changes something: there are two or more choices, or the value shown isn't one of them, which the first
    /// choice replaces.
    private static func canStep<Value>(_ choices: [Value], from current: Value, matches: (Value, Value) -> Bool) -> Bool {
        guard let first = choices.first else { return false }
        return choices.count > 1 || !matches(first, current)
    }

    fileprivate static func sameRate(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.01
    }

    /// "30", "29.97": the chip has no room for "fps".
    fileprivate static func rateLabel(_ fps: Double) -> String {
        guard fps.isFinite, fps > 0, fps < 10_000 else { return "-" }
        if abs(fps - fps.rounded()) < 0.01 {
            return "\(Int(fps.rounded()))"
        }
        return String(format: "%.2f", fps)
    }
}

/// Every size this lens records, largest first, with each of its frame rates, such as "4K at 30".
private struct VideoFormatOptions: View {
    let model: CameraModel

    var body: some View {
        // What the lens records, as on the chip, so the marked row is the one in use.
        let video = model.recordedVideo
        let formats = model.capabilities.formats
        let resolutions = FormatSelector.availableResolutions(colorMode: video.colorMode, among: formats)
        ForEach(Array(resolutions.reversed())) { resolution in
            let rates = FormatSelector.availableFrameRates(resolution: resolution, colorMode: video.colorMode,
                                                           among: formats)
            Section {
                ForEach(rates, id: \.self) { rate in
                    let isCurrent = resolution == video.resolution && VideoFormatChip.sameRate(rate, video.frameRate)
                    Toggle(isOn: Binding(get: { isCurrent }, set: { _ in choose(resolution, rate) })) {
                        Text("\(resolution.title) at \(VideoFormatChip.rateLabel(rate))")
                    }
                }
            }
        }
    }

    private func choose(_ resolution: VideoResolution, _ rate: Double) {
        Haptics.tick()
        withAnimation(Theme.snappy) {
            model.updateSettings {
                $0.video.resolution = resolution
                $0.video.frameRate = rate
            }
        }
    }
}

private struct DrawerToggle: View {
    let model: CameraModel

    var body: some View {
        let isOpen = model.isDrawerOpen
        Button {
            Haptics.tap()
            withAnimation(Theme.spring) { model.isDrawerOpen.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .animation(Theme.spring, value: isOpen)
        }
        .buttonStyle(BarCircleStyle(isActive: isOpen))
        .accessibilityLabel(isOpen ? "Hide quick settings" : "Show quick settings")
    }
}

private struct SettingsButton: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        Button {
            Self.open(model)
        } label: {
            Upright(model: model) {
                Image(systemName: "gearshape")
            }
        }
        .buttonStyle(BarCircleStyle(isPressed: press.isPressed))
        .accessibilityLabel("Settings")
        .accessibilityHint("Touch and hold for more options.")
        .overlay {
            BarTouchLayer(model: model, control: .settings, press: press)
        }
    }

    fileprivate static func open(_ model: CameraModel) {
        Haptics.tap()
        model.isDrawerOpen = false
        model.isSettingsPresented = true
    }
}

/// The switch between the simple and the advanced interface, without the trip through Settings.
private struct SettingsButtonOptions: View {
    let model: CameraModel

    var body: some View {
        let advanced = model.isAdvanced
        Toggle(isOn: Binding(get: { advanced }, set: { setAdvanced($0) })) {
            Label("Advanced controls", systemImage: "slider.horizontal.3")
        }
        Button {
            SettingsButton.open(model)
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private func setAdvanced(_ wanted: Bool) {
        Haptics.tap()
        model.setAdvanced(wanted)
        // The model refuses while a shot is running and says so itself.
        guard model.isAdvanced == wanted else { return }
        // The menu is gone by now and the change can be easy to miss, so it is said, and read out by VoiceOver.
        model.showToast(wanted ? "Advanced controls on" : "Advanced controls off", symbol: "slider.horizontal.3")
    }
}

/// Reads the duration on its own, so the four ticks a second while filming redraw only this capsule.
private struct RecordingCapsule: View {
    let model: CameraModel

    var body: some View {
        let seconds = Self.wholeSeconds(model.recordingDuration)
        // Stays level when the phone turns: turned upright, the capsule would hang over the picture being filmed.
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.primaryText)
                .frame(width: 7, height: 7)
            Text(Self.timecode(seconds))
                .font(Theme.valueFont)
                .contentTransition(.numericText(value: Double(seconds)))
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.recording, in: Capsule())
        .animation(Theme.snappy, value: seconds)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue(Self.timecode(seconds))
    }

    /// Clamped before the conversion, because Int(_:) traps on NaN or out of range values.
    private static func wholeSeconds(_ duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int(min(duration, 359_999).rounded(.down))
    }

    /// "00:01:05", the Camera app's recording clock.
    private static func timecode(_ total: Int) -> String {
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        // %ld: Swift's Int is 64 bits wide, which %d (a C int) doesn't promise to read.
        return String(format: "%02ld:%02ld:%02ld", hours, minutes, seconds)
    }
}

// MARK: - Styles and helpers

/// The shared glass circle, with the touch area grown to 44 pt around it.
private struct BarCircleStyle: ButtonStyle {
    var isActive = false
    /// A press on the button's touch and hold layer.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        GlassCircleButtonStyle(size: Theme.controlSize, isActive: isActive, isPressed: isPressed)
            .makeBody(configuration: configuration)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// The shared glass chip, with the touch area grown to 44 pt high.
private struct BarChipStyle: ButtonStyle {
    var isActive = false
    /// A press on the chip's touch and hold layer.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        GlassChipButtonStyle(isActive: isActive, isPressed: isPressed)
            .makeBody(configuration: configuration)
            .padding(.horizontal, 3)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Rotates its content with the phone. Motion is read here so attitude updates redraw single icons, not the bar.
private struct Upright<Content: View>: View {
    let model: CameraModel
    // Built once in init: a stored closure never compares equal, so SwiftUI could never skip this view.
    let content: Content

    init(model: CameraModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content.uprightRotation(model.motion.iconRotationDegrees)
    }
}

private extension FlashSetting {
    /// Off, Auto, On, the Camera app's order.
    var nextInCycle: FlashSetting {
        switch self {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        }
    }
}
