import SwiftUI
import UIKit
import CoreLocation
import CameraCore

// The top bar's customizable buttons, the badge that stands in for a Timer button, and the steps the buttons share
// with the quick settings drawer. The bar redraws with every settings write, 120 a second while a dial turns, so each
// button is its own small view that reads only what it shows.

// MARK: - Buttons

/// One of the buttons the person placed on the top bar, in the slot `TopBarOptions.layout` gives it.
struct TopBarItemButton: View {
    let model: CameraModel
    let item: TopBarItem
    let mode: CaptureMode
    /// The Timer button ends its cycle, and its menu, in the drawer's timer sheet, as the badge's menu does.
    @Binding var timerSheetRequested: Bool

    /// Without `timerSheetRequested`, a Timer button can't reach the timer sheet; the camera's bar always passes it.
    init(model: CameraModel, item: TopBarItem, mode: CaptureMode,
         timerSheetRequested: Binding<Bool> = .constant(false)) {
        self.model = model
        self.item = item
        self.mode = mode
        _timerSheetRequested = timerSheetRequested
    }

    var body: some View {
        switch item {
        case .flash:
            // In VIDEO the flash button works the flashlight, from the same place.
            if mode == .video {
                BarTorch(model: model)
            } else {
                BarFlash(model: model, mode: mode)
            }
        case .livePhoto:
            BarLivePhoto(model: model)
        case .timer:
            BarTimer(model: model, mode: mode, timerSheetRequested: $timerSheetRequested)
        case .aspect:
            BarAspect(model: model)
        case .grid:
            BarGrid(model: model)
        case .level:
            BarSwitch(model: model, item: item, setting: \.display.showLevel)
        case .location:
            BarSwitch(model: model, item: item, setting: \.capture.saveLocation)
        case .quietShutter:
            BarSwitch(model: model, item: item, setting: \.capture.silentShutter)
        case .batterySaver:
            BarSwitch(model: model, item: item, setting: \.display.dimDuringLongShots)
        case .nightDuration:
            BarNightDuration(model: model)
        case .raw:
            BarRaw(model: model, mode: mode)
        case .exposureLock:
            BarExposureLock(model: model)
        case .format:
            BarFormat(model: model)
        case .resolution:
            BarResolution(model: model)
        case .processing:
            BarProcessing(model: model)
        case .histogram:
            BarHistogram(model: model)
        case .zebras:
            BarSwitch(model: model, item: item, setting: \.display.zebras)
        case .peaking:
            BarPeaking(model: model)
        case .falseColor:
            BarSwitch(model: model, item: item, setting: \.display.falseColor)
        case .whiteBalance:
            BarWhiteBalance(model: model)
        case .stabilization:
            BarStabilization(model: model)
        case .sound:
            BarSwitch(model: model, item: item, setting: \.video.audio)
        }
    }

    /// What CameraCore leaves to the app: whether `item` works on this camera with these settings. One that doesn't
    /// steps aside and the next one moves up. Where a button's use comes and goes while a dial turns (a MANUAL shutter
    /// crossing the stacking limit, an exposure value set by hand), it stays and dims instead, so the bar never
    /// reshuffles under the finger.
    static func isAvailable(_ item: TopBarItem, model: CameraModel, mode: CaptureMode) -> Bool {
        let caps = model.capabilities
        switch item {
        case .flash:
            return mode == .video ? caps.hasTorch : caps.hasFlash
        case .livePhoto:
            return caps.livePhotoSupported
        case .timer:
            return QuickActions.timerApplies(model)
        case .quietShutter:
            // The system keeps the sound where the law asks for it, so the button only shows where it works.
            return caps.shutterSoundSuppressionSupported
        case .raw:
            return BarRaw.choices(for: caps).count > 1
        case .format:
            return QuickActions.canChangeFormat(model)
        case .resolution:
            return QuickActions.resolutionChoices(caps).count > 1
        case .processing:
            return QuickActions.processingChoices(maximum: caps.maxProcessing).count > 1
        case .whiteBalance:
            return caps.supportsCustomWhiteBalance
        case .stabilization:
            return BarStabilization.choices(caps).count > 1
        case .aspect, .grid, .level, .location, .batterySaver, .nightDuration, .exposureLock, .histogram, .zebras,
             .peaking, .falseColor, .sound:
            return true
        }
    }
}

// MARK: - Flash and flashlight

private struct BarFlash: View {
    let model: CameraModel
    let mode: CaptureMode
    @State private var press = PressTracker()

    var body: some View {
        let flash = model.settings.capture.flash
        // A MANUAL shutter past the hardware limit is shot as a stack, which never fires the flash. Dimmed rather
        // than hidden, so the bar doesn't reshuffle while the shutter dial crosses the limit.
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
        .accessibilityHint(stacked ? "Stacked exposures don't use the flash." : HoldMenuText.hint)
        .overlay {
            ItemTouchLayer(model: model, control: .flash, press: press)
        }
        .disabled(stacked)
        .opacity(stacked ? 0.35 : 1)
    }

    static func step(_ model: CameraModel) {
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

/// The video light, where the flash button sits in the photo modes. The front camera has none, so it steps aside there.
private struct BarTorch: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
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
        .accessibilityHint(HoldMenuText.hint)
        // The menu layer is hidden from VoiceOver, and the tap only turns the light on or off, so the brightness
        // steps would otherwise be out of reach.
        .accessibilityActions {
            ForEach(TorchBrightness.allCases) { choice in
                Button(choice.title) { Self.choose(choice, model: model) }
            }
        }
        .overlay {
            ItemTouchLayer(model: model, control: .torch, press: press)
        }
    }

    static func toggle(_ model: CameraModel) {
        // setTorch plays its own click.
        model.setTorch(!model.torchOn)
    }

    /// The model clicks for both.
    static func choose(_ brightness: TorchBrightness, model: CameraModel) {
        if let level = brightness.level {
            model.setTorchLevel(level)
        } else {
            model.setTorch(false)
        }
    }
}

private struct TorchOptions: View {
    let model: CameraModel

