import SwiftUI
import AVKit
// onCameraCaptureEvent lives in AVKit's SwiftUI overlay. Xcode loads it from the two imports above; naming it
// keeps the modifier visible to compilers that don't load cross-import overlays on their own.
import _AVKit_SwiftUI
import CameraCore

/// The whole camera: viewfinder, controls, mode carousel, shutter.
struct CameraScreen: View {
    @Bindable var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase
    /// Settings zooms out of the gear in the top bar.
    @Namespace private var settingsZoom

    var body: some View {
        // The gallery is presented from the thumbnail (GalleryThumbnail.swift), which its zoom transition starts from.
        ZStack {
            Theme.background
                .ignoresSafeArea()
            ScreenContent(model: model, settingsZoom: settingsZoom)
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(model: model)
                .settingsZoomTransition(settingsZoom)
        }
        .alert("Open Shutter can't save to Photos", isPresented: $model.isPhotosAccessAlertShown) {
            Button("Open Settings") { model.openAppSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Turn on Photos access for Open Shutter in Settings, then take the shot again.")
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneDidBecomeActive()
            case .background: model.sceneDidEnterBackground()
            case .inactive: break
            @unknown default: break
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

/// The camera or the permission page.
private struct ScreenContent: View {
    let model: CameraModel
    let settingsZoom: Namespace.ID

    var body: some View {
        ZStack {
            if model.authorization == .authorized {
                CameraLayout(model: model, settingsZoom: settingsZoom)
                    .transition(.opacity)
            } else {
                PermissionView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.authorization)
    }
}

// MARK: - Layout

/// The screen space every layer of the camera is laid out in: the whole screen, safe areas included.
private let cameraSpace = CaptureFlight.space

/// The camera over the whole screen, in the order of Apple's iOS 26 Camera. The viewfinder covers the screen: the 16:9
/// region runs at full width from the safe area's top, the photo frame is the largest of its shape inside it, and the
/// bands around the frame turn from black to see-through once the picture is live. The top bar sits over the top of
/// the region. The lens buttons and the shutter sit inside the region's bottom, and the row with the thumbnail, the
/// modes and the flip button in the band under it, all anchored to the region, so nothing moves when the shape
/// changes. A phone with no band there (iPhone SE) stacks the controls up from the bottom edge in their earlier order.
private struct CameraLayout: View {
    let model: CameraModel
    let settingsZoom: Namespace.ID

    /// The controls' top edge on screen, once measured. The open part of the frame ends there.
    @State private var controlsTop: CGFloat?
    @State private var veilVisible = false
    @State private var veilToken = 0
    @State private var veilHoldNanoseconds: UInt64 = 350_000_000
    /// A lens button is swapping cameras. Both cameras frame the same picture at the swap, so this veil is short.
    /// A lens button's swap of cameras holds the last frame on screen until the new camera's first frames settle.
    @State private var lensFrozen = false
    /// The timer sheet is up. The top bar's Timer button and the quick settings panel's timer item both ask for it,
    /// and it is presented from here, so the bar's button never has to open the panel.
    @State private var timerSheetShown = false
    /// Gesture state shared by the picture, the sun above the bands and VoiceOver's viewfinder element.
    @State private var interaction = ViewfinderInteraction()
    /// The zoom wheel a hold on a lens button opens. Its readout reaches over the rows above the lens row, so they
    /// fade while it is open, and the level steps aside.
    @State private var wheel = ZoomWheelModel()
    /// The steady status, the badge column and the quick settings panel as measured, for the histogram, the badges
    /// and the toasts that move out of their way.
    @State private var furniture = TopFurniture()
    /// Width over height of the camera image as the portrait preview shows it: measured from the preview layer while
    /// the camera runs, expected from the format until then.
    @State private var imageAspect = 3.0 / 4.0
    /// The bands are solid black. They turn see-through once the picture is live and has settled.
    @State private var bandsSolid = true
    /// The copy of a new shot on its way from the picture to the thumbnail.
    @State private var flight = CaptureFlight()

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// The safe area as the screen's own frame in window points. The reader below ignores the safe area so the picture
    /// can reach the top edge, and a reader that does reports insets of zero, which put the top bar under the
    /// Dynamic Island where it can't be tapped.
    @State private var safeFrame: CGRect = .zero

    static let topBarHeight: CGFloat = 48
    /// The thumbnail and the flip button are 48 pt, the carousel 44.
    static let modeRowHeight: CGFloat = 48

    var body: some View {
        let settings = model.settings
        let mode = settings.mode
        // Photos are cut to the chosen shape; video keeps the whole picture.
        let shape: AspectRatio? = mode == .video ? nil : settings.capture.aspect
        let fullscreen = model.controlsFullscreen
        let selectedIsFront = model.lenses.first(where: { $0.id == settings.lensID })?.isFront ?? false
        let isLive = model.sessionState == .running && interaction.isPreviewing
        let isVeiled = veilVisible
        let aspectKey = AspectKey(mode: mode, video: settings.video, lensID: settings.lensID,
                                  isRunning: model.sessionState == .running,
                                  formatCount: model.capabilities.formats.count,
                                  activeVideo: model.capabilities.activeVideo,
                                  formatSummary: model.capabilities.formatSummary)

        ZStack {
        Color.clear
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                safeFrame = frame
            }
        GeometryReader { proxy in
            let size = proxy.size
            let insets = safeFrame.isEmpty ? proxy.safeAreaInsets : EdgeInsets(
                top: max(0, safeFrame.minY),
                leading: max(0, safeFrame.minX),
                bottom: max(0, size.height - safeFrame.maxY),
                trailing: max(0, size.width - safeFrame.maxX)
            )
            let layout = ViewfinderLayout(screenWidth: Double(size.width), screenHeight: Double(size.height),
                                          safeTop: Double(insets.top), topBarHeight: Double(Self.topBarHeight),
                                          shape: shape, imageAspect: imageAspect)
            let topBarBottom = insets.top + Self.topBarHeight
            let geometry = ViewfinderGeometry(layout: layout, screen: size, topBarBottom: topBarBottom,
                                              controlsTop: controlsTop, scale: displayScale)
            let placement = ControlsPlacement(
                anchors: layout.controls(screenHeight: Double(size.height), safeBottom: Double(insets.bottom),
                                         modeRowHeight: Double(Self.modeRowHeight)),
                screenHeight: size.height, safeBottom: insets.bottom)

            ZStack(alignment: .topLeading) {
                ViewfinderStack(model: model, interaction: interaction, wheel: wheel, furniture: furniture,
                                geometry: geometry, veilVisible: isVeiled, lensFrozen: lensFrozen,
                                bandsSolid: bandsSolid)

                // The Camera Control's overlay hides these four layers: VoiceOver leaves them too.
                DrawerLayer(model: model, furniture: furniture,
                            catcherHeight: max(0, (controlsTop ?? size.height) - topBarBottom),
                            timerSheetRequested: $timerSheetShown)
                    .padding(.top, topBarBottom)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)
                    .accessibilityHidden(fullscreen)

                ControlsZone(model: model, wheel: wheel, flight: flight, modeRowInBand: placement.modeRowY != nil,
                             lensGap: placement.lensGap)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(cameraSpace)).minY
                    } action: { top in
                        controlsTop = top
                    }
                    .frame(width: size.width, height: max(0, placement.zoneBottom), alignment: .bottom)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)
                    .accessibilityHidden(fullscreen)

                if let modeRowY = placement.modeRowY {
                    ModeRow(model: model, flight: flight)
                        .frame(width: size.width, height: Self.modeRowHeight)
                        .position(x: size.width / 2, y: modeRowY)
                        .opacity(fullscreen ? 0 : 1)
                        .allowsHitTesting(!fullscreen)
                        .accessibilityHidden(fullscreen)
                }

                // Drawn after the drawer so the drawer slides out from underneath it.
                TopBar(model: model, timerSheetRequested: $timerSheetShown, settingsZoom: settingsZoom)
                    .frame(width: size.width)
                    .padding(.top, insets.top)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)
                    .accessibilityHidden(fullscreen)

                // Over the controls, so the copy passes over the rows between the picture and the thumbnail.
                CaptureFlightLayer(flight: flight, pictureFrame: geometry.frame)
                    .frame(width: size.width, height: size.height)

                // Over the quick settings and the controls a message can share the screen with, so where the open
                // part of the frame is short it is still read whole. It goes under the panel while that is open, and
                // shows in the Camera Control's overlay too.
                ToastLayer(model: model, open: geometry.open, furniture: furniture,
                           panelTop: topBarBottom + DrawerLayer.panelGap)

                // The battery saver's black layer covers everything, the bands and the controls too.
                DimOverlay(model: model)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named(cameraSpace))
            .task(id: BandKey(isLive: isLive, isVeiled: isVeiled, frame: geometry.frame.integral)) {
                // Solid at once whenever something changes: the camera starts or stops, a veil comes up, or the frame
                // moves, so a frame between two shapes never shows picture that isn't part of either.
                if !bandsSolid { bandsSolid = true }
                guard isLive, !isVeiled else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                bandsSolid = false
            }
        }
        .ignoresSafeArea()
        }
        .animation(Theme.fade, value: fullscreen)
        .modifier(HardwareButtons(model: model, isEnabled: hardwareButtonsEnabled))
        .sheet(isPresented: $timerSheetShown) {
            TimerControls(model: model)
        }
        .onChange(of: mode) { oldMode, newMode in
            if let dial = model.activeDial, !Self.dialAllowed(dial, in: newMode) {
                model.activeDial = nil
            }
            // Video needs a session reconfiguration, which takes longer than a photo mode change. A change of scene
            // inside NIGHT is no change of mode on screen, and PHOTO's shutter dial is still being turned when its
            // first tick leads into MANUAL: neither gets the veil. Every other change does, dial open or not.
            let involvesVideo = oldMode == .video || newMode == .video
            let ledByDial = model.modeChangeLedByPick && oldMode == .photo && newMode == .manual
                && model.activeDial == .shutter
            if oldMode.carouselMode != newMode.carouselMode, !ledByDial {
                showVeil(holdNanoseconds: involvesVideo ? 650_000_000 : 350_000_000)
            }
            // VIDEO's shape at once, before the aspect task starts, so the frame never heads for the photo format's.
            updateImageAspect()
        }
        .onChange(of: selectedIsFront) { _, _ in
            showVeil(holdNanoseconds: 450_000_000)
        }
        .onChange(of: shape) { _, _ in
            // With Reduce motion, the app's or the system's, the picture cuts to a new shape instead of zooming to
            // it, and the veil softens the cut as it does a lens change's. A switch to or from VIDEO keeps the mode's
            // longer veil.
            guard systemReduceMotion || AppearanceStore.shared.reduceMotion else { return }
            showVeil(holdNanoseconds: 350_000_000)
        }
        // A swap of cameras holds the last frame instead of going dark: the old picture stays, then fades into the new
        // camera once its first frames have settled their exposure and colour.
        .task(id: model.isSwitchingLensVisibly) {
            if model.isSwitchingLensVisibly {
                lensFrozen = true
                return
            }
            guard lensFrozen else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            lensFrozen = false
        }
        .task(id: aspectKey) {
            // The preview can take a moment to report a new format's shape, so it is asked again a few times.
            updateImageAspect()
            for delay: UInt64 in [300_000_000, 600_000_000, 1_200_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                updateImageAspect()
            }
        }
        .onChange(of: model.activity) { _, activity in
            // An open drawer would cover the Stop button and let settings change under a running shot.
            guard model.isDrawerOpen, Self.closesDrawer(activity) else { return }
            withAnimation(Theme.spring) { model.isDrawerOpen = false }
        }
        .onChange(of: model.bracketInProgress) { _, running in
            // A bracket is a long capture with a Stop button too, though its activity is the brief .capturing
            // that a single photo passes through.
            guard running, model.isDrawerOpen else { return }
            withAnimation(Theme.spring) { model.isDrawerOpen = false }
        }
        .onChange(of: model.intervalometer != nil) { _, running in
            // The model is idle between an intervalometer's shots, but the sequence's status and its Stop are up:
            // the panel would cover them, and its catcher would take the tap meant for Stop.
            guard running, model.isDrawerOpen else { return }
            withAnimation(Theme.spring) { model.isDrawerOpen = false }
        }
        .onChange(of: model.settings.controls.haptics, initial: true) { _, enabled in
            Haptics.isEnabled = enabled
        }
        .task(id: veilToken) {
            guard veilVisible else { return }
            try? await Task.sleep(nanoseconds: veilHoldNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { veilVisible = false }
        }
    }

