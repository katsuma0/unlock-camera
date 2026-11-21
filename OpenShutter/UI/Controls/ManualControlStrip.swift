import SwiftUI
import CameraCore

/// Chips for the manual controls this camera offers, from ISO on. The shutter and the exposure compensation have
/// their chips beside the lens buttons (LensRow), in the same place in every mode, and AE lock is on the top bar. Tap a chip to
/// open its dial; touch and hold it for auto and the values people reach for most. Each chip reads the live values in
/// its own body, so the 10 Hz readings only redraw the chip text and never the row.
struct ManualControlStrip: View {
    @Bindable var model: CameraModel

    var body: some View {
        let kinds = ChipReader.kinds(for: model)
        let locked = ChipReader.isLocked(model.activity)
        let dimmed = ChipReader.isDimmed(model.activity)
        // Fixed in place and sharing the width evenly, with the screen's margins: at most five chips (ISO,
        // aperture, white balance, tint, focus), each narrowing its text a little before it would crowd.
        HStack(spacing: 8) {
            ForEach(kinds) { kind in
                ParameterChip(model: model, kind: kind, isSelected: model.activeDial == kind)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, Theme.edge)
        // A chip that goes away takes its dial with it: tint when white balance returns to auto (Camera Control,
        // the preset row), the duration when bulb comes on, focus on a lens without manual focus. Initial covers a
        // mode switch, which builds a new strip under a dial that was already open. The lens row's chips count too:
        // their dials open over this strip.
        .onChange(of: kinds + ChipReader.lensRowKinds(for: model), initial: true) { _, current in
            guard let dial = model.activeDial, dial != .zoom, !current.contains(dial) else { return }
            withAnimation(Theme.spring) {
                model.activeDial = nil
            }
        }
        .frame(height: 44)
        .disabled(locked)
        .opacity(dimmed ? Theme.Dim.held : 1)
        .animation(Theme.spring, value: kinds)
        .animation(Theme.snappy, value: dimmed)
        // VoiceOver stays on the chip that opened a dial, so its escape gesture has to work from here as well as
        // from the dial.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Manual controls"))
        .accessibilityAction(.escape) {
            guard model.activeDial != nil else { return }
            Haptics.tick()
            withAnimation(Theme.spring) {
                model.activeDial = nil
            }
        }
    }
}

/// The shutter's chip beside the lens buttons, in the same place in every mode: the shutter speed, or in NIGHT how
/// long the shot runs, with a moon. In PHOTO it shows the camera's own shutter, and the first value picked on its
/// dial leads into MANUAL. Bulb has no time to show, so the place stays empty.
struct LensRowShutterChip: View {
    let model: CameraModel
    /// The room between the row's edge and the lens buttons. A longer value shrinks its text to stay inside it.
    let maxWidth: CGFloat
    /// The row's edge the chip keeps to.
    let edge: HorizontalAlignment