    var body: some View {
        let brightness = TorchBrightness.current(isOn: model.torchOn, level: model.torchLevel)
        Picker("Flashlight", selection: Binding(get: { brightness }, set: { BarTorch.choose($0, model: model) })) {
            ForEach(TorchBrightness.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.inline)
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

// MARK: - Live Photo and RAW

private struct BarLivePhoto: View {
    let model: CameraModel

    var body: some View {
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
        .accessibilityLabel("Live Photo")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(blockedByRaw ? "Turn off RAW to use Live Photos." : "")
    }
}

private struct BarRaw: View {
    let model: CameraModel
    let mode: CaptureMode
    @State private var press = PressTracker()

    var body: some View {
        let raw = model.settings.capture.rawFormat
        let isOn = raw != RawFormat.none
        // A MANUAL shutter past the hardware limit is shot as a stack, which writes HEIF or JPEG only.
        let stacked = mode == .manual && model.shutterIsStacked
        // The photo output leaves Bayer RAW out of zoomed shots. Still a button, so RAW can be turned off.
        let zoomed = !stacked && isOn && model.rawBlockedByZoom
        Button {
            Self.step(model)
        } label: {
            Upright(model: model) {
                RawFace(isProRAW: raw == .proRAW, isOn: isOn)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: isOn && !stacked && !zoomed, isPressed: press.isPressed))
        .accessibilityLabel("RAW")
        .accessibilityValue(raw.title)
        .accessibilityHint(Self.hint(stacked: stacked, zoomed: zoomed))
        .overlay {
            ItemTouchLayer(model: model, control: .raw, press: press)
        }
        .disabled(stacked)
        .opacity(stacked || zoomed ? 0.35 : 1)
    }

    static func step(_ model: CameraModel) {
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
        return HoldMenuText.hint
    }

    static func choices(for capabilities: CameraCapabilities) -> [RawFormat] {
        var choices: [RawFormat] = [RawFormat.none]
        if capabilities.rawSupported { choices.append(.bayer) }
        if capabilities.proRAWSupported { choices.append(.proRAW) }
        return choices
    }
}

/// "RAW" in the circle, struck through when off; ProRAW adds a small "PRO" line above it.
private struct RawFace: View {
    let isProRAW: Bool
    let isOn: Bool

    var body: some View {
        let scale = Theme.labelScale
        VStack(spacing: -1) {
            if isProRAW {
                Text("PRO")
                    .font(.system(size: 7 * scale, weight: .heavy))
            }
            Text("RAW")
                .font(.system(size: 11 * scale, weight: .heavy))
                .strikethrough(!isOn, color: Theme.primaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 4)
    }
}

/// Off, RAW and ProRAW, as far as this camera has them.
private struct RawOptions: View {
    let model: CameraModel

    var body: some View {
        let choices = BarRaw.choices(for: model.capabilities)
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

// MARK: - Timer

/// Steps the self timer, and in the advanced interface ends the cycle in the timer sheet, like the drawer's item. It
/// also shows an intervalometer or a bracket, because it takes the badge's place on the bar.
private struct BarTimer: View {
    let model: CameraModel
    let mode: CaptureMode
    @Binding var timerSheetRequested: Bool
    @State private var press = PressTracker()
    @State private var cycle = TimerCycle()

    var body: some View {
        let preview = SchedulePreview(model: model, mode: mode)
        Button {
            Self.step(model, cycle: cycle, timerSheetRequested: $timerSheetRequested)
        } label: {
            Upright(model: model) {
                if preview.isEmpty {
                    Image(systemName: "timer")
                } else {
                    ScheduleFace(preview: preview)
                }
            }
        }
        .buttonStyle(BarCircleStyle(isActive: !preview.isEmpty, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.timer.title(advanced: model.isAdvanced))
        .accessibilityValue(preview.spokenValue)
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            TimerItemTouchLayer(model: model, press: press, cycle: cycle, timerSheetRequested: $timerSheetRequested)
        }
        // Any other change of the schedule starts the cycle over, as in the drawer.
        .onChange(of: model.settings.capture.schedule) { _, _ in
            cycle.sheetOffered = false
        }
    }

    static func step(_ model: CameraModel, cycle: TimerCycle, timerSheetRequested: Binding<Bool>) {
        let advanced = model.isAdvanced
        switch QuickActions.timerStep(after: model.settings.capture.schedule,
                                      delays: QuickActions.delays(advanced: advanced),
                                      endsInSheet: advanced, sheetOffered: cycle.sheetOffered) {
        case .schedule(let schedule):
            cycle.sheetOffered = false
            QuickActions.setSchedule(schedule, model)
        case .sheet:
            cycle.sheetOffered = true
            Haptics.tap()
            // The sheet belongs to the drawer, which opens for it and presents it.
            timerSheetRequested.wrappedValue = true
            withAnimation(Theme.spring) { model.isDrawerOpen = true }
        }
    }
}

/// Whether the Timer button's last tap offered the timer sheet, so the next one turns the timer off. A reference, so
/// the button and its touch and hold layer share it, and changing it redraws nothing.
@MainActor
private final class TimerCycle {
    var sheetOffered = false
}

private struct TimerItemTouchLayer: View {
    let model: CameraModel
    let press: PressTracker
    let cycle: TimerCycle
    @Binding var timerSheetRequested: Bool

    var body: some View {
        MenuOnHoldLayer(press: press) {
            BarTimer.step(model, cycle: cycle, timerSheetRequested: $timerSheetRequested)
        } options: {
            TimerOptions(model: model, timerSheetRequested: $timerSheetRequested)
        }
    }
}

/// Shows that the next press starts a timer, an intervalometer or a bracket, in the slot after the left side's
/// buttons, and opens the drawer to change it. Touch and hold sets the self timer without the drawer. A Timer button
/// on the bar shows the same, so the badge stays away while one does.
struct TopBarScheduleBadge: View {
    let model: CameraModel
    let mode: CaptureMode
    @Binding var timerSheetRequested: Bool
    @State private var press = PressTracker()

    /// A timer, an intervalometer or a bracket is set, and it applies in `mode`.
    static func isWanted(model: CameraModel, mode: CaptureMode) -> Bool {
        !SchedulePreview(model: model, mode: mode).isEmpty
    }

    var body: some View {
        let preview = SchedulePreview(model: model, mode: mode)
        Button {
            Self.openDrawer(model)
        } label: {
            Upright(model: model) {
                ScheduleFace(preview: preview)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: true, isPressed: press.isPressed))
        // The simple interface has the self timer only.
        .accessibilityLabel(model.isAdvanced ? "Timer and brackets" : "Timer")
        .accessibilityValue(preview.spokenValue)
        .accessibilityHint("Opens quick settings. " + HoldMenuText.hint)
        .overlay {
            BadgeTouchLayer(model: model, press: press, timerSheetRequested: $timerSheetRequested)
        }
    }

    fileprivate static func openDrawer(_ model: CameraModel) {
        Haptics.tap()
        withAnimation(Theme.spring) { model.isDrawerOpen = true }
    }
}

/// The badge's tap and its touch and hold menu. Its own view with inputs that never change, like the buttons'.
private struct BadgeTouchLayer: View {
    let model: CameraModel
    let press: PressTracker
    @Binding var timerSheetRequested: Bool

    var body: some View {
        MenuOnHoldLayer(press: press) {
            TopBarScheduleBadge.openDrawer(model)
        } options: {
            TimerOptions(model: model, timerSheetRequested: $timerSheetRequested)
        }
    }
}

/// The self timer's delays. The simple interface offers the ones its drawer steps through; the advanced one adds the
/// rest and the way into the timer sheet.
private struct TimerOptions: View {
    let model: CameraModel
    @Binding var timerSheetRequested: Bool

    var body: some View {
        let advanced = model.isAdvanced
        let schedule = model.settings.capture.schedule
        ForEach(QuickActions.delays(advanced: advanced), id: \.self) { delay in
            // A burst or an intervalometer is none of the plain delays, so no row is marked for it.
            let isCurrent = schedule.shots == 1 && abs(schedule.delay - delay) < 0.01
            Toggle(isOn: Binding(get: { isCurrent }, set: { _ in choose(delay) })) {
                // Worded like the other touch and hold menus; the bar itself keeps the compact "3s".
                Text(QuickActions.delayTitle(delay))
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
        QuickActions.setSchedule(CaptureSchedule(delay: delay), model)
    }

    /// The sheet belongs to the drawer, which opens for it and presents it.
    private func showSheet() {
        timerSheetRequested = true
        withAnimation(Theme.spring) { model.isDrawerOpen = true }
    }
}

/// What the next press adds to the photo: a timer or an intervalometer, and a bracket. Video and bulb start on the
/// press itself and stacks ignore brackets, so each shows only where it applies. A bracket the photo output can't
/// shoot comes out as a single photo, so it shows nothing either.
private struct SchedulePreview {
    var schedule: CaptureSchedule?
    var bracket: BracketPlan?
    /// The frames the bracket really takes, while it shows.
    var bracketFrames = 0

    @MainActor
    init(model: CameraModel, mode: CaptureMode) {
        let capture = model.settings.capture
        let isBulb = mode == .long && model.settings.longExposure.bulb
        if !capture.schedule.isOff, mode != .video, !isBulb {
            schedule = capture.schedule
        }
        let singlePhoto = mode == .photo || (mode == .manual && !model.shutterIsStacked)
        guard !capture.bracket.isOff, singlePhoto else { return }
        // A focus bracket is centered on the manual focus distance. Under autofocus it is wherever the lens is at the
        // press, which would move this count while framing and through the bracket, so it counts around the middle.
        let frames = Self.frameCount(capture.bracket, maxBurst: model.capabilities.maxBracketCount,
                                     focusCenter: model.effectiveFocus.lensPosition ?? 0.5)
        if frames > 1 {
            bracket = capture.bracket
            bracketFrames = frames
        }
    }

    var isEmpty: Bool { schedule == nil && bracket == nil }

    var spokenValue: String {
        var parts: [String] = []
        if let schedule { parts.append(schedule.summary) }
        if let bracket { parts.append(bracket.summary) }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }

    /// "3s" for a timer, "×20" for a burst or an intervalometer. The menus and the timer sheet show the rest.
    static func label(_ schedule: CaptureSchedule) -> String {
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
}

/// The badge's and the Timer button's face: "3s" under a timer glyph or the bracket's frame count under a stack
/// glyph, or both on two small rows. A circle has no room for more; VoiceOver and the drawer say the rest.
private struct ScheduleFace: View {
    let preview: SchedulePreview

    var body: some View {
        let scale = Theme.labelScale
        let timer = preview.schedule.map { SchedulePreview.label($0) }
        let frames = preview.bracket == nil ? nil : "\(preview.bracketFrames)"
        Group {
            if let timer, let frames {
                VStack(spacing: 1) {
                    Self.row(symbol: "timer", text: timer, scale: scale)
                    Self.row(symbol: "square.stack.3d.up", text: frames, scale: scale)
                }
            } else if let text = timer ?? frames {
                VStack(spacing: 0) {
                    Image(systemName: timer == nil ? "square.stack.3d.up" : "timer")
                        .font(.system(size: 11, weight: .semibold))
                    Text(text)
                        .font(.system(size: 10 * scale, weight: .bold).monospacedDigit())
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 3)
    }

    private static func row(symbol: String, text: String, scale: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 9.5 * scale, weight: .bold).monospacedDigit())
        }
    }
}

// MARK: - Photo shape, grid and night time

private struct BarAspect: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let aspect = model.settings.capture.aspect
        Button {
            QuickActions.stepAspect(model)
        } label: {
            Upright(model: model) {
                ItemText(aspect.label, size: 11)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: QuickActions.aspectIsActive(aspect), isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.aspect.title(advanced: model.isAdvanced))
        .accessibilityValue(aspect.label)
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            ItemTouchLayer(model: model, control: .aspect, press: press)
        }
    }
}

/// The interface's shapes, a ratio entered in Settings as a row of its own, and in the advanced interface the way to
/// enter one.
private struct AspectOptions: View {
    let model: CameraModel

    var body: some View {
        let advanced = model.isAdvanced
        let presets = QuickActions.aspects(advanced: advanced)
        let aspect = model.settings.capture.aspect
        let isPreset = presets.contains(where: { $0.matches(aspect) })
        Picker("Aspect ratio", selection: Binding(get: { QuickActions.aspectSelection(aspect, among: presets) },
                                                  set: { QuickActions.setAspect($0, model) })) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset)
            }
            if !isPreset {
                Text(aspect.label).tag(aspect)
            }
        }
        .pickerStyle(.inline)
        if advanced {
            Button {
                // Settings holds the side fields; the bar shows the new ratio once it closes.
                model.isSettingsPresented = true
            } label: {
                Label("Custom\u{2026}", systemImage: "slider.horizontal.3")
            }
        }
    }
}

/// The simple interface's grid is on or off, so a tap says it all; the advanced one steps through the styles and
/// lists them on touch and hold.
private struct BarGrid: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let grid = model.settings.display.grid
        let advanced = model.isAdvanced
        let isOn = grid != .off
        Button {
            QuickActions.stepGrid(model)
        } label: {
            Upright(model: model) {
                ItemSymbol.image(.grid)
                    .marksOn(isOn)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: isOn, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.grid.title(advanced: advanced))
        .accessibilityValue(advanced ? grid.title : (isOn ? "On" : "Off"))
        .accessibilityHint(advanced ? HoldMenuText.hint : "")
        .overlay {
            if advanced {
                ItemTouchLayer(model: model, control: .grid, press: press)
            }
        }
    }
}

private struct GridOptions: View {
    let model: CameraModel

    var body: some View {
        let grid = model.settings.display.grid
        Picker("Grid", selection: Binding(get: { grid }, set: { QuickActions.set(\.display.grid, to: $0, model) })) {
            ForEach(GridStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        .pickerStyle(.inline)
    }
}

/// NIGHT's duration without opening its dial: Auto, then the times the night panel's menu offers.
private struct BarNightDuration: View {
    let model: CameraModel
    @State private var press = PressTracker()

    /// Inside the planner's 1 to 30 s, as in the night panel's menu.
    static let durations: [Double] = [3, 5, 10, 15, 30]

    var body: some View {
        let manual = model.settings.night.seconds
        Button {
            Self.step(model)
        } label: {
            Upright(model: model) {
                // The automatic time follows the light; the face says Auto rather than redraw with every reading.
                ItemText(manual.map { Formatting.compactDuration($0) } ?? "Auto", size: 11)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: manual != nil, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.nightDuration.title(advanced: model.isAdvanced))
        .accessibilityValue(manual.map { HoldMenuText.spokenTime($0) } ?? "Auto")
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            ItemTouchLayer(model: model, control: .nightDuration, press: press)
        }
    }

    /// Auto, then each time, then Auto again. A time set on the dial is none of them and steps back to Auto.
    static func step(_ model: CameraModel) {
        let choices: [Double?] = [nil] + durations.map { Optional($0) }
        let current = model.settings.night.seconds
        let index = choices.firstIndex { choice in
            switch (choice, current) {
            case (nil, nil): return true
            case let (choice?, current?): return abs(choice - current) < 0.01
            default: return false
            }
        }
        var next: Double?
        if let index {
            next = choices[(index + 1) % choices.count]
        }
        Haptics.tick()
        model.setNightSeconds(next)
    }
}

private struct NightDurationOptions: View {
    let model: CameraModel

    var body: some View {
        let manual = model.settings.night.seconds
        Section("Duration") {
            HoldMenuChoice("Auto", isOn: manual == nil) {
                model.setNightSeconds(nil)
            }
            ForEach(BarNightDuration.durations, id: \.self) { seconds in
                HoldMenuChoice(HoldMenuText.time(seconds), isOn: manual.map { abs($0 - seconds) < 0.01 } ?? false) {
                    model.setNightSeconds(seconds)
                }
            }
        }
    }
}

// MARK: - Switches

/// A button that turns one setting on or off: level, location tags, quiet shutter, battery saver, zebras, false
/// color and sound.
private struct BarSwitch: View {
    let model: CameraModel
    let item: TopBarItem
    let setting: WritableKeyPath<CameraSettings, Bool>

    var body: some View {
        let isOn = model.settings[keyPath: setting]
        // Sound is on unless turned off, so its button lights while it's off, the state worth seeing.
        let isActive = item == .sound ? !isOn : isOn
        Button {
            Self.toggle(item, setting, model)
        } label: {
            Upright(model: model) {
                Self.glyph(item, isOn: isOn)
                    .marksOn(Self.showsStateByColorOnly(item) && isActive)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: isActive))
        .accessibilityLabel(item.title(advanced: model.isAdvanced))
        .accessibilityValue(isOn ? "On" : "Off")
    }

    @ViewBuilder
    private static func glyph(_ item: TopBarItem, isOn: Bool) -> some View {
        switch item {
        case .location:
            Image(systemName: isOn ? "location.fill" : "location.slash")
        case .quietShutter:
            Image(systemName: isOn ? "speaker.slash" : "speaker.wave.2")
        case .sound:
            Image(systemName: isOn ? "mic" : "mic.slash")
        case .zebras:
            ZebraGlyph()
        default:
            ItemSymbol.image(item)
        }
    }

    /// The glyphs that look the same on and off, so their state shows by color alone.
    private static func showsStateByColorOnly(_ item: TopBarItem) -> Bool {
        switch item {
        case .location, .quietShutter, .sound: return false
        default: return true
        }
    }

    private static func toggle(_ item: TopBarItem, _ setting: WritableKeyPath<CameraSettings, Bool>,
                               _ model: CameraModel) {
        QuickActions.toggle(setting, model)
        let isOn = model.settings[keyPath: setting]
        switch item {
        case .location:
            // Tags that are on while iOS refuses the location would leave photos without a place, and say nothing.
            if isOn, LocationAccess.isDenied {
                model.showToast("Location access is off for Open Shutter, so photos won't include where they were taken.",
                                symbol: "location.slash")
            } else {
                model.showToast(isOn ? "Location tags on" : "Location tags off",
                                symbol: isOn ? "location.fill" : "location.slash")
            }
        case .batterySaver:
            // Nothing on screen changes until a long shot runs, so the tap is confirmed in words.
            model.showToast(isOn ? "Battery saver on" : "Battery saver off", symbol: ItemSymbol.name(item))
        default:
            break
        }
    }
}

/// Whether iOS refuses this app the location, read when a tap turns location tags on.
@MainActor
private enum LocationAccess {
    static var isDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }
}

// MARK: - Advanced: exposure, format and size

/// AE lock, as in the drawer. With every value set by hand there is no auto exposure left to freeze, but a lock that is
/// on can always be turned off.
private struct BarExposureLock: View {
    let model: CameraModel

    var body: some View {
        let locked = model.aeLocked
        let applies = QuickActions.aeLockApplies(model)
        let busy = QuickActions.exposureIsBusy(model.activity)
        Button {
            model.toggleAELock()
        } label: {
            Upright(model: model) {
                Image(systemName: locked && applies ? "lock.fill" : "lock.open")
            }
        }
        .buttonStyle(BarCircleStyle(isActive: locked && applies))
        .disabled(!(applies || locked) || busy)
        // Dimmed rather than hidden: setting a value by hand mustn't move the buttons beside it.
        .opacity(applies || locked ? 1 : 0.35)
        .accessibilityLabel(TopBarItem.exposureLock.title(advanced: true))
        .accessibilityValue(applies ? (locked ? "On" : "Off") : "Manual")
        .accessibilityHint(applies ? "" : "Exposure is already set by hand.")
    }
}

private struct BarFormat: View {
    let model: CameraModel

    var body: some View {
        let format = model.settings.capture.processedFormat
        let value = QuickActions.formatValue(format)
        Button {
            QuickActions.stepFormat(model)
        } label: {
            Upright(model: model) {
                ItemText(value, size: 10)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: format != .heif))
        .accessibilityLabel(TopBarItem.format.title(advanced: true))
        .accessibilityValue(value)
    }
}

private struct BarResolution: View {
    let model: CameraModel

    var body: some View {
        let resolution = model.settings.capture.resolution
        // Dimmed rather than hidden while a MANUAL shutter is stacked, so the bar holds still as the dial turns.
        let applies = QuickActions.resolutionApplies(model)
        Button {
            QuickActions.stepResolution(model)
        } label: {
            Upright(model: model) {
                if let megapixels = resolution.targetMegapixels {
                    ItemText("\(megapixels)", size: 15)
                } else {
                    // Matches the setting's title, Largest.
                    ItemText("MAX", size: 11)
                }
            }
        }
        .buttonStyle(BarCircleStyle(isActive: resolution != .automatic && applies))
        .disabled(!applies)
        .opacity(applies ? 1 : 0.35)
        .accessibilityLabel(TopBarItem.resolution.title(advanced: true))
        .accessibilityValue(resolution.title)
        .accessibilityHint(applies ? "" : "Stacked exposures are built from video frames, which have their own size.")
    }
}

private struct BarProcessing: View {
    let model: CameraModel

    var body: some View {
        // Manual exposure always captures with Minimal so the camera keeps the chosen shutter and ISO.
        let forced = model.isManualExposure
        let shown = forced ? ProcessingLevel.minimal : model.settings.capture.processing
        Button {
            QuickActions.stepProcessing(model)
        } label: {
            Upright(model: model) {
                if let caption = Self.caption(shown) {
                    CaptionedGlyph(glyph: ItemSymbol.image(.processing), caption: caption)
                } else {
                    ItemSymbol.image(.processing)
                }
            }
        }
        .buttonStyle(BarCircleStyle(isActive: shown != .balanced))
        .disabled(forced)
        .opacity(forced ? 0.35 : 1)
        .accessibilityLabel(TopBarItem.processing.title(advanced: true))
        .accessibilityValue(shown.title)
        .accessibilityHint(forced ? "Manual exposure always uses Minimal." : "")
    }

    /// Balanced is where the camera starts, so only the other two need a word.
    private static func caption(_ level: ProcessingLevel) -> String? {
        switch level {
        case .minimal: return "Min"
        case .balanced: return nil
        case .maximum: return "Max"
        }
    }
}

// MARK: - Advanced: viewfinder tools

private struct BarHistogram: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let style = model.settings.display.histogram
        Button {
            QuickActions.stepHistogram(model)
        } label: {
            Upright(model: model) {
                ItemSymbol.image(.histogram)
                    .marksOn(style != .off)
            }
        }
        .buttonStyle(BarCircleStyle(isActive: style != .off, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.histogram.title(advanced: true))
        .accessibilityValue(style.title)
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            ItemTouchLayer(model: model, control: .histogram, press: press)
        }
    }
}

private struct HistogramOptions: View {
    let model: CameraModel

