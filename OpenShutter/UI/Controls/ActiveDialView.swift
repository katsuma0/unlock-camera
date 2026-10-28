import SwiftUI
import CameraCore

/// The dial for `model.activeDial`, with its header and presets.
struct ActiveDialView: View {
    @Bindable var model: CameraModel

    var body: some View {
        ZStack {
            if let kind = model.activeDial {
                DialPanel(model: model, kind: kind)
                    // A new identity per kind, so each dial starts from its own value instead of the last one's index.
                    .id(kind)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: model.activeDial)
    }
}

// MARK: - Panel

private struct DialPanel: View {
    let model: CameraModel
    let kind: DialKind

    @State private var cache = DialScaleCache()
    /// nil until the follower has placed the dial; the body then reads the live value once.
    @State private var selection: Int?
    @State private var isEditing = false
    @State private var followPausedUntil = Date.distantPast
    @State private var resyncToken = 0
    /// Zooms the current edit sent, so a resync can tell a zoom the model dropped from one another control made.
    @State private var sentZooms: [Double] = []

    /// After a change from the dial, zoom and auto values come back on the next reading. Following them sooner
    /// would pull the ruler back to the old value for a moment.
    private static let followPause: TimeInterval = 0.7

    var body: some View {
        // Scales are rebuilt only when their inputs change, not on every 60 Hz settings write from a drag.
        let scale = cache.scale(for: DialScales.key(kind, model: model)) {
            DialScales.build(kind, model: model)
        }
        let fallback = selection ?? scale.nearestIndex(to: DialValues.current(kind, model: model)) ?? 0
        let locked = DialValues.isLocked(model.activity)
        let dimmed = DialValues.isDimmed(model.activity)
        VStack(spacing: 6) {
            DialHeader(model: model, kind: kind)
            if kind == .whiteBalance {
                WhiteBalancePresetRow(model: model)
            }
            if scale.values.isEmpty {
                Text(kind == .aperture ? "This lens has a fixed aperture." : "Not available on this camera.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(height: 56)
            } else {
                RulerDial(
                    values: scale.values,
                    index: Binding(
                        get: { scale.clamped(selection ?? fallback) },
                        set: { userSelected($0, scale: scale, fallback: fallback) }
                    ),
                    majorTick: { scale.isMajor($0) },
                    label: { scale.label($0) },
                    spacing: scale.spacing,
                    onEditingChanged: editingChanged
                )
                // RulerDial calls itself "Dial" and speaks a long tick's short label ("250" for 1/250 s).
                .accessibilityLabel(Text(kind.title))
                .accessibilityValue(Text(scale.spokenLabel(scale.clamped(selection ?? fallback))))
                .overlay {
                    if kind == .focus {
                        FocusEndGlyphs(model: model)
                    }
                }
                .background {
                    DialFollower(model: model, kind: kind, scale: scale, onTarget: follow)
                        .allowsHitTesting(false)
                }
            }
        }
        .disabled(locked)
        .opacity(dimmed ? 0.45 : 1)
        .task(id: resyncToken) {
            await resync()
        }
    }

    private func userSelected(_ index: Int, scale: DialScale, fallback: Int) {
        guard scale.values.indices.contains(index) else { return }
        let current = scale.clamped(selection ?? fallback)
        selection = index
        // A dial that re-sends its own index must not turn an auto value into a manual one.
        guard index != current else { return }
        pauseFollowing()
        let value = scale.values[index]
        if kind == .zoom, sentZooms.count < 256 {
            sentZooms.append(value)
        }
        DialValues.apply(kind, value: value, model: model)
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        if editing {
            sentZooms.removeAll()
        } else {
            pauseFollowing()
        }
    }

    private func follow(_ target: Int) {
        guard !isEditing, Date() >= followPausedUntil, selection != target else { return }
        selection = target
    }

    private func pauseFollowing() {
        followPausedUntil = Date().addingTimeInterval(Self.followPause)
        resyncToken &+= 1
    }

    /// One catch-up after the pause, for values the camera clamped or changed while following was paused.
    private func resync() async {
        guard resyncToken != 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64((Self.followPause + 0.1) * 1_000_000_000))
        guard !Task.isCancelled, !isEditing else { return }
        if kind == .zoom, retryDroppedZoom() { return }
        let scale = cache.current
        guard let target = scale.nearestIndex(to: DialValues.current(kind, model: model)), target != selection else { return }
        selection = target
    }

