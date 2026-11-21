import SwiftUI
import CameraCore

/// Grid, level, focus reticle and warning badges over the picture, above the bands. Laid out in the viewfinder's
/// screen space; the camera screen hands in where the frame, the picture and the open part of the frame are.
struct ViewfinderOverlays: View {
    let model: CameraModel
    let geometry: ViewfinderGeometry
    /// The exposure sun's drag and the zoom wheel, which the level steps aside for.
    let interaction: ViewfinderInteraction
    let wheel: ZoomWheelModel
    /// The steady status and the histogram the corner badges move under, and where the badges report their height
    /// for the toasts that go under them.
    let furniture: TopFurniture

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
        // The focus magnifier shows the middle of the frame up close, where thirds drawn over the whole frame would
        // mark the wrong places.
        let grid = model.isMagnified ? GridStyle.off : model.settings.display.grid
        ZStack(alignment: .topLeading) {
            // Each layer leaves its touches to the picture, so taps still focus through the grid, the level and the
            // focus square. The badges do the same, except STACKED, which explains itself when tapped.
            GridLines(style: grid, rect: frame)
                .frameMotion(value: frame)
                .allowsHitTesting(false)
            LevelIndicator(model: model, interaction: interaction, wheel: wheel,
                           center: CGPoint(x: frame.midX, y: frame.midY), open: geometry.open)
                .allowsHitTesting(false)
            // The lock label keeps to the open part of the frame, so it never goes under the controls or the top bar.
            FocusReticleLayer(model: model, size: geometry.screen.size, origin: geometry.picture.origin,
                              bounds: geometry.open, square: square)
                .allowsHitTesting(false)
            StatusBadges(model: model, rect: geometry.open, furniture: furniture, square: square,
                         squareOrigin: geometry.picture.origin)
        }
        .frame(width: geometry.screen.width, height: geometry.screen.height, alignment: .topLeading)
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
        // And the focus magnifier, a zoom on the middle of the frame: the square doesn't come back after it.
        .onChange(of: model.isMagnified) {
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
        // The magnified picture is the middle of the frame, so a square at the point would mark the wrong spot.
        guard let point = model.focusPoint, !model.isMagnified else { return nil }
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
/// yellow line when the phone is level. It sits in the middle of the frame, which an open dial, the quick settings
/// and a running shot reach on most phones, so it steps aside while they are up (stepsAside). Where the controls
/// come close under the middle, it rises just far enough to keep clear of them.
private struct LevelIndicator: View {
    let model: CameraModel
    /// The exposure sun: with no focus square up, a drag puts it on the level's right wing.
    let interaction: ViewfinderInteraction
    /// The zoom wheel a hold on a lens button opens.
    let wheel: ZoomWheelModel
    let center: CGPoint
    /// The part of the frame the top bar and the controls leave open.
    let open: CGRect

    @State private var hapticArmed = true

    var body: some View {
        let isEnabled = model.settings.display.showLevel
        // A level that is turned off doesn't read the attitude at all, so its many small updates skip this view.
        // One that steps aside still reads it, so it comes back at the phone's angle instead of turning into it, and
        // its tick is armed by what the phone did meanwhile.
        let motion = isEnabled ? model.motion : MotionState()
        // Pointing at the floor or the sky there is no horizon to show. During a stack the drift crosses take the
        // frame's middle, and a level line through them would hide the very cross the status asks to line up.
        let isVisible = isEnabled && abs(motion.pitch) <= 70 && !model.drift.isTracking
            && !Self.stepsAside(model, interaction: interaction, wheel: wheel)
        // A line looks the same turned half way round, so landscape left and right share one base angle. The
        // deviation is measured from the nearest quarter turn of the roll, so the base angle must come from the
        // roll too: the icons' quarter turn is held a little past the diagonal.
        let sideways = LevelMath.quarterTurns(motion.roll) % 2 != 0
        // How far the drawing reaches above and below its middle: to the wings' ends turned sideways, the middle
        // line's steepest tilt upright. On the iPhone SE at 16:9, NIGHT's and VIDEO's controls start so near under
        // the frame's middle that a turned level's lower wing would run through their top row.
        let reach: CGFloat = sideways ? 70 : 27
        let place = CGPoint(x: center.x, y: min(center.y, open.maxY - reach - 4))
        LevelGraphic(deviation: motion.levelDeviation, isLevel: motion.isLevel)
            .rotationEffect(.degrees(sideways ? 90 : 0))
            .animation(Theme.spring, value: sideways)
            .position(place)
            // A new shape moves the frame's middle; the level glides there with the grid, and rises with a turn.
            .frameMotion(value: place)
            .opacity(isVisible ? 1 : 0)
            .animation(Theme.fade, value: isVisible)
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

    /// Something is being set or a shot runs, and the level would cross it: a dial's header and ruler (they reach the
    /// frame's middle in NIGHT and at 16:9), the quick settings panel, the zoom wheel, the exposure sun's drag, the
    /// Camera Control's overlay and the focus magnifier; a countdown, or a stack, an intervalometer or a bracket with
    /// its status and Stop. A camera that isn't running has nothing to level, and its card sits there instead.
    static func stepsAside(_ model: CameraModel, interaction: ViewfinderInteraction, wheel: ZoomWheelModel) -> Bool {
        if model.activeDial != nil || model.isDrawerOpen || wheel.isOpen || interaction.sliderAnchor != nil
            || model.controlsFullscreen || model.isMagnified {
            return true
        }
        switch model.activity {
        case .countdown, .stacking:
            return true
        case .idle, .capturing, .recording, .saving:
            // Filming keeps the level: it is clear of VIDEO's controls, and a level horizon matters in a movie.
            if model.intervalometer != nil || model.bracketInProgress { return true }
        }
        // Under the battery saver's black screen it would only tick for nobody.
        return model.sessionState != .running || model.dimmer.isDimmed
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
        .lineShadow()
        .animation(Theme.snappy, value: isLevel)
    }
}

// MARK: - Focus reticle

/// Where the focus square sits and whether it carries the long press's lock.
private struct FocusSquare: Equatable {
    var point: CGPoint
    var isLocked: Bool
}

/// Names a lock by what it holds, in the words of the model's lock toasts, the way cameras do. A long press holds the
/// focus and the exposure, or only the one of them still left to the camera; the AE-L chip holds the exposure alone.
private struct LockWording {
    let focus: Bool
    let exposure: Bool

    var badgeLabel: String {
        focus && exposure ? "AE/AF LOCK" : (exposure ? "AE LOCK" : "AF LOCK")
    }

    var spokenLabel: String {
        focus && exposure ? "Exposure and focus locked" : (exposure ? "Exposure locked" : "Focus locked")
    }
}

private struct FocusReticleLayer: View {
    let model: CameraModel
    let size: CGSize
    /// The preview layer's origin on screen: the model keeps the point in the layer's own coordinates.
    let origin: CGPoint
    /// The open part of the frame, between the top bar and the controls, which the lock label stays inside.
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
                    lock: LockWording(focus: model.focusLocked, exposure: model.aeLocked),
                    bias: Self.bias(model),
                    quarterTurns: turns,
                    labelBelow: Self.labelBelow(point, turns: turns, in: bounds),
                    labelRoom: Self.sideRoom(point, in: bounds, turns: turns),
                    labelInSight: Self.labelShows(at: point, turns: turns, in: bounds)
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
        // A square left under a dial that opened over it, or tapped between the controls, stops at their edge
        // instead of showing through the ruler; the corner badge then says what is locked (labelShows).
        .clipShape(OpenAreaClip(rect: bounds))
        .frameMotion(value: bounds)
    }

    /// Night mode keeps its own compensation; every other mode uses the manual one.
    private static func bias(_ model: CameraModel) -> Double {
        model.settings.mode == .night ? model.settings.night.biasEV : model.settings.manual.bias
    }

    /// The lock label goes above the square in the user's frame, or below it near the edge of what shows.
    private static func labelBelow(_ point: CGPoint, turns: Int, in bounds: CGRect) -> Bool {
        let offset = Upright.screenVector(CGPoint(x: 0, y: -(FocusReticle.side / 2 + 26)), quarterTurns: turns)
        let label = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        let margin: CGFloat = 8
        return label.x < bounds.minX + margin || label.x > bounds.maxX - margin
            || label.y < bounds.minY + margin || label.y > bounds.maxY - margin
    }

    /// The lock label of a square at `point` (on screen) is in sight: above or below the square, its middle lies
    /// inside what shows along the person's up and down. Along the other axis it slides to fit (SideClamp).
    static func labelShows(at point: CGPoint, turns: Int, in bounds: CGRect) -> Bool {
        let below = labelBelow(point, turns: turns, in: bounds)
        let offset = Upright.screenVector(CGPoint(x: 0, y: (below ? 1 : -1) * FocusReticle.labelDistance),
                                          quarterTurns: turns)
        let label = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        // About half the label's height.
        let half: CGFloat = 9
        switch ((turns % 4) + 4) % 4 {
        case 1, 3: return label.x >= bounds.minX + half && label.x <= bounds.maxX - half
        default: return label.y >= bounds.minY + half && label.y <= bounds.maxY - half
        }
    }

    /// The room from the point to the edges of what shows, to the person's left and right (Upright.screenVector: one
    /// quarter turn puts the person's right at the screen's bottom).
    private static func sideRoom(_ point: CGPoint, in bounds: CGRect, turns: Int) -> SideRoom {
        let left = point.x - bounds.minX
        let right = bounds.maxX - point.x
        let top = point.y - bounds.minY
        let bottom = bounds.maxY - point.y
        switch ((turns % 4) + 4) % 4 {
        case 1: return SideRoom(lead: top, trail: bottom)
        case 2: return SideRoom(lead: right, trail: left)
        case 3: return SideRoom(lead: bottom, trail: top)
        default: return SideRoom(lead: left, trail: right)
        }
    }
}

/// The room beside a point, to the person's left (`lead`) and right (`trail`).
private struct SideRoom: Equatable {
    var lead: CGFloat
    var trail: CGFloat
}

/// Lays the lock label out centred on the square, then slides it along until it clears the nearer side of what shows
/// by a margin, so a square tapped near an edge still has its whole label. One wider than the whole span stays
/// centred. A layout rather than a measured offset, so the label lands in place in its first frame.
private struct SideClamp: Layout {
    let room: SideRoom

    private static let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let size = label.sizeThatFits(.unspecified)
        let half = size.width / 2 + Self.margin
        var shift: CGFloat = 0
        if room.lead.isFinite, room.trail.isFinite, room.lead + room.trail >= 2 * half {
            shift = max(0, half - room.lead) - max(0, half - room.trail)
        }
        label.place(at: CGPoint(x: bounds.midX + shift, y: bounds.midY), anchor: .center,
                    proposal: ProposedViewSize(size))
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
    /// The room to the sides of what shows, which the lock label slides along to stay inside.
    let labelRoom: SideRoom
    /// The label is inside what shows. Out of sight under the controls, the corner badge says what is locked.
    let labelInSight: Bool

    /// The exposure slider in CameraPreviewView sits beside a square of this size.
    static let side: CGFloat = 72
    /// From the square's middle to the lock label's.
    static let labelDistance: CGFloat = side / 2 + 16

    @State private var settled = false
    @State private var faded = false

    var body: some View {
        ZStack {
            ReticleShape()
                .stroke(Theme.accent, lineWidth: 1.25)
                .frame(width: Self.side, height: Self.side)
                // With Reduce Motion the square lands in place and only fades.
                .scaleEffect(settled || AppearanceStore.shared.reduceMotion ? 1 : 1.3)
                // A held lock stays on screen, dimmed; a plain tap fades out like the Camera app's square.
                .opacity(faded ? (isLocked ? 0.6 : 0) : 1)
                .accessibilityHidden(true)
            if isLocked {
                SideClamp(room: labelRoom) {
                    Text(lock.badgeLabel)
                        .font(Theme.readoutFont.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent, in: Capsule())
                        .fixedSize()
                        // The corner lock badge steps aside while this label shows, so VoiceOver needs this one.
                        .accessibilityLabel(lock.spokenLabel)
                        .accessibilityHidden(!labelInSight)
                }
                .offset(y: (labelBelow ? 1 : -1) * Self.labelDistance)
                .transition(.opacity)
            }
        }
        .lineShadow()
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

/// Status badges in the top right corner of the open part of the frame. The column starts under the steady status,
/// and under the histogram while it shows: centred and about 260 pt wide, it reaches this corner on every phone
/// narrower than 440 pt. Each badge turns upright with the phone where it stands, like the other chips, so the column
/// keeps its corner and never moves under the controls. It reports its height, so a toast can go under it.
private struct StatusBadges: View {
    let model: CameraModel
    /// The open part of the frame, between the top bar and the controls.
    let rect: CGRect
    /// The steady status and the histogram the column starts under while they show. The column's height goes back
    /// into it.
    let furniture: TopFurniture
    /// The focus square, which carries its own lock label while that is in sight.
    let square: FocusSquare?
    /// The preview layer's origin on screen, where the square's point is measured from.
    let squareOrigin: CGPoint
    @State private var showsStackInfo = false

    var body: some View {
        let topShift = furniture.badgeShift(histogramShown: model.histogramOnScreen)
        // NIGHT's plan pill carries the stack symbol beside its frames, so the corner badge is MANUAL's alone, and
        // the shutter dial's header carries it while that dial is open.
        let stacked = model.settings.mode == .manual && model.shutterIsStacked && model.activeDial != .shutter
        let lock = LockWording(focus: model.focusLocked, exposure: model.aeLocked)
        let turns = model.motion.quarterTurns
        // Stands in for the square's label when the square is gone (a zoom moved the picture under it, or the AE-L
        // chip locked without one) or its label is out of sight under the controls.
        let reticleShowsLock = square.map { square in
            square.isLocked && FocusReticleLayer.labelShows(
                at: CGPoint(x: square.point.x + squareOrigin.x, y: square.point.y + squareOrigin.y),
                turns: turns, in: rect)
        } ?? false
        let showsLock = (lock.focus || lock.exposure) && !reticleShowsLock
        let magnified = model.isMagnified
        // The quick settings panel covers the top of the frame. Badges under its glass would only smear behind it.
        let underPanel = model.isDrawerOpen
        VStack(alignment: .trailing, spacing: 0) {
            if magnified {
                // First: while the frame is enlarged, nothing else on it reads as it would.
                MagnifierBadge(model: model, quarterTurns: turns)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if stacked {
                // The one badge that takes a touch: the word needs explaining, and a tap on it does.
                Button {
                    Haptics.tap()
                    showsStackInfo = true
                } label: {
                    StatusBadge(symbol: "square.stack.3d.up.fill", text: "STACKED", tint: Theme.accent,
                                quarterTurns: turns)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A 44 pt touch in the column's 34 pt row, so neither the column nor a toast under it moves.
                .padding(.vertical, -5)
                // Below the badge, over the picture: no other side of the corner fits the bubble on every phone.
                .stackExplanation(isPresented: $showsStackInfo, arrowEdge: .bottom)
                .accessibilityHint("Explains what a stacked exposure is.")
                .transition(.opacity)
            }
            Group {
                if showsLock {
                    StatusBadge(symbol: "lock.fill", text: lock.badgeLabel, tint: Theme.accent, quarterTurns: turns)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                SensorBadges(model: model, quarterTurns: turns)
            }
            .allowsHitTesting(false)
        }
        // The layout's height, not the animated one, so a toast heads for where the column ends up.
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            if furniture.badgeColumnHeight != height { furniture.badgeColumnHeight = height }
        }
        .padding(.top, 10 + topShift)
        .padding(.trailing, 10)
        .frame(width: max(rect.width, 0), height: max(rect.height, 0), alignment: .topTrailing)
        .position(x: rect.midX, y: rect.midY)
        .frameMotion(value: rect)
        .animation(Theme.snappy, value: magnified)
        .animation(Theme.snappy, value: stacked)
        .animation(Theme.snappy, value: showsLock)
        .animation(Theme.spring, value: topShift)
        // The Camera Control overlay takes over the screen; the badges step aside while it shows.
        .opacity(model.controlsFullscreen || underPanel ? 0 : 1)
        .animation(Theme.snappy, value: model.controlsFullscreen)
        .animation(Theme.snappy, value: underPanel)
        .allowsHitTesting(!underPanel)
        .accessibilityHidden(underPanel)
        // The bubble is a system presentation above the whole camera, so it has to be closed with its badge. It
        // would stay lit on the battery saver's black screen, where the first touch would close it instead of
        // lighting the screen, over the Camera Control's overlay, and over the quick settings that hide the badge.
        // A badge that leaves takes its bubble down but not always the flag, and the next badge would then open
        // one by itself.
        .onChange(of: stacked && !model.dimmer.isDimmed && !model.controlsFullscreen && !underPanel) { _, inSight in
            if !inSight && showsStackInfo { showsStackInfo = false }
        }
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
            .font(Theme.microFont)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            // Grows with Larger labels, as its words do.
            .frame(height: 22 * Theme.labelScale)
            .cameraGlass(in: Capsule())
            .uprightRotation(Upright.degrees(quarterTurns))
        }
        .animation(Theme.spring, value: sideways)
        .accessibilityElement(children: .combine)
    }
}

/// The focus magnifier's power, "5×". On its own, because the power follows the zoom readings ten times a second.
private struct MagnifierBadge: View {
    let model: CameraModel
    let quarterTurns: Int

    var body: some View {
        let power = model.magnifierShownPower
        StatusBadge(symbol: "plus.magnifyingglass", text: LensMath.zoomLabel(power, selected: true),
                    tint: Theme.accent, quarterTurns: quarterTurns)
            .accessibilityLabel("Magnified \(LensMath.zoomLabel(power, selected: false)) times")
            .accessibilityHint("Tap the picture to see the whole frame.")
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
                    tint: readings.pressure == .serious ? Theme.warning : Theme.recording,
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