    var body: some View {
        let style = model.settings.display.histogram
        Picker("Histogram", selection: Binding(get: { style },
                                               set: { QuickActions.set(\.display.histogram, to: $0, model) })) {
            ForEach(HistogramStyle.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Peaking that shows only while focusing by hand can't be seen otherwise, so the button says which way it's set.
private struct BarPeaking: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let peaking = model.settings.display.peaking
        Button {
            QuickActions.stepPeaking(model)
        } label: {
            Upright(model: model) {
                if peaking == .off {
                    ItemSymbol.image(.peaking)
                } else {
                    CaptionedGlyph(glyph: ItemSymbol.image(.peaking), caption: QuickActions.peakingValue(peaking))
                }
            }
        }
        .buttonStyle(BarCircleStyle(isActive: peaking != .off, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.peaking.title(advanced: true))
        .accessibilityValue(peaking.title)
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            ItemTouchLayer(model: model, control: .peaking, press: press)
        }
    }
}

private struct PeakingOptions: View {
    let model: CameraModel

    var body: some View {
        let peaking = model.settings.display.peaking
        Picker("Focus peaking", selection: Binding(get: { peaking },
                                                   set: { QuickActions.set(\.display.peaking, to: $0, model) })) {
            ForEach(PeakingMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Auto and the presets, the dial's own; a temperature set on the dial shows as its number.
private struct BarWhiteBalance: View {
    let model: CameraModel
    @State private var press = PressTracker()

    /// What a tap steps through: Auto, then the light a scene is most often lit by. Flash is in the menu, and Candle
    /// sits below the 2000 K the camera can lock to, as on the strip's chip.
    static let steps: [WhiteBalancePreset] = [.auto, .daylight, .cloudy, .shade, .tungsten, .fluorescent]

    var body: some View {
        let holder = ControlHolder.of(.whiteBalance, model: model)
        let running = model.effectiveWhiteBalance
        let preset = Self.personPreset(holder: holder, running: running)
        Button {
            Self.step(model)
        } label: {
            Upright(model: model) {
                if let preset {
                    Image(systemName: preset.symbolName)
                } else if holder == .person, let kelvin = running.kelvinValue {
                    CaptionedGlyph(glyph: ItemSymbol.image(.whiteBalance), caption: Formatting.kelvin(kelvin))
                } else {
                    // The camera's or the scene's own white balance: nothing of the person's to show.
                    ItemSymbol.image(.whiteBalance)
                }
            }
        }
        .buttonStyle(BarCircleStyle(isActive: holder == .person, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.whiteBalance.title(advanced: true))
        .accessibilityValue(Self.spokenValue(holder: holder, preset: preset, running: running, model: model))
        .accessibilityHint(HoldMenuText.hint)
        // The tap steps through the presets; the gray card is only in the menu, which VoiceOver can't open.
        .accessibilityActions {
            Button("From a gray card") { model.setWhiteBalanceFromGrayCard() }
        }
        .overlay {
            ItemTouchLayer(model: model, control: .whiteBalance, press: press)
        }
    }

    /// The person's own preset, counting a dial that lands exactly on a preset's temperature as that preset, as the
    /// dial's preset row does. nil for auto, for a scene's temperature and for any other temperature.
    static func personPreset(holder: ControlHolder, running: WhiteBalanceSetting) -> WhiteBalancePreset? {
        guard holder == .person else { return nil }
        switch running {
        case .auto:
            return nil
        case .preset(let preset):
            return preset == .auto ? nil : preset
        case .kelvin(let kelvin, let tint):
            guard abs(tint) < 0.5 else { return nil }
            return WhiteBalancePreset.allCases.first { preset in
                preset.kelvin.map { abs($0 - kelvin) < 1 } ?? false
            }
        }
    }

    static func step(_ model: CameraModel) {
        let holder = ControlHolder.of(.whiteBalance, model: model)
        // The camera's or a scene's own white balance counts as Auto, the first step.
        let current: WhiteBalancePreset? = holder == .person
            ? personPreset(holder: holder, running: model.effectiveWhiteBalance) : .auto
        let index = current.flatMap { steps.firstIndex(of: $0) }
        // A white balance off the list (Flash, Candle, a temperature from the dial) steps to Auto, like any list.
        let next = index.map { steps[($0 + 1) % steps.count] } ?? steps[0]
        Haptics.tick()
        // Auto answers like the dial's AUTO while a scene holds the temperature.
        let refusal = next == .auto ? ControlHolder.autoRefusal(for: .whiteBalance, model: model) : nil
        model.setWhiteBalance(next == .auto ? .auto : .preset(next))
        if let refusal { model.showToast(refusal) }
    }

    private static func spokenValue(holder: ControlHolder, preset: WhiteBalancePreset?, running: WhiteBalanceSetting,
                                    model: CameraModel) -> String {
        if let preset { return preset.title }
        switch holder {
        case .person: return running.kelvinValue.map { Formatting.kelvin($0) } ?? "Auto"
        case .scene: return ControlHolder.autoTitle(for: .whiteBalance, model: model)
        case .camera: return "Auto"
        }
    }
}

private struct WhiteBalanceOptions: View {
    let model: CameraModel

    /// The dial's own preset row without Auto, which leads the menu.
    private static let presets: [WhiteBalancePreset] = [.daylight, .cloudy, .shade, .tungsten, .fluorescent, .flash]

    var body: some View {
        let holder = ControlHolder.of(.whiteBalance, model: model)
        let chosen = BarWhiteBalance.personPreset(holder: holder, running: model.effectiveWhiteBalance)
        Section(TopBarItem.whiteBalance.title(advanced: true)) {
            HoldMenuChoice(ControlHolder.autoTitle(for: .whiteBalance, model: model), isOn: holder != .person) {
                // Already the camera's or the scene's: giving it back would change nothing.
                if holder == .person { model.setWhiteBalance(.auto) }
            }
            ForEach(Self.presets) { preset in
                HoldMenuChoice(preset.title, icon: Image(systemName: preset.symbolName), isOn: chosen == preset) {
                    model.setWhiteBalance(.preset(preset))
                }
            }
        }
        Section {
            Button {
                model.setWhiteBalanceFromGrayCard()
            } label: {
                Label("From a gray card", systemImage: "eyedropper")
            }
        }
    }
}

// MARK: - Advanced: video

private struct BarStabilization: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let recorded = Self.recorded(model)
        Button {
            Self.step(model)
        } label: {
            Upright(model: model) {
                if let caption = Self.caption(recorded) {
                    CaptionedGlyph(glyph: ItemSymbol.image(.stabilization), caption: caption)
                } else {
                    ItemSymbol.image(.stabilization)
                }
            }
        }
        .buttonStyle(BarCircleStyle(isActive: recorded != .standard, isPressed: press.isPressed))
        .accessibilityLabel(TopBarItem.stabilization.title(advanced: true))
        .accessibilityValue(recorded.title)
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            ItemTouchLayer(model: model, control: .stabilization, press: press)
        }
    }

    /// The modes this format records. Preview optimized runs only on preview connections; a movie gets Standard, so
    /// it would be a second Standard.
    static func choices(_ capabilities: CameraCapabilities) -> [StabilizationChoice] {
        capabilities.stabilizationModes.filter { $0 != .previewOptimized }
    }

    /// The mode the movie gets, which the button shows, as the video panel's chip does: MovieRecorder walks to
    /// milder modes this format supports, and the setting keeps the choice for formats that have it.
    static func recorded(_ model: CameraModel) -> StabilizationChoice {
        let chosen = model.settings.video.stabilization
        let available = choices(model.capabilities)
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

    static func step(_ model: CameraModel) {
        let choices = choices(model.capabilities)
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(of: recorded(model))
        let next = index.map { choices[($0 + 1) % choices.count] } ?? choices[0]
        QuickActions.set(\.video.stabilization, to: next, model)
    }

    /// Standard is where the camera starts, so the others get a short word under the glyph; the menu and VoiceOver
    /// have the full names.
    private static func caption(_ choice: StabilizationChoice) -> String? {
        switch choice {
        case .standard, .previewOptimized: return nil
        case .off: return "Off"
        case .cinematic: return "Cine"
        case .cinematicExtended: return "Ext"
        case .cinematicExtendedEnhanced: return "Enh"
        case .lowLatency: return "Low"
        case .automatic: return "Auto"
        }
    }
}

private struct StabilizationOptions: View {
    let model: CameraModel

    var body: some View {
        let recorded = BarStabilization.recorded(model)
        let choices = BarStabilization.choices(model.capabilities)
        Picker("Stabilization", selection: Binding(get: { recorded },
                                                   set: { QuickActions.set(\.video.stabilization, to: $0, model) })) {
            ForEach(choices.isEmpty ? [recorded] : choices) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.inline)
    }
}

// MARK: - Touch and hold

/// A button's tap and its touch and hold menu, laid over the button. Its own view with inputs that never change, so
/// the button's redraws with every settings change leave the system's menu button alone.
private struct ItemTouchLayer: View {
    enum Control {
        case flash, torch, aspect, grid, nightDuration, raw, histogram, peaking, whiteBalance, stabilization
    }

    let model: CameraModel
    let control: Control
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            switch control {
            case .flash: BarFlash.step(model)
            case .torch: BarTorch.toggle(model)
            case .aspect: QuickActions.stepAspect(model)
            case .grid: QuickActions.stepGrid(model)
            case .nightDuration: BarNightDuration.step(model)
            case .raw: BarRaw.step(model)
            case .histogram: QuickActions.stepHistogram(model)
            case .peaking: QuickActions.stepPeaking(model)
            case .whiteBalance: BarWhiteBalance.step(model)
            case .stabilization: BarStabilization.step(model)
            }
        } options: {
            switch control {
            case .flash: FlashOptions(model: model)
            case .torch: TorchOptions(model: model)
            case .aspect: AspectOptions(model: model)
            case .grid: GridOptions(model: model)
            case .nightDuration: NightDurationOptions(model: model)
            case .raw: RawOptions(model: model)
            case .histogram: HistogramOptions(model: model)
            case .peaking: PeakingOptions(model: model)
            case .whiteBalance: WhiteBalanceOptions(model: model)
            case .stabilization: StabilizationOptions(model: model)
            }
        }
    }
}

// MARK: - Faces

/// A short value as a button's face, sized to stay inside the circle: "16:9", "HEIF", "10s".
private struct ItemText: View {
    let text: String
    let size: CGFloat

    init(_ text: String, size: CGFloat) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * Theme.labelScale, weight: .bold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
    }
}

/// A glyph over a short word, for a button with several values its glyph alone can't tell apart.
private struct CaptionedGlyph: View {
    let glyph: Image
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            glyph
                .font(.system(size: 13, weight: .semibold))
            Text(caption)
                .font(.system(size: 9 * Theme.labelScale, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 3)
    }
}

/// The first of a button's symbol names this iOS has, looked up once per kind of button instead of on every redraw.
@MainActor
private enum ItemSymbol {
    private static var names: [TopBarItem: String] = [:]

    static func name(_ item: TopBarItem) -> String {
        if let name = names[item] { return name }
        let candidates = item.symbolNames
        let name = candidates.first(where: { UIImage(systemName: $0) != nil }) ?? candidates.last ?? "circle"
        names[item] = name
        return name
    }

    static func image(_ item: TopBarItem) -> Image {
        Image(systemName: name(item))
    }
}

/// A dot under a glyph that looks the same on and off, for people who turned on Differentiate Without Color: the
/// accent alone would be the only sign the setting is on.
private struct OnDot: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isOn && differentiateWithoutColor {
                    Circle()
                        .frame(width: 4, height: 4)
                        .offset(y: 7)
                        .accessibilityHidden(true)
                }
            }
    }
}

