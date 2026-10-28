import SwiftUI

/// The shutter, drawn like the Camera app's: a white ring around a disc that morphs into the record and stop shapes.
/// A tap fires `action`. With `onHoldBegan` set, touching and holding opens the shutter until the finger lifts (bulb).
struct ShutterButton: View {
    enum Style: Equatable {
        case photo
        case video
        case recording
        case stacking(progress: Double)
        case night
        case long
        case countdown
        /// An intervalometer between shots, or a focus or white balance bracket: drawn like the countdown, and a
        /// press stops it.
        case sequence
    }

    var style: Style
    var isEnabled: Bool = true
    /// False while the camera would ignore a press, such as during a photo's exposure. A press then gets no scale,
    /// haptic or action, so the shutter is never felt to fire without firing. The look stays: that state is brief.
    var acceptsPress: Bool = true
    var action: () -> Void
    var onHoldBegan: (() -> Void)? = nil
    var onHoldEnded: (() -> Void)? = nil

    @GestureState private var isTouching = false
    /// The finger on the button, from touch down to lift.
    @State private var press: Press?

    private static let ringWidth: CGFloat = 4
    private static let ringGap: CGFloat = 3
    private static let discDiameter: CGFloat = Theme.shutterSize - 2 * (ringWidth + ringGap)
    /// Long enough that an ordinary tap never turns into a bulb exposure.
    private static let holdDelay: UInt64 = 350_000_000
    /// Sliding this far off the button cancels the tap, like UIButton.
    private static let touchSlop: CGFloat = 28
    /// The moon reads as yellow but stays visible on the white disc, which the accent yellow would not.
    private static let nightGlyph = Color(red: 0.74, green: 0.52, blue: 0.02)

    private enum Kind: Equatable {
        case photo, video, recording, stacking, night, long, countdown
    }

