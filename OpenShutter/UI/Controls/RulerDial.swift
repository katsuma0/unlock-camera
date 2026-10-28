import SwiftUI

/// Horizontal ruler dial like the Camera app's exposure and zoom dials.
///
/// One tick per value, the selection under the yellow center line. Scrubbing tracks the finger 1:1 and writes
/// `index` for every tick it crosses; a flick glides on from the release speed, slowing evenly, and stops exactly on
/// a tick. Each tick clicks, the ends click harder, and a tap on a tick selects it.
struct RulerDial: View {
    let values: [Double]
    @Binding var index: Int
    var majorTick: (Int) -> Bool = { _ in false }
    var label: (Int) -> String = { _ in "" }
    var spacing: CGFloat = 10
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// The finger while it is down.
    @State private var drag: DragState?
    /// A glide after release, or an animated jump to a new index.
    @State private var motion: DialMotion?
    /// The motion that finished last. The completion observer reads it once the motion is gone, so finishing doesn't
    /// change the observed value a second time in the same frame.
    @State private var settledMotionID: UUID?
    /// The tick this dial wrote last, so each tick crossed writes and clicks exactly once.
    @State private var trackedIndex = 0
    /// The last write, until the binding reports it back; that echo must not animate the dial a second time.
    @State private var echoIndex: Int?
    @State private var isEditing = false
    /// The end stop already clicked; pushing on into the rubber band stays quiet.
    @State private var endStopLatched = false
    @State private var width: CGFloat = 0
    @GestureState private var isTouching = false

