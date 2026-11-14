import SwiftUI
import CameraCore

/// Grid, level, focus reticle and warning badges over the picture, above the bands. Laid out in the viewfinder's
/// screen space; the camera screen hands in where the frame, the picture and the open part of the frame are.
struct ViewfinderOverlays: View {
    let model: CameraModel
    let geometry: ViewfinderGeometry
    /// How far the corner badges move down to clear the steady status at the top of the frame.
    let topShift: CGFloat

    /// A zoom, lens or picture change since the last focus tap moved the picture under the focus point.
    @State private var focusPointIsStale = false
    /// The focus point the flags around it describe. A model.focusPoint that differs is a tap this view hasn't
    /// caught up with yet (change handlers run after the frame that shows it), so that frame reads the model alone.
    @State private var trackedFocusPoint: CGPoint?
    /// The long press that placed the tracked point also locked the focus, the exposure or both, so the square
    /// carries the lock.
    @State private var lockIsAtFocusPoint = false

    var body: some View {
        let frame = geometry.frame
        let square = focusSquare
        ZStack(alignment: .topLeading) {
            GridLines(style: model.settings.display.grid, rect: frame)
                .animation(Theme.spring, value: frame)
            LevelIndicator(model: model, center: CGPoint(x: frame.midX, y: frame.midY))
            FocusReticleLayer(model: model, size: geometry.screen.size, origin: geometry.picture.origin,
                              bounds: geometry.visibleFrame, square: square)
            StatusBadges(model: model, rect: geometry.open, topShift: topShift,
                         reticleShowsLock: square?.isLocked == true)
        }
        .frame(width: geometry.screen.width, height: geometry.screen.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: model.focusPoint, initial: true) { _, point in
            trackedFocusPoint = point
            if focusPointIsStale { focusPointIsStale = false }
            let locked = point != nil && isLocked
            if lockIsAtFocusPoint != locked { lockIsAtFocusPoint = locked }
        }
        // The model keeps the point of a released lock. Locking again later (the AE-L chip) isn't tied to that old
        // square: it shows as the corner badge and must not bring the square back.
        .onChange(of: isLocked) { _, locked in
            if !locked && lockIsAtFocusPoint { lockIsAtFocusPoint = false }
        }
        // The square marks a spot in the picture; zooming or switching lens moves the picture under it.
        .onChange(of: model.settings.zoom) {
            if !focusPointIsStale { focusPointIsStale = true }
        }
        .onChange(of: model.activePresetID) {
            if !focusPointIsStale { focusPointIsStale = true }
        }
        // So does a new picture rect (another aspect ratio, VIDEO): the same point lands somewhere else now.
        .onChange(of: geometry.picture) {
            if !focusPointIsStale { focusPointIsStale = true }
        }
    }

    /// Either half of a lock keeps the square: a long press in a scene that fixes the ISO holds the focus alone,
    /// and the shots after it are taken at that distance.
    private var isLocked: Bool {
        model.aeLocked || model.focusLocked
    }

    /// The focus square to draw, or nil. Its point is in the preview layer's coordinates.
    private var focusSquare: FocusSquare? {
        guard let point = model.focusPoint else { return nil }
        // A tap clears the lock and a long press sets it, so a new point that arrives locked is a long press.
        guard point == trackedFocusPoint else { return FocusSquare(point: point, isLocked: isLocked) }
        guard !focusPointIsStale else { return nil }
        return FocusSquare(point: point, isLocked: isLocked && lockIsAtFocusPoint)
    }
}

private typealias AnimatableRect = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>

private extension CGRect {
    var animatableRect: AnimatableRect {
        AnimatablePair(AnimatablePair(origin.x, origin.y), AnimatablePair(size.width, size.height))
    }

    init(_ value: AnimatableRect) {
        self.init(x: value.first.first, y: value.first.second, width: value.second.first, height: value.second.second)
    }
}

/// Quarter turns as the rotation that keeps content upright for the user, matching MotionState.
private enum Upright {
    static func degrees(_ quarterTurns: Int) -> Double {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return 90
        case 2: return 180
        case 3: return -90
        default: return 0
        }
    }

    /// A screen vector for a vector given in the user's frame.
    static func screenVector(_ vector: CGPoint, quarterTurns: Int) -> CGPoint {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGPoint(x: -vector.y, y: vector.x)
        case 2: return CGPoint(x: -vector.x, y: -vector.y)
        case 3: return CGPoint(x: vector.y, y: -vector.x)
        default: return vector
        }
    }
}

