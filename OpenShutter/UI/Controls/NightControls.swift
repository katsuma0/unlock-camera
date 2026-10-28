import SwiftUI
import CameraCore

/// NIGHT mode: the duration (automatic from the light, or 1 to 30 s), how steady the phone is, and the frames the
/// shot will take. The duration capsule opens its own dial, since night duration has no `DialKind`.
struct NightControls: View {
    @Bindable var model: CameraModel
    @State private var isDialOpen = false

    var body: some View {
        let locked = model.activity.isBusy
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                NightDurationButton(model: model, isOpen: isDialOpen, action: toggleDial)
                Spacer(minLength: 4)
                StabilityPicker(model: model)
            }
            NightPlanLine(model: model)
            if isDialOpen {
                NightDurationDial(model: model)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .animation(Theme.spring, value: isDialOpen)
        .animation(Theme.snappy, value: locked)
        // One dial at a time: the shared dial (EV, zoom) and this one would stack up in the controls area.
        .onChange(of: model.activeDial) { _, dial in
            if dial != nil { isDialOpen = false }
        }
        .onChange(of: locked) { _, isLocked in
            if isLocked { isDialOpen = false }
        }
    }

    private func toggleDial() {
        Haptics.tick()
        if !isDialOpen, model.activeDial != nil {
            model.activeDial = nil
        }
        isDialOpen.toggle()
    }
}

// MARK: - Duration

private struct NightDurationButton: View {
    let model: CameraModel
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        let manual = model.settings.night.seconds
        // The automatic estimate follows the light, so it is only read (and redrawn at 10 Hz) while it shows.
        let seconds = manual ?? model.nightAutoSeconds
        let text = NightText.duration(seconds, isAuto: manual == nil)
        Button(action: action) {
            HStack(spacing: 6) {
                UprightImage(model: model, systemName: "moon.fill")
                    .foregroundStyle(Theme.accent)
                Text(text)
                    .foregroundStyle(manual == nil ? Theme.primaryText : Theme.accent)
                    .contentTransition(.numericText(value: seconds))
            }
        }
        .buttonStyle(NightChipStyle(isSelected: isOpen))
        // Keyed to auto, not the text: a drag of the dial below changes the text on every tick.
        .animation(Theme.snappy, value: manual == nil)
        .accessibilityLabel(Text("Night mode duration"))
        .accessibilityValue(Text(manual == nil ? "Auto, " + Formatting.compactDuration(seconds) : Formatting.compactDuration(seconds)))
        .accessibilityHint(Text(isOpen ? "Hides the duration dial." : "Shows a dial to set the duration."))
    }
}

private struct NightDurationDial: View {
    let model: CameraModel
    @State private var selection: Int?
    @State private var isEditing = false

    var body: some View {
        let fallback = selection ?? NightScale.nearestIndex(to: NightScale.current(model))
        VStack(spacing: 4) {
            NightDialHeader(model: model)
            RulerDial(
                values: NightScale.values,
                index: Binding(
                    get: { NightScale.clamped(selection ?? fallback) },
                    set: { userSelected($0, fallback: fallback) }
                ),
                majorTick: { NightScale.isMajor($0) },
                label: { NightScale.label($0) },
                spacing: 12,
                onEditingChanged: { editing in isEditing = editing }
            )
            // RulerDial calls itself "Dial"; the header above it is a separate element.
            .accessibilityLabel(Text("Night mode duration"))
            .background {
                NightDialFollower(model: model, onTarget: follow)
                    .allowsHitTesting(false)
            }
        }
    }

    private func userSelected(_ index: Int, fallback: Int) {
        guard NightScale.values.indices.contains(index) else { return }
        let current = NightScale.clamped(selection ?? fallback)
        selection = index
        // A dial that re-sends its own index must not switch an automatic duration to a fixed one.
        guard index != current else { return }
        model.setNightSeconds(NightScale.values[index])
    }

    private func follow(_ target: Int) {
        guard !isEditing, selection != target else { return }
        selection = target
    }
}

/// Reads the live duration in its own body, so light changes re-run this tiny view and not the ruler.
private struct NightDialFollower: View {
    let model: CameraModel
    let onTarget: (Int) -> Void

    var body: some View {
        let target = NightScale.nearestIndex(to: NightScale.current(model))
        Color.clear
            .onChange(of: target, initial: true) { _, newValue in
                onTarget(newValue)
            }
    }
}

private struct NightDialHeader: View {
    let model: CameraModel

    var body: some View {
        let manual = model.settings.night.seconds
        let seconds = manual ?? model.nightAutoSeconds
        // The header's A badge and lit AUTO button already say auto, so the value is the bare duration.
        DialValueHeader(
            title: "Duration",
            value: Formatting.compactDuration(seconds),
            isAuto: manual == nil,
            onAuto: {
                Haptics.tap()
                model.setNightSeconds(nil)
            }
        )
    }
}

