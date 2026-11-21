import SwiftUI
import UIKit
import QuartzCore
import AVFoundation
import Observation
import CameraCore

/// The live picture: the backend's preview layer and the analysis overlay, both laid out at the picture rect of the
/// full-screen viewfinder, plus the viewfinder's gestures. The host view covers the whole screen, so a pinch or a
/// swipe works on the bands too. The sun that goes with the focus square is ExposureSliderLayer, drawn above the
/// bands and the capture blink, and VoiceOver's viewfinder element is ViewfinderAccessibilityTarget.
struct CameraPreviewView: View {
    let model: CameraModel
    let interaction: ViewfinderInteraction
    let geometry: ViewfinderGeometry
    /// The battery saver's black layer covers the screen, so the picture under it stops drawing.
    let isHidden: Bool
    /// A lens swap is running: the last frame stays up until the new camera's frames arrive.
    var isFrozen = false
    /// A change of mode is under way: a still of the last frame blurs over the picture, then fades into the new one.
    var isVeiled = false

    var body: some View {
        ZStack {
            PreviewSurface(model: model, interaction: interaction, picture: geometry.picture, isHidden: isHidden,
                           isFrozen: isFrozen, isVeiled: isVeiled)
            AnalysisOverlay(model: model, picture: geometry.picture, isHidden: isHidden)
        }
        .background(Theme.background)
        .accessibilityHidden(true)
        .onChange(of: geometry, initial: true) { _, geometry in
            interaction.geometry = geometry
        }
        .onChange(of: model.activePresetID, initial: true) { _, id in
            interaction.noteActivePreset(id, model: model)
        }
    }
}

/// VoiceOver's viewfinder: one adjustable element over the open part of the frame. The picture's host covers the
/// whole screen, bands and all, which would put the element first in reading order and outline the whole screen.
struct ViewfinderAccessibilityTarget: View {
    let model: CameraModel
    let interaction: ViewfinderInteraction
    /// Where the element sits, in the screen space the viewfinder is laid out in.
    let rect: CGRect

