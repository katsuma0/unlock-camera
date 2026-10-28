import SwiftUI
import CameraCore

/// Chips for every manual control this camera offers, plus AE lock. Tap a chip to open its dial, hold it to
/// hand the value back to auto. Each chip reads the live values in its own body, so the 10 Hz readings only
/// redraw the chip text and never the row.
struct ManualControlStrip: View {
    @Bindable var model: CameraModel

    var body: some View {
        let kinds = ChipReader.kinds(for: model)
        let locked = ChipReader.isLocked(model.activity)
        let dimmed = ChipReader.isDimmed(model.activity)
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(kinds) { kind in
                            ParameterChip(model: model, kind: kind, isSelected: model.activeDial == kind)
                                .id(kind)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                        AELockChip(model: model)
                    }
                    .padding(.horizontal, 16)
                    // Centered when everything fits, scrollable when it doesn't (iPhone SE, Pro with aperture).
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .onAppear {
                    if let dial = model.activeDial, kinds.contains(dial) {
                        reader.scrollTo(dial, anchor: .center)
                    }
                }
                .onChange(of: model.activeDial) { _, dial in
                    guard let dial, kinds.contains(dial) else { return }
                    withAnimation(Theme.spring) {
                        reader.scrollTo(dial, anchor: .center)
                    }
                }
            }
        }
        // A chip that goes away takes its dial with it: tint when white balance returns to auto (Camera Control,
        // the preset row), the duration when bulb comes on, focus on a lens without manual focus. Initial covers a
        // mode switch, which builds a new strip under a dial that was already open.
        .onChange(of: kinds, initial: true) { _, current in
            guard let dial = model.activeDial, dial != .zoom, !current.contains(dial) else { return }
            withAnimation(Theme.spring) {
                model.activeDial = nil
            }
        }
        .frame(height: 44)
        .disabled(locked)
        .opacity(dimmed ? 0.45 : 1)
        .animation(Theme.spring, value: kinds)
        .animation(Theme.snappy, value: dimmed)
    }
}

// MARK: - Chips

private struct ParameterChip: View {
    let model: CameraModel
    let kind: DialKind
    let isSelected: Bool
    @State private var isPressed = false

    var body: some View {
        let content = ChipReader.content(kind, model: model)
        ChipFace(content: content, isSelected: isSelected, isPressed: isPressed)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onLongPressGesture(minimumDuration: 0.45, perform: reset, onPressingChanged: { pressing in
                isPressed = pressing
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(kind.title))
            .accessibilityValue(Text(content.spokenValue))
            .accessibilityHint(Text(content.canReset ? "Shows the dial. Hold to return to auto." : "Shows the dial."))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction(.default, toggle)
            .accessibilityActions {
                if content.canReset {
                    Button("Return to auto", action: reset)
                }
            }
    }

    private func toggle() {
        Haptics.tick()
        withAnimation(Theme.spring) {
            model.activeDial = model.activeDial == kind ? nil : kind
        }
    }

    private func reset() {
        // Read again at the moment the hold completes: the value may have changed since the last redraw.
        guard ChipReader.content(kind, model: model).canReset else { return }
        Haptics.stop()
        withAnimation(Theme.snappy) {
            ChipReader.reset(kind, model: model)
        }
    }
}

private struct AELockChip: View {
    let model: CameraModel

    var body: some View {
        let locked = model.aeLocked
        let applies = ChipReader.aeLockApplies(model)
        Button {
            model.toggleAELock()
        } label: {
            HStack(spacing: 4) {
                LockGlyph(model: model, locked: locked)
                Text("AE-L")
            }
        }
        .buttonStyle(StripButtonStyle(isActive: locked))
        // Manual exposure ignores the lock, but a lock that is on can always be turned off.
        .disabled(!applies && !locked)
        .opacity(applies || locked ? 1 : 0.45)
        .accessibilityLabel(Text("Auto exposure lock"))
        .accessibilityValue(Text(locked ? "On" : "Off"))
        .accessibilityHint(Text(applies ? "Holds the current auto exposure." : "Has no effect while exposure is manual."))
    }
}

private struct LockGlyph: View {
    let model: CameraModel
    let locked: Bool

    var body: some View {
        Image(systemName: locked ? "lock.fill" : "lock.open")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 12)
            .uprightRotation(model.motion.iconRotationDegrees)
            .accessibilityHidden(true)
    }
}

private struct ChipFace: View {
    let content: ChipContent
    let isSelected: Bool
    let isPressed: Bool

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: content.hugsTitle ? 1 : 4) {
                Text(content.title)
                    .opacity(0.8)
                Text(content.value)
                    .contentTransition(.numericText(value: content.numeric))
            }
            if content.tone == .auto {
                AutoBadge()
            }
        }
        .font(Theme.chipFont)
        .foregroundStyle(content.tone == .manual ? Theme.accent : Theme.primaryText)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .cameraGlass(in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Theme.accent.opacity(isSelected ? 0.8 : 0), lineWidth: 1)
        }
        .scaleEffect(isPressed ? 0.94 : 1)
        .animation(Theme.snappy, value: isPressed)
        // Keyed to auto and manual, not the value: dial drags and live auto readings change the value many times a
        // second, and the digits would never finish rolling.
        .animation(Theme.snappy, value: content.tone)
        .animation(Theme.spring, value: isSelected)
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