    /// While a lens switch is in flight the model drops zooms aimed at another lens, so a drag released during the
    /// switch leaves the camera on an earlier value of the same drag. Then the dial asks once more for the value
    /// under the line. A camera that went anywhere else got there by a pinch or the Camera Control, so the dial
    /// follows it instead of fighting it.
    private func retryDroppedZoom() -> Bool {
        let sent = sentZooms
        // Once per edit: whatever the camera reports after the second request is the answer.
        sentZooms.removeAll()
        let actual = model.readings.displayZoom
        guard let wanted = sent.last, !Self.isSameZoom(wanted, actual),
              sent.contains(where: { Self.isSameZoom($0, actual) }) else { return false }
        pauseFollowing()
        DialValues.apply(.zoom, value: wanted, model: model)
        return true
    }

    private static func isSameZoom(_ a: Double, _ b: Double) -> Bool {
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { return false }
        return abs(log2(a / b)) <= 0.03
    }
}

/// Reads the live value in its own body, so 10 Hz readings re-run this tiny view and not the ruler.
private struct DialFollower: View {
    let model: CameraModel
    let kind: DialKind
    let scale: DialScale
    let onTarget: (Int) -> Void

    var body: some View {
        let target = scale.nearestIndex(to: DialValues.current(kind, model: model)) ?? 0
        Color.clear
            .onChange(of: target, initial: true) { _, newValue in
                onTarget(newValue)
            }
    }
}

private struct DialHeader: View {
    let model: CameraModel
    let kind: DialKind

    var body: some View {
        let readout = DialValues.readout(kind, model: model)
        DialValueHeader(
            title: readout.title,
            value: readout.value,
            isAuto: readout.isAuto,
            onAuto: readout.offersAuto ? {
                Haptics.tap()
                DialValues.setAuto(kind, model: model)
            } : nil
        )
        .overlay(alignment: .trailing) {
            if readout.isStacked {
                StackBadge()
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(Theme.snappy, value: readout.isStacked)
    }
}

/// Shutter values past the hardware maximum are built from several frames.
private struct StackBadge: View {
    var body: some View {
        Text("STACK")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.18)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
            .accessibilityLabel(Text("Stacked exposure, built from several frames"))
    }
}

private struct FocusEndGlyphs: View {
    let model: CameraModel