    var body: some View {
        Color.clear
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .modifier(ViewfinderAccessibility(model: model, interaction: interaction))
            .position(x: rect.midX, y: rect.midY)
            // Touches go to the picture's gesture recognizers underneath.
            .allowsHitTesting(false)
            // The quick settings panel covers the top of the picture and a touch beside it only closes the panel,
            // so VoiceOver keeps to the panel too; its escape closes it. The Camera Control's overlay hides the
            // panel without closing it, and the viewfinder is back while it shows.
            .accessibilityHidden(model.isDrawerOpen && !model.controlsFullscreen)
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

/// State shared by the UIKit gesture recognizers, the SwiftUI exposure slider and the camera screen. Points named
/// "layer" are in the preview layer's own coordinates, the ones the model and the backends use; every other point is
/// in the screen space of the full-screen viewfinder.
@MainActor
@Observable
final class ViewfinderInteraction {
    /// Where the exposure slider sits during a drag and for a moment after it, on screen; nil otherwise.
    private(set) var sliderAnchor: CGPoint?
    private(set) var isDraggingExposure = false
    /// The preview layer shows frames from the camera. Until it does, and after it stops, the bands stay solid.
    private(set) var isPreviewing = false

    // ViewfinderOverlays draws the focus square and keeps the same books from the same model state, so the sun
    // comes and goes with the square.
    /// The focus point the flags below describe. A model.focusPoint that differs is a tap the change handlers
    /// haven't caught up with yet.
    private(set) var trackedFocusPoint: CGPoint?
    /// False once a zoom or lens change has moved the picture under the tracked point.
    private(set) var focusPointIsCurrent = false
    /// The square is bright: tapped, or exposure changed beside it, within the last two seconds.
    private(set) var reticleIsFresh = false
    /// The long press that placed the tracked point also locked the focus, the exposure or both, so the square
    /// stays while that lasts.
    private(set) var lockIsAtFocusPoint = false
    /// Bumped to restart the two-second fade.
    private(set) var freshGeneration = 0

    /// The viewfinder's rectangles, for telling a tap on the photo from one on a band and for actions aimed at the
    /// middle of the frame.
    @ObservationIgnored var geometry: ViewfinderGeometry = .zero

    @ObservationIgnored private var alternatePresetID: String?
    @ObservationIgnored private var lastTap: (time: CFTimeInterval, point: CGPoint)?
    @ObservationIgnored private var pinchBase = 1.0
    @ObservationIgnored private var pinchLastSent = 1.0
    @ObservationIgnored private var pinchAtLimit = false
    /// The pinch sent the model a zoom, so its end owes the model the final, strict one.
    @ObservationIgnored private var pinchSentZoom = false
    @ObservationIgnored private var dragStartBias = 0.0
    @ObservationIgnored private var dragLastBias = 0.0
    @ObservationIgnored private var dragAtLimit = false
    @ObservationIgnored private var dragQuarterTurns = 0
    @ObservationIgnored private var lingerTask: Task<Void, Never>?

    /// Vertical travel per EV: about two finger widths a stop, so a small slip moves the exposure a little. The sun
    /// moves the same distance, so it stays under the finger.
    static let pointsPerEV: CGFloat = 80
    private static let doubleTapInterval: CFTimeInterval = 0.3
    private static let doubleTapSlop = 40.0
    /// A tap this close outside the frame still counts as one on its edge.
    private static let frameSlop: CGFloat = 8

    // MARK: Focus

    /// - Parameters:
    ///   - point: Where the finger landed on screen.
    ///   - layerPoint: The same place in the preview layer's coordinates, for the model.
    func tap(at point: CGPoint, layerPoint: CGPoint, model: CameraModel) {
        // While the focus magnifier enlarges the middle of the frame, a tap only brings the whole frame back: a point
        // on the enlarged picture is not where the frame has it.
        guard !model.isMagnified else {
            lastTap = nil
            model.setMagnified(false)
            return
        }
        let now = CACurrentMediaTime()
        if let last = lastTap, now - last.time <= Self.doubleTapInterval,
           Self.distance(last.point, point) <= Self.doubleTapSlop {
            // Focusing on the first tap keeps single taps instant; the second tap of a pair switches zoom.
            lastTap = nil
            toggleZoom(model: model)
            return
        }
        lastTap = (now, point)
        // A band shows what the photo leaves out, so a tap there focuses nothing. It can still start a double tap.
        guard canAdjust(model), isOnFrame(point) else { return }
        model.tapToFocus(at: layerPoint, lock: false)
    }

    func longPress(at point: CGPoint, layerPoint: CGPoint, model: CameraModel) {
        lastTap = nil
        // A lock while magnified would meter and focus on the enlarged middle, which the exposure holds against.
        guard canAdjust(model), isOnFrame(point), !model.isMagnified else { return }
        model.tapToFocus(at: layerPoint, lock: true)
    }

    func focusCenter(lock: Bool, model: CameraModel) {
        // VoiceOver's double tap is the tap on the picture: while magnified it brings the whole frame back.
        guard !model.isMagnified else {
            model.setMagnified(false)
            return
        }
        let frame = geometry.frame
        guard canAdjust(model), frame.width > 0, frame.height > 0 else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        model.tapToFocus(at: layerPoint(fromScreen: center), lock: lock)
    }

    /// Where a screen point lands in the preview layer, which sits at the picture rect. The host converts with the
    /// layer itself; this is the same sum for the points the SwiftUI side makes.
    func layerPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - geometry.picture.minX, y: point.y - geometry.picture.minY)
    }

