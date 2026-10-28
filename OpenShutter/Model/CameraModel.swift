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
    private(set) var analysis: AnalysisFrame?
    private(set) var lenses: [LensInfo] = []
    private(set) var lensPresets: [LensPreset] = []
    private(set) var activePresetID: String? {
        // The Camera Control's Lens picker follows pinches, lens buttons and the system zoom slider.
        didSet { if oldValue != activePresetID { applyCameraControls() } }
    }

    private(set) var activity: CaptureActivity = .idle {
        didSet { if oldValue != activity { updateIdleTimer() } }
    }
    /// Photos from their request until they are saved. The session can't change lens or mode under them.
    private(set) var photosInFlight = 0
    /// Counts camera swaps started by select(): lens buttons, double tap, Camera Control Lens picks, flips, queued and
    /// deferred picks. The screen blurs the preview for each. A pinch or the zoom dial swaps without it, because the
    /// finger is still framing.
    private(set) var lensSwitchCount = 0
    /// A focus or white balance bracket is running: one capture made of several photos, stopped with the shutter.
    private(set) var bracketInProgress = false
    /// A stopped bracket is still finishing the photo it was taking, so the shutter has nothing left to do.
    private(set) var bracketStopping = false
    private(set) var stackProgress: StackProgress?
    private(set) var intervalometer: IntervalometerStatus? {
        didSet { updateIdleTimer() }
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

    /// Which manual control the dial is editing. Views bind to it.
    var activeDial: DialKind? {
        didSet {
            guard oldValue != activeDial else { return }
            // Peaking follows the focus dial in "manual focus" peaking mode.
            applyAnalysis()
            if activeDial == nil { applyCameraControls() }
        }
    }
    var isSettingsPresented = false
    var isDrawerOpen = false
    var isReviewPresented = false

    let backend: CameraBackend
    var isSimulated: Bool { backend.isSimulated }

    // MARK: - Dependencies and private state

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let motionMonitor: MotionMonitor
    @ObservationIgnored private let locationProvider: LocationProvider

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var backendRunning = false
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
    @ObservationIgnored private var lensSwitchInFlight = false
    /// The newest zoom asked for while a lens switch was reconfiguring the session, or one that needs another lens
    /// while photos were still being saved.
    @ObservationIgnored private var pendingZoom: (value: Double, animated: Bool)?
    /// The newest lens chosen while a lens switch was reconfiguring the session or photos were still being saved.
    @ObservationIgnored private var pendingPreset: LensPreset?
    /// A long press focused once and is holding that distance (the AF half of AE/AF LOCK).
    @ObservationIgnored private var focusHeld = false
    /// Counts photo captures, so a photo that finishes late can tell a newer one owns the shutter state.
    @ObservationIgnored private var photoGeneration = 0
    /// The newest photo frees the shutter as soon as it is exposed (cameraBackendWillCapture).
    @ObservationIgnored private var releasesAtExposure = false
    @ObservationIgnored private var rawNoticeShown = false
    /// A value picked on the Camera Control is already on show in its overlay, so it isn't reinstalled for it.
    @ObservationIgnored private var applyingControlChange = false
    /// NIGHT's metered light and bias when AE was locked, so recomposing doesn't change the plan.
    @ObservationIgnored private var lockedMeter: (product: Double, bias: Double)?
    @ObservationIgnored private var lockMeterTask: Task<Void, Never>?
    /// A stacked shutter with auto ISO wants less than base ISO for the whole time, so it is shot at base ISO and
    /// the preview is asked for that too (updateStackISOFloor).
    @ObservationIgnored private var stackISOAtFloor = false
    /// Pressing the shutter or a side button jolts a phone on a tripod, so the steady plan shown just before the
    /// press still counts for a moment after the motion sensor says otherwise.
    @ObservationIgnored private var steadyLostAt: Date?
    /// When the app last sent a zoom or an exposure bias. Readings that disagree after that settle came from
    /// somewhere else, like the Camera Control's system sliders, and get adopted.
    @ObservationIgnored private var lastZoomCommand = Date.distantPast
    @ObservationIgnored private var lastBiasCommand = Date.distantPast

    private enum ApplyKind: Hashable {
        case exposure, focus, whiteBalance
    }

    // Default arguments run outside the main actor, so the main-actor helpers are built in the body.
    init(backend: CameraBackend, store: SettingsStore = SettingsStore(), motionMonitor: MotionMonitor? = nil, locationProvider: LocationProvider? = nil) {
        self.backend = backend
        self.store = store
        self.motionMonitor = motionMonitor ?? MotionMonitor()
        self.locationProvider = locationProvider ?? LocationProvider()
        self.settings = store.load()
    }

    // MARK: - Lifecycle

    /// Checks permission, starts the backend with the saved settings, starts motion and location.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        backend.delegate = self
        Haptics.isEnabled = settings.controls.haptics
        Haptics.prepare()
        motionMonitor.onUpdate = { [weak self] state in
            guard let self else { return }
            if self.motion.isSteady, !state.isSteady { self.steadyLostAt = Date() }
            self.motion = state
        }

        authorization = backend.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await backend.requestAuthorization()
        }
        guard authorization == .authorized else { return }
        await startBackend()
    }

    func stop() {
        cancelSchedule()
        motionMonitor.stop()
        locationProvider.setEnabled(false)
        backend.stop()
        backendRunning = false
    }

    func sceneDidBecomeActive() {
        guard hasStarted else { return }
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
        guard backendRunning else { return }
        // The scene in front of the lens will have changed by the time the app comes back.
        releaseLock()
        turnTorchOff()
        // A lens change still waiting for photos to save would otherwise land on the stopped session.
        pendingPreset = nil
        pendingZoom = nil
        if activity == .recording {
            stopRecording()
        }
        if case .countdown = activity {
            cancelSchedule()
        } else if intervalometer != nil || bracketInProgress {
            // A bracket's remaining frames would only fail one by one against the stopped session.
            cancelSchedule()
        }
        motionMonitor.stop()
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

    private func startBackend() async {
        guard !backendRunning else { return }
        backendRunning = true
        sessionState = .starting
        await backend.start(settings: settings)
        // A backend that failed or got interrupted has already said so; otherwise start returning means it runs.
        if sessionState == .starting || sessionState == .idle {
            sessionState = .running
        }
        refreshLenses()
        applyAll()
        if settings.mode == .video {
            await backend.configureForVideo(settings.video)
            applyAll()
            noteMicrophoneIfDenied()
        }
        motionMonitor.start()
        locationProvider.setEnabled(settings.capture.saveLocation)
    }

    private func refreshLenses() {
        lenses = backend.lenses
        lensPresets = backend.lensPresets
        updateActivePreset()
    }

    private func applyAll() {
        lastZoomCommand = Date()
        lastBiasCommand = Date()
        backend.apply(options: DeviceOptions(settings: settings))
        backend.apply(exposure: currentExposureRequest())
        backend.apply(focus: currentFocusRequest())
        backend.apply(whiteBalance: currentWhiteBalanceRequest())
        applyAnalysis()
        applyCameraControls()
    }

    // MARK: - Mode and lens

    func setMode(_ mode: CaptureMode) {
        // The carousel and the Camera Control play their own clicks.
        guard mode != settings.mode, canChangeMode else { return }
        releaseLock()
        if let dial = activeDial, !dialAvailable(dial, in: mode) {
            activeDial = nil
        }
        updateSettings { $0.mode = mode }
    }

    /// A capture keeps the mode it started in. Between intervalometer shots the activity reads idle, but a switch
    /// to VIDEO would leave the remaining shots with nothing to take; photos still being processed and saved need
    /// the session as it was when they were exposed.
    private var canChangeMode: Bool {
        !activity.isBusy && intervalometer == nil && photosInFlight == 0
    }

    /// Picking a manual value in PHOTO or NIGHT is a request for manual control, the way a camera's mode dial
    /// works. It goes by setMode's rules, and a lock set in the old mode goes with it. A focus or white balance pick
    /// says nothing about exposure, so keepingAutoExposure leaves MANUAL's saved shutter, ISO and aperture behind
    /// instead of bringing them back into the shot.
    private func switchToManual(keepingAutoExposure: Bool = false, _ change: (inout CameraSettings) -> Void) {
        guard canChangeMode else { return }
        releaseLock()
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
    func select(_ preset: LensPreset, haptic: Bool = true) {
        guard !activity.isBusy else { return }
        lastZoomCommand = Date()
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
        if let lens = lenses.first(where: { $0.id == preset.lensID }), !lens.isFront {
            lastBackPresetID = preset.id
        }
        activePresetID = preset.id
        settings.lensID = preset.lensID
        settings.zoom = preset.zoomFactor
        scheduleSave()
        if haptic { Haptics.tap() }
        if current == preset.lensID {
            backend.setZoomFactor(preset.zoomFactor, animated: true)
            return
        }
        // The locked point and exposure belong to the lens being left.
        releaseLock()
        lensSwitchCount &+= 1
        lensSwitchInFlight = true
        Task {
            await backend.select(preset)
            lensSwitchInFlight = false
            refreshLenses()
            applyCameraControls()
            applyPendingLensChange()
        }
    }

    /// Pinch and zoom dial. Display zoom is relative to the back wide camera; switches lenses when
    /// settings.controls.autoLensSwitching is on and the zoom crosses another lens.
    func setDisplayZoom(_ zoom: Double, animated: Bool) {
        guard zoom.isFinite, zoom > 0 else { return }
        lastZoomCommand = Date()
        // A pinch or a flicked dial keeps going while the session switches lenses; dropping those values would
        // leave the zoom short of where the finger stopped.
        guard !lensSwitchInFlight else {
            pendingZoom = (zoom, animated)
            pendingPreset = nil
            return
        }
        guard let activeLens = activeLens else { return }

        var targetLens = activeLens
        // Photos still being saved keep the session on its lens. A zoom that wants another lens zooms this one for
        // now and switches once they are in.
        var waitsForPhotos = false
        if settings.controls.autoLensSwitching, !activeLens.isFront, !activity.isBusy {
            let backLenses = lenses.filter { !$0.isFront && $0.kind != .external }
            // The longest lens that still covers this zoom without cropping past its own field of view.
            if let best = backLenses.filter({ $0.relativeZoom <= zoom + 0.001 }).max(by: { $0.relativeZoom < $1.relativeZoom })
                ?? backLenses.min(by: { $0.relativeZoom < $1.relativeZoom }) {
                if photosInFlight == 0 {
                    targetLens = best
                } else {
                    waitsForPhotos = best.id != activeLens.id
                }
            }
        }
        // The newest request wins, and a zoom back within this lens's own range cancels a switch still waiting.
        pendingPreset = nil
        pendingZoom = waitsForPhotos ? (zoom, false) : nil

        let base = max(targetLens.relativeZoom, 0.01)
        let factor = zoom / base
        if targetLens.id != activeLens.id {
            let preset = lensPresets.first(where: { $0.lensID == targetLens.id && abs($0.zoomFactor - 1) < 0.01 })
                ?? LensPreset(lensID: targetLens.id, zoomFactor: 1, displayZoom: targetLens.relativeZoom)
            releaseLock()
            lensSwitchInFlight = true
            activePresetID = preset.id
            settings.lensID = targetLens.id
            Task {
                await backend.select(preset)
                lensSwitchInFlight = false
                refreshLenses()
                let clamped = clampZoomFactor(factor)
                settings.zoom = clamped
                backend.setZoomFactor(clamped, animated: false)
                updateActivePreset()
                scheduleSave()
                applyPendingLensChange()
            }
            return
        }

        let clamped = clampZoomFactor(factor)
        settings.zoom = clamped
        backend.setZoomFactor(clamped, animated: animated)
        updateActivePreset(factor: clamped)
        scheduleSave()
    }

    /// Whatever was asked for last while a lens switch was in flight or photos were being saved: a lens or a zoom.
    private func applyPendingLensChange() {
        if let preset = pendingPreset {
            pendingPreset = nil
            select(preset, haptic: false)
        } else if let pending = pendingZoom {
            pendingZoom = nil
            setDisplayZoom(pending.value, animated: pending.animated)
        }
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
        backend.setTorch(level: wanted ? 1 : nil)
        Haptics.tap()
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
        switch settings.mode {
        case .long:
            guard let value else { return }
            updateSettings { $0.longExposure.seconds = min(max(value, 0.25), 1800) }
        case .video:
            let limit = 1.0 / max(recordedVideo.frameRate, 1)
            updateSettings { $0.manual.shutter = value.map { min($0, limit) } }
        case .manual:
            updateSettings { $0.manual.shutter = value }
        case .photo, .night:
            guard let value else { return }
            switchToManual { $0.manual.shutter = value }
        }
    }

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

    /// nil = auto (or the fixed f-number on lenses without an iris).
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
        showToast(aeLocked ? "AE LOCK" : "AE lock off", symbol: aeLocked ? "lock.fill" : "lock.open")
        scheduleApply(.exposure)
    }

    func resetExposureToAuto() {
        releaseLock()
        updateSettings {
            $0.manual.shutter = nil
            $0.manual.iso = nil
            $0.manual.aperture = nil
            $0.manual.bias = 0
        }
        Haptics.tap()
    }

    // MARK: - Focus

    /// nil = continuous autofocus.
    func setManualFocus(_ lensPosition: Double?) {
        guard lensPosition == nil || capabilities.supportsManualFocus else { return }
        let value = lensPosition.map { min(max($0, 0), 1) }
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
        let focusIsAuto = settings.focus.lensPosition == nil
        let request = currentExposureRequest()
        let exposureIsAuto = request.locks.isAllAuto
        // Spot and whole frame metering follow the tap as long as the meter decides something: a value auto exposure
        // still sets, or a stack's auto ISO held at the floor. Only a fully manual exposure leaves the meter be.
        let metersHere = stackISOAtFloor
            || !request.locks.isFullyManual(variableAperture: capabilities.supportsVariableAperture)
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
            // Manual focus or a manual exposure has nothing to hold, so the toast names only what is locked.
            if focusHeld || aeLocked {
                Haptics.stop()
                showToast(focusHeld && aeLocked ? "AE/AF LOCK" : (aeLocked ? "AE LOCK" : "AF LOCK"), symbol: "lock.fill")
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

    /// Ends AE LOCK or AE/AF LOCK: exposure follows its request again, a held focus goes back to autofocus, and
    /// the lock's square goes with it.
    private func releaseLock() {
        if aeLocked {
            aeLocked = false
            scheduleApply(.exposure)
        }
        guard focusHeld else { return }
        focusHeld = false
        reticleTask?.cancel()
        focusPoint = nil
        backend.apply(focus: currentFocusRequest())
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

    func setWhiteBalance(_ setting: WhiteBalanceSetting) {
        updateSettings { $0.whiteBalance = setting }
    }

    /// Switches to a custom temperature, keeping the current tint.
    func setKelvin(_ kelvin: Double) {
        let range = WhiteBalanceMath.kelvinRange
        let k = min(max(kelvin, range.lowerBound), range.upperBound)
        let tint = settings.whiteBalance.tintValue
        updateSettings { $0.whiteBalance = .kelvin(k, tint: tint) }
    }

    func setTint(_ tint: Double) {
        let range = WhiteBalanceMath.tintRange
        let t = min(max(tint, range.lowerBound), range.upperBound)
        let k = settings.whiteBalance.kelvinValue ?? readings.kelvin
        updateSettings { $0.whiteBalance = .kelvin(k, tint: t) }
    }

    /// Locks white balance to whatever is in the middle of the frame being neutral gray.
    func setWhiteBalanceFromGrayCard() {
        guard capabilities.supportsCustomWhiteBalance else { return }
        adoptNextWhiteBalanceReading = true
        backend.apply(whiteBalance: .grayWorld)
        Haptics.tap()
        showToast("White balance set from the scene", symbol: "eyedropper")
    }

    // MARK: - Night and long exposure

    /// nil = automatic duration from the light level.
    func setNightSeconds(_ seconds: Double?) {
        let range = NightModePlanner.secondsRange
        updateSettings { $0.night.seconds = seconds.map { min(max($0, range.lowerBound), range.upperBound) } }
    }

    func setNightStability(_ choice: NightStabilityChoice) {
        updateSettings { $0.night.stability = choice }
    }

    func setLongExposureSeconds(_ seconds: Double) {
        updateSettings { $0.longExposure.seconds = min(max(seconds, 0.25), 1800) }
    }

    func setLongExposureBlend(_ blend: StackBlend) {
        updateSettings { $0.longExposure.blend = blend }
    }

    /// Shutter for each Blur or Trails frame; nil leaves it to auto exposure.
    func setLongExposureFrameSeconds(_ seconds: Double?) {
        let range = capabilities.exposure.seconds
        updateSettings { $0.longExposure.frameSeconds = seconds.map { min(max($0, range.lowerBound), range.upperBound) } }
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
            // A second tap ends a bulb or long exposure and keeps what it has, like releasing a cable release.
            backend.finishStackEarly()
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
        }
        guard canCapture else {
            if !settings.capture.isValid {
                showToast("Pick a photo format in Settings.", symbol: "exclamationmark.triangle")
            }
            return
        }
        if settings.mode == .video {
            startRecording()
            return
        }
        // Earlier photos are still being processed and saved: only another plain photo can start alongside them.
        if photosInFlight > 0, !(pressTakesPlainPhoto && photosInFlight < Self.maxPhotosInFlight) { return }
        let schedule = settings.capture.schedule
        if schedule.isOff || (settings.mode == .long && settings.longExposure.bulb) {
            scheduleTask = Task { [weak self] in
                await self?.performCapture(bulb: self?.isBulbMode ?? false, releaseAtExposure: true)
            }
        } else {
            runSchedule(schedule)
        }
    }

    /// AVCapturePhotoOutput takes the next photo while it still processes the last ones. Each one in flight holds
    /// a full-size image until it is saved, so a run of taps stops here.
    private static let maxPhotosInFlight = 4

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
        guard isBulbMode, activity == .idle, photosInFlight == 0, canCapture else { return }
        bulbHoldActive = true
        scheduleTask = Task { [weak self] in
            await self?.performCapture(bulb: true)
        }
    }

    func shutterHoldEnded() {
        guard bulbHoldActive else { return }
        bulbHoldActive = false
        if activity == .stacking {
            backend.finishStackEarly()
        }
    }

    /// Stops what is running and keeps the result (stack so far, intervalometer, timer).
    func stopCapture() {
        // A bracket only sees the stop once the photo in progress is saved.
        if bracketInProgress { bracketStopping = true }
        cancelSchedule()
        if activity == .stacking {
            backend.finishStackEarly()
        }
        if activity == .recording {
            stopRecording()
        }
    }

    /// Aborts a running stack and discards it.
    func cancelCapture() {
        cancelSchedule()
        if activity == .stacking {
            backend.cancelStack()
        }
    }

    private var isBulbMode: Bool {
        settings.mode == .long && settings.longExposure.bulb
    }

    private func cancelSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        intervalometer = nil
        if case .countdown = activity {
            activity = .idle
        }
    }

    private func runSchedule(_ schedule: CaptureSchedule) {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            if schedule.delay > 0 {
                let completed = await self.countdown(schedule.delay)
                guard completed else { return }
            }
            for index in 0..<schedule.shots {
                if Task.isCancelled { break }
                if schedule.shots > 1 {
                    self.intervalometer = IntervalometerStatus(shot: index + 1, total: schedule.shots, nextShotAt: nil)
                }
                await self.performCapture(bulb: false)
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

    /// Counts down whole seconds. Returns false when cancelled.
    private func countdown(_ seconds: Double) async -> Bool {
        var remaining = seconds
        while remaining > 0 {
            if Task.isCancelled { return false }
            activity = .countdown(remaining: Int(remaining.rounded(.up)))
            Haptics.tap()
            let step = remaining - (remaining.rounded(.up) - 1)
            let sleep = step > 0 ? step : 1
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
            remaining -= sleep
        }
        if Task.isCancelled { return false }
        activity = .idle
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
    /// processing and the save, so the next photo can start.
    private func performPhoto(bracket: BracketPlan, releaseAtExposure: Bool = false) async {
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
        }
        let request = makePhotoRequest(bracket: bracket)
        // Read before the shot, since the zoom can change while it is processed.
        let rawNeedsOneX = rawBlockedByZoom
        do {
            let results = try await backend.capturePhoto(request)
            handle(results)
            if rawNeedsOneX { noteRawLeftOut(request, results: results) }
        } catch {
            report(error)
        }
    }

    /// AVFoundation leaves Bayer RAW out of zoomed shots, so only the processed photo is saved. The RAW chip shows
    /// it as well, so this is said once.
    private func noteRawLeftOut(_ request: PhotoRequest, results: [CaptureResult]) {
        guard !rawNoticeShown, !results.isEmpty, results.allSatisfy({ $0.kind == .photo && $0.savedToLibrary }) else { return }
        rawNoticeShown = true
        let saved = request.processedFormat == .jpeg ? "JPEG" : "HEIF"
        showToast("RAW needs the lens at 1\u{00D7}. Saved \(saved) only.", symbol: "exclamationmark.triangle")
    }

    private func performFocusBracket() async {
        let center = settings.focus.lensPosition ?? readings.lensPosition
        let positions = settings.capture.bracket.focusPositions(center: center)
        // One capture from the first frame to the last: the shutter stops it, and lens, mode and focus stay put
        // between frames.
        bracketInProgress = true
        activity = .capturing
        defer {
            bracketInProgress = false
            bracketStopping = false
            if activity == .capturing { activity = .idle }
        }
        for position in positions {
            if Task.isCancelled { break }
            backend.apply(focus: .manual(position))
            // The lens needs a moment to travel; there is no completion callback across the backend boundary.
            try? await Task.sleep(nanoseconds: 350_000_000)
            // A stopped bracket's sleep returns at once and would still take one more frame.
            if Task.isCancelled { break }
            await performPhoto(bracket: .off)
        }
        // An AE/AF lock goes back to the distance it held; continuous AF would quietly end it.
        backend.apply(focus: focusHeld ? .manual(center) : currentFocusRequest())
    }

    private func performWhiteBalanceBracket() async {
        let center = settings.whiteBalance.kelvinValue ?? readings.kelvin
        let tint = settings.whiteBalance.tintValue
        bracketInProgress = true
        activity = .capturing
        defer {
            bracketInProgress = false
            bracketStopping = false
            if activity == .capturing { activity = .idle }
        }
        for kelvin in settings.capture.bracket.kelvinValues(center: center) {
            if Task.isCancelled { break }
            backend.apply(whiteBalance: .temperature(kelvin: kelvin, tint: tint))
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { break }
            await performPhoto(bracket: .off)
        }
        backend.apply(whiteBalance: currentWhiteBalanceRequest())
    }

    private func performStack(request: StackRequest) async {
        activity = .stacking
        stackProgress = StackProgress(
            framesCaptured: 0,
            framesPlanned: request.isBulb ? 0 : request.plan.frameCount,
            elapsed: 0,
            estimatedTotal: request.isBulb ? nil : request.plan.estimatedDuration(),
            preview: nil
        )
        do {
            let result = try await backend.captureStack(request) { [weak self] progress in
                self?.stackProgress = progress
            }
            activity = .saving
            handle([result])
        } catch let error as CameraError where error == .cancelled {
            showToast("Cancelled", symbol: "xmark")
        } catch {
            report(error)
        }
        stackProgress = nil
        activity = .idle
        bulbHoldActive = false
    }

    private func startRecording() {
        activity = .recording
        recordingDuration = 0
        let request = VideoRequest(settings: settings.video, location: currentLocation)
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

    private func makePhotoRequest(bracket: BracketPlan) -> PhotoRequest {
        let capture = settings.capture
        let manualBase: ExposureValues? = isManualExposure
            ? ExposureValues(seconds: readings.exposureSeconds, iso: readings.iso, aperture: readings.aperture)
            : nil
        return PhotoRequest(
            processedFormat: capture.processedFormat,
            rawFormat: capture.rawFormat,
            quality: capture.quality,
            resolution: capture.resolution,
            processing: effectiveProcessing,
            flash: capture.flash,
            aspect: capture.aspect,
            // Live is switched on and off in PHOTO only, so MANUAL never records a movie nobody can see is on.
            livePhoto: capture.livePhoto && settings.mode == .photo,
            silentShutter: capture.silentShutter,
            depth: capture.depth,
            constantColor: capture.constantColor,
            contentAwareCorrection: capture.lensCorrection,
            location: currentLocation,
            bracket: bracket.kind == .exposure ? bracket : .off,
            bracketBase: manualBase
        )
    }

    private func makeStackRequest(plan: StackPlan, bulb: Bool, noiseReduction: Double) -> StackRequest {
        StackRequest(
            plan: plan,
            isBulb: bulb,
            processedFormat: settings.capture.processedFormat == .none ? .heif : settings.capture.processedFormat,
            quality: settings.capture.quality,
            aspect: settings.capture.aspect,
            location: currentLocation,
            noiseReduction: noiseReduction
        )
    }

    // MARK: - Settings

    /// Mutates settings, saves them, and re-applies whatever changed to the backend.
    func updateSettings(_ change: (inout CameraSettings) -> Void) {
        var next = settings
        change(&next)
        if !next.capture.isValid {
            next.capture.processedFormat = .heif
        }
        guard next != settings else { return }
        let old = settings
        settings = next
        scheduleSave()
        reapply(from: old, to: next)
    }

    func showToast(_ message: String, symbol: String? = nil) {
        let item = Toast(message: message, symbol: symbol)
        toast = item
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == item.id else { return }
            self.toast = nil
        }
    }

    private func reapply(from old: CameraSettings, to new: CameraSettings) {
        // Before any request is built from these settings, including the one a mode change sends at once.
        if old.mode != new.mode || old.manual != new.manual || old.longExposure != new.longExposure {
            updateStackISOFloor()
        }
        if old.mode != new.mode {
            modeDidChange(from: old.mode, to: new.mode)
            return
        }
        if DeviceOptions(settings: old) != DeviceOptions(settings: new) {
            backend.apply(options: DeviceOptions(settings: new))
        }
        if old.manual != new.manual || old.longExposure != new.longExposure || old.night.biasEV != new.night.biasEV
            || old.exposure.aeMaxShutter != new.exposure.aeMaxShutter || old.video.frameRate != new.video.frameRate {
            scheduleApply(.exposure)
        }
        if old.whiteBalance != new.whiteBalance {
            scheduleApply(.whiteBalance)
        }
        if old.focus != new.focus {
            scheduleApply(.focus)
        }
        if old.display != new.display || old.focus != new.focus {
            applyAnalysis()
        }
        // The Camera Control overlay shows these too. An open dial updates it when it closes, since every
        // reinstall reconfigures the session.
        let controlValuesChanged = old.manual.locks != new.manual.locks || old.whiteBalance != new.whiteBalance
            || old.focus != new.focus || old.longExposure != new.longExposure || old.video.frameRate != new.video.frameRate
        if old.controls.cameraControlItems != new.controls.cameraControlItems
            || (controlValuesChanged && activeDial == nil && !applyingControlChange) {
            applyCameraControls()
        }
        if old.controls.haptics != new.controls.haptics {
            Haptics.isEnabled = new.controls.haptics
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
            Task {
                await backend.configureForVideo(video)
                analysis = nil
                applyAll()
                noteMicrophoneIfDenied()
            }
        } else if old == .video {
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
        if kinds.contains(.exposure) { lastBiasCommand = Date() }
        pendingApply.removeAll()
        applyTask = nil
        if kinds.contains(.exposure) { backend.apply(exposure: currentExposureRequest()) }
        if kinds.contains(.focus) { backend.apply(focus: currentFocusRequest()) }
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
        let manualFocus = settings.focus.lensPosition != nil || activeDial == .focus
        let peaking = display.peaking == .always || (display.peaking == .manualFocus && manualFocus)
        return AnalysisOptions(
            histogram: display.histogram != .off,
            rgbHistogram: display.histogram == .rgb,
            zebraThreshold: display.zebras ? display.zebraThreshold : nil,
            peakingThreshold: peaking ? OverlayOptions.peakingThreshold(sensitivity: display.peakingSensitivity) : nil,
            peakingColor: display.peakingColor,
            falseColor: display.falseColor,
            clipping: display.clippingWarnings
        )
    }

    private func applyCameraControls() {
        let state = CameraControlState(
            items: settings.controls.cameraControlItems,
            shutterStops: shutterScale.map(\.seconds),
            // LONG's shutter picker sets the duration, which Blur and Trails have as well; it is never Auto there.
            shutter: settings.mode == .long ? settings.longExposure.seconds : (isShutterAuto ? nil : displayShutter),
            isoStops: isoScale,
            iso: isISOAuto ? nil : displayISO,
            apertureStops: apertureScale,
            aperture: isApertureAuto ? nil : displayAperture,
            kelvin: settings.whiteBalance.kelvinValue,
            lensPosition: settings.focus.lensPosition,
            mode: settings.mode,
            lensTitles: backLensPresets.map(\.selectedLabel),
            lensIndex: backLensPresets.firstIndex(where: { $0.id == activePresetID })
        )
        backend.configureCameraControls(state)
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
            let iso = manual.iso ?? (stackISOAtFloor && shutterIsStacked ? capabilities.exposure.iso.lowerBound : nil)
            let locks = ExposureLocks(seconds: manual.shutter, iso: iso, aperture: aperture)
            return ExposureRequest(locks: locks, bias: manual.bias, aeLocked: aeLocked && locks.isAllAuto, maxAutoSeconds: maxAuto)
        case .video:
            let frameLimit = 1.0 / max(recordedVideo.frameRate, 1)
            let locks = ExposureLocks(seconds: manual.shutter.map { min($0, frameLimit) }, iso: manual.iso, aperture: aperture)
            return ExposureRequest(locks: locks, bias: manual.bias, aeLocked: aeLocked && locks.isAllAuto, maxAutoSeconds: frameLimit)
        case .long:
            let long = settings.longExposure
            switch long.blend {
            case .additive:
                // Auto ISO runs shutter priority at the longest frame, as MANUAL's stacked shutter does, so the
                // meter sees the scene and longPlan can pick the ISO for the whole time. A bulb has no known length,
                // so it stays at base ISO. So does a scene too bright for base ISO over the whole time: the stack
                // comes out brighter than the meter wants, and the preview, brightened to match, shows it.
                let iso = manual.iso ?? (long.bulb || stackISOAtFloor ? capabilities.exposure.iso.lowerBound : nil)
                let locks = ExposureLocks(seconds: long.seconds, iso: iso, aperture: aperture)
                return ExposureRequest(locks: locks, bias: manual.bias, aeLocked: false, maxAutoSeconds: maxAuto)
            case .average, .lighten:
                let range = capabilities.exposure.seconds
                let frame = long.frameSeconds.map { min(max($0, range.lowerBound), range.upperBound) }
                let locks = ExposureLocks(seconds: frame, iso: manual.iso, aperture: aperture)
                return ExposureRequest(locks: locks, bias: manual.bias, aeLocked: aeLocked && locks.isAllAuto, maxAutoSeconds: maxAuto)
            }
        }
    }

    /// Shutter priority at the longest frame previews a stack with auto ISO only while the ISO for the whole time
    /// is in range. Below base ISO the stack comes out brighter than that preview, so the request fixes base ISO
    /// and the backend brightens the preview by the missing stops. Follows the meter as readings arrive.
    private func updateStackISOFloor() {
        guard let seconds = autoISOStackSeconds else {
            // Sent again so the backend's stored request, which it re-applies after lens and format changes,
            // doesn't keep base ISO.
            if stackISOAtFloor {
                stackISOAtFloor = false
                scheduleApply(.exposure)
            }
            return
        }
        // A running capture keeps the request it started with.
        guard !activity.isBusy else { return }
        let aperture = capabilities.supportsVariableAperture ? (settings.manual.aperture ?? readings.aperture) : readings.aperture
        let metered = ExposureMath.iso(forProduct: meteredProduct, seconds: seconds, aperture: aperture)
        let floor = capabilities.exposure.iso.lowerBound
        // A third of a stop of slack keeps a meter hovering at base ISO from switching the preview back and forth.
        let atFloor = stackISOAtFloor ? metered < floor * pow(2, 1.0 / 3) : metered < floor
        guard atFloor != stackISOAtFloor else { return }
        stackISOAtFloor = atFloor
        scheduleApply(.exposure)
    }

    /// The whole time a stack with auto ISO spreads its light over: LONG Real, or MANUAL past the longest shutter.
    private var autoISOStackSeconds: Double? {
        guard settings.manual.iso == nil else { return nil }
        switch settings.mode {
        case .long:
            let long = settings.longExposure
            return long.blend == .additive && !long.bulb ? long.seconds : nil
        case .manual:
            return shutterIsStacked ? settings.manual.shutter : nil
        case .photo, .night, .video:
            return nil
        }
    }

    private func currentFocusRequest() -> FocusRequest {
        if let position = settings.focus.lensPosition, capabilities.supportsManualFocus {
            return .manual(position)
        }
        return .continuousAuto
    }

    private func currentWhiteBalanceRequest() -> WhiteBalanceRequest {
        switch settings.whiteBalance {
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

    private func updateActivePreset(factor: Double? = nil) {
        guard let lensID = backend.activeLensID ?? settings.lensID else {
            activePresetID = lensPresets.first?.id
            return
        }
        let zoom = factor ?? settings.zoom
        let candidates = lensPresets.filter { $0.lensID == lensID }
        let match = candidates.filter { $0.zoomFactor <= zoom + 0.01 }.max(by: { $0.zoomFactor < $1.zoomFactor })
            ?? candidates.min(by: { $0.zoomFactor < $1.zoomFactor })
        activePresetID = match?.id ?? activePresetID
    }

    /// The Camera Control's system zoom and exposure sliders drive the device directly. Once the app's own
    /// commands have had a second to land, a reading that still disagrees came from there and becomes the setting,
    /// so chips, presets and the saved state follow the hardware.
    private func adoptExternalChanges(from readings: LiveReadings) {
        let now = Date()
        var changed = false
        if !lensSwitchInFlight, !activity.isBusy, now.timeIntervalSince(lastZoomCommand) > 1,
           readings.zoomFactor.isFinite, readings.zoomFactor > 0, abs(readings.zoomFactor - settings.zoom) > 0.01 {
            settings.zoom = readings.zoomFactor
            updateActivePreset(factor: readings.zoomFactor)
            changed = true
        }
        let currentBias = settings.mode == .night ? settings.night.biasEV : settings.manual.bias
        if !activity.isBusy, pendingApply.isEmpty, now.timeIntervalSince(lastBiasCommand) > 1,
           readings.bias.isFinite, abs(readings.bias - currentBias) > 0.05 {
            if settings.mode == .night {
                settings.night.biasEV = readings.bias
            } else {
                settings.manual.bias = readings.bias
            }
            changed = true
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
        externalSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, !self.lensSwitchInFlight, !self.activity.isBusy else { return }
            self.lastZoomCommand = Date()
            self.backend.setZoomFactor(self.settings.zoom, animated: false)
            self.scheduleApply(.exposure)
        }
    }

    private func dialAvailable(_ dial: DialKind, in mode: CaptureMode) -> Bool {
        switch dial {
        case .aperture: return capabilities.supportsVariableAperture
        case .tint: return !settings.whiteBalance.isAuto
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
            return ShutterSpeed.scale(minSeconds: max(hardware.lowerBound, 0.25), maxSeconds: 1800)
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
    /// the light measured at the lock, moved by any bias change since, as a locked exposure would be.
    private var meteredProduct: Double {
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

    /// What LONG mode would do right now.
    var longPlan: StackPlan {
        let long = settings.longExposure
        let aperture = capabilities.supportsVariableAperture ? (settings.manual.aperture ?? readings.aperture) : readings.aperture
        switch long.blend {
        case .additive:
            let caps = capabilities.exposure
            // Auto ISO gives the metered light over the whole time, like MANUAL's stacked shutter. A bulb has no
            // known length, so it keeps base ISO.
            let metered = ExposureMath.iso(forProduct: meteredProduct, seconds: long.seconds, aperture: aperture)
            let iso = settings.manual.iso ?? (long.bulb ? caps.iso.lowerBound : min(max(metered, caps.iso.lowerBound), caps.iso.upperBound))
            return LongExposurePlanner.plan(totalSeconds: long.seconds, blend: .additive, iso: iso, aperture: aperture,
                                            frameSeconds: nil, ranges: caps, align: long.align)
        case .average, .lighten:
            // The planner clamps a chosen frame to this lens's range, as the request does.
            return LongExposurePlanner.plan(totalSeconds: long.seconds, blend: long.blend, iso: settings.manual.iso ?? readings.iso,
                                            aperture: aperture, frameSeconds: long.frameSeconds ?? readings.exposureSeconds,
                                            ranges: capabilities.exposure, align: long.align)
        }
    }

    /// MANUAL mode with a shutter past the hardware limit: a Real (additive) stack.
    private var manualStackPlan: StackPlan {
        let seconds = settings.manual.shutter ?? capabilities.exposure.seconds.upperBound
        let aperture = capabilities.supportsVariableAperture ? (settings.manual.aperture ?? readings.aperture) : readings.aperture
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

    var showsClippingWarning: Bool {
        guard settings.display.clippingWarnings, let stats = analysis?.stats else { return false }
        return stats.clippedHighlights > 0.02
    }

    var canCapture: Bool {
        authorization == .authorized && sessionState == .running && settings.capture.isValid
    }

    /// A shutter press (screen, volume buttons or Camera Control) would do something right now. The button skips
    /// its click and haptic otherwise, so a press is never felt without a result.
    var shutterAcceptsPress: Bool {
        switch activity {
        case .idle:
            if intervalometer != nil { return true }
            guard canCapture else { return false }
            return photosInFlight == 0 || (pressTakesPlainPhoto && photosInFlight < Self.maxPhotosInFlight)
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
        case .photo, .night:
            return readings.iso
        }
    }

    var displayAperture: Double {
        if capabilities.supportsVariableAperture, settings.mode != .photo, settings.mode != .night, let f = settings.manual.aperture {
            return f
        }
        return readings.aperture
    }

    var displayKelvin: Double { settings.whiteBalance.kelvinValue ?? readings.kelvin }
    var displayTint: Double { settings.whiteBalance.isAuto ? readings.tint : settings.whiteBalance.tintValue }
    var displayLensPosition: Double { settings.focus.lensPosition ?? readings.lensPosition }

    var isShutterAuto: Bool {
        switch settings.mode {
        case .manual, .video: return settings.manual.shutter == nil
        case .long: return settings.longExposure.blend != .additive
        case .photo, .night: return true
        }
    }

    var isISOAuto: Bool {
        switch settings.mode {
        case .manual, .video, .long: return settings.manual.iso == nil
        case .photo, .night: return true
        }
    }

    var isApertureAuto: Bool {
        guard capabilities.supportsVariableAperture else { return true }
        switch settings.mode {
        case .manual, .video, .long: return settings.manual.aperture == nil
        case .photo, .night: return true
        }
    }

    var isWhiteBalanceAuto: Bool { settings.whiteBalance.isAuto }
    var isFocusAuto: Bool { settings.focus.lensPosition == nil }

    /// "1/250 · ISO 100 · ƒ/1.8 · +0.3" for the readout.
    var exposureSummary: String {
        var parts = [
            ShutterSpeed(seconds: displayShutter).label,
            ISOScale.label(displayISO),
            ApertureScale.label(displayAperture),
        ]
        let bias = settings.mode == .night ? settings.night.biasEV : settings.manual.bias
        if abs(bias) >= 0.05 {
            parts.append(EVFormat.label(bias))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Backend events

extension CameraModel: CameraBackendDelegate {
    func cameraBackend(_ backend: CameraBackend, didChangeState state: SessionState) {
        sessionState = state
        if case .interrupted(let reason) = state {
            showToast(reason, symbol: "pause.circle")
        } else if case .failed(let reason) = state {
            showToast(reason, symbol: "exclamationmark.triangle")
        }
    }

    func cameraBackend(_ backend: CameraBackend, didUpdateCapabilities capabilities: CameraCapabilities) {
        let previous = self.capabilities
        self.capabilities = capabilities
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
        // The Camera Control's stops come from the lens and format, and a pinch can switch lens without select().
        // The backend skips a reinstall when nothing changed.
        applyCameraControls()
    }

    func cameraBackend(_ backend: CameraBackend, didUpdateReadings readings: LiveReadings) {
        self.readings = readings
        updateStackISOFloor()
        adoptExternalChanges(from: readings)
        if adoptNextWhiteBalanceReading, !readings.isAdjustingWhiteBalance {
            adoptNextWhiteBalanceReading = false
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
        // PHOTO and NIGHT have no focus or white balance control to go back to auto with, so a pick there moves
        // to MANUAL, as a shutter or ISO pick does.
        let leavesAutoMode = settings.mode == .photo || settings.mode == .night
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
                let tint = settings.whiteBalance.tintValue
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
        case .mode(let mode): setMode(mode)
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
        }
    }

    func cameraBackend(_ backend: CameraBackend, controlsFullscreenDidChange isFullscreen: Bool) {
        controlsFullscreen = isFullscreen
    }
}
