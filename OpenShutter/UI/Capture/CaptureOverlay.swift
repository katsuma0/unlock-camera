import SwiftUI
import CameraCore

/// Countdown, stacking progress, intervalometer and bracket status and the shutter flash, drawn over the viewfinder.
struct CaptureOverlay: View {
    @Bindable var model: CameraModel

    // Each layer reads only the state it shows, so a stack's progress or the flash never redraws the others.
    var body: some View {
        ZStack {
            StackPreviewLayer(model: model)
            CountdownLayer(model: model)
            StatusLayer(model: model)
            SavingLayer(model: model)
            ShutterFlashLayer(model: model)
        }
    }
}

// MARK: - Stack preview

/// The running result of a night or long exposure, laid exactly over the live preview so the picture builds up
/// where the scene is.
private struct StackPreviewLayer: View {
    let model: CameraModel

    var body: some View {
        let preview = model.activity == .stacking ? model.stackProgress?.preview : nil
        ZStack {
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The camera screen insets the overlay where its controls cover the picture; the preview must still fill
        // the whole frame to line up with the live image underneath.
        .ignoresSafeArea()
        .animation(.easeIn(duration: 0.4), value: preview != nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Countdown

private struct CountdownLayer: View {
    let model: CameraModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let remaining = Self.remaining(model.activity)
        ZStack {
            if let remaining {
                CountdownNumber(model: model, remaining: remaining)
                    .id(remaining)
                    // Each second's numeral grows in and shrinks away; with Reduce Motion they only cross-fade.
                    .transition(reduceMotion ? AnyTransition.opacity : .asymmetric(
                        insertion: .scale(scale: 1.35).combined(with: .opacity),
                        removal: .scale(scale: 0.7).combined(with: .opacity)
                    ))
                CountdownHint(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.35), value: remaining)
        .allowsHitTesting(false)
    }

    private static func remaining(_ activity: CaptureActivity) -> Int? {
        if case .countdown(let remaining) = activity { return remaining }
        return nil
    }
}

/// Reads motion only while counting down, so the numerals stay upright without the layer tracking the phone
/// the rest of the time.
private struct CountdownNumber: View {
    let model: CameraModel
    let remaining: Int

    var body: some View {
        Text("\(remaining)")
            .font(Theme.countdownFont)
            .foregroundStyle(Theme.primaryText)
            .shadow(color: .black.opacity(0.45), radius: 16)
            .uprightRotation(model.motion.iconRotationDegrees)
            .accessibilityLabel("\(remaining)")
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Sits just under the numerals rather than at the viewfinder's edge, where the controls can cover it, and turns
/// with them. Kept apart from the numerals so it doesn't replay their per-second transition.
private struct CountdownHint: View {
    let model: CameraModel

    var body: some View {
        Text("Tap the shutter to cancel")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .shadow(color: .black.opacity(0.6), radius: 4)
            .offset(y: 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .uprightRotation(model.motion.iconRotationDegrees)
    }
}

// MARK: - Status

/// Intervalometer, bracket and stack status with the buttons that end them. Only exists while something runs.
private struct StatusLayer: View {
    let model: CameraModel

    var body: some View {
        let isStacking = model.activity == .stacking
        let hasSequence = model.intervalometer != nil || model.bracketInProgress
        ZStack {
            if isStacking || hasSequence {
                StatusBlock(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: isStacking || hasSequence)
    }
}

private struct StatusBlock: View {
    let model: CameraModel
    /// Stop was tapped and the backend is merging what it has; the capsule says so instead of counting on.
    @State private var isFinishing = false

    var body: some View {
        let degrees = model.motion.iconRotationDegrees
        let isStacking = model.activity == .stacking
        GeometryReader { proxy in
            VStack(spacing: 10) {
                if let status = model.intervalometer {
                    IntervalStatusLine(status: status)
                }
                if model.bracketInProgress {
                    BracketStatusLine(model: model)
                }
                if isStacking {
                    StackStatusLine(progress: model.stackProgress, isFinishing: isFinishing)
                }
                StatusButtons(
                    canDiscard: isStacking && !isFinishing,
                    onStop: {
                        if model.activity == .stacking { isFinishing = true }
                        Haptics.tap()
                        model.stopCapture()
                    },
                    onDiscard: {
                        Haptics.warning()
                        model.cancelCapture()
                    }
                )
                .disabled(isFinishing)
            }
            .uprightRotation(degrees)
            // Below the middle in portrait, clear of the subject; centred when turned, where a sideways block fits.
            .position(x: proxy.size.width / 2, y: degrees == 0 ? proxy.size.height * 0.72 : proxy.size.height / 2)
            .animation(Theme.spring, value: degrees)
        }
        .onChange(of: model.activity) { _, activity in
            if activity != .stacking { isFinishing = false }
        }
    }
}

private struct IntervalStatusLine: View {
    let status: IntervalometerStatus

    var body: some View {
        if status.nextShotAt != nil {
            // The wait counts down between shots; nothing else here changes on its own.
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                StatusCapsuleText(text: Self.text(status, now: context.date))
            }
        } else {
            StatusCapsuleText(text: Self.text(status, now: Date()))
        }
    }

    /// "Shot 3 of 20 · next in 0:05".
    static func text(_ status: IntervalometerStatus, now: Date) -> String {
        var text = "Shot \(status.shot) of \(status.total)"
        if let next = status.nextShotAt {
            let wait = max(0, next.timeIntervalSince(now))
            text += " \u{00B7} next in " + Formatting.clock(wait)
        }
        return text
    }
}

/// "Focus bracket · 2 of 5". Each frame fires the shutter once, so frames are counted from the shutter count.
private struct BracketStatusLine: View {
    let model: CameraModel
    /// The shutter count when the bracket began.
    @State private var startCount: Int?
    /// The focus bracket's center when it began, kept because the lens moves while the bracket runs.
    @State private var startCenter: Double?

    var body: some View {
        let bracket = model.settings.capture.bracket
        let shutterCount = model.shutterCount
        let taken = max(0, shutterCount - (startCount ?? shutterCount))
        StatusCapsuleText(text: Self.text(bracket, focusCenter: startCenter ?? Self.focusCenter(model),
                                          frame: taken + 1, stopping: model.bracketStopping))
            .onAppear(perform: begin)
            // Back-to-back brackets in an intervalometer keep this view, so each new shot starts the count again.
            // The shot number changes in the same turn that starts the next bracket, before its first frame.
            .onChange(of: model.intervalometer?.shot) { begin() }
    }

    private func begin() {
        startCount = model.shutterCount
        startCenter = Self.focusCenter(model)
    }

    /// The model's center for a focus bracket: the manual focus distance, or where autofocus has the lens.
    private static func focusCenter(_ model: CameraModel) -> Double {
        model.settings.focus.lensPosition ?? model.readings.lensPosition
    }

    static func text(_ bracket: BracketPlan, focusCenter: Double, frame: Int, stopping: Bool = false) -> String {
        let title: String
        let total: Int
        // Counted the way the top bar's badge counts them. A focus spread wider than the lens travel piles frames on
        // its ends, so its count depends on the center, which the badge only knows under manual focus.
        switch bracket.kind {
        case .focus:
            title = "Focus bracket"
            total = bracket.focusPositions(center: focusCenter).count
        case .whiteBalance:
            title = "White balance bracket"
            total = bracket.kelvinValues(center: 5500).count
        case .exposure, .off:
            title = "Bracket"
            total = 0
        }
        // A stop waits for the frame in flight to save, which can take a second or two.
        if stopping { return title + " \u{00B7} stopping" }
        guard total > 1 else { return title }
        // The last frame is still saving after its shutter, so the count stops at the total.
        return title + " \u{00B7} \(min(frame, total)) of \(total)"
    }
}

private struct StackStatusLine: View {
    let progress: StackProgress?
    let isFinishing: Bool

    var body: some View {
        let fraction = Self.fraction(progress)
        // Counted in frames: the time estimate can pass 100% while the last frames are still coming in.
        let allFramesIn = progress.map { $0.framesPlanned > 0 && $0.framesCaptured >= $0.framesPlanned } ?? false
        let processing = isFinishing || allFramesIn
        HStack(spacing: 8) {
            if processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.primaryText)
            } else if progress?.framesPlanned == 0 {
                // Bulb has no end to measure against, so a pulsing dot marks the open shutter.
                Circle()
                    .fill(Theme.recording)
                    .frame(width: 8, height: 8)
                    .phaseAnimator([1.0, 0.35]) { dot, opacity in
                        dot.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 0.6)
                    }
            } else {
                ProgressRing(fraction: fraction)
            }
            Text(processing ? "Processing" : Self.text(progress))
                .contentTransition(.numericText())
        }
        .font(Theme.valueFont)
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .cameraGlass(in: Capsule())
        .animation(Theme.snappy, value: processing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(processing ? "Processing" : "Exposure in progress")
        .accessibilityValue(processing ? "" : Self.text(progress))
    }

    private static func fraction(_ progress: StackProgress?) -> Double {
        guard let value = progress?.fraction, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// "12 of 30 · 0:08" counting down to the planned end; bulb counts up: "12 frames · 0:08".
    static func text(_ progress: StackProgress?) -> String {
        guard let progress else { return "Starting" }
        let captured = max(0, progress.framesCaptured)
        let elapsed = progress.elapsed.isFinite ? max(0, progress.elapsed) : 0
        if progress.framesPlanned > 0 {
            let clock: String
            if let total = progress.estimatedTotal, total.isFinite {
                clock = Formatting.clock(max(0, total - elapsed))
            } else {
                clock = Formatting.clock(elapsed.rounded(.down))
            }
            return "\(captured) of \(progress.framesPlanned) \u{00B7} \(clock)"
        }
        let frames = captured == 1 ? "1 frame" : "\(captured) frames"
        return frames + " \u{00B7} " + Formatting.clock(elapsed.rounded(.down))
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(.linear(duration: 0.15), value: fraction)
    }
}

private struct StatusCapsuleText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.valueFont)
            .foregroundStyle(Theme.primaryText)
            .contentTransition(.numericText())
            .padding(.horizontal, 14)
            .frame(height: 34)
            .cameraGlass(in: Capsule())
    }
}

private struct StatusButtons: View {
    let canDiscard: Bool
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if canDiscard {
                Button(action: onDiscard) {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .cameraGlass(in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                .accessibilityHint("Ends the exposure without saving it.")
                .transition(.opacity)
            }
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(Theme.accent, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .accessibilityHint("Ends now and keeps what has been captured.")
        }
        .animation(Theme.snappy, value: canDiscard)
    }
}

// MARK: - Saving and flash

private struct SavingLayer: View {
    let model: CameraModel

    var body: some View {
        let isSaving = model.activity == .saving
        ZStack {
            if isSaving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.primaryText)
                    Text("Saving")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .cameraGlass(in: Capsule())
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: isSaving)
        .allowsHitTesting(false)
    }
}

/// A short white blink each time the backend fires the shutter, so timer and intervalometer shots are visible too.
private struct ShutterFlashLayer: View {
    let model: CameraModel
    @State private var opacity = 0.0

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.shutterCount) { _, _ in
                // Two steps: a change and its reversal in one transaction would never reach the screen.
                withAnimation(.linear(duration: 0.04)) {
                    opacity = 0.6
                } completion: {
                    withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
                }
            }
    }
}
