import SwiftUI
import UIKit
import QuartzCore
import Observation
import CameraCore

/// The live image (the backend's preview layer) plus the analysis overlay and the viewfinder gestures.
struct CameraPreviewView: View {
    @Bindable var model: CameraModel

    @State private var interaction = ViewfinderInteraction()

    var body: some View {
        ZStack {
            PreviewSurface(model: model, interaction: interaction)
            AnalysisOverlay(model: model)
            ExposureSlider(model: model, interaction: interaction)
        }
        .background(Theme.background)
        .clipped()
        .onChange(of: model.activePresetID, initial: true) { _, id in
            interaction.noteActivePreset(id, model: model)
        }
        .modifier(ViewfinderAccessibility(model: model, interaction: interaction))
    }
}

/// VoiceOver reads the viewfinder as one adjustable element. A modifier of its own, so reading the exposure for
/// the spoken value doesn't make the preview's body depend on every settings change.
private struct ViewfinderAccessibility: ViewModifier {
    let model: CameraModel
    let interaction: ViewfinderInteraction

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Viewfinder")
            // Without a value VoiceOver says nothing after a swipe, so the change would go unheard.
            .accessibilityValue("Exposure " + EVFormat.label(ViewfinderInteraction.currentBias(model)))
            .accessibilityHint("Double tap to focus in the middle. Swipe up or down to change exposure.")
            .accessibilityAction {
                interaction.focusCenter(lock: false, model: model)
            }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: interaction.nudgeBias(by: 1.0 / 3.0, model: model)
                case .decrement: interaction.nudgeBias(by: -1.0 / 3.0, model: model)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Lock focus and exposure") {
                interaction.focusCenter(lock: true, model: model)
            }
            .accessibilityAction(named: "Switch zoom") {
                interaction.toggleZoom(model: model)
            }
    }
}

// MARK: - Gesture logic

/// State shared by the UIKit gesture recognizers and the SwiftUI exposure slider.
@MainActor
@Observable
private final class ViewfinderInteraction {
    /// Where the exposure slider sits during a drag and for a moment after it; nil otherwise.
    private(set) var sliderAnchor: CGPoint?
    private(set) var isDraggingExposure = false

    // ViewfinderOverlays draws the focus square and keeps the same books from the same model state, so the sun
    // comes and goes with the square.
    /// The focus point the flags below describe. A model.focusPoint that differs is a tap the change handlers
    /// haven't caught up with yet.
    private(set) var trackedFocusPoint: CGPoint?
    /// False once a zoom or lens change has moved the picture under the tracked point.
    private(set) var focusPointIsCurrent = false
    /// The square is bright: tapped, or exposure changed beside it, within the last two seconds.
    private(set) var reticleIsFresh = false
    /// The long press that placed the tracked point also locked exposure, so the square stays while that lasts.
    private(set) var lockIsAtFocusPoint = false
    /// Bumped to restart the two-second fade.
    private(set) var freshGeneration = 0

    /// Size of the preview host, for actions aimed at the middle of the frame.
    @ObservationIgnored var viewSize: CGSize = .zero

    @ObservationIgnored private var alternatePresetID: String?
    @ObservationIgnored private var lastTap: (time: CFTimeInterval, point: CGPoint)?
    @ObservationIgnored private var pinchBase = 1.0
    @ObservationIgnored private var pinchLastSent = 1.0
    @ObservationIgnored private var pinchAtLimit = false
    @ObservationIgnored private var recentZoom: (value: Double, time: CFTimeInterval)?
    @ObservationIgnored private var dragStartBias = 0.0
    @ObservationIgnored private var dragLastBias = 0.0
    @ObservationIgnored private var dragAtLimit = false
    @ObservationIgnored private var dragQuarterTurns = 0
    @ObservationIgnored private var lingerTask: Task<Void, Never>?

    /// Vertical travel per EV. The sun moves the same distance, so it stays under the finger.
    static let pointsPerEV: CGFloat = 36
    private static let doubleTapInterval: CFTimeInterval = 0.3
    private static let doubleTapSlop = 40.0

    // MARK: Focus

    func tap(at point: CGPoint, model: CameraModel) {
        let now = CACurrentMediaTime()
        if let last = lastTap, now - last.time <= Self.doubleTapInterval,
           Self.distance(last.point, point) <= Self.doubleTapSlop {
            // Focusing on the first tap keeps single taps instant; the second tap of a pair switches zoom.
            lastTap = nil
            toggleZoom(model: model)
            return
        }
        lastTap = (now, point)
        guard canAdjust(model) else { return }
        model.tapToFocus(at: point, lock: false)
    }

