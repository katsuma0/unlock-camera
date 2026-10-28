import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import UIKit
import CameraCore

/// The real camera: AVCaptureSession on physical lenses, every manual control the hardware exposes.
///
/// Threading: the CameraBackend surface is main actor. Everything that touches AVFoundation runs on the
/// serial `sessionQueue`; members marked `nonisolated(unsafe)` belong to that queue and nothing else reads
/// them. Frames arrive on `videoQueue`, which shares only the stack engine reference (behind `engineLock`)
/// and the thread-safe frame analyzer. Results go back to the delegate on the main queue.
final class CameraService: NSObject, CameraBackend, @unchecked Sendable {
    @MainActor weak var delegate: CameraBackendDelegate?
    let isSimulated = false
    @MainActor private(set) var lenses: [LensInfo] = []
    @MainActor private(set) var lensPresets: [LensPreset] = []
    @MainActor private(set) var activeLensID: String?

    // MARK: - Main actor state

    @MainActor private let previewLayer: AVCaptureVideoPreviewLayer
    @MainActor private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @MainActor private var rotationObservations: [NSKeyValueObservation] = []
    /// Degrees that level photos, movies and stacks, kept current by the rotation coordinator.
    @MainActor private var captureRotationAngle: CGFloat = 90
    @MainActor private var previewRotationAngle: CGFloat = 90
    /// DeviceOptions and PhotoRequest don't carry this preference, so the value from `start` is used.
    @MainActor private var mirrorFrontPhotos = true
    @MainActor private var publishedCapabilities: CameraCapabilities?
    @MainActor private var publishedState: SessionState?
    @MainActor private var stackInFlight = false
    @MainActor private var recordingActive = false
    @MainActor private var recordingWaiter: CheckedContinuation<CaptureResult, Error>?
    @MainActor private var recordingStops = 0
    /// Tells the recording in progress apart from an earlier one that finishes late, after its stop timed out.
    @MainActor private var recordingGeneration = 0
    /// A recording that ended before stopRecording asked for it (error, interruption, full disk).
    @MainActor private var finishedRecording: Result<CaptureResult, Error>?
    /// White balance requests sent so far. Readings measured before the latest one reached the camera are about
    /// to change, and the gray card button adopts the first reading that isn't adjusting.
    @MainActor private var whiteBalanceRequestsSent = 0
    /// Held from the start of a stack until its result is back, so a merge or save under way when the person
    /// leaves the app gets to finish.
    @MainActor private var stackBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// A stack merge put off until the app is active again: Metal work is refused to a background app.
    @MainActor private var mergeWaitingForActive: (@MainActor () -> Void)?

    // MARK: - Session queue state

    nonisolated let session: AVCaptureSession
    nonisolated let sessionQueue = DispatchQueue(label: "ca.katsuma.openshutter.session", qos: .userInitiated)
    nonisolated let videoQueue = DispatchQueue(label: "ca.katsuma.openshutter.video", qos: .userInitiated)
    nonisolated let renderQueue = DispatchQueue(label: "ca.katsuma.openshutter.render", qos: .userInitiated)
    nonisolated let metadataQueue = DispatchQueue(label: "ca.katsuma.openshutter.metadata", qos: .utility)
    nonisolated let photoOutput = AVCapturePhotoOutput()
    nonisolated let videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated let recorder = MovieRecorder()
    nonisolated let analyzer = FrameAnalyzer()
    nonisolated let controlsBridge: CameraControlBridge

    nonisolated(unsafe) var catalog: DeviceCatalog?
    nonisolated(unsafe) var activeCamera: DeviceCatalog.Camera?
    nonisolated(unsafe) var videoInput: AVCaptureDeviceInput?
    nonisolated(unsafe) var audioInput: AVCaptureDeviceInput?
    /// Only in the session while iOS 27 subject tracking is on: tracking needs a subscriber to run.
    nonisolated(unsafe) var metadataOutput: AVCaptureMetadataOutput?
    nonisolated(unsafe) var topology: Topology = .photo
    nonisolated(unsafe) var sessionCapabilities: CameraCapabilities = .placeholder

    /// The last request of each kind, re-applied after every lens or format change.
    nonisolated(unsafe) var exposureRequest: ExposureRequest = .auto
    nonisolated(unsafe) var focusRequest: FocusRequest = .continuousAuto
    nonisolated(unsafe) var whiteBalanceRequest: WhiteBalanceRequest = .auto
    nonisolated(unsafe) var deviceOptions: DeviceOptions?
    nonisolated(unsafe) var torchLevel: Double?
    nonisolated(unsafe) var zoomTarget: Double = 1

    nonisolated(unsafe) var softwareAETimer: DispatchSourceTimer?
    nonisolated(unsafe) var softwareAELocks: ExposureLocks?
    nonisolated(unsafe) var softwareAENextStep: CFTimeInterval = 0
    /// Set while the request goes back on after a stack: the exposure from before it. The stack's own frame can be
    /// stops darker, and a loop that started from there would take many long frames to climb back.
    nonisolated(unsafe) var softwareAEStart: ExposureValues?
    /// What the end of a stack asked the device to expose, until it is in effect. Meanwhile the device still reports
    /// the stack's own frame, and a stack started right away has to go back to this instead.
    nonisolated(unsafe) var restoreTarget: ExposureValues?
    /// Counts the commands that replace the exposure, so a completion handler can tell whether its exposure is still
    /// the latest one asked for.
    nonisolated(unsafe) var exposureGeneration = 0
    nonisolated(unsafe) var autoExposureLimitSet = false
    /// The request bias last written to the device. The Camera Control's system exposure slider moves the
    /// device's bias directly, so a request that leaves the bias unchanged leaves the device alone too.
    nonisolated(unsafe) var appliedBiasRequest: Double?
    /// The zoom target last sent to the device, for the same reason with the system zoom slider.
    nonisolated(unsafe) var appliedZoomTarget: Double?
    /// The exposure point moved (a tap, or a new device or format resetting it); an AE lock right after that
    /// meters once at the point before it holds.
    nonisolated(unsafe) var meteringPointPending = false
    /// The exposure point of interest last asked for, which a spot centres on. Kept here because a rect moves the
    /// device's own point to the rect's centre.
    nonisolated(unsafe) var meteringPoint = CGPoint(x: 0.5, y: 0.5)
    /// The exposure rect of interest last set for the metering area; nil while the camera keeps its own. A new point
    /// of interest, device or format puts the camera's own back.
    nonisolated(unsafe) var appliedMeteringRect: CGRect?
    /// A white balance lock is still being applied; readings report "adjusting" until it lands.
    nonisolated(unsafe) var whiteBalanceLockPending = false
    /// Tells a landing lock apart from the ones that replaced it.
    nonisolated(unsafe) var whiteBalanceLockGeneration = 0
    /// Set while a long custom exposure has stretched the frame duration: the longest frame, in seconds, the
    /// format had before. Exposures that fit in it again bring the format's own frame durations back.
    nonisolated(unsafe) var frameDurationRestoreLimit: Double?
    /// Exposure, focus, white balance and zoom belong to the stack while it runs.
    nonisolated(unsafe) var stackInProgress = false

    nonisolated(unsafe) private var isConfigured = false
    nonisolated(unsafe) private var wantsRunning = false
    nonisolated(unsafe) private var interruptionMessage: String?
    nonisolated(unsafe) private var throttledForPressure = false
    nonisolated(unsafe) private var videoFrameDuration: CMTime?
    /// The format video mode set up, for capabilities. nil in photo mode, and while no format could be set.
    nonisolated(unsafe) private var activeVideo: ActiveVideoFormat?
    /// Lens, format, frame rate and color mode of the video format set up, the things the hardware budget can
    /// depend on. nil whenever `activeVideo` is.
    nonisolated(unsafe) private var videoBudgetKey: String?
    /// Video formats, keyed like `videoBudgetKey`, where the movie output and the video data output together went
    /// over the hardware budget. That never changes for a format, so each one stops the session only once.
    nonisolated(unsafe) private var videoDataOverBudget: Set<String> = []
    nonisolated(unsafe) private var formatCache: [String: [FormatDescriptor]] = [:]
    nonisolated(unsafe) private var bayerRAWSupport: [String: Bool] = [:]
    /// Each lens's capabilities as last built with the photo output in the session. Video mode takes the output
    /// out, and Settings should still show what the camera can do for photos.
    nonisolated(unsafe) private var photoModeCapabilities: [String: CameraCapabilities] = [:]
    /// How many white balance requests the session queue has taken (see `whiteBalanceRequestsSent`).
    nonisolated(unsafe) private var whiteBalanceRequestsApplied = 0
    nonisolated(unsafe) private var lastRuntimeRestart: CFTimeInterval?
    nonisolated(unsafe) private var readingsTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var lastReadings: LiveReadings?
    nonisolated(unsafe) private var recordingTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var stackJob: StackJob?
    nonisolated(unsafe) private var photoCoordinators: [Int64: PhotoCaptureCoordinator] = [:]
    nonisolated(unsafe) private var sessionObservers: [NSObjectProtocol] = []
    /// Set once in init.
    nonisolated(unsafe) private var appActiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var pressureObservation: NSKeyValueObservation?
    /// Some analysis option is on; otherwise only a stack needs frames from the video data output.
    nonisolated(unsafe) private var analysisWantsFrames = true
    nonisolated(unsafe) private var cameraControlState: CameraControlState?
    nonisolated(unsafe) private var installedControls: (state: CameraControlState, deviceID: String)?

    // MARK: - Shared with the video queue

