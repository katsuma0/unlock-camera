import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit
import CameraCore

/// A camera made of a synthetic night street, so the app runs and every control does something in the
/// iOS Simulator. Pretends to be an iPhone 18 Pro: four lenses and a variable aperture main camera.
///
/// Main actor like every backend. The street is drawn on `renderQueue`; photos and stacks have their own queue and
/// renderer, so a long exposure never stalls the preview, and movies record the preview frames on their own queue.
/// Auto exposure, autofocus and auto white balance are simulated on the main actor from what the meter reads in the
/// rendered frames, so the HUD moves like the real thing.
@MainActor
final class SimulatedCamera: CameraBackend {
    weak var delegate: CameraBackendDelegate?
    let isSimulated = true
    private(set) var lenses: [LensInfo] = []
    private(set) var lensPresets: [LensPreset] = []
    private(set) var activeLensID: String?

    // MARK: - Workers

    private let previewLayer = CALayer()
    private let liveScene = SyntheticScene(width: SimulatedSpec.previewSize.width, height: SimulatedSpec.previewSize.height)
    private let photoScene = SyntheticScene(width: SimulatedSpec.previewSize.width * SimulatedSpec.photoScale,
                                            height: SimulatedSpec.previewSize.height * SimulatedSpec.photoScale)
    private let stackScene = SyntheticScene(width: SimulatedSpec.stackSize.width, height: SimulatedSpec.stackSize.height)
    private let renderQueue = DispatchQueue(label: "ca.katsuma.openshutter.simulator.render", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "ca.katsuma.openshutter.simulator.capture", qos: .userInitiated)
    private let stackQueue = DispatchQueue(label: "ca.katsuma.openshutter.simulator.stack", qos: .userInitiated)
    private let movieQueue = DispatchQueue(label: "ca.katsuma.openshutter.simulator.movie", qos: .userInitiated)

    // MARK: - Session

    private var lens = SimulatedLens.wide
    private var isRunning = false
    private var lensSwitching = false
    /// Front camera photos and stacks saved as the preview shows them. From `start`, then from every DeviceOptions.
    private var mirrorFrontPhotos = true
    /// Set while in video mode; picks the active format.
    private var videoSettings: VideoSettings?
    private var publishedCapabilities: CameraCapabilities?
    private var publishedReadings: LiveReadings?

    // MARK: - Requests

    private var exposureRequest = ExposureRequest.auto
    private var focusRequest = FocusRequest.continuousAuto
    private var whiteBalanceRequest = WhiteBalanceRequest.auto
    private var deviceOptions: DeviceOptions?
    private var torchLevel: Double?
    private var analysisOptions = AnalysisOptions.off
    /// Normalized frame coordinates as displayed; nil meters center weighted.
    private var meteringPoint: CGPoint?
    /// The meter moved to a new point and auto exposure hasn't settled there yet. An AE lock meanwhile meters on and
    /// holds once it settles, like AE/AF LOCK on the real camera; freezing at once would keep an exposure metered
    /// somewhere else.
    private var meteringPointPending = false

    // MARK: - Simulated hardware

    private var exposure = SimulatedLens.wide.startingExposure(zoom: 1, maxAutoSeconds: nil)
    private var exposureAdjusting = false
    /// The meter of the newest frame, the exposure gain that frame was taken with, and where it metered.
    private var meter: SceneMeter?
    private var meterGain = 1.0
    private var meterSpot: (point: CGPoint?, rect: CGRect?) = (nil, nil)
    private var zoomFactor = 1.0
    private var zoomTarget = 1.0
    private var zoomRamps = false
    private var lensPosition = 0.5
    private var lensVelocity = 0.0
    private var focusHold = false
    private var focusAdjusting = false
    private var mired = 1e6 / SyntheticScene.referenceKelvin
    private var tint = 0.0
    private var grayWorldTarget: (mired: Double, tint: Double)?
    private var whiteBalanceAdjusting = false
    private var whiteBalanceSettleUntil: CFTimeInterval = 0

    // MARK: - Frame loop

    private var displayLink: CADisplayLink?
    private let clockOrigin = CACurrentMediaTime()
    private var lastTick: CFTimeInterval = 0
    private var lastFrameStart: CFTimeInterval = 0
    private var lastExposureStep: CFTimeInterval = 0
    private var lastReadingsCheck: CFTimeInterval = 0
    private var lastAnalysis: CFTimeInterval = 0
    private var stripePhase = 0
    private var renderInFlight = false
    private var latestFrame: SceneFrame?

    // MARK: - Capture