    /// Volume buttons and the Camera Control press go back to the system while a sheet covers the viewfinder,
    /// because a shot nobody can see would be a surprise, and while the camera isn't running, because AVKit
    /// asks apps that can't act on a press to hand the buttons back rather than swallow it.
    private var hardwareButtonsEnabled: Bool {
        model.settings.controls.volumeShutter && model.sessionState == .running
            && !model.isSettingsPresented && !model.isReviewPresented && !timerSheetShown
    }

    private static func closesDrawer(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .countdown, .stacking, .recording: return true
        case .idle, .capturing, .saving: return false
        }
    }

    /// What closes the drawer keeps it closed: the dots button beside the shutter rests until the shot ends, as the
    /// top bar's buttons do, and through the waits between an intervalometer's shots. A single photo doesn't hold
    /// it, which would blink the button with every shot, and a drawer that is open can always be closed.
    static func keepsDrawerClosed(_ model: CameraModel) -> Bool {
        (closesDrawer(model.activity) || model.bracketInProgress || model.intervalometer != nil) && !model.isDrawerOpen
    }

    private func showVeil(holdNanoseconds: UInt64) {
        // A flip asks twice in one update (lens switch and selfie change); the longer hold wins in either order.
        veilHoldNanoseconds = veilVisible ? max(veilHoldNanoseconds, holdNanoseconds) : holdNanoseconds
        veilVisible = true
        veilToken &+= 1
    }

    /// Dials that make sense in each mode. A shutter or ISO dial left open from MANUAL would switch PHOTO back to
    /// MANUAL with the first tick, so it closes instead.
    static func dialAllowed(_ dial: DialKind, in mode: CaptureMode) -> Bool {
        switch mode {
        // The lens row carries the shutter and exposure chips in every mode. PHOTO's shutter dial leads into
        // MANUAL at the first value picked; NIGHT's sets how long the shot runs.
        case .photo, .night: return dial == .bias || dial == .zoom || dial == .shutter
        case .manual, .long, .video: return true
        }
    }

    // MARK: Image shape

    /// What the picture rect is built from. A new format can change the image's shape: a mode, lens or video format
    /// change, or the camera starting with formats it hadn't listed yet. The active format's own description comes in
    /// once a reconfiguration lands, which can be long after the settings changed: VIDEO's first one waits for the
    /// microphone prompt.
    private struct AspectKey: Equatable {
        var mode: CaptureMode
        var video: VideoSettings
        var lensID: String?
        var isRunning: Bool
        var formatCount: Int
        var activeVideo: ActiveVideoFormat?
        var formatSummary: String
    }

    /// The bands go solid while any of these changes.
    private struct BandKey: Equatable {
        var isLive: Bool
        var isVeiled: Bool
        var frame: CGRect
    }

    /// Measured in a task rather than in the body, which runs on every settings write while a dial turns.
    private func updateImageAspect() {
        let settings = model.settings
        // Until VIDEO has a video format, the layer still shows the photo format the switch left behind. The way back
        // needs no such test: the measured video shape crops a photo frame correctly until the photo format lands.
        let stale = settings.mode == .video && model.capabilities.activeVideo == nil
        let measured = model.sessionState == .running && !stale ? Self.measuredAspect(of: model.backend) : nil
        let value = Double(measured ?? Self.expectedAspect(mode: settings.mode, video: settings.video,
                                                            capabilities: model.capabilities,
                                                            simulated: model.isSimulated))
        guard value.isFinite, value > 0, abs(value - imageAspect) > 0.0005 else { return }
        imageAspect = value
    }

    /// Where the sensor's corners land in the preview layer, straight from the backend, so it follows the active
    /// format. Only the shape counts: the layer letterboxes (resize aspect), so its own size doesn't change it.
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
    private static func expectedAspect(mode: CaptureMode, video: VideoSettings, capabilities: CameraCapabilities,
                                       simulated: Bool) -> CGFloat {
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

/// Where the bottom controls go on this screen.
private struct ControlsPlacement {
    /// The controls zone's bottom edge.
    var zoneBottom: CGFloat
    /// The centre of the row with the thumbnail, the modes and the flip button, in the band under the region; nil
    /// when there is no band for it and the row shares the shutter's.
    var modeRowY: CGFloat?
    /// Space between the lens buttons and the shutter row when nothing sits between them.
    var lensGap: CGFloat

    /// The lens row's height (LensRow).
    private static let lensRowHeight: CGFloat = 44

    init(anchors: ViewfinderLayout.Controls, screenHeight: CGFloat, safeBottom: CGFloat) {
        let shutterRow = Theme.shutterSize + 8
        if let modeRowY = anchors.modeRowY, modeRowY.isFinite, anchors.shutterY.isFinite, anchors.lensY.isFinite {
            self.modeRowY = CGFloat(modeRowY)
            zoneBottom = CGFloat(anchors.shutterY) + shutterRow / 2
            // Puts the lens buttons where Apple's are when the shutter is where Apple's is.
            lensGap = max(6, CGFloat(anchors.shutterY - anchors.lensY) - shutterRow / 2 - Self.lensRowHeight / 2)
        } else {
            modeRowY = nil
            zoneBottom = screenHeight - safeBottom
            lensGap = 6
        }
    }
}

// MARK: - Viewfinder

/// The whole-screen viewfinder, bottom to top: the picture (preview, analysis overlay, a running stack), the veil,
/// the capture blink, the bands, the histogram, the marks on the picture (grid, level, focus square and sun, badges),
/// then a running shot's countdown, status and Stop with the drift crosses over all of those, the steady status,
/// and the card that explains a camera that isn't running. Toasts go over the controls (CameraLayout). Everything
/// above the picture leaves touches to the picture's gesture recognizers, except Stop, Cancel and the STACKED badge.
private struct ViewfinderStack: View {
    let model: CameraModel
    let interaction: ViewfinderInteraction
    let wheel: ZoomWheelModel
    /// Passed on, not read: each layer that moves for the steady status or the badges reads it itself.
    let furniture: TopFurniture
    let geometry: ViewfinderGeometry
    let veilVisible: Bool
    let lensFrozen: Bool
    let bandsSolid: Bool

    var body: some View {
        let frame = geometry.frame
        let open = geometry.open
        ZStack(alignment: .topLeading) {
            Theme.background
            // The mode switch's veil is a blurred still of the last frame, laid in the picture's own view so the
            // blur never runs over the live layer.
            CameraPreviewView(model: model, interaction: interaction, geometry: geometry,
                              isHidden: model.dimmer.isDimmed, isFrozen: lensFrozen, isVeiled: veilVisible)
            StackPreviewLayer(model: model, picture: geometry.picture)
            ShutterBlink(model: model)
            FrameBands(frame: frame, solid: bandsSolid)
            // Read off the picture like the bands, so every mark made on the picture is drawn over it: at the top's
            // middle it often meets a focus square's lock label, and the badges move under it.
            HistogramSlot(model: model, open: open, furniture: furniture)
            ViewfinderOverlays(model: model, geometry: geometry, interaction: interaction, wheel: wheel,
                               furniture: furniture)
            ExposureSliderLayer(model: model, interaction: interaction, geometry: geometry)
            // Countdown, status and Stop sit in the part of the frame the top bar and the controls leave open, over
            // the grid, the level, the square and the sun, which would otherwise cross the numerals and the buttons.
            CaptureOverlay(model: model, crossCenter: CGPoint(x: frame.midX - open.minX, y: frame.midY - open.minY))
                .frame(width: max(open.width, 1), height: max(open.height, 1))
                .position(x: open.midX, y: open.midY)
                .frameMotion(value: open)
            // Over the stack's status: where the open area is too short for the block to clear the crosses, as with
            // the phone turned at the shorter shapes, the crosses stay in sight. They never take a touch, so Stop and
            // Cancel under them still do.
            DriftCrosshair(model: model, imageDiagonal: geometry.pictureDiagonal)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            SteadyStatusPlacement(model: model, open: open, furniture: furniture)
            SessionStatusLayer(model: model, open: open)
            ViewfinderAccessibilityTarget(model: model, interaction: interaction, rect: open)
        }
        .frame(width: geometry.screen.width, height: geometry.screen.height, alignment: .topLeading)
        .clipped()
    }
}

/// Reads the analysis frame on its own, so 12 histograms a second redraw only this slot. The histogram sits at the
/// top of the open part of the frame, in the middle, under the steady status while that shows there.
private struct HistogramSlot: View {
    let model: CameraModel
    let open: CGRect
    let furniture: TopFurniture

    var body: some View {
        let style = model.settings.display.histogram
        let steady = furniture.steady
        // With the phone on its side the steady status runs down a side edge instead of across the top, so the
        // histogram stays at the top and keeps narrow enough to pass between it and the other edge.
        let width = steady.onSide
            ? min(HistogramView.width(openWidth: open.width), max(open.width - 2 * SteadyRoom.sideReach, 0))
            : HistogramView.width(openWidth: open.width)
        // Under the quick settings panel's glass the curves would only smear behind its first row. The Camera
        // Control's overlay hides the panel without closing it, and the histogram is back for as long as it shows.
        let underPanel = model.isDrawerOpen && !model.controlsFullscreen
        ZStack(alignment: .top) {
            // Under the battery saver's black layer and the panel the analysis isn't read, so nothing here redraws.
            if model.histogramOnScreen, !underPanel, let histogram = model.analysis?.histogram {
                HistogramView(histogram: histogram, style: style)
                    .frame(width: width, height: HistogramView.height)
                    .padding(.top, 12 + steady.top)
                    .transition(.opacity)
            }
        }
        .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: .top)
        .position(x: open.midX, y: open.midY)
        .frameMotion(value: open)
        .animation(Theme.spring, value: steady)
        .opacity(underPanel ? 0 : 1)
        .animation(Theme.snappy, value: underPanel)
        .accessibilityHidden(underPanel)
        .allowsHitTesting(false)
    }
}