@MainActor
private enum NightScale {
    /// Half seconds where they matter (under 10 s), whole seconds above, over the planner's 1 to 30 s.
    static let values: [Double] = {
        let range = NightModePlanner.secondsRange
        var values: [Double] = []
        var halves = Int((range.lowerBound * 2).rounded(.up))
        while Double(halves) / 2 < min(10, range.upperBound) {
            values.append(Double(halves) / 2)
            halves += 1
        }
        var whole = Int(max(10, range.lowerBound).rounded(.up))
        while Double(whole) <= range.upperBound {
            values.append(Double(whole))
            whole += 1
        }
        return values
    }()

    /// At least four ticks apart: RulerDial thins every label to a fixed period once two neighbours sit closer than
    /// its widest label plus 8 pt, which would drop "10s" from this uneven pattern.
    private static let labelled: Set<Double> = [1, 3, 5, 7, 10, 15, 20, 25, 30]

    static func isMajor(_ index: Int) -> Bool {
        guard values.indices.contains(index) else { return false }
        return labelled.contains(values[index])
    }

    /// Every tick has text: RulerDial draws it over the long ticks and VoiceOver reads it for the selected one.
    static func label(_ index: Int) -> String {
        guard values.indices.contains(index) else { return "" }
        return Formatting.compactDuration(values[index])
    }

    static func clamped(_ index: Int) -> Int {
        min(max(index, 0), max(values.count - 1, 0))
    }

    static func nearestIndex(to seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        var best = 0
        var bestGap = Double.infinity
        for (index, value) in values.enumerated() where abs(value - seconds) < bestGap {
            best = index
            bestGap = abs(value - seconds)
        }
        return best
    }

    static func current(_ model: CameraModel) -> Double {
        model.settings.night.seconds ?? model.nightAutoSeconds
    }
}

// MARK: - Stability

private struct StabilityPicker: View {
    let model: CameraModel
    @Namespace private var selectionSpace

    var body: some View {
        let current = model.settings.night.stability
        HStack(spacing: 0) {
            ForEach(NightStabilityChoice.allCases) { choice in
                Button {
                    guard choice != current else { return }
                    Haptics.tick()
                    withAnimation(Theme.snappy) {
                        model.setNightStability(choice)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if choice == .automatic {
                            SteadyIndicator(model: model)
                        }
                        Text(choice.title)
                    }
                    .font(Theme.chipFont)
                    .foregroundStyle(choice == current ? Theme.accent : Theme.primaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background {
                        if choice == current {
                            Capsule()
                                .fill(Theme.primaryText.opacity(0.16))
                                .matchedGeometryEffect(id: "selection", in: selectionSpace)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == current ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .background {
            Capsule()
                .fill(Color.clear)
                .frame(height: 34)
                .cameraGlass(in: Capsule())
        }
    }
}

/// What automatic stability sees right now: a tripod when the phone has been still, a hand otherwise.
private struct SteadyIndicator: View {
    let model: CameraModel

    var body: some View {
        let steady = model.motion.isSteady
        ZStack {
            if steady {
                TripodGlyph()
                    .frame(width: 10, height: 11)
                    .foregroundStyle(Theme.accent)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 12, height: 12)
        .uprightRotation(model.motion.iconRotationDegrees)
        .animation(Theme.snappy, value: steady)
        .accessibilityLabel(Text(steady ? "Phone is steady" : "Phone is moving"))
    }
}

/// SF Symbols has no tripod, so a small one is drawn here: a camera head on three legs.
private struct TripodGlyph: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let head = CGRect(x: width * 0.2, y: 0, width: width * 0.6, height: height * 0.3)
            context.fill(Path(roundedRect: head, cornerRadius: height * 0.07), with: .foreground)
            let top = CGPoint(x: width * 0.5, y: height * 0.34)
            var legs = Path()
            for foot in [CGPoint(x: width * 0.1, y: height), CGPoint(x: width * 0.5, y: height), CGPoint(x: width * 0.9, y: height)] {
                legs.move(to: top)
                legs.addLine(to: foot)
            }
            context.stroke(legs, with: .foreground, style: StrokeStyle(lineWidth: max(1, width * 0.13), lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Plan

private struct NightPlanLine: View {
    let model: CameraModel

    var body: some View {
        let text = NightText.plan(model.nightPlan)
        Text(text)
            .font(Theme.readoutFont)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            // Rolls only inside an explicit animation: the plan follows the 10 Hz light readings.
            .contentTransition(.numericText())
            .accessibilityLabel(Text("Plan: " + text))
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

private struct NightChipStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chipFont)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 32)
            .cameraGlass(in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Theme.accent.opacity(isSelected ? 0.8 : 0), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .animation(Theme.spring, value: isSelected)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private enum NightText {
    /// "Auto · 3s" or "10s".
    static func duration(_ seconds: Double, isAuto: Bool) -> String {
        let value = Formatting.compactDuration(seconds)
        return isAuto ? "Auto \u{00B7} " + value : value
    }

    /// "12 frames × 1/4s · ISO 640".
    static func plan(_ plan: StackPlan) -> String {
        let frames = plan.frameCount == 1 ? "1 frame" : "\(plan.frameCount) frames"
        let speed = ShutterSpeed(seconds: plan.frameSeconds)
        let shutter = speed.isFraction ? speed.label + "s" : speed.label
        return "\(frames) \u{00D7} \(shutter) \u{00B7} \(ISOScale.label(plan.iso))"
    }
}