    private struct Press {
        var isInside = true
        var holdActive = false
        var holdTask: Task<Void, Never>?
        /// The hold-end handler from when the hold began, in case the parent drops it while the exposure runs.
        var holdEnded: (() -> Void)?
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(showsStopBackdrop ? 0.14 : 0))
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            ZStack {
                centerShape
                glyph
            }
            .scaleEffect(isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: isPressed)
            ring
        }
        .frame(width: Theme.shutterSize, height: Theme.shutterSize)
        .animation(Theme.spring, value: kind)
        .animation(Theme.spring, value: showsBulbGlyph)
        .opacity(isEnabled || press != nil ? 1 : 0.4)
        .animation(Theme.snappy, value: isEnabled)
        .contentShape(Circle())
        .gesture(pressGesture)
        // A press already under way keeps going, so a bulb exposure can always be released.
        .disabled(!isEnabled && press == nil)
        .onChange(of: isTouching) { _, touching in
            guard !touching else { return }
            // A press the system cancels never reaches onEnded; look again once this gesture update is over.
            Task { @MainActor in releaseCancelledPress() }
        }
        .onDisappear { releaseCancelledPress(force: true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(accessibilityProgress))
        .accessibilityHint(Text(showsBulbGlyph ? "Touch and hold to keep the shutter open until you let go." : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activateFromAccessibility() }
    }

    // MARK: - Appearance

    private var kind: Kind {
        switch style {
        case .photo: return .photo
        case .video: return .video
        case .recording: return .recording
        case .stacking: return .stacking
        case .night: return .night
        case .long: return .long
        case .countdown, .sequence: return .countdown
        }
    }

    private var progress: Double {
        guard case .stacking(let value) = style, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// While recording, stacking or counting down the button stops what is running instead of starting a shot.
    private var isStopStyle: Bool {
        kind == .recording || kind == .stacking || kind == .countdown
    }

    private var showsStopBackdrop: Bool {
        kind == .stacking || kind == .countdown
    }

    private var showsBulbGlyph: Bool {
        kind == .long && onHoldBegan != nil
    }

    private var isPressed: Bool {
        guard let press else { return false }
        return press.isInside || press.holdActive
    }

    /// One shape morphs between disc, record square and stop square, the way the Camera app's shutter does.
    private var centerShape: some View {
        let disc = Self.discDiameter
        let size: CGFloat
        let corner: CGFloat
        let color: Color
        switch kind {
        case .photo, .night, .long:
            (size, corner, color) = (disc, disc / 2, .white)
        case .video:
            (size, corner, color) = (disc - 4, (disc - 4) / 2, Theme.recording)
        case .recording:
            (size, corner, color) = (28, 7, Theme.recording)
        case .stacking, .countdown:
            (size, corner, color) = (26, 6, .white)
        }
        return RoundedRectangle(cornerRadius: corner, style: .circular)
            .fill(color)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var glyph: some View {
        if kind == .night {
            Image(systemName: "moon.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Self.nightGlyph)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        } else if showsBulbGlyph {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(kind == .stacking ? 0.28 : 1), lineWidth: Self.ringWidth)
            if kind == .stacking {
                if progress > 0 {
                    Circle()
                        .inset(by: Self.ringWidth / 2)
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                } else {
                    PendingArc(lineWidth: Self.ringWidth)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Touch handling

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, touching, _ in
                touching = true
            }
            .onChanged { value in
                pressChanged(value)
            }
            .onEnded { value in
                pressEnded(value)
            }
    }

    private static func isInside(_ location: CGPoint) -> Bool {
        CGRect(x: 0, y: 0, width: Theme.shutterSize, height: Theme.shutterSize)
            .insetBy(dx: -touchSlop, dy: -touchSlop)
            .contains(location)
    }

    private func pressChanged(_ value: DragGesture.Value) {
        guard var current = press else {
            guard isEnabled, acceptsPress else { return }
            var next = Press()
            if onHoldBegan != nil, !isStopStyle {
                next.holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.holdDelay)
                    guard !Task.isCancelled else { return }
                    holdTimerFired()
                }
            }
            press = next
            return
        }
        // Once the shutter is held open it stays open until the finger lifts, wherever it slides.
        guard !current.holdActive else { return }
        let inside = Self.isInside(value.location)
        guard inside != current.isInside else { return }
        current.isInside = inside
        if !inside {
            current.holdTask?.cancel()
            current.holdTask = nil
        }
        press = current
    }

    private func holdTimerFired() {
        guard var current = press, current.isInside, !current.holdActive, !isStopStyle, acceptsPress,
              let began = onHoldBegan else { return }
        current.holdActive = true
        current.holdTask = nil
        current.holdEnded = onHoldEnded
        press = current
        Haptics.shutter()
        began()
    }

    private func pressEnded(_ value: DragGesture.Value) {
        guard let current = press else { return }
        current.holdTask?.cancel()
        press = nil
        if current.holdActive {
            (onHoldEnded ?? current.holdEnded)?()
        } else if current.isInside, Self.isInside(value.location), isEnabled, acceptsPress {
            // Checked again at the lift: the camera may have started a shot from another button meanwhile.
            Haptics.shutter()
            action()
        }
    }

    /// Ends a press that never got its onEnded (system cancel, view removed). A running bulb exposure must always end.
    private func releaseCancelledPress(force: Bool = false) {
        guard let current = press, force || !isTouching else { return }
        current.holdTask?.cancel()
        press = nil
        if current.holdActive {
            (onHoldEnded ?? current.holdEnded)?()
        }
    }

    private func activateFromAccessibility() {
        guard isEnabled, acceptsPress else { return }
        Haptics.shutter()
        action()
    }

    // MARK: - Accessibility

    private var accessibilityTitle: String {
        if style == .sequence { return "Stop" }
        switch kind {
        case .photo: return "Take photo"
        case .video: return "Start recording"
        case .recording: return "Stop recording"
        case .stacking: return "Stop exposure"
        case .night: return "Take night photo"
        case .long: return "Take long exposure"
        case .countdown: return "Cancel timer"
        }
    }

    private var accessibilityProgress: String {
        guard kind == .stacking, progress > 0 else { return "" }
        return "\(Int((progress * 100).rounded())) percent"
    }
}

/// Bulb exposures have no known length, so the ring shows a slow sweep instead of progress. With Reduce Motion the arc
/// holds still at the top; the stop square already says the shutter is open.
private struct PendingArc: View {
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.2)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 270 : -90))
            .animation(spinning ? .linear(duration: 1.4).repeatForever(autoreverses: false) : nil, value: spinning)
            .onAppear { spinning = !reduceMotion }
            // A repeating animation keeps running after its value changes back, so a switch of the setting starts a
            // fresh arc, whose onAppear picks the new state.
            .id(reduceMotion)
    }
}