    var body: some View {
        HStack {
            UprightImage(model: model, systemName: "camera.macro")
            Spacer(minLength: 0)
            UprightImage(model: model, systemName: "infinity")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

// MARK: - White balance presets

private struct WhiteBalancePresetRow: View {
    let model: CameraModel

    /// Candle sits below the 2000 K the camera can lock to, so the row leaves it out.
    private static let presets: [WhiteBalancePreset] = [.auto, .daylight, .cloudy, .shade, .tungsten, .fluorescent, .flash]

    var body: some View {
        let current = model.settings.whiteBalance
        let grayCardAvailable = model.capabilities.supportsCustomWhiteBalance
        ViewThatFits(in: .horizontal) {
            row(current: current, grayCardAvailable: grayCardAvailable)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                row(current: current, grayCardAvailable: grayCardAvailable)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func row(current: WhiteBalanceSetting, grayCardAvailable: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.presets) { preset in
                PresetButton(model: model, systemName: preset.symbolName, title: preset.title,
                             isSelected: Self.isSelected(preset, current: current)) {
                    Haptics.tick()
                    model.setWhiteBalance(preset == .auto ? .auto : .preset(preset))
                }
            }
            PresetButton(model: model, systemName: "eyedropper", title: "Gray card", isSelected: false) {
                model.setWhiteBalanceFromGrayCard()
            }
            .disabled(!grayCardAvailable)
            .opacity(grayCardAvailable ? 1 : 0.45)
            // Gray world gains assume a neutral card filling the middle half of the frame; a small card leaves them
            // averaging the whole scene.
            .accessibilityHint(Text("Fill the middle of the frame with a gray card or white paper, then tap."))
        }
    }

    private static func isSelected(_ preset: WhiteBalancePreset, current: WhiteBalanceSetting) -> Bool {
        switch current {
        case .auto:
            return preset == .auto
        case .preset(let chosen):
            return chosen == preset
        case .kelvin(let kelvin, let tint):
            // A dial that lands exactly on a preset's temperature counts as that preset.
            guard let presetKelvin = preset.kelvin else { return false }
            return abs(kelvin - presetKelvin) < 1 && abs(tint) < 0.5
        }
    }
}

private struct PresetButton: View {
    let model: CameraModel
    let systemName: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            UprightImage(model: model, systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.accent : Theme.primaryText)
                .frame(width: 38, height: 38)
                .cameraGlass(in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PresetPressStyle())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PresetPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

// MARK: - Values per dial kind

@MainActor
private enum DialValues {
    struct Readout {
        var title: String
        var value: String
        var isAuto: Bool
        var offersAuto: Bool
        var isStacked: Bool
    }

    /// Changing exposure while a shot or stack runs would end up in the picture.
    static func isLocked(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .capturing, .stacking, .saving: return true
        case .idle, .countdown, .recording: return false
        }
    }

    /// A single photo holds the dial only until its exposure ends, so fading it for that would flicker on every
    /// shot, as in the top bar.
    static func isDimmed(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .stacking, .saving: return true
        case .idle, .countdown, .capturing, .recording: return false
        }
    }

    /// The value the dial should sit on: the fixed value, or the live auto value.
    static func current(_ kind: DialKind, model: CameraModel) -> Double {
        switch kind {
        case .shutter:
            // LONG's shutter dial sets the total duration, whatever the per-frame exposure is doing.
            return model.settings.mode == .long ? model.settings.longExposure.seconds : shownShutter(model)
        case .iso: return model.displayISO
        case .aperture: return model.displayAperture
        case .bias: return bias(model)
        case .whiteBalance: return model.displayKelvin
        case .tint: return model.displayTint
        case .focus: return model.displayLensPosition
        case .zoom: return model.readings.displayZoom
        }
    }

    static func apply(_ kind: DialKind, value: Double, model: CameraModel) {
        guard value.isFinite else { return }
        switch kind {
        case .shutter: model.setShutter(value)
        case .iso: model.setISO(value)
        case .aperture: model.setAperture(value)
        case .bias: model.setBias(value)
        case .whiteBalance: model.setKelvin(value)
        case .tint: model.setTint(value)
        case .focus: model.setManualFocus(value)
        case .zoom: model.setDisplayZoom(value, animated: false)
        }
    }

    static func setAuto(_ kind: DialKind, model: CameraModel) {
        switch kind {
        case .shutter: model.setShutter(nil)
        case .iso: model.setISO(nil)
        case .aperture: model.setAperture(nil)
        case .bias: model.setBias(0)
        case .whiteBalance: model.setWhiteBalance(.auto)
        case .focus: model.setManualFocus(nil)
        case .tint, .zoom: break
        }
    }

    static func readout(_ kind: DialKind, model: CameraModel) -> Readout {
        let settings = model.settings
        let caps = model.capabilities
        switch kind {
        case .shutter:
            if settings.mode == .long {
                let long = settings.longExposure
                let value = long.bulb ? "Bulb" : ShutterSpeed(seconds: long.seconds).label
                // Blur and Trails always merge frames; Real only once the duration passes the longest shutter.
                let stacked = !long.bulb && model.shutterIsStacked
                return Readout(title: "Duration", value: value, isAuto: false, offersAuto: false, isStacked: stacked)
            }
            let seconds = shownShutter(model)
            var value = ShutterSpeed(seconds: seconds).label
            if settings.mode == .video, settings.video.showShutterAngle {
                let angle = ExposureMath.shutterAngle(seconds: seconds, fps: model.recordedVideo.frameRate)
                // Checked and bounded before the Int conversion, which traps on NaN and on huge values.
                let degrees = angle.isFinite ? Int(min(max(angle, 0), 3600).rounded()) : 0
                value += " \u{00B7} \(degrees)\u{00B0}"
            }
            return Readout(title: kind.title, value: value, isAuto: model.isShutterAuto, offersAuto: true,
                           isStacked: settings.mode == .manual && model.shutterIsStacked)
        case .iso:
            return Readout(title: kind.title, value: ISOScale.compactLabel(model.displayISO), isAuto: model.isISOAuto,
                           offersAuto: true, isStacked: false)
        case .aperture:
            return Readout(title: kind.title, value: ApertureScale.label(model.displayAperture), isAuto: model.isApertureAuto,
                           offersAuto: caps.supportsVariableAperture, isStacked: false)
        case .bias:
            let bias = bias(model)
            return Readout(title: kind.title, value: EVFormat.label(bias) + " EV", isAuto: abs(bias) < 0.05,
                           offersAuto: true, isStacked: false)
        case .whiteBalance:
            let kelvin = Formatting.kelvin(model.displayKelvin)
            if case .preset(let preset) = settings.whiteBalance, preset != .auto {
                return Readout(title: kind.title, value: "\(preset.title) \u{00B7} \(kelvin)", isAuto: false,
                               offersAuto: true, isStacked: false)
            }
            return Readout(title: kind.title, value: kelvin, isAuto: model.isWhiteBalanceAuto, offersAuto: true, isStacked: false)
        case .tint:
            return Readout(title: kind.title, value: Formatting.tint(model.displayTint), isAuto: false,
                           offersAuto: false, isStacked: false)
        case .focus:
            let position = model.displayLensPosition
            let clamped = position.isFinite ? min(max(position, 0), 1) : 0
            return Readout(title: kind.title, value: "\(Int((clamped * 100).rounded()))%", isAuto: model.isFocusAuto,
                           offersAuto: caps.supportsManualFocus, isStacked: false)
        case .zoom:
            let readings = model.readings
            var value = LensMath.zoomLabel(readings.displayZoom, selected: true)
            let focal = caps.lens.equivalentFocalLength * max(readings.zoomFactor, 1)
            if focal.isFinite, focal > 0 {
                value += " \u{00B7} " + LensMath.focalLengthLabel(focal)
            }
            return Readout(title: kind.title, value: value, isAuto: false, offersAuto: false, isStacked: false)
        }
    }

    private static func bias(_ model: CameraModel) -> Double {
        model.settings.mode == .night ? model.settings.night.biasEV : model.settings.manual.bias
    }

    /// VIDEO shares the manual shutter with MANUAL, where it can be seconds long, but a video frame can't expose
    /// longer than 1/fps. The camera clamps it, so the dial and header show the clamped value.
    private static func shownShutter(_ model: CameraModel) -> Double {
        let seconds = model.displayShutter
        guard model.settings.mode == .video else { return seconds }
        let fps = model.recordedVideo.frameRate
        guard fps.isFinite else { return seconds }
        return min(seconds, 1 / max(fps, 1))
    }
}

// MARK: - Scales

private struct LabelCandidate {
    var index: Int
    /// Drawn above the tick when it gets a long tick.
    var text: String
    /// Higher wins when two labels would crowd each other.
    var priority: Int
}

private struct DialScale {
    enum Metric {
        case linear, logarithmic, mired
    }

    var values: [Double]
    /// Long ticks, each with its label drawn above it.
    var majors: [Bool]
    /// A label for every tick. RulerDial draws only the long ticks' labels, but VoiceOver reads the selected tick's,
    /// so short ticks carry their full text too.
    var labels: [String]
    /// The full text of every tick ("1/250" where the tick reads "250"), for the dial's VoiceOver value.
    var spoken: [String]
    var spacing: CGFloat
    var metric: Metric

    static let empty = DialScale(values: [], spoken: [], candidates: [], spacing: 10, metric: .linear)

    /// `spoken` is the text for every tick; `candidates` are the ticks that may get a long tick and a drawn label.
    init(values: [Double], spoken: [String], candidates: [LabelCandidate], spacing: CGFloat, metric: Metric) {
        self.values = values
        self.spoken = spoken
        self.spacing = spacing
        self.metric = metric
        let placed = Self.placeLabels(candidates, count: values.count, spacing: spacing)
        var majors = Array(repeating: false, count: values.count)
        var labels = (0..<values.count).map { spoken.indices.contains($0) ? spoken[$0] : "" }
        for candidate in candidates where placed.contains(candidate.index) {
            majors[candidate.index] = true
            labels[candidate.index] = candidate.text
        }
        self.majors = majors
        self.labels = labels
    }

    func isMajor(_ index: Int) -> Bool {
        majors.indices.contains(index) ? majors[index] : false
    }

    func label(_ index: Int) -> String {
        labels.indices.contains(index) ? labels[index] : ""
    }

    func spokenLabel(_ index: Int) -> String {
        spoken.indices.contains(index) ? spoken[index] : label(index)
    }

    func clamped(_ index: Int) -> Int {
        min(max(index, 0), max(values.count - 1, 0))
    }

    /// Closest tick in the unit the eye compares: stops for shutter, ISO, aperture and zoom, mireds for color.
    func nearestIndex(to value: Double) -> Int? {
        guard !values.isEmpty, value.isFinite else { return nil }
        var best = 0
        var bestGap = Double.infinity
        for (index, candidate) in values.enumerated() {
            let gap = distance(candidate, value)
            if gap < bestGap {
                best = index
                bestGap = gap
            }
        }
        return best
    }

    private func distance(_ a: Double, _ b: Double) -> Double {
        switch metric {
        case .linear:
            return abs(a - b)
        case .logarithmic:
            guard a > 0, b > 0 else { return abs(a - b) }
            return abs(log2(a / b))
        case .mired:
            guard a > 0, b > 0 else { return abs(a - b) }
            return abs(1_000_000 / a - 1_000_000 / b)
        }
    }

    /// Picks the labelled ticks, most important first. RulerDial thins every label to a fixed period as soon as two
    /// neighbours sit closer than its widest label plus 8 pt, which would scatter an uneven pattern like this one,
    /// so every pair kept here is at least that far apart and RulerDial draws all of them.
    private static func placeLabels(_ candidates: [LabelCandidate], count: Int, spacing: CGFloat) -> Set<Int> {
        let usable = candidates.filter { !$0.text.isEmpty && $0.index >= 0 && $0.index < count }
        guard let widest = usable.map({ labelWidth($0.text) }).max(), spacing > 0 else { return [] }
        let minimumGap = max(1, Int(((widest + 9) / spacing).rounded(.up)))
        let ordered = usable.sorted { a, b in
            a.priority != b.priority ? a.priority > b.priority : a.index < b.index
        }
        var placed: [Int] = []
        for candidate in ordered where placed.allSatisfy({ abs($0 - candidate.index) >= minimumGap }) {
            placed.append(candidate.index)
        }
        return Set(placed)
    }

    /// Width of a label in RulerDial's 11 pt semibold monospaced digits, on the generous side.
    private static func labelWidth(_ text: String) -> CGFloat {
        var width: CGFloat = 0
        for character in text {
            switch character {
            case "0"..."9": width += 7
            case ".", ",", ":": width += 3.4
            case "/": width += 4.8
            case "m", "w", "M", "W": width += 10
            case "f", "i", "j", "l", "r", "t", "I": width += 4.6
            default: width += 7.4
            }
        }
        return width
    }
}

private struct DialScaleKey: Equatable {
    var kind: DialKind
    var mode: CaptureMode
    var numbers: [Double]
}

/// Remembers the last scale so the body only rebuilds it when the camera or mode changes. A plain class:
/// writing to it during body must not invalidate the view.
private final class DialScaleCache {
    private var key: DialScaleKey?
    private(set) var current = DialScale.empty

    func scale(for key: DialScaleKey, build: () -> DialScale) -> DialScale {
        if key != self.key {
            self.key = key
            current = build()
        }
        return current
    }
}

private struct ZoomSpan: Equatable {
    var lower: Double
    var upper: Double
    /// Lens button positions, so the dial can stop exactly on them.
    var marks: [Double]
}

@MainActor
private enum DialScales {
    static func key(_ kind: DialKind, model: CameraModel) -> DialScaleKey {
        let caps = model.capabilities
        let settings = model.settings
        var numbers: [Double] = []
        switch kind {
        case .shutter:
            numbers = [caps.exposure.seconds.lowerBound, caps.exposure.seconds.upperBound,
                       settings.mode == .video ? model.recordedVideo.frameRate : 0]
        case .iso:
            numbers = [caps.exposure.iso.lowerBound, caps.exposure.iso.upperBound]
        case .aperture:
            numbers = [caps.supportsVariableAperture ? 1 : 0, caps.exposure.aperture.lowerBound,
                       caps.exposure.aperture.upperBound] + caps.apertureStops
        case .bias:
            numbers = [caps.biasRange.lowerBound, caps.biasRange.upperBound]
        case .whiteBalance, .tint, .focus:
            numbers = []
        case .zoom:
            let span = zoomSpan(model)
            numbers = [span.lower, span.upper] + span.marks
        }
        return DialScaleKey(kind: kind, mode: settings.mode, numbers: numbers)
    }

    static func build(_ kind: DialKind, model: CameraModel) -> DialScale {
        switch kind {
        case .shutter: return shutter(model.shutterScale.map(\.seconds))
        case .iso: return iso(model.isoScale)
        case .aperture: return aperture(model.apertureScale)
        case .bias: return bias(model.biasScale)
        case .whiteBalance: return kelvin(model.kelvinScale)
        case .tint: return tint()
        case .focus: return focus()
        case .zoom: return zoom(zoomSpan(model))
        }
    }

    private static func shutter(_ values: [Double]) -> DialScale {
        var candidates: [LabelCandidate] = []
        for (index, seconds) in values.enumerated() {
            let isEnd = index == 0 || index == values.count - 1
            let isFullStop = ShutterSpeed.nominalFullStops.contains { isNear(seconds, $0, stops: 0.04) }
            guard isEnd || isFullStop else { continue }
            candidates.append(LabelCandidate(index: index, text: ShutterSpeed(seconds: seconds).compactLabel, priority: isEnd ? 2 : 1))
        }
        // Ticks read "250" like a camera's dial; VoiceOver gets the full "1/250".
        let spoken = values.map { ShutterSpeed(seconds: $0).label }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 13, metric: .logarithmic)
    }

    private static func iso(_ values: [Double]) -> DialScale {
        var candidates: [LabelCandidate] = []
        for (index, iso) in values.enumerated() {
            let isEnd = index == 0 || index == values.count - 1
            let isFullStop = ISOScale.nominalFullStops.contains { isNear(iso, $0, stops: 0.04) }
            guard isEnd || isFullStop else { continue }
            candidates.append(LabelCandidate(index: index, text: ISOScale.compactLabel(iso), priority: isEnd ? 2 : 1))
        }
        let spoken = values.map { ISOScale.compactLabel($0) }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 13, metric: .logarithmic)
    }