    /// Photos still rendering or saving. They may overlap, but a stack waits until none are left.
    private var photosInFlight = 0
    private var stackJob: SimulatedStackJob?
    /// The stack's per-frame exposure, held while it runs.
    private var stackExposure: ExposureValues?
    /// The exposure the stack took over from, put back when it ends.
    private var exposureBeforeStack: ExposureValues?
    private var recorder: SimulatedMovieWriter?
    private var recordingStarting = false
    /// Stops that came in while startRecording was still opening the file; resumed once it is done.
    private var recordingStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordingStart: CFTimeInterval = 0
    private var recordingLocation: LocationStamp?
    private var lastDurationTick: CFTimeInterval = 0
    /// A recording being closed and saved; stopRecording picks it up even when stop() began it.
    private var recordingFinish: Task<CaptureResult, Error>?
    /// Held from the start of a recording until its movie is saved: an asset writer that is still writing when the
    /// app goes to the background fails, and the movie with it.
    private var recordingBackgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        previewLayer.isOpaque = true
        // Frames replace each other 30 times a second; the layer's default cross-fade would smear them.
        previewLayer.actions = ["contents": NSNull()]
    }

    // MARK: - Authorization

    func authorizationStatus() -> CameraAuthorization { .authorized }

    func requestAuthorization() async -> CameraAuthorization { .authorized }

    // MARK: - Lifecycle

    func start(settings: CameraSettings) async {
        mirrorFrontPhotos = settings.capture.mirrorFront
        if activeLensID == nil {
            lenses = SimulatedLens.catalog.map(\.info)
            lensPresets = SimulatedLens.presets
            let chosen = SimulatedLens.catalog.first { $0.info.id == settings.lensID } ?? .wide
            lens = chosen
            activeLensID = chosen.info.id
            zoomFactor = chosen.info.id == settings.lensID ? SimulatedSpec.clampedZoom(settings.zoom) : 1
            zoomTarget = zoomFactor
            exposure = chosen.startingExposure(zoom: zoomFactor, maxAutoSeconds: exposureRequest.maxAutoSeconds)
        }
        if !isRunning {
            isRunning = true
            startLoop()
        }
        publishCapabilities(force: true)
        delegate?.cameraBackend(self, didChangeState: .running)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopLoop()
        // Like the real camera: a running stack keeps what it has, and a recording is closed and saved.
        stackJob?.requestFinish()
        if recorder != nil {
            beginFinishingRecording()
        }
        publishedReadings = nil
        delegate?.cameraBackend(self, didChangeState: .idle)
    }

    // MARK: - Preview

    func makePreviewLayer() -> CALayer {
        previewLayer
    }

    /// The simulator's device points are positions in the frame as displayed. Nothing outside the backend reads
    /// them, so the mirrored front camera needs no special case.
    func devicePoint(fromLayerPoint point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, let rect = displayedFrameRect() else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        // A tap on the letterbox beside the picture has no point in the scene.
        let margin: CGFloat = 0.02
        guard x >= -margin, x <= 1 + margin, y >= -margin, y <= 1 + margin else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    func layerPoint(fromDevicePoint point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, let rect = displayedFrameRect() else { return nil }
        return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    /// Where `.resizeAspect` puts the 3:4 frame inside the layer.
    private func displayedFrameRect() -> CGRect? {
        let bounds = previewLayer.bounds
        let size = SimulatedSpec.previewSize
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / CGFloat(size.width), bounds.height / CGFloat(size.height))
        let width = CGFloat(size.width) * scale
        let height = CGFloat(size.height) * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    // MARK: - Lens and zoom

    func select(_ preset: LensPreset) async {
        guard let target = SimulatedLens.catalog.first(where: { $0.info.id == preset.lensID }) else { return }
        if target.info.id != lens.info.id {
            // A real lens switch reconfigures the session; the preview holds its last frame for that moment.
            lensSwitching = true
            try? await Task.sleep(nanoseconds: SimulatedSpec.lensSwitchNanoseconds)
            lensSwitching = false
            switchLens(to: target)
        }
        zoomRamps = false
        zoomTarget = SimulatedSpec.clampedZoom(preset.zoomFactor)
        zoomFactor = zoomTarget
        publishCapabilities()
    }

    func setZoomFactor(_ factor: Double, animated: Bool) {
        guard factor.isFinite else { return }
        zoomTarget = SimulatedSpec.clampedZoom(factor)
        zoomRamps = animated
        if !animated {
            zoomFactor = zoomTarget
        }
    }

    private func switchLens(to target: SimulatedLens) {
        lens = target
        activeLensID = target.info.id
        // A new device meters from its own center until someone taps.
        meteringPoint = nil
        exposure = exposureRanges.clamp(ExposureValues(seconds: exposure.seconds, iso: exposure.iso, aperture: target.info.aperture))
        // The new lens starts a little out of focus and autofocus pulls it in, as on a phone.
        switch focusRequest {
        case .continuousAuto, .autoOnce:
            lensPosition = min(max(lensPosition + (lensPosition > 0.5 ? -0.14 : 0.14), 0), 1)
            lensVelocity = 0
            focusHold = false
        case .locked, .manual:
            break
        }
    }

    // MARK: - Requests

    func apply(exposure request: ExposureRequest) {
        exposureRequest = request
        // The AE shutter limit is part of the capabilities.
        publishCapabilities()
        // Fixed values reach the sensor right away; auto values keep their own pace.
        stepExposure(allowAutoStep: false)
    }

    func apply(focus request: FocusRequest) {
        focusRequest = request
        switch request {
        case .continuousAuto, .manual:
            focusHold = false
        case .autoOnce:
            focusHold = false
            // A tap already set the lens moving through setPointOfInterest; one swing is enough.
            if abs(lensVelocity) < 0.3 {
                nudgeFocus()
            }
        case .locked:
            lensVelocity = 0
        }
    }

    func apply(whiteBalance request: WhiteBalanceRequest) {
        whiteBalanceRequest = request
        grayWorldTarget = nil
        if case .grayWorld = request, let meter {
            grayWorldTarget = (1e6 / meter.grayWorldKelvin, meter.grayWorldTint)
        }
        // Readings say "adjusting" for a moment, so whoever waits for the new values doesn't take the old ones.
        whiteBalanceSettleUntil = CACurrentMediaTime() + 0.25
        whiteBalanceAdjusting = true
    }

    /// Only the focus range, smooth focus, metering area and front mirroring change anything here: the street has no
    /// faces and the simulated sensor has no tone mapping or HDR modes to switch.
    func apply(options: DeviceOptions) {
        deviceOptions = options
        // Settings can flip this at any time; the next front camera shot follows it, as on the real camera.
        mirrorFrontPhotos = options.mirrorFront
    }

    func setPointOfInterest(_ devicePoint: CGPoint, focus: Bool, exposure meters: Bool) {
        guard devicePoint.x.isFinite, devicePoint.y.isFinite else { return }
        let point = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))
        if meters {
            meteringPoint = point
            meteringPointPending = true
        }
        if focus {
            focusHold = false
            nudgeFocus()
        }
    }

    func setTorch(level: Double?) {
        torchLevel = level.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    func setAnalysis(_ options: AnalysisOptions) {
        analysisOptions = options
    }

    // MARK: - Photo

    func capturePhoto(_ request: PhotoRequest) async throws -> [CaptureResult] {
        guard isRunning else { throw CameraError.captureFailed("The camera isn't running.") }
        // A photo may start while earlier ones still render or save, as AVCapturePhotoOutput allows; the capture
        // queue draws them one after another.
        guard stackJob == nil else { throw CameraError.busy }
        photosInFlight += 1
        defer { photosInFlight -= 1 }

        let exposures = photoExposures(for: request)
        let light = flashFires(request.flash) ? 1 : torchLight
        let mirrored = lens.info.isFront && mirrorFrontPhotos
        // As on the real photo output, Bayer RAW is left out at any zoom but 1, during a zoom ramp, and on a lens
        // without it. Read now: the zoom can move while the photo renders.
        let bayerDropped = request.rawFormat == .bayer
            && (!lens.supportsBayerRAW || abs(zoomFactor - 1) > 0.001 || zoomFactor != zoomTarget)
        let started = CACurrentMediaTime()
        // Bracket frames follow each other like a burst: each exposure, then a frame's gap.
        var clock = started
        var shots: [SceneShot] = []
        for values in exposures {
            clock += values.seconds
            shots.append(shot(at: clock, exposure: values, mirrored: mirrored, foregroundLight: light))
            clock += SimulatedSpec.frameInterval
        }
        let job = SimulatedPhotoJob(
            shots: shots,
            exposures: exposures,
            format: request.processedFormat == .none ? .heif : request.processedFormat,
            quality: request.quality,
            aspect: request.aspect,
            location: request.location,
            lensName: lens.info.name,
            focalLength: lens.info.equivalentFocalLength * zoomFactor,
            date: Date()
        )
        delegate?.cameraBackendWillCapture(self)
        let scene = photoScene
        let queue = captureQueue
        let photos = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SimulatedPhoto], Error>) in
            queue.async {
                continuation.resume(with: Result { try job.render(with: scene) })
            }
        }
        // The shutter stays open as long as the exposure says, so a 1 s photo takes a second here too.
        let exposed = exposures.reduce(0) { $0 + $1.seconds } + Double(max(exposures.count - 1, 0)) * SimulatedSpec.frameInterval
        let waited = CACurrentMediaTime() - started
        if exposed > waited {
            try? await Task.sleep(nanoseconds: UInt64((exposed - waited) * 1_000_000_000))
        }
        // The Simulator can't write DNG, so a RAW request saves the rendering in its place, tagged like the real thing.
        let kind: CaptureResult.Kind = photos.count > 1 ? .bracket : ((request.rawFormat == .none || bayerDropped) ? .photo : .raw)
        var results: [CaptureResult] = []
        for photo in photos {
            var identifier: String?
            var saved = false
            do {
                identifier = try await PhotoLibrary.savePhoto(primary: photo.encoded.data, primaryType: photo.encoded.typeIdentifier,
                                                              raw: nil, livePhotoMovie: nil, location: request.location)
                saved = true
            } catch {
                // The result still goes back, marked unsaved, and the model tells the person why.
            }
            results.append(CaptureResult(kind: kind, assetIdentifier: identifier, thumbnail: photo.thumbnail,
                                         summary: photo.summary, date: job.date, savedToLibrary: saved))
        }
        return results
    }

    /// One exposure, or the bracket around the current one (or the manual base), never more than the
    /// simulated output allows.
    private func photoExposures(for request: PhotoRequest) -> [ExposureValues] {
        let ranges = exposureRanges
        let current = ranges.clamp(exposure)
        guard request.bracket.kind == .exposure else { return [current] }
        let offsets = request.bracket.exposureOffsets()
        var count = min(offsets.count, SimulatedSpec.maxBracketCount)
        // Offsets come center first and then in pairs, so an odd prefix stays balanced around the metered shot.
        if count < offsets.count && count % 2 == 0 {
            count -= 1
        }
        guard count >= 2 else { return [current] }
        let base = request.bracketBase.map { ranges.clamp($0) } ?? current
        return Array(request.bracket.exposures(around: base, ranges: ranges).prefix(count))
    }

    private func flashFires(_ setting: FlashSetting) -> Bool {
        guard lens.hasFlash else { return false }
        switch setting {
        case .off:
            return false
        case .on:
            return true
        case .auto:
            // Auto fires when the scene wants more light than a short handheld shot at a moderate ISO gives.
            let offset = meterOffset(for: exposure) ?? 0
            return ExposureMath.lightProduct(exposure) * pow(2, -offset) > SimulatedSpec.flashThresholdProduct
        }
    }

    // MARK: - Stacks

    func captureStack(_ request: StackRequest, progress: @escaping @MainActor (StackProgress) -> Void) async throws -> CaptureResult {
        guard isRunning else { throw CameraError.captureFailed("The camera isn't running.") }
        guard stackJob == nil, photosInFlight == 0 else { throw CameraError.busy }
        // Cancelled before anything was exposed: there is nothing to keep.
        guard !Task.isCancelled else { throw CameraError.cancelled }
        var plan = request.plan
        let frameExposure = exposureRanges.clamp(ExposureValues(
            seconds: plan.frameSeconds, iso: plan.iso,
            aperture: lens.isVariableAperture ? plan.aperture : lens.info.aperture
        ))
        plan.frameSeconds = frameExposure.seconds
        plan.iso = frameExposure.iso
        plan.aperture = frameExposure.aperture
        // The preview shows what the stack's frames see, and focus, white balance and exposure hold still. The
        // exposure from before comes back afterwards, so an AE lock still holds what it locked.
        stackExposure = frameExposure
        exposureBeforeStack = exposure
        exposure = frameExposure
        exposureAdjusting = false
        let isFront = lens.info.isFront
        let job = SimulatedStackJob(
            request: request,
            plan: plan,
            firstShot: shot(at: CACurrentMediaTime(), exposure: frameExposure, mirrored: isFront, foregroundLight: torchLight),
            scene: stackScene,
            queue: stackQueue,
            flipsResult: isFront && !mirrorFrontPhotos,
            lensName: lens.info.name,
            focalLength: lens.info.equivalentFocalLength * zoomFactor,
            progress: progress
        )
        stackJob = job
        delegate?.cameraBackendWillCapture(self)
        let outcome: SimulatedStackJob.Outcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SimulatedStackJob.Outcome, Error>) in
                    job.start(continuation)
                }
            } onCancel: {
                // The model cancels its capture task for Stop as well as for Discard, and says which one it means
                // through finishStackEarly or cancelStack. Ending early keeps the frames for Stop; Discard's
                // cancelStack follows at once and still throws them away.
                job.requestFinish()
            }
        } catch {
            endStack()
            throw error
        }
        endStack()
        var identifier: String?
        var saved = false
        do {
            identifier = try await PhotoLibrary.savePhoto(primary: outcome.encoded.data, primaryType: outcome.encoded.typeIdentifier,
                                                          raw: nil, livePhotoMovie: nil, location: request.location)
            saved = true
        } catch {
            // Reported through savedToLibrary; the model shows the message.
        }
        return CaptureResult(kind: .stack, assetIdentifier: identifier, thumbnail: outcome.thumbnail, summary: outcome.summary,
                             date: outcome.date, savedToLibrary: saved)
    }

    func finishStackEarly() {
        stackJob?.requestFinish()
    }

    func cancelStack() {
        stackJob?.cancel()
    }

    private func endStack() {
        stackJob = nil
        stackExposure = nil
        if let before = exposureBeforeStack {
            exposure = exposureRanges.clamp(before)
        }
        exposureBeforeStack = nil
    }

    // MARK: - Video

    func configureForVideo(_ settings: VideoSettings) async {
        videoSettings = settings
        publishCapabilities()
    }

    func configureForPhoto() async {
        videoSettings = nil
        publishCapabilities()
    }

    func startRecording(_ request: VideoRequest) async throws {
        guard isRunning else { throw CameraError.captureFailed("The camera isn't running.") }
        guard recorder == nil, !recordingStarting else { throw CameraError.busy }
        recordingStarting = true
        defer {
            recordingStarting = false
            let waiters = recordingStartWaiters
            recordingStartWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        let size = SimulatedSpec.previewSize
        let queue = movieQueue
        let writer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SimulatedMovieWriter, Error>) in
            queue.async {
                continuation.resume(with: Result { try SimulatedMovieWriter(width: size.width, height: size.height, queue: queue) })
            }
        }
        guard isRunning else {
            writer.discard()
            throw CameraError.captureFailed("The camera stopped.")
        }
        recordingFinish = nil
        recorder = writer
        recordingBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save movie") { [weak self] in
            // Out of time: ending here keeps iOS from killing the app.
            self?.endRecordingBackgroundTask()
        }
        recordingStart = CACurrentMediaTime()
        recordingLocation = request.location
        lastDurationTick = recordingStart
        if let latestFrame {
            writer.append(latestFrame, at: 0)
        }
        delegate?.cameraBackend(self, didUpdateRecordingDuration: 0)
    }

    func stopRecording() async throws -> CaptureResult {
        // A stop right after the start would otherwise find no recorder yet, and the clip would then run on with
        // nobody left to stop it. Waiting for the file to open turns it into a very short clip instead.
        let waitedForStart = recordingStarting
        if waitedForStart {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recordingStartWaiters.append(continuation)
            }
        }
        let task: Task<CaptureResult, Error>
        if let started = beginFinishingRecording() {
            task = started
        } else if let pending = recordingFinish {
            task = pending
        } else if waitedForStart {
            // The start failed and startRecording has already reported why.
            throw CameraError.cancelled
        } else {
            throw CameraError.captureFailed("Nothing is recording.")
        }
        recordingFinish = nil
        return try await task.value
    }

    /// Stops feeding frames, then closes and saves the movie. nil when nothing is recording.
    @discardableResult
    private func beginFinishingRecording() -> Task<CaptureResult, Error>? {
        guard let writer = recorder else { return nil }
        recorder = nil
        let location = recordingLocation
        let task = Task<CaptureResult, Error> {
            // Also when closing the file fails: the time is only needed until there is a result.
            defer { self.endRecordingBackgroundTask() }
            let movie = try await writer.finish()
            var identifier: String?
            var saved = false
            do {
                identifier = try await PhotoLibrary.saveVideo(at: movie.url, location: location)
                saved = true
            } catch {
                // Photos didn't take it, and a movie left in tmp would only use space.
                try? FileManager.default.removeItem(at: movie.url)
            }
            return CaptureResult(kind: .video, assetIdentifier: identifier, thumbnail: movie.thumbnail, summary: movie.summary,
                                 date: movie.date, savedToLibrary: saved)
        }
        recordingFinish = task
        return task
    }

    private func endRecordingBackgroundTask() {
        guard recordingBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(recordingBackgroundTask)
        recordingBackgroundTask = .invalid
    }

    // MARK: - Camera Control

    /// The Simulator has no Camera Control button.
    func configureCameraControls(_ state: CameraControlState) {}

    // MARK: - Frame loop

    private func startLoop() {
        guard displayLink == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: SimulatedFrameClock(camera: self), selector: #selector(SimulatedFrameClock.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayLinkFired() {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        let elapsed = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        advanceZoom(elapsed)
        advanceFocus(elapsed)
        advanceWhiteBalance(elapsed, now: now)
        if Self.isDue(now, since: lastExposureStep, every: SimulatedSpec.exposureStepInterval) {
            lastExposureStep = now
            stepExposure(allowAutoStep: true)
        }
        if Self.isDue(now, since: lastReadingsCheck, every: SimulatedSpec.readingsInterval) {
            lastReadingsCheck = now
            publishReadings()
        }
        if recorder != nil, Self.isDue(now, since: lastDurationTick, every: SimulatedSpec.durationInterval) {
            lastDurationTick = now
            delegate?.cameraBackend(self, didUpdateRecordingDuration: now - recordingStart)
        }
        renderIfDue(now)
    }

    /// Display link ticks jitter by a millisecond or two. Without the slack a 0.1 s interval often misses the third
    /// 30 Hz tick and waits for the fourth, and "10 Hz" turns into 7.5 Hz.
    private static func isDue(_ now: CFTimeInterval, since last: CFTimeInterval, every interval: Double) -> Bool {
        now - last >= interval - SimulatedSpec.tickSlack
    }

    private func renderIfDue(_ now: CFTimeInterval) {
        // Skips frames while the last one is still being drawn, or while a lens switch holds the picture.
        guard !renderInFlight, !lensSwitching else { return }
        // A slow shutter holds each preview frame as long as it is open, like a real sensor. Shorter ones keep the
        // preview at 30 fps with their motion blur.
        let interval = exposure.seconds >= SimulatedSpec.slowShutter ? exposure.seconds : SimulatedSpec.frameInterval
        guard Self.isDue(now, since: lastFrameStart, every: interval) else { return }
        lastFrameStart = now
        renderInFlight = true
        let frameShot = shot(at: now, exposure: exposure, mirrored: lens.info.isFront, foregroundLight: torchLight)
        let analysisDue = !analysisOptions.isOff && Self.isDue(now, since: lastAnalysis, every: SimulatedSpec.analysisInterval)
        if analysisDue {
            lastAnalysis = now
            stripePhase = (stripePhase + 1) % SimulatedAnalysis.stripePeriod
        }
        let analysis = analysisDue ? SimulatedAnalysisJob(options: analysisOptions, stripePhase: stripePhase) : nil
        let scene = liveScene
        renderQueue.async { [weak self] in
            let frame = scene.renderFrame(frameShot)
            let result = frame.flatMap { frame in analysis.map { SimulatedAnalysis.analyze(frame, $0) } }
            DispatchQueue.main.async {
                self?.frameDidRender(frame, analysis: result, startedAt: now)
            }
        }
    }

    private func frameDidRender(_ frame: SceneFrame?, analysis: AnalysisFrame?, startedAt: CFTimeInterval) {
        renderInFlight = false
        guard let frame else { return }
        latestFrame = frame
        if let frameMeter = frame.meter {
            meter = frameMeter
            meterGain = frame.shot.gain
            meterSpot = (frame.shot.meteringPoint, frame.shot.meteringRect)
        }
        previewLayer.contents = frame.image
        recorder?.append(frame, at: startedAt - recordingStart)
        if isRunning, let analysis {
            delegate?.cameraBackend(self, didProduceAnalysis: analysis)
        }
    }

    /// The shot for a frame ending at `time` with the simulated device as it is now.
    private func shot(at time: CFTimeInterval, exposure values: ExposureValues, mirrored: Bool, foregroundLight: Double) -> SceneShot {
        SceneShot(
            time: time - clockOrigin,
            shutterSeconds: values.seconds,
            gain: ExposureMath.lightProduct(values) / SyntheticScene.referenceProduct,
            iso: values.iso,
            kelvin: 1e6 / mired,
            tint: tint,
            blur: defocusBlur(aperture: values.aperture),
            framing: SceneFraming(zoom: lens.info.relativeZoom * zoomFactor, mirrored: mirrored),
            foregroundLight: foregroundLight,
            meteringPoint: meteringPoint,
            meteringRect: meteringRect,
            addsNoise: true
        )
    }

    /// What a spot or whole frame meter reads, the same rect the real camera gets; nil keeps the pattern around the
    /// point.
    private var meteringRect: CGRect? {
        let area = deviceOptions?.meteringArea ?? .automatic
        let center = meteringPoint ?? CGPoint(x: 0.5, y: 0.5)
        guard let rect = area.rectOfInterest(centerX: Double(center.x), centerY: Double(center.y),
                                             minWidth: SimulatedSpec.smallestMeteringRect,
                                             minHeight: SimulatedSpec.smallestMeteringRect) else { return nil }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// Defocus grows with the distance from the in-focus position and with the aperture; digital zoom enlarges it
    /// along with everything else.
    private func defocusBlur(aperture: Double) -> Double {
        let miss = abs(lensPosition - SimulatedSpec.subjectLensPosition)
        let opening = aperture.isFinite && aperture > 0 ? 1.78 / aperture : 1
        return min(SimulatedSpec.defocusPerPosition * miss * opening * lens.defocusScale * zoomFactor, SimulatedSpec.maxDefocus)
    }

    private var torchLight: Double {
        lens.hasFlash ? (torchLevel ?? 0) * SimulatedSpec.torchStrength : 0
    }

    // MARK: - Simulated auto exposure

    private var exposureRanges: ExposureRanges {
        lens.ranges(maxAutoSeconds: exposureRequest.maxAutoSeconds)
    }

    private var bias: Double {
        clamped(exposureRequest.bias, SimulatedSpec.biasRange, fallback: 0)
    }

    /// exposureTargetOffset as AVFoundation reports it: metered brightness at `values` against the target, which
    /// the bias moves.
    private func meterOffset(for values: ExposureValues) -> Double? {
        guard let meter, meterGain > 0 else { return nil }
        let gain = ExposureMath.lightProduct(values) / SyntheticScene.referenceProduct
        guard gain > 0 else { return nil }
        let offset = meter.offset + log2(gain / meterGain) - bias
        return offset.isFinite ? offset : nil
    }

    /// One step of the simulated auto exposure: program line when all auto, priority modes honouring the locks,
    /// frozen when locked. `allowAutoStep` false moves the fixed values, and the auto ones only onto the program
    /// line at the same light.
    private func stepExposure(allowAutoStep: Bool) {
        let ranges = exposureRanges
        if let held = stackExposure {
            exposure = ranges.clamp(held)
            exposureAdjusting = false
            return
        }
        let request = exposureRequest
        // A lock waits for the meter to settle at a new point before it holds.
        let aeHolds = request.aeLocked && !meteringPointPending
        let locks = effectiveLocks(request.locks, ranges: ranges)
        var current = exposure
        // Auto aperture rests at the lens's default unless it is the only thing left to adjust.
        if locks.aperture == nil && (locks.seconds == nil || locks.iso == nil) {
            current.aperture = lens.info.aperture
        }
        let handheld = ExposureMath.handheldLimit(equivalentFocalLength: lens.info.equivalentFocalLength * zoomFactor,
                                                  stabilizationStops: SimulatedSpec.stabilizationStops)
        // Inside its deadband the meter keeps the shutter it has, so a new AE limit, lens or zoom would wait for the
        // scene to change. Splitting the same light again applies them now, at the same brightness where the
        // limits allow it.
        if !aeHolds, locks.seconds == nil {
            if locks.iso == nil {
                let split = ProgramLine.split(product: ExposureMath.lightProduct(current), aperture: current.aperture,
                                              ranges: ranges, handheldLimit: handheld)
                current.seconds = split.seconds
                current.iso = split.iso
            } else {
                current.seconds = min(current.seconds, ranges.maxAutoSeconds)
            }
        }
        let held = ExposureValues(seconds: locks.seconds ?? current.seconds, iso: locks.iso ?? current.iso,
                                  aperture: locks.aperture ?? current.aperture)
        if (aeHolds && request.locks.isAllAuto) || locks.isFullyManual(variableAperture: lens.isVariableAperture) {
            var frozen = held
            // A faster frame rate shortens a held shutter to fit the frame, as on the real camera. VIDEO's requests
            // carry the frame duration as their AE limit.
            if videoSettings != nil {
                frozen.seconds = min(frozen.seconds, ranges.maxAutoSeconds)
            }
            exposure = ranges.clamp(frozen)
            exposureAdjusting = false
            return
        }
        guard allowAutoStep, let offset = meterOffset(for: current) else {
            exposure = ranges.clamp(held)
            return
        }
        let next = SoftwareAE.step(current: current, meterOffset: offset, locks: locks, ranges: ranges,
                                   handheldLimit: handheld, gain: 0.6, deadband: 0.08)
        // Adjusting means the exposure is still moving. A priority mode pinned at a range limit stays off target
        // for good, and the real device reports that as settled.
        exposureAdjusting = abs(ExposureMath.stops(from: exposure, to: next)) > 0.02
        exposure = next
        // Settled, or as close as the ranges allow, on a meter read at the point itself: a lock holds from here. A
        // meter from a frame drawn before the point moved says nothing about the new point.
        if meteringPointPending, !exposureAdjusting, meterSpot.point == meteringPoint, meterSpot.rect == meteringRect {
            meteringPointPending = false
        }
    }

    /// Locks the simulated sensor can hold. A shutter past the hardware limit (a stacked exposure) previews at the
    /// longest shutter with ISO raised by the missing stops, as the real camera does.
    private func effectiveLocks(_ locks: ExposureLocks, ranges: ExposureRanges) -> ExposureLocks {
        var result = locks
        if !lens.isVariableAperture {
            result.aperture = nil
        }
        let longest = ranges.seconds.upperBound
        if let seconds = locks.seconds, seconds.isFinite, seconds > longest, longest > 0 {
            result.seconds = longest
            if let iso = locks.iso {
                result.iso = min(iso * (seconds / longest), ranges.iso.upperBound)
            }
        }
        return result
    }

    // MARK: - Simulated zoom, focus and white balance

    private func advanceZoom(_ elapsed: Double) {
        guard zoomFactor != zoomTarget else { return }
        guard zoomRamps else {
            zoomFactor = zoomTarget
            return
        }
        // Same units as AVCaptureDevice.ramp(toVideoZoomFactor:withRate:): doublings per second.
        let step = pow(2, SimulatedSpec.zoomRampRate * elapsed)
        zoomFactor = zoomTarget > zoomFactor ? min(zoomTarget, zoomFactor * step) : max(zoomTarget, zoomFactor / step)
    }

    private func advanceFocus(_ elapsed: Double) {
        // A stack shoots every frame at the same focus.
        guard stackJob == nil else {
            lensVelocity = 0
            focusAdjusting = false
            return
        }
        let target: Double
        let stiffness: Double
        let damping: Double
        switch focusRequest {
        case .locked:
            lensVelocity = 0
            focusAdjusting = false
            return
        case .manual(let position):
            target = position.isFinite ? min(max(position, 0), 1) : lensPosition
            stiffness = 420
            damping = 41
        case .continuousAuto, .autoOnce:
            if focusHold {
                lensVelocity = 0
                focusAdjusting = false
                return
            }
            target = autofocusTarget
            let smooth = deviceOptions?.smoothFocus == true
            stiffness = smooth ? 60 : 160
            damping = smooth ? 14 : 16.5
        }
        // A spring toward the target. Autofocus is a little underdamped, so it overshoots and settles like a
        // lens hunting; manual focus is critically damped and goes straight there.
        var position = lensPosition
        var velocity = lensVelocity
        var remaining = elapsed
        while remaining > 0 {
            let step = min(remaining, 1.0 / 120)
            velocity += (stiffness * (target - position) - damping * velocity) * step
            position += velocity * step
            remaining -= step
        }
        let settled = abs(target - position) < 0.002 && abs(velocity) < 0.02
        if settled {
            position = target
            velocity = 0
            if case .autoOnce = focusRequest {
                focusHold = true
            }
        }
        lensPosition = min(max(position, 0), 1)
        lensVelocity = velocity
        focusAdjusting = !settled
    }

    /// Where autofocus lands: on the street, unless the focus range setting keeps the lens from reaching it.
    private var autofocusTarget: Double {
        let range: FocusRange = deviceOptions?.focusRange ?? FocusRange.none
        switch range {
        case .none: return SimulatedSpec.subjectLensPosition
        case .near: return min(SimulatedSpec.subjectLensPosition, 0.42)
        case .far: return max(SimulatedSpec.subjectLensPosition, 0.4)
        }
    }

    /// A tap makes autofocus search again: the lens swings away and comes back.
    private func nudgeFocus() {
        lensVelocity += lensPosition > 0.5 ? -0.9 : 0.9
    }

    private func advanceWhiteBalance(_ elapsed: Double, now: CFTimeInterval) {
        let settling = now < whiteBalanceSettleUntil
        // A stack shoots every frame with the same white balance.
        guard stackJob == nil else {
            whiteBalanceAdjusting = false
            return
        }
        let target: (mired: Double, tint: Double)
        let rate: Double
        let tolerance: Double
        switch whiteBalanceRequest {
        case .auto:
            guard let meter else {
                whiteBalanceAdjusting = settling
                return
            }
            target = (1e6 / meter.autoKelvin, meter.autoTint)
            rate = 2.5
            tolerance = 4
        case .locked:
            whiteBalanceAdjusting = settling
            return
        case .temperature(let kelvin, let tint):
            // The range the real device conversion accepts, which white balance brackets reach past the dial's ends.
            let k = clamped(kelvin, 1000...40_000, fallback: SyntheticScene.referenceKelvin)
            target = (1e6 / k, clamped(tint, WhiteBalanceMath.tintRange, fallback: 0))
            // Locked gains take effect within a few frames; white balance brackets wait only a fifth of a second.
            rate = 30
            tolerance = 1
        case .grayWorld:
            if grayWorldTarget == nil, let meter {
                grayWorldTarget = (1e6 / meter.grayWorldKelvin, meter.grayWorldTint)
            }
            guard let goal = grayWorldTarget else {
                whiteBalanceAdjusting = true
                return
            }
            target = goal
            rate = 10
            tolerance = 1
        }
        let blend = 1 - exp(-rate * elapsed)
        mired += (target.mired - mired) * blend
        tint += (target.tint - tint) * blend
        let moving = abs(target.mired - mired) > tolerance || abs(target.tint - tint) > tolerance / 2
        whiteBalanceAdjusting = moving || settling
    }

    // MARK: - Publishing

    private func publishCapabilities(force: Bool = false) {
        let capabilities = lens.capabilities(maxAutoSeconds: exposureRequest.maxAutoSeconds, video: videoSettings)
        guard force || capabilities != publishedCapabilities else { return }
        publishedCapabilities = capabilities
        delegate?.cameraBackend(self, didUpdateCapabilities: capabilities)
    }

    private func publishReadings() {
        let readings = LiveReadings(
            exposureSeconds: exposure.seconds,
            iso: exposure.iso,
            aperture: exposure.aperture,
            bias: bias,
            meterOffset: min(max(meterOffset(for: exposure) ?? 0, -8), 8),
            lensPosition: lensPosition,
            kelvin: 1e6 / mired,
            tint: tint,
            zoomFactor: zoomFactor,
            displayZoom: zoomFactor * lens.info.relativeZoom,
            isAdjustingFocus: focusAdjusting,
            isAdjustingExposure: exposureAdjusting,
            isAdjustingWhiteBalance: whiteBalanceAdjusting,
            pressure: .nominal,
            lensSmudged: false
        )
        guard SimulatedReadings.changedMeaningfully(from: publishedReadings, to: readings) else { return }
        publishedReadings = readings
        delegate?.cameraBackend(self, didUpdateReadings: readings)
    }
}

