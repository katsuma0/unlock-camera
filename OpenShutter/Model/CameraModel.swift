import AVFoundation
import Foundation
import Observation
import Photos
import QuartzCore
import UIKit
import CameraCore

/// The app's single source of truth. Views read its state and call its intents; it turns user settings
/// into backend requests and runs capture sequences (timer, intervalometer, brackets, stacks, video).
@MainActor
@Observable
final class CameraModel {
    // MARK: - State the UI reads

    private(set) var settings: CameraSettings
    private(set) var authorization: CameraAuthorization = .notDetermined
    private(set) var sessionState: SessionState = .idle
    private(set) var capabilities: CameraCapabilities = .placeholder
    private(set) var readings: LiveReadings = .initial
    private(set) var analysis: AnalysisFrame? {
        // Written 12 times a second, so the flag that layout reads is only written when frames start or stop.
        didSet { if (analysis != nil) != hasAnalysisFrames { hasAnalysisFrames = analysis != nil } }
    }
    /// There is an analysis frame to draw from: false until the first one comes, again once the last one is dropped
    /// (everything off, a VIDEO format change), and for good on a VIDEO format past the hardware budget, which runs
    /// without the analysis output (histogramOnScreen).
    private(set) var hasAnalysisFrames = false
    private(set) var lenses: [LensInfo] = []
    private(set) var lensPresets: [LensPreset] = []
    private(set) var activePresetID: String? {
        // The Camera Control's Lens picker follows pinches, lens buttons and the system zoom slider.
        didSet { if oldValue != activePresetID { applyCameraControls() } }
    }

    private(set) var activity: CaptureActivity = .idle {
        didSet { if oldValue != activity { activityDidChange(from: oldValue) } }
    }
    /// The countdown running is only the wait a tripod scene takes after the tap, not a self timer.
    private(set) var isSettling = false
    /// Photos from their request until they are saved. The session can't change lens or mode under them.
    private(set) var photosInFlight = 0
    /// A focus or white balance bracket is running: one capture made of several photos, stopped with the shutter.
    private(set) var bracketInProgress = false
    /// A stopped bracket is still finishing the photo it was taking, so the shutter has nothing left to do.
    private(set) var bracketStopping = false
    private(set) var stackProgress: StackProgress?
    private(set) var intervalometer: IntervalometerStatus? {
        didSet {
            updateIdleTimer()
            if (oldValue == nil) != (intervalometer == nil) {
                // A run that ends while the gallery is up lets the camera stop under it.
                updateGalleryPause()
                // The mode stays put for the whole run, so the Camera Control's Mode and Night scene dim with it.
                applyCameraControls()
            }
        }
    }
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastCapture: CaptureResult?
    private(set) var recentCaptures: [CaptureResult] = []
    private(set) var toast: Toast?

    private(set) var aeLocked = false {
        // Every assignment counts: a long press somewhere else locks again at the new point.
        didSet { snapshotLockedMeter() }
    }
    /// Layer point of the last tap-to-focus, for the reticle. nil hides it.
    private(set) var focusPoint: CGPoint?
    /// Increments every time the shutter fires, so views can flash and buzz.
    private(set) var shutterCount = 0
    private(set) var motion = MotionState()
    /// The Camera Control overlay owns the screen; views hide clutter while true.
    private(set) var controlsFullscreen = false
    /// The video light. Only VIDEO uses it, the way the Camera app's flash button becomes a torch there.
    private(set) var torchOn = false
    /// Brightness the video light uses when it is on, 0...1.
    private(set) var torchLevel = 1.0

    /// Which manual control the dial is editing. Views bind to it.
    var activeDial: DialKind? {
        didSet {
            guard oldValue != activeDial else { return }
            // The magnifier belongs to the focus dial: Done, a swipe down, another dial, or the quick settings that
            // close it bring the whole frame back. The next focus dial offers it afresh.
            magnifierDeclined = false
            if activeDial != .focus { setMagnified(false) }
            // Peaking follows the focus dial in "manual focus" peaking mode.
            applyAnalysis()
            if activeDial == nil { applyCameraControls() }
        }
    }
    /// Settings covers the camera. A shot can still run under it, but the battery saver leaves that screen lit.
    var isSettingsPresented = false {
        didSet {
            guard oldValue != isSettingsPresented else { return }
            // Nobody focuses under a sheet, and the camera behind it should be the whole frame when it closes.
            if isSettingsPresented { setMagnified(false) }
            coverDidChange(closed: !isSettingsPresented)
        }
    }
    var isDrawerOpen = false
    /// Shown when the shutter is pressed while the app may not add to Photos.
    var isPhotosAccessAlertShown = false
    /// The gallery is up (the editor opens inside it). The camera stops under it (updateGalleryPause).
    var isReviewPresented = false {
        didSet {
            guard oldValue != isReviewPresented else { return }
            if isReviewPresented { setMagnified(false) }
            updateGalleryPause()
            coverDidChange(closed: !isReviewPresented)
        }
    }

    let backend: CameraBackend
    var isSimulated: Bool { backend.isSimulated }

    // MARK: - Dependencies and private state

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let motionMonitor: MotionMonitor
    @ObservationIgnored private let locationProvider: LocationProvider

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var backendRunning = false
    /// The app is behind another one. The camera can't run there and a permission prompt has nowhere to show, so a
    /// start asked for meanwhile waits for the return.
    @ObservationIgnored private var inBackground = false
    /// Counts backend starts, so one the app left in the middle of doesn't finish setting up a stopped camera.
    @ObservationIgnored private var backendStarts = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var pendingApply: Set<ApplyKind> = []
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var reticleTask: Task<Void, Never>?
    @ObservationIgnored private var externalSyncTask: Task<Void, Never>?
    @ObservationIgnored private var microphoneNoticeShown = false
    @ObservationIgnored private var lastBackPresetID: String?
    @ObservationIgnored private var adoptNextWhiteBalanceReading = false
    @ObservationIgnored private var bulbHoldActive = false
    /// A running stack was told to finish (Stop, the shutter, a hardware button or the end of a bulb hold) and is
    /// putting the picture together. The screen shows Processing, and the battery saver and the steady pill treat
    /// every frame as in.
    private(set) var isFinishingStack = false
    @ObservationIgnored private var lensSwitchInFlight = false
    /// The newest zoom asked for while a lens switch was reconfiguring the session, or one that needs another lens
    /// while photos were still being saved. continuing: a finger was still down, so the lens choice keeps its slack.
    @ObservationIgnored private var pendingZoom: (value: Double, animated: Bool, continuing: Bool)?
    /// The newest lens chosen while a lens switch was reconfiguring the session or photos were still being saved.
    @ObservationIgnored private var pendingPreset: LensPreset?
    /// A long press focused once and is holding that distance (the AF half of AE/AF LOCK). Observed, because the
    /// viewfinder shows a hold of the focus alone as well as one with the exposure.
    private var focusHeld = false
    /// Counts photo captures, so a photo that finishes late can tell a newer one owns the shutter state.
    @ObservationIgnored private var photoGeneration = 0
    /// The newest photo frees the shutter as soon as it is exposed (cameraBackendWillCapture).
    @ObservationIgnored private var releasesAtExposure = false
    /// Which reason the run of zoomed photos was last told: macro (true) or the zoom. nil once a photo kept its RAW.
    @ObservationIgnored private var rawNoticeForMacro: Bool?
    /// The newest mode change came from a manual value picked on screen in PHOTO or NIGHT (switchToManual: a dial or
    /// a chip's menu), not from the carousel or the Camera Control. The camera screen skips its veil for the one a
    /// dial is still being turned on.
    @ObservationIgnored private(set) var modeChangeLedByPick = false
    /// A value picked on the Camera Control is already on show in its overlay, so it isn't reinstalled for it.
    @ObservationIgnored private var applyingControlChange = false
    /// NIGHT's metered light and bias when AE was locked, so recomposing doesn't change the plan.
    @ObservationIgnored private var lockedMeter: (product: Double, bias: Double)?
    @ObservationIgnored private var lockMeterTask: Task<Void, Never>?
    /// A stacked shutter's auto ISO wants less than base ISO for the whole time, or more than a scene lets it have,
    /// so it is shot at that limit and the preview is asked for the same (updateStackISOLimit).
    @ObservationIgnored private var stackISOLimit: StackISOLimit?
    /// Pressing the shutter or a side button jolts a phone on a tripod, so the steady plan shown just before the
    /// press still counts for a moment after the motion sensor says otherwise.
    @ObservationIgnored private var steadyLostAt: Date?
    /// When the last countdown ran out and its shot began. A press that lands just after it was meant for the
    /// countdown (stackJustStartedFromCountdown).
    @ObservationIgnored private var countdownEndedAt: Date?
    /// When the app last sent a zoom or an exposure bias. Readings that disagree after that settle came from
    /// somewhere else, like the Camera Control's system sliders, and get adopted. The far future marks a request
    /// still waiting for the session: until a start or a mode change has set it up and applyAll sends the
    /// settings, the camera runs whatever it ran before, and its readings say nothing about them.
    @ObservationIgnored private var lastZoomCommand = Date.distantPast
    @ObservationIgnored private var lastBiasCommand = Date.distantPast

    private enum ApplyKind: Hashable {
        case exposure, focus, whiteBalance
    }

    private enum StackISOLimit {
        case floor, ceiling
    }

    // MARK: - Zoom transitions, steadiness, battery saver, gallery, look

    /// A lens button's zoom that is still gliding to its value; nil when no transition runs. Taps, VoiceOver steps
    /// and the wheel's landing set it; it clears shortly after the last step lands, and at once when a finger zooms,
    /// so it never changes at a finger's rate. While it is set the active button shows it instead of the readings.
    private(set) var zoomTarget: Double?
    /// A lens button (or the flip, a double tap, the Camera Control's lens picker) is swapping cameras now: true
    /// from the start of the swap until the new camera runs. The screen veils the picture meanwhile. A pinch or the
    /// wheel swaps without it, because the finger is still framing.
    private(set) var isSwitchingLensVisibly = false
    /// The tripod and hold-still status for NIGHT, LONG and a stacked MANUAL shutter. nil in other modes, once every
    /// frame of a shot is in, under the Camera Control's overlay, while the battery saver has the screen dark, and
    /// while the steady sign is switched off (display.showSteadySign).
    /// Stored and only written when the message changes, so the pill (and any layout around it) redraws on a change
    /// of message, not with every reading.
    private(set) var steadyStatus: SteadyMessage?
    /// A tripod shot's settle has run out while the phone still moves, and the shot waits a little longer for it
    /// to come to rest ("Waiting for the phone to settle" under the countdown).
    private(set) var isWaitingForSteady = false
    /// How far the phone turned since a NIGHT or LONG shot began, for the crosshairs.
    let drift = DriftState()
    /// How much the phone is moving right now, for the line on the steady sign.
    let motionPulse = MotionPulse()
    /// The battery saver's dimming.
    let dimmer = ScreenDimmer()
    /// Every photo and video taken with the app, for the gallery.
    let library: CaptureLibrary

    /// Where the look settings go. The app sets AppearanceStore's update here before it builds the model, so the
    /// first frame already has the person's accent. A hook rather than a call, so the model compiles without the
    /// view layer.
    static var onLookChange: (@MainActor (AppearanceOptions, AccessibilityOptions) -> Void)?

    @ObservationIgnored private let spoken = SpokenStatus()
    /// Bumped by every zoom request. A lens button's transition takes its second step (the swap after a zoom in,
    /// the zoom after a swap out) only if nothing newer has asked for a zoom meanwhile.
    @ObservationIgnored private var zoomRequestGeneration = 0
    /// The display zoom asked for last, from any source. Gestures start from it rather than from a reading that is
    /// up to a tenth of a second old, and a lens button's zoom plans from it.
    @ObservationIgnored private var requestedDisplayZoom: Double = 1
    @ObservationIgnored private var zoomTargetTask: Task<Void, Never>?
    /// The zoom request whose glide holds zoomTarget (holdZoomTarget, releaseZoomTarget).
    @ObservationIgnored private var zoomTargetGeneration = 0
    /// The countdown has just run out and its shot starts in this same turn, so a lens change parked behind the
    /// countdown waits for the shot (activityDidChange), and the gallery's pause leaves the camera running for it
    /// (galleryWantsCameraOff).
    @ObservationIgnored private var countdownRanOut = false
    /// What the shot being counted down or taken needs, fixed when it started: the plan keeps moving with the light,
    /// and the pill shouldn't change its mind halfway.
    @ObservationIgnored private var captureNeed: SteadyNeed?
    /// The countdown running is a settle wait, which taps nothing.
    @ObservationIgnored private var countdownIsSilent = false
    /// How long the shot about to start waited (self timer, settle), for its metadata.
    @ObservationIgnored private var timerSecondsForShot: Double?
    /// The camera stopped because the gallery or the editor covers it.
    @ObservationIgnored private var pausedForGallery = false

    /// A one-stop lens button zoom takes about 0.3 s; the target stays this much longer, so the last reading of the
    /// glide has landed before the button reads the live zoom again.
    private static let zoomTargetLinger = 0.2
    /// NIGHT on a tripod waits this long after the press, as the tripod scenes do.
    private static let nightTripodSettleSeconds = 1.0
    /// How much longer a settle waits for a phone that still moves.
    private static let settleExtraSeconds = 3.0
    /// How far past the hand limit LONG's frame has to go, about a fifth of a stop, before the pill changes its
    /// mind about a tripod (longSteadyNeed).
    private static let handLimitMargin = 1.15

    /// Display zoom the pinch, the zoom wheel and the zoom dial offer: from the widest lens to five times the
    /// longest button while lenses may switch, else the active lens's own range (ZoomMath.span).
    var zoomSpan: ClosedRange<Double> {
        let lens = activeLens
        let backZooms = lenses.filter { !$0.isFront && $0.kind != .external }.map(\.relativeZoom).sorted()
        let switches = settings.controls.autoLensSwitching && lens?.isFront == false && !activity.isBusy
            && photosInFlight == 0
        return ZoomMath.span(lensZooms: backZooms, buttonZooms: backLensPresets.map(\.displayZoom),
                             activeZoom: lens?.relativeZoom ?? 1, activeFactorRange: capabilities.zoomRange,
                             switchesLenses: switches)
    }

    /// Values the zoom wheel and the dial mark: the lens buttons' values.
    var zoomMarks: [Double] {
        backLensPresets.map(\.displayZoom)
    }

    /// The display zoom asked for last, which a gesture starts from. Read on demand, not observed.
    var requestedZoom: Double {
        requestedDisplayZoom
    }

    /// Steps along the wheel's ticks (0.1 to 2x, 0.2 to 5x, then wider), gliding at a lens button's speed. VoiceOver's
    /// swipes and the hardware buttons use it; a shot in progress keeps its framing, as it does for pinch.
    func nudgeZoom(by steps: Int) {
        guard steps != 0, canAdjustZoom else { return }
        let from = requestedDisplayZoom
        let target = ZoomMath.nudged(from, by: steps, in: zoomSpan)
        guard abs(target - from) > 0.0001 else { return }
        setDisplayZoom(target, animated: true)
    }

    /// Lights the screen the battery saver darkened. It stays lit a while, then darkens again if the shot goes on.
    func wakeScreen() {
        dimmer.wake()
    }

    /// Moves the brightness by `stops`, on the dial's third-stop grid and inside what the camera takes (a hardware
    /// button's Brighter and Darker). NIGHT keeps its own, as setBias does. A short line says where it landed, since
    /// nobody may be looking at a dial when a button moves it.
    func stepBias(by stops: Double) {
        guard stops.isFinite, stops != 0 else { return }
        let current = settings.mode == .night ? settings.night.biasEV : settings.manual.bias
        let range = capabilities.biasRange
        let next = min(max(EVFormat.snap(current + stops, step: .third), range.lowerBound), range.upperBound)
        if abs(next - current) > 0.001 {
            setBias(next)
        }
        let label = EVFormat.label(abs(next - current) > 0.001 ? next : current)
        showToast(label + " EV", symbol: "plusminus.circle")
    }

    /// The next back lens button, wrapping around after the longest (a hardware button's Next lens). While filming,
    /// the recording lens zooms to the next button's value past the zoom asked for last, as the lens buttons do, and
    /// wraps once no value it can reach is left.
    func selectNextLens() {
        let presets = backLensPresets
        guard !presets.isEmpty else { return }
        if activity == .recording {
            // A movie keeps its lens, so the active button can stay on a shorter one while the zoom moves on (the
            // wide at 5x still lights its 2x button), and stepping from it would ask for the same value again.
            let reach = capabilities.zoomRange.upperBound * (activeLens?.relativeZoom ?? 1)
            let next = presets.first(where: {
                $0.displayZoom > requestedDisplayZoom + 0.01 && $0.displayZoom <= reach + 0.01
            }) ?? presets[0]
            setDisplayZoom(next.displayZoom, animated: true)
            return
        }
        // Quick presses step on from the button already chosen, not from the one a glide or a swap still shows.
        let currentID = pendingPreset?.id
            ?? zoomTarget.flatMap { target in presets.first(where: { abs($0.displayZoom - target) < 0.01 })?.id }
            ?? activePresetID
        let next = presets.firstIndex(where: { $0.id == currentID }).map { presets[($0 + 1) % presets.count] }
            ?? presets.first(where: { $0.id == lastBackPresetID })
            ?? presets[0]
        select(next)
    }

    // MARK: Zoom transition bookkeeping

    /// Zoom follows the person between shots, during a countdown and while filming; a shot in progress keeps the
    /// framing it started with.
    private var canAdjustZoom: Bool {
        switch activity {
        case .idle, .countdown, .recording: return true
        case .capturing, .stacking, .saving: return false
        }
    }

    /// Reduce Motion, the system's or the app's own: zoom changes cut instead of gliding.
    private var reducesMotion: Bool {
        settings.accessibility.reduceMotion || UIAccessibility.isReduceMotionEnabled
    }

    private func nextZoomGeneration() -> Int {
        zoomRequestGeneration &+= 1
        return zoomRequestGeneration
    }

    /// generation: the request whose glide shows the target from now on, the only one that lets go of it.
    private func holdZoomTarget(_ value: Double, generation: Int) {
        zoomTargetTask?.cancel()
        zoomTargetTask = nil
        zoomTargetGeneration = generation
        if zoomTarget != value { zoomTarget = value }
    }