    private static func aperture(_ values: [Double]) -> DialScale {
        // Recommended stops on an iris lens are few, so each one gets a labelled tick and room to breathe.
        let few = values.count <= 8
        var candidates: [LabelCandidate] = []
        for (index, f) in values.enumerated() {
            let isEnd = index == 0 || index == values.count - 1
            let isFullStop = few || ApertureScale.nominalFullStops.contains { isNear(f, $0, stops: 0.03) }
            guard isEnd || isFullStop else { continue }
            candidates.append(LabelCandidate(index: index, text: ApertureScale.compactLabel(f), priority: isEnd ? 2 : 1))
        }
        let spoken = values.map { ApertureScale.compactLabel($0) }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: few ? 36 : 13, metric: .logarithmic)
    }

    private static func bias(_ values: [Double]) -> DialScale {
        var candidates: [LabelCandidate] = []
        for (index, ev) in values.enumerated() where abs(ev - ev.rounded()) < 1e-6 {
            let isEnd = index == 0 || index == values.count - 1
            let priority = abs(ev) < 1e-6 ? 3 : (isEnd ? 2 : 1)
            candidates.append(LabelCandidate(index: index, text: EVFormat.label(ev), priority: priority))
        }
        let spoken = values.map { EVFormat.label($0) }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 10, metric: .linear)
    }