// MARK: - Grid

/// Hairline composition guides inside the photo frame. Animatable so the lines glide with the bands when the
/// aspect ratio changes.
private struct GridLines: View, Animatable {
    let style: GridStyle
    var rect: CGRect
    @Environment(\.displayScale) private var displayScale

    var animatableData: AnimatableRect {
        get { rect.animatableRect }
        set { rect = CGRect(newValue) }
    }

    var body: some View {
        let path = Self.path(for: style, in: rect)
        let hairline = 1 / max(displayScale, 1)
        Canvas { context, _ in
            guard !path.isEmpty else { return }
            // A faint shadow keeps white hairlines visible against a bright sky.
            context.addFilter(.shadow(color: .black.opacity(0.35), radius: 0.8))
            context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: hairline)
        }
        .accessibilityHidden(true)
    }

    private static func path(for style: GridStyle, in r: CGRect) -> Path {
        var path = Path()
        guard r.width > 2, r.height > 2, r.width.isFinite, r.height.isFinite else { return path }
        func vertical(_ x: CGFloat) {
            path.move(to: CGPoint(x: x, y: r.minY))
            path.addLine(to: CGPoint(x: x, y: r.maxY))
        }
        func horizontal(_ y: CGFloat) {
            path.move(to: CGPoint(x: r.minX, y: y))
            path.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        switch style {
        case .off:
            break
        case .thirds:
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                vertical(r.minX + r.width * fraction)
                horizontal(r.minY + r.height * fraction)
            }
        case .goldenRatio:
            // Phi grid: lines at 1/phi^2 and 1/phi of each side.
            let major = 2 / (1 + 5.0.squareRoot())
            for fraction in [1 - major, major] {
                vertical(r.minX + r.width * fraction)
                horizontal(r.minY + r.height * fraction)
            }
        case .square:
            // Square cells, four across the short side, centred so both halves of the frame match.
            let cell = min(r.width, r.height) / 4
            var step: CGFloat = 0
            while step * cell < r.width / 2 - 0.5 {
                vertical(r.midX + step * cell)
                if step > 0 { vertical(r.midX - step * cell) }
                step += 1
            }
            step = 0
            while step * cell < r.height / 2 - 0.5 {
                horizontal(r.midY + step * cell)
                if step > 0 { horizontal(r.midY - step * cell) }
                step += 1
            }
        case .crosshair:
            let arm = max(8, min(r.width, r.height) * 0.05)
            let gap: CGFloat = 3
            path.move(to: CGPoint(x: r.midX - arm, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX - gap, y: r.midY))
            path.move(to: CGPoint(x: r.midX + gap, y: r.midY))
            path.addLine(to: CGPoint(x: r.midX + arm, y: r.midY))
            path.move(to: CGPoint(x: r.midX, y: r.midY - arm))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY - gap))
            path.move(to: CGPoint(x: r.midX, y: r.midY + gap))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY + arm))
        case .diagonals:
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.move(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        return path
    }
}

// MARK: - Level

/// The Camera app's level: two fixed wings and a middle line that follows the horizon, merging into one
/// yellow line when the phone is level.
private struct LevelIndicator: View {
    let model: CameraModel
    let center: CGPoint

    @State private var hapticArmed = true

    var body: some View {
        let isEnabled = model.settings.display.showLevel
        // A level that is turned off doesn't read the attitude at all, so its many small updates skip this view.
        let motion = isEnabled ? model.motion : MotionState()
        // Pointing at the floor or the sky there is no horizon to show.
        let isVisible = isEnabled && abs(motion.pitch) <= 70
        // A line looks the same turned half way round, so landscape left and right share one base angle. The
        // deviation is measured from the nearest quarter turn of the roll, so the base angle must come from the
        // roll too: the icons' quarter turn is held a little past the diagonal.
        let sideways = LevelMath.quarterTurns(motion.roll) % 2 != 0
        LevelGraphic(deviation: motion.levelDeviation, isLevel: motion.isLevel)
            .rotationEffect(.degrees(sideways ? 90 : 0))
            .animation(Theme.spring, value: sideways)
            .position(center)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isVisible)
            .accessibilityHidden(true)
            .onChange(of: motion) { _, new in
                // Attitude updates arrive up to 30 times a second; the flag is written only when it flips.
                if new.isLevel {
                    if hapticArmed {
                        if isVisible { Haptics.tick() }
                        hapticArmed = false
                    }
                } else if abs(new.levelDeviation) > 3 && !hapticArmed {
                    // Re-arms only after a clear tilt, so hovering at the edge of level doesn't buzz.
                    hapticArmed = true
                }
            }
    }
}

