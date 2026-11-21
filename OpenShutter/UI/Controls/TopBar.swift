import SwiftUI
import CameraCore

/// The row over the top of the picture: flash, shape, timer, format, histogram, AE lock, Live Photo and the gear,
/// always in the same eight slots, as plain glyphs with nothing behind them, like Apple's Camera. NIGHT has no
/// histogram, so its slot holds the steady sign's switch. One that has nothing to do in a mode dims in its place and
/// never steps aside, so each stays where the thumb expects it. A tap on a button with choices lists them, the current
/// one checked. Live Photo, AE lock and the steady sign switch on a tap, and the gear opens Settings.
/// VIDEO's flashlight switches on a tap too, and lists its brightness on touch and hold.
struct TopBar: View {
    @Bindable var model: CameraModel
    /// Set to show the timer sheet, which the camera screen presents.
    @Binding var timerSheetRequested: Bool
    /// Where Settings zooms out of, the gear, with the camera screen's namespace; nil leaves the plain sheet.
    var settingsZoom: Namespace.ID? = nil

    /// Left to right. The gear takes the eighth slot. NIGHT has no histogram: the steady sign's switch takes its place,
    /// so the two cross-fade when the mode changes.
    private static func items(in mode: CaptureMode) -> [TopBarItem] {
        [.flash, .aspect, .timer, .format, mode.hasHistogram ? .histogram : .steadySign, .exposureLock, .livePhoto]
    }

    var body: some View {
        let mode = model.settings.mode
        let activity = model.activity
        let isRecording = activity == .recording
        // A focus or white balance bracket is one long capture that reads the settings again for every frame, and an
        // intervalometer is idle between its shots, when a new aspect or format would split the sequence in two.
        let isHeld = Self.holdsControls(activity) || model.bracketInProgress || model.intervalometer != nil

        BarSlots {
            ForEach(Array(Self.items(in: mode).enumerated()), id: \.element) { index, item in
                if mode == .video, item == .format {
                    // VIDEO's format is the size and the frame rate, which need the timer's slot as well.
                    VideoFormatChip(model: model)
                        .modifier(SlotPlacement(slots: BarSlots.format, isHidden: isRecording, isHeld: isHeld))
                } else if !(mode == .video && item == .timer) {
                    let applies = item.applies(in: mode) && TopBarItemButton.isAvailable(item, model: model, mode: mode)
                    // While filming only the light stays: it is wanted most once the recording runs.
                    let stays = item == .flash
                    TopBarItemButton(model: model, item: item, mode: mode, timerSheetRequested: $timerSheetRequested)
                        .disabled(!applies)
                        .opacity(applies ? 1 : Theme.Dim.off)
                        .modifier(SlotPlacement(slots: index...index, isHidden: isRecording && !stays, isHeld: isHeld))
                }
            }
            if isRecording {
                RecordingCapsule(model: model)
                    .accessibilitySortPriority(Double(BarSlots.count - BarSlots.recording.lowerBound))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .layoutValue(key: BarSlot.self, value: BarSlots.recording)
            }
            SettingsButton(model: model, zoom: settingsZoom)
                .modifier(SlotPlacement(slots: BarSlots.gear...BarSlots.gear, isHidden: isRecording, isHeld: isHeld))
        }
        .frame(maxWidth: .infinity)
        .frame(height: BarSlots.height)
        // No background: the bar sits over the top of the picture, as in Apple's Camera. The gaps between buttons
        // still take a stray tap, so a near miss doesn't move focus on the picture behind.
        .contentShape(Rectangle())
        // VoiceOver reads it left to right.
        .accessibilityElement(children: .contain)
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

// MARK: - Slots

/// Eight equal slots across the bar on every iPhone: seven buttons and the gear. The same eight places on every phone
/// keep each button where the thumb expects it, and the narrowest phone still gives each a 44 pt touch area (45 pt
/// at 375 pt wide), so neighbours never overlap.
private struct BarSlots: Layout {
    static let count = 8
    static let gear = 7
    /// While filming, the red capsule takes the middle four slots.
    static let recording = 2...5
    /// VIDEO's format chip, about 90 pt wide, takes the timer's slot and its own.
    static let format = 2...3
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
    /// Countdown, stacks, saving, brackets and intervalometers keep the bar visible but inert.
    let isHeld: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isHidden ? 0 : (isHeld ? Theme.Dim.held : 1))
            .allowsHitTesting(!isHidden && !isHeld)
            // Hit testing only stops touches: VoiceOver opens a menu without one. Disabled as well, so a held bar
            // opens nothing; the look stays the one set above.
            .disabled(isHeld)
            .accessibilityHidden(isHidden)
            .accessibilitySortPriority(Double(BarSlots.count - slots.lowerBound))
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .layoutValue(key: BarSlot.self, value: slots)
    }
}

// MARK: - Menus

/// One half of VIDEO's chip as a menu, laid over its text. Its own view with inputs that compare equal between
/// redraws, so the chip's redraws with every settings change leave the system's menu button alone.
private struct ChipMenuLayer: View {
    enum Control {
        case resolution, frameRate
    }

