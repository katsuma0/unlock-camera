import SwiftUI
import CameraCore

/// The battery saver's black screen during a long shot. On an OLED panel a black pixel is off, which saves more than a
/// lower brightness under a lit picture; the model lowers the brightness under it too, for LCD panels. A few dim lines
/// say what happened and how long is left, and move a few points each minute so a long shot can't mark the panel.
/// The first touch only lights the screen again: it never reaches Stop, Cancel or the shutter underneath.
///
/// Lay it over everything, the bands and controls included, ignoring the safe area. It takes touches only while dark.
struct DimOverlay: View {
    let model: CameraModel

    var body: some View {
        let isDimmed = model.dimmer.isDimmed
        ZStack {
            if isDimmed {
                DimScreen(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(isDimmed)
        // Darkens slowly, so the brightness step that follows happens on black, and lights up quickly.
        .animation(isDimmed ? .easeIn(duration: 0.6) : .easeOut(duration: 0.25), value: isDimmed)
        // The Camera Control's overlay sits over the picture, which has to be seen to use it.
        .onChange(of: model.controlsFullscreen) { _, fullscreen in
            if fullscreen, model.dimmer.isDimmed { model.wakeScreen() }
        }
    }
}

private struct DimScreen: View {
    let model: CameraModel
    /// When the shot ends, or began for one that runs until stopped. Read from the progress every few seconds rather
    /// than with each of its several reports a second, which would keep redrawing the dark screen.
    @State private var clock: DimClock?
    @AccessibilityFocusState private var isFocused: Bool

    private static let title = "Screen dimmed to save battery"

    var body: some View {
        // Once a second for the time left; nothing else here changes on its own.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let time = DimTime(clock: clock, now: context.date)
            ZStack {
                Color.black
                DimLines(title: Self.title, time: time?.shown)
                    .offset(Self.shift(at: context.date))
                    .modifier(DimUpright(model: model))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.title + "." + (time.map { " " + $0.spoken } ?? "")))
            .accessibilityHint(Text("Double tap to light the screen."))
            // Nothing under the black can be seen, so VoiceOver stays on it until it lights up.
            .accessibilityAddTraits(.isModal)
            .accessibilityAction { wake() }
            .accessibilityFocused($isFocused)
        }
        .contentShape(Rectangle())
        // Any touch, not only a tap: a finger that lands to swipe or hold wakes the screen as well.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in wake() })
        .task { await followProgress() }
        .task {
            // Once it has faded in, so VoiceOver reads the dark screen instead of a control it hides.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            isFocused = true
        }
    }

    private func wake() {
        guard model.dimmer.isDimmed else { return }
        model.wakeScreen()
    }

    /// Outside body, so the progress reports never register as something this view draws from.
    private func followProgress() async {
        while !Task.isCancelled {
            let next = DimClock(model.stackProgress, now: Date())
            if !DimClock.isClose(next, clock) { clock = next }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// A few points one way or another each minute, round a small square, so no pixel stays lit for the whole shot.
    private static func shift(at date: Date) -> CGSize {
        let steps: [CGSize] = [
            .zero, CGSize(width: 6, height: 0), CGSize(width: 6, height: 6), CGSize(width: 0, height: 6),
            CGSize(width: -6, height: 6), CGSize(width: -6, height: 0), CGSize(width: -6, height: -6),
            CGSize(width: 0, height: -6), CGSize(width: 6, height: -6),
        ]
        let minutes = date.timeIntervalSinceReferenceDate / 60
        guard minutes.isFinite, abs(minutes) < 1e12 else { return .zero }
        let index = Int(minutes.rounded(.down)) % steps.count
        return steps[index < 0 ? index + steps.count : index]
    }
}

/// Reads the phone's turn on its own, so the text turns upright on a tripod held sideways without the screen around
/// it following the motion updates.
private struct DimUpright: ViewModifier {
    let model: CameraModel

    func body(content: Content) -> some View {
        content.uprightRotation(model.motion.iconRotationDegrees)
    }
}

private struct DimLines: View {
    let title: String
    let time: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.45))
            if let time {
                Text(time)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            Text("Touch the screen to see the shot.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// When a dimmed shot ends, or when it began for one that runs until it is stopped.
private struct DimClock: Equatable {
    var end: Date?
    var start: Date

    init?(_ progress: StackProgress?, now: Date) {
        guard let progress, progress.elapsed.isFinite else { return nil }
        let elapsed = max(0, progress.elapsed)
        start = now.addingTimeInterval(-elapsed)
        // Counted the way the status under the picture counts: down to the end when the shot has one.
        if progress.framesPlanned > 0, let total = progress.estimatedTotal, total.isFinite {
            end = now.addingTimeInterval(max(0, total - elapsed))
        } else {
            end = nil
        }
    }

    /// Within a second of each other. Reports land at their own times, and a clock read a moment off isn't worth
    /// a redraw of the dark screen.
    static func isClose(_ a: DimClock?, _ b: DimClock?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard (a.end == nil) == (b.end == nil) else { return false }
        if let aEnd = a.end, let bEnd = b.end, abs(aEnd.timeIntervalSince(bEnd)) >= 1 { return false }
        return abs(a.start.timeIntervalSince(b.start)) < 1
    }
}

/// "0:42 left", or "1:05" counting up for a shot that runs until stopped, with the words VoiceOver says for it.
private struct DimTime {
    let shown: String
    let spoken: String

    init?(clock: DimClock?, now: Date) {
        guard let clock else { return nil }
        if let end = clock.end {
            let left = max(0, end.timeIntervalSince(now))
            shown = Formatting.clock(left) + " left"
            spoken = HoldMenuText.spokenTime(max(1, left.rounded(.up))) + " left."
        } else {
            let elapsed = max(0, now.timeIntervalSince(clock.start)).rounded(.down)
            shown = Formatting.clock(elapsed)
            spoken = HoldMenuText.spokenTime(max(1, elapsed)) + " so far."
        }
    }
}