private extension View {
    func marksOn(_ isOn: Bool) -> some View {
        modifier(OnDot(isOn: isOn))
    }
}

/// Diagonal stripes in a rounded square, the usual zebra symbol; SF Symbols has none. The drawer and the bar both
/// draw it.
struct ZebraGlyph: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let outline = Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3.5)
            var stripes = Path()
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4.5
            }
            context.stroke(outline, with: .foreground, lineWidth: 1.5)
            context.clip(to: outline)
            context.stroke(stripes, with: .foreground, lineWidth: 1.5)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
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

// MARK: - Quick actions

/// What a tap on a quick setting does, for the drawer and the top bar alike, so a button on the bar and its item in
/// the drawer always step the same way through the same values.
@MainActor
enum QuickActions {
    // MARK: Photo shape

    /// The shapes a tap steps through and a menu lists: the simple interface's three, or every preset.
    static func aspects(advanced: Bool) -> [AspectRatio] {
        advanced ? AspectRatio.presets : CameraSettings.simpleAspects
    }

    /// Lit whenever the shape isn't the one a fresh install starts with, so a new phone's bar and drawer start unlit.
    static func aspectIsActive(_ aspect: AspectRatio) -> Bool {
        !aspect.matches(CameraSettings.default.capture.aspect)
    }