    nonisolated private let engineLock = NSLock()
    nonisolated(unsafe) private var activeEngine: StackedCaptureEngine?
    nonisolated(unsafe) private var engineFinishSignaled = false
    /// The stack whose frames are being merged and saved, still within reach of Discard.
    nonisolated(unsafe) private var mergingEngine: StackedCaptureEngine?
    nonisolated private let analysisLock = NSLock()
    nonisolated(unsafe) private var pendingAnalysis: AnalysisFrame?

    /// What the session is set up for. Video keeps the settings so a lens switch can pick the same format.
    enum Topology {
        case photo
        case video(VideoSettings)
    }

    override init() {
        let session = AVCaptureSession()
        self.session = session
        controlsBridge = CameraControlBridge(queue: DispatchQueue(label: "ca.katsuma.openshutter.controls", qos: .userInitiated))
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        // The UI shows the whole 3:4 sensor like the Camera app and draws aspect masks itself.
        previewLayer.videoGravity = .resizeAspect
        controlsBridge.onChange = { [weak self] change in
            DispatchQueue.main.async {
                guard let self else { return }
                self.delegate?.cameraBackend(self, didReceiveControl: change)
            }
        }
        controlsBridge.onFullscreenChange = { [weak self] isFullscreen in
            DispatchQueue.main.async {
                guard let self else { return }
                self.delegate?.cameraBackend(self, controlsFullscreenDidChange: isFullscreen)
            }
        }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let merge = self.mergeWaitingForActive else { return }
                self.mergeWaitingForActive = nil
                merge()
            }
        }
    }

    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
        }
        readingsTimer?.cancel()
        softwareAETimer?.cancel()
        recordingTimer?.cancel()
        stackJob?.watchdog?.cancel()
    }

    // MARK: - Authorization

    @MainActor func authorizationStatus() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    @MainActor func requestAuthorization() async -> CameraAuthorization {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        return authorizationStatus()
    }

    // MARK: - Lifecycle

    @MainActor func start(settings: CameraSettings) async {
        mirrorFrontPhotos = settings.capture.mirrorFront
        // A cold start in video mode builds the video session right away. Asking for the microphone waits for
        // configureForVideo, which adds it once allowed.
        let audio = settings.mode == .video && settings.video.audio
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.startSession(settings: settings, audio: audio) { done.resume() }
            }
        }
    }

    @MainActor func stop() {
        sessionQueue.async {
            self.stopSession()
        }
    }

    @MainActor func makePreviewLayer() -> CALayer {
        previewLayer
    }

    @MainActor func devicePoint(fromLayerPoint point: CGPoint) -> CGPoint? {
        guard previewLayer.connection != nil, previewLayer.bounds.width > 0, previewLayer.bounds.height > 0 else { return nil }
        let converted = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        guard converted.x.isFinite, converted.y.isFinite else { return nil }
        // A tap on the letterbox beside the image has no device point.
        let margin: CGFloat = 0.02
        guard converted.x >= -margin, converted.x <= 1 + margin, converted.y >= -margin, converted.y <= 1 + margin else { return nil }
        return CGPoint(x: min(max(converted.x, 0), 1), y: min(max(converted.y, 0), 1))
    }

    @MainActor func layerPoint(fromDevicePoint point: CGPoint) -> CGPoint? {
        guard previewLayer.connection != nil, point.x.isFinite, point.y.isFinite else { return nil }
        let converted = previewLayer.layerPointConverted(fromCaptureDevicePoint: point)
        guard converted.x.isFinite, converted.y.isFinite else { return nil }
        return converted
    }

    // MARK: - Lens and zoom

    @MainActor func select(_ preset: LensPreset) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.selectOnSession(preset) { done.resume() }
            }
        }
    }

    @MainActor func setZoomFactor(_ factor: Double, animated: Bool) {
        sessionQueue.async {
            self.zoomTarget = factor
            self.applyZoom(animated: animated)
        }
    }

    // MARK: - Requests

    @MainActor func apply(exposure: ExposureRequest) {
        sessionQueue.async {
            self.exposureRequest = exposure
            self.applyExposure()
        }
    }

    @MainActor func apply(focus: FocusRequest) {
        sessionQueue.async {
            self.focusRequest = focus
            self.applyFocus()
        }
    }

    @MainActor func apply(whiteBalance: WhiteBalanceRequest) {
        whiteBalanceRequestsSent &+= 1
        let sequence = whiteBalanceRequestsSent
        sessionQueue.async {
            self.whiteBalanceRequestsApplied = sequence
            self.whiteBalanceRequest = whiteBalance
            self.applyWhiteBalance()
            // The next poll publishes even if nothing moved, so the readings that flagged the change as pending
            // are always followed by ones that don't.
            self.lastReadings = nil
        }
    }

    @MainActor func apply(options: DeviceOptions) {
        mirrorFrontPhotos = options.mirrorFront
        sessionQueue.async {
            let meteringChanged = self.deviceOptions?.meteringArea != options.meteringArea
            self.deviceOptions = options
            guard self.activeCamera != nil else { return }
            self.applyDeviceOptions()
            // The rect only counts once the exposure mode is set again, and only the exposure path knows which one.
            if meteringChanged {
                self.applyExposure()
            }
            self.refreshCapabilities()
            self.publishSnapshot()
        }
    }

    @MainActor func setPointOfInterest(_ devicePoint: CGPoint, focus: Bool, exposure: Bool) {
        sessionQueue.async {
            self.applyPointOfInterest(devicePoint, focus: focus, exposure: exposure)
        }
    }

    @MainActor func setTorch(level: Double?) {
        sessionQueue.async {
            self.torchLevel = level
            self.applyTorch()
        }
    }

    @MainActor func setAnalysis(_ options: AnalysisOptions) {
        analyzer.setOptions(options)
        let wantsFrames = !options.isOff
        sessionQueue.async {
            self.analysisWantsFrames = wantsFrames
            self.updateFrameDelivery()
        }
    }

    // MARK: - Capture

    @MainActor func capturePhoto(_ request: PhotoRequest) async throws -> [CaptureResult] {
        guard !stackInFlight else { throw CameraError.busy }
        let angle = captureRotationAngle
        let mirrorFront = mirrorFrontPhotos
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CaptureResult], Error>) in
            sessionQueue.async {
                self.beginPhotoCapture(request, rotationAngle: angle, mirrorFront: mirrorFront) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    @MainActor func captureStack(_ request: StackRequest, progress: @escaping @MainActor (StackProgress) -> Void) async throws -> CaptureResult {
        guard !stackInFlight else { throw CameraError.busy }
        // Cancelled before anything was exposed: there is nothing to keep.
        guard !Task.isCancelled else { throw CameraError.cancelled }
        stackInFlight = true
        beginStackBackgroundTask()
        defer {
            stackInFlight = false
            endStackBackgroundTask()
        }
        let isFront = lenses.first { $0.id == activeLensID }?.isFront ?? false
        let orientation = StackOrientation(
            output: Self.imageOrientation(rotationAngle: captureRotationAngle, mirrored: isFront && mirrorFrontPhotos),
            previewRotation: Double(previewRotationAngle),
            previewMirrored: previewLayer.connection?.isVideoMirrored ?? isFront
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CaptureResult, Error>) in
                sessionQueue.async {
                    self.beginStack(request, orientation: orientation, progress: progress) { result in
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            // The model cancels its capture task for Stop as well as for Discard, and says which one it means
            // through finishStackEarly or cancelStack. Ending early keeps the frames for Stop; Discard's
            // cancelStack follows at once and still throws them away.
            self.sessionQueue.async { self.requestStackFinish() }
        }
    }

    @MainActor func finishStackEarly() {
        sessionQueue.async {
            self.requestStackFinish()
        }
    }

    @MainActor func cancelStack() {
        cancelStackNow()
    }

    @MainActor private func beginStackBackgroundTask() {
        guard stackBackgroundTask == .invalid else { return }
        stackBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish stack") { [weak self] in
            // Out of time: iOS ends an app that holds on. The frames stay in memory for when the app comes back.
            self?.endStackBackgroundTask()
        }
    }

    @MainActor private func endStackBackgroundTask() {
        guard stackBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(stackBackgroundTask)
        stackBackgroundTask = .invalid
    }

    // MARK: - Video

    @MainActor func configureForVideo(_ settings: VideoSettings) async {
        var audio = false
        if settings.audio {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                audio = true
            case .notDetermined:
                audio = await AVCaptureDevice.requestAccess(for: .audio)
            default:
                audio = false
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.configureVideoSession(settings, audio: audio) { done.resume() }
            }
        }
    }

    @MainActor func configureForPhoto() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.configurePhotoSession { done.resume() }
            }
        }
    }

    @MainActor func startRecording(_ request: VideoRequest) async throws {
        guard !recordingActive, recordingWaiter == nil else { throw CameraError.busy }
        finishedRecording = nil
        recordingActive = true
        recordingGeneration &+= 1
        let generation = recordingGeneration
        let angle = captureRotationAngle
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    do {
                        try self.beginRecording(request, rotationAngle: angle, generation: generation)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            recordingActive = false
            // A stop tapped while the start was failing has no movie to wait for. The start's own error is the one
            // the person sees, so the stop ends quietly instead of waiting out its timeout.
            if let waiter = recordingWaiter {
                recordingWaiter = nil
                waiter.resume(throwing: CameraError.cancelled)
            }
            throw error
        }
    }

    @MainActor func stopRecording() async throws -> CaptureResult {
        if let finished = finishedRecording {
            finishedRecording = nil
            return try finished.get()
        }
        guard recordingActive else { throw CameraError.captureFailed("Nothing is recording.") }
        guard recordingWaiter == nil else { throw CameraError.busy }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CaptureResult, Error>) in
            recordingWaiter = continuation
            recordingStops &+= 1
            let stop = recordingStops
            sessionQueue.async {
                self.recorder.stop()
                // The length is final now; a tick still on its way would land after the model reset its counter.
                self.stopRecordingTimer()
            }
            // Saving a long movie moves one file; a minute without an answer means the recorder lost track of it.
            // The count keeps this from failing a later recording that happens to be saving at that moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.recordingStops == stop, let waiter = self.recordingWaiter else { return }
                self.recordingWaiter = nil
                self.recordingActive = false
                waiter.resume(throwing: CameraError.saveFailed("The movie didn't finish writing."))
            }
        }
    }

    // MARK: - Camera Control

    @MainActor func configureCameraControls(_ state: CameraControlState) {
        sessionQueue.async {
            self.cameraControlState = state
            self.installCameraControls()
        }
    }
}