    var body: some View {
        let shows = ChipReader.showsShutterChip(model)
        ZStack {
            if shows {
                ParameterChip(model: model, kind: .shutter, isSelected: model.activeDial == .shutter, compact: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        // The cap sits outside the glass: inside it, a flexible frame would stretch the capsule over the whole room.
        .frame(minWidth: 44, maxWidth: max(maxWidth, 44), minHeight: 44,
               alignment: Alignment(horizontal: edge, vertical: .center))
        .disabled(ChipReader.isLocked(model.activity))
        // Like the exposure chip on the row's other side. A stack dims the whole lens row (ControlsZone), and a
        // dimming of its own on top of that would all but hide the running shot's duration.
        .opacity(model.activity == .saving ? Theme.Dim.held : 1)
        .animation(Theme.snappy, value: shows)
    }
}

// MARK: - Chips

/// One control's chip. `compact` is the lens row's: the value alone, with a moon where it is a night shot's length,
/// since the room beside five lens buttons is about 70 pt on a 402 pt phone.
struct ParameterChip: View {
    let model: CameraModel
    let kind: DialKind
    let isSelected: Bool
    var compact = false
    @State private var press = PressTracker()

    var body: some View {
        let content = ChipReader.content(kind, model: model)
        ChipFace(content: content, isSelected: isSelected, isPressed: press.isPressed, compact: compact,
                 symbol: compact && kind == .shutter && model.settings.mode.usesStacking ? "moon.fill" : nil)
            .frame(minWidth: compact ? 44 : nil, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                ChipReader.toggleDial(kind, model: model)
            }
            .overlay {
                ChipTouchLayer(model: model, kind: kind, press: press)
            }
            .accessibilityElement(children: .ignore)
            // In NIGHT the shutter chip is how long the shot runs.
            .accessibilityLabel(Text(kind == .shutter && model.settings.mode.usesStacking ? "Duration" : kind.title))
            .accessibilityValue(Text(content.spokenValue))
            .accessibilityHint(Text("Shows the dial. " + HoldMenuText.hint))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction(.default) {
                ChipReader.toggleDial(kind, model: model)
            }
            .accessibilityActions {
                if content.canReset {
                    Button("Return to auto") {
                        ChipReader.returnToAuto(kind, model: model)
                    }
                }
            }
    }
}

/// A chip's tap and its touch and hold menu, laid over the chip. Its own view with inputs that never change, so
/// the face's redraws with every live reading leave the system's menu button alone.
private struct ChipTouchLayer: View {
    let model: CameraModel
    let kind: DialKind
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            ChipReader.toggleDial(kind, model: model)
        } options: {
            ChipMenu(model: model, kind: kind)
        }
    }
}

/// What a chip offers on touch and hold: the way back to auto first, where the control has one, then the values
/// people reach for most. Where LONG's scene supplies the value, the first row is named for the scene, because that
/// is where giving the value back leads. Its own view, so the rows are worked out for the menu and not with every
/// reading.
private struct ChipMenu: View {
    let model: CameraModel
    let kind: DialKind

    var body: some View {
        switch kind {
        case .shutter: shutter
        case .iso: iso
        case .aperture: aperture
        case .whiteBalance: whiteBalance
        case .tint: tint
        case .focus: focus
        // Exposure compensation has its own chip and menu in the lens row (ExposureChip), and zoom has no chip.
        case .bias, .zoom: EmptyView()
        }
    }

    @ViewBuilder
    private var shutter: some View {
        let settings = model.settings
        if settings.mode == .night {
            // Inside the range the dial offers on this phone.
            let manual = settings.night.seconds
            let range = model.nightSecondsRange
            Section("Duration") {
                HoldMenuChoice("Auto", isOn: manual == nil) {
                    model.setNightSeconds(nil)
                }
                ForEach(ChipPresets.nightDurations.filter { range.contains($0) }, id: \.self) { value in
                    HoldMenuChoice(HoldMenuText.time(value), isOn: manual.map { ChipPresets.isSame($0, value) } ?? false) {
                        model.setNightSeconds(value)
                    }
                }
            }
        } else if settings.mode == .long {
            // LONG's chip is the total time, which has no auto.
            let seconds = settings.longExposure.seconds
            Section("Duration") {
                ForEach(ChipPresets.longDurations.filter { $0 >= model.shortestLongSeconds }, id: \.self) { value in
                    HoldMenuChoice(HoldMenuText.time(value), isOn: ChipPresets.isSame(seconds, value)) {
                        model.setShutter(value)
                    }
                }
            }
        } else {
            // The live auto shutter is left unread: a menu that follows the meter would rebuild ten times a second.
            let fixed = model.isShutterAuto ? nil : settings.manual.shutter
            let scale = model.shutterScale.map(\.seconds)
            let onScale = ChipPresets.shutters.filter { value in scale.contains { ChipPresets.isSame($0, value) } }
            Section(kind.title) {
                HoldMenuChoice("Auto", isOn: fixed == nil) {
                    model.setShutter(nil)
                }
                ForEach(onScale, id: \.self) { value in
                    HoldMenuChoice(HoldMenuText.time(value), isOn: ChipPresets.isSame(fixed, value)) {
                        model.setShutter(value)
                    }
                }
            }
        }
    }