    /// The row a menu marks. A saved ratio within half a percent of a preset reads as that preset.
    static func aspectSelection(_ aspect: AspectRatio, among presets: [AspectRatio]) -> AspectRatio {
        presets.first(where: { $0.matches(aspect) }) ?? aspect
    }

    /// Steps through the interface's shapes. A ratio entered in Settings sits after the last one, so the next tap goes
    /// to the first.
    static func stepAspect(_ model: CameraModel) {
        let presets = aspects(advanced: model.isAdvanced)
        guard !presets.isEmpty else { return }
        let current = model.settings.capture.aspect
        let index = presets.firstIndex(where: { $0.matches(current) })
        setAspect(index.map { presets[($0 + 1) % presets.count] } ?? presets[0], model)
    }

    static func setAspect(_ aspect: AspectRatio, _ model: CameraModel) {
        Haptics.tick()
        model.updateSettings { $0.capture.aspect = aspect }
    }

    // MARK: Timer

    /// The self timer's delays: the simple interface's, or every preset.
    static func delays(advanced: Bool) -> [Double] {
        advanced ? CaptureSchedule.delayPresets : CameraSettings.simpleDelays
    }

    /// Video and bulb start on the press itself, so a timer would never run there.
    static func timerApplies(_ model: CameraModel) -> Bool {
        let mode = model.settings.mode
        return mode != .video && !(mode == .long && model.settings.longExposure.bulb)
    }