// MARK: - Session setup

extension CameraService {
    nonisolated private func startSession(settings: CameraSettings, audio: Bool, completion: @escaping @MainActor () -> Void) {
        wantsRunning = true
        if catalog == nil {
            catalog = DeviceCatalog.discover()
        }
        guard let catalog, let fallback = catalog.defaultCamera else {
            publishSnapshot(state: .failed(CameraError.noCamera.errorDescription ?? "No camera found."), forceState: true, then: completion)
            return
        }
        if !isConfigured {
            let camera = catalog.camera(id: settings.lensID) ?? fallback
            zoomTarget = camera.lens.id == settings.lensID ? settings.zoom : 1
            guard configureSession(with: camera) else {
                publishSnapshot(state: .failed("Couldn't open \(camera.lens.name)."), forceState: true, then: completion)
                return
            }
            isConfigured = true
            // ProRAW, Live Photo and depth rebuild the render pipeline; before the session runs that costs nothing.
            // The model sends the same options again once start returns, which then changes nothing.
            if deviceOptions == nil {
                deviceOptions = DeviceOptions(settings: settings)
            }
            refreshCapabilities()
            applyDeviceOptions()
            if settings.mode == .video {
                // Read while the photo output is still in, so Settings can describe photos from video mode.
                refreshCapabilities()
                // Built before the session runs, so the photo pipeline is never started only to be torn down.
                applyVideoTopology(settings.video, audio: audio)
            }
        }
        observeSessionIfNeeded()
        if !session.isRunning {
            session.startRunning()
        }
        startReadings()
        refreshCapabilities()
        publishSnapshot(state: currentState(), forceState: true, then: completion)
    }

    /// First-time topology: the camera, the photo output and the video data output, with the `.photo` preset
    /// choosing the full-sensor format. Device settings come from the requests that follow.
    nonisolated private func configureSession(with camera: DeviceCatalog.Camera) -> Bool {
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        guard addVideoInput(camera.device) else {
            session.commitConfiguration()
            return false
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        attachVideoDataOutput()
        selectVideoPixelFormat()
        configureVideoDataConnection()
        session.commitConfiguration()
        activeCamera = camera
        observeDevice(camera.device)
        applyZoom(animated: false)
        return true
    }

    /// Inside begin/commitConfiguration. Photo mode always wants it, for stacks; video mode goes through
    /// `attachVideoDataOutputWithinBudget`, which leaves it out where it would go over the hardware budget.
    nonisolated private func attachVideoDataOutput() {
        guard !session.outputs.contains(videoDataOutput) else { return }
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoDataOutput) else { return }
        session.addOutput(videoDataOutput)
        // Preview-sized frames keep the histogram and overlays cheap; stacks ask for full size.
        videoDataOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoDataOutput.deliversPreviewSizedOutputBuffers = true
    }

    nonisolated private func addVideoInput(_ device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            // Video mode sets formats directly; this keeps auto exposure defaults the same as with the preset.
            input.unifiedAutoExposureDefaultsEnabled = true
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            videoInput = input
            return true
        } catch {
            return false
        }
    }

    nonisolated private func stopSession() {
        wantsRunning = false
        if let job = stackJob {
            // Leaving the app ends a stack the way an interruption does: the frames so far are kept, and merged once
            // the app is back.
            if let engine = job.engine, job.phase == .collecting {
                engine.finishEarly()
                finishStack(job)
            } else if job.phase == .settingExposure {
                endStack(job, result: .failure(CameraError.cancelled))
            }
        }
        if recorder.isRecording {
            recorder.stop()
        }
        stopReadings()
        stopSoftwareAE()
        stopRecordingTimer()
        if session.isRunning {
            session.stopRunning()
        }
        interruptionMessage = nil
        publishSnapshot(state: .idle, forceState: true)
    }

    nonisolated private func currentState() -> SessionState {
        if session.isInterrupted || interruptionMessage != nil {
            return .interrupted(interruptionMessage ?? Self.interruptionText(code: nil))
        }
        return session.isRunning ? .running : .failed("The camera didn't start.")
    }

    /// Frames stay in sensor orientation and unmirrored: rotating buffers in the pipeline is expensive, and the
    /// analyzer and the stack engine turn their own small outputs instead.
    nonisolated private func configureVideoDataConnection() {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(0), connection.videoRotationAngle != 0 {
            connection.videoRotationAngle = 0
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        // A connection made for a new input starts out enabled.
        updateFrameDelivery()
    }

    /// With every analysis off and no stack running nothing reads the frames, and scaling one for each preview
    /// frame (up to 240 a second in video) costs memory bandwidth and wakeups for nothing.
    nonisolated private func updateFrameDelivery() {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        let wanted = analysisWantsFrames || stackJob != nil
        if connection.isEnabled != wanted {
            connection.isEnabled = wanted
        }
    }

    /// Full-range 4:2:0 is what the analyzer and the stack engine read fastest; BGRA is the fallback both handle.
    nonisolated private func selectVideoPixelFormat() {
        let available = videoDataOutput.availableVideoPixelFormatTypes
        let preferred: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ]
        guard let format = preferred.first(where: { available.contains($0) }) else { return }
        let key = kCVPixelBufferPixelFormatTypeKey as String
        let current = (videoDataOutput.videoSettings?[key] as? NSNumber)?.uint32Value
        guard current != format else { return }
        videoDataOutput.videoSettings = [key: NSNumber(value: format)]
    }

    /// Stacks want every pixel of the sensor format; the viewfinder analysis only needs preview size.
    /// Changing it rebuilds the pipeline, so it only happens at the start and end of a stack.
    nonisolated private func setFullResolutionFrames(_ full: Bool) {
        guard session.outputs.contains(videoDataOutput), videoDataOutput.deliversPreviewSizedOutputBuffers == full else { return }
        session.beginConfiguration()
        videoDataOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoDataOutput.deliversPreviewSizedOutputBuffers = !full
        session.commitConfiguration()
    }

    // MARK: Lens switching

    nonisolated private func selectOnSession(_ preset: LensPreset, completion: @escaping @MainActor () -> Void) {
        guard let camera = catalog?.camera(id: preset.lensID) else {
            publishSnapshot(then: completion)
            return
        }
        if camera.lens.id == activeCamera?.lens.id {
            zoomTarget = preset.zoomFactor
            applyZoom(animated: true)
        } else if stackJob == nil, !recorder.isRecording {
            switchCamera(to: camera, zoomFactor: preset.zoomFactor)
        }
        publishSnapshot(then: completion)
    }

    /// Swaps the session input to another physical camera and carries every setting over to it.
    nonisolated private func switchCamera(to camera: DeviceCatalog.Camera, zoomFactor: Double) {
        stopSoftwareAE()
        let wasRunning = session.isRunning
        session.beginConfiguration()
        clearFocusTrackingTypes()
        let previous = videoInput
        if let previous {
            session.removeInput(previous)
        }
        if addVideoInput(camera.device) {
            activeCamera = camera
            // The factor belongs to the new lens, so it only becomes the target once the switch has happened.
            zoomTarget = zoomFactor
        } else if let previous, session.canAddInput(previous) {
            // The new camera refused; put the old one back rather than leave the session empty.
            session.addInput(previous)
            videoInput = previous
        }
        if case .video(let settings) = topology, let device = activeCamera?.device {
            applyVideoFormat(settings, device: device)
            attachVideoDataOutputWithinBudget()
        } else {
            if session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            }
            attachVideoDataOutput()
        }
        selectVideoPixelFormat()
        configureVideoDataConnection()
        session.commitConfiguration()
        if let device = activeCamera?.device {
            observeDevice(device)
        }
        if case .video(let settings) = topology {
            fitHardwareBudget(wasRunning: wasRunning)
            recorder.configureConnection(for: settings)
        }
        reapplyDeviceState()
    }

    /// Format and device changes reset exposure limits, points of interest, tone mapping and more, and
    /// ranges differ per lens, so every request is applied again against the new hardware.
    nonisolated private func reapplyDeviceState() {
        autoExposureLimitSet = false
        appliedBiasRequest = nil
        // A new camera hasn't metered yet, so an AE lock carried over meters once before it holds.
        meteringPointPending = true
        // The middle after a new device or format; a reconfiguration that kept the format kept the point too.
        if let point = activeCamera?.device.exposurePointOfInterest, point.x.isFinite, point.y.isFinite {
            meteringPoint = point
        }
        appliedMeteringRect = nil
        whiteBalanceLockGeneration &+= 1
        whiteBalanceLockPending = false
        lastReadings = nil
        refreshCapabilities()
        applyDeviceOptions()
        // Frame limits first: a long manual shutter applied after them stretches the frames it needs, while
        // limits applied after it would cut it short.
        applyFrameRateLimits()
        applyExposure()
        applyFocus()
        applyWhiteBalance()
        applyTorch()
        applyZoom(animated: false)
        installedControls = nil
        installCameraControls()
        refreshCapabilities()
    }

    // MARK: Capabilities and publishing

    @discardableResult
    nonisolated func refreshCapabilities() -> CameraCapabilities {
        guard let camera = activeCamera else { return sessionCapabilities }
        let device = camera.device
        let id = camera.lens.id
        let formats: [FormatDescriptor]
        if let cached = formatCache[id] {
            formats = cached
        } else {
            formats = CapabilitiesBuilder.descriptors(for: device)
            formatCache[id] = formats
        }
        let photo = session.outputs.contains(photoOutput) ? photoOutput : nil
        if let photo, !photo.isAppleProRAWEnabled {
            bayerRAWSupport[id] = CapabilitiesBuilder.bayerRAWSupported(photo, hint: nil)
        }
        let movie = session.outputs.contains(recorder.output) ? recorder.output : nil
        var capabilities = CapabilitiesBuilder.build(
            device: device, lens: camera.lens, formats: formats,
            photoOutput: photo, movieOutput: movie, bayerRAWHint: bayerRAWSupport[id]
        )
        if photo != nil {
            photoModeCapabilities[id] = capabilities
        } else if let photoMode = photoModeCapabilities[id] {
            // Video mode takes the photo output out of the session. Without this, Settings would report HEIF, RAW
            // and Live Photo as missing from a camera that has them; no photo is taken here to act on them.
            capabilities = CapabilitiesBuilder.keepingPhotoFeatures(of: photoMode, in: capabilities)
        }
        capabilities.supportsCameraControls = session.supportsControls
        capabilities.activeVideo = activeVideo
        sessionCapabilities = capabilities
        return sessionCapabilities
    }

    nonisolated func formatDescriptors(for camera: DeviceCatalog.Camera) -> [FormatDescriptor] {
        if let cached = formatCache[camera.lens.id] { return cached }
        let formats = CapabilitiesBuilder.descriptors(for: camera.device)
        formatCache[camera.lens.id] = formats
        return formats
    }

    /// Sends lenses, the active camera, capabilities and optionally a state to the main actor in one step,
    /// so the model never sees capabilities for a lens list it doesn't have yet.
    nonisolated func publishSnapshot(state: SessionState? = nil, forceState: Bool = false, then completion: (@MainActor () -> Void)? = nil) {
        let snapshot = SessionSnapshot(
            lenses: catalog?.lenses ?? [],
            presets: catalog?.presets ?? [],
            camera: activeCamera,
            capabilities: activeCamera == nil ? nil : sessionCapabilities,
            state: state,
            forceState: forceState
        )
        DispatchQueue.main.async {
            self.adopt(snapshot)
            completion?()
        }
    }

    nonisolated func publishState(_ state: SessionState) {
        DispatchQueue.main.async {
            self.deliver(state: state, force: false)
        }
    }

    @MainActor private func adopt(_ snapshot: SessionSnapshot) {
        lenses = snapshot.lenses
        lensPresets = snapshot.presets
        let newID = snapshot.camera?.lens.id
        let cameraChanged = newID != activeLensID || (rotationCoordinator == nil && newID != nil)
        activeLensID = newID
        if cameraChanged, let device = snapshot.camera?.device {
            installRotationCoordinator(for: device)
        } else {
            // The preview connection can come back mirrored or rotated after a reconfiguration.
            applyPreviewRotation(previewRotationAngle)
        }
        if let capabilities = snapshot.capabilities, capabilities != publishedCapabilities {
            publishedCapabilities = capabilities
            delegate?.cameraBackend(self, didUpdateCapabilities: capabilities)
        }
        if let state = snapshot.state {
            deliver(state: state, force: snapshot.forceState)
        }
    }

    @MainActor private func deliver(state: SessionState, force: Bool) {
        guard force || state != publishedState else { return }
        publishedState = state
        delegate?.cameraBackend(self, didChangeState: state)
    }

    // MARK: Rotation

    @MainActor private func installRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservations.forEach { $0.invalidate() }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        // The coordinator reports on the main queue; the hop below only matters if that ever changes.
        let preview = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Self.onMain { self?.applyPreviewRotation(angle) }
        }
        let capture = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Self.onMain { self?.captureRotationAngle = angle }
        }
        rotationObservations = [preview, capture]
    }

    @MainActor private func applyPreviewRotation(_ angle: CGFloat) {
        previewRotationAngle = angle
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
        // Video data frames stay at 0 degrees, so the preview angle is exactly the overlay's rotation.
        analyzer.setPreviewTransform(rotationDegrees: Double(angle), mirrored: connection.isVideoMirrored)
    }

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    /// EXIF-style orientation that turns a sensor-oriented frame upright, mirrored for selfies when asked.
    nonisolated static func imageOrientation(rotationAngle: CGFloat, mirrored: Bool) -> CGImagePropertyOrientation {
        let degrees = Double(rotationAngle)
        let quarterTurns = degrees.isFinite ? ((Int((degrees / 90).rounded()) % 4) + 4) % 4 : 1
        switch (quarterTurns, mirrored) {
        case (0, false): return .up
        case (1, false): return .right
        case (2, false): return .down
        case (3, false): return .left
        case (0, true): return .upMirrored
        case (1, true): return .leftMirrored
        case (2, true): return .downMirrored
        default: return .rightMirrored
        }
    }
}

