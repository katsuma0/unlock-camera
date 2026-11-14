import SwiftUI
import AVKit
// onCameraCaptureEvent lives in AVKit's SwiftUI overlay. Xcode loads it from the two imports above; naming it
// keeps the modifier visible to compilers that don't load cross-import overlays on their own.
import _AVKit_SwiftUI
import CameraCore

/// The whole camera: viewfinder, controls, mode carousel, shutter. The first launch starts with the welcome question.
struct CameraScreen: View {
    @Bindable var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The gallery is presented from the thumbnail (GalleryThumbnail.swift), which its zoom transition starts from.
        ZStack {
            Theme.background
                .ignoresSafeArea()
            ScreenContent(model: model)
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(model: model)
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

/// The welcome question, the camera or the permission page. Whether the question is still open is a setting, and
/// dials and pinches write the settings many times a second, so it is read here and not by the screen with its sheets.
private struct ScreenContent: View {
    let model: CameraModel

    var body: some View {
        let needsWelcome = model.needsWelcome
        ZStack {
            if needsWelcome {
                // Before the camera starts, so the permission prompt comes after the answer.
                WelcomeView(model: model)
                    .transition(.opacity)
            } else if model.authorization == .authorized {
                CameraLayout(model: model)
                    .transition(.opacity)
            } else {
                PermissionView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.authorization)
        .animation(.easeInOut(duration: 0.3), value: needsWelcome)
    }
}

// MARK: - Layout

/// The screen space every layer of the camera is laid out in: the whole screen, safe areas included.
private let cameraSpace = "camera"

/// The camera over the whole screen, in the order of Apple's iOS 26 Camera. The viewfinder covers the screen: the 16:9
/// region runs at full width from the safe area's top, the photo frame is the largest of its shape inside it, and the
/// bands around the frame turn from black to see-through once the picture is live. The top bar sits over the top of
/// the region. The lens buttons and the shutter sit inside the region's bottom, and the row with the thumbnail, the
/// modes and the flip button in the band under it, all anchored to the region, so nothing moves when the shape
/// changes. A phone with no band there (iPhone SE) stacks the controls up from the bottom edge in their earlier order.
private struct CameraLayout: View {
    let model: CameraModel

    /// The controls' top edge on screen, once measured. The open part of the frame ends there.
    @State private var controlsTop: CGFloat?
    @State private var veilVisible = false
    @State private var veilToken = 0
    @State private var veilHoldNanoseconds: UInt64 = 350_000_000
    /// A lens button is swapping cameras. Both cameras frame the same picture at the swap, so this veil is short.
    @State private var lensVeilVisible = false
    /// The drawer's timer sheet is up. It belongs to the drawer, so the drawer reports it as a preference.
    @State private var drawerSheetShown = false
    /// The top bar's timer badge asked for that sheet. The badge opens the drawer, and the drawer presents it.
    @State private var timerSheetRequested = false
    /// Gesture state shared by the picture, the sun above the bands and VoiceOver's viewfinder element.
    @State private var interaction = ViewfinderInteraction()
    /// Width over height of the camera image as the portrait preview shows it: measured from the preview layer while
    /// the camera runs, expected from the format until then.
    @State private var imageAspect = 3.0 / 4.0
    /// The bands are solid black. They turn see-through once the picture is live and has settled.
    @State private var bandsSolid = true

    @Environment(\.displayScale) private var displayScale

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
        let isVeiled = veilVisible || lensVeilVisible
        let aspectKey = AspectKey(mode: mode, video: settings.video, lensID: settings.lensID,
                                  isRunning: model.sessionState == .running,
                                  formatCount: model.capabilities.formats.count)

        GeometryReader { proxy in
            let size = proxy.size
            let insets = proxy.safeAreaInsets
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
                ViewfinderStack(model: model, interaction: interaction, geometry: geometry, veilVisible: isVeiled,
                                bandsSolid: bandsSolid)

                DrawerLayer(model: model, catcherHeight: max(0, (controlsTop ?? size.height) - topBarBottom),
                            timerSheetRequested: $timerSheetRequested)
                    .padding(.top, topBarBottom)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)

                ControlsZone(model: model, modeRowInBand: placement.modeRowY != nil, lensGap: placement.lensGap)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(cameraSpace)).minY
                    } action: { top in
                        controlsTop = top
                    }
                    .frame(width: size.width, height: max(0, placement.zoneBottom), alignment: .bottom)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)

