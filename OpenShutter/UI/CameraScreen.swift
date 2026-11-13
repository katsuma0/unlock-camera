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

/// Top bar, a 3:4 viewfinder under it and the controls anchored to the bottom. On shorter phones the controls
/// rise over the bottom of the viewfinder (behind a scrim) instead of shrinking the preview.
private struct CameraLayout: View {
    let model: CameraModel

    @State private var controlsHeight: CGFloat = 0
    @State private var veilVisible = false
    @State private var veilToken = 0
    @State private var veilHoldNanoseconds: UInt64 = 350_000_000
    /// The drawer's timer sheet is up. It belongs to the drawer, so the drawer reports it as a preference.
    @State private var drawerSheetShown = false
    /// The top bar's timer badge asked for that sheet. The badge opens the drawer, and the drawer presents it.
    @State private var timerSheetRequested = false

    static let topBarHeight: CGFloat = 48

    var body: some View {
        let mode = model.settings.mode
        let fullscreen = model.controlsFullscreen
        let selectedIsFront = model.lenses.first(where: { $0.id == model.settings.lensID })?.isFront ?? false

        GeometryReader { proxy in
            let width = proxy.size.width
            let viewfinderHeight = (width * 4 / 3).rounded()
            let freeBelow = max(0, proxy.size.height - Self.topBarHeight - viewfinderHeight)
            let overlap = min(max(0, controlsHeight - freeBelow), viewfinderHeight)

            ZStack(alignment: .top) {
                ViewfinderStack(model: model, bottomInset: overlap, veilVisible: veilVisible)
                    .frame(width: width, height: viewfinderHeight)
                    .padding(.top, Self.topBarHeight)

                DrawerLayer(model: model, viewfinderHeight: viewfinderHeight, timerSheetRequested: $timerSheetRequested)
                    .padding(.top, Self.topBarHeight)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)

                ControlsZone(model: model)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        controlsHeight = height
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)

                // Drawn last so the drawer slides out from underneath it.
                TopBar(model: model, timerSheetRequested: $timerSheetRequested)
                    .opacity(fullscreen ? 0 : 1)
                    .allowsHitTesting(!fullscreen)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
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
        // Only a swap of cameras freezes the preview: a lens tap the model refuses, or a pinch, never gets here.
        .onChange(of: model.lensSwitchCount) { _, _ in
            showVeil(holdNanoseconds: 350_000_000)
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
}

// MARK: - Viewfinder

private struct ViewfinderStack: View {
    let model: CameraModel
    /// How much of the viewfinder's bottom the controls cover, so the readout stays visible above them.
    let bottomInset: CGFloat
    let veilVisible: Bool

    var body: some View {
        ZStack {
            CameraPreviewView(model: model)
            ModeSwitchVeil(isVisible: veilVisible)
            CaptureOverlay(model: model)
                // Countdown, status and Stop sit in the part of the picture the controls leave uncovered; the
                // stack preview and the flash ignore this inset and still cover the whole frame.
                .safeAreaPadding(.bottom, bottomInset)
                .animation(Theme.spring, value: bottomInset)
            // Display only; without this the full-frame canvas would swallow tap to focus.
            ViewfinderOverlays(model: model)
                .allowsHitTesting(false)
            HistogramSlot(model: model)
            ReadoutSlot(model: model, bottomInset: bottomInset)
            ToastLayer(model: model, bottomInset: bottomInset)
            SessionStatusLayer(model: model)
        }
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

    var body: some View {
        let style = model.settings.display.histogram
        if style != .off, let histogram = model.analysis?.histogram {
            HistogramView(histogram: histogram, style: style)
                .frame(width: 120, height: 60)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
        }
    }
}

private struct ReadoutSlot: View {
    let model: CameraModel
    let bottomInset: CGFloat

    var body: some View {
        // ReadoutHUD keeps its own margin; this only lifts it clear of controls that rise over the picture.
        if model.settings.display.showReadout {
            ReadoutHUD(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, bottomInset)
                .animation(Theme.spring, value: bottomInset)
        }
    }
}

private struct ToastLayer: View {
    let model: CameraModel
    /// How much of the viewfinder's bottom the controls cover; a sideways toast sits in the middle of the rest.
    let bottomInset: CGFloat
    /// A toast that repeated the status card when it arrived. Remembered, so it doesn't pop up late when the
    /// camera resumes before the toast would have expired.
    @State private var repeatedToastID: UUID?
    /// The viewfinder's height, which a sideways message runs along.
    @State private var viewfinderHeight: CGFloat = 0

    var body: some View {
        let toast = model.toast.flatMap { toast in
            toast.id == repeatedToastID || Self.repeatsStatus(toast, sessionState: model.sessionState) ? nil : toast
        }
        // Below the corner furniture: the histogram on the left and the status badges on the right end around
        // 70 pt down, and a long message spans the width between them.
        let topInset: CGFloat = 84
        // Read even with no toast up, so a message never changes place or angle while it fades out.
        let motion = model.motion
        // Turned sideways, a message runs along the viewfinder's long side, so it moves to the middle like the
        // stack status; the slot under the corner furniture is too short for it.
        let sideways = motion.quarterTurns % 2 != 0
        // The capsule is laid out before it turns, so its width ends up along the viewfinder's height. On small
        // phones the controls cover much of that, so it gets only the part they leave, less a margin at each end,
        // and a third line for what no longer fits on two.
        let sidewaysWidth = max(viewfinderHeight - bottomInset - 32, 160)
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
        .padding(.bottom, sideways ? bottomInset : 0)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sideways ? .center : .top)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            viewfinderHeight = height
        }
        .animation(Theme.spring, value: toast?.id)
        .animation(Theme.spring, value: sideways)
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

    var body: some View {
        ZStack {
            switch model.sessionState {
            case .interrupted(let reason):
                StatusCard(symbol: "video.slash", title: "Camera paused", detail: reason)
                    .transition(.opacity)
            case .failed(let reason):
                StatusCard(symbol: "exclamationmark.triangle", title: "Camera unavailable", detail: reason)
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

    var body: some View {
        ZStack {
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
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Drawer

private struct DrawerLayer: View {
    let model: CameraModel
    let viewfinderHeight: CGFloat
    @Binding var timerSheetRequested: Bool

    var body: some View {
        let isOpen = model.isDrawerOpen
        ZStack(alignment: .top) {
            if isOpen {
                // A tap on the viewfinder closes the drawer instead of moving focus behind it.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: viewfinderHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.spring) { model.isDrawerOpen = false }
                    }
                    .accessibilityHidden(true)
                QuickSettingsDrawer(model: model, timerSheetRequested: $timerSheetRequested)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Clipping to the viewfinder makes the drawer appear from under the top bar.
        .clipped()
        .animation(Theme.spring, value: isOpen)
    }
}

// MARK: - Controls

private struct ControlsZone: View {
    let model: CameraModel

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
                // The dial takes the carousel's place, like the Camera app's exposure dial.
                if dial != nil {
                    ActiveDialView(model: model)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    CarouselSlot(model: model, activity: activity)
                        .transition(.opacity)
                }
            }

            BottomRow(model: model)
        }
        .padding(.bottom, 4)
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
        // fills whatever it is given (a horizontal ScrollView does) from stretching it over the viewfinder.
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) { ControlsScrim() }
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

/// Keeps controls readable where they rise over the preview; over the black area below it, it is invisible.
/// The fade spans the lens row, whose glass buttons read fine on their own, so a small overlap barely dims the
/// picture and the plain text of the panels further down gets the full scrim.
private struct ControlsScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Theme.background.opacity(0), Theme.background.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 52)
            Theme.background.opacity(0.65)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The controls each mode adds between the lens row and the carousel. The manual strip and the video panel are
/// the advanced interface's; NightControls and LongExposureControls switch to their simple layout themselves.
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
    let activity: CaptureActivity

    var body: some View {
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
        // Hidden but still laid out while filming, so the controls above don't jump when recording starts.
        .opacity(isRecording ? 0 : (activity.isCountdown || sequenceRunning ? 0.35 : 1))
        // Photos still being saved keep the session as it is. Not dimmed for them, which would blink after each shot.
        .disabled(activity.isBusy || sequenceRunning || model.photosInFlight > 0)
        .accessibilityHidden(isRecording)
    }
}

private struct BottomRow: View {
    let model: CameraModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ThumbnailButton(model: model)
                Spacer(minLength: 0)
                FlipButton(model: model)
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