/// Non-finite values take `fallback`: they say nothing about where in the range the caller meant.
private func clamped(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}

// MARK: - Specification

/// The pretend hardware and the simulator's pacing. Kept outside the main-actor class so the queues can read it.
private enum SimulatedSpec {
    static let previewSize = (width: 768, height: 1024)
    static let photoScale = 2
    static let stackSize = (width: 384, height: 512)
    static let frameInterval = 1.0 / 30
    /// Shutters at least this long slow the preview down to one frame per exposure.
    static let slowShutter = 0.25
    static let analysisInterval = 0.1
    static let exposureStepInterval = 0.1
    static let readingsInterval = 0.1
    static let durationInterval = 0.25
    /// How early a periodic job may run, to absorb display link jitter.
    static let tickSlack = 0.004
    static let shutterRange: ClosedRange<Double> = (1.0 / 16000)...1
    static let biasRange: ClosedRange<Double> = -8...8
    static let zoomRange: ClosedRange<Double> = 1...10
    /// What the device reports as activeMaxExposureDuration when nobody set it.
    static let defaultAutoExposureLimit = 1.0 / 3
    static let maxBracketCount = 5
    static let maxWhiteBalanceGain = 4.0
    /// Side of the smallest exposure rect of interest, as a share of the frame: about 40 of the meter's samples.
    static let smallestMeteringRect = 0.1
    static let zoomRampRate = 6.0
    /// Lens position at which the street is sharp.
    static let subjectLensPosition = 0.62
    static let defocusPerPosition = 0.034
    static let maxDefocus = 0.06
    /// Optical stabilization the simulated auto exposure trusts when it picks a handheld shutter.
    static let stabilizationStops = 1.5
    /// Long frames of a stack take at most this long, so a 30 s exposure is done in a few seconds.
    static let maxWallSecondsPerStackFrame = 0.2
    /// Metered light product above which auto flash fires; the night street is always past it.
    static let flashThresholdProduct = 8.0
    static let torchStrength = 0.6
    static let movieFrameRate = 30.0
    static let lensSwitchNanoseconds: UInt64 = 120_000_000