// MARK: - Readings

extension CameraService {
    nonisolated private func startReadings() {
        guard readingsTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.pollReadings()
        }
        timer.resume()
        readingsTimer = timer
    }

    nonisolated private func stopReadings() {
        readingsTimer?.cancel()
        readingsTimer = nil
        lastReadings = nil
    }

    nonisolated private func pollReadings() {
        guard let camera = activeCamera, session.isRunning, !session.isInterrupted else { return }
        let device = camera.device
        let previous = lastReadings ?? .initial
        let maxGain = max(1, device.maxWhiteBalanceGain)
        let gains = Self.clamped(device.deviceWhiteBalanceGains, maxGain: maxGain)
        // Gains outside 1...maxWhiteBalanceGain make this conversion raise, hence the clamp above.
        let temperatureAndTint = device.temperatureAndTintValues(for: gains)
        let zoom = Double(device.videoZoomFactor)
        let readings = LiveReadings(
            exposureSeconds: Self.finite(device.exposureDuration.seconds, positive: true) ?? previous.exposureSeconds,
            iso: Self.finite(Double(device.iso), positive: true) ?? previous.iso,
            aperture: Self.finite(Double(device.lensAperture), positive: true) ?? previous.aperture,
            bias: Self.finite(Double(device.exposureTargetBias)) ?? previous.bias,
            meterOffset: Self.finite(Double(device.exposureTargetOffset)) ?? previous.meterOffset,
            lensPosition: Self.finite(Double(device.lensPosition)) ?? previous.lensPosition,
            kelvin: Self.finite(Double(temperatureAndTint.temperature), positive: true) ?? previous.kelvin,
            tint: Self.finite(Double(temperatureAndTint.tint)) ?? previous.tint,
            zoomFactor: Self.finite(zoom, positive: true) ?? previous.zoomFactor,
            displayZoom: (Self.finite(zoom, positive: true) ?? previous.zoomFactor) * camera.lens.relativeZoom,
            isAdjustingFocus: device.isAdjustingFocus,
            isAdjustingExposure: device.isAdjustingExposure,
            isAdjustingWhiteBalance: device.isAdjustingWhiteBalance || whiteBalanceLockPending,
            pressure: Self.pressureLevel(device.systemPressureState.level),
            lensSmudged: Self.isSmudged(device)
        )
        guard Self.changedMeaningfully(from: lastReadings, to: readings) else { return }
        lastReadings = readings
        let whiteBalanceSequence = whiteBalanceRequestsApplied
        DispatchQueue.main.async {
            var delivered = readings
            // Measured before the latest white balance request reached the camera, so the gains are about to change.
            if whiteBalanceSequence != self.whiteBalanceRequestsSent {
                delivered.isAdjustingWhiteBalance = true
            }
            self.delegate?.cameraBackend(self, didUpdateReadings: delivered)
        }
    }

    /// The HUD only needs changes it can show; publishing every 0.1 s jitter would redraw SwiftUI for nothing.
    nonisolated static func changedMeaningfully(from old: LiveReadings?, to new: LiveReadings) -> Bool {
        guard let old else { return true }
        func stops(_ a: Double, _ b: Double) -> Double {
            guard a > 0, b > 0 else { return a == b ? 0 : .infinity }
            return abs(log2(b / a))
        }
        return stops(old.exposureSeconds, new.exposureSeconds) > 1.0 / 24
            || stops(old.iso, new.iso) > 1.0 / 24
            || abs(old.aperture - new.aperture) > 0.01
            || abs(old.bias - new.bias) > 0.01
            || abs(old.meterOffset - new.meterOffset) > 0.04
            || abs(old.lensPosition - new.lensPosition) > 0.002
            || abs(old.kelvin - new.kelvin) > 10
            || abs(old.tint - new.tint) > 0.5
            || abs(old.zoomFactor - new.zoomFactor) > 0.005
            || old.isAdjustingFocus != new.isAdjustingFocus
            || old.isAdjustingExposure != new.isAdjustingExposure
            || old.isAdjustingWhiteBalance != new.isAdjustingWhiteBalance
            || old.pressure != new.pressure
            || old.lensSmudged != new.lensSmudged
    }

    nonisolated static func finite(_ value: Double, positive: Bool = false) -> Double? {
        guard value.isFinite, !positive || value > 0 else { return nil }
        return value
    }

    nonisolated static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains, maxGain: Float) -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ value: Float) -> Float {
            guard value.isFinite else { return 1 }
            return min(max(value, 1), maxGain)
        }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(gains.redGain), greenGain: clamp(gains.greenGain), blueGain: clamp(gains.blueGain))
    }

    nonisolated static func pressureLevel(_ level: AVCaptureDevice.SystemPressureState.Level) -> PressureLevel {
        switch level {
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        case .shutdown: return .shutdown
        default: return .nominal
        }
    }

    nonisolated static func isSmudged(_ device: AVCaptureDevice) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return device.cameraLensSmudgeDetectionStatus == .smudged
        }
        #endif
        return false
    }
}

