import SwiftUI
import CameraCore

/// Glass panel under the top bar with the settings people change between shots. Tap an item to step through its
/// values; touch and hold the ones with many values to pick directly. The simple interface keeps one row of four.
/// Every item steps through QuickActions, as its button on the top bar does, so the two never disagree.
struct QuickSettingsDrawer: View {
    @Bindable var model: CameraModel
    /// Set by the top bar's timer badge or Timer button to ask for the timer sheet, which is presented from here.
    @Binding var timerSheetRequested: Bool
    @State private var showsTimerSheet = false
    /// The timer cycle ends with "custom": after that sheet closes, the next tap wraps around to Off.
    @State private var timerCycleReachedCustom = false

    var body: some View {
        let advanced = model.isAdvanced
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 2, verticalSpacing: 12) {
                if advanced {
                    GridRow {
                        aspectItem(advanced: true)
                        timerItem(advanced: true)
                        formatItem
                        resolutionItem
                    }
                    GridRow {
                        processingItem
                        lockItem
                        gridItem
                        levelItem
                    }
                    GridRow {
                        histogramItem
                        zebraItem
                        peakingItem
                        falseColorItem
                    }
                } else {
                    // What the simple interface leaves to choose between shots. Everything else runs on automatic.
                    GridRow {
                        aspectItem(advanced: false)
                        timerItem(advanced: false)
                        simpleGridItem
                        levelItem
                    }
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
        // Outside the glass, so the panel grows and shrinks with its rows when the interface level changes.
        .animation(Theme.spring, value: advanced)
        // Swiping the panel back up closes it, the way it came.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -24 {
                        close()
                    }
                }
        )
        .sheet(isPresented: $showsTimerSheet) {
            TimerControls(model: model)
        }
        // The camera screen hands the volume buttons back to the system while a sheet covers the viewfinder.
        .preference(key: QuickSettingsSheetKey.self, value: showsTimerSheet)
        .onChange(of: model.settings.capture.schedule) { _, _ in
            timerCycleReachedCustom = false
        }
        // Initial covers a request that opened the drawer: it arrives before this view exists.
        .onChange(of: timerSheetRequested, initial: true) { _, requested in
            guard requested else { return }
            timerSheetRequested = false
            // The sheet holds the intervalometer and the brackets, which the simple interface doesn't have.
            if advanced { showsTimerSheet = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick settings")
        .accessibilityAction(.escape) { close() }
    }

    private func close() {
        withAnimation(Theme.spring) { model.isDrawerOpen = false }
    }

    // MARK: - Capture

    /// The advanced interface offers every preset and the way to a ratio entered in Settings.
    private func aspectItem(advanced: Bool) -> some View {
        let aspect = model.settings.capture.aspect
        let presets = QuickActions.aspects(advanced: advanced)
        let selection = Binding<AspectRatio>(
            get: { QuickActions.aspectSelection(aspect, among: presets) },
            set: { value in QuickActions.setAspect(value, model) }
        )
        let isPreset = presets.contains(where: { $0.matches(aspect) })
        // Video frames are always 16:9; the crop only applies to stills.
        return DrawerMenuItem(model: model, title: "Aspect", value: aspect.label,
                              isActive: QuickActions.aspectIsActive(aspect),
                              isEnabled: model.settings.mode != .video,
                              primaryAction: { QuickActions.stepAspect(model) }) {
            Picker("Aspect", selection: selection) {
                ForEach(presets) { preset in
                    Text(preset.label).tag(preset)
                }
                // A ratio entered in Settings gets its own row, so the menu shows which one is in use.
                if !isPreset {
                    Text(aspect.label).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            if advanced {
                Button {
                    // Settings holds the side fields; the drawer stays open underneath and shows the new ratio after.
                    model.isSettingsPresented = true
                } label: {
                    Label("Custom\u{2026}", systemImage: "slider.horizontal.3")
                }
            }
        } glyph: {
            Text(aspect.label)
                .font(.system(size: 11 * Theme.labelScale, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
        }
    }

    /// The advanced interface ends the tap cycle and the menu with the timer sheet.
    private func timerItem(advanced: Bool) -> some View {
        let schedule = model.settings.capture.schedule
        let delays = QuickActions.delays(advanced: advanced)
        let selection = Binding<Double>(
            // A burst or intervalometer matches none of the plain delays, so no row gets the checkmark.
            get: { schedule.shots == 1 ? schedule.delay : -1 },
            set: { delay in QuickActions.setSchedule(CaptureSchedule(delay: delay), model) }
        )
        return DrawerMenuItem(model: model, title: "Timer", value: Self.timerValue(schedule),
                              isActive: !schedule.isOff,
                              isEnabled: QuickActions.timerApplies(model),
                              primaryAction: { cycleTimer(through: delays, endsInSheet: advanced) }) {
            Picker("Timer", selection: selection) {
                ForEach(delays, id: \.self) { delay in
                    Text(QuickActions.delayTitle(delay)).tag(delay)
                }
            }
            .pickerStyle(.inline)
            if advanced {
                Button {
                    showsTimerSheet = true
                } label: {
                    Label("Custom", systemImage: "slider.horizontal.3")
                }
            }
        } glyph: {
            Image(systemName: "timer")
        }
    }

    /// Off, 3s, 5s, 10s, 30s, then the timer sheet for anything else; a custom schedule steps back to Off. Without
    /// the sheet the last delay goes straight back to Off.
    private func cycleTimer(through delays: [Double], endsInSheet: Bool) {
        switch QuickActions.timerStep(after: model.settings.capture.schedule, delays: delays,
                                      endsInSheet: endsInSheet, sheetOffered: timerCycleReachedCustom) {
        case .schedule(let schedule):
            timerCycleReachedCustom = false
            QuickActions.setSchedule(schedule, model)
        case .sheet:
            timerCycleReachedCustom = true
            Haptics.tap()
            showsTimerSheet = true
        }
    }

    private var formatItem: some View {
        let format = model.settings.capture.processedFormat
        let value = QuickActions.formatValue(format)
        // Stacks write HEIF or JPEG too, so only video turns this off.
        return DrawerButtonItem(model: model, title: "Format", value: value,
                                isActive: format != .heif,
                                isEnabled: model.settings.mode != .video && QuickActions.canChangeFormat(model)) {
            QuickActions.stepFormat(model)
        } glyph: {
            Text(value)
                .font(.system(size: 10 * Theme.labelScale, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
    }

    private var resolutionItem: some View {
        let resolution = model.settings.capture.resolution
        let choices = QuickActions.resolutionChoices(model.capabilities)
        return DrawerButtonItem(model: model, title: "Resolution", value: resolution.title,
                                isActive: resolution != .automatic,
                                isEnabled: QuickActions.resolutionApplies(model) && choices.count > 1) {
            QuickActions.stepResolution(model)
        } glyph: {
            if let megapixels = resolution.targetMegapixels {
                Text("\(megapixels)")
                    .font(.system(size: 15 * Theme.labelScale, weight: .bold).monospacedDigit())
            } else {
                // Matches the setting's title, Largest.
                Text("MAX")
                    .font(.system(size: 11 * Theme.labelScale, weight: .bold))
            }
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
        return DrawerButtonItem(model: model, title: "Processing", value: shown.title,
                                isActive: shown != .balanced,
                                isEnabled: (mode == .photo || mode == .manual) && !forcedMinimal && choices.count > 1,
                                hint: forcedMinimal ? "Manual exposure always uses Minimal." : nil) {
            QuickActions.stepProcessing(model)
        } glyph: {
            Image(systemName: "wand.and.stars")
        }
    }

    private var lockItem: some View {
        let locked = model.aeLocked
        let applies = QuickActions.aeLockApplies(model)
        let value = applies ? (locked ? "On" : "Off") : "Manual"
        // With any value set by hand there is no auto exposure left to freeze, but a lock that is on can always
        // be turned off. Nothing changes while a shot or a stack runs, like the strip's AE-L chip. Exposure only:
        // focus keeps following the scene, and touch and hold on the viewfinder is the AE/AF lock.
        return DrawerButtonItem(model: model, title: "AE lock", value: value,
                                isActive: locked && applies,
                                isEnabled: (applies || locked) && !QuickActions.exposureIsBusy(model.activity),
                                hint: applies ? nil : "Exposure is already set by hand.") {
            model.toggleAELock()
        } glyph: {
            Image(systemName: locked && applies ? "lock.fill" : "lock.open")
        }
    }

    // MARK: - Viewfinder

    private var gridItem: some View {
        let grid = model.settings.display.grid
        let selection = Binding<GridStyle>(
            get: { grid },
            set: { value in QuickActions.set(\.display.grid, to: value, model) }
        )
        return DrawerMenuItem(model: model, title: "Grid", value: grid.title, isActive: grid != .off,
                              primaryAction: { QuickActions.stepGrid(model) }) {
            Picker("Grid", selection: selection) {
                ForEach(GridStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.inline)
        } glyph: {
            Image(systemName: "square.grid.3x3")
        }
    }

    /// The simple interface's grid is the rule of thirds or nothing.
    private var simpleGridItem: some View {
        let isOn = model.settings.display.grid != .off
        return DrawerButtonItem(model: model, title: "Grid", value: isOn ? "On" : "Off", isActive: isOn) {
            QuickActions.stepGrid(model)
        } glyph: {
            Image(systemName: "square.grid.3x3")
        }
    }

    private var levelItem: some View {
        let isOn = model.settings.display.showLevel
        return DrawerButtonItem(model: model, title: "Level", value: isOn ? "On" : "Off", isActive: isOn) {
            QuickActions.toggle(\.display.showLevel, model)
        } glyph: {
            Image(systemName: "level")
        }
    }

    private var histogramItem: some View {
        let style = model.settings.display.histogram
        return DrawerButtonItem(model: model, title: "Histogram", value: style.title, isActive: style != .off) {
            QuickActions.stepHistogram(model)
        } glyph: {
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
        return DrawerButtonItem(model: model, title: "Peaking", value: QuickActions.peakingValue(peaking),
                                isActive: peaking != .off) {
            QuickActions.stepPeaking(model)
        } glyph: {
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

    // MARK: - Helpers

    private static func timerValue(_ schedule: CaptureSchedule) -> String {
        if schedule.isOff { return "Off" }
        if schedule.shots == 1 { return Formatting.compactDuration(schedule.delay) }
        if schedule.delay > 0 {
            return Formatting.compactDuration(schedule.delay) + " \u{00D7}\(schedule.shots)"
        }
        return "\(schedule.shots) shots"
    }
}

/// True while the drawer's timer sheet is up. Internal rather than private because the camera screen reads it:
/// the sheet covers the viewfinder, so the screen gives the volume buttons back to the system meanwhile.
struct QuickSettingsSheetKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

// MARK: - Items

/// A drawer item that does one thing on tap.
private struct DrawerButtonItem<Glyph: View>: View {
    let model: CameraModel
    let title: String
    let value: String
    var isActive = false
    var isEnabled = true
    var hint: String? = nil
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            DrawerItemLabel(model: model, title: title, value: value, isActive: isActive, glyph: glyph())
        }
        .buttonStyle(DrawerPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(hint ?? "")
    }
}

/// A drawer item that steps on tap and lists every value on touch and hold.
private struct DrawerMenuItem<Glyph: View, Options: View>: View {
    let model: CameraModel
    let title: String
    let value: String
    var isActive = false
    var isEnabled = true
    let primaryAction: () -> Void
    @ViewBuilder let options: () -> Options
    @ViewBuilder let glyph: () -> Glyph
    @State private var press = PressTracker()

    var body: some View {
        // The same button as the items without a menu, with the menu laid over it. Every step changes the label,
        // and a label inside the system's menu button would be redrawn through that button each time.
        Button(action: primaryAction) {
            DrawerItemLabel(model: model, title: title, value: value, isActive: isActive, glyph: glyph())
        }
        .buttonStyle(DrawerPressStyle(isPressed: press.isPressed))
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(HoldMenuText.hint)
        .overlay {
            MenuOnHoldLayer(press: press, action: primaryAction, options: options)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
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
                .font(.system(size: 16 * scale, weight: .semibold))
                .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
                .frame(width: 44, height: 44)
                // Filled circles instead of glass: a dozen glass shapes on a glass panel would cost frames.
                .background(isActive ? Theme.accent.opacity(0.2) : Color.white.opacity(0.12), in: Circle())
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 10 * scale, weight: .medium))
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

private struct DrawerPressStyle: ButtonStyle {
    /// A press that lands on the item's touch and hold layer.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isPressed
        configuration.label
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(Theme.snappy, value: pressed)
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