    static func clampedZoom(_ factor: Double) -> Double {
        guard factor.isFinite else { return zoomRange.lowerBound }
        return min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
    }
}

// MARK: - Lenses

/// One pretend physical camera of an iPhone 18 Pro.
private struct SimulatedLens {
    let info: LensInfo
    let isoRange: ClosedRange<Double>
    let apertureRange: ClosedRange<Double>
    let apertureStops: [Double]
    let minimumFocusDistance: Int
    let photoDimensions: [PixelSize]
    let hasFlash: Bool
    let supportsBayerRAW: Bool
    let supportsDepth: Bool
    let correctsDistortion: Bool
    /// Depth of field: a longer lens blurs more for the same focus error.
    let defocusScale: Double

    var isVariableAperture: Bool {
        apertureRange.upperBound > apertureRange.lowerBound * 1.01
    }

    // No 24 MP: the real backend keeps it out because AVFoundation only delivers it through deferred photos.
    private static let twelve = PixelSize(width: 4032, height: 3024)
    private static let fortyEight = PixelSize(width: 8064, height: 6048)

    static let ultraWide = SimulatedLens(
        info: LensInfo(id: "simulated.back.ultrawide", kind: .ultraWide, name: "Back Ultra Wide Camera",
                       equivalentFocalLength: 13, relativeZoom: 0.5, aperture: 2.2),
        isoRange: 50...6400, apertureRange: 2.2...2.2, apertureStops: [], minimumFocusDistance: 20,
        photoDimensions: [twelve, fortyEight], hasFlash: true, supportsBayerRAW: true, supportsDepth: false,
        correctsDistortion: true, defocusScale: 0.45
    )

