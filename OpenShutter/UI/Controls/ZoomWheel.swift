import SwiftUI
import UIKit
import QuartzCore
import CameraCore

// Touch and hold a lens button, then drag: the buttons give way to a ruler that zooms with the finger, like the
// Camera app's zoom wheel. The camera follows the finger continuously; the readout and the landing use ZoomMath's
// grid (tenths below 10x, whole numbers from there), so a zoom can stop on 1.4x. After the lift the wheel waits a
// moment for another stroke, then folds back into the buttons.

/// Where a touch on the wheel comes from: the hold on a lens button that opened it, or a new touch on the wheel
/// while it lingers after a lift.
enum ZoomWheelTouch {
    case hold, surface
}

/// The wheel's state, owned by LensRow. A reference, so a drag reaches only the views that draw it: the row and the
/// buttons read `isOpen`, the ruler reads `rawZoom`, the readout reads `shownZoom`.
@MainActor
@Observable
final class ZoomWheelModel {
    /// The ruler stands in for the lens buttons.
    private(set) var isOpen = false
    /// A finger is zooming with it: the hold that opened it, or a new touch while it lingers.
    private(set) var isDragging = false
    /// The zoom under the centre line, 1:1 with the finger. Changes on every touch event.
    private(set) var rawZoom = 1.0
    /// What the readout says: the raw zoom on the wheel's grid, with hysteresis so a resting finger doesn't flicker.
    private(set) var shownZoom = 1.0
    /// What this opening offers. Fixed while the wheel is open, so the ruler never rescales under the finger when
    /// the camera changes lenses on the way.
    private(set) var scale = ZoomWheelScale.empty

    /// The finger now zooming, if any.
    @ObservationIgnored private var stroke: Stroke?
    /// The touch the wheel is following, from its first update to its lift.
    @ObservationIgnored private var touch: Touch?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var lastTickTime: CFTimeInterval = 0
    /// The end the finger pushed into. Its stop played once; it plays again only after the shown value left it.
    @ObservationIgnored private var latchedEnd: Double?

    private struct Stroke {
        /// The zoom at zero travel. It moves with an end the finger pushes past.
        var start: Double
        var lastSent: Double
        /// A hold released without moving leaves the zoom where it was.
        var sentAny = false
        /// A touch on the lingering wheel that never moved is a tap, which closes it.
        var moved = false
    }

    private struct Touch {
        let source: ZoomWheelTouch
        var accepted: Bool
        /// Travel already reported when the touch was taken on, so the stroke starts where the finger is.
        var origin: Double = 0
    }

    /// Lens to lens is 100 pt of travel either way, so a tap that wobbles moves less than a tenth.
    private static let tapSlop = 10.0
    /// Finger jitter would otherwise send the camera a new zoom on every touch event, as pinch's filter says.
    private static let sendThreshold = 0.002
    /// Selection feedback faster than about 30 a second turns into a buzz.
    private static let tickInterval: CFTimeInterval = 0.035
    private static let lingerNanoseconds: UInt64 = 1_500_000_000
    /// Zooms closer than this many doublings (under one percent) are the same zoom: a landing the camera reached
    /// reads back far closer.
    private static let sameZoomStops = 0.01

    // MARK: - Touches

    /// Every update of a touch on the wheel. `translation` is the horizontal travel in points since the touch
    /// began, nil until the hold's finger moves. The first update opens the wheel (a hold) or takes it on again (a
    /// touch while it lingers); a touch the wheel refuses is ignored to its lift.
    func touchChanged(_ source: ZoomWheelTouch, translation: Double?, model: CameraModel) {
        if touch == nil {
            let accepted = source == .hold ? begin(model: model) : grab(model: model)
            touch = Touch(source: source, accepted: accepted, origin: translation ?? 0)
        }
        // A second finger on the other control while one is zooming would pull the zoom two ways.
        guard let touch, touch.source == source, touch.accepted, let translation else { return }
        drag(translation: translation - touch.origin, model: model)
    }

    /// The touch lifted, or the system cancelled it. A second report of the same lift does nothing.
    func touchEnded(_ source: ZoomWheelTouch, model: CameraModel) {
        guard let touch, touch.source == source else { return }
        self.touch = nil
        guard touch.accepted else { return }
        let wasTap = source == .surface && stroke.map { !$0.moved } == true
        end(model: model)
        if wasTap { close() }
    }

    // MARK: - Strokes