    private func screenPoint(fromLayer point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + geometry.picture.minX, y: point.y + geometry.picture.minY)
    }

    private func isOnFrame(_ point: CGPoint) -> Bool {
        let frame = geometry.frame
        // Before the first layout there is no frame to tell a band by.
        guard frame.width > 0, frame.height > 0 else { return true }
        return frame.insetBy(dx: -Self.frameSlop, dy: -Self.frameSlop).contains(point)
    }

    /// The host reports when the preview layer starts or stops showing frames.
    func previewingChanged(_ previewing: Bool) {
        if isPreviewing != previewing {
            isPreviewing = previewing
        }
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
        lockIsAtFocusPoint = point != nil && Self.isLocked(model)
        freshGeneration &+= 1
    }

    /// The model keeps the point of a released lock. Locking again later (the AE-L chip) isn't tied to that old
    /// square, so it must not bring the square and the sun back.
    func lockChanged(_ locked: Bool) {
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

    /// Where the focus square is, in the preview layer's coordinates, if it is up.
    func visibleFocusPoint(_ model: CameraModel) -> CGPoint? {
        guard let point = model.focusPoint else { return nil }
        // A point the handlers haven't seen yet was tapped a moment ago, so its square has just appeared.
        guard point == trackedFocusPoint else { return point }
        guard focusPointIsCurrent, reticleIsFresh || holdsLock(model) else { return nil }
        return point
    }

    /// A tap clears the lock and a long press sets it, so a point that arrived locked came from a long press.
    private func holdsLock(_ model: CameraModel) -> Bool {
        Self.isLocked(model) && lockIsAtFocusPoint
    }

    /// Either half of a lock keeps the square, by the rule ViewfinderOverlays draws it with: in a scene that fixes
    /// the ISO a long press holds the focus alone.
    static func isLocked(_ model: CameraModel) -> Bool {
        model.aeLocked || model.focusLocked
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
        // The zoom asked for last, not the 10 Hz reading, which trails a zoom that is still on its way.
        let requested = model.requestedZoom
        let live = model.readings.displayZoom
        pinchBase = requested.isFinite && requested > 0 ? requested : (live.isFinite && live > 0 ? live : 1)
        pinchLastSent = pinchBase
        pinchAtLimit = false
        pinchSentZoom = false
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
            // The zoom wheel's tap at a lens value. The dial ticks switch is about dials and leaves zoom stops alone.
            Haptics.zoomTick(atLensValue: true)
        }
        pinchLastSent = target
        pinchSentZoom = true
        // While the fingers move, the lens in use keeps a zoom just past the next lens's own value, so a pinch that
        // rests on a lens boundary doesn't swap cameras back and forth.
        model.setDisplayZoom(target, animated: false, continuing: true)
    }

    func pinchEnded(model: CameraModel) {
        pinchAtLimit = false
        guard pinchSentZoom else { return }
        pinchSentZoom = false
        // A capture that began under the fingers keeps its zoom.
        guard canAdjust(model) else { return }
        // The fingers are off: the last value again, with the strict lens choice, so the zoom ends on the lens that
        // owns it.
        model.setDisplayZoom(pinchLastSent, animated: false)
    }

    /// Display zoom the pinch may reach: the span the zoom wheel and the zoom dial offer too.
    private static func displayZoomRange(_ model: CameraModel) -> ClosedRange<Double> {
        let span = model.zoomSpan
        let lower = positive(span.lowerBound, or: 1)
        let upper = positive(span.upperBound, or: lower)
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
        // The exposure holds while the focus magnifier is on (the gesture coordinator doesn't start the drag then);
        // this covers a drag that a turn of the focus dial overtakes.
        guard !model.isMagnified else { return }
        lingerTask?.cancel()
        lingerTask = nil
        dragStartBias = Self.currentBias(model)
        dragLastBias = dragStartBias
        dragAtLimit = false
        // "Up" stays fixed for the whole drag; turning the phone halfway would otherwise reread the travel so far
        // along the other axis and throw the value back to where the drag began.
        dragQuarterTurns = model.motion.quarterTurns
        // Beside the focus square when one is up and in sight, as in the Camera app; a faded square's old spot means
        // nothing, and one under the controls can't be seen. Otherwise in the middle of the frame, held inside the
        // part of it the controls leave open: a tall dial can reach over the frame's middle.
        let open = geometry.open
        let square = visibleFocusPoint(model).map(screenPoint(fromLayer:)).flatMap { open.contains($0) ? $0 : nil }
        sliderAnchor = square ?? Self.middle(of: geometry.frame, inside: open)
        isDraggingExposure = true
    }

    func exposureDragChanged(translation: CGPoint, model: CameraModel) {
        // A capture that starts mid-drag keeps the exposure it started with, and so does the focus magnifier.
        guard isDraggingExposure, canAdjust(model), !model.isMagnified else { return }
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
        // As the drag on the picture: the exposure holds while the focus magnifier is on.
        guard canAdjust(model), !model.isMagnified else { return }
        let range = Self.biasRange(model)
        let next = EVFormat.snap(Self.currentBias(model) + step, step: .third)
        model.setBias(min(max(next, range.lowerBound), range.upperBound))
    }

    /// The frame's middle, moved in from the edges of `open` where the open part doesn't reach it.
    private static func middle(of frame: CGRect, inside open: CGRect) -> CGPoint {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        let area = open.insetBy(dx: 24, dy: 24)
        guard area.width > 0, area.height > 0 else { return middle }
        return CGPoint(x: min(max(middle.x, area.minX), area.maxX), y: min(max(middle.y, area.minY), area.maxY))
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

/// Hosts the backend's preview layer and the gesture recognizers. The host covers the whole screen and the layer sits
/// at the picture rect inside it; tap to focus hands the model points in the layer's own coordinates, which is what
/// both backends convert from.
private struct PreviewSurface: UIViewRepresentable {
    let model: CameraModel
    let interaction: ViewfinderInteraction
    /// Where the whole camera image goes, in the host's coordinates.
    let picture: CGRect
    let isHidden: Bool
    let isFrozen: Bool
    let isVeiled: Bool

    func makeCoordinator() -> GestureCoordinator {
        GestureCoordinator(model: model, interaction: interaction)
    }

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        // Pinch needs both fingers delivered to this view.
        view.isMultipleTouchEnabled = true
        // At 16:9 the picture reaches past the screen's sides.
        view.clipsToBounds = true
        let interaction = self.interaction
        view.onPreviewingChange = { [weak interaction, weak view] previewing in
            interaction?.previewingChanged(previewing)
            if previewing { view?.openShutterOnce() }
        }
        view.attach(model.backend.makePreviewLayer())
        view.setPictureRect(picture, animated: false)
        view.isHidden = isHidden
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        context.coordinator.model = model
        uiView.reattachIfNeeded()
        uiView.setPictureRect(picture, animated: PictureLayerMotion.animates(in: context.environment))
        // Under the battery saver's black layer the picture would still be drawn 30 times a second. The session and
        // the shot keep running: frames reach the stack through the video output, not this layer.
        if uiView.isHidden != isHidden {
            uiView.isHidden = isHidden
        }
        uiView.setFrozen(isFrozen)
        uiView.setVeiled(isVeiled && !isHidden)
    }
}