    static let wide = SimulatedLens(
        info: LensInfo(id: "simulated.back.wide", kind: .wide, name: "Back Camera",
                       equivalentFocalLength: 24, relativeZoom: 1, aperture: 1.48),
        isoRange: 50...6400, apertureRange: 1.48...4.0, apertureStops: [1.48, 1.8, 2.8, 4.0], minimumFocusDistance: 120,
        photoDimensions: [twelve, fortyEight], hasFlash: true, supportsBayerRAW: true, supportsDepth: true,
        correctsDistortion: false, defocusScale: 1
    )

    static let telephoto = SimulatedLens(
        info: LensInfo(id: "simulated.back.telephoto", kind: .telephoto, name: "Back Telephoto Camera",
                       equivalentFocalLength: 100, relativeZoom: 4, aperture: 2.8),
        isoRange: 50...6400, apertureRange: 2.8...2.8, apertureStops: [], minimumFocusDistance: 900,
        photoDimensions: [twelve, fortyEight], hasFlash: true, supportsBayerRAW: true, supportsDepth: false,
        correctsDistortion: false, defocusScale: 1.7
    )

    static let front = SimulatedLens(
        info: LensInfo(id: "simulated.front", kind: .front, name: "Front Camera",
                       equivalentFocalLength: 23, relativeZoom: 1, aperture: 1.9),
        isoRange: 32...2304, apertureRange: 1.9...1.9, apertureStops: [], minimumFocusDistance: 200,
        photoDimensions: [twelve], hasFlash: false, supportsBayerRAW: false, supportsDepth: true,
        correctsDistortion: true, defocusScale: 0.5
    )