    /// Where a tap on a timer goes next.
    enum TimerStep {
        case schedule(CaptureSchedule)
        /// The timer sheet, for an intervalometer or a delay the presets don't have.
        case sheet
    }

    /// Off, then each delay, then the timer sheet where the cycle ends there, and Off again. A burst, an
    /// intervalometer or a delay off the list steps back to Off, and so does the tap after the sheet was offered.
    static func timerStep(after schedule: CaptureSchedule, delays: [Double], endsInSheet: Bool,
                          sheetOffered: Bool) -> TimerStep {
        guard schedule.shots == 1,
              let index = delays.firstIndex(where: { abs($0 - schedule.delay) < 0.01 }) else {
            return .schedule(.off)
        }
        if index + 1 < delays.count {
            return .schedule(CaptureSchedule(delay: delays[index + 1]))
        }
        return endsInSheet && !sheetOffered ? .sheet : .schedule(.off)
    }

    static func setSchedule(_ schedule: CaptureSchedule, _ model: CameraModel) {
        Haptics.tick()
        model.updateSettings { $0.capture.schedule = schedule }
    }

    /// A menu row, worded like the other touch and hold menus ("3 s"); the drawer's value and the bar keep "3s".
    static func delayTitle(_ delay: Double) -> String {
        delay > 0 ? HoldMenuText.time(delay) : "Off"
    }