    let model: CameraModel
    let control: Control
    let press: PressTracker
    let label: String
    let value: String

    var body: some View {
        MenuOnTapLayer(press: press, label: label, value: value) {
            switch control {
            case .resolution: VideoResolutionOptions(model: model)
            case .frameRate: VideoFrameRateOptions(model: model)
            }
        }
    }
}

// MARK: - Furniture

/// "4K · 30" like the Camera app: a tap on the resolution lists the sizes this lens records, a tap on the frame rate
/// the rates of the size in use.
private struct VideoFormatChip: View {
    let model: CameraModel
    @State private var resolutionPress = PressTracker()
    @State private var frameRatePress = PressTracker()

    var body: some View {
        // What this lens records: a lens without the saved 4K 120 shows 4K 60 here, and its menu marks that.
        let video = model.recordedVideo
        let formats = model.capabilities.formats
        let resolutions = FormatSelector.availableResolutions(colorMode: video.colorMode, among: formats)
        let rates = FormatSelector.availableFrameRates(resolution: video.resolution, colorMode: video.colorMode,
                                                       among: formats)
        // Stays level when the phone turns, like the strip's text chips: turned upright, the chip would hang out of
        // the bar and its two menus would sit over the picture.
        HStack(spacing: 0) {
            Text(video.resolution.title)
                .padding(.leading, 12)
                .padding(.trailing, 5)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
                // The touch lands on the menu layer, so the press dimming is done by hand.
                .opacity(resolutionPress.isPressed ? 0.5 : 1)
                // The menu over the text is what VoiceOver reads and opens.
                .accessibilityHidden(true)
                .overlay {
                    ChipMenuLayer(model: model, control: .resolution, press: resolutionPress,
                                  label: "Video resolution", value: video.resolution.title)
                }
                .disabled(!Self.canChoose(resolutions, from: video.resolution, matches: ==))

            Text("\u{00B7}")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)

            Text(Self.rateLabel(video.frameRate))
                .padding(.leading, 5)
                .padding(.trailing, 12)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(frameRatePress.isPressed ? 0.5 : 1)
                .accessibilityHidden(true)
                .overlay {
                    ChipMenuLayer(model: model, control: .frameRate, press: frameRatePress,
                                  label: "Frame rate", value: Formatting.frameRate(video.frameRate))
                }
                .disabled(!Self.canChoose(rates, from: video.frameRate, matches: Self.sameRate))
        }
        // Medium, like the other text in the bar: the bare glyphs beside it are drawn in thin lines.
        .font(Theme.chipFont.weight(.medium))
        // Its two slots hold "1080p · 29.97" on the narrowest phone; with Larger labels the text shrinks to fit them
        // rather than reach its neighbours.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(Theme.primaryText)
        // Bare like the glyphs beside it, with their shadow to read over a bright picture.
        .legibleShadow()
        .background {
            SolidBacking(shape: Capsule(), height: Theme.chipHeight)
        }
        .contentTransition(.numericText())
        // One unit for the bar's reading order, so both its menus come before the gear.
        .accessibilityElement(children: .contain)
    }

    /// A menu's pick, which ticks by itself. Not every size records at every rate, so the rate moves to the closest
    /// one the new size supports. Closest to the saved rate rather than the one shown, so a size that has the saved
    /// rate gets it back.
    fileprivate static func choose(resolution: VideoResolution, _ model: CameraModel) {
        let video = model.recordedVideo
        guard resolution != video.resolution else { return }
        let rates = FormatSelector.availableFrameRates(resolution: resolution, colorMode: video.colorMode,
                                                       among: model.capabilities.formats)
        let saved = model.settings.video.frameRate
        let rate = nearest(to: saved, in: rates) ?? saved
        withAnimation(Theme.snappy) {
            model.updateSettings {
                $0.video.resolution = resolution
                $0.video.frameRate = rate
            }
        }
    }

    /// A menu's pick, which ticks by itself.
    fileprivate static func choose(frameRate: Double, _ model: CameraModel) {
        guard !sameRate(frameRate, model.recordedVideo.frameRate) else { return }
        withAnimation(Theme.snappy) {
            model.updateSettings { $0.video.frameRate = frameRate }
        }
    }

    private static func nearest(to rate: Double, in rates: [Double]) -> Double? {
        rates.min(by: { abs($0 - rate) < abs($1 - rate) })
    }

    /// A menu has something to offer: two or more choices, or a value shown that isn't one of them, which the
    /// choice replaces.
    private static func canChoose<Value>(_ choices: [Value], from current: Value,
                                         matches: (Value, Value) -> Bool) -> Bool {
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

/// Every size this lens records in the color in use, largest first. Two short menus instead of one list of every
/// size at every rate, which ran to about fifteen rows on a Pro.
private struct VideoResolutionOptions: View {
    let model: CameraModel

    var body: some View {
        // What the lens records, as on the chip, so the marked row is the one in use.
        let video = model.recordedVideo
        let resolutions = FormatSelector.availableResolutions(colorMode: video.colorMode,
                                                              among: model.capabilities.formats)
        ForEach(Array(resolutions.reversed())) { resolution in
            HoldMenuChoice(resolution.title, isOn: resolution == video.resolution) {
                VideoFormatChip.choose(resolution: resolution, model)
            }
        }
    }
}

/// The frame rates of the size in use, such as "30 fps".
private struct VideoFrameRateOptions: View {
    let model: CameraModel

    var body: some View {
        let video = model.recordedVideo
        let rates = FormatSelector.availableFrameRates(resolution: video.resolution, colorMode: video.colorMode,
                                                       among: model.capabilities.formats)
        ForEach(rates, id: \.self) { rate in
            HoldMenuChoice(Formatting.frameRate(rate), isOn: VideoFormatChip.sameRate(rate, video.frameRate)) {
                VideoFormatChip.choose(frameRate: rate, model)
            }
        }
    }
}

private struct SettingsButton: View {
    let model: CameraModel
    let zoom: Namespace.ID?

    var body: some View {
        Button {
            Haptics.tap()
            model.isDrawerOpen = false
            model.isSettingsPresented = true
        } label: {
            Upright(model: model) {
                Image(systemName: "gearshape")
            }
        }
        .buttonStyle(BarCircleStyle())
        .accessibilityLabel("Settings")
        .settingsZoomSource(zoom)
    }
}

/// The id Settings' zoom transition and the gear share.
enum SettingsZoom {
    static let id = "settings"
}

extension View {
    /// Marks the gear as where Settings zooms from. Marked whatever Reduce Motion says: a sheet that opened with
    /// the zoom still needs its gear to shrink back into after the switch is turned on inside it, and a plain
    /// sheet just leaves the mark unused.
    @MainActor
    @ViewBuilder
    func settingsZoomSource(_ namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: SettingsZoom.id, in: namespace)
        } else {
            self
        }
    }

    /// Settings grows out of the gear and back into it. Reduce Motion keeps the plain sheet.
    @MainActor
    @ViewBuilder
    func settingsZoomTransition(_ namespace: Namespace.ID?) -> some View {
        if let namespace {
            modifier(SettingsZoomTransition(namespace: namespace))
        } else {
            self
        }
    }
}