    /// Back cameras by focal length, then the front camera.
    static let catalog: [SimulatedLens] = [ultraWide, wide, telephoto, front]

    /// One button per back lens at 1x, the main camera's 2x crop, and the front camera; ascending, the back camera
    /// first when two show the same zoom.
    static let presets: [LensPreset] = {
        var back = catalog.filter { !$0.info.isFront }.map {
            LensPreset(lensID: $0.info.id, zoomFactor: 1, displayZoom: $0.info.relativeZoom)
        }
        back.append(LensPreset(lensID: wide.info.id, zoomFactor: 2, displayZoom: 2 * wide.info.relativeZoom))
        back.sort { $0.displayZoom < $1.displayZoom }
        let fronts = catalog.filter { $0.info.isFront }.map {
            LensPreset(lensID: $0.info.id, zoomFactor: 1, displayZoom: 1)
        }
        return (back + fronts).enumerated().sorted { a, b in
            a.element.displayZoom != b.element.displayZoom ? a.element.displayZoom < b.element.displayZoom : a.offset < b.offset
        }.map(\.element)
    }()

    func ranges(maxAutoSeconds: Double?) -> ExposureRanges {
        ExposureRanges(seconds: SimulatedSpec.shutterRange, iso: isoRange, aperture: apertureRange,
                       maxAutoSeconds: maxAutoSeconds ?? SimulatedSpec.defaultAutoExposureLimit)
    }

    /// Where auto exposure starts: the scene's correct exposure, split the way the program line splits it.
    func startingExposure(zoom: Double, maxAutoSeconds: Double?) -> ExposureValues {
        let ranges = ranges(maxAutoSeconds: maxAutoSeconds)
        let handheld = ExposureMath.handheldLimit(equivalentFocalLength: info.equivalentFocalLength * zoom,
                                                  stabilizationStops: SimulatedSpec.stabilizationStops)
        let split = ProgramLine.split(product: SyntheticScene.referenceProduct, aperture: info.aperture, ranges: ranges,
                                      handheldLimit: handheld)
        return ranges.clamp(ExposureValues(seconds: split.seconds, iso: split.iso, aperture: info.aperture))
    }

    /// Horizontal field of view of a 4:3 sensor with this 35 mm equivalent focal length.
    private var fieldOfView: Double {
        let halfWidth = 43.2666 / 2 / (1 + 9.0 / 16).squareRoot()
        return 2 * atan(halfWidth / info.equivalentFocalLength) * 180 / .pi
    }

    /// Photo, 4K HDR with Log, and high frame rate 1080p.
    var formats: [FormatDescriptor] {
        let largest = photoDimensions.max()?.pixelCount ?? Self.twelve.pixelCount
        let shutter = SimulatedSpec.shutterRange
        func format(_ index: Int, _ width: Int, _ height: Int, fps: Double, pixelFormat: String, tenBit: Bool,
                    binned: Bool, photoPixels: Int) -> FormatDescriptor {
            FormatDescriptor(index: index, width: width, height: height, minFrameRate: 1, maxFrameRate: fps,
                             pixelFormat: pixelFormat, supportsVideoHDR: tenBit, supportsHLG: tenBit, supportsAppleLog: tenBit,
                             supportsAppleLog2: tenBit, isBinned: binned, maxPhotoPixels: photoPixels, fieldOfView: fieldOfView,
                             minISO: isoRange.lowerBound, maxISO: isoRange.upperBound,
                             minExposure: shutter.lowerBound, maxExposure: shutter.upperBound)
        }
        return [
            format(0, 4032, 3024, fps: 30, pixelFormat: "420f", tenBit: false, binned: false, photoPixels: largest),
            format(1, 3840, 2160, fps: 60, pixelFormat: "x420", tenBit: true, binned: false, photoPixels: 3840 * 2160),
            format(2, 1920, 1080, fps: 240, pixelFormat: "420v", tenBit: false, binned: true, photoPixels: 1920 * 1080),
        ]
    }

    /// The photo format, or the video format for the settings and what it records. Chosen the way the real camera
    /// chooses, so settings this lens can't record fall back to the same nearest format.
    func activeFormat(for video: VideoSettings?, among formats: [FormatDescriptor]) -> (format: FormatDescriptor?, video: ActiveVideoFormat?) {
        guard let video else { return (formats.first, nil) }
        let requested = VideoRequirement(resolution: video.resolution, frameRate: video.frameRate, colorMode: video.colorMode)
        guard let chosen = FormatSelector.nearestVideoFormat(for: requested, among: formats) else { return (formats.first, nil) }
        return (chosen.format, ActiveVideoFormat(requested: requested, recorded: chosen.recorded))
    }

    func capabilities(maxAutoSeconds: Double?, video: VideoSettings?) -> CameraCapabilities {
        let formats = self.formats
        let active = activeFormat(for: video, among: formats)
        return CameraCapabilities(
            lens: info,
            formatSummary: active.format.map(SimulatedText.formatSummary) ?? "",
            exposure: ranges(maxAutoSeconds: maxAutoSeconds),
            biasRange: SimulatedSpec.biasRange,
            supportsCustomExposure: true,
            supportsVariableAperture: isVariableAperture,
            apertureStops: isVariableAperture ? apertureStops : [],
            nativePriority: PrioritySupport(shutter: true, iso: true, aperture: true),
            supportsManualFocus: true,
            supportsFocusPointOfInterest: true,
            supportsExposurePointOfInterest: true,
            supportsMeteringArea: true,
            minimumFocusDistance: minimumFocusDistance,
            supportsCustomWhiteBalance: true,
            maxWhiteBalanceGain: SimulatedSpec.maxWhiteBalanceGain,
            zoomRange: SimulatedSpec.zoomRange,
            hasFlash: hasFlash,
            hasTorch: hasFlash,
            photoDimensions: photoDimensions.sorted(),
            heifSupported: true,
            rawSupported: supportsBayerRAW,
            proRAWSupported: true,
            livePhotoSupported: true,
            depthSupported: supportsDepth,
            constantColorSupported: hasFlash,
            shutterSoundSuppressionSupported: true,
            maxBracketCount: SimulatedSpec.maxBracketCount,
            maxProcessing: .maximum,
            lowLightBoostSupported: false,
            geometricCorrectionSupported: correctsDistortion,
            contentAwareCorrectionSupported: correctsDistortion,
            globalToneMappingSupported: true,
            videoHDRSupported: true,
            focusRangeRestrictionSupported: true,
            smoothFocusSupported: true,
            faceDrivenAutoExposureSupported: true,
            faceDrivenAutoFocusSupported: true,
            smudgeDetectionSupported: !info.isFront,
            continuousAFTrackingSupported: true,
            lowLightVideoNoiseReductionSupported: true,
            formats: formats,
            videoCodecs: VideoCodecChoice.allCases,
            stabilizationModes: [.off, .standard, .cinematic, .cinematicExtended],
            colorModes: VideoColorMode.allCases,
            activeVideo: active.video
        )
    }
}

// MARK: - Text

