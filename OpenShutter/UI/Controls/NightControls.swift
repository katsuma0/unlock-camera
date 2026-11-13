import SwiftUI
import CameraCore

/// NIGHT mode: the duration (automatic from the light, or 1 to 30 s) and, in the advanced interface, how steady the
/// phone is and the frames the shot will take. The simple interface shows one line of advice in their place. The
/// duration capsule opens its own dial, since night duration has no `DialKind`; touch and hold lists a few durations.
struct NightControls: View {
    @Bindable var model: CameraModel
    @State private var isDialOpen = false

    var body: some View {
        let locked = model.activity.isBusy
        VStack(spacing: 6) {
            NightHeaderRows(model: model, isDialOpen: $isDialOpen)
            if isDialOpen {
                NightDurationDial(model: model, isOpen: $isDialOpen)
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
        // VoiceOver stays on the button that opened the dial, so its escape gesture has to work from there as well
        // as from the dial.
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if isDialOpen { NightDial.close($isDialOpen) }
        }
    }
}

/// The duration button and what goes with it at each interface level. The level is a setting, and pinches and
/// dials write the settings many times a second, so it is read here and not by the panel with its dial.
private struct NightHeaderRows: View {
    let model: CameraModel
    @Binding var isDialOpen: Bool

    var body: some View {
        if model.isAdvanced {
            HStack(spacing: 8) {
                NightDurationButton(model: model, isDialOpen: $isDialOpen)
                Spacer(minLength: 4)
                StabilityPicker(model: model)
            }
            NightPlanLine(model: model)
        } else {
            // Stability stays on automatic and the frames are the camera's business, so the button stands alone
            // over a line of advice.
            NightDurationButton(model: model, isDialOpen: $isDialOpen)
            NightHintLine(model: model)
        }
    }
}

// MARK: - Duration

private struct NightDurationButton: View {
    let model: CameraModel
    @Binding var isDialOpen: Bool
    @State private var press = PressTracker()

    var body: some View {
        let manual = model.settings.night.seconds
        // The automatic estimate follows the light, so it is only read (and redrawn at 10 Hz) while it shows.
        let seconds = manual ?? model.nightAutoSeconds
        let text = NightText.duration(seconds, isAuto: manual == nil)
        HStack(spacing: 6) {
            UprightImage(model: model, systemName: "moon.fill")
                .foregroundStyle(Theme.accent)
            Text(text)
                .foregroundStyle(manual == nil ? Theme.primaryText : Theme.accent)
                .contentTransition(.numericText(value: seconds))
        }
        .modifier(NightChipLook(isSelected: isDialOpen, isPressed: press.isPressed))
        .onTapGesture {
            NightDial.toggle($isDialOpen, model: model)
        }
        .overlay {
            NightDurationTouchLayer(model: model, isDialOpen: $isDialOpen, press: press)
        }
        // Keyed to auto, not the text: a drag of the dial below changes the text on every tick.
        .animation(Theme.snappy, value: manual == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Night mode duration"))
        .accessibilityValue(Text(manual == nil ? "Auto, " + Formatting.compactDuration(seconds) : Formatting.compactDuration(seconds)))
        .accessibilityHint(Text((isDialOpen ? "Hides the duration dial. " : "Shows a dial to set the duration. ") + HoldMenuText.hint))
        .accessibilityAction {
            NightDial.toggle($isDialOpen, model: model)
        }
        .accessibilityActions {
            if manual != nil {
                Button("Return to auto") {
                    model.setNightSeconds(nil)
                }
            }
        }
    }
}

/// The button's tap and its touch and hold menu, apart from the face: the automatic duration on the face follows
/// the light, and this layer's inputs never change.
private struct NightDurationTouchLayer: View {
    let model: CameraModel
    @Binding var isDialOpen: Bool
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            NightDial.toggle($isDialOpen, model: model)
        } options: {
            NightDurationMenu(model: model)
        }
    }
}

private struct NightDurationMenu: View {
    let model: CameraModel

    /// Inside the planner's 1 to 30 s, like the dial.
    private static let durations: [Double] = [3, 5, 10, 15, 30]

    var body: some View {
        let manual = model.settings.night.seconds
        Section("Duration") {
            HoldMenuChoice("Auto", isOn: manual == nil) {
                model.setNightSeconds(nil)
            }
            ForEach(Self.durations, id: \.self) { seconds in
                HoldMenuChoice(HoldMenuText.time(seconds), isOn: manual.map { abs($0 - seconds) < 0.01 } ?? false) {
                    model.setNightSeconds(seconds)
                }
            }
        }
    }
}

@MainActor
private enum NightDial {
    /// Opens or closes the duration dial, closing the shared dial first. The panel animates the change.
    static func toggle(_ isOpen: Binding<Bool>, model: CameraModel) {
        Haptics.tick()
        if !isOpen.wrappedValue, model.activeDial != nil {
            model.activeDial = nil
        }
        isOpen.wrappedValue.toggle()
    }

    /// Done, a swipe down and VoiceOver's escape gesture all end here.
    static func close(_ isOpen: Binding<Bool>) {
        Haptics.tick()
        isOpen.wrappedValue = false
    }
}

private struct NightDurationDial: View {
    let model: CameraModel
    @Binding var isOpen: Bool
    @State private var selection: Int?
    @State private var isEditing = false

    var body: some View {
        let fallback = selection ?? NightScale.nearestIndex(to: NightScale.current(model))
        VStack(spacing: 4) {
            NightDialHeader(model: model, isOpen: $isOpen)
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
        .closesDial(named: "Night mode duration dial") {
            NightDial.close($isOpen)
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
    @Binding var isOpen: Bool

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
            },
            onDone: {
                NightDial.close($isOpen)
            },
            // This dial opens inside the panel, with the modes still in view below it.
            doneHint: "Closes the dial."
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

/// The simple interface's one line of advice, where the advanced one has the stability picker and the plan. Reads
/// motion on its own, so the attitude updates redraw only this line.
private struct NightHintLine: View {
    let model: CameraModel

    var body: some View {
        let steady = model.motion.isSteady
        ZStack {
            Text(steady ? NightText.steadyHint : NightText.handheldHint)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .id(steady)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        // The controls sit in a fixed band above the shutter; the largest text sizes would push them up the picture.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(Theme.snappy, value: steady)
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

/// The duration capsule: glass, outlined in yellow while its dial is open, in a 44 pt touch area.
private struct NightChipLook: ViewModifier {
    var isSelected: Bool
    var isPressed: Bool

    func body(content: Content) -> some View {
        content
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
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: isPressed)
            .animation(Theme.spring, value: isSelected)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private enum NightText {
    static let handheldHint = "Hold still until it finishes."
    /// The longest duration follows the planner's range.
    static let steadyHint = "On a tripod it can run up to \(Int(NightModePlanner.secondsRange.upperBound)) s."

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