private struct LevelGraphic: View {
    let deviation: Double
    let isLevel: Bool

    private static let wing: CGFloat = 26
    private static let middle: CGFloat = 72

    var body: some View {
        let color = isLevel ? Theme.accent : Color.white
        let gap: CGFloat = isLevel ? 0 : 8
        let thickness: CGFloat = isLevel ? 2 : 1.5
        let tilt = isLevel || !deviation.isFinite ? 0 : min(max(deviation, -45), 45)
        let wingOffset = Self.middle / 2 + gap + Self.wing / 2
        ZStack {
            Capsule()
                .fill(color)
                .frame(width: Self.wing, height: thickness)
                .offset(x: -wingOffset)
            Capsule()
                .fill(color)
                .frame(width: Self.wing, height: thickness)
                .offset(x: wingOffset)
            Capsule()
                .fill(color)
                .frame(width: Self.middle, height: thickness)
                .rotationEffect(.degrees(tilt))
        }
        .frame(width: Self.middle + 2 * (Self.wing + 8), height: Self.middle)
        .shadow(color: .black.opacity(0.35), radius: 1)
        .animation(Theme.snappy, value: isLevel)
    }
}

// MARK: - Focus reticle

/// Where the focus square sits and whether it carries the long press's lock.
private struct FocusSquare: Equatable {
    var point: CGPoint
    var isLocked: Bool
}

/// Names a lock by what it holds, in the words of the model's lock toasts: the advanced interface the way cameras
/// do, the simple one in plain words. A long press holds the focus and the exposure, or only the one of them still
/// left to the camera; the AE-L chip holds the exposure alone.
private struct LockWording {
    let focus: Bool
    let exposure: Bool
    let advanced: Bool

    var badgeLabel: String {
        if advanced {
            return focus && exposure ? "AE/AF LOCK" : (exposure ? "AE LOCK" : "AF LOCK")
        }
        return focus && exposure ? "Focus and brightness locked" : (exposure ? "Brightness locked" : "Focus locked")
    }

    /// One short word on the square for a full lock in the simple interface: the square and the sun beside it
    /// show what is held, and a longer label would run off the picture next to its edges. A lock of only one of
    /// them names it, because the square and the sun would claim both.
    var squareLabel: String {
        !advanced && focus && exposure ? "Locked" : badgeLabel
    }

    var spokenLabel: String {
        guard advanced else { return badgeLabel }
        return focus && exposure ? "Exposure and focus locked" : (exposure ? "Exposure locked" : "Focus locked")
    }
}

private struct FocusReticleLayer: View {
    let model: CameraModel
    let size: CGSize
    /// The preview layer's origin on screen: the model keeps the point in the layer's own coordinates.
    let origin: CGPoint
    /// The part of the frame that shows, which the lock label stays inside.
    let bounds: CGRect
    let square: FocusSquare?

    var body: some View {
        ZStack {
            if let square {
                // Read only while a square is up, so the attitude's frequent updates cost nothing the rest of the time.
                let turns = model.motion.quarterTurns
                let point = CGPoint(x: square.point.x + origin.x, y: square.point.y + origin.y)
                FocusReticle(
                    isLocked: square.isLocked,
                    lock: LockWording(focus: model.focusLocked, exposure: model.aeLocked, advanced: model.isAdvanced),
                    bias: Self.bias(model),
                    quarterTurns: turns,
                    labelBelow: labelBelow(point, turns: turns)
                )
                .position(point)
                // Every tap gets a new square, which replays the arrival and restarts the fade in the very frame
                // the point moves, instead of dragging the old square across first.
                .id(square.point)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.25), value: square == nil)
    }

    /// Night mode keeps its own compensation; every other mode uses the manual one.
    private static func bias(_ model: CameraModel) -> Double {
        model.settings.mode == .night ? model.settings.night.biasEV : model.settings.manual.bias
    }

