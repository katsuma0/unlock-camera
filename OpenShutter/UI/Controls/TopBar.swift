import SwiftUI
import CameraCore

/// The row over the top of the picture: up to three buttons on the left, the drawer chevron in the middle, up to two
/// on the right and the gear, in seven equal slots on every iPhone. The person picks and orders the buttons in
/// Settings; one that doesn't work in this mode or on this camera steps aside and the next one moves up. A tap does
/// a button's main thing; touch and hold lists its choices.
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
        // The level switch brings buttons in or out, animated like the controls under the viewfinder.
        let advanced = model.isAdvanced
        let layout = model.settings.topBar.layout(
            advanced: advanced, mode: mode,
            wantsBadge: TopBarScheduleBadge.isWanted(model: model, mode: mode),
            isAvailable: { TopBarItemButton.isAvailable($0, model: model, mode: mode) }
        )
        // The right side sits against the gear, where the bar's last buttons have always been.
        let trailingStart = BarSlots.gear - layout.trailing.count

        BarSlots {
            ForEach(Array(layout.leading.enumerated()), id: \.element) { index, item in
                // While filming only the light stays: it is wanted most once the recording runs. It keeps clear of the
                // recording capsule, which spans the middle three slots.
                let stays = item == .flash
                let slot = isRecording && stays ? min(index, BarSlots.recording.lowerBound - 1) : index
                TopBarItemButton(model: model, item: item, mode: mode, timerSheetRequested: $timerSheetRequested)
                    .modifier(SlotPlacement(slots: slot...slot, isHidden: isRecording && !stays, isHeld: isHeld))
            }
            if layout.showsBadge {
                TopBarScheduleBadge(model: model, mode: mode, timerSheetRequested: $timerSheetRequested)
                    .modifier(SlotPlacement(slots: layout.leading.count...layout.leading.count,
                                            isHidden: isRecording, isHeld: isHeld))
            }
            if isRecording {
                RecordingCapsule(model: model)
                    .accessibilitySortPriority(Double(BarSlots.count - BarSlots.recording.lowerBound))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .layoutValue(key: BarSlot.self, value: BarSlots.recording)
            } else {
                DrawerToggle(model: model)
                    .modifier(SlotPlacement(slots: BarSlots.chevron...BarSlots.chevron, isHidden: false,
                                            isHeld: isHeld))
            }
            ForEach(Array(layout.trailing.enumerated()), id: \.element) { index, item in
                let slot = trailingStart + index
                TopBarItemButton(model: model, item: item, mode: mode, timerSheetRequested: $timerSheetRequested)
                    .modifier(SlotPlacement(slots: slot...slot, isHidden: isRecording, isHeld: isHeld))
            }
            // In VIDEO the format takes the right side, which the layout leaves without buttons there.
            if mode == .video {
                VideoFormatChip(model: model)
                    .modifier(SlotPlacement(slots: BarSlots.format, isHidden: isRecording, isHeld: isHeld))
            }
            SettingsButton(model: model)
                .modifier(SlotPlacement(slots: BarSlots.gear...BarSlots.gear, isHidden: isRecording, isHeld: isHeld))
        }
        .frame(maxWidth: .infinity)
        .frame(height: BarSlots.height)
        // No background: at 16:9 the bar sits over the top of the picture, as in Apple's Camera, and the drawer slides
        // out from the clip edge under it. The gaps between buttons still take a stray tap, as the black bar did,
        // so a near miss doesn't move focus on the picture behind.
        .contentShape(Rectangle())
        // VoiceOver reads it left to right: the left side, the chevron, the right side and the gear.
        .accessibilityElement(children: .contain)
        .animation(Theme.snappy, value: layout)
        .animation(Theme.snappy, value: mode)
        .animation(Theme.snappy, value: isRecording)
        .animation(Theme.snappy, value: isHeld)
        .animation(Theme.snappy, value: advanced)
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

// MARK: - Slots

/// Seven equal slots across the bar on every iPhone: three for the left side, the chevron, two for the right side
/// and the gear. The same seven places on every phone keep each button where the thumb expects it, and the narrowest
/// phone still leaves 14 pt between the circles, so neighbours never crowd or overlap.
private struct BarSlots: Layout {
    static let count = 7
    static let chevron = 3
    static let gear = 6
    /// While filming, the red capsule takes the chevron's slot and one on each side of it.
    static let recording = 2...4
    /// VIDEO's format chip, about 90 pt wide, takes both right slots.
    static let format = 4...5
    static let height: CGFloat = 48
    /// From the screen edges, as the bar has always sat.
    static let inset: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Only an unbounded proposal lacks a width; the bar is always offered the screen's.
        let narrowest = CGFloat(Self.count) * 44 + Self.inset * 2
        let width = proposal.width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? narrowest
        return CGSize(width: width, height: Self.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let pitch = max(bounds.width - Self.inset * 2, 0) / CGFloat(Self.count)
        for subview in subviews {
            let span = subview[BarSlot.self]
            let first = min(max(span.lowerBound, 0), Self.count - 1)
            let last = min(max(span.upperBound, first), Self.count - 1)
            let center = bounds.minX + Self.inset + pitch * CGFloat(first + last + 1) / 2
            subview.place(at: CGPoint(x: center, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: pitch * CGFloat(last - first + 1), height: bounds.height))
        }
    }
}