    private static func kelvin(_ scale: [Double]) -> DialScale {
        let range = WhiteBalanceMath.kelvinRange
        let marks: [Double] = [2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500, 7000, 7500, 8000, 9000, 10000]
        let presets = WhiteBalancePreset.allCases.compactMap(\.kelvin)
        // Round marks and preset temperatures replace their neighbours, so labels and presets land exactly.
        let specials = (marks + presets).filter { range.contains($0) }
        let values = merged(scale, specials: specials) { abs(1_000_000 / $0 - 1_000_000 / $1) < 2 }
        var candidates: [LabelCandidate] = []
        for (index, kelvin) in values.enumerated() where marks.contains(where: { abs($0 - kelvin) < 0.5 }) {
            let isEnd = index == 0 || index == values.count - 1
            let isThousand = abs(kelvin / 1000 - (kelvin / 1000).rounded()) < 1e-9
            let priority = isEnd ? 3 : (isThousand ? 2 : 1)
            candidates.append(LabelCandidate(index: index, text: "\(Int(kelvin.rounded()))", priority: priority))
        }
        let spoken = values.map { Formatting.kelvin($0) }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 10, metric: .mired)
    }

    private static func tint() -> DialScale {
        let range = WhiteBalanceMath.tintRange
        let values = Array(stride(from: range.lowerBound, through: range.upperBound, by: 5))
        var candidates: [LabelCandidate] = []
        for (index, tint) in values.enumerated() where abs(tint.truncatingRemainder(dividingBy: 50)) < 1e-9 {
            let priority = abs(tint) < 1e-9 ? 3 : 1
            candidates.append(LabelCandidate(index: index, text: Formatting.tint(tint), priority: priority))
        }
        let spoken = values.map { Formatting.tint($0) }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 10, metric: .linear)
    }

    private static func focus() -> DialScale {
        let values = (0...100).map { Double($0) / 100 }
        var candidates: [LabelCandidate] = []
        for index in stride(from: 0, through: 100, by: 10) {
            let text: String
            let priority: Int
            switch index {
            case 0: (text, priority) = ("near", 2)
            case 100: (text, priority) = ("far", 2)
            default: (text, priority) = ("\(index)%", 1)
            }
            candidates.append(LabelCandidate(index: index, text: text, priority: priority))
        }
        // The lens position has no distance unit, so the percentage of its travel is the honest reading.
        let spoken = (0...100).map { "\($0)%" }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 8, metric: .linear)
    }

    private static func zoom(_ span: ZoomSpan) -> DialScale {
        let values = zoomValues(span)
        var candidates: [LabelCandidate] = []
        for (index, zoom) in values.enumerated() {
            let isEnd = index == 0 || index == values.count - 1
            let isMark = span.marks.contains { isNear(zoom, $0, stops: 0.03) }
            let isFive = zoom >= 4.99 && abs(zoom / 5 - (zoom / 5).rounded()) < 0.002
            // Whole numbers below 5 fill the gaps on phones with one or two lenses.
            let isWhole = zoom >= 1.99 && zoom < 4.99 && abs(zoom - zoom.rounded()) < 0.005
            guard isEnd || isMark || isFive || isWhole else { continue }
            let priority = isMark ? 3 : (isEnd ? 2 : (isFive ? 1 : 0))
            candidates.append(LabelCandidate(index: index, text: LensMath.zoomLabel(zoom, selected: false), priority: priority))
        }
        let spoken = values.map { LensMath.zoomLabel($0, selected: true) }
        return DialScale(values: values, spoken: spoken, candidates: candidates, spacing: 10, metric: .logarithmic)
    }

    /// Display zoom the dial covers. With automatic lens switching it spans every back lens like the Camera app
    /// (up to five times the longest lens), so switching lenses mid-drag never rescales the ruler under the finger.
    static func zoomSpan(_ model: CameraModel) -> ZoomSpan {
        let caps = model.capabilities
        let lens = caps.lens
        let relative = lens.relativeZoom.isFinite && lens.relativeZoom > 0 ? lens.relativeZoom : 1
        let backLenses = model.lenses.filter { !$0.isFront && $0.kind != .external }
        let backIDs = Set(backLenses.map(\.id))
        let backPresets = model.lensPresets.filter { backIDs.contains($0.lensID) }
        let ownLower = max(relative * caps.zoomRange.lowerBound, 0.1)
        let ownUpper = relative * caps.zoomRange.upperBound

        let zooms = backLenses.map(\.relativeZoom).filter { $0.isFinite && $0 > 0 }
        // The model switches lenses only while idle with no photo still saving. During a countdown, a recording or a
        // save the dial keeps to the active lens, so it never offers a zoom the camera won't go to.
        if model.settings.controls.autoLensSwitching, !lens.isFront, !model.activity.isBusy, model.photosInFlight == 0,
           zooms.count > 1, let widest = zooms.min(), let longest = zooms.max() {
            let upper = max(min(longest * 5, 25), widest)
            return ZoomSpan(lower: widest, upper: upper, marks: backPresets.map(\.displayZoom))
        }
        let upper = max(min(ownUpper, relative * 5, 25), ownLower)
        let marks = lens.isFront ? [] : backPresets.filter { $0.lensID == lens.id }.map(\.displayZoom)
        return ZoomSpan(lower: ownLower, upper: upper, marks: marks)
    }

    /// Tenths up to 2×, then coarser steps so the long end stays a short swipe away, as on the Camera app dial.
    private static func zoomValues(_ span: ZoomSpan) -> [Double] {
        let lower = span.lower
        let upper = span.upper
        // The Int conversions below trap on NaN and on huge values; real spans end at 25×.
        guard lower.isFinite, upper.isFinite, lower > 0, upper < 1000 else { return [] }
        guard upper > lower * 1.01 else { return [lower] }
        // Whole hundredths keep repeated steps from drifting.
        let lowerHundredths = Int((lower * 100).rounded(.up))
        let upperHundredths = Int((upper * 100).rounded(.down))
        var grid: [Double] = []
        let firstStep = zoomStep(lowerHundredths)
        var hundredths = (lowerHundredths + firstStep - 1) / firstStep * firstStep
        while hundredths <= upperHundredths {
            grid.append(Double(hundredths) / 100)
            hundredths += zoomStep(hundredths)
        }
        let specials = [lower, upper] + span.marks.filter { $0 >= lower * 0.99 && $0 <= upper * 1.01 }
        return merged(grid, specials: specials) { isNear($0, $1, stops: 0.03) }
    }

    private static func zoomStep(_ hundredths: Int) -> Int {
        if hundredths < 200 { return 10 }
        if hundredths < 500 { return 20 }
        if hundredths < 1000 { return 50 }
        return 100
    }

    /// Sorted union where a special value replaces any plain value it would crowd.
    private static func merged(_ base: [Double], specials: [Double], tooClose: (Double, Double) -> Bool) -> [Double] {
        var entries: [(value: Double, special: Bool)] = []
        entries.reserveCapacity(base.count + specials.count)
        for value in base where value.isFinite { entries.append((value, false)) }
        for value in specials where value.isFinite { entries.append((value, true)) }
        entries.sort { $0.value < $1.value }
        var result: [(value: Double, special: Bool)] = []
        for entry in entries {
            if let last = result.last, tooClose(last.value, entry.value) {
                if entry.special && !last.special {
                    result[result.count - 1] = entry
                }
                continue
            }
            result.append(entry)
        }
        return result.map(\.value)
    }

    private static func isNear(_ a: Double, _ b: Double, stops: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(log2(a / b)) < stops
    }
}