    /// The lock label goes above the square in the user's frame, or below it near the edge of what shows.
    private func labelBelow(_ point: CGPoint, turns: Int) -> Bool {
        let offset = Upright.screenVector(CGPoint(x: 0, y: -(FocusReticle.side / 2 + 26)), quarterTurns: turns)
        let label = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        let margin: CGFloat = 8
        return label.x < bounds.minX + margin || label.x > bounds.maxX - margin
            || label.y < bounds.minY + margin || label.y > bounds.maxY - margin
    }
}

private struct FocusReticle: View {
    let isLocked: Bool
    /// The label says what is held, so a hold of the focus alone doesn't read as one of the brightness too.
    let lock: LockWording
    /// Exposure compensation. The square stays bright while it changes, as the Camera app's does while its sun
    /// is dragged; CameraPreviewView keeps the sun up by the same rule.
    let bias: Double
    let quarterTurns: Int
    let labelBelow: Bool

    /// The exposure slider in CameraPreviewView sits beside a square of this size.
    static let side: CGFloat = 72

    @State private var settled = false
    @State private var faded = false

    var body: some View {
        ZStack {
            ReticleShape()
                .stroke(Theme.accent, lineWidth: 1.25)
                .frame(width: Self.side, height: Self.side)
                .scaleEffect(settled ? 1 : 1.3)
                // A held lock stays on screen, dimmed; a plain tap fades out like the Camera app's square.
                .opacity(faded ? (isLocked ? 0.6 : 0) : 1)
                .accessibilityHidden(true)
            if isLocked {
                Text(lock.squareLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .fixedSize()
                    .offset(y: (labelBelow ? 1 : -1) * (Self.side / 2 + 16))
                    .transition(.opacity)
                    // The corner lock badge steps aside while this label shows, so VoiceOver needs this one.
                    .accessibilityLabel(lock.spokenLabel)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 1)
        .uprightRotation(Upright.degrees(quarterTurns))
        .animation(Theme.snappy, value: isLocked)
        .task {
            withAnimation(Theme.spring) {
                settled = true
            }
        }
        .task(id: bias) {
            // A plain tap's square that has faded stays gone; a held lock's dimmed square lights up again.
            guard !faded || isLocked else { return }
            if faded {
                withAnimation(.easeOut(duration: 0.15)) {
                    faded = false
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                faded = true
            }
        }
    }
}

/// A square with short ticks pointing in from the middle of each side, like the Camera app's.
private struct ReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let tick = min(rect.width, rect.height) * 0.08
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + tick))
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - tick))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + tick, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - tick, y: rect.midY))
        return path
    }
}

// MARK: - Badges

/// Status badges in the top right corner of the open part of the frame. Each one turns upright with the phone where
/// it stands, like the other chips, so nothing moves into the histogram's corner or under the controls.
private struct StatusBadges: View {
    let model: CameraModel
    /// The open part of the frame, between the top bar and the controls.
    let rect: CGRect
    /// The steady status sits at the top of the frame; the column starts under it while it shows.
    let topShift: CGFloat
    /// The focus square is on screen with its own lock label.
    let reticleShowsLock: Bool

    var body: some View {
        let advanced = model.isAdvanced
        // How a long shutter is built is the advanced interface's business. In the simple one LONG would wear this
        // badge nearly all the time, for a word it never explains.
        let stacked = advanced && model.shutterIsStacked
        let lock = LockWording(focus: model.focusLocked, exposure: model.aeLocked, advanced: advanced)
        // Stands in for the square's label when the square is gone: a zoom moved the picture under it, or the AE-L
        // chip locked without one.
        let showsLock = (lock.focus || lock.exposure) && !reticleShowsLock
        let turns = model.motion.quarterTurns
        VStack(alignment: .trailing, spacing: 0) {
            if stacked {
                StatusBadge(symbol: "square.stack.3d.up.fill", text: "STACKED", tint: Theme.accent, quarterTurns: turns)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            if showsLock {
                StatusBadge(symbol: "lock.fill", text: lock.badgeLabel, tint: Theme.accent, quarterTurns: turns)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            ClippingBadge(model: model, quarterTurns: turns)
            SensorBadges(model: model, quarterTurns: turns)
        }
        .padding(.top, 10 + topShift)
        .padding(.trailing, 10)
        .frame(width: max(rect.width, 0), height: max(rect.height, 0), alignment: .topTrailing)
        .position(x: rect.midX, y: rect.midY)
        .animation(Theme.snappy, value: stacked)
        .animation(Theme.snappy, value: showsLock)
        .animation(Theme.spring, value: topShift)
        // The Camera Control overlay takes over the screen; the badges step aside while it shows.
        .opacity(model.controlsFullscreen ? 0 : 1)
        .animation(Theme.snappy, value: model.controlsFullscreen)
    }
}

/// Reports its child's size with width and height swapped while the child is turned sideways, so a rotated
/// badge takes exactly the room it covers and the column below it stays tidy.
private struct SidewaysFrame: Layout {
    var sideways: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.unspecified)
        return sideways ? CGSize(width: size.height, height: size.width) : size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.unspecified)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
    }
}