private final class PreviewHostView: UIView {
    /// Called on the main queue with the preview layer's isPreviewing.
    var onPreviewingChange: ((Bool) -> Void)?
    private var previewLayer: CALayer?
    private var previewing: NSKeyValueObservation?
    /// Where the layer goes, in this view's coordinates; null until the camera screen has laid out.
    private var pictureRect = CGRect.null
    /// The last frame before a lens swap. Changing the camera input blanks the preview layer until the new camera
    /// delivers, which showed as a black flash; Apple's Camera holds the old picture and fades to the new one.
    private var frozenFrame: UIView?

    func setFrozen(_ frozen: Bool) {
        if frozen {
            guard frozenFrame == nil, window != nil,
                  let snapshot = snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = bounds
            snapshot.isUserInteractionEnabled = false
            addSubview(snapshot)
            frozenFrame = snapshot
        } else if let snapshot = frozenFrame {
            frozenFrame = nil
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }
    }

    // MARK: Mode switch veil

    /// The still under the blur while a mode changes, and the blur's ramp.
    private var veil: ModeVeilView?

    /// Covers the picture with a still of the last frame that blurs in, and fades it into the live picture when the
    /// change is over. The still is a snapshot, so the blur never runs over the live layer, and the new mode's
    /// first frames, often a jump of exposure or shape, arrive under it.
    func setVeiled(_ veiled: Bool) {
        if veiled {
            guard veil == nil, window != nil, previewLayer != nil,
                  let snapshot = snapshotView(afterScreenUpdates: false) else { return }
            let cover = ModeVeilView(snapshot: snapshot, frame: bounds)
            addSubview(cover)
            veil = cover
            cover.blurIn()
        } else if let cover = veil {
            veil = nil
            cover.fadeAway()
        }
    }

    // MARK: Launch

    /// The picture has opened once since launch: later sessions (a return from the background, a reconfiguration)
    /// come back without the flourish.
    private static var hasOpened = false