    private static let height: CGFloat = 56
    private static let labelCenterY: CGFloat = 12
    private static let tickBottom: CGFloat = 44
    private static let majorTickHeight: CGFloat = 16
    private static let minorTickHeight: CGFloat = 9
    private static let labelFont = Font.system(size: 11, weight: .semibold).monospacedDigit()
    /// Natural frequency of the spring that snaps a slow release into its tick or bounces a throw off an end, rad/s.
    private static let releaseStiffness = 12.0
    /// Taps and outside changes start at rest, so they can afford a quicker spring.
    private static let jumpStiffness = 16.0
    /// How far the rubber band stretches past an end, in ticks.
    private static let rubberLimit = 3.0

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: motion == nil)) { timeline in
            let now = timeline.date
            let shown = displayedPosition(at: now)
            face(at: shown)
                .onChange(of: userDetent(of: shown)) { _, newValue in
                    // The completion handler for the same frame may already have ended the edit.
                    if let newValue, isEditing { commit(newValue) }
                }
                .onChange(of: drag != nil && isOverscrolled(shown)) { _, isOver in
                    if isOver { overscrollBegan() }
                }
                .onChange(of: finishedMotionID(at: now)) { _, finished in
                    if finished != nil, finished == motion?.id { finishMotion() }
                }
        }
        .overlay { indicator }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            width = newWidth
        }
        .gesture(scrub.exclusively(before: tapToSelect))
        .onChange(of: isTouching) { _, touching in
            guard !touching else { return }
            // A drag the system cancels never reaches onEnded; look again once this gesture update is over.
            Task { @MainActor in releaseCancelledDrag() }
        }
        .onChange(of: SyncKey(index: index, values: values)) { old, new in
            bindingChanged(from: old, to: new)
        }
        .onDisappear { stopAll() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dial"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAdjustableAction { direction in
            adjust(direction)
        }
    }

    // MARK: - Drawing

    private func face(at position: Double) -> some View {
        Canvas { context, size in
            drawTicks(in: &context, size: size, position: position)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var indicator: some View {
        Capsule()
            .fill(Theme.accent)
            .frame(width: 2, height: 26)
            .offset(y: 9)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func drawTicks(in context: inout GraphicsContext, size: CGSize, position: Double) {
        guard !values.isEmpty, position.isFinite else { return }
        let step = self.step
        let midX = Double(size.width) / 2
        // Only the ticks on screen are drawn, so long scales cost the same as short ones.
        let reach = midX / step + 1
        let first = max(0, Int((position - reach).rounded(.down)))
        let last = min(lastIndex, Int((position + reach).rounded(.up)))
        guard first <= last else { return }

        // Tick edges sit on device pixels so hairlines stay crisp instead of smearing across two pixels.
        let scale = displayScale.isFinite && displayScale >= 1 ? displayScale : 1
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minorWidth = max(snapped(1), 1 / scale)
        let majorWidth = max(snapped(1.5), 1 / scale)

        var minor = Path()
        var major = Path()
        var labelled: [Int] = []
        for i in first...last {
            let x = CGFloat(midX + (Double(i) - position) * step)
            if majorTick(i) {
                major.addRect(CGRect(x: snapped(x - majorWidth / 2), y: Self.tickBottom - Self.majorTickHeight, width: majorWidth, height: Self.majorTickHeight))
                labelled.append(i)
            } else {
                minor.addRect(CGRect(x: snapped(x - minorWidth / 2), y: Self.tickBottom - Self.minorTickHeight, width: minorWidth, height: Self.minorTickHeight))
            }
        }
        context.fill(minor, with: .color(Theme.primaryText.opacity(0.45)))
        context.fill(major, with: .color(Theme.primaryText.opacity(0.9)))
        drawLabels(labelled, in: &context, midX: midX, position: position)
    }

    private func drawLabels(_ indices: [Int], in context: inout GraphicsContext, midX: Double, position: Double) {
        let selected = detent(of: position)
        var items: [(index: Int, x: CGFloat, text: GraphicsContext.ResolvedText, width: CGFloat)] = []
        for i in indices {
            let string = label(i)
            guard !string.isEmpty else { continue }
            var text = context.resolve(Text(string).font(Self.labelFont))
            text.shading = .color(i == selected ? Theme.accent : Theme.primaryText.opacity(0.75))
            let width = text.measure(in: CGSize(width: 400, height: 40)).width
            items.append((i, CGFloat(midX + (Double(i) - position) * step), text, width))
        }
        guard !items.isEmpty else { return }

        // Labels wider than the gap between major ticks are thinned to every n-th major, counted from the first major
        // of the whole scale, so the pattern stays put while the dial moves instead of flickering.
        var period = 1
        var anchor = 0
        if items.count > 1 {
            var gap = Int.max
            for pair in zip(items, items.dropFirst()) {
                gap = min(gap, pair.1.index - pair.0.index)
            }
            gap = max(gap, 1)
            let needed = Double(items.map { $0.width }.max() ?? 0) + 4
            let pitch = Double(gap) * step
            if needed > pitch {
                period = gap * Int((needed / pitch).rounded(.up))
                anchor = (0...lastIndex).first(where: majorTick) ?? 0
            }
        }
        for item in items where period == 1 || ((item.index - anchor) % period + period) % period == 0 {
            context.draw(item.text, at: CGPoint(x: item.x, y: Self.labelCenterY), anchor: .center)
        }
    }

    // MARK: - Positions

    /// Points per tick. A zero, negative or absurd spacing would divide by zero or overflow the visible range.
    private var step: Double {
        guard spacing.isFinite else { return 10 }
        return Double(min(max(spacing, 2), 200))
    }

    private var lastIndex: Int { max(values.count - 1, 0) }

    private func clamped(_ i: Int) -> Int {
        min(max(i, 0), lastIndex)
    }

    /// The tick nearest to a fractional position.
    private func detent(of position: Double) -> Int {
        guard position.isFinite else { return clamped(index) }
        return Int(min(max(position, 0), Double(lastIndex)).rounded())
    }

    private func displayedPosition(at date: Date) -> Double {
        if let drag { return drag.position }
        if let motion { return motion.value(at: date) }
        return Double(clamped(index))
    }

    private func isOverscrolled(_ position: Double) -> Bool {
        position < -0.3 || position > Double(lastIndex) + 0.3
    }

    private func finishedMotionID(at date: Date) -> UUID? {
        guard let motion, motion.isFinished(at: date) else { return settledMotionID }
        return motion.id
    }

    private func rubberBanded(_ raw: Double) -> Double {
        guard raw.isFinite else { return Double(clamped(index)) }
        let upper = Double(lastIndex)
        if raw < 0 { return -Self.rubber(-raw) }
        if raw > upper { return upper + Self.rubber(raw - upper) }
        return raw
    }

    /// UIScrollView's rubber band: resistance grows with the stretch and it never passes the limit.
    private static func rubber(_ distance: Double) -> Double {
        rubberLimit * (1 - 1 / (distance * 0.55 / rubberLimit + 1))
    }

    // MARK: - Gestures

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($isTouching) { _, touching, _ in
                touching = true
            }
            .onChanged { value in
                dragChanged(value)
            }
            .onEnded { value in
                dragEnded(value)
            }
    }

    private var tapToSelect: some Gesture {
        SpatialTapGesture()
            .onEnded { event in
                tapped(at: event.location)
            }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard !values.isEmpty else { return }
        let translation = value.translation.width
        guard var state = drag else {
            // A finger landing on a gliding dial catches it where it is, like a scroll view. Measuring from the
            // first reported translation hides the few points the gesture needed to start.
            let start = displayedPosition(at: Date())
            motion = nil
            beginEditing(at: start)
            drag = DragState(startPosition: start, startTranslation: translation, lastTranslation: translation, position: start)
            return
        }
        state.lastTranslation = translation
        state.position = rubberBanded(state.startPosition - Double(translation - state.startTranslation) / step)
        drag = state
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard let state = drag else { return }
        drag = nil
        var velocity = -Double(value.velocity.width) / step
        if !velocity.isFinite { velocity = 0 }
        let target: Int
        let overscrolled = state.position < 0 || state.position > Double(lastIndex)
        if overscrolled {
            target = state.position < 0 ? 0 : lastIndex
            // Flinging further out of the rubber band only deepens the bounce a little.
            if (state.position < 0) == (velocity < 0) { velocity *= 0.3 }
        } else if reduceMotion {
            // Without the glide a thrown dial would jump to a value the user never saw go by.
            target = detent(of: state.position)
        } else {
            // Land on the tick nearest to where SwiftUI predicts the drag would have come to rest.
            let throwTicks = -Double(value.predictedEndTranslation.width - value.translation.width) / step
            target = detent(of: state.position + (throwTicks.isFinite ? throwTicks : 0))
        }
        settle(from: state.position, to: target, velocity: velocity, stiffness: Self.releaseStiffness, mayGlide: !overscrolled)
    }

    private func tapped(at location: CGPoint) {
        guard !values.isEmpty, width > 0, drag == nil else { return }
        let current = displayedPosition(at: Date())
        let offset = Double(location.x - width / 2) / step
        guard offset.isFinite else { return }
        let target = detent(of: current + offset)
        if motion?.userDriven == true {
            // The tap replaces the glide; the glide's own edit ends where it got to.
            endEditing()
        }
        if target != clamped(index) {
            trackedIndex = clamped(index)
            onEditingChanged(true)
            commit(target)
            onEditingChanged(false)
        }
        // Animate from wherever the ticks are now, which mid-glide is between two ticks.
        if reduceMotion || abs(current - Double(target)) < 0.001 {
            motion = nil
        } else {
            motion = DialMotion(from: current, target: target, initialVelocity: 0,
                                curve: .spring(stiffness: Self.jumpStiffness), userDriven: false)
        }
    }

    /// A drag the system cancelled (no onEnded) still has to land on a tick and end the edit.
    private func releaseCancelledDrag() {
        guard !isTouching, let state = drag else { return }
        drag = nil
        settle(from: state.position, to: detent(of: state.position), velocity: 0, stiffness: Self.jumpStiffness, mayGlide: false)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard !values.isEmpty else { return }
        let current = clamped(index)
        let next: Int
        switch direction {
        case .increment: next = clamped(current + 1)
        case .decrement: next = clamped(current - 1)
        @unknown default: return
        }
        guard next != current else { return }
        onEditingChanged(true)
        index = next
        onEditingChanged(false)
    }

    private var accessibilityValue: String {
        guard !values.isEmpty else { return "" }
        let i = clamped(index)
        let text = label(i)
        return text.isEmpty ? values[i].formatted() : text
    }

    // MARK: - Editing

    private func beginEditing(at position: Double) {
        trackedIndex = detent(of: position)
        endStopLatched = false
        guard !isEditing else { return }
        isEditing = true
        Haptics.prepare()
        onEditingChanged(true)
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        onEditingChanged(false)
    }

    /// Writes a tick the user reached and clicks for it; the first and last ticks give the end-stop click.
    private func commit(_ newIndex: Int) {
        guard newIndex != trackedIndex else { return }
        trackedIndex = newIndex
        index = newIndex
        // A binding that refused the value never reports it back. A leftover echo would make the dial ignore that
        // value the next time it arrives from outside.
        echoIndex = clamped(index) == newIndex ? newIndex : nil
        if lastIndex > 0, newIndex == 0 || newIndex == lastIndex {
            Haptics.stop()
            endStopLatched = true
        } else {
            Haptics.tick()
            endStopLatched = false
        }
    }

    /// The tick under the line while the user moves the dial, nil otherwise. Outside changes and their animations
    /// move the ticks too, but only the user's own movement writes back, and observing nil for the rest keeps an
    /// outside change from reporting twice in one frame.
    private func userDetent(of position: Double) -> Int? {
        guard isEditing, drag != nil || motion?.userDriven == true else { return nil }
        return detent(of: position)
    }

    private func overscrollBegan() {
        guard drag != nil, !endStopLatched else { return }
        endStopLatched = true
        Haptics.stop()
    }

    private func settle(from position: Double, to target: Int, velocity: Double, stiffness: Double, mayGlide: Bool) {
        guard !reduceMotion else {
            motion = nil
            commit(target)
            endEditing()
            return
        }
        let glide = mayGlide ? DialMotion.glide(from: position, to: target, velocity: velocity, springStiffness: stiffness) : nil
        motion = glide ?? DialMotion(from: position, target: target, initialVelocity: velocity,
                                     curve: .spring(stiffness: stiffness), userDriven: true)
    }

    private func finishMotion() {
        guard let finished = motion else { return }
        settledMotionID = finished.id
        motion = nil
        if finished.userDriven {
            commit(finished.target)
            endEditing()
        }
        // The binding may clamp or refuse a value; glide on to whatever it reports.
        let settled = clamped(index)
        if settled != finished.target, !values.isEmpty, !reduceMotion {
            motion = DialMotion(from: Double(finished.target), target: settled, initialVelocity: 0,
                                curve: .spring(stiffness: Self.jumpStiffness), userDriven: false)
        }
    }

    private func bindingChanged(from old: SyncKey, to new: SyncKey) {
        let echo = echoIndex
        echoIndex = nil
        if old.values != new.values {
            scaleChanged()
            return
        }
        // The dial's own writes come back through here, the last one sometimes just after editing ended; the dial
        // already shows them.
        guard !isEditing, old.index != new.index, new.index != echo, !values.isEmpty else { return }
        let target = clamped(new.index)
        if let running = motion, running.target == target { return }
        guard !reduceMotion else {
            motion = nil
            return
        }
        let now = Date()
        let from = motion?.value(at: now) ?? Double(clamped(old.index))
        let velocity = motion?.velocity(at: now) ?? 0
        motion = DialMotion(from: from, target: target, initialVelocity: velocity,
                            curve: .spring(stiffness: Self.jumpStiffness), userDriven: false)
    }

    /// Another control or another lens: jump, since gliding across values from a different scale means nothing.
    private func scaleChanged() {
        if let running = motion {
            motion = nil
            if running.userDriven { endEditing() }
        }
        trackedIndex = clamped(index)
        guard var state = drag else { return }
        let resting = Double(clamped(index))
        state.startPosition = resting
        state.startTranslation = state.lastTranslation
        state.position = resting
        drag = state
    }

    /// The dial is going away: keep the last tick it wrote rather than jumping to a glide target nobody saw land.
    private func stopAll() {
        drag = nil
        motion = nil
        endEditing()
    }
}

private struct DragState {
    var startPosition: Double
    var startTranslation: CGFloat
    var lastTranslation: CGFloat
    var position: Double
}

private struct SyncKey: Equatable {
    var index: Int
    var values: [Double]
}

/// The dial moving to a tick on its own, in tick units. Both curves start at the given velocity, so a flick carries on
/// at the speed the finger left it.
private struct DialMotion: Equatable {
    enum Curve: Equatable {
        /// Critically damped, natural frequency in rad/s. Lands without overshoot unless the start velocity carries it
        /// past the tick, which only happens when a throw is cut short at an end of the scale (the bounce).
        case spring(stiffness: Double)
        /// Slows evenly from the start velocity to rest exactly on the tick at `duration`, like friction on a real dial.
        case glide(duration: TimeInterval)
    }

    let id = UUID()
    let start = Date()
    let from: Double
    let target: Int
    /// Ticks per second at the start.
    let initialVelocity: Double
    let curve: Curve
    /// A release or tap the user made, as opposed to following an outside change of `index`.
    let userDriven: Bool

    /// A cap so a frame-rate hiccup can never leave the dial animating.
    private static let maxDuration: TimeInterval = 2.5
    /// A glide slower than this crawls into its tick; the spring snaps it in sooner.
    private static let longestGlide: TimeInterval = 1.2

    /// A throw released toward a tick at least one tick away, or nil when the spring suits better. A spring pulling
    /// toward a tick that far would first speed the dial up past the finger's speed, a visible lurch; the glide never
    /// goes faster than the release.
    static func glide(from position: Double, to target: Int, velocity: Double, springStiffness: Double) -> DialMotion? {
        let distance = Double(target) - position
        guard velocity.isFinite, distance.isFinite, distance * velocity > 0, abs(distance) >= 1 else { return nil }
        let duration = 2 * distance / velocity
        // Under 4 / stiffness the spring lands without speeding up, and it bounces off an end, which a glide can't.
        guard duration > 4 / max(springStiffness, 1), duration <= longestGlide else { return nil }
        return DialMotion(from: position, target: target, initialVelocity: velocity, curve: .glide(duration: duration), userDriven: true)
    }

    func value(at date: Date) -> Double {
        let t = elapsed(at: date)
        switch curve {
        case .spring(let stiffness):
            let x0 = from - Double(target)
            return Double(target) + (x0 + (initialVelocity + stiffness * x0) * t) * exp(-stiffness * t)
        case .glide(let duration):
            guard duration > 0, t < duration else { return Double(target) }
            let progress = t / duration
            return from + (Double(target) - from) * progress * (2 - progress)
        }
    }

    func velocity(at date: Date) -> Double {
        let t = elapsed(at: date)
        switch curve {
        case .spring(let stiffness):
            let x0 = from - Double(target)
            return (initialVelocity - stiffness * (initialVelocity + stiffness * x0) * t) * exp(-stiffness * t)
        case .glide(let duration):
            guard duration > 0, t < duration else { return 0 }
            return 2 * (Double(target) - from) / duration * (1 - t / duration)
        }
    }

    func isFinished(at date: Date) -> Bool {
        let t = elapsed(at: date)
        if t >= Self.maxDuration { return true }
        switch curve {
        case .spring:
            return abs(value(at: date) - Double(target)) < 0.004 && abs(velocity(at: date)) < 0.05
        case .glide(let duration):
            return t >= duration
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(start))
    }
}

/// Title and value above a dial, with an AUTO button on the left when `onAuto` is set.
struct DialValueHeader: View {
    let title: String
    let value: String
    var isAuto: Bool = false
    var onAuto: (() -> Void)? = nil

    /// Both sides get the same width so the value stays centered over the dial's yellow line.
    private static let sideWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            autoButton
                .frame(width: Self.sideWidth, alignment: .leading)
            Spacer(minLength: 4)
            readout
            Spacer(minLength: 4)
            Color.clear
                .frame(width: Self.sideWidth, height: 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .animation(Theme.snappy, value: isAuto)
    }

    private var readout: some View {
        VStack(spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 5) {
                // Not animated per value: a scrub or a live auto reading changes it many times a second, and the digits
                // would never stop rolling long enough to read. Switching to or from auto still rolls them.
                Text(value)
                    .font(Theme.bigValueFont)
                    .foregroundStyle(isAuto ? Theme.primaryText : Theme.accent)
                    .contentTransition(.numericText())
                if isAuto {
                    Text("A")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Theme.primaryText.opacity(0.85)))
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isAuto ? "\(value), auto" : value))
    }

    @ViewBuilder
    private var autoButton: some View {
        if let onAuto {
            Button(action: onAuto) {
                Text("AUTO")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(isAuto ? Color.black : Theme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(isAuto ? Theme.accent : Color.white.opacity(0.16)))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Auto"))
            .accessibilityValue(Text(isAuto ? "On" : "Off"))
            .accessibilityHint(Text(isAuto ? "" : "Returns \(title.lowercased()) to automatic."))
        }
    }
}