    /// The hold on a lens button went through: opens the wheel at the zoom asked for last, whichever button the
    /// finger is on. Refused while the camera can't zoom.
    @discardableResult
    func begin(model: CameraModel) -> Bool {
        guard Self.canAdjust(model) else { return false }
        if model.activeDial == .zoom {
            withAnimation(Theme.spring) { model.activeDial = nil }
        }
        startStroke(at: model.requestedZoom, model: model)
        Haptics.tap()
        if !isOpen {
            withAnimation(Theme.spring) { isOpen = true }
        }
        return true
    }

    /// A new touch on the lingering wheel: carries on from where the ruler stands, without another hold. If the
    /// zoom moved some other way meanwhile (a pinch, the Camera Control), the ruler goes on from there instead.
    @discardableResult
    func grab(model: CameraModel) -> Bool {
        guard isOpen, stroke == nil, Self.canAdjust(model) else { return false }
        let requested = model.requestedZoom
        let movedElsewhere = ZoomMath.stops(from: rawZoom, to: requested) > Self.sameZoomStops
        startStroke(at: movedElsewhere ? requested : rawZoom, model: model)
        return true
    }

    /// The finger moved `translation` points from where the stroke began; left zooms in.
    func drag(translation: Double, model: CameraModel) {
        guard var stroke, translation.isFinite else { return }
        // A shot that starts under the finger, such as a timer running out, keeps the zoom it starts with.
        guard Self.canAdjust(model) else { return }
        let span = scale.span
        var raw = ZoomMath.zoom(from: stroke.start, translation: translation)
        let pinned = raw < span.lowerBound || raw > span.upperBound
        if pinned {
            raw = min(max(raw, span.lowerBound), span.upperBound)
            // The start moves with the end, so the wheel answers the moment the finger turns around.
            stroke.start = ZoomMath.zoom(from: raw, translation: -translation)
        }
        if abs(translation) >= Self.tapSlop { stroke.moved = true }
        if raw != rawZoom { rawZoom = raw }

        let shown = scale.clamped(ZoomMath.snapped(raw, keeping: shownZoom))
        if shown != shownZoom {
            let previous = shownZoom
            shownZoom = shown
            stroke.moved = true
            if let end = latchedEnd, shown != end { latchedEnd = nil }
            stepped(from: previous, to: shown)
        }
        // Only a real push into the end stops: a wheel opened at its end would otherwise bump on the jitter of the
        // finger that just held it.
        if pinned, latchedEnd == nil, stroke.moved {
            latchedEnd = shown
            Haptics.stop()
        }

        // An end always goes through, so the zoom lands on it exactly rather than a hair short.
        let reachesEnd = pinned && raw != stroke.lastSent
        if reachesEnd || abs(raw - stroke.lastSent) > stroke.lastSent * Self.sendThreshold {
            stroke.lastSent = raw
            stroke.sentAny = true
            model.setDisplayZoom(raw, animated: false, continuing: true)
        }
        self.stroke = stroke
    }

    /// The finger lifted. The zoom stays where the finger left it: the camera settles onto the value the readout
    /// shows, now picking the lens strictly since no finger is down, and the ruler eases onto that tick. The wheel
    /// then waits a moment for another stroke.
    func end(model: CameraModel) {
        guard let stroke else { return }
        self.stroke = nil
        if isDragging { isDragging = false }
        if stroke.sentAny {
            let landing = shownZoom
            if Self.canAdjust(model) {
                model.setDisplayZoom(landing, animated: true)
            }
            if rawZoom != landing {
                withAnimation(.easeOut(duration: 0.18)) { rawZoom = landing }
            }
            Self.announce(landing)
        }
        scheduleLinger()
    }

    /// Folds the wheel back into the buttons. A touch still on it is ignored from here to its lift.
    func close() {
        lingerTask?.cancel()
        lingerTask = nil
        stroke = nil
        if isDragging { isDragging = false }
        touch?.accepted = false
        latchedEnd = nil
        guard isOpen else { return }
        withAnimation(Theme.spring) { isOpen = false }
    }

    /// Zoom stays put while frames are captured or saved, as the viewfinder's pinch does, and the selfie camera has
    /// no lens buttons to hold.
    static func canAdjust(_ model: CameraModel) -> Bool {
        guard model.sessionState == .running, !model.capabilities.lens.isFront else { return false }
        switch model.activity {
        case .idle, .countdown, .recording: return true
        case .capturing, .stacking, .saving: return false
        }
    }

    // MARK: - Helpers

    private func startStroke(at zoom: Double, model: CameraModel) {
        lingerTask?.cancel()
        lingerTask = nil
        let fresh = ZoomWheelScale(model: model)
        if fresh != scale { scale = fresh }
        let start = scale.clamped(zoom)
        stroke = Stroke(start: start, lastSent: start)
        if !isDragging { isDragging = true }
        if rawZoom != start { rawZoom = start }
        let shown = scale.clamped(ZoomMath.snapped(start))
        if shown != shownZoom { shownZoom = shown }
        latchedEnd = nil
    }