/// The furniture at the top of the open part of the frame as the views that draw it measure it: the steady status,
/// the badge column, and the quick settings panel that opens over them. The histogram, the badges and the toasts read
/// it to keep out of each other's way. A reference, so a measurement redraws only the views that read it.
@MainActor
@Observable
final class TopFurniture {
    var steady = SteadyRoom()
    /// The badge column's height, 0 with no badge up.
    var badgeColumnHeight: CGFloat = 0
    /// The quick settings panel's height, as it was when last open.
    var panelHeight: CGFloat = 0

    /// Where a toast starts under the histogram's place: the histogram's 12 pt margin, its height and a gap.
    static let belowHistogram: CGFloat = 12 + HistogramView.height + 8

    /// How far the badge column at the top right moves down: under the steady status, and under the histogram while
    /// it shows, which centred and about 260 pt wide reaches that corner on every phone narrower than 440 pt.
    func badgeShift(histogramShown: Bool) -> CGFloat {
        max(steady.trailing, steady.top + (histogramShown ? HistogramView.height + 8 : 0))
    }

}

/// Where the steady status sits, for the furniture that moves out of its way. Upright it runs across the top of the
/// open part of the frame. With the phone on its side it runs down the edge that is then the person's top, for as
/// long as the banner is tall, and the top's middle stays free.
struct SteadyRoom: Equatable {
    /// How far the histogram and a toast in the top's middle move down.
    var top: CGFloat = 0
    /// How far the badge column at the top right moves down.
    var trailing: CGFloat = 0
    /// The status runs down a side edge.
    var onSide = false