/// Decides zoom or plain once, as the sheet opens. Read live, the Reduce Motion switch on Settings' own
/// Accessibility page would swap the branch under the open sheet, which rebuilds Settings and drops it back to
/// its first page.
private struct SettingsZoomTransition: ViewModifier {
    let namespace: Namespace.ID
    @State private var zooms = !AppearanceStore.shared.reduceMotion

    func body(content: Content) -> some View {
        if zooms {
            content.navigationTransition(.zoom(sourceID: SettingsZoom.id, in: namespace))
        } else {
            content
        }
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
                // Medium, like the rest of the bar's text.
                .font(Theme.valueFont.weight(.medium))
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

/// The style of a bar button a tap switches: Live Photo, AE lock, the gear and VIDEO's flashlight. It draws
/// BarGlyphLook, which the buttons whose tap lists their choices wear on a plain face. The name is from when each
/// sat in a glass circle.
struct BarCircleStyle: ButtonStyle {
    var isActive = false
    /// A press on the button's touch and hold layer.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(BarGlyphLook(isActive: isActive, isPressed: configuration.isPressed || isPressed))
    }
}

/// A bar button's look: the glyph alone in a 44 pt touch area, white, or the accent while its setting is on. No
/// circle behind it, as in Apple's Camera, so it carries a shadow to read over a bright picture. Regular weight:
/// without a circle around them, heavier lines made the row look bold. With Solid buttons the dark circle is back.
/// A button whose tap lists its choices is no Button, as its tap has nothing else to do: it wears this on a plain
/// face, under the MenuOnTapLayer that takes its touches and tells it when it is pressed.
struct BarGlyphLook: ViewModifier {
    var isActive = false
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 18 * Theme.labelScale, weight: .regular))
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .legibleShadow()
            .accentGlow(isActive)
            .frame(width: 44, height: 44)
            .background {
                SolidBacking(shape: Circle(), width: Theme.controlSize, height: Theme.controlSize)
            }
            .scaleEffect(isPressed ? 0.86 : 1)
            .opacity(isPressed ? 0.7 : 1)
            .animation(Theme.snappy, value: isPressed)
            .contentShape(Rectangle())
    }
}

/// The dark backing Solid buttons puts behind a bar button, which is bare without it: the same fill and hairline as
/// every other control then has. Its own view, so it reads the option itself and comes or goes when the switch does.
private struct SolidBacking<S: Shape>: View {
    let shape: S
    /// nil takes the width of the control it sits behind.
    var width: CGFloat? = nil
    let height: CGFloat

    var body: some View {
        if AppearanceStore.shared.solidControls {
            Color.clear
                .frame(width: width, height: height)
                .cameraGlass(in: shape)
        }
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