    /// A tick per step, at most one per 35 ms; a firmer tap, never skipped, where the value reaches a lens button's.
    /// Haptics decides from the Zoom ticks setting whether the steps between lens values tick at all.
    private func stepped(from previous: Double, to shown: Double) {
        let now = CACurrentMediaTime()
        let low = min(previous, shown)
        let high = max(previous, shown)
        // A fast stroke can step over a lens value between two touch events; the tap still marks it.
        let reachesLens = scale.lensStops.contains { $0 != previous && $0 >= low && $0 <= high }
        guard reachesLens || now - lastTickTime >= Self.tickInterval else { return }
        Haptics.zoomTick(atLensValue: reachesLens)
        lastTickTime = now
    }

    private func scheduleLinger() {
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.lingerNanoseconds)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// The wheel is drawn only, so VoiceOver hears where a stroke landed.
    private static func announce(_ zoom: Double) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(spokenZoom(zoom)).post()
    }

    /// "1.4x", in the person's own number format.
    static func spokenZoom(_ zoom: Double) -> String {
        let rounded = ((zoom.isFinite && zoom > 0 ? zoom : 1) * 10).rounded() / 10
        return "\(rounded.formatted())x"
    }
}

// MARK: - Scale

/// What one opening of the wheel offers and draws, read from the camera when a stroke starts.
struct ZoomWheelScale: Equatable {
    struct Label: Equatable {
        var zoom: Double
        var text: String
        /// The grid value the readout shows at this label, so the label lights up there.
        var grid: Double
    }

    struct Lens: Equatable {
        var zoom: Double
        var focalLength: Double
    }

    var span: ClosedRange<Double>
    /// Short ticks: the wheel's steps without the labelled values, which get long ticks of their own.
    var minorTicks: [Double]
    var labels: [Label]
    /// The lens buttons' values on the wheel's grid, where it taps harder.
    var lensStops: [Double]
    /// The back lenses, widest first, for the focal length under the readout.
    var lenses: [Lens]
    /// The one lens the camera keeps for this opening: switching is off, or a countdown, a recording or a photo
    /// still saving holds the session on its lens.
    var fixedLens: Lens?
    /// Millimetres are for people who think in lenses; the simple interface counts in times.
    var showsFocalLength: Bool
    /// Larger labels makes the ruler's numbers bigger, and spaces them further apart to match.
    var labelScale: CGFloat

    static let empty = ZoomWheelScale(span: 1...1, minorTicks: [], labels: [], lensStops: [], lenses: [],
                                      fixedLens: nil, showsFocalLength: false, labelScale: 1)

    /// Round values labelled after the lens buttons, as on the Camera app's wheel.
    private static let roundLabels: [Double] = [10, 15, 20, 25, 30, 40]
    /// Labels closer than this, in points of travel, would touch.
    private static let labelGap = 26.0

    init(span: ClosedRange<Double>, minorTicks: [Double], labels: [Label], lensStops: [Double], lenses: [Lens],
         fixedLens: Lens?, showsFocalLength: Bool, labelScale: CGFloat) {
        self.span = span
        self.minorTicks = minorTicks
        self.labels = labels
        self.lensStops = lensStops
        self.lenses = lenses
        self.fixedLens = fixedLens
        self.showsFocalLength = showsFocalLength
        self.labelScale = labelScale
    }