private enum SimulatedText {
    /// "4032×3024 · 1–30 fps", like the real camera's summary.
    static func formatSummary(_ format: FormatDescriptor) -> String {
        let size = Formatting.resolution(width: format.width, height: format.height)
        let low = Int(format.minFrameRate.rounded())
        let high = Int(format.maxFrameRate.rounded())
        let span = low == high ? "\(high) fps" : "\(low)\u{2013}\(high) fps"
        return "\(size) \u{00B7} \(span)"
    }

    /// "1/8 · ISO 480 · ƒ/1.48 · 24 mm".
    static func photoSummary(_ values: ExposureValues, focalLength: Double) -> String {
        let exposure = MediaWriter.summary(exposureSeconds: values.seconds, iso: values.iso, aperture: values.aperture)
        guard focalLength.isFinite, focalLength > 0 else { return exposure }
        let lens = LensMath.focalLengthLabel(focalLength)
        return exposure.isEmpty ? lens : exposure + " \u{00B7} " + lens
    }

    /// "768×1024 · 30 fps · H.264 · 0:12".
    static func movieSummary(width: Int, height: Int, duration: Double) -> String {
        [
            Formatting.resolution(width: width, height: height),
            Formatting.frameRate(SimulatedSpec.movieFrameRate),
            VideoCodecChoice.h264.title,
            Formatting.clock(duration),
        ].joined(separator: " \u{00B7} ")
    }
}

// MARK: - Readings

private enum SimulatedReadings {
    /// The HUD only needs changes it can show; publishing every jitter would redraw SwiftUI for nothing.
    static func changedMeaningfully(from old: LiveReadings?, to new: LiveReadings) -> Bool {
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
}

// MARK: - Analysis

private struct SimulatedAnalysisJob: Sendable {
    var options: AnalysisOptions
    var stripePhase: Int
}

/// Histogram and overlays from a rendered frame. The frame is already oriented and mirrored as displayed, so the
/// overlay needs no turning.
private enum SimulatedAnalysis {
    static let stripePeriod = 6
    private static let overlayLongSide = 480
    private static let histogramSamples = 40_000.0

    static func analyze(_ frame: SceneFrame, _ job: SimulatedAnalysisJob) -> AnalysisFrame {
        frame.withPlane { plane in
            // Always measured: the clipping warning needs the stats even with the histogram hidden.
            let samplesStep = Int((Double(plane.width) * Double(plane.height) / histogramSamples).squareRoot().rounded())
            let (histogram, stats) = HistogramComputer.compute(bgra: plane, step: max(1, samplesStep))
            let options = job.options
            let overlayOptions = OverlayOptions(
                zebraThreshold: options.zebraThreshold,
                stripePeriod: stripePeriod,
                stripePhase: job.stripePhase,
                peakingThreshold: options.peakingThreshold,
                peakingColor: options.peakingColor.rgba,
                falseColor: options.falseColor
            )
            var overlay: CGImage?
            if !overlayOptions.isEmpty {
                let longSide = max(plane.width, plane.height)
                let factor = max(1, (longSide + overlayLongSide - 1) / overlayLongSide)
                let luma = LumaDownsampler.downsampleBGRA(plane, factor: factor)
                let bitmap = OverlayRenderer.render(luma, options: overlayOptions)
                // Nothing marked: no image, so the preview composites nothing.
                if !bitmap.isFullyTransparent {
                    overlay = FrameAnalyzer.makeImage(bitmap)
                }
            }
            return AnalysisFrame(histogram: histogram, stats: stats, overlay: overlay)
        }
    }
}

// MARK: - Frame clock

/// CADisplayLink needs an Objective-C target and keeps it alive. This one holds the camera weakly, and ends the
/// link once the camera is gone.
@MainActor
private final class SimulatedFrameClock: NSObject {
    private weak var camera: SimulatedCamera?

    init(camera: SimulatedCamera) {
        self.camera = camera
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let camera else {
            link.invalidate()
            return
        }
        camera.displayLinkFired()
    }
}

// MARK: - Photo job

private struct SimulatedPhoto: @unchecked Sendable {
    var encoded: EncodedImage
    var thumbnail: CGImage?
    var summary: String
}

/// Everything a photo needs from the main actor, so the capture queue renders and encodes on its own.
private struct SimulatedPhotoJob: Sendable {
    var shots: [SceneShot]
    var exposures: [ExposureValues]
    var format: ProcessedFormat
    var quality: Double
    var aspect: AspectRatio
    var location: LocationStamp?
    var lensName: String
    var focalLength: Double
    var date: Date

    /// Capture queue. Draws each exposure at twice the preview size, crops it to the aspect ratio and encodes it.
    func render(with scene: SyntheticScene) throws -> [SimulatedPhoto] {
        // Full-size buffers are large; the next photo draws them again.
        defer { scene.releaseCaches() }
        var photos: [SimulatedPhoto] = []
        for (shot, values) in zip(shots, exposures) {
            guard let frame = scene.renderFrame(shot, metered: false) else {
                throw CameraError.captureFailed("The simulated scene couldn't be drawn.")
            }
            let image = Self.cropped(frame.image, to: aspect)
            let metadata = CaptureMetadata(exposureSeconds: values.seconds, iso: values.iso, aperture: values.aperture,
                                           focalLength35mm: focalLength, lensModel: lensName,
                                           comment: "Open Shutter simulated camera", date: date, location: location)
            let encoded = try MediaWriter.encode(image, as: format, quality: quality, metadata: metadata)
            photos.append(SimulatedPhoto(encoded: encoded,
                                         thumbnail: encoded.thumbnail ?? MediaWriter.thumbnail(of: image, maxPixelSize: 400),
                                         summary: SimulatedText.photoSummary(values, focalLength: focalLength)))
        }
        return photos
    }

    private static func cropped(_ image: CGImage, to aspect: AspectRatio) -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = aspect.centeredCrop(width: Double(image.width), height: Double(image.height))
        let rect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height).integral.intersection(bounds)
        guard rect.width >= 1, rect.height >= 1, rect != bounds else { return image }
        return image.cropping(to: rect) ?? image
    }
}

// MARK: - Stack job

/// One night or long exposure in progress. Frames are drawn on `queue`; finish and cancel may come from anywhere.
private final class SimulatedStackJob: @unchecked Sendable {
    struct Outcome: @unchecked Sendable {
        var encoded: EncodedImage
        var thumbnail: CGImage?
        var summary: String
        var date: Date
    }

    private let request: StackRequest
    private let plan: StackPlan
    private let firstShot: SceneShot
    private let scene: SyntheticScene
    private let queue: DispatchQueue
    private let flipsResult: Bool
    private let lensName: String
    private let focalLength: Double
    private let progress: @MainActor (StackProgress) -> Void
    /// Scene time from one frame to the next: frames can't come faster than the preview's 30 fps.
    private let frameSpacing: Double
    /// Real time per frame, but a long frame takes at most 0.2 s so long exposures don't keep you waiting.
    private let wallSpacing: Double

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var finishRequested = false
    private var isCancelled = false
    private var isDone = false

    // Owned by `queue`.
    private var accumulator: StackAccumulator
    private var framesAccumulated = 0
    private var wallStart: CFTimeInterval = 0
    private var lastProgress: CFTimeInterval = 0

    init(request: StackRequest, plan: StackPlan, firstShot: SceneShot, scene: SyntheticScene, queue: DispatchQueue,
         flipsResult: Bool, lensName: String, focalLength: Double, progress: @escaping @MainActor (StackProgress) -> Void) {
        self.request = request
        self.plan = plan
        self.firstShot = firstShot
        self.scene = scene
        self.queue = queue
        self.flipsResult = flipsResult
        self.lensName = lensName
        self.focalLength = focalLength
        self.progress = progress
        accumulator = StackAccumulator(width: scene.width, height: scene.height, channels: 4, blend: plan.blend)
        frameSpacing = max(plan.frameSeconds, SimulatedSpec.frameInterval)
        wallSpacing = min(frameSpacing, SimulatedSpec.maxWallSecondsPerStackFrame)
    }

    func start(_ continuation: CheckedContinuation<Outcome, Error>) {
        let cancelled = lock.withLock { () -> Bool in
            self.continuation = continuation
            return isCancelled
        }
        guard !cancelled else {
            complete(.failure(CameraError.cancelled))
            return
        }
        queue.async {
            self.wallStart = CACurrentMediaTime()
            self.lastProgress = self.wallStart
            self.captureFrame(0)
        }
    }

    /// Bulb release or the Stop button: keep the frames so far.
    func requestFinish() {
        lock.withLock { finishRequested = true }
    }

    func cancel() {
        lock.withLock { isCancelled = true }
        complete(.failure(CameraError.cancelled))
    }