// MARK: - Interruptions and system pressure

extension CameraService {
    nonisolated private func observeSessionIfNeeded() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let interrupted = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let code = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            self?.sessionQueue.async { self?.sessionWasInterrupted(code: code) }
        }
        let ended = center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { self?.sessionInterruptionEnded() }
        }
        let failed = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let code = error?.code
            let message = error?.localizedDescription
            self?.sessionQueue.async { self?.sessionRuntimeError(code: code, message: message) }
        }
        sessionObservers = [interrupted, ended, failed]
    }

    nonisolated private func observeDevice(_ device: AVCaptureDevice) {
        pressureObservation?.invalidate()
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            self?.sessionQueue.async { self?.systemPressureChanged(level) }
        }
    }

    nonisolated private func sessionWasInterrupted(code: Int?) {
        guard wantsRunning else { return }
        let message = Self.interruptionText(code: code)
        interruptionMessage = message
        stopSoftwareAE()
        if let job = stackJob {
            // A stack can't continue without frames; keep what it has.
            if let engine = job.engine, job.phase == .collecting {
                engine.finishEarly()
                finishStack(job)
            } else if job.phase == .settingExposure {
                endStack(job, result: .failure(CameraError.captureFailed(message)))
            }
        }
        publishState(.interrupted(message))
    }

    nonisolated private func sessionInterruptionEnded() {
        interruptionMessage = nil
        guard wantsRunning else { return }
        if !session.isRunning {
            session.startRunning()
        }
        applyExposure()
        publishState(currentState())
    }

    nonisolated private func sessionRuntimeError(code: AVError.Code?, message: String?) {
        guard wantsRunning else { return }
        // The restart below can come back without the stack's exposure; keep the frames the stack has rather than
        // mix in others.
        if !session.isRunning, let job = stackJob {
            if let engine = job.engine, job.phase == .collecting {
                engine.finishEarly()
                finishStack(job)
            } else if job.phase == .settingExposure {
                endStack(job, result: .failure(CameraError.captureFailed(message ?? "The camera stopped unexpectedly.")))
            }
        }
        // Media services resets are routine (another app crashed the camera daemon); others may clear on
        // restart, which is what a person would try anyway. At most one restart every few seconds, so an error
        // that comes straight back can't keep the camera restarting. A video format found over the hardware budget
        // is the exception: fitHardwareBudget has already taken out the output that cost too much, so the error
        // can't come back, and two such formats in a row mustn't leave the camera stopped.
        let now = CACurrentMediaTime()
        let budgetFitted = code == .sessionHardwareCostOverage && !session.outputs.contains(videoDataOutput)
        if !session.isRunning, budgetFitted || (lastRuntimeRestart.map({ now - $0 > 5 }) ?? true) {
            lastRuntimeRestart = now
            session.startRunning()
            if session.isRunning {
                // A reset camera daemon forgets the device's settings, so every request goes back on.
                reapplyDeviceState()
                publishSnapshot()
            }
        }
        if session.isRunning {
            publishState(currentState())
        } else if code == .mediaServicesWereReset {
            publishState(.failed("The camera restarted. Try again in a moment."))
        } else {
            publishState(.failed(message ?? "The camera stopped unexpectedly."))
        }
    }

    nonisolated private func systemPressureChanged(_ level: AVCaptureDevice.SystemPressureState.Level) {
        let critical = level == .critical || level == .shutdown
        if critical != throttledForPressure {
            throttledForPressure = critical
            applyFrameRateLimits()
            applyExposure()
        }
        let thermalMessage = Self.interruptionText(code: 5)
        if level == .shutdown {
            guard wantsRunning else { return }
            interruptionMessage = thermalMessage
            publishState(.interrupted(thermalMessage))
        } else if interruptionMessage == thermalMessage, !session.isInterrupted {
            // Cooled down without an interruption to end, which would otherwise have cleared the message.
            interruptionMessage = nil
            if wantsRunning {
                publishState(currentState())
            }
        }
    }

    nonisolated static func interruptionText(code: Int?) -> String {
        // Raw values, because the iOS 26 reason can't be named without an availability check.
        switch code {
        case 1: return "The camera pauses while the app is in the background."
        case 2: return "The microphone is busy with a call or another app."
        case 3: return "Another app is using the camera."
        case 4: return "The camera isn't available while another app shares the screen."
        case 5: return "iPhone is too warm. The camera will be back when it cools down."
        case 6: return "The camera paused for sensitive content."
        default: return "The camera was interrupted."
        }
    }

    /// Video runs at its chosen rate; photo modes keep the preset's defaults. Under critical thermal pressure
    /// both drop to 15 fps, the mitigation Apple recommends before the system shuts the camera down.
    /// A running stack keeps its long frames; the limits come back with the exposure when it ends.
    nonisolated func applyFrameRateLimits() {
        guard let device = activeCamera?.device, !stackInProgress, !device.isAutoVideoFrameRateEnabled else { return }
        let format = device.activeFormat
        var minDuration: CMTime = .invalid
        var maxDuration: CMTime = .invalid
        if case .video = topology, let duration = videoFrameDuration {
            minDuration = duration
            maxDuration = duration
        }
        if throttledForPressure, let slow = Self.frameDuration(fps: 15, in: format) {
            if !minDuration.isValid || CMTimeCompare(minDuration, slow) < 0 {
                minDuration = slow
            }
            if maxDuration.isValid, CMTimeCompare(maxDuration, minDuration) < 0 {
                maxDuration = minDuration
            }
        }
        guard Self.isSupported(minDuration, in: format), Self.isSupported(maxDuration, in: format),
              Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        // Grow the maximum first so the minimum never passes it while both change.
        if maxDuration.isValid, CMTimeCompare(maxDuration, device.activeVideoMaxFrameDuration) > 0 {
            device.activeVideoMaxFrameDuration = maxDuration
            device.activeVideoMinFrameDuration = minDuration
        } else {
            device.activeVideoMinFrameDuration = minDuration
            device.activeVideoMaxFrameDuration = maxDuration
        }
        // These replace whatever a long custom exposure stretched the frames to.
        frameDurationRestoreLimit = nil
    }

    /// `.invalid` means "format default", which is always accepted.
    nonisolated static func isSupported(_ duration: CMTime, in format: AVCaptureDevice.Format) -> Bool {
        guard duration.isValid else { return true }
        return format.videoSupportedFrameRateRanges.contains {
            CMTimeCompare(duration, $0.minFrameDuration) >= 0 && CMTimeCompare(duration, $0.maxFrameDuration) <= 0
        }
    }

    /// Frame duration for `fps` inside the format's ranges, NTSC rates as exact 1001-based fractions.
    nonisolated static func frameDuration(fps: Double, in format: AVCaptureDevice.Format) -> CMTime? {
        guard fps.isFinite, fps > 0 else { return nil }
        let ranges = format.videoSupportedFrameRateRanges
        let containing = ranges.first { fps >= $0.minFrameRate - 0.01 && fps <= $0.maxFrameRate + 0.01 }
        let nearest = ranges.min { a, b in
            min(abs(a.minFrameRate - fps), abs(a.maxFrameRate - fps)) < min(abs(b.minFrameRate - fps), abs(b.maxFrameRate - fps))
        }
        guard let range = containing ?? nearest else { return nil }
        let wanted: CMTime
        if abs(fps - fps.rounded()) < 0.001 {
            wanted = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        } else {
            wanted = CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded()))
        }
        return CMTimeMaximum(range.minFrameDuration, CMTimeMinimum(wanted, range.maxFrameDuration))
    }
}

// MARK: - Photos

extension CameraService {
    nonisolated private func beginPhotoCapture(_ request: PhotoRequest, rotationAngle: CGFloat, mirrorFront: Bool,
                                               completion: @escaping @Sendable (Result<[CaptureResult], Error>) -> Void) {
        guard let camera = activeCamera, session.isRunning, !session.isInterrupted else {
            completion(.failure(CameraError.captureFailed("The camera isn't running.")))
            return
        }
        guard stackJob == nil else {
            completion(.failure(CameraError.busy))
            return
        }
        guard session.outputs.contains(photoOutput),
              let connection = photoOutput.connection(with: .video), connection.isEnabled, connection.isActive else {
            completion(.failure(CameraError.captureFailed("The camera isn't ready for photos.")))
            return
        }
        let device = camera.device
        guard !Self.colorSpaceBlocksPhotos(device) else {
            completion(.failure(CameraError.captureFailed("Photos can't be taken while the camera is set to Apple Log.")))
            return
        }
        var request = request
        // Bayer RAW is only defined at zoom 1 (AVFoundation raises otherwise), so a zoomed RAW shot, or one taken
        // mid zoom ramp, keeps the processed photo instead.
        if request.rawFormat == .bayer, abs(device.videoZoomFactor - 1) > 0.001 || device.isRampingVideoZoom
            || abs(connection.videoScaleAndCropFactor - 1) > 0.001 {
            request.rawFormat = .none
            if request.processedFormat == .none {
                request.processedFormat = .heif
            }
        }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = camera.lens.isFront && mirrorFront
        }
        let settings: AVCapturePhotoSettings
        do {
            settings = try PhotoCaptureCoordinator.makeSettings(for: request, output: photoOutput, capabilities: sessionCapabilities)
        } catch {
            completion(.failure(error))
            return
        }
        let id = settings.uniqueID
        let coordinator = PhotoCaptureCoordinator(
            request: request,
            lensName: camera.lens.name,
            focalLength35mm: camera.lens.equivalentFocalLength * Double(device.videoZoomFactor),
            willCapture: { [weak self] in
                guard let self else { return }
                self.delegate?.cameraBackendWillCapture(self)
            },
            completion: { [weak self] result in
                self?.sessionQueue.async { self?.photoCoordinators[id] = nil }
                completion(result)
            }
        )
        photoCoordinators[id] = coordinator
        photoOutput.capturePhoto(with: settings, delegate: coordinator)
    }

    /// AVCapturePhotoOutput refuses to capture while the camera records Apple Log.
    nonisolated static func colorSpaceBlocksPhotos(_ device: AVCaptureDevice) -> Bool {
        if device.activeColorSpace == .appleLog { return true }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return device.activeColorSpace == .appleLog2
        }
        #endif
        return false
    }
}