    /// The first live frame since launch opens out from a circle in the middle of the picture, like a shutter's
    /// blades parting. Only drawn: the camera is ready and takes touches from the first frame, whether this runs or
    /// not. With Reduce Motion the picture fades in.
    func openShutterOnce() {
        guard !Self.hasOpened, let previewLayer, window != nil, !isHidden else { return }
        Self.hasOpened = true
        let reduceMotion = UIAccessibility.isReduceMotionEnabled || AppearanceStore.shared.reduceMotion
        let duration: CFTimeInterval = 0.3
        let curve = CAMediaTimingFunction(name: .easeOut)
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration
            fade.timingFunction = curve
            previewLayer.add(fade, forKey: "launchFade")
            return
        }
        let bounds = previewLayer.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Far enough to clear the corners, so the last frame of the opening is the whole picture.
        let full = hypot(bounds.width, bounds.height) / 2
        let start = min(bounds.width, bounds.height) * 0.04
        func circle(_ radius: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                   transform: nil)
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = circle(full)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.mask = mask
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak previewLayer, weak mask] in
            // Left on, a mask would make every frame of the picture pass through it.
            if let previewLayer, previewLayer.mask === mask { previewLayer.mask = nil }
        }
        let open = CABasicAnimation(keyPath: "path")
        open.fromValue = circle(start)
        open.toValue = circle(full)
        open.duration = duration
        open.timingFunction = curve
        mask.add(open, forKey: "open")
        CATransaction.commit()
    }

    func attach(_ layer: CALayer) {
        previewLayer = layer
        if let video = layer as? AVCaptureVideoPreviewLayer {
            // AVFoundation says to watch this to learn when video reaches the layer (iOS 13).
            previewing = video.observe(\.isPreviewing, options: [.initial, .new]) { [weak self] layer, _ in
                let isPreviewing = layer.isPreviewing
                DispatchQueue.main.async { self?.onPreviewingChange?(isPreviewing) }
            }
        } else {
            // The simulated camera draws into a plain layer, which shows frames as soon as its session runs.
            DispatchQueue.main.async { [weak self] in self?.onPreviewingChange?(true) }
        }
        reattachIfNeeded()
    }

    /// The backend hands out one shared layer. If SwiftUI briefly builds a second host during a transition,
    /// that host takes the layer; this one takes it back when it is the one on screen.
    func reattachIfNeeded() {
        guard let previewLayer, previewLayer.superlayer !== layer else { return }
        layer.insertSublayer(previewLayer, at: 0)
        setNeedsLayout()
    }

    /// Moves the layer to `rect`, springing it there from where it shows now when asked and when there is a
    /// "there" to start from.
    func setPictureRect(_ rect: CGRect, animated: Bool) {
        guard PictureLayerMotion.isUsable(rect), rect != pictureRect else { return }
        let hadRect = !pictureRect.isNull
        pictureRect = rect
        guard let previewLayer else { return }
        PictureLayerMotion.move(previewLayer, to: rect, animated: animated && hadRect && window != nil)
    }

    /// A touch in this view's coordinates, in the preview layer's own, which the backends convert from.
    func layerPoint(fromHostPoint point: CGPoint) -> CGPoint {
        guard let previewLayer, previewLayer.superlayer === layer else { return point }
        return previewLayer.convert(point, from: layer)
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
        guard let previewLayer else { return }
        let target = pictureRect.isNull ? bounds : pictureRect
        guard previewLayer.frame != target else { return }
        // A standalone layer animates frame changes by default and would trail the view by a quarter second.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = target
        CATransaction.commit()
    }
}

/// A still of the picture under a blur that ramps from none to a soft focus, for a change of mode. The system's
/// blur only has its full strength, which smears the picture past recognising; a paused animator held part of the
/// way gives a radius near 18 pt, and a short display link walks it there. The link runs only for the ramp, a
/// quarter of a second per switch.
@MainActor
private final class ModeVeilView: UIView {
    private let blur = UIVisualEffectView(effect: nil)
    private let shade = UIView()
    private var animator: UIViewPropertyAnimator?
    private var link: CADisplayLink?
    private var rampStart: CFTimeInterval = 0

    /// How far along the system blur's strength the ramp stops.
    private static let strength: CGFloat = 0.6
    private static let rampDuration: CFTimeInterval = 0.25