    private var iso: some View {
        let range = model.capabilities.exposure.iso
        let holder = ControlHolder.of(kind, model: model)
        let fixed = holder == .person ? model.settings.manual.iso : nil
        let lowest = range.lowerBound
        let inRange = ChipPresets.isos.filter { $0 > lowest * 1.03 && $0 <= range.upperBound * 1.02 }
        return Section(kind.title) {
            HoldMenuChoice(ControlHolder.autoTitle(for: kind, model: model), isOn: holder != .person) {
                if holder == .person { model.setISO(nil) }
            }
            HoldMenuChoice("Lowest (\(ISOScale.compactLabel(lowest)))", isOn: ChipPresets.isSame(fixed, lowest)) {
                model.setISO(lowest)
            }
            ForEach(inRange, id: \.self) { value in
                HoldMenuChoice(ISOScale.compactLabel(value), isOn: ChipPresets.isSame(fixed, value)) {
                    model.setISO(value)
                }
            }
        }
    }

    private var aperture: some View {
        let caps = model.capabilities
        let range = caps.exposure.aperture
        let holder = ControlHolder.of(kind, model: model)
        let fixed = holder == .person ? model.settings.manual.aperture : nil
        // The lens's own stops where it names them, whole stops across its range otherwise.
        let stops = ApertureScale.scale(min: range.lowerBound, max: range.upperBound, recommended: caps.apertureStops, step: .full)
        return Section(kind.title) {
            HoldMenuChoice(ControlHolder.autoTitle(for: kind, model: model), isOn: holder != .person) {
                if holder == .person { model.setAperture(nil) }
            }
            ForEach(stops, id: \.self) { value in
                HoldMenuChoice(ApertureScale.label(value), isOn: ChipPresets.isSame(fixed, value)) {
                    model.setAperture(value)
                }
            }
        }
    }