    /// How far in from a side edge a turned status reaches: its 12 pt margin, the pill's thickness with two lines and
    /// a gap.
    static let sideReach: CGFloat = 74

    init() {}

    /// - Parameters:
    ///   - height: The banner's height: the pill's height upright, its length on its side, 0 while hidden.
    ///   - quarterTurns: The phone's turn, by which the banner places the pill (SteadyBanner).
    init(height: CGFloat, quarterTurns: Int) {
        guard height.isFinite, height > 1 else { return }
        let room = height + 8
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1:
            // The person's top is the screen's right edge, the badges' side.
            trailing = room
            onSide = true
        case 3:
            onSide = true
        default:
            top = room
            trailing = room
        }
    }
}

/// Puts the tripod and hold-still status 12 pt down from the top of the open part of the frame, as wide as the frame
/// shows. The banner turns itself to the person's top when the phone is on its side, and has no height while hidden.
/// It is offered the open part's height less a margin at each end: on its side the status runs along that height, and
/// a longer one scales its words down and then shortens them rather than reaching under the controls. Its height and
/// the phone's turn tell the furniture at the top of the frame where to move to clear it.
private struct SteadyStatusPlacement: View {
    let model: CameraModel
    let open: CGRect
    let furniture: TopFurniture
    /// The banner as laid out: the pill's height upright, its length on its side.
    @State private var height: CGFloat = 0

    private static let margin: CGFloat = 12

    var body: some View {
        SteadyBanner(model: model)
            .frame(width: max(open.width, 0))
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { value in
                if height != value { height = value }
            }
            .background {
                SteadyRoomReport(model: model, height: height, furniture: furniture)
            }
            .padding(.vertical, Self.margin)
            .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: .top)
            .position(x: open.midX, y: open.midY)
            .frameMotion(value: open)
            // Under the quick settings panel's glass the words would only smear behind its first row. Faded, not
            // removed, so the furniture it moved down keeps its place. It stays faded under the Camera Control's
            // overlay, which hides the panel without closing it: the model drops the sign there, and fading back in
            // would only show the sign leaving, through the panel as that fades out.
            .opacity(model.isDrawerOpen ? 0 : 1)
            .animation(Theme.snappy, value: model.isDrawerOpen)
            .accessibilityHidden(model.isDrawerOpen)
            .allowsHitTesting(false)
    }
}

/// Hands the furniture the room the steady status takes, worked out from the banner's height and the phone's turn,
/// only when it changes. It reads the turn on its own and only while the status shows, so the attitude's frequent
/// updates redraw nothing else.
private struct SteadyRoomReport: View {
    let model: CameraModel
    let height: CGFloat
    let furniture: TopFurniture

    var body: some View {
        let turns = height > 1 ? model.motion.quarterTurns : 0
        Color.clear
            .onChange(of: SteadyRoom(height: height, quarterTurns: turns), initial: true) { _, room in
                if furniture.steady != room { furniture.steady = room }
            }
            .accessibilityHidden(true)
    }
}

private struct ToastLayer: View {
    let model: CameraModel
    /// The open part of the frame. A toast sits under the furniture at its top, or in its middle when turned.
    let open: CGRect
    /// The steady status, the histogram, the badge column and the quick settings panel the toast goes under.
    let furniture: TopFurniture
    /// Where the quick settings panel starts on screen, just under the top bar.
    let panelTop: CGFloat
    /// A toast that repeated the status card when it arrived. Remembered, so it doesn't pop up late when the
    /// camera resumes before the toast would have expired.
    @State private var repeatedToastID: UUID?

    /// A two-line message and a margin: what a toast keeps above the controls when the open part is short.
    private static let lowestRoom: CGFloat = 56