    func longPress(at point: CGPoint, model: CameraModel) {
        lastTap = nil
        guard canAdjust(model) else { return }
        model.tapToFocus(at: point, lock: true)
    }

    func focusCenter(lock: Bool, model: CameraModel) {
        guard canAdjust(model), viewSize.width > 0, viewSize.height > 0 else { return }
        model.tapToFocus(at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), lock: lock)
    }

    /// Focus, zoom and exposure stay put while frames are captured or saved, so a stray touch can't move
    /// the lens in the middle of a long exposure or a bracket.
    func canAdjust(_ model: CameraModel) -> Bool {
        guard model.sessionState == .running else { return false }
        switch model.activity {
        case .idle, .countdown, .recording: return true
        case .capturing, .stacking, .saving: return false
        }
    }

    // MARK: Focus square

    func focusPointChanged(to point: CGPoint?, model: CameraModel) {
        trackedFocusPoint = point
        focusPointIsCurrent = point != nil
        reticleIsFresh = point != nil
        lockIsAtFocusPoint = point != nil && model.aeLocked
        freshGeneration &+= 1
    }

    /// The model keeps the point of a released lock. Locking again later (the AE-L chip) isn't tied to that old
    /// square, so it must not bring the square and the sun back.
    func aeLockChanged(_ locked: Bool) {
        if !locked && lockIsAtFocusPoint {
            lockIsAtFocusPoint = false
        }
    }

    /// Changing exposure beside a square that is still up keeps it up, like the Camera app's while its sun moves.
    func biasChanged(model: CameraModel) {
        guard reticleIsFresh || holdsLock(model) else { return }
        reticleIsFresh = true
        freshGeneration &+= 1
    }

    func freshnessExpired() {
        if reticleIsFresh {
            reticleIsFresh = false
        }
    }

    /// Pinching changes the zoom on every touch event; writing only on a real change spares the observers.
    func focusPointMoved() {
        if focusPointIsCurrent {
            focusPointIsCurrent = false
        }
    }

    /// Where the focus square is on screen, if it is.
    func visibleFocusPoint(_ model: CameraModel) -> CGPoint? {
        guard let point = model.focusPoint else { return nil }
        // A point the handlers haven't seen yet was tapped a moment ago, so its square has just appeared.
        guard point == trackedFocusPoint else { return point }
        guard focusPointIsCurrent, reticleIsFresh || holdsLock(model) else { return nil }
        return point
    }

    /// A tap clears the AE lock and a long press sets it, so a point that arrived locked came from a long press.
    private func holdsLock(_ model: CameraModel) -> Bool {
        model.aeLocked && lockIsAtFocusPoint
    }

    // MARK: Zoom

    /// Remembers the last back lens button other than 1x, the other end of the double tap toggle.
    func noteActivePreset(_ id: String?, model: CameraModel) {
        guard let id, let preset = model.lensPresets.first(where: { $0.id == id }) else { return }
        let lenses = Self.lensTable(model)
        guard Self.isBack(preset, lenses), !Self.isOneX(preset, lenses) else { return }
        alternatePresetID = id
    }

    /// Double tap: 1x and the lens used before it.
    func toggleZoom(model: CameraModel) {
        guard canAdjust(model), !model.activity.isBusy else { return }
        let lenses = Self.lensTable(model)
        let back = model.lensPresets.filter { Self.isBack($0, lenses) }
        guard let oneX = back.first(where: { Self.isOneX($0, lenses) }),
              let active = model.activePreset, Self.isBack(active, lenses) else { return }
        let atOneX = active.id == oneX.id && abs(model.settings.zoom - oneX.zoomFactor) < 0.02
        guard atOneX else {
            if active.id != oneX.id { alternatePresetID = active.id }
            model.select(oneX)
            return
        }
        let others = back.filter { $0.id != oneX.id }
        let target = others.first(where: { $0.id == alternatePresetID })
            ?? others.filter { $0.displayZoom > oneX.displayZoom }.min(by: { $0.displayZoom < $1.displayZoom })
            ?? others.first
        if let target {
            model.select(target)
        }
    }

    func pinchBegan(model: CameraModel) {
        pinchBase = currentDisplayZoom(model)
        pinchLastSent = pinchBase
        pinchAtLimit = false
    }

    func pinchChanged(scale: CGFloat, model: CameraModel) {
        let factor = Double(scale)
        guard factor.isFinite, factor > 0, canAdjust(model) else { return }
        let range = Self.displayZoomRange(model)
        let wanted = pinchBase * factor
        let target = min(max(wanted, range.lowerBound), range.upperBound)
        if target != wanted {
            // Moving the base with the limit makes the zoom answer the moment the fingers turn around.
            pinchBase = target / factor
            if !pinchAtLimit { Haptics.stop() }
            pinchAtLimit = true
        } else {
            pinchAtLimit = false
        }
        let previous = pinchLastSent
        // Finger jitter would otherwise send the device a new zoom on every touch event. The limit itself always
        // goes through, so the zoom lands exactly on it rather than a hair short.
        let reachesLimit = pinchAtLimit && target != previous
        guard reachesLimit || abs(target - previous) > previous * 0.002 else { return }
        if Self.crossesPreset(from: previous, to: target, model: model) {
            Haptics.tick()
        }
        pinchLastSent = target
        recentZoom = (target, CACurrentMediaTime())
        model.setDisplayZoom(target, animated: false)
    }

    func pinchEnded() {
        pinchAtLimit = false
    }

    private func currentDisplayZoom(_ model: CameraModel) -> Double {
        // Readings arrive ten times a second, so right after a pinch they can trail what was just set.
        if let recent = recentZoom, CACurrentMediaTime() - recent.time < 0.6 {
            return recent.value
        }
        let live = model.readings.displayZoom
        return live.isFinite && live > 0 ? live : 1
    }

    /// Display zoom the pinch may reach: the active lens, or every back lens when auto switching is on.
    private static func displayZoomRange(_ model: CameraModel) -> ClosedRange<Double> {
        let factors = model.capabilities.zoomRange
        let low = positive(factors.lowerBound, or: 1)
        let high = max(positive(factors.upperBound, or: low), low)
        let lenses = model.lenses
        let activeID = model.backend.activeLensID ?? model.settings.lensID
        let active = lenses.first(where: { $0.id == activeID })
        let activeZoom = positive(active?.relativeZoom ?? 1, or: 1)
        var lower = activeZoom * low
        var upper = activeZoom * high
        // The same conditions as the model's switch: it holds the lens while photos are still being saved.
        if model.settings.controls.autoLensSwitching, active?.isFront == false, !model.activity.isBusy,
           model.photosInFlight == 0 {
            let backZooms = lenses
                .filter { !$0.isFront && $0.kind != .external }
                .map { positive($0.relativeZoom, or: 1) }
            if let widest = backZooms.min(), let longest = backZooms.max() {
                lower = min(lower, widest * low)
                upper = max(upper, longest * high)
            }
        }
        return lower...max(upper, lower)
    }

    private static func crossesPreset(from a: Double, to b: Double, model: CameraModel) -> Bool {
        let lenses = lensTable(model)
        // The lens buttons belong to the back cameras; the selfie camera's zoom has no stops to feel.
        let activeID = model.backend.activeLensID ?? model.settings.lensID
        guard let active = activeID.flatMap({ lenses[$0] }), !active.isFront, active.kind != .external else { return false }
        let low = min(a, b)
        let high = max(a, b)
        return model.lensPresets.contains { preset in
            isBack(preset, lenses) && preset.displayZoom > low && preset.displayZoom <= high
        }
    }

    // MARK: Exposure

    func exposureDragBegan(model: CameraModel) {
        lingerTask?.cancel()
        lingerTask = nil
        dragStartBias = Self.currentBias(model)
        dragLastBias = dragStartBias
        dragAtLimit = false
        // "Up" stays fixed for the whole drag; turning the phone halfway would otherwise reread the travel so far
        // along the other axis and throw the value back to where the drag began.
        dragQuarterTurns = model.motion.quarterTurns
        // Beside the focus square when one is up, as in the Camera app; a faded square's old spot means nothing.
        sliderAnchor = visibleFocusPoint(model) ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        isDraggingExposure = true
    }

    func exposureDragChanged(translation: CGPoint, model: CameraModel) {
        // A capture that starts mid-drag keeps the exposure it started with.
        guard isDraggingExposure, canAdjust(model) else { return }
        let travel = Self.userVector(translation, quarterTurns: dragQuarterTurns)
        let delta = -Double(travel.y / Self.pointsPerEV)
        guard delta.isFinite else { return }
        // Tenths match the readout. Stepping the change rather than the value keeps a third-stop setting
        // from the dial where it is until the finger really moves.
        let stepped = dragStartBias + (delta * 10).rounded() / 10
        let range = Self.biasRange(model)
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        let atLimit = clamped != stepped
        if atLimit && !dragAtLimit { Haptics.stop() }
        dragAtLimit = atLimit
        let bias = abs(clamped) < 0.05 ? 0 : clamped
        guard bias != dragLastBias else { return }
        if Self.reachesWholeStop(from: dragLastBias, to: bias) {
            Haptics.tick()
        }
        dragLastBias = bias
        model.setBias(bias)
    }

    func exposureDragEnded() {
        guard isDraggingExposure else { return }
        isDraggingExposure = false
        lingerTask?.cancel()
        // The slider stays for a moment so the new value can be read, like the Camera app's sun.
        lingerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, !self.isDraggingExposure else { return }
            self.sliderAnchor = nil
        }
    }

    /// VoiceOver's swipe up and down: a third of a stop, the dial's step.
    func nudgeBias(by step: Double, model: CameraModel) {
        guard canAdjust(model) else { return }
        let range = Self.biasRange(model)
        let next = EVFormat.snap(Self.currentBias(model) + step, step: .third)
        model.setBias(min(max(next, range.lowerBound), range.upperBound))
    }

    /// Night mode keeps its own compensation; every other mode uses the manual one.
    static func currentBias(_ model: CameraModel) -> Double {
        model.settings.mode == .night ? model.settings.night.biasEV : model.settings.manual.bias
    }

    private static func biasRange(_ model: CameraModel) -> ClosedRange<Double> {
        let range = model.capabilities.biasRange
        let low = range.lowerBound.isFinite ? range.lowerBound : -2
        let high = range.upperBound.isFinite ? range.upperBound : 2
        return min(low, high)...max(low, high)
    }

    /// True when the value lands on or passes a whole stop, but not when it only leaves one.
    private static func reachesWholeStop(from old: Double, to new: Double) -> Bool {
        let first = min(old, new).rounded(.up)
        let last = max(old, new).rounded(.down)
        guard first <= last else { return false }
        return !(first == last && first == old)
    }

    // MARK: Orientation

    /// A screen-space vector in the frame of a user holding the phone `quarterTurns` turns counterclockwise,
    /// so "up" on the slider is up for them in landscape too.
    static func userVector(_ vector: CGPoint, quarterTurns: Int) -> CGPoint {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGPoint(x: vector.y, y: -vector.x)
        case 2: return CGPoint(x: -vector.x, y: -vector.y)
        case 3: return CGPoint(x: -vector.y, y: vector.x)
        default: return vector
        }
    }

    /// Inverse of `userVector`.
    static func screenVector(_ vector: CGPoint, quarterTurns: Int) -> CGPoint {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGPoint(x: -vector.y, y: vector.x)
        case 2: return CGPoint(x: -vector.x, y: -vector.y)
        case 3: return CGPoint(x: vector.y, y: -vector.x)
        default: return vector
        }
    }

    // MARK: Helpers

    private static func lensTable(_ model: CameraModel) -> [String: LensInfo] {
        Dictionary(model.lenses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func isBack(_ preset: LensPreset, _ lenses: [String: LensInfo]) -> Bool {
        guard let lens = lenses[preset.lensID] else { return false }
        return !lens.isFront && lens.kind != .external
    }

    private static func isOneX(_ preset: LensPreset, _ lenses: [String: LensInfo]) -> Bool {
        guard lenses[preset.lensID]?.kind == .wide else { return false }
        return abs(preset.zoomFactor - 1) < 0.01
    }

    private static func positive(_ value: Double, or fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Preview layer host

/// Hosts the backend's preview layer and the gesture recognizers. UIKit recognizers report points in the
/// layer's own coordinates, which is exactly what tap to focus needs, and give the long press a location.
private struct PreviewSurface: UIViewRepresentable {
    let model: CameraModel
    let interaction: ViewfinderInteraction

    func makeCoordinator() -> GestureCoordinator {
        GestureCoordinator(model: model, interaction: interaction)
    }

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        // Pinch needs both fingers delivered to this view.
        view.isMultipleTouchEnabled = true
        view.clipsToBounds = true
        view.attach(model.backend.makePreviewLayer())
        let interaction = self.interaction
        view.onLayout = { [weak interaction] size in
            interaction?.viewSize = size
        }
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        context.coordinator.model = model
        uiView.reattachIfNeeded()
    }
}

private final class PreviewHostView: UIView {
    var onLayout: ((CGSize) -> Void)?
    private var previewLayer: CALayer?

    func attach(_ layer: CALayer) {
        previewLayer = layer
        reattachIfNeeded()
    }

    /// The backend hands out one shared layer. If SwiftUI briefly builds a second host during a transition,
    /// that host takes the layer; this one takes it back when it is the one on screen.
    func reattachIfNeeded() {
        guard let previewLayer, previewLayer.superlayer !== layer else { return }
        layer.insertSublayer(previewLayer, at: 0)
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            reattachIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reattachIfNeeded()
        // A standalone layer animates frame changes by default and would trail the view by a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        CATransaction.commit()
        onLayout?(bounds.size)
    }
}

@MainActor
private final class GestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    var model: CameraModel
    let interaction: ViewfinderInteraction
    private weak var exposurePan: UIPanGestureRecognizer?

    init(model: CameraModel, interaction: ViewfinderInteraction) {
        self.model = model
        self.interaction = interaction
        super.init()
    }

    func install(on view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 12
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        exposurePan = pan
        for recognizer in [tap, longPress, pinch, pan] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        interaction.tap(at: recognizer.location(in: view), model: model)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let view = recognizer.view else { return }
        interaction.longPress(at: recognizer.location(in: view), model: model)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            interaction.pinchBegan(model: model)
            interaction.pinchChanged(scale: recognizer.scale, model: model)
        case .changed:
            interaction.pinchChanged(scale: recognizer.scale, model: model)
        case .ended, .cancelled, .failed:
            interaction.pinchEnded()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        switch recognizer.state {
        case .began:
            // The pan only begins after some travel; starting from zero keeps the value from jumping.
            recognizer.setTranslation(.zero, in: view)
            interaction.exposureDragBegan(model: model)
        case .changed:
            interaction.exposureDragChanged(translation: recognizer.translation(in: view), model: model)
        case .ended, .cancelled, .failed:
            interaction.exposureDragEnded()
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = exposurePan, gestureRecognizer === pan, let view = pan.view else { return true }
        let velocity = ViewfinderInteraction.userVector(pan.velocity(in: view), quarterTurns: model.motion.quarterTurns)
        // Only a mostly vertical drag is the exposure slider; sideways swipes stay free for other gestures.
        return abs(velocity.y) > abs(velocity.x) * 1.2 && interaction.canAdjust(model)
    }
}

// MARK: - Analysis overlay

/// Peaking, zebras and false color over the live image. Only this small view reads `model.analysis`,
/// so the twelve updates a second never re-render the rest of the viewfinder.
private struct AnalysisOverlay: View {
    let model: CameraModel

    var body: some View {
        OverlaySurface(image: showsOverlay ? model.analysis?.overlay : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The analyzer stops producing frames once every analysis is off, which would leave the last overlay
    /// frozen on screen; the settings decide whether one belongs here at all.
    private var showsOverlay: Bool {
        guard model.sessionState == .running else { return false }
        let display = model.settings.display
        let manualFocus = model.settings.focus.lensPosition != nil || model.activeDial == .focus
        let peaking = display.peaking == .always || (display.peaking == .manualFocus && manualFocus)
        return display.zebras || display.falseColor || peaking
    }
}

private struct OverlaySurface: UIViewRepresentable {
    let image: CGImage?

    func makeUIView(context: Context) -> OverlayHostView {
        let view = OverlayHostView()
        view.configure()
        view.show(image)
        return view
    }

    func updateUIView(_ uiView: OverlayHostView, context: Context) {
        uiView.show(image)
    }
}

/// Core Animation scales the overlay to the preview, so a new one costs a texture upload and no layout.
private final class OverlayHostView: UIView {
    private let overlayLayer = CALayer()
    private var shownImage: CGImage?

    func configure() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        // The analyzer draws at 480 px on the long side; linear filtering keeps the upscale soft, not blocky.
        overlayLayer.contentsGravity = .resizeAspect
        overlayLayer.magnificationFilter = .linear
        overlayLayer.minificationFilter = .linear
        overlayLayer.opacity = 0.9
        layer.addSublayer(overlayLayer)
    }

    func show(_ image: CGImage?) {
        guard image !== shownImage else { return }
        shownImage = image
        CATransaction.begin()
        // New overlays arrive about twelve times a second; the default crossfade would smear them.
        CATransaction.setDisableActions(true)
        overlayLayer.contents = image
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Exposure slider

/// The Camera app's sun: it sits beside the focus square and slides along a short track while the
/// exposure is dragged.
private struct ExposureSlider: View {
    let model: CameraModel
    let interaction: ViewfinderInteraction

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let anchor = visibleAnchor {
                    let turns = model.motion.quarterTurns
                    SunSliderGraphic(
                        bias: ViewfinderInteraction.currentBias(model),
                        showsTrack: interaction.isDraggingExposure,
                        showsValue: interaction.sliderAnchor != nil,
                        side: Self.side(for: anchor, quarterTurns: turns, in: proxy.size)
                    )
                    .rotationEffect(.degrees(Self.degrees(quarterTurns: turns)))
                    .position(anchor)
                    .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeOut(duration: 0.2), value: visibleAnchor == nil)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: model.focusPoint, initial: true) { _, point in
            interaction.focusPointChanged(to: point, model: model)
        }
        .onChange(of: model.aeLocked) { _, locked in
            interaction.aeLockChanged(locked)
        }
        .onChange(of: ViewfinderInteraction.currentBias(model)) {
            interaction.biasChanged(model: model)
        }
        .task(id: interaction.freshGeneration) {
            // Matches the focus square, which fades two seconds after a tap or the last exposure change.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            interaction.freshnessExpired()
        }
        // A zoom or lens change moves the picture under the focus point, so the sun no longer belongs there.
        .onChange(of: model.settings.zoom) {
            interaction.focusPointMoved()
        }
        .onChange(of: model.activePresetID) {
            interaction.focusPointMoved()
        }
    }

    /// The drag's anchor, or the focus point while its square is on screen.
    private var visibleAnchor: CGPoint? {
        interaction.sliderAnchor ?? interaction.visibleFocusPoint(model)
    }

    /// 1 puts the sun on the user's right of the focus square, -1 on the left when the right side is off screen.
    private static func side(for anchor: CGPoint, quarterTurns: Int, in size: CGSize) -> CGFloat {
        let reach = SunSliderGraphic.sunDistance + 14
        let offset = ViewfinderInteraction.screenVector(CGPoint(x: reach, y: 0), quarterTurns: quarterTurns)
        let sun = CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y)
        let margin: CGFloat = 8
        let fits = sun.x >= margin && sun.x <= size.width - margin && sun.y >= margin && sun.y <= size.height - margin
        return fits ? 1 : -1
    }

    private static func degrees(quarterTurns: Int) -> Double {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return 90
        case 2: return 180
        case 3: return -90
        default: return 0
        }
    }
}

private struct SunSliderGraphic: View {
    let bias: Double
    let showsTrack: Bool
    let showsValue: Bool
    /// 1 = right of the focus square, -1 = left, in the user's frame.
    let side: CGFloat

    /// Half the focus square drawn by ViewfinderOverlays (72 pt) plus a gap.
    static let sunDistance: CGFloat = 36 + 18
    private static let trackHalf: CGFloat = 80
    private static let trackGap: CGFloat = 14

    var body: some View {
        let x = side * Self.sunDistance
        let y = -min(max(CGFloat(bias) * ViewfinderInteraction.pointsPerEV, -Self.trackHalf), Self.trackHalf)
        let upper = max(0, y - Self.trackGap + Self.trackHalf)
        let lower = max(0, Self.trackHalf - y - Self.trackGap)
        ZStack {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1, height: upper)
                .offset(x: x, y: -Self.trackHalf + upper / 2)
                .opacity(showsTrack ? 1 : 0)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1, height: lower)
                .offset(x: x, y: Self.trackHalf - lower / 2)
                .opacity(showsTrack ? 1 : 0)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .offset(x: x, y: y)
            Text(EVFormat.label(bias))
                .font(Theme.readoutFont)
                .foregroundStyle(Theme.accent)
                .fixedSize()
                .offset(x: x + side * 30, y: y)
                .opacity(showsValue ? 1 : 0)
        }
        .frame(width: 2 * (Self.sunDistance + 60), height: 2 * Self.trackHalf + 32)
        .shadow(color: .black.opacity(0.4), radius: 1.5)
        .animation(Theme.snappy, value: bias)
        .animation(.easeOut(duration: 0.2), value: showsTrack)
        .animation(.easeOut(duration: 0.2), value: showsValue)
    }
}