    // UIKit asserts when a paused animator is released, and a display link holds its target: both are let go as
    // soon as the veil leaves the screen, however it leaves.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        link?.invalidate()
        link = nil
        animator?.stopAnimation(true)
        animator = nil
    }

    init(snapshot: UIView, frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.frame = bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(snapshot)
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled || AppearanceStore.shared.reduceTransparency
        if !reduceTransparency {
            blur.frame = bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(blur)
        }
        // A little darker, as the old veil was, so the still reads as waiting rather than as the picture. Without
        // the blur, darker still: the still alone looks like a frozen camera.
        shade.frame = bounds
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shade.backgroundColor = UIColor.black.withAlphaComponent(reduceTransparency ? 0.45 : 0.2)
        shade.alpha = 0
        addSubview(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func blurIn() {
        UIView.animate(withDuration: Self.rampDuration, delay: 0, options: [.curveEaseOut]) {
            self.shade.alpha = 1
        }
        guard blur.superview != nil else { return }
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [blur] in
            blur.effect = UIBlurEffect(style: .dark)
        }
        animator.pausesOnCompletion = true
        animator.pauseAnimation()
        self.animator = animator
        rampStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        let t = min((CACurrentMediaTime() - rampStart) / Self.rampDuration, 1)
        // Ease out, as the shade's fade does.
        let eased = 1 - (1 - t) * (1 - t)
        animator?.fractionComplete = Self.strength * CGFloat(eased)
        if t >= 1 { stopLink() }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// Cross-fades into the live picture, then lets go of the animator, which UIKit requires to be stopped first.
    func fadeAway() {
        stopLink()
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.alpha = 0
        } completion: { _ in
            self.animator?.stopAnimation(true)
            self.animator = nil
            self.removeFromSuperview()
        }
    }
}

/// Moves the picture's layers (the preview and the analysis overlay) to a new rect. An aspect change springs them
/// there on the curve the bands and the grid use (Theme.spring: response 0.32, damping 0.86), so the picture and its
/// frame move as one.
@MainActor
private enum PictureLayerMotion {
    private static let animationKey = "pictureRect"

    /// A spring up to 4/3 times the size is a zoom, which Reduce motion, in the app or in iOS, asks to leave out. The
    /// picture then cuts to its new size, and the camera screen covers the cut with its veil.
    static func animates(in environment: EnvironmentValues) -> Bool {
        !(environment.accessibilityReduceMotion || AppearanceStore.shared.reduceMotion)
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    static func move(_ layer: CALayer, to rect: CGRect, animated: Bool) {
        // Where it shows now, a spring still running included.
        let from = layer.presentation()?.frame ?? layer.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect
        CATransaction.commit()
        guard animated, isUsable(from), from != rect else {
            layer.removeAnimation(forKey: animationKey)
            return
        }
        // The final frame is set already; the transform makes it start out where it was and settles to none.
        let scale = from.width / rect.width
        let start = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                        CATransform3DMakeTranslation(from.midX - rect.midX, from.midY - rect.midY, 0))
        let spring = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.14)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: animationKey)
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
        guard recognizer.state == .ended, let view = recognizer.view as? PreviewHostView else { return }
        let point = recognizer.location(in: view)
        interaction.tap(at: point, layerPoint: view.layerPoint(fromHostPoint: point), model: model)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let view = recognizer.view as? PreviewHostView else { return }
        let point = recognizer.location(in: view)
        interaction.longPress(at: point, layerPoint: view.layerPoint(fromHostPoint: point), model: model)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            interaction.pinchBegan(model: model)
            interaction.pinchChanged(scale: recognizer.scale, model: model)
        case .changed:
            interaction.pinchChanged(scale: recognizer.scale, model: model)
        case .ended, .cancelled, .failed:
            interaction.pinchEnded(model: model)
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
        // Only a mostly vertical drag is the exposure slider; sideways swipes stay free for other gestures. The
        // exposure holds while the focus magnifier is on, so no drag starts then.
        return abs(velocity.y) > abs(velocity.x) * 1.2 && interaction.canAdjust(model) && !model.isMagnified
    }
}

// MARK: - Analysis overlay

/// Peaking, zebras and false color over the live image. Only this small view reads `model.analysis`,
/// so the twelve updates a second never re-render the rest of the viewfinder.
private struct AnalysisOverlay: View {
    let model: CameraModel
    /// The analyzer draws the whole camera image, so its layer sits where the preview's does.
    let picture: CGRect
    /// Under the battery saver's black layer. The analysis isn't read then, so its updates don't upload overlays
    /// nobody sees.
    let isHidden: Bool