/// The slots a view takes, the first to the last.
private struct BarSlot: LayoutValueKey {
    static let defaultValue: ClosedRange<Int> = 0...0
}

/// Puts a view in its slots, hides it while filming, dims it while a shot runs and orders it for VoiceOver.
private struct SlotPlacement: ViewModifier {
    let slots: ClosedRange<Int>
    /// Hidden while filming: only the light and the recording capsule stay.
    let isHidden: Bool
    /// Countdown, stacks and saving keep the bar visible but inert.
    let isHeld: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isHidden ? 0 : (isHeld ? 0.35 : 1))
            .allowsHitTesting(!isHidden && !isHeld)
            .accessibilityHidden(isHidden)
            .accessibilitySortPriority(Double(BarSlots.count - slots.lowerBound))
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .layoutValue(key: BarSlot.self, value: slots)
    }
}

// MARK: - Touch and hold

/// A control's tap and its touch and hold menu, laid over the control. Its own view with inputs that never change,
/// so the control's redraws with every settings change leave the system's menu button alone.
private struct BarTouchLayer: View {
    enum Control {
        case resolution, frameRate, settings
    }

    let model: CameraModel
    let control: Control
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            switch control {
            case .resolution: VideoFormatChip.stepResolution(model)
            case .frameRate: VideoFormatChip.stepFrameRate(model)
            case .settings: SettingsButton.open(model)
            }
        } options: {
            switch control {
            case .resolution, .frameRate: VideoFormatOptions(model: model)
            case .settings: SettingsButtonOptions(model: model)
            }
        }
    }
}

// MARK: - Furniture

/// "4K · 30" like the Camera app: tap the resolution or the frame rate to step through what this lens can record.
/// Touch and hold either one lists every size and rate together.
private struct VideoFormatChip: View {
    let model: CameraModel
    @State private var resolutionPress = PressTracker()
    @State private var frameRatePress = PressTracker()

    var body: some View {
        // What this lens records: a lens without the saved 4K 120 shows 4K 60 here, and a tap steps from that.
        let video = model.recordedVideo
        let formats = model.capabilities.formats
        let resolutions = FormatSelector.availableResolutions(colorMode: video.colorMode, among: formats)
        let rates = FormatSelector.availableFrameRates(resolution: video.resolution, colorMode: video.colorMode,
                                                       among: formats)
        // Stays level when the phone turns, like the strip's text chips: turned upright, the chip would hang out of
        // the bar and its two buttons would sit over the picture.
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
            .accessibilityHint(HoldMenuText.hint)
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
            .accessibilityHint(HoldMenuText.hint)
            .opacity(frameRatePress.isPressed ? 0.5 : 1)
            .overlay {
                BarTouchLayer(model: model, control: .frameRate, press: frameRatePress)
            }
            .disabled(!Self.canStep(rates, from: video.frameRate, matches: Self.sameRate))
        }
        .buttonStyle(.plain)
        .font(Theme.chipFont)
        // Its two slots hold "1080p · 29.97" on the narrowest phone; with Larger labels the text shrinks to fit them
        // rather than reach the chevron or the gear.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(Theme.primaryText)
        .background {
            Color.clear
                .frame(height: 28)
                .cameraGlass(in: Capsule())
        }
        .contentTransition(.numericText())
        // One unit for the bar's reading order, so both its buttons come before the gear.
        .accessibilityElement(children: .contain)
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
        // With Reduce motion, in the app or in iOS, the chevron switches direction instead of turning over.
        let still = AppearanceStore.shared.reduceMotion
        Button {
            Haptics.tap()
            withAnimation(Theme.spring) { model.isDrawerOpen.toggle() }
        } label: {
            Image(systemName: still && isOpen ? "chevron.up" : "chevron.down")
                .rotationEffect(.degrees(isOpen && !still ? 180 : 0))
                .animation(still ? nil : Theme.spring, value: isOpen)
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
        .accessibilityHint(HoldMenuText.hint)
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
        // Off whenever the model would refuse, like the switch in Settings, so the menu never offers a change that
        // only ends in a warning.
        .disabled(!model.canChangeInterface)
        Button {
            SettingsButton.open(model)
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private func setAdvanced(_ wanted: Bool) {
        Haptics.tap()
        model.setAdvanced(wanted)
        // A shot that starts while the menu is open still makes the model refuse, and it says so itself.
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

/// The shared glass circle, with the touch area grown to 44 pt around it. Every customizable button uses it, so each
/// fills one of the bar's slots exactly.
struct BarCircleStyle: ButtonStyle {
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