    // MARK: Grid

    /// The simple interface's grid: the rule of thirds or nothing.
    static var simpleGrid: GridStyle {
        CameraSettings.simpleGrids.first(where: { $0 != .off }) ?? .thirds
    }

    /// The advanced interface steps through every grid; the simple one turns its one grid on or off.
    static func stepGrid(_ model: CameraModel) {
        guard !model.isAdvanced else {
            cycle(\.display.grid, through: GridStyle.allCases, model)
            return
        }
        let next = model.settings.display.grid == .off ? simpleGrid : GridStyle.off
        Haptics.tap()
        model.updateSettings { $0.display.grid = next }
    }

    // MARK: Lists and switches

    /// Steps a setting to the value after the current one, wrapping around. A value off the list goes to the first.
    static func cycle<Value: Equatable>(_ keyPath: WritableKeyPath<CameraSettings, Value>, through values: [Value],
                                        _ model: CameraModel) {
        guard !values.isEmpty else { return }
        let index = values.firstIndex(of: model.settings[keyPath: keyPath])
        let next = index.map { values[($0 + 1) % values.count] } ?? values[0]
        Haptics.tick()
        model.updateSettings { $0[keyPath: keyPath] = next }
    }

    /// A menu's pick.
    static func set<Value>(_ keyPath: WritableKeyPath<CameraSettings, Value>, to value: Value, _ model: CameraModel) {
        Haptics.tick()
        model.updateSettings { $0[keyPath: keyPath] = value }
    }