    @MainActor
    init(model: CameraModel) {
        let span = Self.usable(model.zoomSpan)
        let active = model.capabilities.lens
        let marks = active.isFront ? [] : model.zoomMarks.filter {
            $0.isFinite && $0 >= span.lowerBound * 0.999 && $0 <= span.upperBound * 1.001
        }.sorted()
        let labelScale = Theme.labelScale.isFinite ? max(Theme.labelScale, 1) : 1

        // Lens values first, so a round number never pushes one out; the ends last, for phones with few lenses.
        let candidates = marks + Self.roundLabels.filter(span.contains) + [span.upperBound, span.lowerBound]
        let gap = Self.labelGap * Double(labelScale) / ZoomMath.pointsPerStop
        var placed: [Double] = []
        for value in candidates where placed.allSatisfy({ abs(log2(value / $0)) >= gap }) {
            placed.append(value)
        }
        let labels = placed.sorted().map {
            Label(zoom: $0, text: LensMath.zoomLabel($0, selected: false), grid: ZoomMath.snapped($0))
        }
        let minorTicks = ZoomMath.ticks(in: span).filter { tick in
            !placed.contains { abs(log2(tick / $0)) < 0.02 }
        }

        func lens(_ info: LensInfo) -> Lens? {
            let zoom = info.relativeZoom
            let focal = info.equivalentFocalLength
            guard zoom.isFinite, zoom > 0, focal.isFinite, focal > 0 else { return nil }
            return Lens(zoom: zoom, focalLength: focal)
        }
        let backLenses = model.lenses.filter { !$0.isFront && $0.kind != .external }.compactMap(lens)
        // The model's own rule for when a zoom may change lenses.
        let followsLenses = model.settings.controls.autoLensSwitching && !active.isFront
            && !model.activity.isBusy && model.photosInFlight == 0

        self.init(span: span,
                  minorTicks: minorTicks,
                  labels: labels,
                  lensStops: Array(Set(marks.map { ZoomMath.snapped($0) })).sorted(),
                  lenses: backLenses.sorted { $0.zoom < $1.zoom },
                  fixedLens: followsLenses ? nil : lens(active),
                  showsFocalLength: model.isAdvanced,
                  labelScale: labelScale)
    }

    func clamped(_ zoom: Double) -> Double {
        let value = zoom.isFinite && zoom > 0 ? zoom : 1
        return min(max(value, span.lowerBound), span.upperBound)
    }

    /// 35 mm equivalent at `zoom`, on the lens the camera ends on there: the longest one at or below it, as the
    /// model picks, unless this opening keeps one lens.
    func focalLength(at zoom: Double) -> Double? {
        guard zoom.isFinite, zoom > 0,
              let lens = fixedLens ?? lenses.last(where: { $0.zoom <= zoom + 0.001 }) ?? lenses.first else { return nil }
        let millimetres = lens.focalLength * zoom / lens.zoom
        return millimetres.isFinite && millimetres > 0 ? millimetres : nil
    }

    private static func usable(_ span: ClosedRange<Double>) -> ClosedRange<Double> {
        let low = span.lowerBound
        let high = span.upperBound
        guard low.isFinite, high.isFinite, low > 0, high >= low else { return 1...1 }
        return low...high
    }
}

// MARK: - Views

/// The wheel laid over the lens row: the readout above, the ruler and its touch surface over the row itself. An
/// overlay, so the controls zone measures the same height whether it is open or not. Drawn only: VoiceOver zooms
/// with the active lens button instead.
struct ZoomWheelOverlay: View {
    let model: CameraModel
    let wheel: ZoomWheelModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if wheel.isOpen {
                VStack(spacing: 2) {
                    ZoomReadout(model: model, wheel: wheel)
                        .allowsHitTesting(false)
                    ZStack {
                        ZoomWheelFace(wheel: wheel)
                            .allowsHitTesting(false)
                        ZoomWheelSurface(model: model, wheel: wheel)
                    }
                    .frame(height: ZoomWheelFace.height)
                    .background { ZoomWheelBackdrop() }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

/// In the 16:9 layout the wheel sits on the live picture, so the ticks get a soft dark band behind them.
private struct ZoomWheelBackdrop: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.32), location: 0.3),
                .init(color: .black.opacity(0.32), location: 0.75),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// The ruler, in the style of RulerDial. Reads the raw zoom, so it redraws on every touch event; nothing else does.
struct ZoomWheelFace: View {
    let wheel: ZoomWheelModel

    static let height: CGFloat = 56

    var body: some View {
        let zoom = wheel.rawZoom
        ZoomRuler(position: log2(zoom.isFinite && zoom > 0 ? zoom : 1), shownZoom: wheel.shownZoom,
                  scale: wheel.scale, accent: Theme.accent)
            .overlay {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2, height: 26)
                    .offset(y: 9)
            }
    }
}

/// Animatable on the log of the zoom, so the lift eases the ruler onto its tick at an even pace on screen.
private struct ZoomRuler: View, Animatable {
    var position: Double
    let shownZoom: Double
    let scale: ZoomWheelScale
    /// Read in the parent's body and passed in: the Canvas draws later, and the accent can change.
    let accent: Color
    @Environment(\.displayScale) private var displayScale

