import SwiftUI
import CameraCore

/// Grid, level, aspect mask, focus reticle and warning badges over the preview.
struct ViewfinderOverlays: View {
    @Bindable var model: CameraModel

    /// Bumped a few times after a mode, video or lens change, because the preview can take a moment to
    /// report the new format's shape.
    @State private var measurePass = 0
    /// A zoom or lens change since the last focus tap moved the picture under the focus point.
    @State private var focusPointIsStale = false
    /// The focus point the flags around it describe. A model.focusPoint that differs is a tap this view hasn't
    /// caught up with yet (change handlers run after the frame that shows it), so that frame reads the model alone.
    @State private var trackedFocusPoint: CGPoint?
    /// The long press that placed the tracked point also locked exposure, so the square carries the lock.
    @State private var lockIsAtFocusPoint = false

    var body: some View {
        GeometryReader { proxy in
            let frame = PreviewFrame(size: proxy.size, imageAspect: imageAspect, crop: cropAspect)
            let square = focusSquare
            ZStack(alignment: .topLeading) {
                AspectMask(cropRect: frame.cropRect, isVisible: frame.isCropped)
                GridLines(style: model.settings.display.grid, rect: frame.cropRect)
                    .animation(Theme.spring, value: frame.cropRect)
                LevelIndicator(model: model, center: CGPoint(x: frame.cropRect.midX, y: frame.cropRect.midY))
                FocusReticleLayer(model: model, size: proxy.size, square: square)
                StatusBadges(model: model, rect: frame.imageRect, reticleShowsLock: square?.isLocked == true)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onChange(of: model.focusPoint, initial: true) { _, point in
            trackedFocusPoint = point
            if focusPointIsStale { focusPointIsStale = false }
            let locked = point != nil && model.aeLocked
            if lockIsAtFocusPoint != locked { lockIsAtFocusPoint = locked }
        }
        // The model keeps the point of a released lock. Locking again later (the AE-L chip) isn't tied to that old
        // square: it shows as the corner badge and must not bring the square back.
        .onChange(of: model.aeLocked) { _, locked in
            if !locked && lockIsAtFocusPoint { lockIsAtFocusPoint = false }
        }
        // The square marks a spot in the picture; zooming or switching lens moves the picture under it.
        .onChange(of: model.settings.zoom) {
            if !focusPointIsStale { focusPointIsStale = true }
        }
        .onChange(of: model.activePresetID) {
            if !focusPointIsStale { focusPointIsStale = true }
        }
        .task(id: FormatKey(mode: model.settings.mode, video: model.settings.video, lensID: model.settings.lensID)) {
            for delay: UInt64 in [300_000_000, 600_000_000, 1_200_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                measurePass &+= 1
            }
        }
    }

    private struct FormatKey: Equatable {
        var mode: CaptureMode
        var video: VideoSettings
        var lensID: String?
    }

    /// The focus square to draw, or nil.
    private var focusSquare: FocusSquare? {
        guard let point = model.focusPoint else { return nil }
        // A tap clears the AE lock and a long press sets it, so a new point that arrives locked is a long press.
        guard point == trackedFocusPoint else { return FocusSquare(point: point, isLocked: model.aeLocked) }
        guard !focusPointIsStale else { return nil }
        return FocusSquare(point: point, isLocked: model.aeLocked && lockIsAtFocusPoint)
    }

    /// Photos are cropped to the chosen ratio; video keeps the whole frame.
    private var cropAspect: AspectRatio? {
        let settings = model.settings
        return settings.mode == .video ? nil : settings.capture.aspect
    }

    /// Width over height of the picture inside the preview layer, which letterboxes it (resize aspect).
    private var imageAspect: CGFloat {
        // Capabilities are rebuilt after every lens and format change, so reading them here re-measures then;
        // the measure passes catch a preview that switches over a little later.
        let capabilities = model.capabilities
        _ = measurePass
        if model.sessionState == .running, let measured = Self.measuredAspect(of: model.backend) {
            return measured
        }
        let settings = model.settings
        return Self.expectedAspect(mode: settings.mode, video: settings.video, capabilities: capabilities, simulated: model.isSimulated)
    }

    /// Where the sensor's corners land in the layer, straight from the backend, so it follows the active format.
    private static func measuredAspect(of backend: CameraBackend) -> CGFloat? {
        guard let first = backend.layerPoint(fromDevicePoint: CGPoint(x: 0, y: 0)),
              let second = backend.layerPoint(fromDevicePoint: CGPoint(x: 1, y: 1)) else { return nil }
        let width = abs(second.x - first.x)
        let height = abs(second.y - first.y)
        guard width.isFinite, height.isFinite, width > 1, height > 1 else { return nil }
        let aspect = width / height
        // The interface is portrait; a landscape answer means the preview rotation isn't applied yet.
        guard aspect >= 0.4, aspect <= 1 else { return nil }
        return aspect
    }

    /// The shape to assume until the backend can say: 4:3 photo formats and 16:9 video formats, upright.
    private static func expectedAspect(mode: CaptureMode, video: VideoSettings, capabilities: CameraCapabilities, simulated: Bool) -> CGFloat {
        // The simulated camera renders its 3:4 scene in every mode.
        guard mode == .video, !simulated else { return 3.0 / 4.0 }
        let requirement = VideoRequirement(resolution: video.resolution, frameRate: video.frameRate, colorMode: video.colorMode)
        let size = FormatSelector.bestVideoFormat(for: requirement, among: capabilities.formats)
            .map { (width: $0.width, height: $0.height) } ?? video.resolution.dimensions
        let long = Double(max(size.width, size.height))
        let short = Double(min(size.width, size.height))
        guard long > 0, short > 0 else { return 3.0 / 4.0 }
        return CGFloat(short / long)
    }
}

// MARK: - Geometry

/// Where the picture and the photo crop sit inside the viewfinder.
private struct PreviewFrame {
    let imageRect: CGRect
    let cropRect: CGRect
    let isCropped: Bool

    init(size: CGSize, imageAspect: CGFloat, crop: AspectRatio?) {
        let image = Self.fit(aspect: imageAspect, in: size)
        var cropped = image
        if let crop, image.width > 0, image.height > 0 {
            // The crop's long side runs along the sensor's long axis, vertical in the portrait preview.
            let unit = crop.normalizedCrop(imageAspect: Double(image.width / image.height))
            cropped = CGRect(
                x: image.minX + CGFloat(unit.x) * image.width,
                y: image.minY + CGFloat(unit.y) * image.height,
                width: CGFloat(unit.width) * image.width,
                height: CGFloat(unit.height) * image.height
            )
        }
        imageRect = image
        cropRect = cropped
        isCropped = cropped.width < image.width - 0.5 || cropped.height < image.height - 0.5
    }

    private static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, aspect.isFinite, aspect > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
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

// MARK: - Aspect mask

private struct AspectMask: View {
    let cropRect: CGRect
    let isVisible: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            CropCutout(crop: cropRect)
                .fill(Theme.maskDim, style: FillStyle(eoFill: true))
            CropOutline(crop: cropRect)
                .stroke(Color.white.opacity(0.3), lineWidth: 1 / max(displayScale, 1))
        }
        .opacity(isVisible ? 1 : 0)
        .animation(Theme.spring, value: cropRect)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .accessibilityHidden(true)
    }
}

/// The whole view with the crop cut out (even-odd fill).
private struct CropCutout: Shape {
    var crop: CGRect