/// Capsule chip with a 44 pt tall hit area around a 30 pt visible capsule.
private struct StripButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chipFont)
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .cameraGlass(in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Values

private enum ChipTone {
    /// White with the "A" badge: the camera picks the value.
    case auto
    /// Yellow: the user fixed the value.
    case manual
    /// White without a badge: a control that has no auto, sitting at its neutral value (EV 0, tint 0).
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
        let settings = model.settings
        var kinds: [DialKind] = []
        if settings.mode == .long {
            // In LONG the shutter chip is the total duration, which bulb replaces with the hold.
            if !settings.longExposure.bulb { kinds.append(.shutter) }
        } else if caps.supportsCustomExposure {
            kinds.append(.shutter)
        }
        if caps.supportsCustomExposure { kinds.append(.iso) }
        if caps.supportsVariableAperture { kinds.append(.aperture) }
        kinds.append(.bias)
        if caps.supportsCustomWhiteBalance {
            kinds.append(.whiteBalance)
            if !settings.whiteBalance.isAuto { kinds.append(.tint) }
        }
        if caps.supportsManualFocus { kinds.append(.focus) }
        return kinds
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

    static func content(_ kind: DialKind, model: CameraModel) -> ChipContent {
        let settings = model.settings
        switch kind {
        case .shutter:
            return shutter(model: model, settings: settings)
        case .iso:
            let iso = model.displayISO
            let auto = model.isISOAuto
            return ChipContent(title: kind.shortTitle, value: ISOScale.compactLabel(iso), numeric: iso,
                               tone: auto ? .auto : .manual, canReset: !auto && allowsAuto(settings.mode),
                               spokenValue: spoken(ISOScale.label(iso), auto: auto))
        case .aperture:
            let aperture = model.displayAperture
            let auto = model.isApertureAuto
            return ChipContent(title: kind.shortTitle, value: ApertureScale.compactLabel(aperture), numeric: aperture,
                               tone: auto ? .auto : .manual, canReset: !auto && allowsAuto(settings.mode),
                               spokenValue: spoken("f " + ApertureScale.compactLabel(aperture), auto: auto), hugsTitle: true)
        case .bias:
            let bias = settings.mode == .night ? settings.night.biasEV : settings.manual.bias
            let isSet = abs(bias) >= 0.05
            return ChipContent(title: kind.shortTitle, value: EVFormat.label(bias), numeric: bias,
                               tone: isSet ? .manual : .neutral, canReset: isSet,
                               spokenValue: EVFormat.label(bias) + " EV")
        case .whiteBalance:
            let kelvin = model.displayKelvin
            let auto = model.isWhiteBalanceAuto
            return ChipContent(title: kind.shortTitle, value: Formatting.kelvin(kelvin), numeric: kelvin,
                               tone: auto ? .auto : .manual, canReset: !auto,
                               spokenValue: spoken(Formatting.kelvin(kelvin), auto: auto))
        case .tint:
            let tint = model.displayTint
            let text = Formatting.tint(tint)
            let isSet = text != "0"
            return ChipContent(title: kind.shortTitle, value: text, numeric: tint,
                               tone: isSet ? .manual : .neutral, canReset: isSet, spokenValue: text)
        case .focus:
            let position = model.displayLensPosition
            let auto = model.isFocusAuto
            // "MF" with an auto badge would contradict itself, so autofocus reads "AF".
            return ChipContent(title: auto ? "AF" : kind.shortTitle, value: percent(position), numeric: position,
                               tone: auto ? .auto : .manual, canReset: !auto,
                               spokenValue: spoken(percent(position) + " of the focus range", auto: auto))
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
            model.setShutter(nil)
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
        if settings.mode == .long {
            // LONG has no auto shutter: the chip is the total duration the frames add up to.
            if settings.longExposure.bulb {
                return ChipContent(title: title, value: "Bulb", numeric: 0, tone: .manual, canReset: false, spokenValue: "Bulb")
            }
            let speed = ShutterSpeed(seconds: settings.longExposure.seconds)
            return ChipContent(title: title, value: speed.label, numeric: speed.seconds, tone: .manual, canReset: false,
                               spokenValue: spokenShutter(speed))
        }
        let speed = ShutterSpeed(seconds: shownShutter(model))
        let auto = model.isShutterAuto
        var value = speed.label
        var spokenValue = spokenShutter(speed)
        if settings.mode == .video, settings.video.showShutterAngle {
            let degrees = angleDegrees(seconds: speed.seconds, fps: model.recordedVideo.frameRate)
            value = "\(degrees)\u{00B0}"
            spokenValue = "\(degrees) degree shutter angle"
        }
        return ChipContent(title: title, value: value, numeric: speed.seconds, tone: auto ? .auto : .manual,
                           canReset: !auto && allowsAuto(settings.mode), spokenValue: spoken(spokenValue, auto: auto))
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

    /// PHOTO and NIGHT are auto by definition; the model ignores nil there.
    private static func allowsAuto(_ mode: CaptureMode) -> Bool {
        mode == .manual || mode == .long || mode == .video
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

    private static func spoken(_ value: String, auto: Bool) -> String {
        auto ? value + ", auto" : value
    }
}