    private static let labelCenterY: CGFloat = 12
    private static let tickBottom: CGFloat = 44
    private static let majorTickHeight: CGFloat = 16
    private static let minorTickHeight: CGFloat = 9
    /// How far the ends of the ruler sit below its middle: a gentle arc, as on the Camera app's wheel.
    private static let arcDepth: CGFloat = 6

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let labelFont = Font.system(size: 11 * scale.labelScale, weight: .semibold).monospacedDigit()
        Canvas { context, size in
            draw(in: &context, size: size, labelFont: labelFont)
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

    private func draw(in context: inout GraphicsContext, size: CGSize, labelFont: Font) {
        let center = pow(2, position)
        guard center.isFinite, center > 0, size.width > 0 else { return }
        let midX = Double(size.width) / 2
        let reach = midX + 12
        // Tick edges sit on device pixels so hairlines stay crisp instead of smearing across two pixels.
        let pixels = displayScale.isFinite && displayScale >= 1 ? displayScale : 1
        func snapped(_ value: CGFloat) -> CGFloat { (value * pixels).rounded() / pixels }
        let minorWidth = max(snapped(1), 1 / pixels)
        let majorWidth = max(snapped(1.5), 1 / pixels)
        func drop(_ dx: Double) -> CGFloat {
            let t = dx / max(midX, 1)
            return Self.arcDepth * CGFloat(min(t * t, 1.5))
        }

        // Over a bright sky white ticks need an edge, as SunSliderGraphic's do.
        context.addFilter(.shadow(color: .black.opacity(0.4), radius: 1.5))
        var minor = Path()
        for tick in scale.minorTicks {
            let dx = ZoomMath.offset(of: tick, from: center)
            guard abs(dx) <= reach else { continue }
            let x = CGFloat(midX + dx)
            minor.addRect(CGRect(x: snapped(x - minorWidth / 2), y: Self.tickBottom - Self.minorTickHeight + drop(dx),
                                 width: minorWidth, height: Self.minorTickHeight))
        }
        var major = Path()
        var visibleLabels: [(label: ZoomWheelScale.Label, x: CGFloat, y: CGFloat)] = []
        for label in scale.labels {
            let dx = ZoomMath.offset(of: label.zoom, from: center)
            guard abs(dx) <= reach + 20 else { continue }
            let x = CGFloat(midX + dx)
            let y = drop(dx)
            major.addRect(CGRect(x: snapped(x - majorWidth / 2), y: Self.tickBottom - Self.majorTickHeight + y,
                                 width: majorWidth, height: Self.majorTickHeight))
            visibleLabels.append((label, x, y))
        }
        context.fill(minor, with: .color(.white.opacity(0.45)))
        context.fill(major, with: .color(.white.opacity(0.9)))
        for item in visibleLabels {
            var text = context.resolve(Text(item.label.text).font(labelFont))
            text.shading = .color(item.label.grid == shownZoom ? accent : .white.opacity(0.75))
            context.draw(text, at: CGPoint(x: item.x, y: Self.labelCenterY + item.y), anchor: .center)
        }
    }
}

/// The value above the ruler's centre line: "1.4x", and in the advanced interface the equivalent focal length under
/// it. It turns upright with the phone; the ruler's labels stay level, as RulerDial's do.
struct ZoomReadout: View {
    let model: CameraModel
    let wheel: ZoomWheelModel

    var body: some View {
        let zoom = wheel.shownZoom
        let scale = wheel.scale
        ZoomReadoutBubble(
            value: LensMath.zoomLabel(zoom, selected: true),
            detail: scale.showsFocalLength ? scale.focalLength(at: zoom).map(LensMath.focalLengthLabel) : nil
        )
        // Motion updates 30 times a second; read here, it redraws this bubble and nothing else of the wheel.
        .uprightRotation(model.motion.iconRotationDegrees)
    }
}

/// Plain values only, so the 30 Hz rotation updates above leave the text alone. No numeric roll: the value
/// changes on every step and would never settle.
private struct ZoomReadoutBubble: View {
    let value: String
    let detail: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(Theme.bigValueFont)
                .foregroundStyle(Theme.accent)
            if let detail {
                Text(detail)
                    .font(Theme.readoutFont)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(minWidth: 64, minHeight: 30)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Takes new touches while the wheel lingers after a lift, so the next stroke needs no hold. Over the ruler only:
/// the readout above it sits on the picture, which keeps its tap to focus.
private struct ZoomWheelSurface: View {
    let model: CameraModel
    let wheel: ZoomWheelModel

    @GestureState private var isTouching = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($isTouching) { _, touching, _ in
                        touching = true
                    }
                    .onChanged { value in
                        wheel.touchChanged(.surface, translation: Double(value.translation.width), model: model)
                    }
                    .onEnded { _ in
                        wheel.touchEnded(.surface, model: model)
                    }
            )
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                // A touch the system cancels never reaches onEnded; look again once this gesture update is over.
                Task { @MainActor in wheel.touchEnded(.surface, model: model) }
            }
    }
}