                if let modeRowY = placement.modeRowY {
                    ModeRow(model: model)
                        .frame(width: size.width, height: Self.modeRowHeight)
                        .position(x: size.width / 2, y: modeRowY)
                        .opacity(fullscreen ? 0 : 1)
                        .allowsHitTesting(!fullscreen)
                }

                // Drawn after the drawer so the drawer slides out from underneath it.
                TopBar(model: model, timerSheetRequested: $timerSheetRequested)
                    .frame(width: size.width)
                    .padding(.top, insets.top)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)

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
        .animation(.easeInOut(duration: 0.25), value: fullscreen)
        .modifier(HardwareButtons(model: model, isEnabled: hardwareButtonsEnabled))
        .onChange(of: mode) { oldMode, newMode in
            if let dial = model.activeDial, !Self.dialAllowed(dial, in: newMode, advanced: model.isAdvanced) {
                model.activeDial = nil
            }
            // Video needs a session reconfiguration, which takes longer than a photo mode change.
            let involvesVideo = oldMode == .video || newMode == .video
            showVeil(holdNanoseconds: involvesVideo ? 650_000_000 : 350_000_000)
        }
        .onChange(of: selectedIsFront) { _, _ in
            showVeil(holdNanoseconds: 450_000_000)
        }
        // Only a lens button's swap of cameras gets the veil: a pinch or the zoom wheel swaps while the finger is
        // still framing, and the picture holding still for a moment is less in the way than a blur.
        .task(id: model.isSwitchingLensVisibly) {
            if model.isSwitchingLensVisibly {
                withAnimation(.easeIn(duration: 0.08)) { lensVeilVisible = true }
                return
            }
            guard lensVeilVisible else { return }
            // A moment past the swap, while the new camera's first frames settle their exposure and colour.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { lensVeilVisible = false }
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
            // An open drawer would cover the Stop button and let settings change under a running shot. With its
            // timer sheet up it stays, since closing it would throw the sheet's edits away.
            guard model.isDrawerOpen, !drawerSheetShown, Self.closesDrawer(activity) else { return }
            withAnimation(Theme.spring) { model.isDrawerOpen = false }
        }
        .onChange(of: model.bracketInProgress) { _, running in
            // A bracket is a long capture with a Stop button too, though its activity is the brief .capturing
            // that a single photo passes through.
            guard running, model.isDrawerOpen, !drawerSheetShown else { return }
            withAnimation(Theme.spring) { model.isDrawerOpen = false }
        }
        .onPreferenceChange(QuickSettingsSheetKey.self) { shown in
            drawerSheetShown = shown
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
            && !model.isSettingsPresented && !model.isReviewPresented && !drawerSheetShown
    }

    private static func closesDrawer(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .countdown, .stacking, .recording: return true
        case .idle, .capturing, .saving: return false
        }
    }

    private func showVeil(holdNanoseconds: UInt64) {
        // A flip asks twice in one update (lens switch and selfie change); the longer hold wins in either order.
        veilHoldNanoseconds = veilVisible ? max(veilHoldNanoseconds, holdNanoseconds) : holdNanoseconds
        veilVisible = true
        veilToken &+= 1
    }

    /// Dials that make sense in each mode. A shutter or ISO dial left open from MANUAL would switch PHOTO back to
    /// MANUAL with the first tick, so it closes instead. The simple interface has no strip in any mode: its dials
    /// are the two its lens row opens, brightness and zoom.
    static func dialAllowed(_ dial: DialKind, in mode: CaptureMode, advanced: Bool) -> Bool {
        guard advanced else { return dial == .bias || dial == .zoom }
        switch mode {
        case .photo, .night: return dial == .bias || dial == .zoom
        case .manual, .long, .video: return true
        }
    }

    // MARK: Image shape

    /// What the picture rect is built from. A new format can change the image's shape: a mode, lens or video format
    /// change, or the camera starting with formats it hadn't listed yet.
    private struct AspectKey: Equatable {
        var mode: CaptureMode
        var video: VideoSettings
        var lensID: String?
        var isRunning: Bool
        var formatCount: Int
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
        let measured = model.sessionState == .running ? Self.measuredAspect(of: model.backend) : nil
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
/// the capture blink, the bands, then the furniture (grid, level, focus square and sun, badges, status, toasts).
/// Everything above the picture leaves touches to the picture's gesture recognizers, except Stop and Cancel.
private struct ViewfinderStack: View {
    let model: CameraModel
    let interaction: ViewfinderInteraction
    let geometry: ViewfinderGeometry
    let veilVisible: Bool
    let bandsSolid: Bool

    /// How far the furniture at the top of the frame moves down to clear the steady status while it shows there.
    @State private var bannerShift: CGFloat = 0

    var body: some View {
        let frame = geometry.frame
        let open = geometry.open
        ZStack(alignment: .topLeading) {
            Theme.background
            CameraPreviewView(model: model, interaction: interaction, geometry: geometry,
                              isHidden: model.dimmer.isDimmed)
            StackPreviewLayer(model: model, picture: geometry.picture)
            ModeSwitchVeil(isVisible: veilVisible)
            ShutterBlink(model: model)
            FrameBands(frame: frame, solid: bandsSolid)
            DriftCrosshair(model: model, imageDiagonal: geometry.pictureDiagonal)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            // Countdown, status and Stop sit in the part of the frame the top bar and the controls leave open.
            CaptureOverlay(model: model)
                .frame(width: max(open.width, 1), height: max(open.height, 1))
                .position(x: open.midX, y: open.midY)
                .animation(Theme.spring, value: open)
            ViewfinderOverlays(model: model, geometry: geometry, topShift: bannerShift)
            ExposureSliderLayer(model: model, interaction: interaction, geometry: geometry)
            HistogramSlot(model: model, open: open, topShift: bannerShift)
            ReadoutSlot(model: model, open: open)
            SteadyStatusPlacement(model: model, open: open, shift: $bannerShift)
            ToastLayer(model: model, open: open, topShift: bannerShift)
            SessionStatusLayer(model: model, open: open)
            ViewfinderAccessibilityTarget(model: model, interaction: interaction, rect: open)
        }
        .frame(width: geometry.screen.width, height: geometry.screen.height, alignment: .topLeading)
        .clipped()
    }
}

/// The Camera app blurs the preview while it changes modes; a backdrop material blurs the live layer underneath.
private struct ModeSwitchVeil: View {
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .overlay(Theme.background.opacity(0.2))
            .environment(\.colorScheme, .dark)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Reads the analysis frame on its own, so 12 histograms a second redraw only this corner.
private struct HistogramSlot: View {
    let model: CameraModel
    let open: CGRect
    let topShift: CGFloat

    var body: some View {
        let style = model.settings.display.histogram
        ZStack(alignment: .topLeading) {
            if style != .off, let histogram = model.analysis?.histogram {
                HistogramView(histogram: histogram, style: style)
                    .frame(width: 120, height: 60)
                    .padding(.leading, 12)
                    .padding(.top, 12 + topShift)
                    .transition(.opacity)
            }
        }
        .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: .topLeading)
        .position(x: open.midX, y: open.midY)
        .animation(Theme.spring, value: topShift)
        .allowsHitTesting(false)
    }
}

private struct ReadoutSlot: View {
    let model: CameraModel
    let open: CGRect

    var body: some View {
        // ReadoutHUD keeps its own margin; this keeps it clear of the controls under the frame.
        if model.settings.display.showReadout {
            ReadoutHUD(model: model)
                .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: .bottom)
                .position(x: open.midX, y: open.midY)
                .animation(Theme.spring, value: open)
        }
    }
}

