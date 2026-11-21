import SwiftUI
import CameraCore

/// Glass panel under the top bar with the settings people change between shots that the bar itself has no room for.
/// The dots button beside the shutter opens it. A tap on an item with choices lists them, as a tap on the bar's
/// buttons does, so none is stepped through to reach the one wanted. An item that is on or off switches on a tap, and
/// Resolution's tap takes the other of its two sizes. The photo's shape, the grid and the level are in Settings: they
/// are set once, not between shots.
struct QuickSettingsDrawer: View {
    @Bindable var model: CameraModel
    /// Set to show the timer sheet, which the camera screen presents.
    @Binding var timerSheetRequested: Bool

    var body: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 2, verticalSpacing: 12) {
                GridRow {
                    TimerItem(model: model, timerSheetRequested: $timerSheetRequested)
                    formatItem
                    rawItem
                    resolutionItem
                }
                GridRow {
                    processingItem
                    // AE lock, which had this place, is on the top bar.
                    SetupsItem(model: model)
                    silentItem
                    batterySaverItem
                }
                GridRow {
                    histogramItem
                    zebraItem
                    peakingItem
                    falseColorItem
                }
            }
            Capsule()
                .fill(Theme.tertiaryText)
                .frame(width: 36, height: 4)
                .accessibilityHidden(true)
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        // Offered the viewfinder's height by its container; the panel is only as tall as its rows.
        .fixedSize(horizontal: false, vertical: true)
        .cameraGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 8)
        // Swiping the panel back up closes it, the way it came.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -24 {
                        close()
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick settings")
        .accessibilityAction(.escape) { close() }
    }

    private func close() {
        withAnimation(Theme.spring) { model.isDrawerOpen = false }
    }

    // MARK: - Capture

    private var formatItem: some View {
        // The format set, or HEIF in place of RAW only in a stack, which saves a HEIF there.
        let shown = QuickActions.shownFormat(model)
        // Stacks save all six formats too, so only video turns this off.
        return DrawerMenuItem(model: model, control: .format, title: "Format", value: shown.title,
                              isActive: shown != .heif, isEnabled: model.settings.mode != .video) {
            FormatGlyph(choice: shown)
        }
    }

    private var resolutionItem: some View {
        let resolution = model.settings.capture.resolution
        // 12 MP or 48 MP: a saved 24 MP is taken as 12 MP, and Largest as 48 MP.
        let shown = resolution.shownAs
        let applies = QuickActions.resolutionApplies(model)
        let stacked = QuickActions.isStacked(model)
        let sizes = model.capabilities.photoDimensions
        var value = shown.title
        var hint: String? = nil
        if !applies && stacked {
            hint = QuickActions.stackedPhotos(model.settings.mode) + " are 12 MP."
        } else if applies, let instead = QuickActions.sizeInstead(resolution, sizes: sizes) {
            // A lens without that size, such as the selfie camera, takes another, and the item says which, as the
            // Format menu's row does. The glyph keeps the setting, so a tap still visibly steps.
            value = instead + " here"
            hint = QuickActions.sizeDetail(resolution, sizes: sizes).map { $0 + "." }
        }
        return DrawerButtonItem(model: model, title: "Resolution", value: value, spokenValue: shown.title,
                                // Lit away from a fresh install's size, as the shape is on the bar.
                                isActive: shown != CameraSettings.default.capture.resolution.shownAs,
                                isEnabled: applies, hint: hint) {
            QuickActions.stepResolution(model)
        } glyph: {
            Text(shown.targetMegapixels.map { "\($0)" } ?? shown.title)
                .font(.system(size: 15 * Theme.labelScale, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var rawItem: some View {
        let raw = model.settings.capture.rawFormat
        let mode = model.settings.mode
        let choices = QuickActions.rawChoices(model.capabilities)
        let applies = mode == .photo || mode == .manual
        let isOn = raw != RawFormat.none
        // A MANUAL shutter past the hardware limit is shot as a stack, which saves no RAW.
        let stacked = mode == .manual && model.shutterIsStacked
        // The photo output leaves Bayer RAW out of zoomed shots, macro's among them. The menu still opens, so RAW can
        // be turned off.
        let zoomed = applies && !stacked && isOn && model.rawBlockedByZoom
        var value = raw.title
        var hint: String? = nil
        if stacked {
            value = "Not in stacks"
            hint = "Stacked exposures are saved without RAW."
        } else if zoomed, model.isMacro {
            // Macro keeps the 1x button lit, so "this zoom" would point at a lens that isn't the one running.
            value = "Not in macro"
            hint = "Macro photos are saved without RAW."
        } else if zoomed {
            value = "Not at this zoom"
            hint = "RAW needs a lens at its own zoom, such as 1\u{00D7}. Zoomed photos are saved without it."
        }
        return DrawerMenuItem(model: model, control: .raw, title: "RAW", value: value,
                              isActive: isOn && !stacked && !zoomed,
                              isEnabled: applies && !stacked && choices.count > 1,
                              hint: hint) {
            Text("RAW")
                .font(.system(size: 10 * Theme.labelScale, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
    }

    // MARK: - Exposure

    private var processingItem: some View {
        let setting = model.settings.capture.processing
        let choices = QuickActions.processingChoices(maximum: model.capabilities.maxProcessing)
        let mode = model.settings.mode
        // Manual exposure always captures with Minimal so the camera keeps the chosen shutter and ISO.
        let forcedMinimal = model.isManualExposure
        let shown = forcedMinimal ? ProcessingLevel.minimal : setting
        return DrawerMenuItem(model: model, control: .processing, title: "Processing", value: shown.title,
                              isActive: shown != .balanced,
                              isEnabled: (mode == .photo || mode == .manual) && !forcedMinimal && choices.count > 1,
                              hint: forcedMinimal ? "Manual exposure always uses Minimal." : nil) {
            Image(systemName: "wand.and.stars")
        }
    }

    private var silentItem: some View {
        let isOn = model.settings.capture.silentShutter
        let mode = model.settings.mode
        // The system keeps the sound where the law asks for it, so the item only works where the camera allows it.
        let supported = model.capabilities.shutterSoundSuppressionSupported
        // Settings calls it Silent shutter. The column has room for the first word; VoiceOver says both.
        return DrawerButtonItem(model: model, title: "Silent", spokenTitle: "Silent shutter",
                                value: isOn ? "On" : "Off", isActive: isOn && supported,
                                isEnabled: supported && (mode == .photo || mode == .manual),
                                hint: supported ? nil : "This camera always plays the shutter sound.") {
            QuickActions.toggle(\.capture.silentShutter, model)
        } glyph: {
            Image(systemName: isOn ? "speaker.slash.fill" : "speaker.wave.2.fill")
                // QuickActions.toggle animates the write, so the speaker changes over as iOS's own toggles do.
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var batterySaverItem: some View {
        let isOn = model.settings.display.dimDuringLongShots
        return DrawerButtonItem(model: model, title: "Battery saver", value: isOn ? "On" : "Off", isActive: isOn,
                                hint: "Darkens the screen during long shots.") {
            QuickActions.toggle(\.display.dimDuringLongShots, model)
        } glyph: {
            Image(systemName: "battery.75percent")
        }
    }

    // MARK: - Viewfinder

    private var histogramItem: some View {
        let style = model.settings.display.histogram
        // NIGHT's photos are merged from many frames, so it shows none. The setting waits for the other modes.
        let available = model.settings.mode.hasHistogram
        return DrawerMenuItem(model: model, control: .histogram, title: "Histogram",
                              value: available ? style.title : "Not in Night",
                              isActive: available && style != .off, isEnabled: available,
                              hint: available ? nil : "Night mode shows no histogram.") {
            Image(systemName: "chart.bar.fill")
        }
    }

    private var zebraItem: some View {
        let isOn = model.settings.display.zebras
        return DrawerButtonItem(model: model, title: "Zebras", value: isOn ? "On" : "Off", isActive: isOn) {
            QuickActions.toggle(\.display.zebras, model)
        } glyph: {
            ZebraGlyph()
        }
    }

    private var peakingItem: some View {
        let peaking = model.settings.display.peaking
        return DrawerMenuItem(model: model, control: .peaking, title: "Peaking",
                              value: QuickActions.peakingValue(peaking), isActive: peaking != .off) {
            Image(systemName: "scope")
        }
    }

    private var falseColorItem: some View {
        let isOn = model.settings.display.falseColor
        return DrawerButtonItem(model: model, title: "False color", value: isOn ? "On" : "Off", isActive: isOn) {
            QuickActions.toggle(\.display.falseColor, model)
        } glyph: {
            Image(systemName: "paintpalette")
        }
    }
}

// MARK: - Items

/// A drawer item that does one thing on tap.
private struct DrawerButtonItem<Glyph: View>: View {
    let model: CameraModel
    let title: String
    /// What VoiceOver calls the item, where the title under the glyph is a shorter word.
    var spokenTitle: String? = nil
    let value: String
    /// What VoiceOver says for the value, where the glyph above the value line says part of it.
    var spokenValue: String? = nil
    var isActive = false
    var isEnabled = true
    var hint: String? = nil
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            DrawerItemLabel(model: model, title: title, value: value, isActive: isActive, glyph: glyph())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : Theme.Dim.off)
        .accessibilityLabel(spokenTitle ?? title)
        .accessibilityValue(spokenValue ?? value)
        .accessibilityHint(hint ?? "")
    }
}

/// A drawer item whose tap lists its choices, as the top bar's buttons do: the face every item has, with its menu
/// laid over it. A tap has nothing else to do, so the face is no button.
private struct DrawerMenuItem<Glyph: View>: View {
    let model: CameraModel
    let control: DrawerMenuLayer.Control
    let title: String
    let value: String
    var isActive = false
    var isEnabled = true
    /// Said in place of the hint that the item lists its choices: why it is dimmed, or what it can't do here.
    var hint: String? = nil
    @ViewBuilder let glyph: () -> Glyph
    @State private var press = PressTracker()

    var body: some View {
        DrawerItemLabel(model: model, title: title, value: value, isActive: isActive, glyph: glyph())
            // The touch lands on the menu layer, so the press look is set by hand, as PressScaleStyle sets it.
            .scaleEffect(press.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: press.isPressed)
            // The menu over the item is what VoiceOver reads and opens.
            .accessibilityHidden(true)
            .overlay {
                DrawerMenuLayer(model: model, control: control, press: press, label: title, value: value,
                                hint: hint ?? HoldMenuText.choicesHint)
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : Theme.Dim.off)
    }
}

/// An item's menu, laid over the item. Its own view with inputs that compare equal between redraws, so the panel's
/// redraws with every settings change leave the system's menu button alone. Where the top bar lists the same choice,
/// these are its rows, so the two never differ.
private struct DrawerMenuLayer: View {
    enum Control {
        case format, raw, processing, histogram, peaking
    }

    let model: CameraModel
    let control: Control
    let press: PressTracker
    let label: String
    let value: String
    let hint: String

    var body: some View {
        MenuOnTapLayer(press: press, label: label, value: value, hint: hint) {
            switch control {
            case .format: PhotoFormatRows(model: model)
            case .raw: RawFormatRows(model: model)
            case .processing: ProcessingRows(model: model)
            case .histogram: HistogramOptions(model: model)
            case .peaking: PeakingRows(model: model)
            }
        }
    }
}

/// The self timer. A tap lists the top bar's Timer menu: the delays, what the timer sheet set, and the way into the
/// sheet. That menu takes the sheet's binding, which no other item's menu needs, so the timer is an item of its own.
private struct TimerItem: View {
    let model: CameraModel
    @Binding var timerSheetRequested: Bool
    @State private var press = PressTracker()

    var body: some View {
        let schedule = model.settings.capture.schedule
        let value = Self.value(schedule)
        let isEnabled = QuickActions.timerApplies(model)
        DrawerItemLabel(model: model, title: "Timer", value: value, isActive: !schedule.isOff,
                        glyph: Image(systemName: "timer"))
            // As DrawerMenuItem's face: the touch lands on the menu layer, which VoiceOver reads and opens.
            .scaleEffect(press.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: press.isPressed)
            .accessibilityHidden(true)
            .overlay {
                TimerMenuLayer(model: model, mode: model.settings.mode, press: press, value: value,
                               timerSheetRequested: $timerSheetRequested)
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : Theme.Dim.off)
    }

    /// "Off", "3s", "10s ×5", or "5 shots" for an intervalometer with no delay.
    private static func value(_ schedule: CaptureSchedule) -> String {
        if schedule.isOff { return "Off" }
        if schedule.shots == 1 { return Formatting.compactDuration(schedule.delay) }
        if schedule.delay > 0 {
            return Formatting.compactDuration(schedule.delay) + " \u{00D7}\(schedule.shots)"
        }
        return "\(schedule.shots) shots"
    }
}

/// The file type, with HIGH under it for HEIF High and JPEG High.
private struct FormatGlyph: View {
    let choice: PhotoFormatChoice

    var body: some View {
        let scale = Theme.labelScale
        VStack(spacing: 0) {
            Text(QuickActions.formatCode(choice))
                .font(.system(size: 10 * scale, weight: .bold))
            if choice.isHigh {
                Text("HIGH")
                    .font(.system(size: 7 * scale, weight: .bold))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 3)
    }
}

/// The levels up to the most this camera does. A saved level past it stays listed, dimmed, so the menu shows what is
/// set; photos take the camera's most instead.
private struct ProcessingRows: View {
    let model: CameraModel

    var body: some View {
        let setting = model.settings.capture.processing
        let choices = QuickActions.processingChoices(maximum: model.capabilities.maxProcessing)
        ForEach(ProcessingLevel.allCases.filter { choices.contains($0) || $0 == setting }) { level in
            let offered = choices.contains(level)
            // The row ticks.
            HoldMenuChoice(level.title, detail: offered ? nil : "Not on this camera", isOn: level == setting) {
                model.updateSettings { $0.capture.processing = level }
            }
            .disabled(!offered)
        }
    }
}

/// Off, Manual focus and Always, as Settings lists them.
private struct PeakingRows: View {
    let model: CameraModel

    var body: some View {
        let peaking = model.settings.display.peaking
        Picker("Focus peaking", selection: Binding(get: { peaking },
                                                   set: { QuickActions.set(\.display.peaking, to: $0, model) })) {
            ForEach(PeakingMode.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.inline)
    }
}

/// The custom setups C1 to C3: a tap lists the slots, to use one or to save the current setup in one.
private struct SetupsItem: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let saved = model.settings.setups.slots.filter { $0 != nil }.count
        let value = saved == 0 ? "None" : "\(saved) saved"
        DrawerItemLabel(model: model, title: "Setups", value: value, isActive: false,
                        glyph: Image(systemName: "slider.horizontal.3"))
            // The touch lands on the menu layer, so the press look is set by hand, as PressScaleStyle sets it.
            .scaleEffect(press.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: press.isPressed)
            // The menu over the item is what VoiceOver reads and opens.
            .accessibilityHidden(true)
            .overlay {
                SetupsMenuLayer(model: model, press: press, value: value)
            }
    }
}

/// The Setups item's menu, laid over the item. Its own view with inputs that compare equal between redraws, so the
/// panel's redraws with every settings change leave the system's menu button alone.
private struct SetupsMenuLayer: View {
    let model: CameraModel
    let press: PressTracker
    let value: String

    var body: some View {
        MenuOnTapLayer(press: press, label: "Custom setups", value: value) {
            SetupsMenu(model: model)
        }
    }
}

/// The saved setups to use, then the three slots to save the current setup in. A slot with a name keeps it when the
/// current setup goes into it, as in Settings, which also renames and clears them.
private struct SetupsMenu: View {
    let model: CameraModel

    var body: some View {
        let setups = model.settings.setups
        Section("Use a setup") {
            ForEach(0..<CameraSetups.count, id: \.self) { slot in
                let setup = setups[slot]
                // The model closes the panel and names the setup in a toast, or says why it has to wait.
                Button {
                    model.recallSetup(slot: slot)
                } label: {
                    Text(Self.title(slot: slot, setup: setup))
                    Text(setup?.summary ?? "Empty")
                }
                .disabled(setup == nil)
            }
        }
        Section("Save the current setup to") {
            ForEach(0..<CameraSetups.count, id: \.self) { slot in
                let setup = setups[slot]
                Button {
                    // Without a name the slot keeps its own, and the model's toast says where it went.
                    model.saveSetup(slot: slot)
                    Haptics.tap()
                } label: {
                    Text(Self.title(slot: slot, setup: setup))
                    Text(setup == nil ? "Empty" : "Replaces this setup")
                }
            }
        }
    }

    /// "C1 · Milky Way", or "C1" while it has no name, as Settings writes it.
    private static func title(slot: Int, setup: CameraSetup?) -> String {
        let code = "C\(slot + 1)"
        guard let name = setup?.name, !name.isEmpty else { return code }
        return "\(code) \u{00B7} \(name)"
    }
}

private struct DrawerItemLabel<Glyph: View>: View {
    let model: CameraModel
    let title: String
    let value: String
    let isActive: Bool
    let glyph: Glyph

    var body: some View {
        // Larger labels makes the glyphs and both lines a fifth bigger; the columns still hold them.
        let scale = Theme.labelScale
        VStack(spacing: 5) {
            Upright(model: model) { glyph }
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
                .frame(width: 44, height: 44)
                // Filled circles instead of glass: a dozen glass shapes on a glass panel would cost frames.
                .background(isActive ? Theme.accent.opacity(0.2) : Theme.raisedFill, in: Circle())
            VStack(spacing: 1) {
                Text(title)
                    .font(Theme.microFont.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Text(value)
                    .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .animation(Theme.snappy, value: value)
        .animation(Theme.snappy, value: isActive)
    }
}

/// Rotates its content with the phone. Motion is read here so attitude updates redraw single glyphs.
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