    @ViewBuilder
    private var whiteBalance: some View {
        let holder = ControlHolder.of(kind, model: model)
        // The camera's or the scene's own white balance checks the first row, and no preset with it.
        let chosen: WhiteBalanceSetting = holder == .person ? model.effectiveWhiteBalance : .auto
        Section(kind.title) {
            HoldMenuChoice(ControlHolder.autoTitle(for: kind, model: model), isOn: holder != .person) {
                if holder == .person { model.setWhiteBalance(.auto) }
            }
            ForEach(ChipPresets.whiteBalance) { preset in
                HoldMenuChoice(preset.title, icon: Image(systemName: preset.symbolName),
                               isOn: ChipPresets.isChosen(preset, in: chosen)) {
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

    private var tint: some View {
        // A tint that already reads 0 is left alone: writing it would store the scene's or a preset's temperature as
        // a white balance of the person's, which outlives the scene and holds in every mode.
        let isZero = Formatting.tint(model.displayTint) == "0"
        return Section(kind.title) {
            HoldMenuChoice("0", isOn: isZero) {
                if !isZero { model.setTint(0) }
            }
        }
    }

    private var focus: some View {
        let holder = ControlHolder.of(kind, model: model)
        let position = holder == .person ? model.effectiveFocus.lensPosition : nil
        return Section(kind.title) {
            HoldMenuChoice(ControlHolder.autoTitle(for: kind, model: model, auto: "Autofocus"), isOn: holder != .person) {
                if holder == .person { model.setManualFocus(nil) }
            }
            HoldMenuChoice("Nearest", icon: Image(systemName: "camera.macro"), isOn: position.map { $0 <= 0.005 } ?? false) {
                model.setManualFocus(0)
            }
            HoldMenuChoice("Infinity", icon: Image(systemName: "infinity"), isOn: position.map { $0 >= 0.995 } ?? false) {
                model.setManualFocus(1)
            }
        }
    }
}

/// The values the chip menus offer. Each list is cut to what the camera and the mode can do before it shows.
private enum ChipPresets {
    static let shutters: [Double] = [1.0 / 1000, 1.0 / 250, 1.0 / 60, 1.0 / 15, 1.0 / 4, 1, 4, 30]
    /// From the shortest time worth stacking to the dial's longest.
    static let longDurations: [Double] = [1, 2, 4, 8, 15, 30, 60, 300, 600, 1800]
    static let nightDurations: [Double] = [0.5, 3, 5, 10, 15, 30, 60, 300, 600, 1800]
    static let isos: [Double] = [100, 400, 800, 1600, 3200]
    /// The dial's own preset row without Auto, which leads the menu. Candle sits below the 2000 K the camera can
    /// lock to.
    static let whiteBalance: [WhiteBalancePreset] = [.daylight, .cloudy, .shade, .tungsten, .fluorescent, .flash]

    /// The same stop, give or take what a float or the camera's own rounding loses. nil is auto and matches nothing.
    static func isSame(_ a: Double?, _ b: Double) -> Bool {
        guard let a, a > 0, b > 0 else { return false }
        return abs(log2(a / b)) < 0.03
    }

    /// A dial that lands exactly on a preset's temperature counts as that preset, as on the dial's preset row.
    static func isChosen(_ preset: WhiteBalancePreset, in setting: WhiteBalanceSetting) -> Bool {
        switch setting {
        case .auto:
            return false
        case .preset(let chosen):
            return chosen == preset
        case .kelvin(let kelvin, let tint):
            guard let presetKelvin = preset.kelvin else { return false }
            return abs(kelvin - presetKelvin) < 1 && abs(tint) < 0.5
        }
    }
}

private struct ChipFace: View {
    let content: ChipContent
    let isSelected: Bool
    let isPressed: Bool
    var compact = false
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            // The lens row's chip has room for the value alone, with the moon where it is a night shot's length.
            if compact, let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: content.hugsTitle ? 1 : 4) {
                if !compact {
                    Text(content.title)
                        .opacity(0.8)
                }
                // White with the small A for the camera's value, the accent for one set by hand, on every chip.
                AutoMarked(isAuto: content.tone == .auto) {
                    Text(content.value)
                        .contentTransition(.numericText(value: content.numeric))
                }
            }
            // The value redraws with every detent while its dial turns, so the bloom is drawn on a flattened copy
            // of the few glyphs rather than traced round each one again.
            .compositingGroup()
            .accentGlow(isSelected)
        }
        .font(Theme.chipFont)
        .foregroundStyle(content.tone == .manual ? Theme.accent : Theme.primaryText)
        .lineLimit(1)
        // The strip's chips share the row and the lens row's has the room beside the lens buttons, so each shrinks
        // its text a little instead of reaching a neighbour.
        .minimumScaleFactor(0.7)
        .padding(.horizontal, compact ? Theme.chipPadding : 6)
        .frame(maxWidth: compact ? nil : .infinity)
        .frame(height: Theme.chipHeight)
        .cameraGlass(in: Capsule())
        .instrumentEdge(isActive: isSelected)
        .scaleEffect(isPressed ? 0.94 : 1)
        .animation(Theme.snappy, value: isPressed)
        // Keyed to auto and manual, not the value: dial drags and live auto readings change the value many times a
        // second, and the digits would never finish rolling.
        .animation(Theme.snappy, value: content.tone)
        // A change of length moves the capsule's inner edge, so it glides. Keyed on the length, not the value, so the
        // live readings never keep it running.
        .animation(Theme.snappy, value: content.value.count)
        .animation(Theme.spring, value: isSelected)
        // The moment a dial takes a value away from the camera is felt as well as seen. Only with the dial open:
        // a mode change can turn a chip manual too, and that is no turn of the person's.
        .onChange(of: content.tone) { old, new in
            guard isSelected, old == .auto, new == .manual else { return }
            Haptics.takeOver()
        }
    }
}

/// A value and, while the camera picks it, the small A at its top right, in grey. Every value that marks auto draws
/// it this way: the chips, PHOTO's readout line and the dial's header. Decoration only: each control says "auto" in
/// its own VoiceOver value.
struct AutoMarked<Value: View>: View {
    let isAuto: Bool
    /// The A's size before Larger labels: 7 beside the chips' and the readout line's values, 11 beside the dial
    /// header's.
    let size: CGFloat
    // Built once in init: a stored closure never compares equal.
    let value: Value