// MARK: - Stacked exposures

extension CameraService {
    nonisolated private func beginStack(_ request: StackRequest, orientation: StackOrientation,
                                        progress: @escaping @MainActor (StackProgress) -> Void,
                                        completion: @escaping @Sendable (Result<CaptureResult, Error>) -> Void) {
        guard stackJob == nil else {
            completion(.failure(CameraError.busy))
            return
        }
        guard let camera = activeCamera, session.isRunning, !session.isInterrupted, session.outputs.contains(videoDataOutput) else {
            completion(.failure(CameraError.captureFailed("The camera isn't running.")))
            return
        }
        guard case .photo = topology else {
            completion(.failure(CameraError.unsupported("Long exposure in video mode")))
            return
        }
        guard camera.device.isExposureModeSupported(.custom) else {
            completion(.failure(CameraError.unsupported("Long exposure")))
            return
        }
        // A lock still metering once (a long press just before the shutter) has settled on nothing yet, so it meters
        // again after the stack. What the last stack's end asked for may not be in effect yet, and until it is the
        // device reports that stack's frame.
        let lockSettled = exposureRequest.aeLocked && camera.device.exposureMode != .autoExpose && !meteringPointPending
        let job = StackJob(request: request, orientation: orientation, progress: progress, completion: completion,
                           lens: camera.lens, zoomFactor: Double(camera.device.videoZoomFactor),
                           exposureBefore: restoreTarget ?? Self.currentExposure(of: camera.device), wasAELocked: lockSettled)
        stackJob = job
        stackInProgress = true
        stopSoftwareAE()
        updateFrameDelivery()
        setFullResolutionFrames(true)
        holdFocusAndWhiteBalance(camera.device)
        let id = job.id
        let applied = applyStackExposure(request.plan, device: camera.device) { [weak self] syncTime in
            self?.sessionQueue.async { self?.stackExposureReady(id, syncTime: syncTime) }
        }
        guard applied else {
            endStack(job, result: .failure(CameraError.captureFailed("Couldn't set the exposure.")))
            return
        }
        // A completion handler that never fires (the session paused mid-change) must not hang the shutter.
        let patience = max(2, request.plan.frameSeconds * 3 + 1)
        sessionQueue.asyncAfter(deadline: .now() + patience) { [weak self] in
            self?.stackExposureReady(id, syncTime: .invalid)
        }
    }

    /// The device confirmed the stack exposure; frames from `syncTime` on carry it.
    nonisolated private func stackExposureReady(_ id: UUID, syncTime: CMTime) {
        guard let job = stackJob, job.id == id, job.phase == .settingExposure else { return }
        if job.cancelRequested {
            endStack(job, result: .failure(CameraError.cancelled))
            return
        }
        let plan = job.request.plan
        let configuration = StackedCaptureEngine.Configuration(
            plan: plan,
            isBulb: job.request.isBulb,
            startTime: sessionClockTime(fromDeviceTime: syncTime, margin: plan.frameSeconds * 2 + 0.1),
            outputOrientation: job.orientation.output,
            previewRotation: job.orientation.previewRotation,
            previewMirrored: job.orientation.previewMirrored
        )
        let progress = job.progress
        let engine = StackedCaptureEngine(configuration: configuration) { update in
            DispatchQueue.main.async { progress(update) }
        }
        job.engine = engine
        job.phase = .collecting
        let now = CACurrentMediaTime()
        job.collectingSince = now
        // Generous: frames can drop and a bulb can run to its cap, but a stuck pipeline must end eventually.
        job.deadline = now + plan.estimatedDuration() * 2 + 15
        engineLock.withLock {
            activeEngine = engine
            engineFinishSignaled = false
        }
        startStackWatchdog(job)
        DispatchQueue.main.async {
            self.delegate?.cameraBackendWillCapture(self)
        }
    }

    /// The exposure completion time is on the device clock; frame timestamps are on the session's clock.
    /// Without a time (the handler timed out) frames count from a little after now.
    nonisolated private func sessionClockTime(fromDeviceTime time: CMTime, margin: Double) -> CMTime {
        let sessionClock = session.synchronizationClock
        guard time.isValid, time.isNumeric else {
            let now = CMClockGetTime(sessionClock ?? CMClockGetHostTimeClock())
            return CMTimeAdd(now, CMTime(seconds: max(margin, 0), preferredTimescale: 1_000_000_000))
        }
        guard let sessionClock,
              let deviceClock = videoInput?.ports.first(where: { $0.mediaType == .video })?.clock else { return time }
        let converted = CMSyncConvertTime(time, from: deviceClock, to: sessionClock)
        return converted.isValid ? converted : time
    }

    nonisolated private func startStackWatchdog(_ job: StackJob) {
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        let id = job.id
        timer.setEventHandler { [weak self] in
            self?.checkStack(id)
        }
        timer.resume()
        job.watchdog = timer
    }

    /// Catches every way a stack ends without a final frame: stop pressed between long frames, frames that
    /// stopped coming, a session that paused.
    nonisolated private func checkStack(_ id: UUID) {
        guard let job = stackJob, job.id == id, job.phase == .collecting, let engine = job.engine else { return }
        let now = CACurrentMediaTime()
        if job.cancelRequested || engine.isCancelled || engine.isFinished {
            finishStack(job)
            return
        }
        if let asked = job.finishRequestedAt {
            if engine.framesAccumulated > 0 {
                engine.finishEarly()
            }
            // The next frame may be a whole frame time away; after that, stop waiting for it. A stop that came while
            // the exposure was still being set counts from the moment frames could arrive, or a quick bulb press
            // would end with nothing.
            let waitingSince = max(asked, job.collectingSince ?? asked)
            if now - waitingSince > max(1.5, job.request.plan.frameSeconds * 2 + 0.5) {
                engine.finishEarly()
                finishStack(job)
            }
            return
        }
        if !session.isRunning || session.isInterrupted || (job.deadline.map { now > $0 } ?? false) {
            engine.finishEarly()
            finishStack(job)
        }
    }

    /// Video queue: the engine has every frame it needs.
    nonisolated private func stackEngineDidFinish(_ engine: StackedCaptureEngine) {
        let first: Bool = engineLock.withLock {
            guard activeEngine === engine, !engineFinishSignaled else { return false }
            engineFinishSignaled = true
            return true
        }
        guard first else { return }
        sessionQueue.async { [weak self] in
            guard let self, let job = self.stackJob, job.engine === engine else { return }
            self.finishStack(job)
        }
    }

    nonisolated private func requestStackFinish() {
        guard let job = stackJob else { return }
        if job.finishRequestedAt == nil {
            job.finishRequestedAt = CACurrentMediaTime()
        }
        // Stopping before the first frame would leave nothing to save; the watchdog stops it after one frame.
        if let engine = job.engine, engine.framesAccumulated > 0 {
            engine.finishEarly()
        }
    }

    nonisolated func cancelStackNow() {
        engineLock.withLock {
            activeEngine?.cancel()
            // The merge checks for this after rendering, and nothing gets saved.
            mergingEngine?.cancel()
        }
        sessionQueue.async { [weak self] in
            guard let self, let job = self.stackJob else { return }
            job.cancelRequested = true
            switch job.phase {
            case .settingExposure:
                self.endStack(job, result: .failure(CameraError.cancelled))
            case .collecting:
                job.engine?.cancel()
                self.finishStack(job)
            case .finishing:
                break
            }
        }
    }

    nonisolated private func finishStack(_ job: StackJob) {
        guard job.phase == .collecting, let engine = job.engine else { return }
        job.phase = .finishing
        detachStack(job, merging: engine)
        if job.cancelRequested || engine.isCancelled {
            completeMerge(job, engine: engine, result: .failure(CameraError.cancelled))
        } else {
            let frames = engine.framesAccumulated
            let date = Date()
            DispatchQueue.main.async {
                self.mergeWhenActive(job, engine: engine, frames: frames, date: date, earlierFailure: nil)
            }
        }
        // Only now: going back to preview-sized frames rebuilds the pipeline, and the merge needn't wait for that.
        restoreAfterStack(job)
    }

    /// Ends a stack that never collected frames.
    nonisolated private func endStack(_ job: StackJob, result: Result<CaptureResult, Error>) {
        job.phase = .finishing
        detachStack(job, merging: nil)
        restoreAfterStack(job)
        job.complete(result)
    }