    var body: some View {
        let toast = model.toast.flatMap { toast in
            toast.id == repeatedToastID || Self.repeatsStatus(toast, sessionState: model.sessionState) ? nil : toast
        }
        // Read even with no toast up, so a message never changes place or angle while it fades out.
        let motion = model.motion
        // Turned sideways, a message runs along the frame's long side, so it moves to the middle like the stack
        // status; the slot under the furniture at the top is too short for it. The histogram stays at the top's
        // middle, so the message keeps to the part below it. Whether the histogram shows is read only where it
        // moves the message: it reads the settings, which a turning dial writes 120 times a second.
        let sideways = motion.quarterTurns % 2 != 0
        let sidewaysTop = sideways && model.histogramOnScreen ? TopFurniture.belowHistogram : 0
        let topInset = sideways ? 0 : portraitInset()
        // The capsule is laid out before it turns, so its width ends up along the open part's height, less a margin
        // at each end, with a third line for what no longer fits on two.
        let sidewaysWidth = max(open.height - sidewaysTop - 32, 160)
        ZStack {
            if let toast {
                ToastCapsule(toast: toast, lineLimit: sideways ? 3 : 2)
                    .frame(maxWidth: sideways ? sidewaysWidth : nil)
                    .uprightRotation(motion.iconRotationDegrees)
                    .id(toast.id)
                    .transition(sideways ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, sideways ? sidewaysTop : topInset)
        .padding(.horizontal, 16)
        .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: sideways ? .center : .top)
        .position(x: open.midX, y: open.midY)
        .frameMotion(value: open)
        .animation(Theme.spring, value: toast?.id)
        .animation(Theme.spring, value: sideways)
        .animation(Theme.spring, value: topInset)
        .animation(Theme.spring, value: sidewaysTop)
        .allowsHitTesting(false)
        .onChange(of: model.toast?.id) { _, _ in
            guard let current = model.toast else { return }
            if Self.repeatsStatus(current, sessionState: model.sessionState) {
                repeatedToastID = current.id
            }
            // A toast fades before VoiceOver could reach it, and the status card is never announced, so every
            // message is read out when it arrives.
            AccessibilityNotification.Announcement(current.message).post()
        }
    }

    /// How far down the open part of the frame a toast starts, upright: under the histogram's place and the steady
    /// status above it, under the badge column where that reaches lower, and under the quick settings panel while it
    /// is open. Never so low that a two-line message would reach under the controls: where the open part is short,
    /// as with a tall dial open on a small phone, it rises over the furniture instead, which it is drawn above.
    private func portraitInset() -> CGFloat {
        var top = TopFurniture.belowHistogram + furniture.steady.top
        let column = furniture.badgeColumnHeight
        if column > 0 {
            let shift = furniture.badgeShift(histogramShown: model.histogramOnScreen)
            top = max(top, 10 + shift + column + 8)
        }
        if model.isDrawerOpen, !model.controlsFullscreen {
            top = max(top, panelTop + furniture.panelHeight + 8 - open.minY)
        }
        return max(0, min(top, open.height - Self.lowestRoom))
    }

    /// The status card already says why the camera paused or failed; the same words as a toast would say it twice.
    private static func repeatsStatus(_ toast: Toast, sessionState: SessionState) -> Bool {
        switch sessionState {
        case .interrupted(let reason), .failed(let reason):
            return toast.message == reason
        case .idle, .starting, .running:
            return false
        }
    }
}

private struct ToastCapsule: View {
    let toast: Toast
    let lineLimit: Int

    var body: some View {
        HStack(spacing: 8) {
            // A glyph leads where the message has one; otherwise the accent dot marks it as the camera's word.
            if let symbol = toast.symbol {
                Image(systemName: symbol)
            } else {
                AccentDot(size: 5)
            }
            Text(toast.message)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
        }
        .font(Theme.labelFont)
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .cameraGlass(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Explains a black viewfinder: another app has the camera, a call came in, or the session failed.
private struct SessionStatusLayer: View {
    let model: CameraModel
    /// The words sit in the middle of the open part of the frame.
    let open: CGRect

    var body: some View {
        ZStack {
            switch model.sessionState {
            case .interrupted(let reason):
                StatusCard(symbol: "video.slash", title: "Camera paused", detail: reason, open: open)
                    .transition(.opacity)
            case .failed(let reason):
                StatusCard(symbol: "exclamationmark.triangle", title: "Camera unavailable", detail: reason, open: open)
                    .transition(.opacity)
            case .idle, .starting, .running:
                EmptyView()
            }
        }
        .animation(Theme.fade, value: model.sessionState)
        .allowsHitTesting(false)
    }
}

private struct StatusCard: View {
    let symbol: String
    let title: String
    let detail: String
    let open: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Darkens the whole screen, bands and all.
            Theme.background.opacity(0.55)
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                Text(title)
                    .font(.headline)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 32)
            .frame(width: max(open.width, 0))
            .position(x: open.midX, y: open.midY)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Drawer

private struct DrawerLayer: View {
    let model: CameraModel
    /// Where the panel's height goes, for the toasts that go under it.
    let furniture: TopFurniture
    /// From the top bar's bottom edge to the controls' top: a tap there closes the drawer.
    let catcherHeight: CGFloat
    @Binding var timerSheetRequested: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// The panel starts this far under the top bar.
    static let panelGap: CGFloat = 6

    var body: some View {
        let isOpen = model.isDrawerOpen
        // The app's own Reduce motion switch counts as much as the system's.
        let reduceMotion = systemReduceMotion || AppearanceStore.shared.reduceMotion
        ZStack(alignment: .top) {
            if isOpen {
                // A tap on the viewfinder closes the drawer instead of moving focus behind it.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: catcherHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.spring) { model.isDrawerOpen = false }
                    }
                    .accessibilityHidden(true)
                QuickSettingsDrawer(model: model, timerSheetRequested: $timerSheetRequested)
                    // Its size, not its frame, which the slide moves: a message that arrives while the panel is open
                    // goes under it.
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        if furniture.panelHeight != height { furniture.panelHeight = height }
                    }
                    .padding(.top, Self.panelGap)
                    // With Reduce Motion the drawer fades in place instead of sliding down.
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Clipping at the top bar's bottom edge makes the drawer appear from under the bar.
        .clipped()
        .animation(Theme.spring, value: isOpen)
    }
}

// MARK: - Controls

private struct ControlsZone: View {
    let model: CameraModel
    /// The zoom wheel a hold on a lens button opens. Its readout reaches over the rows above the lens row, so they
    /// fade while it is open.
    let wheel: ZoomWheelModel
    let flight: CaptureFlight
    /// The thumbnail, the modes and the flip button have a row of their own in the band under the frame (ModeRow).
    /// Without a band (iPhone SE) the thumbnail and the flip button flank the shutter and the modes sit above it.
    let modeRowInBand: Bool
    /// Space between the lens buttons and the shutter row when nothing sits between them.
    let lensGap: CGFloat

    var body: some View {
        let mode = model.settings.mode
        let dial = model.activeDial
        let wheelOpen = wheel.isOpen
        let activity = model.activity
        let isStacking = activity == .stacking
        let isRecording = activity == .recording
        let showsPanel = mode != .photo
        // PHOTO has no chips of its own, so its line of live values has the row the other modes give theirs.
        let showsReadout = mode == .photo && model.settings.display.showReadout
        // Without a band (iPhone SE) the quick settings panel reaches down to the mode's own row above the chips, so
        // that row folds while the quick settings are open.
        let hasRoomForModeRow = modeRowInBand || !model.isDrawerOpen

        VStack(spacing: 6) {
            // A stack can't change mid-capture, so its panels fold away and the progress has the screen.
            if !isStacking {
                // The dial opens at the top of the stack, above the rows whose chips opened it: the lens buttons, the
                // shutter and exposure chips beside them and the mode's chips stay exactly where they were, so
                // nothing moves under the finger.
                Group {
                    if dial != nil {
                        // Comes into focus where it stands rather than sliding up: nothing on the camera travels to
                        // arrive, and the chips under it stay put.
                        ActiveDialView(model: model)
                            .transition(.cameraFocus)
                    }
                    if showsPanel {
                        ModePanels(model: model, mode: mode, hasRoom: hasRoomForModeRow, dialOpen: dial != nil,
                                   isRecording: isRecording)
                            // NIGHT's two kinds of shot are one mode on screen, so its panel changes in place.
                            .id(mode.carouselMode)
                            .transition(.cameraFocus)
                    } else if showsReadout {
                        // As tall as the strip of chips: when PHOTO's shutter dial leads into MANUAL at its first
                        // tick, the strip takes this row over and the dial stays where the finger is.
                        ReadoutHUD(model: model)
                            .frame(height: 44)
                            .transition(.cameraFocus)
                    } else if dial == .shutter {
                        // With the readout switched off the row is kept free for that dial, for the same reason.
                        Color.clear
                            .frame(height: 44)
                            .accessibilityHidden(true)
                    }
                }
                // Faded, not removed: the zone keeps its height, so nothing moves while the wheel is open.
                .opacity(wheelOpen ? 0 : 1)
                .allowsHitTesting(!wheelOpen)
                .accessibilityHidden(wheelOpen)
            }

            // In every mode, at Apple's distance from the shutter, with the shutter chip on one side and the exposure
            // chip on the other.
            LensRow(model: model, wheel: wheel)
                .disabled(isStacking)
                .opacity(isStacking ? Theme.Dim.held : 1)

            // Without a band for the mode row the carousel sits here. It stays while a dial is open, as it does in
            // the band, so the lens row and the chips above it keep their place under the finger.
            if !isStacking, !modeRowInBand {
                CarouselSlot(model: model)
                    .transition(.opacity)
            }

            if modeRowInBand {
                ShutterRow(model: model)
                    .padding(.top, max(0, lensGap - 6))
            } else {
                BottomRow(model: model, flight: flight)
            }
        }
        .padding(.bottom, modeRowInBand ? 0 : 4)
        .frame(maxWidth: .infinity)
        // The gaps between the controls let a touch through to the picture. With the quick settings open a tap there
        // is meant to close them, as it does above the controls (DrawerLayer), and not to move the focus behind
        // the panel. The controls in front keep their own touches.
        .background {
            if model.isDrawerOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.spring) { model.isDrawerOpen = false }
                    }
                    .accessibilityHidden(true)
            }
        }
        // VoiceOver's two-finger scrub closes an open dial from whichever control has the focus: the lens row's
        // chips open dials too, and have no escape of their own.
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            guard model.activeDial != nil else { return }
            Haptics.tick()
            withAnimation(Theme.spring) { model.activeDial = nil }
        }
        // The zone is offered the whole screen height. Sizing it to what its rows ideally need keeps a row that
        // fills whatever it is given (a horizontal ScrollView does) from stretching it over the viewfinder. The
        // rows bring their own glass or shadow where they sit on the picture: a scrim behind them would darken the
        // bottom of the photo frame and make it look shorter than the photo.
        .fixedSize(horizontal: false, vertical: true)
        .animation(Theme.spring, value: dial)
        .animation(Theme.spring, value: mode)
        .animation(Theme.spring, value: isStacking)
        // The stack with a dial on top reaches up into the open quick settings panel: on a phone without the band
        // with any dial, and on the others in a long exposure scene, where NIGHT's row stays under the dial, or with
        // the white balance dial's row of presets. So the two take turns on every phone: opening one closes the
        // other.
        .onChange(of: dial) { _, opened in
            guard opened != nil, model.isDrawerOpen else { return }
            withAnimation(Theme.spring) { model.isDrawerOpen = false }
        }
        .onChange(of: model.isDrawerOpen) { _, isOpen in
            guard isOpen, model.activeDial != nil else { return }
            withAnimation(Theme.spring) { model.activeDial = nil }
        }
    }
}