/// Puts the tripod and hold-still status 12 pt down from the top of the open part of the frame, as wide as the frame
/// shows. The banner turns itself to the person's top when the phone is on its side, and has no height while hidden.
/// Its height tells the furniture at the top of the frame how far to move down to clear it.
private struct SteadyStatusPlacement: View {
    let model: CameraModel
    let open: CGRect
    @Binding var shift: CGFloat

    private static let margin: CGFloat = 12

    var body: some View {
        SteadyBanner(model: model)
            .frame(width: max(open.width, 0))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                let value = height > 1 ? height + 8 : 0
                if shift != value { shift = value }
            }
            .padding(.top, Self.margin)
            .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: .top)
            .position(x: open.midX, y: open.midY)
            .allowsHitTesting(false)
    }
}

private struct ToastLayer: View {
    let model: CameraModel
    /// The open part of the frame. A toast sits under the corner furniture in it, or in its middle when turned.
    let open: CGRect
    /// How far the corner furniture moved down for the steady status.
    let topShift: CGFloat
    /// A toast that repeated the status card when it arrived. Remembered, so it doesn't pop up late when the
    /// camera resumes before the toast would have expired.
    @State private var repeatedToastID: UUID?

    var body: some View {
        let toast = model.toast.flatMap { toast in
            toast.id == repeatedToastID || Self.repeatsStatus(toast, sessionState: model.sessionState) ? nil : toast
        }
        // Below the corner furniture: the histogram on the left and the status badges on the right end around
        // 70 pt down, and a long message spans the width between them.
        let topInset: CGFloat = 84 + topShift
        // Read even with no toast up, so a message never changes place or angle while it fades out.
        let motion = model.motion
        // Turned sideways, a message runs along the frame's long side, so it moves to the middle like the stack
        // status; the slot under the corner furniture is too short for it.
        let sideways = motion.quarterTurns % 2 != 0
        // The capsule is laid out before it turns, so its width ends up along the open part's height, less a margin
        // at each end, with a third line for what no longer fits on two.
        let sidewaysWidth = max(open.height - 32, 160)
        ZStack {
            if let toast {
                ToastCapsule(toast: toast, lineLimit: sideways ? 3 : 2)
                    .frame(maxWidth: sideways ? sidewaysWidth : nil)
                    .uprightRotation(motion.iconRotationDegrees)
                    .id(toast.id)
                    .transition(sideways ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, sideways ? 0 : topInset)
        .padding(.horizontal, 16)
        .frame(width: max(open.width, 0), height: max(open.height, 0), alignment: sideways ? .center : .top)
        .position(x: open.midX, y: open.midY)
        .animation(Theme.spring, value: toast?.id)
        .animation(Theme.spring, value: sideways)
        .animation(Theme.spring, value: topShift)
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
            if let symbol = toast.symbol {
                Image(systemName: symbol)
            }
            Text(toast.message)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
        }
        .font(.system(size: 13, weight: .semibold))
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
        .animation(.easeInOut(duration: 0.25), value: model.sessionState)
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
    /// From the top bar's bottom edge to the controls' top: a tap there closes the drawer.
    let catcherHeight: CGFloat
    @Binding var timerSheetRequested: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

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
                    .padding(.top, 6)
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
    /// The thumbnail, the modes and the flip button have a row of their own in the band under the frame (ModeRow).
    /// Without a band (iPhone SE) the thumbnail and the flip button flank the shutter and the modes sit above it.
    let modeRowInBand: Bool
    /// Space between the lens buttons and the shutter row when nothing sits between them.
    let lensGap: CGFloat

    var body: some View {
        let mode = model.settings.mode
        let dial = model.activeDial
        let activity = model.activity
        let isStacking = activity == .stacking
        let isRecording = activity == .recording
        let advanced = model.isAdvanced
        let showsPanel = Self.hasPanel(mode: mode, dialOpen: dial != nil, advanced: advanced)
        // An exposure dial makes the stack tall enough to cover a good part of the picture on 6.1" phones, so the
        // lens buttons step aside for it. The zoom dial belongs with them, and the EV chip of PHOTO and NIGHT lives
        // in that row. So does the simple interface's brightness chip in every mode, and the panel steps aside there.
        let showsLensRow = dial == nil || dial == .zoom || mode == .photo || mode == .night || !advanced
        // With nothing between them, the lens buttons keep the distance Apple's keep from the shutter.
        let lensAboveShutter = showsLensRow && (isStacking || (!showsPanel && dial == nil))

        VStack(spacing: 6) {
            if showsLensRow {
                LensRow(model: model)
                    .disabled(isStacking)
                    .opacity(isStacking ? 0.35 : 1)
                    .transition(.opacity)
            }

            // A stack can't change mid-capture, so its panels fold away and the progress has the screen.
            if !isStacking {
                if showsPanel {
                    ModePanels(model: model, mode: mode, advanced: advanced, showsSecondary: dial == nil,
                               isRecording: isRecording)
                        .id(mode)
                        .transition(.opacity)
                }
                // The dial sits above the shutter, like the Camera app's exposure dial. Without a band for the mode
                // row it takes the carousel's place.
                if dial != nil {
                    ActiveDialView(model: model)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if !modeRowInBand {
                    CarouselSlot(model: model)
                        .transition(.opacity)
                }
            }

            if modeRowInBand {
                ShutterRow(model: model)
                    .padding(.top, lensAboveShutter ? max(0, lensGap - 6) : 4)
            } else {
                BottomRow(model: model)
            }
        }
        .padding(.bottom, modeRowInBand ? 0 : 4)
        .frame(maxWidth: .infinity)
        // VoiceOver's two-finger scrub closes an open dial from whichever control has the focus: the lens row and
        // the brightness chip open dials too, and have no escape of their own.
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
        .animation(Theme.spring, value: advanced)
    }

    /// The advanced interface keeps its manual strip under an open dial. The simple one has no strip: its LONG
    /// panel is the scene picker, which makes room for a dial as NIGHT's panel does, and its VIDEO has no panel.
    private static func hasPanel(mode: CaptureMode, dialOpen: Bool, advanced: Bool) -> Bool {
        switch mode {
        case .manual, .video: return advanced
        case .long: return advanced || !dialOpen
        case .night: return !dialOpen
        case .photo: return false
        }
    }
}

/// The controls each mode adds between the lens row and the shutter. The manual strip and the video panel are the
/// advanced interface's; NightControls and LongExposureControls switch to their simple layout themselves.
private struct ModePanels: View {
    let model: CameraModel
    let mode: CaptureMode
    let advanced: Bool
    let showsSecondary: Bool
    let isRecording: Bool

    var body: some View {
        VStack(spacing: 6) {
            switch mode {
            case .manual:
                if advanced {
                    ManualControlStrip(model: model)
                }
            case .long:
                // The simple interface picks a scene and its time; the values on the strip follow the scene.
                if advanced {
                    ManualControlStrip(model: model)
                }
                if showsSecondary {
                    LongExposureControls(model: model)
                }
            case .video:
                // The simple interface films on automatic, with the format chip in the top bar.
                if advanced {
                    ManualControlStrip(model: model)
                    if showsSecondary {
                        // A format change mid-recording would reconfigure the session under the movie file.
                        VideoControls(model: model)
                            .disabled(isRecording)
                            .opacity(isRecording ? 0.35 : 1)
                    }
                }
            case .night:
                if showsSecondary {
                    NightControls(model: model)
                }
            case .photo:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CarouselSlot: View {
    let model: CameraModel

    var body: some View {
        let activity = model.activity
        let isRecording = activity == .recording
        // The model is idle between intervalometer shots, but each shot is taken in the current mode: a switch to
        // VIDEO there would leave the rest of the sequence taking nothing. A bracket runs as long, so it dims too.
        let sequenceRunning = model.intervalometer != nil || model.bracketInProgress
        ModeCarousel(
            mode: Binding(
                get: { model.settings.mode },
                set: { model.setMode($0) }
            ),
            // The simple interface leaves MANUAL out.
            modes: model.availableModes
        )
        // Hidden but still laid out while filming, so the controls around it don't jump when recording starts.
        .opacity(isRecording ? 0 : (activity.isCountdown || sequenceRunning ? 0.35 : 1))
        // Photos still being saved keep the session as it is. Not dimmed for them, which would blink after each shot.
        .disabled(activity.isBusy || sequenceRunning || model.photosInFlight > 0)
        .accessibilityHidden(isRecording)
    }
}

/// The row in the band under the frame: the thumbnail, the modes between, the flip button. Left-handed, the flip
/// button and the thumbnail trade places.
private struct ModeRow: View {
    let model: CameraModel

    var body: some View {
        let leftHanded = AppearanceStore.shared.leftHanded
        HStack(spacing: 8) {
            if leftHanded {
                FlipButton(model: model)
            } else {
                ThumbnailButton(model: model)
            }
            CarouselSlot(model: model)
            if leftHanded {
                ThumbnailButton(model: model)
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

/// The shutter alone, when the thumbnail and the flip button have the mode row.
private struct ShutterRow: View {
    let model: CameraModel

    var body: some View {
        ShutterSlot(model: model)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.shutterSize + 8)
    }
}

/// The thumbnail, the shutter and the flip button in one row, when there is no band for a mode row of their own.
private struct BottomRow: View {
    let model: CameraModel

    var body: some View {
        let leftHanded = AppearanceStore.shared.leftHanded
        ZStack {
            HStack(spacing: 0) {
                if leftHanded {
                    FlipButton(model: model)
                } else {
                    ThumbnailButton(model: model)
                }
                Spacer(minLength: 0)
                if leftHanded {
                    ThumbnailButton(model: model)
                } else {
                    FlipButton(model: model)
                }
            }
            .padding(.horizontal, 30)
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
        .opacity(isHidden ? 0 : (hasFront ? 1 : 0.35))
        .allowsHitTesting(!isHidden)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .accessibilityLabel("Switch camera")
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