    var body: some View {
        OverlaySurface(image: showsOverlay && !isHidden ? model.analysis?.overlay : nil, picture: picture)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The analyzer stops producing frames once every analysis is off, which would leave the last overlay
    /// frozen on screen; the settings decide whether one belongs here at all.
    private var showsOverlay: Bool {
        guard model.sessionState == .running else { return false }
        let display = model.settings.display
        // Focus as the camera runs it, like the model's options: a scene that holds the lens at infinity counts
        // as manual focus.
        let manualFocus = model.effectiveFocus.lensPosition != nil || model.activeDial == .focus
        let peaking = display.peaking == .always || (display.peaking == .manualFocus && manualFocus)
        return display.zebras || display.falseColor || peaking
    }
}

private struct OverlaySurface: UIViewRepresentable {
    let image: CGImage?
    let picture: CGRect

    func makeUIView(context: Context) -> OverlayHostView {
        let view = OverlayHostView()
        view.configure()
        view.setPictureRect(picture, animated: false)
        view.show(image)
        return view
    }

    func updateUIView(_ uiView: OverlayHostView, context: Context) {
        uiView.setPictureRect(picture, animated: PictureLayerMotion.animates(in: context.environment))
        uiView.show(image)
    }
}

/// Core Animation scales the overlay to the preview, so a new one costs a texture upload and no layout.
private final class OverlayHostView: UIView {
    private let overlayLayer = CALayer()
    private var shownImage: CGImage?
    /// Where the overlay goes, in this view's coordinates; null until the camera screen has laid out.
    private var pictureRect = CGRect.null

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

    /// Moves the overlay with the preview layer, on the same spring.
    func setPictureRect(_ rect: CGRect, animated: Bool) {
        guard PictureLayerMotion.isUsable(rect), rect != pictureRect else { return }
        let hadRect = !pictureRect.isNull
        pictureRect = rect
        PictureLayerMotion.move(overlayLayer, to: rect, animated: animated && hadRect && window != nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let target = pictureRect.isNull ? bounds : pictureRect
        guard overlayLayer.frame != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.frame = target
        CATransaction.commit()
    }
}

// MARK: - Exposure slider

/// The Camera app's sun: it sits beside the focus square and slides along a short track while the exposure is
/// dragged. Its own layer above the bands and the capture blink, which belong to the picture, laid out in the
/// viewfinder's screen space. The sun, its track and its value keep to the open part of the frame, so none of them
/// goes under the controls or the top bar.
struct ExposureSliderLayer: View {
    let model: CameraModel
    let interaction: ViewfinderInteraction
    let geometry: ViewfinderGeometry

    var body: some View {
        ZStack {
            if let anchor = visibleAnchor {
                let turns = model.motion.quarterTurns
                let area = geometry.open
                let travel = Self.travel(from: anchor, quarterTurns: turns, in: area)
                SunSliderGraphic(
                    bias: ViewfinderInteraction.currentBias(model),
                    showsTrack: interaction.isDraggingExposure,
                    showsValue: interaction.sliderAnchor != nil,
                    side: Self.side(for: anchor, quarterTurns: turns, in: area),
                    up: travel.up,
                    down: travel.down
                )
                .rotationEffect(.degrees(Self.degrees(quarterTurns: turns)))
                .position(anchor)
                .transition(.opacity)
            }
        }
        .frame(width: geometry.screen.width, height: geometry.screen.height)
        .animation(Theme.fade, value: visibleAnchor == nil)
        // Beside a square under the controls, the sun stops at their edge with it.
        .clipShape(OpenAreaClip(rect: geometry.open))
        .frameMotion(value: geometry.open)
        // The Camera Control's overlay has an exposure slider of its own, which changes the same value: a second
        // one beside the square would show each change twice.
        .opacity(model.controlsFullscreen ? 0 : 1)
        .animation(Theme.fade, value: model.controlsFullscreen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: model.focusPoint, initial: true) { _, point in
            interaction.focusPointChanged(to: point, model: model)
        }
        .onChange(of: ViewfinderInteraction.isLocked(model)) { _, locked in
            interaction.lockChanged(locked)
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
        // A zoom or lens change moves the picture under the focus point, so the sun no longer belongs there. So
        // does a new picture rect (another aspect ratio or VIDEO), and the focus magnifier, a zoom on the middle.
        .onChange(of: model.settings.zoom) {
            interaction.focusPointMoved()
        }
        .onChange(of: model.activePresetID) {
            interaction.focusPointMoved()
        }
        .onChange(of: geometry.picture) {
            interaction.focusPointMoved()
        }
        .onChange(of: model.isMagnified) {
            interaction.focusPointMoved()
        }
    }

    /// The drag's anchor, or the focus point while its square is on screen. None while the focus magnifier enlarges
    /// the middle of the frame: the square is hidden then, and the exposure holds.
    private var visibleAnchor: CGPoint? {
        guard !model.isMagnified else { return nil }
        if let anchor = interaction.sliderAnchor { return anchor }
        let picture = geometry.picture
        return interaction.visibleFocusPoint(model).map { CGPoint(x: $0.x + picture.minX, y: $0.y + picture.minY) }
    }

    /// 1 puts the sun on the user's right of the focus square, -1 on the left when the right side, the value beside
    /// the sun included, runs off the open part of the frame.
    private static func side(for anchor: CGPoint, quarterTurns: Int, in area: CGRect) -> CGFloat {
        // Out to the far end of the value: its offset from the sun and about half a value's width.
        let reach = SunSliderGraphic.sunDistance + SunSliderGraphic.valueOffset + 14
        let offset = ViewfinderInteraction.screenVector(CGPoint(x: reach, y: 0), quarterTurns: quarterTurns)
        let sun = CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y)
        let margin: CGFloat = 8
        let fits = sun.x >= area.minX + margin && sun.x <= area.maxX - margin
            && sun.y >= area.minY + margin && sun.y <= area.maxY - margin
        return fits ? 1 : -1
    }