    static func toggle(_ keyPath: WritableKeyPath<CameraSettings, Bool>, _ model: CameraModel) {
        Haptics.tap()
        model.updateSettings { $0[keyPath: keyPath].toggle() }
    }

    static func stepHistogram(_ model: CameraModel) {
        cycle(\.display.histogram, through: HistogramStyle.allCases, model)
    }

    static func stepPeaking(_ model: CameraModel) {
        cycle(\.display.peaking, through: PeakingMode.allCases, model)
    }

    /// "Off", "MF", "On": short enough for the drawer's value line and a word under the bar's glyph.
    static func peakingValue(_ mode: PeakingMode) -> String {
        switch mode {
        case .off: return "Off"
        case .manualFocus: return "MF"
        case .always: return "On"
        }
    }

    // MARK: Format

    static func formatChoices(_ capabilities: CameraCapabilities) -> [ProcessedFormat] {
        capabilities.heifSupported ? [.heif, .jpeg] : [.jpeg]
    }

    /// A camera without HEIF has nothing to step through, unless the setting is one it can't write.
    static func canChangeFormat(_ model: CameraModel) -> Bool {
        let choices = formatChoices(model.capabilities)
        return choices.count > 1 || !choices.contains(model.settings.capture.processedFormat)
    }

    static func stepFormat(_ model: CameraModel) {
        let choices = formatChoices(model.capabilities)
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(of: model.settings.capture.processedFormat)
        let next = index.map { choices[($0 + 1) % choices.count] } ?? choices[0]
        Haptics.tick()
        model.updateSettings { $0.capture.processedFormat = next }
    }

    /// RAW alone has no processed format, so the value names what is saved.
    static func formatValue(_ format: ProcessedFormat) -> String {
        format == ProcessedFormat.none ? "RAW" : format.title
    }

    // MARK: Resolution

    /// Sizes this camera can shoot. A size counts when one of the lens's photo dimensions is within 20% of it,
    /// because sensors sold as 48 MP deliver 48.8 MP and 12 MP ones 12.2 MP.
    static func resolutionChoices(_ capabilities: CameraCapabilities) -> [PhotoResolution] {
        var choices: [PhotoResolution] = [.automatic]
        for option in [PhotoResolution.mp12, .mp24, .mp48] {
            guard let target = option.targetMegapixels, target > 0 else { continue }
            let wanted = Double(target)
            let available = capabilities.photoDimensions.contains { size in
                let megapixels = Double(size.width) * Double(size.height) / 1_000_000
                return abs(megapixels - wanted) / wanted < 0.2
            }
            if available { choices.append(option) }
        }
        return choices
    }

    /// Single photos only: stacks are merged from video frames, so a MANUAL shutter past the hardware limit ignores
    /// the size too.
    static func resolutionApplies(_ model: CameraModel) -> Bool {
        let mode = model.settings.mode
        return mode == .photo || (mode == .manual && !model.shutterIsStacked)
    }

    static func stepResolution(_ model: CameraModel) {
        let choices = resolutionChoices(model.capabilities)
        let index = choices.firstIndex(of: model.settings.capture.resolution)
        let next = index.map { choices[($0 + 1) % choices.count] } ?? .automatic
        Haptics.tick()
        model.updateSettings { $0.capture.resolution = next }
    }

    // MARK: Processing

    /// Levels up to what the camera reports; asking for more would only be clamped by the model.
    static func processingChoices(maximum: ProcessingLevel) -> [ProcessingLevel] {
        let order: [ProcessingLevel] = [.minimal, .balanced, .maximum]
        guard let limit = order.firstIndex(of: maximum) else { return order }
        return Array(order[...limit])
    }

    static func stepProcessing(_ model: CameraModel) {
        let choices = processingChoices(maximum: model.capabilities.maxProcessing)
        let index = choices.firstIndex(of: model.settings.capture.processing)
        let next = index.map { choices[($0 + 1) % choices.count] } ?? .balanced
        Haptics.tick()
        model.updateSettings { $0.capture.processing = next }
    }

    // MARK: Exposure lock

    /// When the model honours AE lock: only while auto exposure owns every value. LONG's Blur and Trails meter
    /// each frame, so the lock holds there too as long as ISO and aperture are auto.
    static func aeLockApplies(_ model: CameraModel) -> Bool {
        switch model.settings.mode {
        case .photo, .night:
            return true
        case .manual, .video:
            return !model.isManualExposure
        case .long:
            // A fixed Blur or Trails frame shutter leaves no auto exposure to freeze, as in the strip's AE-L chip.
            return model.settings.longExposure.blend != .additive && model.settings.longExposure.frameSeconds == nil
                && model.isISOAuto && model.isApertureAuto
        }
    }

    /// A change of exposure in the middle of a shot or a stack would end up in the picture.
    static func exposureIsBusy(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .capturing, .stacking, .saving: return true
        case .idle, .countdown, .recording: return false
        }
    }
}