/// The controls each mode adds above the lens row. The manual chips sit directly over the lens buttons in every mode
/// that has them, with the mode's own row above.
private struct ModePanels: View {
    let model: CameraModel
    let mode: CaptureMode
    /// False while the quick settings panel is open on a phone without the band, where it reaches down to the
    /// mode's own row.
    let hasRoom: Bool
    let dialOpen: Bool
    let isRecording: Bool

    var body: some View {
        VStack(spacing: 6) {
            switch mode {
            case .manual:
                ManualControlStrip(model: model)
            case .night, .long:
                // One row, so it stays under an open dial: the frames can be read while the duration is turned.
                if hasRoom {
                    NightModePanel(model: model)
                }
                // Manual night takes ISO, aperture, white balance and focus by hand. The night shot and the scenes
                // set their own, so they show what they chose, on PHOTO's readout line.
                if mode == .long, model.settings.longExposure.scene == .custom {
                    ManualControlStrip(model: model)
                } else if model.settings.display.showReadout {
                    NightReadout(model: model)
                        .frame(height: 44)
                } else if NightReadout.opensFocusDial(model) {
                    // Without the line these scenes would have no way into the focus dial, and so none to the
                    // magnifier.
                    SceneFocusChip(model: model)
                        .frame(height: 44)
                }
            case .video:
                // An open dial folds VIDEO's row of format chips away to keep the stack short.
                if hasRoom, !dialOpen {
                    // A format change mid-recording would reconfigure the session under the movie file.
                    VideoControls(model: model)
                        .disabled(isRecording)
                        .opacity(isRecording ? Theme.Dim.held : 1)
                }
                ManualControlStrip(model: model)
            case .photo:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The readout line of the night shot and the scenes. In the scenes that hold the focus at the far end (Stars, Star
/// trails, Northern lights, Fireworks) a tap on it opens the focus dial, which has no chip there while the line
/// shows: the far end of the lens is not always sharp at infinity, and the dial's magnifier shows whether the stars
/// are points before a long shot.
private struct NightReadout: View {
    let model: CameraModel

    var body: some View {
        if Self.opensFocusDial(model) {
            Button {
                // As a chip opens its dial: a tick, and a second tap closes it again.
                Haptics.tick()
                withAnimation(Theme.spring) {
                    model.activeDial = model.activeDial == .focus ? nil : .focus
                }
            } label: {
                // The line is shorter than a finger: the button takes 44 pt round it.
                ReadoutHUD(model: model, opensFocusDial: true)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the focus dial.")
        } else {
            ReadoutHUD(model: model)
        }
    }

    /// Also decides where the focus chip stands in for the line while the readout is switched off (ModePanels).
    static func opensFocusDial(_ model: CameraModel) -> Bool {
        model.sceneRecipe?.focusAtInfinity == true && model.capabilities.supportsManualFocus
    }
}

/// Manual night's focus chip on its own, for the scenes whose way into the focus dial and its magnifier is the
/// readout line: it takes the line's row while Settings has the readout off.
private struct SceneFocusChip: View {
    let model: CameraModel

    var body: some View {
        let activity = model.activity
        // The strip's face, not the lens row's compact one: that shows the value alone, and a bare "100%" says
        // nothing of focus.
        ParameterChip(model: model, kind: .focus, isSelected: model.activeDial == .focus)
            // In the strip the chips share out its width. On its own the chip keeps to its text.
            .fixedSize(horizontal: true, vertical: false)
            // Locked with the dial it opens, its touch and hold menu included, as the strip's chips are while a shot
            // runs or saves.
            .disabled(activity == .capturing || activity == .stacking || activity == .saving)
            .opacity(activity == .saving ? Theme.Dim.held : 1)
    }
}

private struct CarouselSlot: View {
    let model: CameraModel

    var body: some View {
        let activity = model.activity
        // A stack hides it like filming does. In the band the thumbnail and the flip button hide then too, and the
        // titles would be left there on their own, offering modes nothing can switch to.
        let isHidden = activity == .recording || activity == .stacking
        // The model is idle between intervalometer shots, but each shot is taken in the current mode: a switch to
        // VIDEO there would leave the rest of the sequence taking nothing. A bracket runs as long, so it dims too.
        let sequenceRunning = model.intervalometer != nil || model.bracketInProgress
        ModeCarousel(
            // NIGHT stands for the night shot and the long exposure scenes, and comes back to the one used last.
            mode: Binding(
                get: { model.settings.mode.carouselMode },
                set: { model.selectCarouselMode($0) }
            ),
            modes: model.availableModes
        )
        // Hidden but still laid out, so the controls around it don't jump when recording starts.
        .opacity(isHidden ? 0 : (activity.isCountdown || sequenceRunning ? Theme.Dim.held : 1))
        .animation(Theme.snappy, value: activity.isCountdown || sequenceRunning)
        // Photos still being saved keep the session as it is. Not dimmed for them, which would blink after each shot.
        .disabled(activity.isBusy || sequenceRunning || model.photosInFlight > 0)
        .accessibilityHidden(isHidden)
        // Fades with the thumbnail and the flip button beside it.
        .animation(Theme.fade, value: isHidden)
    }
}

/// The row in the band under the frame: the thumbnail, the modes between, the flip button. Left-handed, the flip
/// button and the thumbnail trade places.
private struct ModeRow: View {
    let model: CameraModel
    let flight: CaptureFlight

    var body: some View {
        let leftHanded = AppearanceStore.shared.leftHanded
        HStack(spacing: 8) {
            if leftHanded {
                FlipButton(model: model)
            } else {
                ThumbnailButton(model: model, flight: flight)
            }
            CarouselSlot(model: model)
            if leftHanded {
                ThumbnailButton(model: model, flight: flight)
            } else {
                FlipButton(model: model)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        // The dial sits above the shutter while these stay; VoiceOver's two-finger scrub closes it from here too.
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            guard model.activeDial != nil else { return }
            Haptics.tick()
            withAnimation(Theme.spring) { model.activeDial = nil }
        }
    }
}

/// The shutter, with macro or NIGHT's scene menu on its left and quick settings on its right, as in Apple's Camera,
/// when the thumbnail and the flip button have the mode row.
private struct ShutterRow: View {
    let model: CameraModel

    var body: some View {
        let busy = model.activity.isBusy
        let drawerHeld = CameraLayout.keepsDrawerClosed(model)
        ZStack {
            HStack(spacing: 0) {
                // Left of the shutter: NIGHT's scenes in NIGHT, macro in PHOTO and MANUAL, nothing in VIDEO.
                if model.settings.mode.usesStacking {
                    SceneSideButton(model: model)
                        .disabled(busy)
                        .opacity(busy ? Theme.Dim.held : 1)
                        // On each button, not the row: the shutter between them has its own spring.
                        .animation(Theme.snappy, value: busy)
                } else if model.macroOffered {
                    ShutterSideButton(symbol: "camera.macro", isActive: model.isMacro,
                                      label: model.isMacro ? "Macro, on" : "Macro") {
                        model.toggleMacro()
                    }
                    .disabled(busy)
                    .opacity(busy ? Theme.Dim.held : 1)
                    .animation(Theme.snappy, value: busy)
                } else {
                    Color.clear.frame(width: ShutterSideButton.standardSize)
                }
                Spacer(minLength: 0)
                ShutterSideButton(symbol: "circle.grid.3x3.fill", isActive: model.isDrawerOpen,
                                  label: model.isDrawerOpen ? "Hide quick settings" : "Show quick settings") {
                    withAnimation(Theme.spring) { model.isDrawerOpen.toggle() }
                }
                .disabled(drawerHeld)
                .opacity(drawerHeld ? Theme.Dim.held : 1)
                .animation(Theme.snappy, value: drawerHeld)
            }
            .padding(.horizontal, 36)
            ShutterSlot(model: model)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.shutterSize + 8)
    }
}

/// A round button beside the shutter. Lit in the accent while its feature is on.
private struct ShutterSideButton: View {
    static let standardSize: CGFloat = 50

    let symbol: String
    let isActive: Bool
    let label: String
    var size: CGFloat = ShutterSideButton.standardSize
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ShutterSideFace(image: Image(systemName: symbol), isActive: isActive, size: size)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(Text(label))
    }
}

/// The look of a round button beside the shutter: a glass circle. While its feature is on the glass takes a tint
/// of the accent and the glyph glows in it, which says "on" without a ring drawn round the glass.
private struct ShutterSideFace: View {
    let image: Image
    let isActive: Bool
    let size: CGFloat

    var body: some View {
        image
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .accentGlow(isActive)
            .frame(width: size, height: size)
            .cameraGlass(in: Circle(), tint: isActive ? Theme.accent.opacity(0.22) : nil)
            .contentShape(Circle())
            .animation(Theme.snappy, value: isActive)
    }
}

/// NIGHT's button left of the shutter, in the place macro has in PHOTO and MANUAL: the scene the shot uses, by its
/// symbol, and a tap lists them all. Lit like macro when it is on, since a scene is always in force here. The menu is
/// a layer over the face, as the bar's are: NIGHT's dial writes the settings while this shows, and a menu built here
/// would rebuild the system's menu button with each write.
private struct SceneSideButton: View {
    let model: CameraModel
    var size: CGFloat = ShutterSideButton.standardSize

    @State private var press = PressTracker()

    var body: some View {
        // nil is the night shot.
        let scene: LongExposureScene? = model.settings.mode == .long ? model.settings.longExposure.scene : nil
        let symbol: Image = scene.map { SceneSymbols.image(for: $0) } ?? Image(systemName: NightText.nightSymbol)
        ShutterSideFace(image: symbol, isActive: true, size: size)
            .scaleEffect(press.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: press.isPressed)
            // The menu over the face is what VoiceOver reads and opens.
            .accessibilityHidden(true)
            .overlay {
                SceneMenuLayer(model: model, press: press, value: NightText.title(scene),
                               hint: (scene?.tip ?? NightText.nightDetail) + " Shows the other scenes.")
            }
    }
}

/// The scene menu over the button. Its inputs compare equal until the scene changes, so a dial's writes leave the
/// system's menu button alone.
private struct SceneMenuLayer: View {
    let model: CameraModel
    let press: PressTracker
    let value: String
    let hint: String

    var body: some View {
        // In the list's order whichever way the menu opens (the layer keeps it fixed): the night shot first.
        MenuOnTapLayer(press: press, label: "Scene", value: value, hint: hint) {
            SceneMenuRows(model: model)
        }
    }
}

/// Reads the scene in its own body, so the rows follow it and the menu button doesn't.
private struct SceneMenuRows: View {
    let model: CameraModel

    var body: some View {
        NightSceneMenuItems(model: model,
                            scene: model.settings.mode == .long ? model.settings.longExposure.scene : nil)
    }
}

/// The thumbnail, the shutter and the flip button in one row, when there is no band for a mode row of their own.
private struct BottomRow: View {
    let model: CameraModel
    let flight: CaptureFlight

    var body: some View {
        let leftHanded = AppearanceStore.shared.leftHanded
        let busy = model.activity.isBusy
        let drawerHeld = CameraLayout.keepsDrawerClosed(model)
        ZStack {
            // Macro, or NIGHT's scenes, and the quick settings sit between the outer buttons and the shutter, as
            // they flank the shutter on a phone with a band: without them this phone would have no way to them.
            HStack(spacing: 6) {
                if leftHanded {
                    FlipButton(model: model)
                } else {
                    ThumbnailButton(model: model, flight: flight)
                }
                if model.settings.mode.usesStacking {
                    SceneSideButton(model: model, size: 44)
                        .disabled(busy)
                        .opacity(busy ? Theme.Dim.held : 1)
                        // On each button, not the row: the shutter between them has its own spring.
                        .animation(Theme.snappy, value: busy)
                } else if model.macroOffered {
                    ShutterSideButton(symbol: "camera.macro", isActive: model.isMacro,
                                      label: model.isMacro ? "Macro, on" : "Macro", size: 44) {
                        model.toggleMacro()
                    }
                    .disabled(busy)
                    .opacity(busy ? Theme.Dim.held : 1)
                    .animation(Theme.snappy, value: busy)
                }
                Spacer(minLength: 0)
                ShutterSideButton(symbol: "circle.grid.3x3.fill", isActive: model.isDrawerOpen,
                                  label: model.isDrawerOpen ? "Hide quick settings" : "Show quick settings", size: 44) {
                    withAnimation(Theme.spring) { model.isDrawerOpen.toggle() }
                }
                .disabled(drawerHeld)
                .opacity(drawerHeld ? Theme.Dim.held : 1)
                .animation(Theme.snappy, value: drawerHeld)
                if leftHanded {
                    ThumbnailButton(model: model, flight: flight)
                } else {
                    FlipButton(model: model)
                }
            }
            .padding(.horizontal, 16)
            ShutterSlot(model: model)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.shutterSize + 8)
    }
}

/// Isolated so stack progress (several updates a second) redraws only the shutter.
private struct ShutterSlot: View {
    let model: CameraModel

    var body: some View {
        let mode = model.settings.mode
        let activity = model.activity
        let isBulb = mode == .long && model.settings.longExposure.bulb
        ShutterButton(
            style: Self.style(mode: mode, activity: activity, progress: model.stackProgress?.fraction ?? 0,
                              sequenceRunning: model.intervalometer != nil || model.bracketInProgress),
            // While busy the shutter is how you stop, so it stays live.
            isEnabled: model.canCapture || activity.isBusy || model.intervalometer != nil,
            // A press the model would ignore gets no click, so the shutter is never felt to fire without firing.
            acceptsPress: model.shutterAcceptsPress,
            clicksOnPress: !model.isMagnified,
            isDimmed: model.dimmer.isDimmed,
            action: { pressShutter(model) },
            onHoldBegan: isBulb ? { model.shutterHoldBegan() } : nil,
            onHoldEnded: isBulb ? { model.shutterHoldEnded() } : nil
        )
        .background {
            // At 16:9 the shutter sits on the picture. A dark rim outside its white ring keeps it apart from a bright
            // scene, as Apple's does; over the black band it can't be seen.
            Circle()
                .strokeBorder(Color.black.opacity(0.28), lineWidth: 2)
                .frame(width: Theme.shutterSize + 4, height: Theme.shutterSize + 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static func style(mode: CaptureMode, activity: CaptureActivity, progress: Double,
                              sequenceRunning: Bool) -> ShutterButton.Style {
        switch activity {
        case .recording:
            return .recording
        case .stacking:
            return .stacking(progress: progress.isFinite ? min(max(progress, 0), 1) : 0)
        case .countdown:
            return .countdown
        case .idle, .capturing, .saving:
            // Between intervalometer shots and through a focus or white balance bracket, the button reads as
            // "running, tap to stop".
            if sequenceRunning { return .sequence }
            switch mode {
            case .video: return .video
            case .night: return .night
            case .long: return .long
            case .photo, .manual: return .photo
            }
        }
    }
}

private struct FlipButton: View {
    let model: CameraModel
    @State private var turns = 0.0

    var body: some View {
        let hasFront = model.lenses.contains(where: { $0.isFront })
        let activity = model.activity
        let isHidden = activity == .recording || activity == .stacking
        Button {
            turns += 1
            model.flipCamera()
        } label: {
            Upright(model: model) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(turns * 180))
                    .animation(Theme.spring, value: turns)
            }
        }
        .buttonStyle(GlassCircleButtonStyle(size: 48))
        // A flip reconfigures the session, which waits for photos still being saved.
        .disabled(!hasFront || activity.isBusy || model.photosInFlight > 0)
        .opacity(isHidden ? 0 : (hasFront ? 1 : Theme.Dim.off))
        .allowsHitTesting(!isHidden)
        .animation(Theme.fade, value: isHidden)
        .accessibilityLabel("Switch camera")
    }
}

// MARK: - Capture flight

/// Draws the copy of a new shot on its way to the thumbnail (CaptureFlight). Reads the flight on its own, so a
/// launch redraws this layer and nothing else.
private struct CaptureFlightLayer: View {
    let flight: CaptureFlight
    /// The photo frame, where the copy sets off.
    let pictureFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shot = flight.shot, let target = flight.thumbnailFrame {
                FlyingShot(shot: shot, from: pictureFrame, to: target, flight: flight)
                    .id(shot.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The copy itself: the frame's size and place at the start, the thumbnail's at the end, on a critically damped
/// spring so it settles into the square without passing it. Its rim comes up as it nears the square's, so the
/// copy turns into the thumbnail rather than landing on it.
private struct FlyingShot: View {
    let shot: CaptureFlight.Shot
    let from: CGRect
    let to: CGRect
    let flight: CaptureFlight
    @State private var landed = false
    @State private var visible = false

    var body: some View {
        let rect = landed ? to : from
        // The thumbnail shows the photo turned with the phone. On its side the photo is as wide as the frame is
        // tall, so its box is laid out across and then turned into the frame.
        let quarter = Int((abs(shot.degrees) / 90).rounded())
        let sideways = quarter % 2 == 1
        let shape = RoundedRectangle(cornerRadius: landed ? 8 : 2, style: .continuous)
        Image(decorative: shot.image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: sideways ? rect.height : rect.width, height: sideways ? rect.width : rect.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(landed ? 0.85 : 0), lineWidth: 1))
            .rotationEffect(.degrees(shot.degrees))
            .position(x: rect.midX, y: rect.midY)
            .opacity(visible ? 1 : 0)
            .onAppear {
                // A short fade in, so the copy lifts off the picture instead of appearing over it.
                withAnimation(.easeOut(duration: 0.08)) { visible = true }
                withAnimation(Theme.flight) {
                    landed = true
                } completion: {
                    flight.land(shot.id)
                }
            }
    }
}

// MARK: - Helpers

/// Rotates its content with the phone. Reading motion here instead of in the parent keeps the 30 Hz attitude
/// updates from redrawing whole control rows.
private struct Upright<Content: View>: View {
    let model: CameraModel
    // Built once in init: a stored closure never compares equal, so SwiftUI could never skip this view.
    let content: Content

    init(model: CameraModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content.uprightRotation(model.motion.iconRotationDegrees)
    }
}

private extension CaptureActivity {
    var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }
}