    /// How far the sun may travel up and down the person's frame from the anchor before it would leave the open
    /// part of the frame (ViewfinderInteraction.screenVector: one quarter turn puts the person's up at the screen's
    /// right). An anchor outside the open part, as for a square tapped between the controls, gets no travel there.
    private static func travel(from anchor: CGPoint, quarterTurns: Int,
                               in area: CGRect) -> (up: CGFloat, down: CGFloat) {
        // The sun is 17 pt: this keeps all of it in.
        let margin: CGFloat = 12
        let top = anchor.y - (area.minY + margin)
        let bottom = (area.maxY - margin) - anchor.y
        let left = anchor.x - (area.minX + margin)
        let right = (area.maxX - margin) - anchor.x
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return (right, left)
        case 2: return (bottom, top)
        case 3: return (left, right)
        default: return (top, bottom)
        }
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
    /// How far the sun may go up and down from the square in the user's frame and stay in the open part of the frame.
    /// The track ends there too, so at a limit the sun waits at the end while the value goes on.
    let up: CGFloat
    let down: CGFloat

    /// Half the focus square drawn by ViewfinderOverlays (72 pt) plus a gap.
    static let sunDistance: CGFloat = 36 + 18
    /// The value sits this far beyond the sun.
    static let valueOffset: CGFloat = 30
    private static let trackHalf: CGFloat = 120
    private static let trackGap: CGFloat = 14

    var body: some View {
        let up = Self.limit(self.up)
        let down = Self.limit(self.down)
        let x = side * Self.sunDistance
        let y = -min(max(CGFloat(bias) * ViewfinderInteraction.pointsPerEV, -down), up)
        let upper = max(0, y - Self.trackGap + up)
        let lower = max(0, down - y - Self.trackGap)
        ZStack {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1, height: upper)
                .offset(x: x, y: -up + upper / 2)
                .opacity(showsTrack ? 1 : 0)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1, height: lower)
                .offset(x: x, y: down - lower / 2)
                .opacity(showsTrack ? 1 : 0)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.accent)
                .offset(x: x, y: y)
            Text(EVFormat.label(bias))
                .font(Theme.readoutFont)
                .foregroundStyle(Theme.accent)
                .fixedSize()
                .offset(x: x + side * Self.valueOffset, y: y)
                .opacity(showsValue ? 1 : 0)
        }
        .frame(width: 2 * (Self.sunDistance + 60), height: 2 * Self.trackHalf + 32)
        .lineShadow()
        .animation(Theme.snappy, value: bias)
        .animation(Theme.fade, value: showsTrack)
        .animation(Theme.fade, value: showsValue)
    }

    /// A limit inside the track's half length. One that isn't a number leaves the whole track.
    private static func limit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), trackHalf) : trackHalf
    }
}