private struct StatusBadge: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.primaryText
    let quarterTurns: Int

    var body: some View {
        let sideways = quarterTurns % 2 != 0
        SidewaysFrame(sideways: sideways) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(text)
                    .foregroundStyle(Theme.primaryText)
            }
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .cameraGlass(in: Capsule())
            .uprightRotation(Upright.degrees(quarterTurns))
        }
        .animation(Theme.spring, value: sideways)
        .accessibilityElement(children: .combine)
    }
}

/// Only this view reads the analysis, so the twelve updates a second stay inside it.
private struct ClippingBadge: View {
    let model: CameraModel
    let quarterTurns: Int
    @State private var isShown = false

    var body: some View {
        let clipping = analysisIsRunning && model.showsClippingWarning
        // The hold below is for clipping that comes and goes. A warning that is switched off goes at once, which
        // is also what leaving the advanced interface does to it.
        let isOn = model.settings.display.clippingWarnings
        ZStack(alignment: .topTrailing) {
            // Keeps the view alive while the badge is hidden, so the task below keeps watching.
            Color.clear.frame(width: 0, height: 0)
            if isShown && isOn {
                StatusBadge(symbol: "exclamationmark.triangle.fill", text: "CLIPPING", tint: Theme.accent,
                            quarterTurns: quarterTurns)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .task(id: clipping) {
            if clipping {
                withAnimation(Theme.snappy) { isShown = true }
                return
            }
            // Clipping hovers around the threshold from frame to frame; holding the badge stops it flickering.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.snappy) { isShown = false }
        }
    }

    /// The analyzer stops sending frames once every analysis is off, and the last frame's statistics would
    /// keep the badge up forever; this mirrors the options the model hands the backend.
    private var analysisIsRunning: Bool {
        guard model.sessionState == .running else { return false }
        let display = model.settings.display
        // Focus as the camera runs it, like the model's options: a scene that holds the lens at infinity counts
        // as manual focus.
        let manualFocus = model.effectiveFocus.lensPosition != nil || model.activeDial == .focus
        let peaking = display.peaking == .always || (display.peaking == .manualFocus && manualFocus)
        return display.histogram != .off || display.zebras || display.falseColor || peaking || display.clippingWarnings
    }
}

/// Lens smudge and thermal state, the two hints that come from the 10 Hz readings.
private struct SensorBadges: View {
    let model: CameraModel
    let quarterTurns: Int

    var body: some View {
        let readings = model.readings
        VStack(alignment: .trailing, spacing: 0) {
            if readings.lensSmudged {
                StatusBadge(symbol: "drop.fill", text: "Clean the lens", quarterTurns: quarterTurns)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            if readings.pressure >= .serious {
                StatusBadge(
                    symbol: readings.pressure == .serious ? "thermometer.medium" : "thermometer.high",
                    text: Self.thermalText(readings.pressure),
                    tint: readings.pressure == .serious ? Theme.accent : Theme.recording,
                    quarterTurns: quarterTurns
                )
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(Theme.snappy, value: readings.lensSmudged)
        .animation(Theme.snappy, value: readings.pressure)
    }

    private static func thermalText(_ level: PressureLevel) -> String {
        switch level {
        case .nominal, .fair, .serious: return "Phone is warm"
        case .critical: return "Phone is hot"
        case .shutdown: return "Too hot, camera paused"
        }
    }
}