    /// Stops routing frames. `merging` is the engine whose frames are about to be merged.
    nonisolated private func detachStack(_ job: StackJob, merging: StackedCaptureEngine?) {
        job.watchdog?.cancel()
        job.watchdog = nil
        engineLock.withLock {
            activeEngine = nil
            engineFinishSignaled = false
            // In the same step, so a discard reaches either the running stack or its merge.
            if let merging {
                mergingEngine = merging
            }
        }
        // Waits out a consume() still running on the video queue, so rendering never overlaps it.
        videoQueue.sync {}
        if stackJob === job {
            stackJob = nil
        }
    }

    /// Gives the camera back to the person's own settings.
    nonisolated private func restoreAfterStack(_ job: StackJob) {
        stackInProgress = false
        setFullResolutionFrames(false)
        updateFrameDelivery()
        // The stack's long frames stretched the frame duration, and pressure changes waited for it to end.
        applyFrameRateLimits()
        // A focus-once request is already where it should be: the stack held the lens where that focus settled.
        // Applying it again would start a new scan.
        if focusRequest != .autoOnce {
            applyFocus()
        }
        applyWhiteBalance()
        // An AE lock goes back to what it held before the stack, which its badge and the next shot's plan still go
        // by. Metering again would follow wherever the camera points now.
        let lockRestored = job.wasAELocked && exposureRequest.aeLocked
            && job.exposureBefore.map { holdExposure($0) } == true
        if !lockRestored {
            // A lock with nothing to go back to meters once rather than hold the stack's own frame exposure.
            meteringPointPending = true
            softwareAEStart = job.exposureBefore
            applyExposure()
            softwareAEStart = nil
        }
        // A zoom asked for during the stack goes on now. Otherwise the zoom stays where it is, which may be where
        // the Camera Control's system zoom slider put it.
        if zoomTarget != appliedZoomTarget {
            applyZoom(animated: false)
        }
    }

    /// A background app gets no GPU time, so the merge waits for the app to be active; the frames stay in memory.
    @MainActor private func mergeWhenActive(_ job: StackJob, engine: StackedCaptureEngine, frames: Int, date: Date,
                                            earlierFailure: Error?) {
        let merge: @MainActor () -> Void = { [weak self] in
            // The task captureStack began may have run out while the app was away, and leaving again mid-merge must
            // still let the merge and the save finish. captureStack ends it once the result is back.
            self?.beginStackBackgroundTask()
            self?.renderQueue.async {
                self?.renderStack(job, engine: engine, frames: frames, date: date, earlierFailure: earlierFailure)
            }
        }
        if UIApplication.shared.applicationState == .active {
            merge()
        } else {
            mergeWaitingForActive = merge
        }
    }

    /// Any queue. After this a discard has nothing left to reach.
    nonisolated private func completeMerge(_ job: StackJob, engine: StackedCaptureEngine,
                                           result: Result<CaptureResult, Error>) {
        engineLock.withLock {
            if mergingEngine === engine {
                mergingEngine = nil
            }
        }
        job.complete(result)
    }

    /// Render queue: merge, encode, save. `date` is when the stack ended, which can be well before a merge put off
    /// while the app was away. `earlierFailure` marks the second try of a merge that failed.
    nonisolated private func renderStack(_ job: StackJob, engine: StackedCaptureEngine, frames: Int, date: Date,
                                         earlierFailure: Error?) {
        let request = job.request
        var captured = request.plan
        // A bulb or an early stop exposed fewer frames than planned; the metadata says what really happened.
        captured.frameCount = max(1, frames)
        let image: CGImage
        do {
            image = try engine.renderFinal(aspect: request.aspect, noiseReduction: request.noiseReduction)
        } catch {
            // A discard during either try means no photo, whatever went wrong on the first one.
            if engine.isCancelled {
                completeMerge(job, engine: engine, result: .failure(CameraError.cancelled))
                return
            }
            // Metal refuses work from an app that went to the background mid-merge. The engine keeps its frames
            // after a failed merge, so it gets one more try with the app in front; the first error says more than
            // a repeat would.
            if earlierFailure == nil {
                DispatchQueue.main.async {
                    self.mergeWhenActive(job, engine: engine, frames: frames, date: date, earlierFailure: error)
                }
                return
            }
            // Frees whatever the failed merge kept.
            engine.cancel()
            completeMerge(job, engine: engine, result: .failure(earlierFailure ?? error))
            return
        }
        let encoded: EncodedImage
        do {
            let metadata = CaptureMetadata(
                exposureSeconds: captured.effectiveExposureSeconds,
                iso: captured.iso,
                aperture: captured.aperture,
                focalLength35mm: job.lens.equivalentFocalLength * job.zoomFactor,
                lensModel: job.lens.name,
                comment: "Stacked \(frames) \u{00D7} \(ShutterSpeed(seconds: captured.frameSeconds).label), \(captured.blend.title)",
                date: date,
                location: request.location
            )
            let format: ProcessedFormat = request.processedFormat == .none ? .heif : request.processedFormat
            encoded = try MediaWriter.encode(image, as: format, quality: request.quality, metadata: metadata)
        } catch {
            completeMerge(job, engine: engine, result: .failure(error))
            return
        }
        // A discard that came during the encode still means no photo.
        guard !engine.isCancelled else {
            completeMerge(job, engine: engine, result: .failure(CameraError.cancelled))
            return
        }
        let thumbnail = encoded.thumbnail ?? MediaWriter.thumbnail(of: image, maxPixelSize: 400)
        let summary = MediaWriter.summary(exposureSeconds: captured.effectiveExposureSeconds, iso: captured.iso, aperture: captured.aperture)
        Task {
            var identifier: String?
            var saved = false
            do {
                identifier = try await PhotoLibrary.savePhoto(primary: encoded.data, primaryType: encoded.typeIdentifier,
                                                              raw: nil, livePhotoMovie: nil, location: request.location)
                saved = true
            } catch {
                // The result still reaches the model, which tells the person the photo wasn't saved.
                saved = false
            }
            self.completeMerge(job, engine: engine, result: .success(CaptureResult(
                kind: .stack, assetIdentifier: identifier, thumbnail: thumbnail,
                summary: summary, date: date, savedToLibrary: saved
            )))
        }
    }
}

// MARK: - Video

extension CameraService {
    nonisolated private func configureVideoSession(_ settings: VideoSettings, audio: Bool, completion: @escaping @MainActor () -> Void) {
        guard activeCamera != nil, !recorder.isRecording, stackJob == nil else {
            publishSnapshot(then: completion)
            return
        }
        applyVideoTopology(settings, audio: audio)
        publishSnapshot(then: completion)
    }

    /// Also runs at a cold start in video mode, before the session first runs.
    nonisolated private func applyVideoTopology(_ settings: VideoSettings, audio: Bool) {
        guard let camera = activeCamera else { return }
        let wasRunning = session.isRunning
        topology = .video(settings)
        session.beginConfiguration()
        clearFocusTrackingTypes()
        // The photo output limits which formats can stream at full rate, and Apple Log can't take photos.
        if session.outputs.contains(photoOutput) {
            session.removeOutput(photoOutput)
        }
        applyVideoFormat(settings, device: camera.device)
        attachVideoDataOutputWithinBudget()
        if !session.outputs.contains(recorder.output), session.canAddOutput(recorder.output) {
            session.addOutput(recorder.output)
        }
        setAudioInput(enabled: audio, windNoiseReduction: settings.windNoiseReduction)
        selectVideoPixelFormat()
        configureVideoDataConnection()
        session.commitConfiguration()
        fitHardwareBudget(wasRunning: wasRunning)
        // After the commit: the output lists codecs and stabilization modes for the committed format only.
        recorder.configureConnection(for: settings)
        reapplyDeviceState()
    }

    /// After commitConfiguration in video mode. A plain session only has a hardware budget while a movie output and
    /// a video data output share it, and it can't run past it. The movie matters more than the histogram, so the
    /// analysis frames stay off for this lens, format and rate, and the output never goes back in with them.
    nonisolated private func fitHardwareBudget(wasRunning: Bool) {
        guard session.hardwareCost > 1, session.outputs.contains(videoDataOutput) else { return }
        if let key = videoBudgetKey {
            videoDataOverBudget.insert(key)
        }
        session.beginConfiguration()
        session.removeOutput(videoDataOutput)
        session.commitConfiguration()
        // The commit that went over budget stopped the session with a runtime error.
        if wasRunning, wantsRunning, !session.isRunning, !session.isInterrupted {
            session.startRunning()
        }
    }

    /// Inside begin/commitConfiguration, after applyVideoFormat. Where the format is known to go over the hardware
    /// budget with the output, it stays out, and comes out if another lens or photo mode left it in: committing it
    /// would stop the running session.
    nonisolated private func attachVideoDataOutputWithinBudget() {
        if let key = videoBudgetKey, videoDataOverBudget.contains(key) {
            if session.outputs.contains(videoDataOutput) {
                session.removeOutput(videoDataOutput)
            }
        } else {
            attachVideoDataOutput()
        }
    }

    nonisolated private func configurePhotoSession(completion: @escaping @MainActor () -> Void) {
        guard case .video = topology, activeCamera != nil else {
            publishSnapshot(then: completion)
            return
        }
        if recorder.isRecording {
            recorder.stop()
        }
        topology = .photo
        videoFrameDuration = nil
        activeVideo = nil
        videoBudgetKey = nil
        session.beginConfiguration()
        clearFocusTrackingTypes()
        if session.outputs.contains(recorder.output) {
            session.removeOutput(recorder.output)
        }
        setAudioInput(enabled: false)
        session.automaticallyConfiguresCaptureDeviceForWideColor = true
        // The video rate's cap would otherwise outlive video mode on this input.
        videoInput?.videoMinFrameDurationOverride = .invalid
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        // Stacks need it, and a video format over the hardware budget may have taken it out.
        attachVideoDataOutput()
        selectVideoPixelFormat()
        configureVideoDataConnection()
        session.commitConfiguration()
        reapplyDeviceState()
        publishSnapshot(then: completion)
    }