    init(isAuto: Bool, size: CGFloat = 7, @ViewBuilder value: () -> Value) {
        self.isAuto = isAuto
        self.size = size
        self.value = value()
    }

    var body: some View {
        let mark = size * Theme.labelScale
        HStack(alignment: .firstTextBaseline, spacing: SmallAutoMark.spacing(for: mark)) {
            value
            if isAuto {
                SmallAutoMark(size: mark)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Values

private enum ChipTone {
    /// White with the small A: the camera picks the value.
    case auto
    /// Yellow: the user fixed the value.
    case manual
    /// White without the A: a control resting where nothing of the user's is set and no camera is choosing.
    /// EV 0, tint 0, or a value LONG's scene fixes.
    case neutral
}

private struct ChipContent {
    var title: String
    var value: String
    /// Drives the direction of the digit roll animation.
    var numeric: Double
    var tone: ChipTone
    var canReset: Bool
    var spokenValue: String
    /// "ƒ1.8" is written without a gap, like on a lens barrel.
    var hugsTitle = false
}

@MainActor
private enum ChipReader {
    /// The chips this camera and mode can use. Controls the hardware can't drive are left out, not shown dead.
    static func kinds(for model: CameraModel) -> [DialKind] {
        let caps = model.capabilities
        var kinds: [DialKind] = []
        if caps.supportsCustomExposure { kinds.append(.iso) }
        if caps.supportsVariableAperture { kinds.append(.aperture) }
        if caps.supportsCustomWhiteBalance {
            kinds.append(.whiteBalance)
            // By the white balance the camera runs: a scene that fixes the temperature leaves a tint to set.
            if !model.effectiveWhiteBalance.isAuto { kinds.append(.tint) }
        }
        if caps.supportsManualFocus { kinds.append(.focus) }
        return kinds
    }

    /// The chips beside the lens buttons: the shutter where this camera and mode have one to set, and the exposure
    /// compensation.
    static func lensRowKinds(for model: CameraModel) -> [DialKind] {
        showsShutterChip(model) ? [.shutter, .bias] : [.bias]
    }

    /// In a long exposure the shutter chip is the total duration, which bulb replaces with the hold. A night shot's
    /// is how long it runs. Elsewhere it needs a camera that takes a shutter speed.
    static func showsShutterChip(_ model: CameraModel) -> Bool {
        switch model.settings.mode {
        case .long: return !model.settings.longExposure.bulb
        case .night: return true
        // A shutter speed, which only the phones with manual shutter speeds offer (CameraModel.allowsManualShutter).
        case .photo, .manual, .video: return model.allowsManualShutter && model.capabilities.supportsCustomExposure
        }
    }

    /// Exposure changes in the middle of a shot or a stack would end up in the picture.
    static func isLocked(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .capturing, .stacking, .saving: return true
        case .idle, .countdown, .recording: return false
        }
    }

    /// A single photo holds the chips only until its exposure ends, so fading them for it would flicker on every
    /// shot, as in the top bar.
    static func isDimmed(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .stacking, .saving: return true
        case .idle, .countdown, .capturing, .recording: return false
        }
    }

    /// The model only honors AE lock while auto exposure owns every parameter.
    static func aeLockApplies(_ model: CameraModel) -> Bool {
        switch model.settings.mode {
        case .photo, .night:
            return true
        case .manual, .video:
            return !model.isManualExposure
        case .long:
            let long = model.settings.longExposure
            return long.blend != .additive && long.frameSeconds == nil && model.isISOAuto && model.isApertureAuto
        }
    }

    static func toggleDial(_ kind: DialKind, model: CameraModel) {
        Haptics.tick()
        withAnimation(Theme.spring) {
            model.activeDial = model.activeDial == kind ? nil : kind
        }
    }

    /// VoiceOver's "Return to auto". The menu's first row does the same by touch.
    static func returnToAuto(_ kind: DialKind, model: CameraModel) {
        // Read again at the moment of the action: the value may have changed since the last redraw.
        guard content(kind, model: model).canReset else { return }
        Haptics.stop()
        withAnimation(Theme.snappy) {
            reset(kind, model: model)
        }
    }

    static func content(_ kind: DialKind, model: CameraModel) -> ChipContent {
        let settings = model.settings
        switch kind {
        case .shutter:
            return shutter(model: model, settings: settings)
        case .iso:
            let holder = ControlHolder.of(kind, model: model)
            // The camera's own value on the third-stop scale, so its digits settle. Set by hand or by a scene, exact.
            let iso = holder == .camera ? AutoValues.iso(model.displayISO) : model.displayISO
            return ChipContent(title: kind.shortTitle, value: ISOScale.compactLabel(iso), numeric: iso,
                               tone: tone(holder), canReset: holder == .person,
                               spokenValue: spoken(ISOScale.label(iso), holder: holder))
        case .aperture:
            let aperture = model.displayAperture
            let holder = ControlHolder.of(kind, model: model)
            return ChipContent(title: kind.shortTitle, value: ApertureScale.compactLabel(aperture), numeric: aperture,
                               tone: tone(holder), canReset: holder == .person,
                               spokenValue: spoken("f " + ApertureScale.compactLabel(aperture), holder: holder), hugsTitle: true)
        case .bias:
            let bias = settings.mode == .night ? settings.night.biasEV : settings.manual.bias
            let isSet = abs(bias) >= 0.05
            return ChipContent(title: kind.shortTitle, value: EVFormat.label(bias), numeric: bias,
                               tone: isSet ? .manual : .neutral, canReset: isSet,
                               spokenValue: EVFormat.label(bias) + " EV")
        case .whiteBalance:
            let holder = ControlHolder.of(kind, model: model)
            let kelvin = holder == .camera ? AutoValues.kelvin(model.displayKelvin) : model.displayKelvin
            return ChipContent(title: kind.shortTitle, value: Formatting.kelvin(kelvin), numeric: kelvin,
                               tone: tone(holder), canReset: holder == .person,
                               spokenValue: spoken(Formatting.kelvin(kelvin), holder: holder))
        case .tint:
            let tint = model.displayTint
            let text = Formatting.tint(tint)
            let isSet = text != "0"
            return ChipContent(title: kind.shortTitle, value: text, numeric: tint,
                               tone: isSet ? .manual : .neutral, canReset: isSet, spokenValue: text)
        case .focus:
            let position = model.displayLensPosition
            let holder = ControlHolder.of(kind, model: model)
            // "MF" with the auto A would contradict itself, so autofocus reads "AF". A scene that parks the
            // lens is manual focus without the yellow.
            return ChipContent(title: holder == .camera ? "AF" : kind.shortTitle, value: percent(position), numeric: position,
                               tone: tone(holder), canReset: holder == .person,
                               spokenValue: spoken(percent(position) + " of the focus range", holder: holder))
        case .zoom:
            let zoom = model.readings.displayZoom
            let label = LensMath.zoomLabel(zoom, selected: true)
            return ChipContent(title: kind.shortTitle, value: label, numeric: zoom, tone: .neutral, canReset: false,
                               spokenValue: label)
        }
    }

    static func reset(_ kind: DialKind, model: CameraModel) {
        switch kind {
        case .shutter:
            if model.settings.mode == .night {
                model.setNightSeconds(nil)
            } else {
                model.setShutter(nil)
            }
        case .iso:
            model.setISO(nil)
        case .aperture:
            model.setAperture(nil)
        case .bias:
            model.setBias(0)
        case .whiteBalance:
            // The tint chip leaves with the custom white balance, and the strip closes its dial.
            model.setWhiteBalance(.auto)
        case .tint:
            model.setTint(0)
        case .focus:
            model.setManualFocus(nil)
        case .zoom:
            break
        }
    }

    private static func shutter(model: CameraModel, settings: CameraSettings) -> ChipContent {
        let title = DialKind.shutter.shortTitle
        if settings.mode == .night {
            // A night shot's chip is how long it runs: the camera's own choice from the light, or a time set by hand.
            let manual = settings.night.seconds
            let seconds = manual ?? model.nightAutoSeconds
            let text = seconds < 1 ? ShutterSpeed(seconds: seconds).label : Formatting.compactDuration(seconds)
            return ChipContent(title: title, value: text, numeric: seconds, tone: manual == nil ? .auto : .manual,
                               canReset: manual != nil, spokenValue: manual == nil ? text + ", auto" : text)
        }
        if settings.mode == .long {
            // LONG has no auto shutter: the chip is the total duration the frames add up to.
            if settings.longExposure.bulb {
                return ChipContent(title: title, value: "Bulb", numeric: 0, tone: .manual, canReset: false, spokenValue: "Bulb")
            }
            let speed = ShutterSpeed(seconds: settings.longExposure.seconds)
            return ChipContent(title: title, value: speed.label, numeric: speed.seconds, tone: .manual, canReset: false,
                               spokenValue: spokenShutter(speed))
        }
        let auto = model.isShutterAuto
        // The camera's own shutter on the third-stop scale, as a camera's display shows it: 1/83 reads 1/80.
        let speed = auto ? AutoValues.shutter(shownShutter(model)) : ShutterSpeed(seconds: shownShutter(model))
        var value = speed.label
        var spokenValue = spokenShutter(speed)
        if settings.mode == .video, settings.video.showShutterAngle {
            let degrees = angleDegrees(seconds: speed.seconds, fps: model.recordedVideo.frameRate)
            value = "\(degrees)\u{00B0}"
            spokenValue = "\(degrees) degree shutter angle"
        }
        // PHOTO and NIGHT, where the model ignores a return to auto, always read auto and never show the strip.
        return ChipContent(title: title, value: value, numeric: speed.seconds, tone: auto ? .auto : .manual,
                           canReset: !auto, spokenValue: spoken(spokenValue, holder: auto ? .camera : .person))
    }

    /// VIDEO shares the manual shutter with MANUAL, where it can be seconds long, but a video frame can't expose
    /// longer than 1/fps. The camera clamps it, so the chip shows the clamped value instead of "2s" or "3600°".
    private static func shownShutter(_ model: CameraModel) -> Double {
        let seconds = model.displayShutter
        guard model.settings.mode == .video else { return seconds }
        let fps = model.recordedVideo.frameRate
        guard fps.isFinite else { return seconds }
        return min(seconds, 1 / max(fps, 1))
    }

    private static func angleDegrees(seconds: Double, fps: Double) -> Int {
        let angle = ExposureMath.shutterAngle(seconds: seconds, fps: fps)
        // Checked and bounded before the Int conversion, which traps on NaN and on huge values.
        guard angle.isFinite else { return 0 }
        return Int(min(max(angle, 0), 3600).rounded())
    }

    private static func percent(_ position: Double) -> String {
        let clamped = position.isFinite ? min(max(position, 0), 1) : 0
        return "\(Int((clamped * 100).rounded()))%"
    }

    private static func spokenShutter(_ speed: ShutterSpeed) -> String {
        speed.isFraction ? speed.label + " of a second" : speed.label
    }

    private static func tone(_ holder: ControlHolder) -> ChipTone {
        switch holder {
        case .person: return .manual
        case .scene: return .neutral
        case .camera: return .auto
        }
    }

    private static func spoken(_ value: String, holder: ControlHolder) -> String {
        switch holder {
        case .person: return value
        case .scene: return value + ", set by the scene"
        case .camera: return value + ", auto"
        }
    }
}