    private func captureFrame(_ index: Int) {
        let (finishing, cancelled) = lock.withLock { (finishRequested, isCancelled) }
        if cancelled {
            scene.releaseCaches()
            return
        }
        // A real shutter that opened exposes at least one frame, so a quick bulb tap still makes a picture.
        if finishing && index > 0 {
            finish()
            return
        }
        var shot = firstShot
        shot.time = firstShot.time + Double(index) * frameSpacing + plan.frameSeconds
        // Frames shorter than their spacing leave gaps, so their moving lights stay separate streaks.
        shot.isBackToBack = frameSpacing <= plan.frameSeconds
        // A frame that fails to draw is skipped, like a dropped camera frame.
        if let frame = scene.renderLinear(shot) {
            accumulator.add(frame)
            framesAccumulated += 1
        }
        // The plan's frame count also caps a bulb exposure, so a forgotten one ends by itself.
        if index + 1 >= plan.frameCount {
            finish()
            return
        }
        let now = CACurrentMediaTime()
        if now - lastProgress >= 0.15 {
            lastProgress = now
            report(now: now, image: nil)
        }
        let next = wallStart + Double(index + 1) * wallSpacing
        queue.asyncAfter(deadline: .now() + max(0, next - now)) {
            self.captureFrame(index + 1)
        }
    }

    private func finish() {
        defer { scene.releaseCaches() }
        let frames = framesAccumulated
        guard frames > 0 else {
            complete(.failure(CameraError.captureFailed("No frames were captured.")))
            return
        }
        // Discard can land just after an early finish; the frames are not wanted then, so skip the encode.
        if lock.withLock({ isCancelled }) {
            complete(.failure(CameraError.cancelled))
            return
        }
        var captured = plan
        // A bulb or an early stop exposed fewer frames than planned; the metadata says what really happened.
        captured.frameCount = frames
        let result = accumulator.result(scale: captured.outputScale(framesAccumulated: frames))
        report(now: CACurrentMediaTime(), image: result)
        guard let image = SyntheticScene.displayImage(fromLinear: result, upscale: Double(SimulatedSpec.photoScale),
                                                      mirrored: flipsResult, aspect: request.aspect) else {
            complete(.failure(CameraError.captureFailed("The stacked image couldn't be drawn.")))
            return
        }
        let date = Date()
        let metadata = CaptureMetadata(
            exposureSeconds: captured.effectiveExposureSeconds,
            iso: captured.iso,
            aperture: captured.aperture,
            focalLength35mm: focalLength,
            lensModel: lensName,
            comment: "Stacked \(frames) \u{00D7} \(ShutterSpeed(seconds: captured.frameSeconds).label), \(captured.blend.title)",
            date: date,
            location: request.location
        )
        let format: ProcessedFormat = request.processedFormat == .none ? .heif : request.processedFormat
        do {
            let encoded = try MediaWriter.encode(image, as: format, quality: request.quality, metadata: metadata)
            let summary = MediaWriter.summary(exposureSeconds: captured.effectiveExposureSeconds, iso: captured.iso,
                                              aperture: captured.aperture)
            complete(.success(Outcome(encoded: encoded,
                                      thumbnail: encoded.thumbnail ?? MediaWriter.thumbnail(of: image, maxPixelSize: 400),
                                      summary: summary, date: date)))
        } catch {
            complete(.failure(error))
        }
    }

    /// The running result for the overlay, oriented like the preview because the frames are.
    private func report(now: CFTimeInterval, image: FloatImage?) {
        let current = image ?? accumulator.result(scale: plan.outputScale(framesAccumulated: framesAccumulated))
        let update = StackProgress(
            framesCaptured: framesAccumulated,
            framesPlanned: request.isBulb ? 0 : plan.frameCount,
            elapsed: now - wallStart,
            estimatedTotal: request.isBulb ? nil : Double(plan.frameCount) * wallSpacing,
            preview: SyntheticScene.displayImage(fromLinear: current)
        )
        let deliver = progress
        lock.withLock {
            guard !isDone else { return }
            // Sent while holding the lock, so it is queued before any result: the main queue is first in, first out.
            DispatchQueue.main.async {
                deliver(update)
            }
        }
    }

    private func complete(_ result: Result<Outcome, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Outcome, Error>? in
            isDone = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        guard let pending else { return }
        // Through the main queue too, behind any progress already sent, so a late preview can't follow the result.
        DispatchQueue.main.async {
            pending.resume(with: result)
        }
    }
}

// MARK: - Movie writer

/// Writes preview frames to an H.264 movie. Everything after init runs on `queue`.
private final class SimulatedMovieWriter: @unchecked Sendable {
    struct Movie: @unchecked Sendable {
        var url: URL
        var thumbnail: CGImage?
        var summary: String
        var date: Date
    }

    private let queue: DispatchQueue
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private var lastTime = CMTime.invalid
    private var frames = 0
    private var lastImage: CGImage?
    private var isClosed = false

    /// Call on `queue`: creating the file and starting the writer touch the disk.
    init(width: Int, height: Int, queue: DispatchQueue) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenShutter-\(UUID().uuidString).mov")
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw CameraError.captureFailed("The movie file couldn't be created.")
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        // Adding an input the writer can't take raises an exception, so both checks come first.
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CameraError.unsupported("H.264 recording")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CameraError.unsupported("H.264 recording")
        }
        // The adaptor has to exist before writing starts.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw CameraError.captureFailed(writer.error?.localizedDescription ?? "The movie couldn't start.")
        }
        writer.startSession(atSourceTime: .zero)
        self.queue = queue
        self.url = url
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.width = width
        self.height = height
    }

    /// `seconds` since the recording started.
    func append(_ frame: SceneFrame, at seconds: Double) {
        queue.async {
            self.write(frame, at: seconds)
        }
    }

    func finish() async throws -> Movie {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Movie, Error>) in
            queue.async {
                self.close(continuation)
            }
        }
    }

    /// Throws the file away; for a recording that started after the camera stopped.
    func discard() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.url)
        }
    }

    private func write(_ frame: SceneFrame, at seconds: Double) {
        guard !isClosed, seconds.isFinite, seconds >= 0, frame.width == width, frame.height == height else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // Timestamps must keep increasing, and appending while the input is busy raises an exception.
        guard !lastTime.isValid || CMTimeCompare(time, lastTime) > 0, writer.status == .writing,
              input.isReadyForMoreMediaData, let buffer = pixelBuffer(for: frame) else { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            lastTime = time
            frames += 1
            lastImage = frame.image
        }
    }

    private func pixelBuffer(for frame: SceneFrame) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        }
        if created == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        }
        guard let buffer = created, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let rowLength = min(frame.bytesPerRow, destinationRowBytes, width * 4)
        let rows = min(height, CVPixelBufferGetHeight(buffer), frame.height)
        withExtendedLifetime(frame.pixels) {
            let source = frame.pixels.bytes
            for row in 0..<rows {
                memcpy(destination + row * destinationRowBytes, source + row * frame.bytesPerRow, rowLength)
            }
        }
        return buffer
    }

    private func close(_ continuation: CheckedContinuation<Movie, Error>) {
        guard !isClosed else {
            continuation.resume(throwing: CameraError.captureFailed("The movie was already closed."))
            return
        }
        isClosed = true
        // finishWriting raises unless the writer is writing; an empty movie isn't worth keeping either way.
        guard frames > 0, writer.status == .writing else {
            let reason = frames == 0 ? "No frames were recorded." : (writer.error?.localizedDescription ?? "The movie couldn't be written.")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            continuation.resume(throwing: CameraError.captureFailed(reason))
            return
        }
        // Frames carry no duration of their own. Without an end time the session would end where the last frame
        // starts, which drops that frame and leaves a one-frame clip empty.
        let end = CMTimeAdd(lastTime, CMTime(seconds: 1 / SimulatedSpec.movieFrameRate, preferredTimescale: 600))
        writer.endSession(atSourceTime: end)
        let summary = SimulatedText.movieSummary(width: width, height: height, duration: end.seconds)
        let thumbnail = lastImage.flatMap { MediaWriter.thumbnail(of: $0, maxPixelSize: 400) }
        let url = self.url
        writer.finishWriting {
            if self.writer.status == .completed {
                continuation.resume(returning: Movie(url: url, thumbnail: thumbnail, summary: summary, date: Date()))
            } else {
                try? FileManager.default.removeItem(at: url)
                let reason = self.writer.error?.localizedDescription ?? "The movie couldn't be written."
                continuation.resume(throwing: CameraError.captureFailed(reason))
            }
        }
    }
}