    /// Inside begin/commitConfiguration. Picks the format for the settings (or the nearest one the camera
    /// has), sets a constant frame rate and the color space.
    nonisolated private func applyVideoFormat(_ settings: VideoSettings, device: AVCaptureDevice) {
        guard let camera = activeCamera else { return }
        let deviceFormats = device.formats
        let usable = formatDescriptors(for: camera).filter { descriptor in
            guard descriptor.index >= 0, descriptor.index < deviceFormats.count else { return false }
            let unsupported = deviceFormats[descriptor.index].unsupportedCaptureOutputClasses
            return !unsupported.contains { $0 == AVCaptureMovieFileOutput.self }
        }
        let requested = VideoRequirement(resolution: settings.resolution, frameRate: settings.frameRate, colorMode: settings.colorMode)
        // A format the lens had before isn't known to be what it records now.
        activeVideo = nil
        videoBudgetKey = nil
        guard let chosen = FormatSelector.nearestVideoFormat(for: requested, among: usable), Self.lockForChanges(device) else { return }
        let format = deviceFormats[chosen.format.index]
        defer { device.unlockForConfiguration() }
        if device.activeFormat != format {
            device.activeFormat = format
        }
        activeVideo = ActiveVideoFormat(requested: requested, recorded: chosen.recorded)
        videoBudgetKey = "\(camera.lens.id)|\(chosen.format.index)|\(chosen.recorded.frameRate)|\(chosen.recorded.colorMode)"
        // The fallback's rate rather than the one asked for, so frames run at the rate capabilities report.
        videoFrameDuration = Self.frameDuration(fps: chosen.recorded.frameRate, in: format)
        // Otherwise the session reserves hardware for the format's fastest rate, which next to the video data output
        // can cost more than it has. Set before the frame durations, so they never fall outside it. Adding an input
        // clears it, which is why it lives here.
        let override = videoFrameDuration.flatMap { Self.isSupported($0, in: format) ? $0 : nil } ?? .invalid
        if let input = videoInput, input.videoMinFrameDurationOverride != override {
            input.videoMinFrameDurationOverride = override
        }
        if let duration = videoFrameDuration, !device.isAutoVideoFrameRateEnabled, Self.isSupported(duration, in: format) {
            if CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0 {
                device.activeVideoMaxFrameDuration = duration
                device.activeVideoMinFrameDuration = duration
            } else {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
        }
        let wanted: AVCaptureColorSpace
        switch settings.colorMode {
        case .sdr: wanted = .sRGB
        case .hdr: wanted = .HLG_BT2020
        case .appleLog: wanted = .appleLog
        // The format can be the Apple Log fallback that nearestVideoFormat steps down to, which still records log.
        case .appleLog2: wanted = CapabilitiesBuilder.appleLog2Space(in: format.supportedColorSpaces) ?? .appleLog
        }
        if format.supportedColorSpaces.contains(wanted) {
            // Otherwise the session would put its own choice back on the next commit.
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            if device.activeColorSpace != wanted {
                device.activeColorSpace = wanted
            }
        } else {
            // A fallback format, or HDR from a format that only streams EDR: the session picks what it supports.
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
        }
    }

    /// Inside begin/commitConfiguration.
    nonisolated private func setAudioInput(enabled: Bool, windNoiseReduction: Bool = false) {
        if enabled {
            if audioInput == nil {
                guard let microphone = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) else { return }
                session.addInput(input)
                // Mono unless asked, where the Camera app records stereo. The setter raises for an unsupported mode.
                if input.isMultichannelAudioModeSupported(.stereo) {
                    input.multichannelAudioMode = .stereo
                }
                audioInput = input
            }
            // Also for a microphone already in, since the switch can change between video setups. Removal only runs
            // on multichannel audio, and the setter raises where the input doesn't support it.
            if let input = audioInput, input.isWindNoiseRemovalSupported, input.multichannelAudioMode != .none,
               input.isWindNoiseRemovalEnabled != windNoiseReduction {
                input.isWindNoiseRemovalEnabled = windNoiseReduction
            }
        } else if let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }
    }

    /// The checks mirror MovieRecorder.start's, so a refusal surfaces here as an error instead of as a recording
    /// that silently never began.
    nonisolated private func beginRecording(_ request: VideoRequest, rotationAngle: CGFloat, generation: Int) throws {
        guard case .video = topology, session.isRunning, !session.isInterrupted,
              session.outputs.contains(recorder.output),
              let connection = recorder.output.connection(with: .video), connection.isActive, connection.isEnabled else {
            throw CameraError.captureFailed("Video isn't ready yet.")
        }
        guard !recorder.isRecording, !recorder.output.isRecording else { throw CameraError.busy }
        recorder.start(rotationAngle: rotationAngle, location: request.location) { [weak self] result in
            self?.recordingFinished(result, generation: generation)
        }
        startRecordingTimer()
    }

    @MainActor private func recordingFinished(_ result: Result<CaptureResult, Error>, generation: Int) {
        // A movie whose stop timed out can finish while the next one records; it must not end that one's state.
        guard generation == recordingGeneration else { return }
        recordingActive = false
        sessionQueue.async {
            self.stopRecordingTimer()
        }
        if let waiter = recordingWaiter {
            recordingWaiter = nil
            waiter.resume(with: result)
        } else {
            finishedRecording = result
        }
    }

    nonisolated private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let duration = self.recorder.duration
            DispatchQueue.main.async {
                self.delegate?.cameraBackend(self, didUpdateRecordingDuration: duration)
            }
        }
        timer.resume()
        recordingTimer = timer
    }

    nonisolated private func stopRecordingTimer() {
        recordingTimer?.cancel()
        recordingTimer = nil
    }
}

// MARK: - Camera Control

extension CameraService {
    /// Installs controls for the latest state on the active camera. Skips identical re-installs, which the
    /// model asks for often, because each one reconfigures the session.
    nonisolated func installCameraControls() {
        guard let state = cameraControlState, let camera = activeCamera, session.supportsControls else { return }
        if let installed = installedControls, installed.state == state, installed.deviceID == camera.lens.id { return }
        session.beginConfiguration()
        controlsBridge.install(on: session, device: camera.device, state: state)
        session.commitConfiguration()
        installedControls = (state, camera.lens.id)
    }
}

// MARK: - Frames

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let engine = engineLock.withLock { activeEngine }
        if let engine {
            // While stacking every frame belongs to the engine; the stack preview replaces the overlays.
            if engine.consume(sampleBuffer) {
                stackEngineDidFinish(engine)
            }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = analyzer.analyze(pixelBuffer) else { return }
        deliverAnalysis(frame)
    }

    /// Keeps at most one analysis frame queued for the main thread; a busy main thread gets the newest one.
    nonisolated private func deliverAnalysis(_ frame: AnalysisFrame) {
        let wasIdle: Bool = analysisLock.withLock {
            let idle = pendingAnalysis == nil
            pendingAnalysis = frame
            return idle
        }
        guard wasIdle else { return }
        DispatchQueue.main.async {
            let latest = self.analysisLock.withLock { () -> AnalysisFrame? in
                let frame = self.pendingAnalysis
                self.pendingAnalysis = nil
                return frame
            }
            if let latest {
                self.delegate?.cameraBackend(self, didProduceAnalysis: latest)
            }
        }
    }
}

// MARK: - Helper types

/// What start, select and reconfigurations hand to the main actor in one piece.
private struct SessionSnapshot: @unchecked Sendable {
    var lenses: [LensInfo]
    var presets: [LensPreset]
    var camera: DeviceCatalog.Camera?
    var capabilities: CameraCapabilities?
    var state: SessionState?
    var forceState: Bool
}

/// How stacked frames turn upright for the photo and for the live preview.
private struct StackOrientation: Sendable {
    var output: CGImagePropertyOrientation
    var previewRotation: Double
    var previewMirrored: Bool
}

/// One night or long exposure in flight. Session queue only, apart from `complete`, which can run anywhere.
private final class StackJob: @unchecked Sendable {
    enum Phase {
        case settingExposure, collecting, finishing
    }

    let id = UUID()
    let request: StackRequest
    let orientation: StackOrientation
    let progress: @MainActor (StackProgress) -> Void
    let lens: LensInfo
    let zoomFactor: Double
    /// What the camera exposed just before the stack took over, which the preview goes back to.
    let exposureBefore: ExposureValues?
    let wasAELocked: Bool
    var phase: Phase = .settingExposure
    var engine: StackedCaptureEngine?
    var watchdog: DispatchSourceTimer?
    var finishRequestedAt: CFTimeInterval?
    var cancelRequested = false
    var collectingSince: CFTimeInterval?
    var deadline: CFTimeInterval?

    private let completion: @Sendable (Result<CaptureResult, Error>) -> Void
    private let lock = NSLock()
    private var completed = false

    init(request: StackRequest, orientation: StackOrientation, progress: @escaping @MainActor (StackProgress) -> Void,
         completion: @escaping @Sendable (Result<CaptureResult, Error>) -> Void, lens: LensInfo, zoomFactor: Double,
         exposureBefore: ExposureValues?, wasAELocked: Bool) {
        self.request = request
        self.orientation = orientation
        self.progress = progress
        self.completion = completion
        self.lens = lens
        self.zoomFactor = zoomFactor
        self.exposureBefore = exposureBefore
        self.wasAELocked = wasAELocked
    }

    /// Exactly once, whichever path ends the stack first.
    func complete(_ result: Result<CaptureResult, Error>) {
        let first: Bool = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if first {
            completion(result)
        }
    }
}
