import SwiftUI
import CameraCore

/// Glass panel under the top bar with the settings people change between shots. Tap an item to step through its
/// values; touch and hold the ones with many values to pick directly.
struct QuickSettingsDrawer: View {
    @Bindable var model: CameraModel
    @State private var showsTimerSheet = false
    /// The timer cycle ends with "custom": after that sheet closes, the next tap wraps around to Off.
    @State private var timerCycleReachedCustom = false

    var body: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 2, verticalSpacing: 12) {
                GridRow {
                    aspectItem
                    timerItem
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
        .sheet(isPresented: $showsTimerSheet) {
            TimerControls(model: model)
        }
        // The camera screen hands the volume buttons back to the system while a sheet covers the viewfinder.
        .preference(key: QuickSettingsSheetKey.self, value: showsTimerSheet)
        .onChange(of: model.settings.capture.schedule) { _, _ in
            timerCycleReachedCustom = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick settings")
        .accessibilityAction(.escape) { close() }
    }

    private func close() {
        withAnimation(Theme.spring) { model.isDrawerOpen = false }
    }

    // MARK: - Capture

    private var aspectItem: some View {
        let aspect = model.settings.capture.aspect
        let selection = Binding<AspectRatio>(
            get: { AspectRatio.presets.first(where: { $0.matches(aspect) }) ?? aspect },
            set: { value in
                Haptics.tick()
                model.updateSettings { $0.capture.aspect = value }
            }
        )
        let isPreset = AspectRatio.presets.contains(where: { $0.matches(aspect) })
        // Video frames are always 16:9; the crop only applies to stills.
        return DrawerMenuItem(model: model, title: "Aspect", value: aspect.label,
                              isActive: !aspect.matches(.fourThree),
                              isEnabled: model.settings.mode != .video,
                              primaryAction: cycleAspect) {
            Picker("Aspect", selection: selection) {
                ForEach(AspectRatio.presets) { preset in
                    Text(preset.label).tag(preset)
                }
                // A ratio entered in Settings gets its own row, so the menu shows which one is in use.
                if !isPreset {
                    Text(aspect.label).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            Button {
                // Settings holds the side fields; the drawer stays open underneath and shows the new ratio after.
                model.isSettingsPresented = true
            } label: {
                Label("Custom\u{2026}", systemImage: "slider.horizontal.3")
            }
        } glyph: {
            Text(aspect.label)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
        }
    }

    /// Steps through the presets. A ratio entered in Settings sits after the last preset, so the next tap goes to
    /// the first one.
    private func cycleAspect() {
        let presets = AspectRatio.presets
        guard !presets.isEmpty else { return }
        let current = model.settings.capture.aspect
        let index = presets.firstIndex(where: { $0.matches(current) })
        let next = index.map { presets[($0 + 1) % presets.count] } ?? presets[0]
        Haptics.tick()
        model.updateSettings { $0.capture.aspect = next }
    }

    private var timerItem: some View {
        let schedule = model.settings.capture.schedule
        let selection = Binding<Double>(
            // A burst or intervalometer matches none of the plain delays, so no row gets the checkmark.
            get: { schedule.shots == 1 ? schedule.delay : -1 },
            set: { delay in
                Haptics.tick()
                model.updateSettings { $0.capture.schedule = CaptureSchedule(delay: delay) }
            }
        )
        let mode = model.settings.mode
        // Video and bulb start on the press itself, so a timer would never run there.
        let applies = mode != .video && !(mode == .long && model.settings.longExposure.bulb)
        return DrawerMenuItem(model: model, title: "Timer", value: Self.timerValue(schedule),
                              isActive: !schedule.isOff,
                              isEnabled: applies,
                              primaryAction: cycleTimer) {
            Picker("Timer", selection: selection) {
                ForEach(CaptureSchedule.delayPresets, id: \.self) { delay in
                    Text(Self.delayTitle(delay)).tag(delay)
                }
            }
            .pickerStyle(.inline)
            Button {
                showsTimerSheet = true
            } label: {
                Label("Custom", systemImage: "slider.horizontal.3")
            }
        } glyph: {
            Image(systemName: "timer")
        }
    }

    /// Off, 3s, 5s, 10s, 30s, then the timer sheet for anything else; a custom schedule steps back to Off.
    private func cycleTimer() {
        let schedule = model.settings.capture.schedule
        let presets = CaptureSchedule.delayPresets
        guard schedule.shots == 1,
              let index = presets.firstIndex(where: { abs($0 - schedule.delay) < 0.01 }) else {
            setSchedule(.off)
            return
        }
        if index + 1 < presets.count {
            setSchedule(CaptureSchedule(delay: presets[index + 1]))
        } else if timerCycleReachedCustom {
            timerCycleReachedCustom = false
            setSchedule(.off)
        } else {
            timerCycleReachedCustom = true
            Haptics.tap()
            showsTimerSheet = true
        }
    }

    private func setSchedule(_ schedule: CaptureSchedule) {
        Haptics.tick()
        model.updateSettings { $0.capture.schedule = schedule }
    }

    private var formatItem: some View {
        let format = model.settings.capture.processedFormat
        let choices = formatChoices
        // A camera without HEIF has nothing to step through, unless the setting is one it can't write.
        let canChange = choices.count > 1 || !choices.contains(format)
        // Stacks write HEIF or JPEG too, so only video turns this off.
        return DrawerButtonItem(model: model, title: "Format", value: Self.formatValue(format),
                                isActive: format != .heif,
                                isEnabled: model.settings.mode != .video && canChange) {
            guard !choices.isEmpty else { return }
            let index = choices.firstIndex(of: format)
            let next = index.map { choices[($0 + 1) % choices.count] } ?? choices[0]
            Haptics.tick()
            model.updateSettings { $0.capture.processedFormat = next }
        } glyph: {
            Text(Self.formatValue(format))
                .font(.system(size: 10, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
    }

    private var formatChoices: [ProcessedFormat] {
        model.capabilities.heifSupported ? [.heif, .jpeg] : [.jpeg]
    }

    private var resolutionItem: some View {
        let resolution = model.settings.capture.resolution
        let choices = Self.resolutionChoices(model.capabilities)
        let mode = model.settings.mode
        // Stacks are merged from video frames, so a MANUAL shutter past the hardware limit ignores this too.
        let singlePhoto = mode == .photo || (mode == .manual && !model.shutterIsStacked)
        return DrawerButtonItem(model: model, title: "Resolution", value: resolution.title,
                                isActive: resolution != .automatic,
                                isEnabled: singlePhoto && choices.count > 1) {
            let index = choices.firstIndex(of: resolution)
            let next = index.map { choices[($0 + 1) % choices.count] } ?? .automatic
            Haptics.tick()
            model.updateSettings { $0.capture.resolution = next }
        } glyph: {
            if let megapixels = resolution.targetMegapixels {
                Text("\(megapixels)")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
            } else {
                // Matches the setting's title, Largest.
                Text("MAX")
                    .font(.system(size: 11, weight: .bold))
            }
        }
    }

    // MARK: - Exposure

    private var processingItem: some View {
        let setting = model.settings.capture.processing
        let choices = Self.processingChoices(maximum: model.capabilities.maxProcessing)
        let mode = model.settings.mode
        // Manual exposure always captures with Minimal so the camera keeps the chosen shutter and ISO.
        let forcedMinimal = model.isManualExposure
        let shown = forcedMinimal ? ProcessingLevel.minimal : setting
        return DrawerButtonItem(model: model, title: "Processing", value: shown.title,
                                isActive: shown != .balanced,
                                isEnabled: (mode == .photo || mode == .manual) && !forcedMinimal && choices.count > 1,
                                hint: forcedMinimal ? "Manual exposure always uses Minimal." : nil) {
            let index = choices.firstIndex(of: setting)
            let next = index.map { choices[($0 + 1) % choices.count] } ?? .balanced
            Haptics.tick()
            model.updateSettings { $0.capture.processing = next }
        } glyph: {
            Image(systemName: "wand.and.stars")
        }
    }

    private var lockItem: some View {
        let locked = model.aeLocked
        let applies = Self.aeLockApplies(model)
        let value = applies ? (locked ? "On" : "Off") : "Manual"
        // With any value set by hand there is no auto exposure left to freeze, but a lock that is on can always
        // be turned off. Nothing changes while a shot or a stack runs, like the strip's AE-L chip. Exposure only:
        // focus keeps following the scene, and touch and hold on the viewfinder is the AE/AF lock.
        return DrawerButtonItem(model: model, title: "AE lock", value: value,
                                isActive: locked && applies,
                                isEnabled: (applies || locked) && !Self.exposureIsBusy(model.activity),
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
            set: { value in
                Haptics.tick()
                model.updateSettings { $0.display.grid = value }
            }
        )
        return DrawerMenuItem(model: model, title: "Grid", value: grid.title, isActive: grid != .off,
                              primaryAction: { cycle(\.display.grid, through: GridStyle.allCases) }) {
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

    private var levelItem: some View {
        let isOn = model.settings.display.showLevel
        return DrawerButtonItem(model: model, title: "Level", value: isOn ? "On" : "Off", isActive: isOn) {
            Haptics.tap()
            model.updateSettings { $0.display.showLevel.toggle() }
        } glyph: {
            Image(systemName: "level")
        }
    }

    private var histogramItem: some View {
        let style = model.settings.display.histogram
        return DrawerButtonItem(model: model, title: "Histogram", value: style.title, isActive: style != .off) {
            cycle(\.display.histogram, through: HistogramStyle.allCases)
        } glyph: {
            Image(systemName: "chart.bar.fill")
        }
    }

    private var zebraItem: some View {
        let isOn = model.settings.display.zebras
        return DrawerButtonItem(model: model, title: "Zebras", value: isOn ? "On" : "Off", isActive: isOn) {
            Haptics.tap()
            model.updateSettings { $0.display.zebras.toggle() }
        } glyph: {
            ZebraGlyph()
        }
    }

    private var peakingItem: some View {
        let peaking = model.settings.display.peaking
        return DrawerButtonItem(model: model, title: "Peaking", value: Self.peakingValue(peaking),
                                isActive: peaking != .off) {
            cycle(\.display.peaking, through: PeakingMode.allCases)
        } glyph: {
            Image(systemName: "scope")
        }
    }

    private var falseColorItem: some View {
        let isOn = model.settings.display.falseColor
        return DrawerButtonItem(model: model, title: "False color", value: isOn ? "On" : "Off", isActive: isOn) {
            Haptics.tap()
            model.updateSettings { $0.display.falseColor.toggle() }
        } glyph: {
            Image(systemName: "paintpalette")
        }
    }

    // MARK: - Helpers

    /// Steps a setting to the value after the current one, wrapping around.
    private func cycle<Value: Equatable>(_ keyPath: WritableKeyPath<CameraSettings, Value>, through values: [Value]) {
        guard !values.isEmpty else { return }
        let current = model.settings[keyPath: keyPath]
        let index = values.firstIndex(of: current)
        let next = index.map { values[($0 + 1) % values.count] } ?? values[0]
        Haptics.tick()
        model.updateSettings { $0[keyPath: keyPath] = next }
    }

    private static func timerValue(_ schedule: CaptureSchedule) -> String {
        if schedule.isOff { return "Off" }
        if schedule.shots == 1 { return Formatting.compactDuration(schedule.delay) }
        if schedule.delay > 0 {
            return Formatting.compactDuration(schedule.delay) + " \u{00D7}\(schedule.shots)"
        }
        return "\(schedule.shots) shots"
    }

    private static func delayTitle(_ delay: Double) -> String {
        delay > 0 ? Formatting.compactDuration(delay) : "Off"
    }

    private static func formatValue(_ format: ProcessedFormat) -> String {
        format == ProcessedFormat.none ? "RAW" : format.title
    }

    private static func peakingValue(_ mode: PeakingMode) -> String {
        switch mode {
        case .off: return "Off"
        case .manualFocus: return "MF"
        case .always: return "On"
        }
    }

    /// Sizes this camera can shoot. A size counts when one of the lens's photo dimensions is within 20% of it,
    /// because sensors sold as 48 MP deliver 48.8 MP and 12 MP ones 12.2 MP.
    private static func resolutionChoices(_ capabilities: CameraCapabilities) -> [PhotoResolution] {
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

    /// Levels up to what the camera reports; asking for more would only be clamped by the model.
    private static func processingChoices(maximum: ProcessingLevel) -> [ProcessingLevel] {
        let order: [ProcessingLevel] = [.minimal, .balanced, .maximum]
        guard let limit = order.firstIndex(of: maximum) else { return order }
        return Array(order[...limit])
    }

    /// When the model honours AE lock: only while auto exposure owns every value. LONG's Blur and Trails meter
    /// each frame, so the lock holds there too as long as ISO and aperture are auto.
    private static func aeLockApplies(_ model: CameraModel) -> Bool {
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
    private static func exposureIsBusy(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .capturing, .stacking, .saving: return true
        case .idle, .countdown, .recording: return false
        }
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

    var body: some View {
        Menu {
            options()
        } label: {
            DrawerItemLabel(model: model, title: title, value: value, isActive: isActive, glyph: glyph())
        } primaryAction: {
            primaryAction()
        }
        .menuStyle(.button)
        .buttonStyle(DrawerPressStyle())
        .menuIndicator(.hidden)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Touch and hold for every option.")
    }
}

private struct DrawerItemLabel<Glyph: View>: View {
    let model: CameraModel
    let title: String
    let value: String
    let isActive: Bool
    let glyph: Glyph

    var body: some View {
        VStack(spacing: 5) {
            Upright(model: model) { glyph }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
                .frame(width: 44, height: 44)
                // Filled circles instead of glass: a dozen glass shapes on a glass panel would cost frames.
                .background(isActive ? Theme.accent.opacity(0.2) : Color.white.opacity(0.12), in: Circle())
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Text(value)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Diagonal stripes in a rounded square, the usual zebra symbol; SF Symbols has none.
private struct ZebraGlyph: View {
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