    /// The target stays on the button until the motion has landed, so the button doesn't count through the values
    /// in between at the readings' rate. Only the request holding it lets go: a newer one that glides holds its own,
    /// and one that glides nothing (a choice parked behind a shot) would otherwise leave the button frozen on a
    /// target with nothing on its way there. Called after a transition's last step, or for a step called off.
    private func releaseZoomTarget(after seconds: Double, generation: Int) {
        guard zoomTarget != nil, generation == zoomTargetGeneration else { return }
        // The button follows the camera in use from here, lit while the target still names the zoom. Lit only as
        // the target clears, LensPicker would wait for a reading that moves before trusting the zoom, and a camera
        // at rest never sends one: a parked swap's 2x button would read "2×" at 4x. A release that comes with a
        // transition's last step finds that button already lit.
        updateActivePreset(force: true)
        zoomTargetTask?.cancel()
        let wait = max(seconds.isFinite ? seconds : 0, 0) + Self.zoomTargetLinger
        zoomTargetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, generation == self.zoomTargetGeneration else { return }
            self.clearZoomTarget(resync: true)
        }
    }

    /// resync: the transition held the active button, which follows the device and the settings again now.
    private func clearZoomTarget(resync: Bool) {
        zoomTargetTask?.cancel()
        zoomTargetTask = nil
        guard zoomTarget != nil else { return }
        zoomTarget = nil
        if resync { updateActivePreset() }
    }

    /// Leaving the app or the camera drops whatever step a lens button's transition had left. The settings name the
    /// lens the camera is on, or the one a swap was bringing up, with the zoom it was going to, and the next start
    /// brings the camera there (startBackend): a warm session keeps whatever the device had reached.
    private func cancelZoomTransition() {
        zoomRequestGeneration &+= 1
        clearZoomTarget(resync: false)
    }

    /// Glides the active lens to a device zoom `factor` at the speed a lens button takes from `from` to `to`
    /// (display zoom); with Reduce Motion it cuts there. endsTransition: false while a lens swap is still to follow,
    /// which releases the target itself.
    private func rampZoom(toFactor factor: Double, from: Double, to: Double, generation: Int,
                          endsTransition: Bool = true) {
        lastZoomCommand = Date()
        let glides = !reducesMotion
        backend.setZoomFactor(factor, rampRate: glides ? ZoomMath.rampRate(from: from, to: to) : nil)
        if endsTransition {
            // A cut keeps the target only until the readings catch up with it.
            releaseZoomTarget(after: glides ? ZoomMath.rampDuration(from: from, to: to) : 0, generation: generation)
        }
    }

    /// A lens change that select() asks for: veiled from its start until the new camera runs. `completion` is the
    /// transition's next step, taken only if nothing newer came meanwhile.
    private func switchLens(to preset: LensPreset, generation: Int, then completion: (() -> Void)? = nil) {
        lensSwitchInFlight = true
        setSwitchingLensVisibly(true)
        lastZoomCommand = Date()
        Task {
            await backend.select(preset)
            lensSwitchInFlight = false
            setSwitchingLensVisibly(false)
            lastZoomCommand = Date()
            refreshLenses()
            applyCameraControls()
            if generation == zoomRequestGeneration, let completion {
                completion()
            } else {
                // The last step, or a newer request called off the rest.
                releaseZoomTarget(after: 0, generation: generation)
            }
            applyPendingLensChange()
        }
    }

    private func setSwitchingLensVisibly(_ switching: Bool) {
        if isSwitchingLensVisibly != switching { isSwitchingLensVisibly = switching }
    }

    /// The display zoom the settings hold, on the lens they name.
    private var settingsDisplayZoom: Double {
        let zoom = settings.zoom * (activeLens?.relativeZoom ?? 1)
        return zoom.isFinite && zoom > 0 ? zoom : 1
    }

    // MARK: Steady status

    private func refreshSteadyStatus() {
        let next = currentSteadyMessage
        if next != steadyStatus { steadyStatus = next }
    }

    private var currentSteadyMessage: SteadyMessage? {
        // Switched off on NIGHT's top bar or in Settings. Nobody sees the pill under the Camera Control's overlay or
        // the battery saver's black screen.
        guard settings.display.showSteadySign, !controlsFullscreen, !dimmer.isDimmed else { return nil }
        let phase: SteadyPhase
        switch activity {
        case .idle:
            phase = .framing
        case .countdown:
            phase = .countingDown
        case .stacking:
            // Once every frame is in, or the shot was told to finish, the picture is being put together and holding
            // still no longer matters.
            if isFinishingStack { return nil }
            if let progress = stackProgress, progress.framesPlanned > 0, progress.framesCaptured >= progress.framesPlanned {
                return nil
            }
            phase = .capturing
        case .capturing, .saving, .recording:
            return nil
        }
        guard let need = (phase == .framing ? nil : captureNeed) ?? liveSteadyNeed else { return nil }
        // Off target only counts while the crosses show (DriftState.isTracking): front camera, past a minute.
        return SteadyMessage(need: need, phase: phase, isSteady: motion.isSteady, sensorAvailable: motion.isAvailable,
                             isOffTarget: drift.isTracking && drift.isOffTarget, wasBumped: drift.wasBumped)
    }

    /// What the shot in view asks of the person holding the phone: the one rule the pill and the metadata share
    /// (SteadyAdvice). nil outside NIGHT, LONG and a stacked MANUAL shutter.
    private var liveSteadyNeed: SteadyNeed? {
        switch settings.mode {
        case .night:
            return SteadyAdvice.night(stability: settings.night.stability,
                                      seconds: settings.night.seconds ?? nightAutoSeconds)
        case .long:
            return longSteadyNeed(plan: longPlan, leaning: shownSteadyNeed)
        case .manual:
            // Past the longest shutter MANUAL builds a Real stack, which adds light over the whole time.
            return shutterIsStacked ? .tripod : nil
        case .photo, .video:
            return nil
        }
    }

    /// leaning: the need the pill names now. An auto frame time hovering at the hand limit (Water at 2x at dusk)
    /// would flip the pill between "Hold still" and "Use a tripod" with every reading, so the limit gives way a
    /// little toward the side on show, and only a frame clearly past it changes the message.
    private func longSteadyNeed(plan: StackPlan, leaning shown: SteadyNeed? = nil) -> SteadyNeed {
        let focal = capabilities.lens.equivalentFocalLength * max(readings.zoomFactor, 1)
        var limit = ExposureMath.handheldLimit(equivalentFocalLength: focal)
        if let shown {
            limit *= shown == .tripod ? 1 / Self.handLimitMargin : Self.handLimitMargin
        }
        return SteadyAdvice.longExposure(plan: plan, align: settings.longExposure.align, handheldLimit: limit)
    }

    /// The need the pill names, where its message says one.
    private var shownSteadyNeed: SteadyNeed? {
        switch steadyStatus {
        case .useTripod: return .tripod
        case .holdStill: return .holdStill
        case .noSensor(let need): return need
        default: return nil
        }
    }

    // MARK: Battery saver

    /// The battery saver's rule (DimPolicy), run whenever one of its inputs moves: each progress report (about 6 a
    /// second), the motion sensor, the shutter's state, a bulb hold and the setting.
    private func updateDimming() {
        let progress = stackProgress
        // A bulb plans no frames, so only a finish asked for says its last frame is in.
        let framesAllIn = isFinishingStack
            || (progress.map { $0.framesPlanned > 0 && $0.framesCaptured >= $0.framesPlanned } ?? false)
        func rule(steady: Bool) -> Bool {
            DimPolicy.shouldDim(
                isEnabled: settings.display.dimDuringLongShots,
                // The gallery or Settings can be up while an intervalometer or a settled shot runs under it. The
                // dark layer and its wake touch sit under them, and the brightness is the whole screen's.
                isCapturing: activity == .stacking && progress != nil && !isReviewPresented && !isSettingsPresented,
                elapsed: progress?.elapsed ?? 0,
                total: progress?.estimatedTotal,
                framesAllIn: framesAllIn,
                isSteady: steady,
                sensorAvailable: motion.isAvailable,
                bulbHeld: bulbHoldActive,
                sinceWake: dimmer.secondsSinceWake
            )
        }
        let shouldDim = rule(steady: motion.isSteady)
        // A gust or a bump lights the dark screen for the crosses, and it stays lit the wake time, as after a touch.
        // Darkened again at the next calm moment, wind would flash the screen with every gust.
        if dimmer.isDimmed, !shouldDim, rule(steady: true) {
            dimmer.wake()
            return
        }
        dimmer.update(shouldDim: shouldDim)
    }

    /// The gallery or Settings opened or closed over the camera. Opening lights the screen at once; closing during a
    /// shot is a look at it, so it stays lit the wake time before it may go dark again.
    private func coverDidChange(closed: Bool) {
        if closed, activity == .stacking { dimmer.noteLook() }
        updateDimming()
    }

    /// Under the black screen the crosses stop drawing (tracking goes on) and the pill steps aside.
    private func dimmingDidChange() {
        motionMonitor.pausesDriftAngles = dimmer.isDimmed
        refreshSteadyStatus()
        applyAnalysis()
    }

    // MARK: Gallery

    /// The gallery and the editor cover the camera, so the session stops under them as it does in the background:
    /// the camera indicator goes off, the battery rests, and a video in the gallery can play its sound. An
    /// intervalometer or a bracket keeps it running, and a shot still being taken or saved finishes first. So does
    /// the shot a self timer or a settle counts down to: countdown() passes through .idle as it runs out
    /// (countdownRanOut), and a pause in that step would stop the camera under the shot about to start.
    private var galleryWantsCameraOff: Bool {
        isReviewPresented && intervalometer == nil && !bracketInProgress && !activity.isBusy && !countdownRanOut
            && photosInFlight == 0
    }

    private func updateGalleryPause() {
        if galleryWantsCameraOff {
            guard backendRunning, !pausedForGallery else { return }
            pausedForGallery = true
            releaseLock()
            turnTorchOff()
            pendingPreset = nil
            pendingZoom = nil
            cancelZoomTransition()
            motionMonitor.stop()
            // The most precise fix and the compass are for shots, and none can start under the gallery.
            // startBackend turns them back on.
            locationProvider.setEnabled(false)
            backend.stop()
            backendRunning = false
        } else if pausedForGallery, !isReviewPresented {
            pausedForGallery = false
            guard hasStarted, !inBackground, authorization == .authorized, !backendRunning else { return }
            Task { await startBackend() }
        }
    }

    // MARK: Spoken status and look

    /// Speak status (Accessibility settings). Never while filming, where the microphone would record it, nor in
    /// PHOTO with Live Photo on, whose movie starts before the shot and would keep the countdown's last word.
    private func speak(_ text: String) {
        guard settings.accessibility.speakStatus, settings.mode != .video else { return }
        if settings.mode == .photo, settings.capture.livePhoto, capabilities.livePhotoSupported { return }
        spoken.say(text)
    }

    /// For VoiceOver alone, whatever Speak status is set to: what the screen shows without words (a lock, macro,
    /// the half press). A toast would say it a second time to everyone else.
    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Haptics follow the settings from here: the views that play them read no settings.
    private func mirrorHaptics() {
        let controls = settings.controls
        Haptics.isEnabled = controls.haptics
        Haptics.strength = controls.hapticStrength
        Haptics.dialTicks = controls.dialTicks
        Haptics.zoomTicks = controls.zoomTicks
    }

    /// The accent, the sheets' scheme and the accessibility options, copied out once here rather than read by the
    /// camera screen, which would then redraw with every settings write a dial makes.
    private func mirrorLook() {
        Self.onLookChange?(settings.appearance, settings.accessibility)
    }

    // Default arguments run outside the main actor, so the main-actor helpers are built in the body.
    init(backend: CameraBackend, store: SettingsStore = SettingsStore(), motionMonitor: MotionMonitor? = nil,
         locationProvider: LocationProvider? = nil, library: CaptureLibrary? = nil) {
        self.backend = backend
        self.store = store
        self.motionMonitor = motionMonitor ?? MotionMonitor()
        self.locationProvider = locationProvider ?? LocationProvider()
        self.library = library ?? CaptureLibrary()
        var stored = store.load()
        // The camera shows every control now, and Settings has the switch for how much it lists. A save from the
        // earlier simple interface gets back what that interface had put aside, once. Written back before the
        // snapshot goes: a launch that changes no setting would otherwise leave the simple save on disk with nothing
        // left to restore it from.
        if !stored.interface.advanced, stored.interface.welcomed {
            stored = stored.restoringAdvanced(from: store.loadAdvancedSnapshot())
            store.save(stored)
            store.clearAdvancedSnapshot()
        }
        // The night shot plans for a tripod unless the person says otherwise in Settings > Night. A save from the
        // build that had no control for it on the camera screen is moved to tripod once, whatever it held: an old
        // Handheld would have shown only as shots that came out differently. A choice made since stays, wherever it
        // was made.
        if !store.nightMovedToTripod {
            if stored.night.stability != .tripod {
                stored.night.stability = .tripod
                store.save(stored)
            }
            store.nightMovedToTripod = true
        }
        // Night duration joined the Camera Control's default list. A list still equal to the default before it was
        // never changed by hand, so it moves to the new default once; a list the person made stays as it is.
        if !store.cameraControlMovedToNightDuration {
            if stored.controls.cameraControlItems == CameraControlItem.previousDefaultSelection {
                stored.controls.cameraControlItems = CameraControlItem.defaultSelection
                store.save(stored)
            }
            store.cameraControlMovedToNightDuration = true
        }
        // What the startup options don't keep goes back to where a fresh install starts, after the restore, so a
        // MANUAL it brings back doesn't open a camera that is set to start in PHOTO.
        var loaded = stored.applyingStartupOptions()
        loaded.interface.advanced = true
        loaded.interface.welcomed = true
        // A shutter speed saved on a phone that no longer offers them, or by a build before the rule, would go on
        // running with no chip to show it or turn it off.
        let manualShutter = backend.isSimulated || PhoneModel.isProShutterPhone || PhoneModel.variableApertureSeen
        if !manualShutter { loaded.manual.shutter = nil }
        self.allowsManualShutter = manualShutter
        self.settings = loaded
        lastNightFamilyMode = loaded.mode == .long ? .long : .night
        mirrorHaptics()
        mirrorLook()
        dimmer.onChange = { [weak self] _ in self?.dimmingDidChange() }
    }

    // MARK: - Lifecycle

    /// Checks permission, starts the backend with the saved settings, starts motion and location. Waits for the app
    /// to be in front (sceneDidBecomeActive calls again).
    func start() async {
        guard !hasStarted, !inBackground else { return }
        hasStarted = true
        backend.delegate = self
        mirrorHaptics()
        Haptics.prepare()
        motionMonitor.onUpdate = { [weak self] state in
            guard let self else { return }
            if self.motion.isSteady, !state.isSteady { self.steadyLostAt = Date() }
            self.motion = state
            self.refreshSteadyStatus()
            self.updateDimming()
        }
        motionMonitor.onDriftChange = { [weak self] in
            self?.refreshSteadyStatus()
        }
        motionMonitor.onPulse = { [weak self] level in
            self?.motionPulse.set(level)
        }

        authorization = backend.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await backend.requestAuthorization()
        }
        guard authorization == .authorized else { return }
        await startBackend()
    }

    func stop() {
        // Called off before the countdown is, whose end would otherwise replay them on a camera about to stop.
        pendingPreset = nil
        pendingZoom = nil
        cancelSchedule()
        cancelZoomTransition()
        // Told to the session before it stops, so the next start opens on the whole frame.
        setMagnified(false)
        motionMonitor.stop()
        locationProvider.setEnabled(false)
        backend.stop()
        backendRunning = false
        dimmer.restore()
        spoken.stop()
    }

    func sceneDidBecomeActive() {
        inBackground = false
        guard hasStarted else {
            // A start put off while the app was away.
            Task { await start() }
            return
        }
        // Keeps Auto-Lock in step with a stack that went on while the app was away.
        updateIdleTimer()
        let status = backend.authorizationStatus()
        if status != authorization {
            authorization = status
        }
        guard authorization == .authorized, !backendRunning else { return }
        Task { await startBackend() }
    }

    func sceneDidEnterBackground() {
        inBackground = true
        spoken.stop()
        setMagnified(false)
        guard backendRunning else { return }
        // The scene in front of the lens will have changed by the time the app comes back.
        releaseLock()
        turnTorchOff()
        // A lens change still waiting for photos to save would otherwise land on the stopped session.
        pendingPreset = nil
        pendingZoom = nil
        cancelZoomTransition()
        if activity == .recording {
            stopRecording()
        }
        if case .countdown = activity {
            cancelSchedule()
        } else if intervalometer != nil || bracketInProgress {
            // A bracket's remaining frames would only fail one by one against the stopped session.
            cancelSchedule()
        }
        // The stopped session finishes a stack with the frames it has, and the return finds it putting them together.
        noteStackFinishing()
        motionMonitor.stop()
        // Every request still on its way took its location when it was made.
        locationProvider.setEnabled(false)
        backend.stop()
        backendRunning = false
    }

    func requestCameraAccess() async {
        authorization = await backend.requestAuthorization()
        if authorization == .authorized {
            await startBackend()
        }
    }

    /// Opens this app's page in the Settings app.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// A running capture session doesn't keep the screen on, and Auto-Lock would send the app to the background
    /// in the middle of a long exposure, a timer, an intervalometer or a recording and end it. An idle viewfinder
    /// still locks as usual.
    private func updateIdleTimer() {
        let keepAwake = activity.isBusy || intervalometer != nil
        if UIApplication.shared.isIdleTimerDisabled != keepAwake {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
    }

    /// Everything that follows what the shutter is doing: Auto-Lock, the haptics hold, the drift crosses, the status
    /// pill, the battery saver and the gallery's pause.
    private func activityDidChange(from old: CaptureActivity) {
        // The half press ends the magnifier before any shot; this catches anything else that starts one, so no
        // photo, stack or recording is ever taken enlarged.
        if activity != .idle { setMagnified(false) }
        updateIdleTimer()
        // A tap of the Taptic Engine shakes a phone on a tripod: none while frames come in or a settle runs.
        var settling = false
        if case .countdown = activity { settling = countdownIsSilent }
        Haptics.isSuppressed = activity == .stacking || settling
        if old == .stacking, activity != .stacking {
            motionMonitor.endDrift()
        }
        refreshSteadyStatus()
        updateDimming()
        updateGalleryPause()
        // The Camera Control's controls dim while a shot runs and the mode can't change, and come back after.
        applyCameraControls()
        // The camera is free again: a lens button's swap parked behind the shot, a recording, a cancelled countdown or
        // a bracket happens now. Not as a countdown runs out, whose shot starts in this same turn on the lens it was
        // framed with, and not under a gallery that has just stopped the camera.
        if activity == .idle, !countdownRanOut {
            replayParkedLensChange()
        }
    }

    private func startBackend() async {
        guard !backendRunning, !inBackground else { return }
        // The gallery or the editor is up (a return from the background, or a start that waited): the camera starts
        // when it closes.
        if galleryWantsCameraOff {
            pausedForGallery = true
            return
        }
        backendRunning = true
        // A starting camera runs whatever bias it had until applyAll sends these settings.
        lastBiasCommand = .distantFuture
        backendStarts &+= 1
        let attempt = backendStarts
        sessionState = .starting
        await backend.start(settings: settings)
        // The app left while the camera was starting, and leaving stopped it. The return starts it afresh.
        guard backendRunning, attempt == backendStarts else { return }
        // A backend that failed or got interrupted has already said so; otherwise start returning means it runs.
        if sessionState == .starting || sessionState == .idle {
            sessionState = .running
        }
        // A warm start runs the camera the session had before the pause, wherever an interrupted lens button's
        // transition left it, and only a cold one reads the settings. They name where the camera belongs, so it goes
        // there before anything reads the zoom. A fallback camera, whose lens isn't on offer, stays as it is, and a
        // shot still finishing keeps its lens.
        if let wanted = settings.lensID, let running = backend.activeLensID, !activity.isBusy, photosInFlight == 0 {
            if running != wanted, let lens = backend.lenses.first(where: { $0.id == wanted }) {
                lensSwitchInFlight = true
                setSwitchingLensVisibly(true)
                lastZoomCommand = Date()
                await backend.select(LensPreset(lensID: wanted, zoomFactor: settings.zoom,
                                                displayZoom: settings.zoom * lens.relativeZoom))
                lensSwitchInFlight = false
                setSwitchingLensVisibly(false)
                guard backendRunning, attempt == backendStarts else { return }
            } else if running == wanted {
                lastZoomCommand = Date()
                backend.setZoomFactor(settings.zoom, rampRate: nil)
            }
        }
        refreshLenses()
        requestedDisplayZoom = settingsDisplayZoom
        applyAll()
        if settings.mode == .video {
            await backend.configureForVideo(settings.video)
            guard backendRunning, attempt == backendStarts else { return }
            applyAll()
            noteMicrophoneIfDenied()
        }
        motionMonitor.start()
        locationProvider.setEnabled(settings.capture.saveLocation)
        // A lens or zoom asked for while the start was bringing the camera back to its lens.
        replayParkedLensChange()
    }

    private func refreshLenses() {
        // Every capabilities update comes through here, and Observation tells each reader of a write even when the
        // value is the same.
        let lenses = backend.lenses
        if lenses != self.lenses { self.lenses = lenses }
        let presets = backend.lensPresets
        if presets != lensPresets { lensPresets = presets }
        // A camera left in macro opens in macro: the saved lens and zoom say so once the lenses are known. Only in
        // the modes that have the macro button. NIGHT gave its place to the scenes, and a save from the build
        // before can still hold NIGHT in macro: it opens on the main camera's 1x, as entering NIGHT leaves macro
        // (setMode). Parked, because the camera is still starting here, and startBackend ends with the replay. With
        // lens switching off the same lens and zoom were reached by hand and stay, as they do in VIDEO.
        if !macroRestored, !lenses.isEmpty {
            macroRestored = true
            if let lens = lenses.first(where: { $0.id == settings.lensID }), lens.kind == .ultraWide,
               abs(settings.zoom * lens.relativeZoom - 1) < 0.02 {
                if Self.offersMacro(settings.mode) {
                    isMacro = true
                } else if settings.mode.usesStacking, settings.controls.autoLensSwitching, let id = macroButtonID,
                          let wide = backLensPresets.first(where: { $0.id == id }) {
                    pendingPreset = wide
                }
            }
        }
        updateActivePreset()
    }

    private func applyAll() {
        lastZoomCommand = Date()
        lastBiasCommand = Date()
        backend.apply(options: DeviceOptions(settings: settings))
        backend.apply(exposure: currentExposureRequest())
        endFocusHold()
        backend.apply(focus: currentFocusRequest())
        backend.apply(whiteBalance: currentWhiteBalanceRequest())
        applyAnalysis()
        applyCameraControls()
    }

    // MARK: - Advanced settings and the carousel

    /// Settings lists every option, in groups. Off keeps the page to the ones most people change. Nothing about
    /// the camera follows it.
    var showsAdvancedSettings: Bool { settings.interface.advancedSettings }

    func setAdvancedSettings(_ on: Bool) {
        guard on != showsAdvancedSettings else { return }
        var next = settings
        next.interface.advancedSettings = on
        commit(next)
    }

    /// Modes in the carousel, left to right. NIGHT stands for the night shot and the long exposure scenes.
    var availableModes: [CaptureMode] { CaptureMode.carouselOrder }

    /// Which of the two NIGHT holds was in use last, so the carousel's NIGHT comes back to it.
    @ObservationIgnored private var lastNightFamilyMode: CaptureMode = .night

    /// The carousel's pick. NIGHT opens the night shot or the long exposure scene used there last.
    func selectCarouselMode(_ mode: CaptureMode) {
        setMode(mode == .night ? lastNightFamilyMode : mode)
    }

    // MARK: - Mode and lens

    func setMode(_ mode: CaptureMode) {
        // The carousel and the Camera Control play their own clicks.
        guard mode != settings.mode, canChangeMode, availableModes.contains(mode.carouselMode) else { return }
        releaseLock()
        if let dial = activeDial, !dialAvailable(dial, in: mode) {
            activeDial = nil
        }
        if mode.usesStacking { lastNightFamilyMode = mode }
        // VIDEO and NIGHT have no macro button to show macro or to end it, so macro stays behind: the main
        // camera's 1x, the button that was lit, is the lens they open on.
        if !Self.offersMacro(mode), isMacro, let id = macroButtonID,
           let wide = backLensPresets.first(where: { $0.id == id }) {
            select(wide, haptic: false)
        }
        modeChangeLedByPick = false
        updateSettings { $0.mode = mode }
    }

    /// A capture keeps the mode it started in. Between intervalometer shots the activity reads idle, but a switch
    /// to VIDEO would leave the remaining shots with nothing to take; photos still being processed and saved need
    /// the session as it was when they were exposed.
    private var canChangeMode: Bool {
        !activity.isBusy && intervalometer == nil && photosInFlight == 0
    }

    /// Says why a pick that leads to another mode did nothing (canChangeMode). The controls that send such picks stay
    /// live while the mode can't change: PHOTO's shutter dial while a photo saves, NIGHT's scene menu between an
    /// intervalometer's shots. A dial sends a tick many times a second, and every toast slides in anew and
    /// is read out by VoiceOver, so one that already says this stays up as it is, with its time started over.
    private func noteModeChangeRefused() {
        let message = activity.isBusy || intervalometer != nil
            ? "Finish the shot first." : "Wait for the last photo to save."
        if let shown = toast, shown.message == message {
            expireToast(shown)
            return
        }
        showToast(message, symbol: "exclamationmark.triangle")
    }

    /// Picking a manual value in PHOTO or NIGHT is a request for manual control, the way a camera's mode dial
    /// works. It goes by setMode's rules, and a lock set in the old mode goes with it. A focus or white balance pick
    /// says nothing about exposure, so keepingAutoExposure leaves MANUAL's saved shutter, ISO and aperture behind
    /// instead of bringing them back into the shot.
    private func switchToManual(keepingAutoExposure: Bool = false, _ change: (inout CameraSettings) -> Void) {
        guard canChangeMode else {
            noteModeChangeRefused()
            return
        }
        releaseLock()
        modeChangeLedByPick = !applyingControlChange
        updateSettings { settings in
            settings.mode = .manual
            if keepingAutoExposure {
                settings.manual.shutter = nil
                settings.manual.iso = nil
                settings.manual.aperture = nil
            }
            change(&settings)
        }
    }

    /// haptic: false for the Camera Control, which clicks on its own, and for a choice replayed after a wait, whose
    /// click already played when it was made.
    ///
    /// A lens button zooms to its value instead of cutting to it. On its own lens it glides there. To a longer lens
    /// it zooms the lens in use in to that framing and swaps at the end, where both lenses frame the same picture; to
    /// a wider one it swaps at the framing in view and zooms the new lens out. Only the swap is veiled
    /// (isSwitchingLensVisibly). The selfie camera and Reduce Motion keep the cut.
    func select(_ preset: LensPreset, haptic: Bool = true) {
        // Any lens button leaves macro, the 1x button too: lit for macro, a tap on it brings the main camera back.
        // That tap is not the second tap on a button a glide is heading to, so it goes through like a replay.
        // A shot in progress keeps its lens, and macro with it.
        guard !activity.isBusy else { return }
        let leavingMacro = isMacro
        if leavingMacro { isMacro = false }
        select(preset, haptic: haptic, replaying: leavingMacro)
    }

    /// replaying: a choice that waited for a swap or a shot (applyPendingLensChange). Its button and target can still
    /// be the ones showing, which a new tap on the same button would leave alone.
    private func select(_ preset: LensPreset, haptic: Bool, replaying: Bool) {
        guard !activity.isBusy else { return }
        // The Camera Control's Lens picker shows a parked choice. Parked or dropped while the active button stays
        // put, the change sends no state of its own; any other lens change does, through activePresetID.
        let parkedBefore = pendingPreset?.id
        defer { if pendingPreset?.id != parkedBefore { applyCameraControls() } }
        // Any lens choice frames anew, and the magnifier enlarges the frame of the lens it was turned on for. The
        // whole frame it metered is the old framing's.
        setMagnified(false)
        if magnifierMeter != nil { magnifierMeter = nil }
        // A second tap on the button a glide is already heading to: planned again from where the picture is midway,
        // it would cut the glide short with a swap.
        if !replaying, let target = zoomTarget, preset.id == activePresetID, abs(target - preset.displayZoom) < 0.001 {
            if haptic { Haptics.tap() }
            // Its swap was parked behind a shot that has ended since: the tap takes it now.
            if pendingPreset?.id == preset.id { replayParkedLensChange() }
            return
        }
        lastZoomCommand = Date()
        let generation = nextZoomGeneration()
        // Quick taps, or a scroll through the Camera Control's lens picker, end on the lens chosen last.
        guard !lensSwitchInFlight else {
            pendingPreset = preset
            pendingZoom = nil
            if haptic { Haptics.tap() }
            return
        }
        let current = backend.activeLensID
        // Another zoom step on the same lens leaves the session alone, so only a lens switch waits for the saves.
        if current != preset.lensID, photosInFlight > 0 {
            pendingPreset = preset
            pendingZoom = nil
            if haptic { Haptics.tap() }
            return
        }
        // This choice is newer than any still waiting.
        pendingPreset = nil
        pendingZoom = nil
        let targetLens = lenses.first(where: { $0.id == preset.lensID })
        if let targetLens, !targetLens.isFront {
            lastBackPresetID = preset.id
        }
        // A glide on this lens plans from where the last one was going. A change of lens goes by the picture itself,
        // which is somewhere between while another transition is on its way.
        let from = requestedDisplayZoom
        let framing = zoomTarget == nil ? from : readings.displayZoom
        let to = preset.displayZoom
        // Macro is 1x taken with the ultra wide camera, so the 1x button keeps the light.
        activePresetID = isMacro ? (macroButtonID ?? preset.id) : preset.id
        settings.lensID = preset.lensID
        settings.zoom = preset.zoomFactor
        requestedDisplayZoom = to
        scheduleSave()
        if haptic { Haptics.tap() }
        if current == preset.lensID {
            holdZoomTarget(to, generation: generation)
            rampZoom(toFactor: preset.zoomFactor, from: from, to: to, generation: generation)
            return
        }
        // The locked point and exposure belong to the lens being left.
        releaseLock()
        guard let currentLens = activeLens, let targetLens, !currentLens.isFront, !targetLens.isFront else {
            // The selfie camera frames another scene: a cut under the veil, as lens changes have always been.
            clearZoomTarget(resync: false)
            switchLens(to: preset, generation: generation)
            return
        }
        holdZoomTarget(to, generation: generation)
        guard !reducesMotion, framing.isFinite, framing > 0 else {
            switchLens(to: preset, generation: generation)
            return
        }
        // From 1x heading to 8x, a tap on 4 at 1.7x still zooms in; planned from the old target it would zoom out
        // and cut.
        if to > framing {
            // In: the lens in use zooms the whole way, digitally past its own reach, then the longer lens takes over
            // at the same framing. The swap at the end reads as the camera settling, not as a stutter mid-motion.
            let factor = clampZoomFactor(to / max(currentLens.relativeZoom, 0.01))
            // Until the swap the camera that runs is the lens in use, zoomed in, and the settings say so: a pause,
            // a newer zoom or a shot that stops the swap leaves them true to the camera.
            settings.lensID = currentLens.id
            settings.zoom = factor
            scheduleSave()
            rampZoom(toFactor: factor, from: framing, to: to, generation: generation, endsTransition: false)
            // No margin: the swap starting on the ramp's last frames is hidden by the veil, a late one is not.
            let wait = ZoomMath.rampDuration(from: framing, to: to)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self else { return }
                // A newer request has the zoom, or a stop already let go of the target.
                guard generation == self.zoomRequestGeneration, self.backendRunning else {
                    self.releaseZoomTarget(after: 0, generation: generation)
                    return
                }
                // A shot started meanwhile keeps its lens; the swap waits for it like any lens change
                // (replayParkedLensChange). The glide has landed, so the button follows the camera from here, lit by
                // the release while the target still shows: lit at rest, it would read its own value, not the zoom.
                guard !self.activity.isBusy, self.photosInFlight == 0, !self.lensSwitchInFlight else {
                    self.pendingPreset = preset
                    self.releaseZoomTarget(after: 0, generation: generation)
                    return
                }
                self.settings.lensID = preset.lensID
                self.settings.zoom = preset.zoomFactor
                self.scheduleSave()
                self.switchLens(to: preset, generation: generation)
            }
        } else {
            // Out: the wider lens takes over at the framing in view (the backend keeps the factor inside what that
            // lens can do), then zooms out to the button's value.
            let start = LensPreset(lensID: targetLens.id, zoomFactor: framing / max(targetLens.relativeZoom, 0.01),
                                   displayZoom: framing)
            switchLens(to: start, generation: generation) { [weak self] in
                self?.rampZoom(toFactor: preset.zoomFactor, from: framing, to: to, generation: generation)
            }
        }
    }

    /// Pinch, the zoom wheel, VoiceOver steps and the zoom dial. Display zoom is relative to the back wide camera;
    /// switches lenses when settings.controls.autoLensSwitching is on and the zoom crosses another lens.
    /// animated glides at a lens button's speed (VoiceOver, the wheel's landing, the lens buttons while filming);
    /// otherwise the zoom follows the finger. continuing: a finger is still down, so the lens in use keeps the zoom a
    /// little past the next lens's own value instead of swapping back and forth at the boundary; the lift then
    /// chooses strictly.
    func setDisplayZoom(_ zoom: Double, animated: Bool, continuing: Bool = false) {
        guard zoom.isFinite, zoom > 0 else { return }
        // A zoom drops a lens choice still parked, which the Camera Control's Lens picker shows. Only then: this runs
        // at the finger's rate.
        let parkedBefore = pendingPreset?.id
        defer { if pendingPreset?.id != parkedBefore { applyCameraControls() } }
        // A zoom frames anew from the whole frame: the magnifier lives on the same device zoom, and the whole frame
        // it metered is the old framing's.
        setMagnified(false)
        if magnifierMeter != nil { magnifierMeter = nil }
        // A zoom by hand goes on from the macro framing as plain zoom.
        if isMacro { isMacro = false }
        lastZoomCommand = Date()
        let generation = nextZoomGeneration()
        let from = requestedDisplayZoom
        // Only a glide shows a target; a finger's zoom lands at once.
        if animated {
            holdZoomTarget(zoom, generation: generation)
        } else {
            clearZoomTarget(resync: false)
        }
        // A pinch or a flicked dial keeps going while the session switches lenses; dropping those values would
        // leave the zoom short of where the finger stopped.
        guard !lensSwitchInFlight else {
            pendingZoom = (zoom, animated, continuing)
            pendingPreset = nil
            requestedDisplayZoom = zoom
            return
        }
        guard let activeLens = activeLens else {
            // No camera yet: nothing glides, so nothing may keep showing a target.
            clearZoomTarget(resync: false)
            return
        }

        var targetLens = activeLens
        // Photos still being saved keep the session on its lens. A zoom that wants another lens zooms this one for
        // now and switches once they are in.
        var waitsForPhotos = false
        if settings.controls.autoLensSwitching, !activeLens.isFront, !activity.isBusy {
            let backLenses = lenses.filter { !$0.isFront && $0.kind != .external }
                .sorted { $0.relativeZoom < $1.relativeZoom }
            // The longest lens that still covers this zoom without cropping past its own field of view, with some
            // slack for the lens in use while a finger is down.
            let index = ZoomMath.lensIndex(for: zoom, lensZooms: backLenses.map(\.relativeZoom),
                                           current: backLenses.firstIndex(where: { $0.id == activeLens.id }),
                                           currentMaxFactor: capabilities.zoomRange.upperBound,
                                           continuing: continuing)
            if let index {
                let best = backLenses[index]
                if photosInFlight == 0 {
                    targetLens = best
                } else {
                    waitsForPhotos = best.id != activeLens.id
                }
            }
        }
        // The newest request wins, and a zoom back within this lens's own range cancels a switch still waiting.
        pendingPreset = nil
        pendingZoom = waitsForPhotos ? (zoom, false, false) : nil

        let base = max(targetLens.relativeZoom, 0.01)
        let factor = zoom / base
        if targetLens.id != activeLens.id {
            let preset = lensPresets.first(where: { $0.lensID == targetLens.id && abs($0.zoomFactor - 1) < 0.01 })
                ?? LensPreset(lensID: targetLens.id, zoomFactor: 1, displayZoom: targetLens.relativeZoom)
            releaseLock()
            lensSwitchInFlight = true
            activePresetID = preset.id
            // The swap brings the lens up at its own button's factor; the asked zoom follows once it runs.
            settings.lensID = targetLens.id
            settings.zoom = preset.zoomFactor
            requestedDisplayZoom = zoom
            Task {
                await backend.select(preset)
                lensSwitchInFlight = false
                lastZoomCommand = Date()
                refreshLenses()
                let clamped = clampZoomFactor(factor)
                settings.zoom = clamped
                // A lens that can't reach the asked zoom is where a gesture goes on from.
                if generation == zoomRequestGeneration { requestedDisplayZoom = clamped * base }
                backend.setZoomFactor(clamped, rampRate: nil)
                updateActivePreset()
                scheduleSave()
                releaseZoomTarget(after: 0, generation: generation)
                applyPendingLensChange()
            }
            return
        }

        let clamped = clampZoomFactor(factor)
        settings.zoom = clamped
        // A zoom saved for a lens names that lens with it. The camera is on this one, whatever an earlier choice left
        // in the settings, and a cold start opens the lens they name at this factor.
        if settings.lensID != targetLens.id { settings.lensID = targetLens.id }
        let reached = clamped * base
        requestedDisplayZoom = reached
        if animated {
            // The value this lens reaches, so a button never names one the glide stops short of.
            holdZoomTarget(reached, generation: generation)
            rampZoom(toFactor: clamped, from: from, to: reached, generation: generation)
        } else {
            backend.setZoomFactor(clamped, rampRate: nil)
        }
        // The destination's button lights at the request, while the zoom still moves, as a tap on it would. The target
        // holds the button back only during a change of lens, whose lit button names the lens still to come.
        updateActivePreset(factor: clamped, force: true)
        scheduleSave()
    }

    /// Whatever was asked for last while a lens switch was in flight or photos were being saved: a lens or a zoom.
    private func applyPendingLensChange() {
        if let preset = pendingPreset {
            // A shot that started during the swap keeps its lens, and select would refuse the choice now: it stays
            // parked for the shot's end (replayParkedLensChange).
            guard !activity.isBusy else { return }
            pendingPreset = nil
            select(preset, haptic: false, replaying: true)
        } else if let pending = pendingZoom {
            pendingZoom = nil
            setDisplayZoom(pending.value, animated: pending.animated, continuing: pending.continuing)
        }
    }

    /// A lens or zoom choice parked behind a shot, a countdown or a bracket, taken as soon as the camera is free:
    /// nothing running, no photo still saving, no swap on its way.
    private func replayParkedLensChange() {
        guard pendingPreset != nil || pendingZoom != nil, activity == .idle, photosInFlight == 0,
              !lensSwitchInFlight, !bracketInProgress, backendRunning else { return }
        applyPendingLensChange()
    }

    func flipCamera() {
        guard !activity.isBusy, photosInFlight == 0 else { return }
        // The active lens only changes once a switch lands, so taps during one go by the camera asked for last.
        let headingID = pendingPreset?.lensID ?? (lensSwitchInFlight ? settings.lensID : nil)
        let onFront = headingID.flatMap { id in lenses.first(where: { $0.id == id })?.isFront } ?? (activeLens?.isFront == true)
        if onFront {
            let back = lensPresets.first(where: { $0.id == lastBackPresetID })
                ?? lensPresets.first(where: { preset in
                    guard let lens = lenses.first(where: { $0.id == preset.lensID }) else { return false }
                    return lens.kind == .wide && abs(preset.zoomFactor - 1) < 0.01
                })
                ?? lensPresets.first(where: { preset in lenses.first(where: { $0.id == preset.lensID })?.isFront == false })
            if let back { select(back) }
        } else {
            // During a switch the active preset can still be the selfie one, which would trap the flip there.
            if let id = activePresetID, let preset = lensPresets.first(where: { $0.id == id }),
               lenses.first(where: { $0.id == preset.lensID })?.isFront == false {
                lastBackPresetID = id
            }
            let front = lensPresets.first(where: { preset in lenses.first(where: { $0.id == preset.lensID })?.isFront == true })
            if let front { select(front) }
        }
    }

    /// Turns the video light on or off. It only lights in VIDEO, and goes off when the mode or the app changes.
    func setTorch(_ on: Bool) {
        let wanted = on && settings.mode == .video && capabilities.hasTorch
        guard wanted != torchOn else { return }
        torchOn = wanted
        backend.setTorch(level: wanted ? torchLevel : nil)
        Haptics.tap()
    }

    /// Brightness of the video light, 0...1 (the menu offers a few steps). Choosing one turns the light on.
    func setTorchLevel(_ level: Double) {
        guard level.isFinite else { return }
        torchLevel = min(max(level, 0.05), 1)
        if torchOn {
            backend.setTorch(level: torchLevel)
            Haptics.tap()
        } else {
            setTorch(true)
        }
    }

    private func turnTorchOff() {
        guard torchOn else { return }
        torchOn = false
        backend.setTorch(level: nil)
    }

    // MARK: - Exposure

    /// nil = auto. Values longer than the hardware maximum become stacked exposures.
    func setShutter(_ seconds: Double?) {
        let value = seconds.map { max($0, 1.0 / 1_000_000) }
        // NIGHT's shutter is its duration, which every phone sets. Elsewhere it is a shutter speed.
        guard settings.mode.usesStacking || allowsManualShutter else { return }
        switch settings.mode {
        case .long:
            guard let value else { return }
            setLongExposureSeconds(value)
        case .night:
            // The night shot's time, as its dial sets it; nil is the camera's own. It stays in NIGHT.
            setNightSeconds(value)
        case .video:
            let limit = 1.0 / max(recordedVideo.frameRate, 1)
            updateSettings { $0.manual.shutter = value.map { min($0, limit) } }
        case .manual:
            updateSettings { $0.manual.shutter = value }
        case .photo:
            guard let value else { return }
            switchToManual { $0.manual.shutter = value }
        }
    }

    /// nil = auto, or in LONG the ISO the scene fixes.
    func setISO(_ iso: Double?) {
        let value = iso.map { min(max($0, capabilities.exposure.iso.lowerBound), capabilities.exposure.iso.upperBound) }
        switch settings.mode {
        case .manual, .long, .video:
            updateSettings { $0.manual.iso = value }
        case .photo, .night:
            guard let value else { return }
            switchToManual { $0.manual.iso = value }
        }
    }

    /// nil = auto, or in LONG the aperture the scene asks for. Does nothing on lenses without an iris.
    func setAperture(_ fNumber: Double?) {
        guard capabilities.supportsVariableAperture else { return }
        let range = capabilities.exposure.aperture
        let value = fNumber.map { min(max($0, range.lowerBound), range.upperBound) }
        switch settings.mode {
        case .manual, .long, .video:
            updateSettings { $0.manual.aperture = value }
        case .photo, .night:
            guard let value else { return }
            switchToManual { $0.manual.aperture = value }
        }
    }

    func setBias(_ ev: Double) {
        let range = capabilities.biasRange
        let value = min(max(ev, range.lowerBound), range.upperBound)
        if settings.mode == .night {
            updateSettings { $0.night.biasEV = value }
        } else {
            updateSettings { $0.manual.bias = value }
        }
    }

    func toggleAELock() {
        if aeLocked {
            releaseLock()
        } else {
            aeLocked = true
            // The metering point stays where it was, so the light the meter reads right now is what the lock holds.
            lockMeterTask?.cancel()
            lockedMeter = (liveMeteredProduct, settings.night.biasEV)
        }
        Haptics.tap()
        // The button's lock and the corner badge show it, so only VoiceOver hears it.
        announce(aeLocked ? Self.lockAnnouncement(focus: false, exposure: true) : "Exposure lock off")
        scheduleApply(.exposure)
    }

    // MARK: - Focus

    /// nil = continuous autofocus, or in LONG the distance the scene holds.
    func setManualFocus(_ lensPosition: Double?) {
        // AUTO in the focus dial's header: autofocus needs no magnifier.
        if lensPosition == nil { setMagnified(false) }
        guard lensPosition == nil || capabilities.supportsManualFocus else { return }
        var value = lensPosition.map { min(max($0, 0), 1) }
        // The far end is where a scene that focuses at infinity already holds the lens. Kept as the person's, it
        // would follow them out of the scene and focus every other mode at infinity.
        if let position = value, position >= 1, sceneRecipe?.focusAtInfinity == true {
            value = nil
        }
        updateSettings { $0.focus = value.map { FocusSetting.manual(lensPosition: $0) } ?? .auto }
    }

    /// Tap: focus and meter there. lock = long press, which also locks exposure (AE/AF LOCK).
    func tapToFocus(at layerPoint: CGPoint, lock: Bool) {
        // A focus bracket sets every lens position itself.
        guard !bracketInProgress, let devicePoint = backend.devicePoint(fromLayerPoint: layerPoint) else { return }
        if settings.mode == .photo || settings.mode == .night, settings.focus.lensPosition != nil {
            // Manual focus brought over from MANUAL has no control here to undo it, and a tap means "focus here".
            // Written directly: updateSettings would send continuous AF a moment later and undo a long press's AF.
            settings.focus = .auto
            scheduleSave()
            applyAnalysis()
            applyCameraControls()
        }
        // A scene that holds focus at infinity counts as manual focus: the tap moves the metering point and the
        // lens stays where the stars are sharp.
        let focusIsAuto = effectiveFocus.lensPosition == nil
        let request = currentExposureRequest()
        let exposureIsAuto = request.locks.isAllAuto
        // Spot and whole frame metering follow the tap as long as the meter decides something: a value auto exposure
        // still sets, or a stack's auto ISO held at a limit. Only a fully manual exposure leaves the meter be.
        let metersHere = stackISOLimit != nil
            || !request.locks.isFullyManual(variableAperture: capabilities.supportsVariableAperture)
        // Nothing to focus and nothing to meter (star trails, fireworks on a fixed lens): a square would say the tap
        // did something.
        guard focusIsAuto || metersHere else { return }
        focusPoint = layerPoint
        backend.setPointOfInterest(devicePoint, focus: focusIsAuto, exposure: metersHere)
        if focusIsAuto {
            // A tap keeps autofocus working at the new point, so the next subject isn't shot at the old distance.
            // A long press focuses once and holds, the AF half of AE/AF LOCK.
            backend.apply(focus: lock ? .autoOnce : .continuousAuto)
        }
        focusHeld = lock && focusIsAuto
        if lock {
            aeLocked = exposureIsAuto
            // Manual focus or a manual exposure has nothing to hold, so only what is locked is named. The square's
            // label shows it, or the corner badge where the label is out of sight, so only VoiceOver hears it.
            if focusHeld || aeLocked {
                Haptics.stop()
                announce(Self.lockAnnouncement(focus: focusHeld, exposure: aeLocked))
            }
        } else if aeLocked {
            aeLocked = false
        }
        scheduleApply(.exposure)
        reticleTask?.cancel()
        guard !lock else { return }
        reticleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, !self.aeLocked else { return }
            self.focusPoint = nil
        }
    }

    /// A long press holds the focus distance it found, with the exposure (aeLocked) or, where the exposure has
    /// nothing auto to hold, alone.
    var focusLocked: Bool { focusHeld }

    /// What VoiceOver hears for a lock, in the words the square's label is read with.
    private static func lockAnnouncement(focus: Bool, exposure: Bool) -> String {
        focus && exposure ? "Exposure and focus locked" : (exposure ? "Exposure locked" : "Focus locked")
    }

    /// Ends AE LOCK or AE/AF LOCK: exposure follows its request again, a held focus goes back to autofocus, and
    /// the lock's square goes with it.
    private func releaseLock() {
        if aeLocked {
            aeLocked = false
            scheduleApply(.exposure)
        }
        guard focusHeld else { return }
        endFocusHold()
        backend.apply(focus: currentFocusRequest())
    }

    /// A focus request other than the hold's own is going to the camera, and it ends the distance a long press was
    /// holding. The viewfinder stops showing that lock, and its square goes unless it still marks a held exposure.
    private func endFocusHold() {
        guard focusHeld else { return }
        focusHeld = false
        guard !aeLocked else { return }
        reticleTask?.cancel()
        focusPoint = nil
    }

    /// The exposure freezes when AE locks, but the meter keeps reading the recomposed frame, and NIGHT plans from
    /// the meter. Its plan keeps the light measured at the lock instead.
    private func snapshotLockedMeter() {
        lockMeterTask?.cancel()
        lockMeterTask = nil
        lockedMeter = nil
        guard aeLocked else { return }
        // A long press meters once at its point before the exposure holds. About three preview frames and one
        // readings poll let the meter see the new point; any longer and a recompose right after the press would end
        // up in the snapshot.
        let settle = min(max(0.2, 3 * readings.exposureSeconds + 0.1), 1.5)
        lockMeterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            while !Task.isCancelled, self?.readings.isAdjustingExposure == true {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, let self, self.aeLocked else { return }
            self.lockedMeter = (self.liveMeteredProduct, self.settings.night.biasEV)
        }
    }

    // MARK: - White balance

    /// Auto gives the white balance back to the camera, or in LONG to the scene where it holds one.
    func setWhiteBalance(_ setting: WhiteBalanceSetting) {
        updateSettings { $0.whiteBalance = setting }
    }

    /// Switches to a custom temperature, keeping the current tint.
    func setKelvin(_ kelvin: Double) {
        let range = WhiteBalanceMath.kelvinRange
        let k = min(max(kelvin, range.lowerBound), range.upperBound)
        let setting = chosenWhiteBalance(kelvin: k, tint: effectiveWhiteBalance.tintValue)
        updateSettings { $0.whiteBalance = setting }
    }

    func setTint(_ tint: Double) {
        let range = WhiteBalanceMath.tintRange
        let t = min(max(tint, range.lowerBound), range.upperBound)
        // A scene's temperature stays when its tint is the first thing changed.
        let k = effectiveWhiteBalance.kelvinValue ?? readings.kelvin
        let setting = chosenWhiteBalance(kelvin: k, tint: t)
        updateSettings { $0.whiteBalance = setting }
    }

    /// A temperature and tint the person picked, as they are kept: auto where they are the ones the scene already
    /// runs, since kept as the person's they would follow them out of the scene into every mode. The margins are
    /// the ones the strip's chips use to tell the scene's value from the person's.
    private func chosenWhiteBalance(kelvin: Double, tint: Double) -> WhiteBalanceSetting {
        if let scene = sceneRecipe?.kelvin, capabilities.supportsCustomWhiteBalance,
           abs(kelvin - scene) < 1, abs(tint) < 0.5 {
            return .auto
        }
        return .kelvin(kelvin, tint: tint)
    }

    /// Locks white balance to whatever is in the middle of the frame being neutral gray.
    func setWhiteBalanceFromGrayCard() {
        guard capabilities.supportsCustomWhiteBalance else { return }
        adoptNextWhiteBalanceReading = true
        backend.apply(whiteBalance: .grayWorld)
        Haptics.tap()
        showToast("White balance set", symbol: "eyedropper")
    }

    // MARK: - Night and long exposure

    /// Manual shutter speeds: the shutter chip and dial in PHOTO, MANUAL and VIDEO, the Camera Control's shutter,
    /// the frame shutter of Blur and Trails, and night shots and long exposures shorter than a second. The iPhone 18
    /// Pro and later Pros only; the Simulator's camera too, so every control can be tried there.
    private(set) var allowsManualShutter: Bool

    /// What the night shot's duration can be set to: up to half an hour on every phone, and below a second where
    /// manual shutter speeds are offered.
    var nightSecondsRange: ClosedRange<Double> {
        let range = NightModePlanner.secondsRange
        return allowsManualShutter ? NightModePlanner.shortestManualSeconds...range.upperBound : range
    }

    /// The shortest long exposure. Below a second it is a shutter speed more than a duration.
    var shortestLongSeconds: Double { allowsManualShutter ? 0.25 : 1 }

    /// nil = automatic duration from the light level.
    func setNightSeconds(_ seconds: Double?) {
        let range = nightSecondsRange
        updateSettings { $0.night.seconds = seconds.map { min(max($0, range.lowerBound), range.upperBound) } }
    }

    /// The time stays the scene's own to change: every scene offers several.
    func setLongExposureSeconds(_ seconds: Double) {
        updateSettings { $0.longExposure.seconds = min(max(seconds, shortestLongSeconds), 1800) }
    }

    /// Picks what LONG mode is pointed at and loads that scene's blend, time, bulb, frame and alignment. Custom keeps
    /// the values.
    func setLongExposureScene(_ scene: LongExposureScene) {
        // The scene already on has nothing to load.
        guard !activity.isBusy, scene != settings.longExposure.scene else { return }
        // A lock holds the exposure and the focus of the scene being left.
        releaseLock()
        // Stars and Northern lights start at a time that keeps the stars as points at this zoom. The time stays the
        // scene's own to change, so the scene stays a scene.
        let start = scene.limitsStarTrails ? sceneStartSeconds(scene) : nil
        updateSettings {
            $0.longExposure.apply(scene)
            if let start { $0.longExposure.seconds = start }
        }
    }

    /// The time a scene starts at: its recipe's, or in Stars and Northern lights the longest of its times that keeps
    /// stars as points at this zoom (the limit only ever shortens it). nil for Custom, which has no time of its own.
    private func sceneStartSeconds(_ scene: LongExposureScene) -> Double? {
        guard let recipe = scene.recipe else { return nil }
        let limit = scene.limitsStarTrails ? sharpStarSecondsAtThisZoom : nil
        return StarTrails.startingSeconds(recipe: recipe, limit: limit, shortest: shortestLongSeconds)
    }

    /// The longest time that keeps stars as points at this zoom, in Stars and Northern lights; nil elsewhere. The
    /// duration dial marks the times past it.
    var starSharpSeconds: Double? {
        guard settings.mode == .long, settings.longExposure.scene.limitsStarTrails else { return nil }
        return sharpStarSecondsAtThisZoom
    }

    /// 400 over the equivalent focal length of the lens in use at its zoom, the one the night plan and the crosses
    /// use. The magnifier leaves the zoom the readings report alone, so the limit holds still while focusing.
    private var sharpStarSecondsAtThisZoom: Double? {
        StarTrails.sharpSeconds(equivalentFocalLength: capabilities.lens.equivalentFocalLength * max(readings.zoomFactor, 1))
    }

    /// A pick from NIGHT's scene menu: the night shot (nil), or a long exposure scene. The two are different ways of
    /// taking the shot, so the pick changes the mode underneath while the carousel stays on NIGHT.
    func selectNightScene(_ scene: LongExposureScene?) {
        guard !activity.isBusy else { return }
        let mode: CaptureMode = scene == nil ? .night : .long
        let enteringLong = mode == .long && settings.mode != .long
        if settings.mode != mode { setMode(mode) }
        // setMode refuses while photos are still being saved or an intervalometer runs.
        guard settings.mode == mode else {
            noteModeChangeRefused()
            return
        }
        guard let scene else {
            clearHandSetValues()
            return
        }
        let fromScene = settings.longExposure.scene != .custom
        setLongExposureScene(scene)
        // The scene kept from the last visit loads nothing, and its time may be one that trails the stars at this
        // zoom: picked from the night shot, it starts inside the limit as a fresh pick does. A time still inside it
        // stays, and the scene stays a scene.
        if enteringLong, scene.limitsStarTrails, let limit = sharpStarSecondsAtThisZoom,
           settings.longExposure.seconds > limit * 1.02, let start = sceneStartSeconds(scene) {
            setLongExposureSeconds(start)
        }
        // Every choice but Manual night is automatic: the scene, or the camera, sets ISO, aperture, white balance
        // and focus, and there are no chips to show values set by hand.
        if scene != .custom { clearHandSetValues() }
        // Manual night is a long exposure of the person's own making. Picked from a scene, it starts as a long
        // shutter would (frames added, Real), not as the scene's blur or trails; picked again, it keeps what was set.
        if scene == .custom, fromScene { setLongExposureBlend(.additive) }
    }

    /// ISO, aperture, white balance and focus back to auto. They are MANUAL's too, so its setup goes with them;
    /// in NIGHT nothing but Manual night has a chip to show them.
    private func clearHandSetValues() {
        updateSettings {
            $0.manual.iso = nil
            $0.manual.aperture = nil
            $0.whiteBalance = .auto
            $0.focus = .auto
        }
    }

    /// The scene's recipe while LONG is on with a scene chosen; nil in other modes and for Custom.
    var sceneRecipe: LongExposureRecipe? {
        settings.mode == .long ? settings.longExposure.recipe : nil
    }

    // A blend, frame, bulb or alignment set by hand is no longer the scene's recipe, so a change in one of them
    // leaves the scene for Custom (commit).

    func setLongExposureBlend(_ blend: StackBlend) {
        updateSettings {
            // Custom has no recipe for commit to compare with. Alignment still where its blend put it (on for Blur,
            // off for Real and Trails) was not set by hand, so it follows the new blend, as on the way out of a scene.
            if $0.longExposure.scene == .custom, $0.longExposure.blend != blend,
               $0.longExposure.align == ($0.longExposure.blend == .average) {
                $0.longExposure.align = blend == .average
            }
            $0.longExposure.blend = blend
        }
    }

    /// Shutter for each Blur or Trails frame; nil leaves it to auto exposure.
    func setLongExposureFrameSeconds(_ seconds: Double?) {
        let range = capabilities.exposure.seconds
        let frame = seconds.map { min(max($0, range.lowerBound), range.upperBound) }
        // Behind a closed iris a scene runs a longer frame than the one it stores (longFrameSeconds). Picking the
        // stored one then changes nothing in the settings, so commit can't tell it was picked by hand: the scene
        // would stay and the pick would do nothing. A pick that differs from the frame in force leaves the scene.
        let leavesScene = sceneRecipe != nil && frame != longFrameSeconds
        updateSettings {
            $0.longExposure.frameSeconds = frame
            if leavesScene { $0.longExposure.scene = .custom }
        }
    }

    func setBulb(_ enabled: Bool) {
        updateSettings { $0.longExposure.bulb = enabled }
    }

    // MARK: - Capture

    /// Tap on the shutter: starts the timer, takes the photo, starts a stack, or starts/stops video.
    func shutterPressed() {
        switch activity {
        case .recording:
            stopRecording()
            return
        case .stacking:
            if stackJustStartedFromCountdown {
                cancelCapture()
                return
            }
            // A second tap ends a bulb or long exposure and keeps what it has, like releasing a cable release.
            backend.finishStackEarly()
            motionMonitor.endDrift()
            noteStackFinishing()
            return
        case .countdown:
            cancelSchedule()
            return
        case .capturing, .saving:
            // An intervalometer, or a focus or white balance bracket, is one capture that the shutter stops.
            if intervalometer != nil || bracketInProgress { stopCapture() }
            return
        case .idle:
            // Between intervalometer shots the shutter stops the sequence rather than starting a second one.
            if intervalometer != nil {
                stopCapture()
                return
            }
            // A camera's half press: while the magnifier enlarges the middle, the first press only brings the whole
            // frame back, so nothing is ever taken cropped, and the next press shoots.
            if isMagnified {
                setMagnified(false)
                Haptics.tap()
                announceHalfPress()
                return
            }
        }
        guard canCapture else {
            if !settings.capture.isValid {
                showToast("Pick a photo format in Settings.", symbol: "exclamationmark.triangle")
            }
            return
        }
        if photosAccessBlocksShot() { return }
        if settings.mode == .video {
            startRecording()
            return
        }
        // Earlier photos are still being processed and saved: only another plain photo can start alongside them.
        if photosInFlight > 0, !(pressTakesPlainPhoto && photosInFlight < maxPhotosInFlight) { return }
        var schedule = settings.capture.schedule
        // A scene shot from a tripod waits a moment first, so the tap on the shutter isn't in the picture, and so
        // does NIGHT on a tripod. A self timer counts toward the wait but never shortens it, and a bulb starts when it
        // is told to.
        let settle = isBulbMode ? 0 : settleSeconds
        isSettling = settle > 0 && schedule.delay == 0
        if settle > 0 {
            schedule.delay = max(schedule.delay, settle)
        }
        // The status pill keeps what this shot needs from the press on; the plan moves with the light meanwhile.
        captureNeed = liveSteadyNeed
        if schedule.isOff || isBulbMode {
            scheduleTask = Task { [weak self] in
                await self?.performCapture(bulb: self?.isBulbMode ?? false, releaseAtExposure: true)
            }
        } else {
            // The wait is there to let the phone come to rest, so nothing taps it on the way, a timer's count
            // included.
            runSchedule(schedule, silentCountdown: settle > 0)
        }
    }

    /// With adding to Photos turned off a shot has nowhere to go, and a long night stack would be lost at the end.
    /// Asking before the shot, with a way to Settings, beats a toast after it. Only a press that would start one asks:
    /// limited, full and not yet asked all let the save through.
    private func photosAccessBlocksShot() -> Bool {
        let addAccess = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard addAccess == .denied || addAccess == .restricted else { return false }
        isPhotosAccessAlertShown = true
        return true
    }

    /// A half press takes nothing and plays no shutter sound. Someone who can't see the whole frame come back would
    /// take it for a photo, so VoiceOver says what happened, whatever Speak status is set to.
    private func announceHalfPress() {
        let next = settings.mode == .video ? "start recording" : "take the photo"
        announce("Whole frame. Press again to \(next).")
    }

    /// A press as a countdown runs out was meant to cancel it, and the shot it started has nothing yet: ended
    /// early, it would save a dark, nearly empty picture.
    private var stackJustStartedFromCountdown: Bool {
        guard let ended = countdownEndedAt, Date().timeIntervalSince(ended) < 0.5 else { return false }
        return (stackProgress?.framesCaptured ?? 0) == 0
    }

    /// AVCapturePhotoOutput takes the next photo while it still processes the last ones. Each one in flight holds
    /// a full-size image until it is saved, so a run of taps stops here. PNG and TIFF photos wait as lossless HEIF
    /// files of tens of MB and are converted one at a time with several hundred MB at 48 MP, so fewer of those queue.
    private var maxPhotosInFlight: Int {
        let capture = settings.capture
        guard capture.processedFormat.isLossless else { return 4 }
        let counts = capabilities.photoDimensions.map { $0.width > 0 && $0.height > 0 ? $0.pixelCount : 0 }
        let pixels = capture.resolution.pick(amongPixelCounts: counts).map { counts[$0] } ?? 0
        return pixels > 24_000_000 ? 2 : 4
    }

    /// A press takes one plain photo: no timer, no bracket and no stacked shutter. Only those overlap.
    private var pressTakesPlainPhoto: Bool {
        guard settings.capture.schedule.isOff, settings.capture.bracket.isOff else { return false }
        switch settings.mode {
        case .photo: return true
        case .manual: return !shutterIsStacked
        case .night, .long, .video: return false
        }
    }

    /// Press and hold in LONG mode with bulb on: the exposure runs until release.
    func shutterHoldBegan() {
        guard isBulbMode, activity == .idle, photosInFlight == 0 else { return }
        // The half press, for a bulb: the hold brings the whole frame back and starts nothing.
        if isMagnified {
            setMagnified(false)
            Haptics.tap()
            announceHalfPress()
            return
        }
        guard canCapture else { return }
        // A held bulb is the longest shot there is, and the one most worth asking about before it starts.
        if photosAccessBlocksShot() { return }
        bulbHoldActive = true
        // A finger on the shutter keeps the screen lit.
        updateDimming()
        scheduleTask = Task { [weak self] in
            await self?.performCapture(bulb: true)
        }
    }

    func shutterHoldEnded() {
        guard bulbHoldActive else { return }
        bulbHoldActive = false
        if activity == .stacking {
            backend.finishStackEarly()
            motionMonitor.endDrift()
            noteStackFinishing()
        }
        updateDimming()
    }

    /// Stops what is running and keeps the result (stack so far, intervalometer, timer).
    func stopCapture() {
        // A stop as the countdown runs out was meant for the countdown, whichever button sent it.
        if activity == .stacking, stackJustStartedFromCountdown {
            cancelCapture()
            return
        }
        // A bracket only sees the stop once the photo in progress is saved.
        if bracketInProgress { bracketStopping = true }
        cancelSchedule()
        if activity == .stacking {
            backend.finishStackEarly()
            // No more frames come in, so the crosses have nothing to follow.
            motionMonitor.endDrift()
            noteStackFinishing()
        }
        if activity == .recording {
            stopRecording()
        }
    }

    /// A running stack was told to finish and keeps what it has. The stack goes on putting the picture together
    /// for a while, and the screen says so whichever button stopped it: lit for Processing, with no pill asking to
    /// keep still. Never for a cancel, which ends the shot without a picture.
    private func noteStackFinishing() {
        guard activity == .stacking, !isFinishingStack else { return }
        isFinishingStack = true
        refreshSteadyStatus()
        updateDimming()
    }

    /// Aborts a running stack and discards it.
    func cancelCapture() {
        cancelSchedule()
        if activity == .stacking {
            backend.cancelStack()
            motionMonitor.endDrift()
        }
    }

    private var isBulbMode: Bool {
        settings.mode == .long && settings.longExposure.bulb
    }

    /// The wait before a shot that has to start still: the tripod scene's, or a second for NIGHT on a tripod (the
    /// Tripod choice, or Automatic while the phone is steady), where the press itself would shake the first frames.
    private var settleSeconds: Double {
        if let recipe = sceneRecipe { return recipe.settleSeconds }
        if settings.mode == .night, nightStability != .handheld { return Self.nightTripodSettleSeconds }
        return 0
    }

    private func cancelSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        intervalometer = nil
        isSettling = false
        if isWaitingForSteady { isWaitingForSteady = false }
        countdownEndedAt = nil
        timerSecondsForShot = nil
        if case .countdown = activity {
            // A countdown called off takes its shot's need with it. A stack an intervalometer stop ends keeps its own.
            captureNeed = nil
            activity = .idle
        }
    }

    private func runSchedule(_ schedule: CaptureSchedule, silentCountdown: Bool = false) {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            if schedule.delay > 0 {
                // A settle (the silent countdown) waits a little longer for a phone that still moves.
                let completed = await self.countdown(schedule.delay, haptics: !silentCountdown,
                                                     untilSteady: silentCountdown)
                guard completed else { return }
                // The first shot's metadata says how long it waited, any wait for the phone included.
                self.timerSecondsForShot = Date().timeIntervalSince(start)
            }
            for index in 0..<schedule.shots {
                if Task.isCancelled { break }
                if schedule.shots > 1 {
                    self.intervalometer = IntervalometerStatus(shot: index + 1, total: schedule.shots, nextShotAt: nil)
                }
                await self.performCapture(bulb: false)
                self.timerSecondsForShot = nil
                if Task.isCancelled { break }
                let finishedAt = Date().timeIntervalSince(start)
                guard let next = schedule.nextStartTime(afterShot: index, finishedAt: finishedAt) else { break }
                let wait = next - finishedAt
                if wait > 0 {
                    self.intervalometer?.nextShotAt = Date().addingTimeInterval(wait)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
            self.intervalometer = nil
            // Each capture leaves .capturing or .stacking itself; clearing more here could end a newer one.
            if case .countdown = self.activity {
                self.activity = .idle
            }
        }
    }

    /// Counts down whole seconds. Returns false when cancelled. haptics: false for a settle, during which nothing
    /// may tap the phone (Haptics.isSuppressed). untilSteady: a settle, which waits a little longer for a phone that
    /// still moves when it runs out.
    private func countdown(_ seconds: Double, haptics: Bool = true, untilSteady: Bool = false) async -> Bool {
        countdownIsSilent = !haptics
        // A self timer's count is said out loud (Speak status); a settle alone has nothing to count for anyone.
        let speaks = !isSettling
        var remaining = seconds
        while remaining > 0 {
            if Task.isCancelled { return false }
            let shown = Int(remaining.rounded(.up))
            activity = .countdown(remaining: shown)
            if haptics { Haptics.tap() }
            if speaks { speak(String(shown)) }
            let step = remaining - (remaining.rounded(.up) - 1)
            let sleep = step > 0 ? step : 1
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
            remaining -= sleep
        }
        if Task.isCancelled { return false }
        if untilSteady {
            guard await waitUntilSteady() else { return false }
        }
        isSettling = false
        countdownEndedAt = Date()
        countdownRanOut = true
        activity = .idle
        countdownRanOut = false
        return true
    }

    /// A tripod still swaying from the press would smear the first frames. The countdown holds on its last second
    /// for up to settleExtraSeconds while the sensor says the phone moves. Without a sensor it can't tell, and
    /// doesn't wait. Returns false when cancelled.
    private func waitUntilSteady() async -> Bool {
        guard motion.isAvailable, !motion.isSteady else { return true }
        isWaitingForSteady = true
        defer { if isWaitingForSteady { isWaitingForSteady = false } }
        let deadline = Date().addingTimeInterval(Self.settleExtraSeconds)
        while !motion.isSteady, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }

    /// One capture in the current mode, awaited to completion. releaseAtExposure: a press without a timer, whose
    /// plain photo frees the shutter once it is exposed.
    private func performCapture(bulb: Bool, releaseAtExposure: Bool = false) async {
        switch settings.mode {
        case .video:
            return
        case .night:
            await performStack(request: makeStackRequest(plan: nightPlan, bulb: false, noiseReduction: 0.5))
        case .long:
            var plan = longPlan
            if bulb {
                // Bulb runs until release; the cap only stops a forgotten exposure.
                let frame = max(plan.frameSeconds, 1.0 / 30.0)
                // Clamped before Int(_:) because a corrupted setting could otherwise overflow and trap.
                let cap = min(max(settings.longExposure.maxBulbSeconds, 1), 7200)
                plan.frameCount = max(1, Int((cap / frame).rounded(.up)))
            }
            await performStack(request: makeStackRequest(plan: plan, bulb: bulb, noiseReduction: 0))
        case .manual where shutterIsStacked:
            await performStack(request: makeStackRequest(plan: manualStackPlan, bulb: false, noiseReduction: 0))
        case .photo, .manual:
            switch settings.capture.bracket.kind {
            case .focus:
                await performFocusBracket()
            case .whiteBalance:
                await performWhiteBalanceBracket()
            case .exposure, .off:
                let bracket = settings.capture.bracket
                // An exposure bracket keeps the shutter until its last frame is in.
                await performPhoto(bracket: bracket, releaseAtExposure: releaseAtExposure && bracket.isOff)
            }
        }
    }

    /// releaseAtExposure ends .capturing at the exposure (cameraBackendWillCapture) while this task still awaits
    /// processing and the save, so the next photo can start. position: this photo's place in a focus or white
    /// balance bracket, for its metadata.
    private func performPhoto(bracket: BracketPlan, position: BracketPosition? = nil,
                              releaseAtExposure: Bool = false) async {
        photoGeneration &+= 1
        let generation = photoGeneration
        photosInFlight += 1
        releasesAtExposure = releaseAtExposure
        activity = .capturing
        defer {
            photosInFlight -= 1
            // An older photo that finishes late leaves a newer one's state alone; a bracket holds .capturing to
            // its last frame.
            if generation == photoGeneration {
                releasesAtExposure = false
                if activity == .capturing, !bracketInProgress { activity = .idle }
            }
            // A lens or zoom asked for while photos were saving waits for the last of them.
            if photosInFlight == 0, !lensSwitchInFlight, !activity.isBusy, backendRunning {
                applyPendingLensChange()
            }
            // The gallery opened while this photo was saving stops the camera once it is in.
            updateGalleryPause()
        }
        let request = makePhotoRequest(bracket: bracket, position: position)
        // Read before the shot, since the zoom can change while it is processed.
        let rawNeedsOneX = rawBlockedByZoom
        let inMacro = isMacro
        do {
            let results = try await backend.capturePhoto(request)
            handle(results)
            if rawNeedsOneX {
                noteRawLeftOut(request, results: results, inMacro: inMacro)
            } else {
                // A photo that could keep its RAW ends the run, so the next zoomed one is told again.
                rawNoticeForMacro = nil
            }
        } catch {
            report(error)
        }
    }

    /// AVFoundation leaves Bayer RAW out of zoomed shots, so only the processed photo is saved. Said once for each
    /// run of zoomed photos and for each reason: RAW in the quick settings shows it too, but that panel is closed
    /// while shooting. Not worded as "needs 1x": macro is a crop with the 1x button lit, and the 8x button only needs
    /// 4x. Worded about the photo, since the zoom may have changed by the time it is saved.
    private func noteRawLeftOut(_ request: PhotoRequest, results: [CaptureResult], inMacro: Bool) {
        guard rawNoticeForMacro != inMacro, !results.isEmpty, results.allSatisfy({ $0.kind == .photo && $0.savedToLibrary }) else { return }
        rawNoticeForMacro = inMacro
        // RAW only falls back to HEIF where the RAW can't be taken.
        let saved = request.processedFormat.saved.title
        let reason = inMacro ? "No RAW in macro." : "No RAW in zoomed photos."
        showToast("\(reason) Saved \(saved) only.", symbol: "exclamationmark.triangle")
    }

    private func performFocusBracket() async {
        let center = effectiveFocus.lensPosition ?? readings.lensPosition
        let plan = settings.capture.bracket
        let positions = plan.focusPositions(center: center)
        // One id for the set, so a reader can put the photos back together.
        let group = UUID()
        // One capture from the first frame to the last: the shutter stops it, and lens, mode and focus stay put
        // between frames.
        bracketInProgress = true
        activity = .capturing
        defer {
            bracketInProgress = false
            bracketStopping = false
            if activity == .capturing { activity = .idle }
        }
        for (index, position) in positions.enumerated() {
            if Task.isCancelled { break }
            backend.apply(focus: .manual(position))
            // The lens needs a moment to travel; there is no completion callback across the backend boundary.
            try? await Task.sleep(nanoseconds: 350_000_000)
            // A stopped bracket's sleep returns at once and would still take one more frame.
            if Task.isCancelled { break }
            let place = BracketPosition(kind: .focus, index: index + 1, count: positions.count, step: plan.step,
                                        value: position, group: group)
            await performPhoto(bracket: .off, position: place)
        }
        // An AE/AF lock goes back to the distance it held; continuous AF would quietly end it.
        backend.apply(focus: focusHeld ? .manual(center) : currentFocusRequest())
    }

    private func performWhiteBalanceBracket() async {
        let whiteBalance = effectiveWhiteBalance
        let center = whiteBalance.kelvinValue ?? readings.kelvin
        let tint = whiteBalance.tintValue
        let plan = settings.capture.bracket
        let temperatures = plan.kelvinValues(center: center)
        let group = UUID()
        bracketInProgress = true
        activity = .capturing
        defer {
            bracketInProgress = false
            bracketStopping = false
            if activity == .capturing { activity = .idle }
        }
        for (index, kelvin) in temperatures.enumerated() {
            if Task.isCancelled { break }
            backend.apply(whiteBalance: .temperature(kelvin: kelvin, tint: tint))
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { break }
            let place = BracketPosition(kind: .whiteBalance, index: index + 1, count: temperatures.count,
                                        step: plan.step, value: kelvin, group: group)
            await performPhoto(bracket: .off, position: place)
        }
        backend.apply(whiteBalance: currentWhiteBalanceRequest())
    }

    private func performStack(request: StackRequest) async {
        isFinishingStack = false
        // The pill keeps the need of the plan that runs, whatever the light does to the plan in view. It leans as the
        // framing pill did, toward the need the press took (an intervalometer's later shots: the one on show), or a
        // frame near the hand limit would change the message as the shot starts.
        captureNeed = settings.mode == .long
            ? longSteadyNeed(plan: request.plan, leaning: captureNeed ?? shownSteadyNeed) : liveSteadyNeed
        dimmer.resetWake()
        // Set before the activity, so everything that follows .stacking already sees the shot's length.
        stackProgress = StackProgress(
            framesCaptured: 0,
            framesPlanned: request.isBulb ? 0 : request.plan.frameCount,
            elapsed: 0,
            estimatedTotal: request.isBulb ? nil : request.plan.estimatedDuration(),
            preview: nil
        )
        activity = .stacking
        // The crosses start from where the camera points now; zoom can't change while frames come in.
        motionMonitor.beginDrift(into: drift,
                                 equivalentFocalLength: capabilities.lens.equivalentFocalLength * max(readings.zoomFactor, 1),
                                 tracksAim: !capabilities.lens.isFront)
        speak("Keep the phone still.")
        var failure: Error?
        var cancelled = false
        do {
            let result = try await backend.captureStack(request) { [weak self] progress in
                self?.stackDidProgress(progress)
            }
            activity = .saving
            handle([result])
            if result.savedToLibrary {
                // The frames are all in by now and the haptics hold has lifted with .saving, so the one tap that
                // says the picture is developed can't shake a frame. Not within an intervalometer: its next stack
                // can start as this one saves, with the tap still running through the tripod.
                if intervalometer == nil { Haptics.success() }
                speak("Done.")
            }
        } catch let error as CameraError where error == .cancelled {
            cancelled = true
        } catch {
            failure = error
        }
        stackProgress = nil
        isFinishingStack = false
        captureNeed = nil
        activity = .idle
        bulbHoldActive = false
        // Said once the shot is over, so the warning's haptic isn't held back with the ones that would shake it.
        if cancelled {
            showToast("Cancelled", symbol: "xmark")
        } else if let failure {
            report(failure)
        }
    }

    /// About six times a second while a stack runs.
    private func stackDidProgress(_ progress: StackProgress) {
        stackProgress = progress
        // Every frame is in: the picture is being put together, and the crosses have nothing more to follow.
        if progress.framesPlanned > 0, progress.framesCaptured >= progress.framesPlanned {
            motionMonitor.endDrift()
        }
        refreshSteadyStatus()
        updateDimming()
    }

    private func startRecording() {
        activity = .recording
        recordingDuration = 0
        let request = VideoRequest(settings: settings.video, location: currentLocation, shot: shotContext())
        Task {
            do {
                try await backend.startRecording(request)
            } catch {
                activity = .idle
                report(error)
            }
        }
    }

    private func stopRecording() {
        guard activity == .recording else { return }
        activity = .saving
        Task {
            do {
                let result = try await backend.stopRecording()
                handle([result])
            } catch {
                report(error)
            }
            activity = .idle
            recordingDuration = 0
        }
    }

    private func handle(_ results: [CaptureResult]) {
        guard !results.isEmpty else { return }
        lastCapture = results.last
        recentCaptures.insert(contentsOf: results.reversed(), at: 0)
        if recentCaptures.count > 40 {
            recentCaptures.removeLast(recentCaptures.count - 40)
        }
        // Every capture passes here, so the gallery's list misses none: photos, RAW pairs, bracket frames, stacks
        // (also one that finished after a return from the background), videos and intervalometer shots.
        library.record(results)
        if results.contains(where: { !$0.savedToLibrary }) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            let message = status == .denied || status == .restricted
                ? "Couldn't save to Photos. Allow access in Settings."
                : "Couldn't save to Photos."
            showToast(message, symbol: "exclamationmark.triangle")
        }
    }

    private func report(_ error: Error) {
        if let cameraError = error as? CameraError, cameraError == .cancelled { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showToast(message, symbol: "exclamationmark.triangle")
        Haptics.warning()
    }

    private var currentLocation: LocationStamp? {
        settings.capture.saveLocation ? locationProvider.current : nil
    }

    /// position: a focus or white balance bracket frame's place in its set. An exposure bracket is one request, and
    /// the camera numbers its photos, so its position carries the set and the backend fills in each photo's index
    /// and offset.
    private func makePhotoRequest(bracket: BracketPlan, position: BracketPosition? = nil) -> PhotoRequest {
        let capture = settings.capture
        let manualBase: ExposureValues? = isManualExposure
            ? ExposureValues(seconds: readings.exposureSeconds, iso: readings.iso, aperture: readings.aperture)
            : nil
        // Live is switched on and off in PHOTO only, so MANUAL never records a movie nobody can see is on. The movie
        // goes with a HEIF or JPEG while RAW is off: PNG and TIFF can't carry one, and the output only prepares for
        // movies without RAW. Depth only needs a HEIF or JPEG, and the coordinator drops it from a photo that takes a
        // RAW file, so a zoomed shot whose Bayer RAW is left out still keeps it.
        let livePhoto = capture.livePhoto && settings.mode == .photo && capture.allowsLivePhoto
        let exposureBracket = bracket.kind == .exposure
            ? BracketPosition(kind: .exposure, count: bracket.exposureOffsets().count, step: bracket.step, group: UUID())
            : nil
        var shot = shotContext(bracket: position ?? exposureBracket)
        shot.processing = effectiveProcessing
        shot.flash = capture.flash
        shot.livePhoto = livePhoto
        return PhotoRequest(
            processedFormat: capture.processedFormat,
            rawFormat: capture.rawFormat,
            // HEIF High and JPEG High save at their own quality, whatever the slider says.
            quality: capture.effectiveQuality,
            resolution: capture.resolution,
            processing: effectiveProcessing,
            flash: capture.flash,
            aspect: capture.aspect,
            livePhoto: livePhoto,
            silentShutter: capture.silentShutter,
            depth: capture.depth && !capture.processedFormat.saved.isLossless,
            constantColor: capture.constantColor,
            contentAwareCorrection: capture.lensCorrection,
            location: currentLocation,
            bracket: bracket.kind == .exposure ? bracket : .off,
            bracketBase: manualBase,
            shot: shot
        )
    }

    private func makeStackRequest(plan: StackPlan, bulb: Bool, noiseReduction: Double) -> StackRequest {
        StackRequest(
            plan: plan,
            isBulb: bulb,
            // A stack saves the container chosen for photos, any of the six; RAW only's has no RAW to keep, so HEIF.
            processedFormat: settings.capture.processedFormat.saved,
            quality: settings.capture.effectiveQuality,
            aspect: settings.capture.aspect,
            location: currentLocation,
            noiseReduction: noiseReduction,
            shot: shotContext()
        )
    }

    /// What the model knows at the press, for the file's metadata: how exposure, focus and white balance were set
    /// and whether a person or a scene set them, the zoom and the shape, the wait before the shot, its place in an
    /// intervalometer run or a bracket, and how steady the phone was. The location only while location tags are on
    /// (currentLocation); the metadata builder checks that again. Photos add their processing, flash and Live.
    private func shotContext(bracket: BracketPosition? = nil) -> ShotContext {
        let mode = settings.mode
        var whiteBalance = effectiveWhiteBalance
        var whiteBalanceFromScene = settings.whiteBalance.isAuto && !whiteBalance.isAuto
        var kelvin = displayKelvin
        var tint = displayTint
        var focus = effectiveFocus
        var focusFromScene = settings.focus.lensPosition == nil && focus.lensPosition != nil
        var held = focusHeld
        var lensPosition = displayLensPosition
        // A focus or white balance bracket frame runs at the value its loop set on the camera, not the person's
        // setting. Only where the camera takes such a value: without it the loop's request changes nothing.
        if let bracket, let value = bracket.value, value.isFinite {
            switch bracket.kind {
            case .whiteBalance where capabilities.supportsCustomWhiteBalance:
                // The tint performWhiteBalanceBracket keeps for every frame.
                let frameTint = whiteBalance.tintValue
                whiteBalance = .kelvin(value, tint: frameTint)
                whiteBalanceFromScene = false
                kelvin = value
                tint = frameTint
            case .focus where capabilities.supportsManualFocus:
                focus = .manual(lensPosition: value)
                focusFromScene = false
                held = false
                lensPosition = value
            default:
                break
            }
        }
        let metered = meteredProduct
        let steady: Bool? = motion.isAvailable ? motion.isSteady : nil
        let zoom = readings.displayZoom.isFinite && readings.displayZoom > 0 ? readings.displayZoom : requestedDisplayZoom
        return ShotContext(
            mode: mode,
            // The files' interface field: every shot is taken with the full set of controls now.
            advanced: true,
            scene: mode == .long ? settings.longExposure.scene : nil,
            exposureControl: ExposureControl.from(shutterAuto: isShutterAuto, isoAuto: isISOAuto,
                                                  apertureAuto: isApertureAuto,
                                                  variableAperture: capabilities.supportsVariableAperture),
            bias: requestedBias,
            aeLocked: aeLocked,
            // A camera without metering areas meters the way it always does.
            meteringArea: capabilities.supportsMeteringArea ? settings.exposure.meteringArea : .automatic,
            meteredProduct: metered.isFinite && metered > 0 ? metered : nil,
            whiteBalance: whiteBalance,
            whiteBalanceFromScene: whiteBalanceFromScene,
            kelvin: kelvin,
            tint: tint,
            focus: focus,
            focusFromScene: focusFromScene,
            focusHeld: held,
            lensPosition: lensPosition,
            aspect: settings.capture.aspect,
            displayZoom: zoom,
            timerSeconds: timerSecondsForShot,
            interval: intervalometer.map { SequencePosition(index: $0.shot, count: $0.total) },
            bracket: bracket,
            stability: shotStability(steady: steady),
            steadyAtStart: steady,
            locationTagsOn: settings.capture.saveLocation,
            location: currentLocation,
            video: mode == .video ? settings.video : nil,
            artist: settings.capture.artist,
            copyright: settings.capture.copyright
        )
    }

    /// NIGHT: how steady its plan took the phone to be (Tripod, or Automatic's steady or handheld). LONG and a
    /// stacked MANUAL shutter plan no stability, so they say whether the sensor called the phone steady; without a
    /// sensor there is nothing to say.
    private func shotStability(steady: Bool?) -> NightStability? {
        switch settings.mode {
        case .night: return nightStability
        case .long: return steady.map { $0 ? .steady : .handheld }
        case .manual: return shutterIsStacked ? steady.map { $0 ? .steady : .handheld } : nil
        case .photo, .video: return nil
        }
    }

    // MARK: - Settings

    /// Mutates settings, saves them, and re-applies whatever changed to the backend. The interface options only
    /// change through their own setters, so a reset to the defaults keeps them.
    func updateSettings(_ change: (inout CameraSettings) -> Void) {
        var next = settings
        change(&next)
        next.interface = settings.interface
        commit(next)
    }

    /// Takes new settings, interface options included, saves them and re-applies whatever changed to the backend.
    private func commit(_ proposed: CameraSettings) {
        var next = proposed
        // A blend, frame, bulb or alignment that isn't the scene's own was set by hand, and that is what Custom
        // means. Checked here for every way in: the NIGHT panel's setters and the rows in Settings.
        let long = next.longExposure
        if let recipe = long.recipe,
           long.blend != recipe.blend || long.bulb != recipe.bulb || long.frameSeconds != recipe.frameSeconds
            || long.align != recipe.align {
            next.longExposure.scene = .custom
            // Alignment the person hasn't touched was the scene's, chosen for its blend, so it follows the new one:
            // on for Blur, whose frames may be held by hand; off for Real and Trails, which over a night sky would
            // follow the stars and smear the ground.
            if long.blend != recipe.blend, long.align == recipe.align {
                next.longExposure.align = long.blend == .average
            }
        }
        if !next.capture.isValid {
            next.capture.processedFormat = .heif
        }
        guard next != settings else { return }
        let old = settings
        settings = next
        scheduleSave()
        reapply(from: old, to: next)
        // Outside reapply, which stops early for a mode change: these follow whatever else changed with them.
        if old.controls != next.controls {
            mirrorHaptics()
        }
        if old.appearance != next.appearance || old.accessibility != next.accessibility {
            mirrorLook()
        }
        refreshSteadyStatus()
        updateDimming()
    }

    func showToast(_ message: String, symbol: String? = nil) {
        let item = Toast(message: message, symbol: symbol)
        toast = item
        expireToast(item)
    }

    /// Takes the toast down after its time. Called again for a toast already up, it starts that time over.
    private func expireToast(_ item: Toast) {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == item.id else { return }
            self.toast = nil
        }
    }

    private func reapply(from old: CameraSettings, to new: CameraSettings) {
        // Another mode or scene frames anew, and the magnifier turned off in Settings or Depth turned on leaves
        // nothing to offer it with. Told to the backend before the requests these settings send.
        if isMagnified, old.mode != new.mode || old.longExposure.scene != new.longExposure.scene || !magnifierOffered {
            setMagnified(false)
        }
        // Before any request is built from these settings, including the one a mode change sends at once.
        if old.mode != new.mode || old.manual != new.manual || old.longExposure != new.longExposure {
            updateStackISOLimit()
        }
        if old.mode != new.mode {
            // applyAll sends everything, which also covers a scene that changed with the mode.
            modeDidChange(from: old.mode, to: new.mode)
            return
        }
        if DeviceOptions(settings: old) != DeviceOptions(settings: new) {
            backend.apply(options: DeviceOptions(settings: new))
        }
        let sceneChanged = new.mode == .long && old.longExposure.scene != new.longExposure.scene
        // A scene holds a focus distance and a white balance of its own wherever the person has set none and the
        // lens can hold them. Only that share goes out again when LONG's scene changes: a scene turned into Custom
        // by hand runs the same autofocus, and sending it again would end a long press's held focus.
        let oldRecipe = new.mode == .long ? old.longExposure.recipe : nil
        let newRecipe = new.mode == .long ? new.longExposure.recipe : nil
        let sceneFocusChanged = capabilities.supportsManualFocus
            && (oldRecipe?.focusAtInfinity ?? false) != (newRecipe?.focusAtInfinity ?? false)
        let sceneKelvinChanged = capabilities.supportsCustomWhiteBalance && oldRecipe?.kelvin != newRecipe?.kelvin
        if old.manual != new.manual || old.longExposure != new.longExposure || old.night.biasEV != new.night.biasEV
            || old.exposure.aeMaxShutter != new.exposure.aeMaxShutter || old.video.frameRate != new.video.frameRate {
            scheduleApply(.exposure)
        }
        if old.whiteBalance != new.whiteBalance || sceneKelvinChanged {
            scheduleApply(.whiteBalance)
        }
        if old.focus != new.focus || sceneFocusChanged {
            scheduleApply(.focus)
        }
        if old.display != new.display || old.focus != new.focus || sceneChanged {
            applyAnalysis()
        }
        // The Camera Control overlay shows these too, and which of its controls work follows some of them. An open
        // dial updates it when it closes, as it would otherwise send a state at the dial's rate.
        let controlValuesChanged = old.manual.locks != new.manual.locks || old.whiteBalance != new.whiteBalance
            || old.focus != new.focus || old.longExposure != new.longExposure || old.video.frameRate != new.video.frameRate
            || old.night.seconds != new.night.seconds || old.capture.schedule != new.capture.schedule
            || old.capture.flash != new.capture.flash || old.display.histogram != new.display.histogram
        if old.controls.cameraControlItems != new.controls.cameraControlItems
            || (controlValuesChanged && activeDial == nil && !applyingControlChange) {
            applyCameraControls()
        }
        if old.capture.saveLocation != new.capture.saveLocation {
            locationProvider.setEnabled(new.capture.saveLocation)
        }
        if new.mode == .video && old.video != new.video && backendRunning {
            let video = new.video
            // The reconfigured session gets continuous autofocus again (applyAll), so an AE/AF lock ends here
            // instead of leaving its badge over a focus that moves.
            releaseLock()
            // A format past the hardware budget runs without the analysis output, and its last frame would stay up.
            analysis = nil
            // The rebuilt session puts the old exposure back first, so its readings say nothing about these
            // settings until applyAll sends them.
            lastBiasCommand = .distantFuture
            Task {
                await backend.configureForVideo(video)
                // A frame the old format sent during the reconfiguration would otherwise stay up.
                analysis = nil
                applyAll()
                noteMicrophoneIfDenied()
            }
        }
    }

    /// Video still records without the microphone, just silently, so say it once per launch.
    private func noteMicrophoneIfDenied() {
        guard settings.video.audio, !backend.isSimulated, !microphoneNoticeShown else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .denied || status == .restricted else { return }
        microphoneNoticeShown = true
        showToast("Microphone access is off. Videos record without sound.", symbol: "mic.slash")
    }

    private func modeDidChange(from old: CaptureMode, to new: CaptureMode) {
        if old == .video { turnTorchOff() }
        guard backendRunning else { return }
        if new == .video {
            let video = settings.video
            analysis = nil
            // The camera keeps the old mode's exposure until the session is rebuilt, which can wait on the
            // microphone question. Its bias meanwhile is no change of the person's, so none is adopted until
            // applyAll sends these settings.
            lastBiasCommand = .distantFuture
            Task {
                await backend.configureForVideo(video)
                analysis = nil
                applyAll()
                noteMicrophoneIfDenied()
            }
        } else if old == .video {
            lastBiasCommand = .distantFuture
            Task {
                await backend.configureForPhoto()
                applyAll()
            }
        } else {
            applyAll()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = settings
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.store.save(snapshot)
        }
    }

    /// Dials can fire 60 times a second; the device only needs the latest value about 30 times a second.
    private func scheduleApply(_ kind: ApplyKind) {
        pendingApply.insert(kind)
        guard applyTask == nil else { return }
        applyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000)
            self?.flushApply()
        }
    }

    private func flushApply() {
        let kinds = pendingApply
        // A start or a mode switch keeps its far-future mark until applyAll: a request sent now queues behind the
        // session's rebuild, which first puts back the old mode's exposure, so readings until then still carry it.
        if kinds.contains(.exposure), lastBiasCommand != .distantFuture { lastBiasCommand = Date() }
        pendingApply.removeAll()
        applyTask = nil
        if kinds.contains(.exposure) { backend.apply(exposure: currentExposureRequest()) }
        if kinds.contains(.focus) {
            endFocusHold()
            backend.apply(focus: currentFocusRequest())
        }
        if kinds.contains(.whiteBalance) { backend.apply(whiteBalance: currentWhiteBalanceRequest()) }
    }

    private func applyAnalysis() {
        let options = analysisOptions
        backend.setAnalysis(options)
        // The analyzer goes quiet when everything is off, and its last frame would otherwise stay on screen.
        if options.isOff, analysis != nil { analysis = nil }
    }

    private var analysisOptions: AnalysisOptions {
        let display = settings.display
        let manualFocus = effectiveFocus.lensPosition != nil || activeDial == .focus
        let peaking = display.peaking == .always || (display.peaking == .manualFocus && manualFocus)
        // Nobody sees the overlays or the histogram under the battery saver's black screen, so the analyzer stops
        // drawing them until a touch lights it again.
        let shown = !dimmer.isDimmed
        // NIGHT draws no histogram, and the magnifier hides it while only the middle of the frame shows. With
        // nothing else on, the analyzer and its frames stop altogether.
        let histogram = shown && showsHistogram && !isMagnified
        return AnalysisOptions(
            histogram: histogram,
            rgbHistogram: histogram && display.histogram == .rgb,
            zebraThreshold: shown && display.zebras ? display.zebraThreshold : nil,
            peakingThreshold: shown && peaking
                ? OverlayOptions.peakingThreshold(sensitivity: display.peakingSensitivity) : nil,
            peakingColor: display.peakingColor,
            falseColor: shown && display.falseColor
        )
    }

    /// Sends the Camera Control what it shows. One set of controls serves every mode: what a control can't do in
    /// this mode, or while a shot runs, it shows dimmed (disabledItems), so a mode change only changes values and
    /// the overlay never rebuilds under the finger. The backend skips a state equal to the one it has.
    private func applyCameraControls() {
        let items = settings.controls.cameraControlItems
            // Without manual shutter speeds the shutter picker would have nothing to set: NIGHT's time is Night
            // duration's, on every phone.
            .filter { allowsManualShutter || $0 != .shutter }
        let context = cameraControlContext
        let night = nightControlChoice
        let whiteBalance = effectiveWhiteBalance
        let lensButtons = backLensPresets
        let state = CameraControlState(
            items: items,
            shutterStops: cameraControlShutterStops,
            // NIGHT's time is Night duration's, so its Shutter sits dimmed on Auto.
            shutter: settings.mode.usesStacking || isShutterAuto ? nil : displayShutter,
            isoStops: isoScale,
            // Auto on the ISO and aperture pickers is wherever the person has set nothing, which in LONG can be a
            // value the scene fixes: Auto leads back to it, as the dial's does.
            iso: locksByHand && settings.manual.iso != nil ? displayISO : nil,
            apertureStops: apertureScale,
            aperture: locksByHand && capabilities.supportsVariableAperture && settings.manual.aperture != nil
                ? displayAperture : nil,
            kelvin: whiteBalance.kelvinValue,
            lensPosition: effectiveFocus.lensPosition,
            mode: settings.mode,
            lensTitles: lensButtons.map(\.selectedLabel),
            // A choice parked behind a save or a lens switch is where the camera is heading, so the picker keeps the
            // pick rather than going back to the lens in use and forward again. A parked preset that is no button (the
            // selfie camera, a recall's own zoom, macro) leaves it on the active one.
            lensIndex: pendingPreset.flatMap { parked in lensButtons.firstIndex { $0.id == parked.id } }
                ?? lensButtons.firstIndex(where: { $0.id == activePresetID }),
            durationStops: NightControlStops.durations(manualShutter: allowsManualShutter),
            duration: night.duration,
            sceneTitles: Self.nightSceneTitles,
            // Star trails is no longer on the menu: its picker stays where it is.
            sceneIndex: LongExposureScene.nightMenuChoices.firstIndex(of: night.scene),
            tint: whiteBalance.isAuto ? nil : whiteBalance.tintValue,
            timerIndex: timerPresetIndex,
            flash: settings.capture.flash,
            histogram: settings.display.histogram,
            disabledItems: Set(items.filter { !cameraControlWorks($0, in: context) })
        )
        backend.configureCameraControls(state)
    }

    /// A Camera Control control does something now: CameraCore's rule for the mode and the shot, and Flash only
    /// where this camera's photos can fire one, as for the top bar's flash (the selfie camera's screen flash counts).
    private func cameraControlWorks(_ item: CameraControlItem, in context: CameraControlContext) -> Bool {
        item.isActive(in: context) && (item != .flash || capabilities.hasFlash)
    }

    /// What the camera is doing, as the Camera Control's rule for which controls work reads it
    /// (CameraControlItem.isActive).
    private var cameraControlContext: CameraControlContext {
        CameraControlContext(
            mode: settings.mode,
            scene: settings.longExposure.scene,
            bulb: settings.longExposure.bulb,
            // A scene's fixed temperature counts as set: its tint moves from there, as the strip's tint chip does.
            whiteBalanceIsAuto: effectiveWhiteBalance.isAuto,
            stackedShutter: settings.mode == .manual && shutterIsStacked,
            // The dials' own rule: a photo, a stack or a save locks them; a countdown and a recording don't.
            shotRunning: activity == .capturing || activity == .stacking || activity == .saving,
            // canChangeMode without the photos still being saved, whose end sends the controls nothing. A mode pick
            // meanwhile is refused and the overlay goes back.
            modeLocked: activity.isBusy || intervalometer != nil,
            manualShutterAllowed: allowsManualShutter
        )
    }

    /// The Shutter picker's speeds: MANUAL's list in PHOTO, MANUAL and NIGHT, so a PHOTO pick that leads to MANUAL
    /// keeps the titles on show (one past the longest frame lands as a stacked shutter, as on MANUAL's dial), and
    /// VIDEO's own, up to one frame. Titles can't change without a rebuild of the controls, which only VIDEO's
    /// session change brings anyway.
    private var cameraControlShutterStops: [Double] {
        if settings.mode == .video { return shutterScale.map(\.seconds) }
        return ShutterSpeed.scale(minSeconds: capabilities.exposure.seconds.lowerBound, maxSeconds: 1800).map(\.seconds)
    }

    /// The night choice and time the Camera Control shows: NIGHT's own in NIGHT, and elsewhere the ones NIGHT would
    /// open with, so the dimmed pickers are already right when it does. The night shot's nil time is the camera's
    /// own; a scene always has a time.
    private var nightControlChoice: (scene: LongExposureScene?, duration: Double?) {
        let family = settings.mode.usesStacking ? settings.mode : lastNightFamilyMode
        guard family == .long else { return (nil, settings.night.seconds) }
        return (settings.longExposure.scene, settings.longExposure.seconds)
    }

    /// The Night scene picker's titles, in the scene menu's order and words (NightText): the night shot, Manual
    /// night, then the scenes.
    private static let nightSceneTitles: [String] = LongExposureScene.nightMenuChoices.map { scene in
        guard let scene else { return "Night" }
        return scene == .custom ? "Manual night" : scene.title
    }

    /// The self timer as the Timer picker lists it: an index into CaptureSchedule.delayPresets, Off first. A burst,
    /// an intervalometer or a delay set in the timer sheet has no row of its own and shows on Custom, the spot after
    /// them, so a rebuilt picker never reads Off while the next press starts a sequence.
    private var timerPresetIndex: Int {
        let delays = CaptureSchedule.delayPresets
        let schedule = settings.capture.schedule
        guard schedule.shots == 1 else { return delays.count }
        return delays.firstIndex { abs($0 - schedule.delay) < 0.001 } ?? delays.count
    }

    /// MANUAL, LONG and VIDEO expose with the shared manual values. PHOTO and NIGHT leave them alone.
    private var locksByHand: Bool {
        switch settings.mode {
        case .manual, .long, .video: return true
        case .photo, .night: return false
        }
    }

    // MARK: - Requests

    private func currentExposureRequest() -> ExposureRequest {
        let maxAuto = settings.exposure.aeMaxShutter
        let manual = settings.manual
        let variable = capabilities.supportsVariableAperture
        let aperture = variable ? manual.aperture : nil
        switch settings.mode {
        case .photo:
            return ExposureRequest(locks: ExposureLocks(), bias: manual.bias, aeLocked: aeLocked, maxAutoSeconds: maxAuto)
        case .night:
            return ExposureRequest(locks: ExposureLocks(), bias: settings.night.biasEV, aeLocked: aeLocked, maxAutoSeconds: maxAuto)
        case .manual:
            // A stacked shutter's auto ISO at the floor is fixed there, as LONG Real's is below. Only while it is
            // stacked on this camera's limits: a lens or format change can make the same shutter a single frame.
            let iso = manual.iso ?? (shutterIsStacked ? heldStackISO : nil)
            let locks = ExposureLocks(seconds: manual.shutter, iso: iso, aperture: aperture)
            return ExposureRequest(locks: locks, bias: manual.bias, aeLocked: aeLocked && locks.isAllAuto, maxAutoSeconds: maxAuto)
        case .video:
            let frameLimit = 1.0 / max(recordedVideo.frameRate, 1)
            let locks = ExposureLocks(seconds: manual.shutter.map { min($0, frameLimit) }, iso: manual.iso, aperture: aperture)
            return ExposureRequest(locks: locks, bias: manual.bias, aeLocked: aeLocked && locks.isAllAuto, maxAutoSeconds: frameLimit)
        case .long:
            let long = settings.longExposure
            // A scene's ISO, aperture, compensation and longest auto frame stand in wherever the person has set no
            // value of their own. All of it is worked out here from the scene, so leaving LONG or the scene drops
            // it with nothing to undo.
            let sceneISO = sceneISOLock
            let longAperture = aperture ?? sceneAperture
            let longMaxAuto = sceneRecipe?.maxAutoSeconds(in: capabilities.exposure.seconds) ?? maxAuto
            switch long.blend {
            case .additive:
                // Auto ISO runs shutter priority at the longest frame, as MANUAL's stacked shutter does, so the
                // meter sees the scene and longPlan can pick the ISO for the whole time. A bulb has no known length,
                // so it stays at base ISO. So does a scene too bright for base ISO over the whole time: the stack
                // comes out brighter than the meter wants, and the preview, brightened to match, shows it. A sky
                // too dark for the ISO a scene stops at is held there the same way, and comes out darker.
                let iso = manual.iso ?? sceneISO ?? (long.bulb ? capabilities.exposure.iso.lowerBound : heldStackISO)
                let locks = ExposureLocks(seconds: long.seconds, iso: iso, aperture: longAperture)
                return ExposureRequest(locks: locks, bias: requestedBias, aeLocked: false, maxAutoSeconds: longMaxAuto)
            case .average, .lighten:
                let locks = ExposureLocks(seconds: longFrameSeconds, iso: manual.iso ?? sceneISO, aperture: longAperture)
                return ExposureRequest(locks: locks, bias: requestedBias, aeLocked: aeLocked && locks.isAllAuto,
                                       maxAutoSeconds: longMaxAuto)
            }
        }
    }

    /// Exposure compensation as the camera gets it: the person's own, plus in LONG what the scene adds (a stop
    /// under for a night sky, which the meter would turn gray).
    private var requestedBias: Double {
        switch settings.mode {
        case .night:
            return settings.night.biasEV
        case .long:
            guard let scene = sceneRecipe?.biasEV, scene != 0 else { return settings.manual.bias }
            // Kept inside what the camera takes, so its reading of the sum can be told from a change made on the
            // Camera Control (adoptExternalChanges).
            let range = capabilities.biasRange
            let sum = settings.manual.bias + scene
            return sum.isFinite ? min(max(sum, range.lowerBound), range.upperBound) : settings.manual.bias
        case .photo, .manual, .video:
            return settings.manual.bias
        }
    }

    /// The ISO a scene fixes for its frames: the lowest for light trails, a set one for star trails. nil where the
    /// scene leaves the ISO to auto exposure, and outside LONG's scenes. The person's exposure compensation moves
    /// it: a scene that fixes the frame as well leaves the brightness control nothing else to work on, and with the
    /// frame on auto the meter's target moves by the same amount, so the frame keeps the length the scene wants.
    private var sceneISOLock: Double? {
        guard let recipe = sceneRecipe else { return nil }
        let range = capabilities.exposure.iso
        guard let lock = recipe.isoLock(in: range) else { return nil }
        let moved = lock * pow(2, settings.manual.bias)
        return moved.isFinite ? min(max(moved, range.lowerBound), range.upperBound) : lock
    }

    /// The highest ISO a scene lets its auto ISO reach (stars stay under the grain), moved by the person's exposure
    /// compensation as the lock is: held there, the scene fixes the frame and the ISO, and the brightness control
    /// would have nothing else to work on. nil where auto ISO may go as high as the sensor does, and outside
    /// LONG's scenes.
    private var sceneISOCeiling: Double? {
        guard let recipe = sceneRecipe else { return nil }
        let range = capabilities.exposure.iso
        let ceiling = recipe.isoCeiling(in: range)
        guard ceiling < range.upperBound else { return nil }
        let moved = ceiling * pow(2, settings.manual.bias)
        return moved.isFinite ? min(max(moved, range.lowerBound), range.upperBound) : ceiling
    }

    /// The aperture a scene asks for on a lens with an iris: open all the way for a night sky, closed all the way
    /// for fireworks and other moving lights. nil where the scene leaves it to auto exposure, and on a fixed lens.
    private var sceneAperture: Double? {
        guard capabilities.supportsVariableAperture else { return nil }
        return sceneRecipe?.aperture(in: capabilities.exposure.aperture, variable: true)
    }

    /// The frame of each Blur or Trails exposure in LONG, inside what this lens takes: the person's or the scene's.
    /// A scene whose frame was chosen for a wider aperture than the one its iris closes to gets it lengthened by
    /// the light the iris takes away (fireworks keep their skyline). nil leaves the frame to auto exposure. Worked
    /// out here rather than stored, so the scene's own frame stays in the settings and the scene stays a scene.
    var longFrameSeconds: Double? {
        var frame = settings.longExposure.frameSeconds
        if let recipe = sceneRecipe, settings.manual.aperture == nil, let aperture = sceneAperture {
            frame = recipe.frameSeconds(at: aperture) ?? frame
        }
        let range = capabilities.exposure.seconds
        return frame.map { min(max($0, range.lowerBound), range.upperBound) }
    }

    /// The aperture a stack is planned for: the locked one on a lens with an iris, else the one the lens has now.
    private var stackAperture: Double {
        guard capabilities.supportsVariableAperture else { return readings.aperture }
        return settings.manual.aperture ?? sceneAperture ?? readings.aperture
    }

    /// Shutter priority at the longest frame previews a stack with auto ISO only while the ISO for the whole time
    /// is in range. Below base ISO the stack comes out brighter than that preview, and above the ISO a scene stops
    /// at (stars stay under the grain) it comes out darker. The request then fixes the ISO at that limit, and the
    /// backend scales the preview by the missing stops. Follows the meter as readings arrive.
    private func updateStackISOLimit() {
        guard let seconds = autoISOStackSeconds else {
            // Sent again so the backend's stored request, which it re-applies after lens and format changes,
            // doesn't keep the held ISO.
            if stackISOLimit != nil {
                stackISOLimit = nil
                scheduleApply(.exposure)
            }
            return
        }
        // A running capture keeps the request it started with.
        guard !activity.isBusy else { return }
        let range = capabilities.exposure.iso
        let metered = ExposureMath.iso(forProduct: meteredProduct, seconds: seconds, aperture: stackAperture)
        let floor = range.lowerBound
        // Only a scene stops auto ISO short of what the sensor has. At the sensor's own top it stops by itself,
        // which is also where the person's compensation can move a scene's ceiling to.
        let ceiling = sceneISOCeiling ?? range.upperBound
        // A third of a stop of slack keeps a meter hovering at a limit from switching the preview back and forth.
        let slack = pow(2, 1.0 / 3)
        let floorEdge = stackISOLimit == .floor ? floor * slack : floor
        let ceilingEdge = stackISOLimit == .ceiling ? ceiling / slack : ceiling
        let limit: StackISOLimit?
        if metered < floorEdge {
            limit = .floor
        } else if metered > ceilingEdge, ceiling < range.upperBound {
            limit = .ceiling
        } else {
            limit = nil
        }
        guard limit != stackISOLimit else { return }
        stackISOLimit = limit
        scheduleApply(.exposure)
    }

    /// The ISO a stack's auto ISO is held at while the meter asks for one past a limit; nil while it is in range.
    private var heldStackISO: Double? {
        let range = capabilities.exposure.iso
        switch stackISOLimit {
        case .floor: return range.lowerBound
        case .ceiling: return sceneISOCeiling ?? range.upperBound
        case nil: return nil
        }
    }

    /// The whole time a stack with auto ISO spreads its light over: LONG Real, or MANUAL past the longest shutter.
    private var autoISOStackSeconds: Double? {
        guard settings.manual.iso == nil else { return nil }
        switch settings.mode {
        case .long:
            let long = settings.longExposure
            // A scene that fixes the ISO leaves no auto ISO to hold.
            return long.blend == .additive && !long.bulb && sceneISOLock == nil ? long.seconds : nil
        case .manual:
            return shutterIsStacked ? settings.manual.shutter : nil
        case .photo, .night, .video:
            return nil
        }
    }

    /// Focus as the camera runs it: the person's own setting, else the scene's (stars and fireworks sit at
    /// infinity), else autofocus.
    var effectiveFocus: FocusSetting {
        if settings.focus.lensPosition != nil { return settings.focus }
        if sceneRecipe?.focusAtInfinity == true, capabilities.supportsManualFocus {
            // The far end of the lens travel. Past the hyperfocal distance of a phone lens, so the sky is sharp.
            return .manual(lensPosition: 1)
        }
        return .auto
    }

    /// White balance as the camera runs it: the person's own setting, else the scene's fixed temperature, else auto.
    var effectiveWhiteBalance: WhiteBalanceSetting {
        if !settings.whiteBalance.isAuto { return settings.whiteBalance }
        if let kelvin = sceneRecipe?.kelvin, capabilities.supportsCustomWhiteBalance {
            return .kelvin(kelvin, tint: 0)
        }
        return .auto
    }

    private func currentFocusRequest() -> FocusRequest {
        if let position = effectiveFocus.lensPosition, capabilities.supportsManualFocus {
            return .manual(position)
        }
        return .continuousAuto
    }

    private func currentWhiteBalanceRequest() -> WhiteBalanceRequest {
        switch effectiveWhiteBalance {
        case .auto:
            return .auto
        case .preset(let preset):
            if let kelvin = preset.kelvin { return .temperature(kelvin: kelvin, tint: 0) }
            return .auto
        case .kelvin(let kelvin, let tint):
            return .temperature(kelvin: kelvin, tint: tint)
        }
    }

    // MARK: - Lenses

    private var activeLens: LensInfo? {
        let id = backend.activeLensID ?? settings.lensID
        return lenses.first(where: { $0.id == id }) ?? lenses.first
    }

    private func clampZoomFactor(_ factor: Double) -> Double {
        let range = capabilities.zoomRange
        let clamped = min(max(factor, range.lowerBound), range.upperBound)
        // Bayer RAW needs a zoom of exactly 1, and a pinch that stops a hair away from it looks the same.
        return abs(clamped - 1) <= 0.001 && range.contains(1) ? 1 : clamped
    }

    /// force: a zoom on the lens in use, whose destination's button lights at the request.
    private func updateActivePreset(factor: Double? = nil, force: Bool = false) {
        // A lens button's transition owns the active button until it lands: a zoom in reaches the next lens's value
        // on the lens it leaves, and a zoom out names the wider lens while the device is still on the longer one.
        // releaseZoomTarget brings this back in step, while the target still shows.
        guard force || zoomTarget == nil else { return }
        if isMacro {
            // Macro lasts while the ultra wide camera is the one in use or on its way.
            let heading = pendingPreset?.lensID ?? settings.lensID
            if lenses.first(where: { $0.id == heading })?.kind == .ultraWide, let id = macroButtonID {
                setActivePreset(id)
                return
            }
            isMacro = false
        }
        guard let lensID = backend.activeLensID ?? settings.lensID else {
            setActivePreset(lensPresets.first?.id)
            return
        }
        let zoom = factor ?? settings.zoom
        let candidates = lensPresets.filter { $0.lensID == lensID }
        let match = candidates.filter { $0.zoomFactor <= zoom + 0.01 }.max(by: { $0.zoomFactor < $1.zoomFactor })
            ?? candidates.min(by: { $0.zoomFactor < $1.zoomFactor })
        setActivePreset(match?.id ?? activePresetID)
    }

    /// A pinch comes through here at the finger's rate, and Observation tells every reader of a write even when the
    /// value is the same.
    private func setActivePreset(_ id: String?) {
        if activePresetID != id { activePresetID = id }
    }

    /// The Camera Control's system zoom and exposure sliders drive the device directly. Once the app's own
    /// commands have had a second to land, a reading that still disagrees came from there and becomes the setting,
    /// so chips, presets and the saved state follow the hardware.
    private func adoptExternalChanges(from readings: LiveReadings) {
        let now = Date()
        var changed = false
        // The magnifier's zoom is the device's, not a slider's move; the readings report the photo's zoom then anyway.
        if !lensSwitchInFlight, !activity.isBusy, !isMagnified, now.timeIntervalSince(lastZoomCommand) > 1,
           readings.zoomFactor.isFinite, readings.zoomFactor > 0, abs(readings.zoomFactor - settings.zoom) > 0.01 {
            // The factor belongs to the lens the camera runs, which the saved lens has to name with it.
            if let running = backend.activeLensID, settings.lensID != running { settings.lensID = running }
            if isMacro { isMacro = false }
            // A zoom frames anew, as a pinch does: the whole frame the magnifier metered was the old framing's.
            if magnifierMeter != nil { magnifierMeter = nil }
            settings.zoom = readings.zoomFactor
            // The next pinch or wheel turn goes on from the slider's zoom.
            if readings.displayZoom.isFinite, readings.displayZoom > 0 {
                requestedDisplayZoom = readings.displayZoom
            }
            updateActivePreset(factor: readings.zoomFactor)
            changed = true
        }
        let requested = requestedBias
        // While the magnifier is on the exposure holds and a bias asked for waits in the backend, so the camera's
        // bias says nothing about the Camera Control's slider, whose overlay ends the magnifier anyway.
        if !activity.isBusy, !isMagnified, pendingApply.isEmpty, now.timeIntervalSince(lastBiasCommand) > 1,
           readings.bias.isFinite, abs(readings.bias - requested) > 0.05 {
            if settings.mode == .night {
                settings.night.biasEV = readings.bias
                changed = true
            } else {
                // The slider shows what the camera runs, a scene's share included; the rest is the person's own.
                // At the end of the range their part can't move further, and then nothing is adopted.
                let range = capabilities.biasRange
                let own = min(max(settings.manual.bias + readings.bias - requested, range.lowerBound), range.upperBound)
                if abs(own - settings.manual.bias) > 0.001 {
                    settings.manual.bias = own
                    changed = true
                }
            }
        }
        guard changed else { return }
        scheduleSave()
        scheduleExternalSync()
    }

    /// The backend keeps its own zoom target and exposure request and re-applies them after lens and format
    /// changes, so they have to follow the adopted values. Sending them while the slider still moves would fight it,
    /// so this waits until it rests.
    private func scheduleExternalSync() {
        externalSyncTask?.cancel()
        // A zoom asked for after the slider (a lens button's glide, a pinch) has given the backend its own target,
        // and setting the adopted zoom over it would snap the glide back.
        let generation = zoomRequestGeneration
        externalSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, !self.lensSwitchInFlight, !self.activity.isBusy else { return }
            // A zoom request ends the magnifier in the backend, and this one is only a resend of the zoom in force.
            if generation == self.zoomRequestGeneration, !self.isMagnified {
                self.lastZoomCommand = Date()
                self.backend.setZoomFactor(self.settings.zoom, rampRate: nil)
            }
            self.scheduleApply(.exposure)
        }
    }

    private func dialAvailable(_ dial: DialKind, in mode: CaptureMode) -> Bool {
        switch dial {
        case .aperture: return capabilities.supportsVariableAperture
        // NIGHT's shutter dial sets a duration, which every phone has.
        case .shutter: return mode.usesStacking || allowsManualShutter
        case .tint: return !effectiveWhiteBalance.isAuto
        default: return true
        }
    }

    // MARK: - Derived values for the UI

    /// What VIDEO records on this lens: the saved resolution, frame rate and color where the lens has them, else the
    /// nearest format it has. The settings keep asking for theirs, so a lens that can record them gets them back.
    var recordedVideo: VideoSettings {
        var video = settings.video
        let wanted = VideoRequirement(resolution: video.resolution, frameRate: video.frameRate, colorMode: video.colorMode)
        // Until the backend has set up these settings, the same choice made from the lens's formats stands in.
        let recorded = capabilities.activeVideo.flatMap { $0.requested == wanted ? $0.recorded : nil }
            ?? FormatSelector.nearestVideoFormat(for: wanted, among: capabilities.formats)?.recorded
        guard let recorded else { return video }
        video.resolution = recorded.resolution
        video.frameRate = recorded.frameRate
        video.colorMode = recorded.colorMode
        return video
    }

    /// Shutter dial values: hardware range plus stacked values up to 30 minutes in MANUAL and LONG
    /// (up to 1/fps in VIDEO mode).
    var shutterScale: [ShutterSpeed] {
        let hardware = capabilities.exposure.seconds
        switch settings.mode {
        case .manual:
            return ShutterSpeed.scale(minSeconds: hardware.lowerBound, maxSeconds: 1800)
        case .long:
            return ShutterSpeed.scale(minSeconds: max(hardware.lowerBound, shortestLongSeconds), maxSeconds: 1800)
        case .video:
            let fps = max(recordedVideo.frameRate, 1)
            let limit = max(min(hardware.upperBound, 1.0 / fps), hardware.lowerBound)
            var values = ShutterSpeed.scale(minSeconds: hardware.lowerBound, maxSeconds: limit).map(\.seconds)
            // Third stops miss the angles people set by number, such as 180° at 24 fps (1/48 s).
            for angle in [90.0, 180, 360] {
                let seconds = ExposureMath.seconds(shutterAngle: angle, fps: fps)
                guard seconds >= hardware.lowerBound, seconds <= limit * 1.0001,
                      !values.contains(where: { abs($0 / seconds - 1) < 0.01 }) else { continue }
                values.append(seconds)
            }
            return values.sorted().map { ShutterSpeed(seconds: $0) }
        case .photo, .night:
            return ShutterSpeed.scale(minSeconds: hardware.lowerBound, maxSeconds: hardware.upperBound)
        }
    }

    var isoScale: [Double] {
        ISOScale.scale(min: capabilities.exposure.iso.lowerBound, max: capabilities.exposure.iso.upperBound)
    }

    /// Empty on fixed-aperture lenses.
    var apertureScale: [Double] {
        guard capabilities.supportsVariableAperture else { return [] }
        let range = capabilities.exposure.aperture
        return ApertureScale.scale(min: range.lowerBound, max: range.upperBound, recommended: capabilities.apertureStops)
    }

    var biasScale: [Double] {
        let range = capabilities.biasRange
        let limit = min(abs(range.lowerBound), abs(range.upperBound), 8)
        return EVFormat.scale(range: limit)
    }

    var kelvinScale: [Double] {
        WhiteBalanceMath.kelvinScale(count: 81)
    }

    var isManualExposure: Bool {
        switch settings.mode {
        case .manual, .video: return !currentExposureRequest().locks.isAllAuto
        case .long: return true
        case .photo, .night: return false
        }
    }

    /// The chosen shutter is longer than the hardware allows and will be built from frames.
    var shutterIsStacked: Bool {
        let hardwareMax = capabilities.exposure.seconds.upperBound
        switch settings.mode {
        case .manual:
            guard let shutter = settings.manual.shutter else { return false }
            return shutter > hardwareMax * 1.001
        case .long:
            return settings.longExposure.blend != .additive || settings.longExposure.seconds > hardwareMax * 1.001
        default:
            return false
        }
    }

    /// Processing actually used: manual exposure forces .minimal so the shutter and ISO are honoured.
    var effectiveProcessing: ProcessingLevel {
        if isManualExposure { return .minimal }
        let wanted = settings.capture.processing
        let order: [ProcessingLevel] = [.minimal, .balanced, .maximum]
        let wantedIndex = order.firstIndex(of: wanted) ?? 1
        let maxIndex = order.firstIndex(of: capabilities.maxProcessing) ?? 1
        return order[min(wantedIndex, maxIndex)]
    }

    /// What auto exposure wants for this scene, as a light product (t × ISO / N²). In NIGHT with AE locked it is
    /// the light measured at the lock, moved by any bias change since, as a locked exposure would be. While the
    /// magnifier enlarges the middle it is the whole frame's, metered as the magnifier came on, moved the same way,
    /// and so it stays until the frames after the magnifier's end show the whole frame (magnifierMeterUntil).
    private var meteredProduct: Double {
        if let held = magnifierMeter, isMagnified || Date() < magnifierMeterUntil {
            return held.product * pow(2, requestedBias - held.bias)
        }
        if settings.mode == .night, aeLocked, let locked = lockedMeter {
            return locked.product * pow(2, settings.night.biasEV - locked.bias)
        }
        return liveMeteredProduct
    }

    /// What auto exposure wants for the frame in view right now.
    private var liveMeteredProduct: Double {
        let current = ExposureValues(seconds: readings.exposureSeconds, iso: readings.iso, aperture: readings.aperture)
        // exposureTargetOffset says how far the current image is from the meter's target; undo it.
        return ExposureMath.lightProduct(current) * pow(2, -readings.meterOffset)
    }

    private var nightStability: NightStability {
        switch settings.night.stability {
        case .handheld: return .handheld
        case .tripod: return .tripod
        case .automatic:
            let justMoved = steadyLostAt.map { Date().timeIntervalSince($0) < 1 } ?? false
            return motion.isSteady || justMoved ? .steady : .handheld
        }
    }

    /// What NIGHT mode would do right now.
    var nightPlan: StackPlan {
        let focal = capabilities.lens.equivalentFocalLength * max(readings.zoomFactor, 1)
        let input = NightModeInput(
            meteredProduct: meteredProduct,
            // Auto exposure already applied the night EV bias to the metered product.
            biasEV: 0,
            requestedSeconds: settings.night.seconds,
            stability: nightStability,
            ranges: capabilities.exposure,
            aperture: readings.aperture,
            handheldFrameLimit: ExposureMath.handheldLimit(equivalentFocalLength: focal),
            maxISO: settings.night.maxISO
        )
        var plan = NightModePlanner.plan(input)
        plan.align = plan.align && settings.night.alignFrames
        return plan
    }

    /// The duration NIGHT mode shows when set to automatic.
    var nightAutoSeconds: Double {
        NightModePlanner.suggestedSeconds(meteredProduct: meteredProduct, aperture: readings.aperture, stability: nightStability)
    }

    /// What LONG mode would do right now. A scene's ISO and aperture stand in wherever the person has set none,
    /// as in the exposure request.
    var longPlan: StackPlan {
        let long = settings.longExposure
        let caps = capabilities.exposure
        let aperture = stackAperture
        switch long.blend {
        case .additive:
            // Auto ISO gives the metered light over the whole time, like MANUAL's stacked shutter, up to the ISO a
            // scene stops at. A bulb has no known length, so it keeps base ISO.
            let metered = ExposureMath.iso(forProduct: meteredProduct, seconds: long.seconds, aperture: aperture)
            let wanted = metered.isFinite ? metered : caps.iso.lowerBound
            let auto = min(max(wanted, caps.iso.lowerBound), sceneISOCeiling ?? caps.iso.upperBound)
            let iso = settings.manual.iso ?? sceneISOLock ?? (long.bulb ? caps.iso.lowerBound : auto)
            return LongExposurePlanner.plan(totalSeconds: long.seconds, blend: .additive, iso: iso, aperture: aperture,
                                            frameSeconds: nil, ranges: caps, align: long.align)
        case .average, .lighten:
            // The planner clamps a chosen frame to this lens's range, as the request does.
            var iso = settings.manual.iso ?? sceneISOLock ?? readings.iso
            var frame = longFrameSeconds ?? readings.exposureSeconds
            // Auto exposure takes a moment to come down to a scene's longest frame, so a reading can still be
            // the scene before's (Water picked right after Stars): frames too long to hold. They are planned at
            // the limit, and an auto ISO makes up the light the shorter frame loses.
            if longFrameSeconds == nil, let limit = sceneRecipe?.maxAutoSeconds(in: caps.seconds),
               limit > 0, readings.exposureSeconds > limit {
                if settings.manual.iso == nil, sceneISOLock == nil {
                    let carried = iso * readings.exposureSeconds / limit
                    if carried.isFinite { iso = min(max(carried, caps.iso.lowerBound), caps.iso.upperBound) }
                }
                frame = limit
            }
            return LongExposurePlanner.plan(totalSeconds: long.seconds, blend: long.blend, iso: iso, aperture: aperture,
                                            frameSeconds: frame, ranges: caps, align: long.align)
        }
    }

    /// MANUAL mode with a shutter past the hardware limit: a Real (additive) stack.
    private var manualStackPlan: StackPlan {
        let seconds = settings.manual.shutter ?? capabilities.exposure.seconds.upperBound
        let aperture = stackAperture
        // Auto ISO with a fixed long shutter: pick the ISO that gives the metered brightness, like shutter priority.
        let iso = settings.manual.iso ?? ExposureMath.iso(forProduct: meteredProduct, seconds: seconds, aperture: aperture)
        let clampedISO = min(max(iso, capabilities.exposure.iso.lowerBound), capabilities.exposure.iso.upperBound)
        return LongExposurePlanner.plan(totalSeconds: seconds, blend: .additive, iso: clampedISO, aperture: aperture,
                                        frameSeconds: nil, ranges: capabilities.exposure)
    }

    /// Meter needle in EV, clamped to -3...3. Positive means the photo will come out brighter than the meter wants.
    var meterOffset: Double {
        let offset: Double
        switch settings.mode {
        case .long where settings.longExposure.blend == .additive:
            offset = plannedOffset(plan: longPlan)
        case .manual where shutterIsStacked:
            offset = plannedOffset(plan: manualStackPlan)
        default:
            offset = readings.meterOffset
        }
        guard offset.isFinite else { return 0 }
        return min(max(offset, -3), 3)
    }

    private func plannedOffset(plan: StackPlan) -> Double {
        let planned = ExposureValues(seconds: plan.effectiveExposureSeconds, iso: plan.iso, aperture: plan.aperture)
        let target = meteredProduct
        guard target > 0 else { return 0 }
        return log2(ExposureMath.lightProduct(planned) / target)
    }

    var canCapture: Bool {
        authorization == .authorized && sessionState == .running && settings.capture.isValid
    }

    /// A shutter press (screen, volume buttons or Camera Control) would do something right now. The button skips
    /// its click and haptic otherwise, so a press is never felt without a result.
    var shutterAcceptsPress: Bool {
        switch activity {
        case .idle:
            // A press while the magnifier is on brings the whole frame back.
            if intervalometer != nil || isMagnified { return true }
            guard canCapture else { return false }
            return photosInFlight == 0 || (pressTakesPlainPhoto && photosInFlight < maxPhotosInFlight)
        case .countdown, .stacking, .recording: return true
        case .capturing, .saving: return intervalometer != nil || (bracketInProgress && !bracketStopping)
        }
    }

    /// Bayer RAW needs the lens at zoom 1 (AVCapturePhotoOutput leaves it out otherwise); ProRAW works at any zoom.
    var rawBlockedByZoom: Bool {
        let raw = settings.capture.rawFormat
        // ProRAW falls back to a Bayer DNG on a lens without it.
        let bayer = raw == .bayer || (raw == .proRAW && !capabilities.proRAWSupported)
        // The backends leave RAW out past a thousandth off 1.
        return bayer && abs(settings.zoom - 1) > 0.001
    }

    var activePreset: LensPreset? {
        lensPresets.first(where: { $0.id == activePresetID })
    }

    // MARK: Macro and close subjects

    /// Macro is on: the ultra wide camera framing like 1x. It focuses far closer than the main camera, which is how
    /// Apple's Camera takes its close-ups. The 1x button stays lit for it. Any lens button leaves it, and so does a
    /// switch to VIDEO or NIGHT, which have no macro button. A flag of its own, not read off the lens and zoom: a
    /// pinch through 1x on the ultra wide camera is not macro.
    private(set) var isMacro = false
    @ObservationIgnored private var macroRestored = false

    /// The button macro keeps lit: the main camera's 1x.
    private var macroButtonID: String? {
        let ones = backLensPresets.filter { abs($0.displayZoom - 1) < 0.01 }
        return (ones.first { preset in lenses.first(where: { $0.id == preset.lensID })?.kind == .wide } ?? ones.first)?.id
    }

    /// Macro can run on phones with an ultra wide camera, while a back camera is in use.
    var macroAvailable: Bool {
        !capabilities.lens.isFront && lenses.contains { $0.kind == .ultraWide }
    }

    /// The modes with a macro button. In NIGHT its place beside the shutter is the scene menu's, and VIDEO has
    /// neither.
    private static func offersMacro(_ mode: CaptureMode) -> Bool {
        mode == .photo || mode == .manual
    }

    /// Whether the macro button shows: a phone and camera that can, in a mode that has the button.
    var macroOffered: Bool {
        macroAvailable && Self.offersMacro(settings.mode)
    }

    /// Macro on: the ultra wide at the 1x framing. Off: back to the main camera's 1x.
    func toggleMacro() {
        guard !activity.isBusy, macroOffered else { return }
        if isMacro {
            if let id = macroButtonID, let wide = backLensPresets.first(where: { $0.id == id }) { select(wide) }
            return
        }
        guard let ultra = lenses.first(where: { $0.kind == .ultraWide }) else { return }
        let factor = clampFactor(1 / max(ultra.relativeZoom, 0.01), for: ultra)
        isMacro = true
        select(LensPreset(lensID: ultra.id, zoomFactor: factor, displayZoom: factor * ultra.relativeZoom),
               haptic: true, replaying: false)
        // The button's ring shows it, so only VoiceOver hears it.
        announce("Macro on")
    }

    /// Only the running lens reports its range; the backend keeps the top inside what the new lens can do.
    private func clampFactor(_ factor: Double, for lens: LensInfo) -> Double {
        factor.isFinite ? max(1, factor) : 1
    }

    /// A longer lens can't focus closer than its minimum distance, so autofocus parks at the near end and the
    /// picture stays soft. Apple's Camera switches to a crop of the main camera then; so does this, after the lens
    /// has sat at its near end for a second.
    @ObservationIgnored private var nearEndSince: Date?

    private func checkCloseSubject(_ readings: LiveReadings) {
        guard activity == .idle, zoomTarget == nil, !lensSwitchInFlight, effectiveFocus.lensPosition == nil,
              settings.mode != .video || activity != .recording,
              let lens = activeLens, lens.kind == .telephoto,
              !readings.isAdjustingFocus, readings.lensPosition <= 0.02,
              let wide = lenses.first(where: { $0.kind == .wide && !$0.isFront }) else {
            nearEndSince = nil
            return
        }
        guard let since = nearEndSince else {
            nearEndSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= 1 else { return }
        nearEndSince = nil
        let zoom = readings.displayZoom.isFinite && readings.displayZoom > 0 ? readings.displayZoom : lens.relativeZoom
        let factor = clampFactor(zoom / max(wide.relativeZoom, 0.01), for: wide)
        select(LensPreset(lensID: wide.id, zoomFactor: factor, displayZoom: factor * wide.relativeZoom), haptic: false)
        showToast("Too close for \(LensMath.zoomLabel(lens.relativeZoom, selected: true)). Using the main camera.",
                  symbol: "camera.macro")
    }

    /// The lens buttons. The selfie camera is reached with the flip button, so its presets stay out.
    var backLensPresets: [LensPreset] {
        lensPresets.filter { preset in lenses.first(where: { $0.id == preset.lensID })?.isFront != true }
    }

    /// Value to show on each chip: the locked value, or the live auto value.
    var displayShutter: Double {
        switch settings.mode {
        case .long where settings.longExposure.blend == .additive:
            return settings.longExposure.seconds
        case .manual:
            return settings.manual.shutter ?? readings.exposureSeconds
        case .video:
            // VIDEO shares the manual shutter with MANUAL but can't expose longer than one frame.
            let frameLimit = 1.0 / max(recordedVideo.frameRate, 1)
            return settings.manual.shutter.map { min($0, frameLimit) } ?? readings.exposureSeconds
        default:
            return readings.exposureSeconds
        }
    }

    var displayISO: Double {
        switch settings.mode {
        case .long:
            return settings.manual.iso ?? longPlan.iso
        case .manual:
            if let iso = settings.manual.iso { return iso }
            // The preview runs at the longest frame; the stacked frames use the ISO for the whole time.
            return shutterIsStacked ? manualStackPlan.iso : readings.iso
        case .video:
            return settings.manual.iso ?? readings.iso
        case .night:
            // What the night shot's frames use, as the scenes show theirs: the preview runs a shorter shutter at a
            // higher ISO. NIGHT's plan pill leaves the ISO to the readout line.
            return nightPlan.iso
        case .photo:
            return readings.iso
        }
    }

    var displayAperture: Double {
        guard capabilities.supportsVariableAperture else { return readings.aperture }
        switch settings.mode {
        case .manual, .video: return settings.manual.aperture ?? readings.aperture
        case .long: return settings.manual.aperture ?? sceneAperture ?? readings.aperture
        case .photo, .night: return readings.aperture
        }
    }

    // White balance and focus show what the camera runs, which in LONG can be a scene's.

    var displayKelvin: Double { effectiveWhiteBalance.kelvinValue ?? readings.kelvin }

    var displayTint: Double {
        let whiteBalance = effectiveWhiteBalance
        return whiteBalance.isAuto ? readings.tint : whiteBalance.tintValue
    }

    var displayLensPosition: Double { effectiveFocus.lensPosition ?? readings.lensPosition }

    var isShutterAuto: Bool {
        switch settings.mode {
        case .manual, .video: return settings.manual.shutter == nil
        case .long: return settings.longExposure.blend != .additive
        case .photo, .night: return true
        }
    }

    // Auto means auto exposure picks the value as the light changes. A value a scene fixes is not auto, though the
    // person never set it: asking for auto there goes back to the scene's.

    var isISOAuto: Bool {
        switch settings.mode {
        case .manual, .video: return settings.manual.iso == nil
        case .long: return settings.manual.iso == nil && sceneISOLock == nil
        case .photo, .night: return true
        }
    }

    var isApertureAuto: Bool {
        guard capabilities.supportsVariableAperture else { return true }
        switch settings.mode {
        case .manual, .video: return settings.manual.aperture == nil
        case .long: return settings.manual.aperture == nil && sceneAperture == nil
        case .photo, .night: return true
        }
    }

    // MARK: - Histogram

    /// The histogram is on and this mode draws one. NIGHT has none: its shots are built from many frames.
    var showsHistogram: Bool { settings.display.histogram != .off && settings.mode.hasHistogram }

    /// The histogram is on the screen now: on, in a mode that draws one, and with live frames to draw it from. Not
    /// while a stack runs (its frames go to the stack, so the last one would stay up), while the magnifier shows only
    /// the middle, under the battery saver's black screen, with the camera stopped, or before a frame has come (a
    /// VIDEO format past the hardware budget never sends one). Built from state that changes rarely, so what makes
    /// room for the histogram reads this and not the analysis, which changes 12 times a second.
    var histogramOnScreen: Bool {
        showsHistogram && hasAnalysisFrames && activity != .stacking && !isMagnified && !dimmer.isDimmed
            && sessionState == .running
    }

    // MARK: - Photo format

    // The top bar's Format menu, the quick settings and Settings > Photos set the format through these, so each
    // shows what the others set.

    /// One row of the format list: the container and High. The Quality slider keeps its value for plain HEIF and
    /// JPEG, and RAW stays as it is (RAW only is a row while RAW is on).
    func setPhotoFormat(_ choice: PhotoFormatChoice) {
        updateSettings { choice.apply(to: &$0.capture) }
    }

    /// Off, RAW (the sensor's data, at a lens's own zoom) or ProRAW. Turned off under RAW only, photos save HEIF
    /// (commit).
    func setRawFormat(_ raw: RawFormat) {
        updateSettings { $0.capture.rawFormat = raw }
    }

    /// 12 MP or 48 MP, the largest size the lens has up to it.
    func setPhotoResolution(_ resolution: PhotoResolution) {
        updateSettings { $0.capture.resolution = resolution }
    }

    // MARK: - Focus magnifier

    /// How many times the middle of the frame shows enlarged for focusing by hand; 1 is the whole frame. It lives on
    /// the device's zoom only: the photo's zoom stays as it is, the backend undoes the magnifier before any capture,
    /// and the half press (shutterPressed) makes sure none starts with it on.
    private(set) var magnification: Double = 1
    var isMagnified: Bool { magnification > 1 }
    /// How many times the badge says the frame is enlarged: the power asked for, or less where the lens's zoom runs
    /// out (5× at 2× on a lens that stops at 15 shows 7.5×). Worked out as the magnifier comes on, since any zoom
    /// ends it.
    private(set) var magnifierShownPower: Double = 1
    /// What the whole frame metered as the magnifier came on, and the bias then. The meter reads only the middle
    /// while it is enlarged, and the exposure holds, so the plans keep this meanwhile (meteredProduct). It outlives
    /// the magnifier by about two frames (magnifierMeterUntil), while the frames on their way still show the middle:
    /// a press right after the half press is planned from the whole frame. A lens or zoom change frames anew and
    /// drops it. Observed, because a view showing the held meter may read nothing that the readings change: the
    /// readout line, the ISO chip and NIGHT's plan pill go back to the live meter when the first reading after those
    /// frames drops it (didUpdateReadings). Observation tells every reader of each write of a value that isn't
    /// Equatable, as a tuple isn't, so it is only written when it changes.
    private var magnifierMeter: (product: Double, bias: Double)?
    /// When the frames after the magnifier's end show the whole frame again, and the meter can be read once more.
    @ObservationIgnored private var magnifierMeterUntil = Date.distantPast
    /// Magnify was tapped off while the focus dial is open: the dial's turns leave the frame whole until it closes.
    @ObservationIgnored private var magnifierDeclined = false

    /// The focus dial offers the magnifier: on in Settings, a back lens that focuses by hand, a running camera, a
    /// mode with the focus dial, and no depth delivery, whose zoom changes rebuild the capture pipeline.
    var magnifierOffered: Bool {
        guard settings.focusOptions.magnifier != .off, capabilities.supportsManualFocus, !capabilities.lens.isFront,
              sessionState == .running else { return false }
        switch settings.mode {
        case .manual, .long:
            return !(DeviceOptions(settings: settings).depth && capabilities.depthSupported)
        case .video:
            // VIDEO takes the photo output, and its depth, out of the session.
            return true
        case .photo, .night:
            return false
        }
    }

    /// The magnifier can come on now: nothing being taken or saved, no sequence between its shots, no lens on its
    /// way, and the Camera Control's overlay closed, whose zoom slider would show the enlarged zoom.
    var canMagnify: Bool {
        magnifierOffered && activity == .idle && intervalometer == nil && !bracketInProgress && photosInFlight == 0
            && !lensSwitchInFlight && !controlsFullscreen
    }

    /// On enlarges the middle by the power Settings names, from the focus dial only. Off brings the whole frame back,
    /// and does nothing when it is already whole.
    func setMagnified(_ on: Bool) {
        if on {
            let power = settings.focusOptions.magnifier.power
            guard !isMagnified, power > 1, canMagnify, activeDial == .focus else { return }
            let base = settings.zoom
            // The backend enlarges from the zoom it was asked for. A glide still on its way, or the Camera Control's
            // slider not yet adopted, has the device elsewhere; the next turn of the dial finds it settled.
            let device = readings.zoomFactor
            guard device.isFinite, device > 0, base > 0, abs(device / base - 1) < 0.02 else { return }
            let zoom = MagnifierMath.deviceZoom(base: base, power: power, range: capabilities.zoomRange)
            let shown = MagnifierMath.shownPower(base: base, deviceZoom: zoom)
            // A lens already at the end of its zoom has nothing left to enlarge with.
            guard shown > 1 else { return }
            magnifierMeter = (meteredProduct, requestedBias)
            magnifierShownPower = shown
            magnification = power
        } else {
            guard isMagnified else { return }
            magnification = 1
            magnifierShownPower = 1
            // The cut back reaches the preview a frame or two later, and the readings poll a tenth of a second after
            // that: the meter goes on reading the middle until then, a couple of seconds at Manual night's 1 s frames.
            let settle = min(max(2 * readings.exposureSeconds + 0.2, 0.3), 2.5)
            magnifierMeterUntil = Date().addingTimeInterval(settle.isFinite ? settle : 0.3)
        }
        // The device cuts in or out while the zoom asked for stays, and the exposure requests that waited go out as
        // the frame comes back: this keeps adoptExternalChanges from taking the frame or two before either lands
        // for a move of the Camera Control's sliders. A start's far-future mark stays for applyAll.
        lastZoomCommand = Date()
        if lastBiasCommand != .distantFuture { lastBiasCommand = Date() }
        backend.setFocusMagnification(magnification)
        // Peaking and zebras are worked out on the enlarged frames, and the histogram waits for the whole frame.
        applyAnalysis()
    }

    /// The focus dial's Magnify button.
    func toggleMagnifier() {
        let on = !isMagnified
        setMagnified(on)
        magnifierDeclined = !on
    }

    /// A turn of the focus dial and its Far end button: the magnifier comes on by itself, as a camera's focus assist
    /// does, unless Magnify was tapped off since the dial opened.
    func focusDialTurned() {
        guard !magnifierDeclined else { return }
        setMagnified(true)
    }

    // MARK: - Custom setups

    /// Saves the shooting setup in use into a slot, 0 to 2 for C1 to C3. Without a name, a slot saved over keeps the
    /// name it had. The setups alone send the camera nothing: reapply compares the rest.
    func saveSetup(slot: Int, name: String? = nil) {
        guard (0..<CameraSetups.count).contains(slot) else { return }
        let kept = name.map(Self.setupName) ?? settings.setups[slot]?.name ?? ""
        updateSettings { $0.setups[slot] = CameraSetup(name: kept, from: $0) }
        // Saved from the quick settings, nothing on screen changes to say so.
        showToast("Saved to C\(slot + 1)", symbol: "slider.horizontal.3")
    }

    func renameSetup(slot: Int, to name: String) {
        guard var setup = settings.setups[slot] else { return }
        let trimmed = Self.setupName(name)
        guard trimmed != setup.name else { return }
        setup.name = trimmed
        updateSettings { $0.setups[slot] = setup }
    }

    func clearSetup(slot: Int) {
        guard settings.setups[slot] != nil else { return }
        updateSettings { $0.setups[slot] = nil }
    }

    /// Puts a saved setup back, as a camera's C1 to C3 do: the mode and scene, the exposure, white balance and focus,
    /// the format, the timer and brackets, the viewfinder tools, NIGHT, VIDEO and the lens. Macro isn't kept, and
    /// comes back from the lens and zoom, as it does at launch. The interface and everything outside shooting stay as
    /// they are. Refused, with the reason, while a shot, a sequence or a save runs, as a mode change is.
    func recallSetup(slot: Int) {
        guard let setup = settings.setups[slot] else { return }
        guard canChangeMode else {
            noteModeChangeRefused()
            return
        }
        releaseLock()
        activeDial = nil
        isDrawerOpen = false
        setMagnified(false)
        let lens = recalledLens(of: setup)
        // The macro framing comes back as macro in the modes with its button, as a camera saved in macro opens in it
        // (refreshLenses). The bare lens and zoom would light the .5 button reading 1x beside the 1x button.
        let recallsMacro = Self.offersMacro(setup.mode) && (lenses.first(where: { $0.id == setup.lensID }).map {
            $0.kind == .ultraWide && abs(setup.zoom * $0.relativeZoom - 1) < 0.02
        } ?? false)
        // VIDEO and NIGHT have no macro button to end macro with, so it stays behind as setMode leaves it, unless the
        // setup's own lens ends it below.
        if lens == nil, !Self.offersMacro(setup.mode), isMacro, let id = macroButtonID,
           let wide = backLensPresets.first(where: { $0.id == id }) {
            select(wide, haptic: false)
        }
        var next = setup.applied(to: settings)
        // A shutter speed saved where they are offered would run here with no chip to show it, as at launch.
        if !allowsManualShutter { next.manual.shutter = nil }
        if next.mode.usesStacking { lastNightFamilyMode = next.mode }
        modeChangeLedByPick = false
        // One commit: a change of mode sends everything (applyAll), and otherwise reapply sends what changed, a VIDEO
        // session's rebuild included.
        updateSettings { $0 = next }
        // After the commit, so a VIDEO session is set up before the lens moves on it. Macro goes through the select
        // that keeps it, as the macro button's does, so the 1x button stays lit for it.
        if recallsMacro {
            isMacro = true
            if let lens { select(lens, haptic: false, replaying: false) } else { updateActivePreset(force: true) }
        } else if let lens {
            select(lens, haptic: false)
        }
        showToast(setup.name.isEmpty ? "C\(slot + 1)" : "C\(slot + 1) \u{00B7} \(setup.name)",
                  symbol: "slider.horizontal.3")
        Haptics.tap()
    }

    /// Where a recall takes the lens: the setup's back lens at its zoom, through the lens button that matches, else
    /// that lens zoomed there. nil leaves the lens as it is: already there, a lens this phone lacks, or the selfie
    /// camera.
    private func recalledLens(of setup: CameraSetup) -> LensPreset? {
        guard let id = setup.lensID, let lens = lenses.first(where: { $0.id == id }), !lens.isFront,
              setup.zoom.isFinite, setup.zoom > 0 else { return nil }
        if backend.activeLensID == id, pendingPreset == nil, abs(settings.zoom - setup.zoom) < 0.01 { return nil }
        return backLensPresets.first(where: { $0.lensID == id && abs($0.zoomFactor - setup.zoom) < 0.01 })
            ?? LensPreset(lensID: id, zoomFactor: setup.zoom, displayZoom: setup.zoom * lens.relativeZoom)
    }

    /// A setup's name as it is kept, without the spaces around it.
    private static func setupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Backend events

extension CameraModel: CameraBackendDelegate {
    func cameraBackend(_ backend: CameraBackend, didChangeState state: SessionState) {
        sessionState = state
        // A camera that stops shows nothing to focus on, and comes back on the whole frame.
        if state != .running { setMagnified(false) }
        if case .interrupted(let reason) = state {
            showToast(reason, symbol: "pause.circle")
        } else if case .failed(let reason) = state {
            showToast(reason, symbol: "exclamationmark.triangle")
        } else {
            return
        }
        // A session that stops ends a running stack with the frames it has (CameraService), and the screen shows it
        // as after a stop: lit for Processing, with no pill asking to keep still and no crosses to follow.
        if activity == .stacking {
            motionMonitor.endDrift()
            noteStackFinishing()
        }
    }

    func cameraBackend(_ backend: CameraBackend, didUpdateCapabilities capabilities: CameraCapabilities) {
        // Only the iPhone 18 Pro's main camera has an iris, so seeing one settles which phone this is.
        if capabilities.supportsVariableAperture, !allowsManualShutter {
            PhoneModel.variableApertureSeen = true
            allowsManualShutter = true
        }
        let previous = self.capabilities
        self.capabilities = capabilities
        // The magnifier was for the lens that was in use, and a lens without manual focus has none to offer.
        if isMagnified, previous.lens.id != capabilities.lens.id || !magnifierOffered { setMagnified(false) }
        // The new lens's format may run without the analysis output (over the hardware budget), and the old lens's
        // last frame would stay on screen.
        if settings.mode == .video, previous.lens.id != capabilities.lens.id { analysis = nil }
        refreshLenses()
        if let dial = activeDial, !dialAvailable(dial, in: settings.mode) {
            activeDial = nil
        }
        // The backend re-applies its last requests after a lens switch, but those were built for the lens it left:
        // on a fixed iris the aperture lock was left out, and the new lens may differ in manual focus.
        if previous.lens.id != capabilities.lens.id || previous.supportsVariableAperture != capabilities.supportsVariableAperture
            || previous.supportsManualFocus != capabilities.supportsManualFocus {
            scheduleApply(.exposure)
            scheduleApply(.focus)
        }
        // A scene's white balance and infinity focus only go to a lens that can hold them, and peaking follows
        // whether focus is held.
        if previous.supportsCustomWhiteBalance != capabilities.supportsCustomWhiteBalance {
            scheduleApply(.whiteBalance)
        }
        if previous.supportsManualFocus != capabilities.supportsManualFocus {
            applyAnalysis()
        }
        // The Camera Control's stops come from the lens and format, and a pinch can switch lens without select().
        // The backend skips a reinstall when nothing changed.
        applyCameraControls()
        // A stacked MANUAL shutter, and so the pill, depend on the lens's longest shutter.
        refreshSteadyStatus()
    }

    func cameraBackend(_ backend: CameraBackend, didUpdateReadings readings: LiveReadings) {
        self.readings = readings
        checkCloseSubject(readings)
        // While the magnifier is on, and until the frames after it show the whole frame, the meter reads only the
        // middle and would flip the stack's held ISO. The first reading after that drops the snapshot and lets the
        // limit follow the meter again.
        if magnifierMeter != nil, !isMagnified, Date() >= magnifierMeterUntil { magnifierMeter = nil }
        if magnifierMeter == nil { updateStackISOLimit() }
        adoptExternalChanges(from: readings)
        // NIGHT's automatic time and LONG's frames follow the light, and with them whether a tripod is needed.
        refreshSteadyStatus()
        if adoptNextWhiteBalanceReading, !readings.isAdjustingWhiteBalance {
            adoptNextWhiteBalanceReading = false
            // Written directly, so the request isn't sent again and the measured gains stay.
            settings.whiteBalance = .kelvin(readings.kelvin, tint: readings.tint)
            scheduleSave()
            if activeDial == nil { applyCameraControls() }
        }
    }

    func cameraBackend(_ backend: CameraBackend, didProduceAnalysis frame: AnalysisFrame) {
        // A frame already in flight when everything was switched off.
        guard !analysisOptions.isOff else { return }
        analysis = frame
    }

    func cameraBackendWillCapture(_ backend: CameraBackend) {
        shutterCount += 1
        // Processing and saving a plain photo go on while the next one starts. This arrives as the exposure
        // begins, so a long exposure keeps the shutter, focus and zoom until the exposure ends.
        if releasesAtExposure, activity == .capturing {
            let hold = displayShutter
            if hold.isFinite, hold > 0.1 {
                let generation = photoGeneration
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(min(hold, 30) * 1_000_000_000))
                    // A photo that already finished, or a newer one, owns the shutter state by now.
                    guard let self, self.photoGeneration == generation, self.releasesAtExposure,
                          self.activity == .capturing else { return }
                    self.releasesAtExposure = false
                    self.activity = .idle
                }
            } else {
                releasesAtExposure = false
                activity = .idle
            }
        }
    }

    func cameraBackend(_ backend: CameraBackend, didUpdateRecordingDuration duration: TimeInterval) {
        recordingDuration = duration
    }

    func cameraBackend(_ backend: CameraBackend, didReceiveControl change: CameraControlChange) {
        applyingControlChange = true
        defer { applyingControlChange = false }
        // A pick still on its way as its control went dim (a shot started, the mode changed) does nothing. The state
        // sent here puts the control back where the camera is.
        guard cameraControlWorks(Self.controlItem(of: change), in: cameraControlContext) else {
            applyCameraControls()
            return
        }
        // PHOTO has no focus or white balance control to go back to auto with, so a pick there moves to MANUAL, as
        // a shutter or ISO pick does. NIGHT keeps them to Manual night, where they are set in place.
        let leavesAutoMode = settings.mode == .photo
        switch change {
        case .shutter(let value): setShutter(value)
        case .iso(let value): setISO(value)
        case .aperture(let value): setAperture(value)
        case .kelvin(let value):
            guard let value else {
                setWhiteBalance(.auto)
                break
            }
            if leavesAutoMode {
                let range = WhiteBalanceMath.kelvinRange
                let kelvin = min(max(value, range.lowerBound), range.upperBound)
                let tint = effectiveWhiteBalance.tintValue
                switchToManual(keepingAutoExposure: true) { $0.whiteBalance = .kelvin(kelvin, tint: tint) }
            } else {
                setKelvin(value)
            }
        case .focus(let value):
            guard let value else {
                setManualFocus(nil)
                break
            }
            if leavesAutoMode {
                guard capabilities.supportsManualFocus else { break }
                switchToManual(keepingAutoExposure: true) { $0.focus = .manual(lensPosition: min(max(value, 0), 1)) }
            } else {
                setManualFocus(value)
            }
        case .mode(let mode): selectCarouselMode(mode)
        case .lens(let index):
            let presets = backLensPresets
            guard presets.indices.contains(index) else { break }
            if activity == .recording {
                // A movie keeps its lens, so the pick zooms the recording lens to that value, as the lens buttons do.
                setDisplayZoom(presets[index].displayZoom, animated: true)
            } else {
                // The Camera Control clicks on its own.
                select(presets[index], haptic: false)
            }
        case .duration(let seconds):
            setNightControlDuration(seconds)
        case .scene(let index):
            let choices = LongExposureScene.nightMenuChoices
            guard choices.indices.contains(index) else { break }
            // A slide passes back over the choice in use: picked again, it would only clear what was set by hand.
            if choices[index] != nightControlChoice.scene {
                selectNightScene(choices[index])
            }
        case .tint(let value):
            let range = WhiteBalanceMath.tintRange
            let tint = min(max(value, range.lowerBound), range.upperBound)
            if leavesAutoMode {
                let kelvin = displayKelvin
                switchToManual(keepingAutoExposure: true) { $0.whiteBalance = .kelvin(kelvin, tint: tint) }
            } else {
                setTint(tint)
            }
        case .timer(let index):
            let delays = CaptureSchedule.delayPresets
            // Custom, after the delays, stands for what the timer sheet sets and has nothing to set here: the state
            // sent below puts the picker back on what is set.
            guard delays.indices.contains(index) else { break }
            // A plain delay, in place of a burst or an intervalometer too, as the top bar's timer menu picks one.
            updateSettings { $0.capture.schedule = CaptureSchedule(delay: delays[index]) }
        case .flash(let flash):
            updateSettings { $0.capture.flash = flash }
        case .histogram(let style):
            updateSettings { $0.display.histogram = style }
        }
        // The overlay shows what the pick did: a scene's own time, Manual night's ISO coming alive, a clamped value or
        // a refused pick going back. The bridge spares the control under the finger until it rests.
        applyCameraControls()
    }

    /// The control a pick came from.
    private static func controlItem(of change: CameraControlChange) -> CameraControlItem {
        switch change {
        case .shutter: return .shutter
        case .iso: return .iso
        case .aperture: return .aperture
        case .kelvin: return .whiteBalance
        case .focus: return .focus
        case .mode: return .mode
        case .lens: return .lens
        case .duration: return .nightDuration
        case .scene: return .nightScene
        case .tint: return .tint
        case .timer: return .timer
        case .flash: return .flash
        case .histogram: return .histogram
        }
    }

    /// The Camera Control's Night duration. The night shot takes any time, nil for its own. A scene's Auto is the
    /// time the scene starts at; Manual night has none to go back to, so its Auto only puts the picker back.
    private func setNightControlDuration(_ seconds: Double?) {
        switch settings.mode {
        case .night:
            setNightSeconds(seconds)
        case .long:
            if let seconds {
                setLongExposureSeconds(seconds)
            } else if let start = sceneStartSeconds(settings.longExposure.scene) {
                setLongExposureSeconds(start)
            }
        case .photo, .manual, .video:
            break
        }
    }

    func cameraBackendControlsDidBecomeActive(_ backend: CameraBackend) {
        // A light press shows the overlay before any fullscreen appearance, and its zoom slider reads the device from
        // then on: the magnifier's zoom would show as the photo's, and a swipe would start from it. The press is also
        // someone looking at the screen.
        setMagnified(false)
        wakeScreen()
    }

    func cameraBackend(_ backend: CameraBackend, controlsFullscreenDidChange isFullscreen: Bool) {
        if controlsFullscreen != isFullscreen { controlsFullscreen = isFullscreen }
        // A light press on the Camera Control is someone looking at the screen. Its system zoom slider would show
        // the magnifier's zoom as the photo's, so the frame comes back whole first.
        if isFullscreen {
            setMagnified(false)
            wakeScreen()
        }
        refreshSteadyStatus()
    }
}
