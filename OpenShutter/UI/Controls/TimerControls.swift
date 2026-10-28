import SwiftUI
import CameraCore

/// Sheet for the self timer, intervalometer and brackets. Edits a draft; Done writes it to the settings in one go,
/// so a half-set intervalometer never fires.
struct TimerControls: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    @State private var schedule: CaptureSchedule
    @State private var bracket: BracketPlan
    /// The last plan per kind, so flipping between kinds keeps what was set for each one.
    @State private var bracketMemory: [BracketKind: BracketPlan]
    private let originalSchedule: CaptureSchedule
    private let originalBracket: BracketPlan

    init(model: CameraModel) {
        _model = Bindable(model)
        let capture = model.settings.capture
        let bracket = TimerOptions.normalized(capture.bracket, capabilities: model.capabilities)
        originalSchedule = capture.schedule
        originalBracket = bracket
        _schedule = State(initialValue: capture.schedule)
        _bracket = State(initialValue: bracket)
        _bracketMemory = State(initialValue: [bracket.kind: bracket])
    }

    private var hasChanges: Bool {
        schedule != originalSchedule || bracket != originalBracket
    }

    var body: some View {
        NavigationStack {
            Form {
                timerSection
                shotsSection
                bracketSection
            }
            .navigationTitle("Timer and brackets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: apply)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        // Swiping the sheet away would drop the draft without a word; Cancel says it out loud.
        .interactiveDismissDisabled(hasChanges)
    }

    // MARK: Sections

    private var timerSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(CaptureSchedule.delayPresets, id: \.self) { preset in
                    delayPresetButton(preset)
                }
            }
            Stepper(
                label: { LabeledContent("Delay", value: TimerText.delay(schedule.delay)) },
                onIncrement: schedule.delay < TimerOptions.delayRange.upperBound ? {
                    schedule.delay = TimerOptions.stepped(schedule.delay, up: true, range: TimerOptions.delayRange)
                } : nil,
                onDecrement: schedule.delay > TimerOptions.delayRange.lowerBound ? {
                    schedule.delay = TimerOptions.stepped(schedule.delay, up: false, range: TimerOptions.delayRange)
                } : nil
            )
        } header: {
            Text("Self timer")
        } footer: {
            Text("Counts down before the first shot. Video and bulb start right away.")
        }
    }

    private var shotsSection: some View {
        Section {
            Stepper(
                label: { LabeledContent("Shots", value: "\(schedule.shots)") },
                onIncrement: schedule.shots < TimerOptions.shotsRange.upperBound ? {
                    schedule.shots = TimerOptions.stepped(schedule.shots, up: true)
                } : nil,
                onDecrement: schedule.shots > TimerOptions.shotsRange.lowerBound ? {
                    schedule.shots = TimerOptions.stepped(schedule.shots, up: false)
                } : nil
            )
            Stepper(
                label: { LabeledContent("Interval", value: TimerText.interval(schedule.interval)) },
                onIncrement: schedule.interval < TimerOptions.intervalRange.upperBound ? {
                    schedule.interval = TimerOptions.stepped(schedule.interval, up: true, range: TimerOptions.intervalRange)
                } : nil,
                onDecrement: schedule.interval > TimerOptions.intervalRange.lowerBound ? {
                    schedule.interval = TimerOptions.stepped(schedule.interval, up: false, range: TimerOptions.intervalRange)
                } : nil
            )
            // One shot has nothing to space out.
            .disabled(schedule.shots < 2)
            LabeledContent("Plan", value: schedule.summary)
            if schedule.shots > 1 {
                LabeledContent("Last shot starts", value: TimerText.after(schedule.plannedDuration))
            }
        } header: {
            Text("Intervalometer")
        } footer: {
            Text("The interval runs from the start of one shot to the start of the next. A shot that runs long pushes the next one back.")
        }
    }

    private var bracketSection: some View {
        let capabilities = model.capabilities
        let kinds = TimerOptions.kinds(for: capabilities, including: bracket.kind)
        let counts = TimerOptions.counts(for: bracket.kind, maxCount: capabilities.maxBracketCount)
        let steps = TimerOptions.steps(for: bracket.kind)
        let countIndex = TimerOptions.nearestIndex(of: Double(bracket.count), in: counts.map(Double.init))
        let stepIndex = TimerOptions.nearestIndex(of: bracket.step, in: steps)
        return Section {
            Picker("Bracket", selection: Binding(get: { bracket.kind }, set: selectKind)) {
                ForEach(kinds) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            if bracket.kind != .off, counts.indices.contains(countIndex), steps.indices.contains(stepIndex) {
                Stepper(
                    label: { LabeledContent("Frames", value: "\(counts[countIndex])") },
                    onIncrement: countIndex + 1 < counts.count ? { setCount(counts[countIndex + 1]) } : nil,
                    onDecrement: countIndex > 0 ? { setCount(counts[countIndex - 1]) } : nil
                )
                Stepper(
                    label: { LabeledContent("Step", value: TimerText.step(steps[stepIndex], kind: bracket.kind)) },
                    onIncrement: stepIndex + 1 < steps.count ? { setStep(steps[stepIndex + 1]) } : nil,
                    onDecrement: stepIndex > 0 ? { setStep(steps[stepIndex - 1]) } : nil
                )
                LabeledContent("Plan", value: bracket.summary)
            }
        } header: {
            Text("Bracket")
        } footer: {
            Text(TimerText.bracketFooter(bracket.kind, maxCount: capabilities.maxBracketCount))
        }
    }

    private func delayPresetButton(_ preset: Double) -> some View {
        let selected = abs(schedule.delay - preset) < 0.01
        let title = TimerText.delay(preset)
        return Button {
            Haptics.tick()
            schedule.delay = preset
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.black : Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Capsule().fill(selected ? Theme.accent : Theme.primaryText.opacity(0.12)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        // Several buttons in one Form row: borderless keeps each tap on its own button.
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(preset <= 0 ? "Timer off" : title + " timer"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Changes

    private func selectKind(_ kind: BracketKind) {
        guard kind != bracket.kind else { return }
        Haptics.tick()
        bracketMemory[bracket.kind] = bracket
        bracket = bracketMemory[kind] ?? TimerOptions.defaultPlan(for: kind)
    }

    private func setCount(_ count: Int) {
        bracket = BracketPlan(kind: bracket.kind, count: count, step: bracket.step)
    }

    private func setStep(_ step: Double) {
        bracket = BracketPlan(kind: bracket.kind, count: bracket.count, step: step)
    }

    private func apply() {
        let newSchedule = schedule
        let newBracket = bracket
        model.updateSettings { settings in
            settings.capture.schedule = newSchedule
            settings.capture.bracket = newBracket
        }
        Haptics.tap()
        dismiss()
    }
}

// MARK: - Options

private enum TimerOptions {
    static let delayRange: ClosedRange<Double> = 0...600
    static let intervalRange: ClosedRange<Double> = 0...3600
    static let shotsRange: ClosedRange<Int> = 1...9999

    /// Single seconds where they matter, bigger steps where nobody counts them, so the stepper stays usable to an hour.
    static func stepped(_ value: Double, up: Bool, range: ClosedRange<Double>) -> Double {
        let current = value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
        let ladder: [(limit: Double, step: Double)] = [(10, 1), (60, 5), (600, 30)]
        let step = ladder.first(where: { up ? current < $0.limit : current <= $0.limit })?.step ?? 60
        let next = up ? ((current / step).rounded(.down) + 1) * step : ((current / step).rounded(.up) - 1) * step
        return min(max(next, range.lowerBound), range.upperBound)
    }

    static func stepped(_ value: Int, up: Bool) -> Int {
        let current = min(max(value, shotsRange.lowerBound), shotsRange.upperBound)
        let ladder: [(limit: Int, step: Int)] = [(20, 1), (100, 5), (1000, 50)]
        let step = ladder.first(where: { up ? current < $0.limit : current <= $0.limit })?.step ?? 500
        let next = up ? (current / step + 1) * step : ((current + step - 1) / step - 1) * step
        return min(max(next, shotsRange.lowerBound), shotsRange.upperBound)
    }

    /// Kinds this camera can shoot. The current one stays listed so the picker always has a selection.
    static func kinds(for capabilities: CameraCapabilities, including current: BracketKind) -> [BracketKind] {
        BracketKind.allCases.filter { kind in
            if kind == current { return true }
            switch kind {
            case .off: return true
            case .exposure: return capabilities.maxBracketCount >= 3
            case .focus: return capabilities.supportsManualFocus
            case .whiteBalance: return capabilities.supportsCustomWhiteBalance
            }
        }
    }

    /// Exposure brackets are one hardware burst, capped by the photo output; the others are separate shots.
    static func counts(for kind: BracketKind, maxCount: Int) -> [Int] {
        switch kind {
        case .off: return []
        case .exposure: return [3, 5, 7, 9].filter { $0 <= max(maxCount, 3) }
        case .whiteBalance: return [3, 5, 7, 9]
        case .focus: return Array(2...30)
        }
    }

    static func steps(for kind: BracketKind) -> [Double] {
        switch kind {
        case .off: return []
        case .exposure: return [1.0 / 3, 2.0 / 3, 1, 4.0 / 3, 5.0 / 3, 2, 7.0 / 3, 8.0 / 3, 3]
        case .focus: return [0.005, 0.01, 0.02, 0.03, 0.05, 0.08, 0.1, 0.15, 0.2, 0.3, 0.5]
        case .whiteBalance: return [5, 10, 15, 20, 30, 40, 50, 75, 100]
        }
    }

    static func defaultPlan(for kind: BracketKind) -> BracketPlan {
        switch kind {
        case .off: return .off
        case .exposure: return BracketPlan(kind: .exposure, count: 3, step: 1)
        case .focus: return BracketPlan(kind: .focus, count: 5, step: 0.05)
        case .whiteBalance: return BracketPlan(kind: .whiteBalance, count: 3, step: 10)
        }
    }

    /// Snaps a stored plan to the choices the steppers offer, so the sheet shows what will really be shot.
    static func normalized(_ plan: BracketPlan, capabilities: CameraCapabilities) -> BracketPlan {
        let allowedCounts = Self.counts(for: plan.kind, maxCount: capabilities.maxBracketCount)
        let allowedSteps = Self.steps(for: plan.kind)
        guard plan.kind != .off, !allowedCounts.isEmpty, !allowedSteps.isEmpty else { return plan }
        let count = allowedCounts[nearestIndex(of: Double(plan.count), in: allowedCounts.map(Double.init))]
        let step = allowedSteps[nearestIndex(of: plan.step, in: allowedSteps)]
        return BracketPlan(kind: plan.kind, count: count, step: step)
    }

    static func nearestIndex(of value: Double, in values: [Double]) -> Int {
        guard value.isFinite else { return 0 }
        var best = 0
        var bestGap = Double.infinity
        for (index, candidate) in values.enumerated() where abs(candidate - value) < bestGap {
            best = index
            bestGap = abs(candidate - value)
        }
        return best
    }
}

private enum TimerText {
    static func delay(_ seconds: Double) -> String {
        seconds <= 0 ? "Off" : Formatting.compactDuration(seconds)
    }

    static func interval(_ seconds: Double) -> String {
        seconds <= 0 ? "Back to back" : Formatting.compactDuration(seconds)
    }

    static func after(_ seconds: Double) -> String {
        seconds <= 0 ? "Right away" : "After " + Formatting.compactDuration(seconds)
    }

    static func step(_ step: Double, kind: BracketKind) -> String {
        switch kind {
        case .exposure: return "\u{00B1}" + trimmed(step) + " EV"
        case .focus: return trimmed(step * 100) + "% of the range"
        case .whiteBalance: return trimmed(step) + " mired"
        case .off: return ""
        }
    }

    static func bracketFooter(_ kind: BracketKind, maxCount: Int) -> String {
        let modes = "Works in photo and manual modes."
        switch kind {
        case .off:
            return "Brackets take several photos from one press. " + modes
        case .exposure:
            let limit = maxCount < 9 ? " This camera takes up to \(max(maxCount, 3)) frames." : ""
            return "One burst of photos spaced evenly darker and brighter than the metered exposure. " + modes + limit
        case .focus:
            return "Moves the focus between shots, for focus stacking later. Use a tripod. " + modes
        case .whiteBalance:
            return "Shifts the color temperature between shots. " + modes
        }
    }

    /// One decimal, ".0" dropped: 1 -> "1", 0.333 -> "0.3".
    private static func trimmed(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e9 else { return "0" }
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}