    var animatableData: AnimatableRect {
        get { crop.animatableRect }
        set { crop = CGRect(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(crop)
        return path
    }
}

private struct CropOutline: Shape {
    var crop: CGRect

    var animatableData: AnimatableRect {
        get { crop.animatableRect }
        set { crop = CGRect(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        Path(crop)
    }
}

// MARK: - Grid

/// Hairline composition guides inside the photo crop. Animatable so the lines glide with the mask when
/// the aspect ratio changes.
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

/// Where the focus square sits and whether it carries the AE/AF lock.
private struct FocusSquare: Equatable {
    var point: CGPoint
    var isLocked: Bool
}

private struct FocusReticleLayer: View {
    let model: CameraModel
    let size: CGSize
    let square: FocusSquare?

    var body: some View {
        ZStack {
            if let square {
                // Read only while a square is up, so the attitude's frequent updates cost nothing the rest of the time.
                let turns = model.motion.quarterTurns
                FocusReticle(
                    isLocked: square.isLocked,
                    bias: Self.bias(model),
                    quarterTurns: turns,
                    labelBelow: labelBelow(square.point, turns: turns)
                )
                .position(square.point)
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

    /// The lock label goes above the square in the user's frame, or below it near the edge.
    private func labelBelow(_ point: CGPoint, turns: Int) -> Bool {
        let offset = Upright.screenVector(CGPoint(x: 0, y: -(FocusReticle.side / 2 + 26)), quarterTurns: turns)
        let label = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        let margin: CGFloat = 8
        return label.x < margin || label.x > size.width - margin || label.y < margin || label.y > size.height - margin
    }
}

private struct FocusReticle: View {
    let isLocked: Bool
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
                Text("AE/AF LOCK")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .fixedSize()
                    .offset(y: (labelBelow ? 1 : -1) * (Self.side / 2 + 16))
                    .transition(.opacity)
                    // The corner AE LOCK badge steps aside while this label shows, so VoiceOver needs this one.
                    .accessibilityLabel("Exposure and focus locked")
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

/// Status badges in the picture's top right corner. Each one turns upright with the phone where it stands,
/// like the other chips, so nothing moves into the histogram's corner or under the controls.
private struct StatusBadges: View {
    let model: CameraModel
    let rect: CGRect
    /// The focus square is on screen with its own AE/AF LOCK label.
    let reticleShowsLock: Bool

    var body: some View {
        let stacked = model.shutterIsStacked
        let exposureLocked = model.aeLocked && !reticleShowsLock
        let turns = model.motion.quarterTurns
        VStack(alignment: .trailing, spacing: 0) {
            if stacked {
                StatusBadge(symbol: "square.stack.3d.up.fill", text: "STACKED", tint: Theme.accent, quarterTurns: turns)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            if exposureLocked {
                StatusBadge(symbol: "lock.fill", text: "AE LOCK", tint: Theme.accent, quarterTurns: turns)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            ClippingBadge(model: model, quarterTurns: turns)
            SensorBadges(model: model, quarterTurns: turns)
        }
        .padding(.top, 10)
        .padding(.trailing, 10)
        .frame(width: max(rect.width, 0), height: max(rect.height, 0), alignment: .topTrailing)
        .position(x: rect.midX, y: rect.midY)
        .animation(Theme.snappy, value: stacked)
        .animation(Theme.snappy, value: exposureLocked)
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
        ZStack(alignment: .topTrailing) {
            // Keeps the view alive while the badge is hidden, so the task below keeps watching.
            Color.clear.frame(width: 0, height: 0)
            if isShown {
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
        let manualFocus = model.settings.focus.lensPosition != nil || model.activeDial == .focus
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
