import Foundation
import QuartzCore
import CameraCore

/// The camera as the model sees it. CameraService drives real hardware through AVFoundation;
/// SimulatedCamera renders a synthetic scene so the whole app runs in the iOS Simulator.
///
/// Every method is called on the main actor and returns quickly. Implementations do their
/// AVFoundation work on their own serial queue and report back through `delegate` on the main actor.
@MainActor
protocol CameraBackend: AnyObject {
    var delegate: CameraBackendDelegate? { get set }
    var isSimulated: Bool { get }

    /// Physical cameras, back cameras first, ordered by focal length. Valid after `start`.
    var lenses: [LensInfo] { get }
    /// Lens picker buttons for the back cameras plus the front camera, ascending display zoom.
    var lensPresets: [LensPreset] { get }
    var activeLensID: String? { get }

    func authorizationStatus() -> CameraAuthorization
    func requestAuthorization() async -> CameraAuthorization

    /// Configures the session for `settings` (mode, lens, zoom) and starts it.
    func start(settings: CameraSettings) async
    func stop()

    /// The layer that shows the live image. The UI adds it to its view hierarchy once and keeps it sized
    /// to the preview view. Real backend: an AVCaptureVideoPreviewLayer with .resizeAspect gravity.
    func makePreviewLayer() -> CALayer
    /// Converts a point in the preview layer's coordinates to a device point of interest (0...1).
    func devicePoint(fromLayerPoint point: CGPoint) -> CGPoint?
    /// Inverse of devicePoint(fromLayerPoint:), for drawing the focus reticle where the device is focusing.
    func layerPoint(fromDevicePoint point: CGPoint) -> CGPoint?

    /// Switches lens if needed, then sets the zoom factor. Rebuilds capabilities and re-applies the last
    /// exposure, focus, white balance and device options requests.
    func select(_ preset: LensPreset) async
    /// Device zoom factor on the active lens, clamped to capabilities.zoomRange.
    func setZoomFactor(_ factor: Double, animated: Bool)

    func apply(exposure: ExposureRequest)
    func apply(focus: FocusRequest)
    func apply(whiteBalance: WhiteBalanceRequest)
    func apply(options: DeviceOptions)
    /// Tap to focus / meter at a device point (0...1). Uses the focus and exposure modes from the last requests.
    func setPointOfInterest(_ devicePoint: CGPoint, focus: Bool, exposure: Bool)
    /// nil turns the torch off.
    func setTorch(level: Double?)
    func setAnalysis(_ options: AnalysisOptions)

    /// One photo, or a bracket. Returns one result per saved asset.
    func capturePhoto(_ request: PhotoRequest) async throws -> [CaptureResult]
    /// Night mode or long exposure: captures and merges frames, saves the result.
    func captureStack(_ request: StackRequest, progress: @escaping @MainActor (StackProgress) -> Void) async throws -> CaptureResult
    /// Stops a running stack and saves what it has (bulb release, "Stop" button).
    func finishStackEarly()
    /// Stops a running stack and throws CameraError.cancelled from captureStack.
    func cancelStack()

    /// Picks the best format for `settings`, adds audio if wanted. Call when entering video mode
    /// or when a video setting changes.
    func configureForVideo(_ settings: VideoSettings) async
    /// Restores the photo configuration when leaving video mode.
    func configureForPhoto() async
    func startRecording(_ request: VideoRequest) async throws
    func stopRecording() async throws -> CaptureResult

    /// iOS 18 Camera Control (the side button on iPhone 16 and later). No-op where unsupported.
    func configureCameraControls(_ state: CameraControlState)
}

@MainActor
protocol CameraBackendDelegate: AnyObject {
    func cameraBackend(_ backend: CameraBackend, didChangeState state: SessionState)
    func cameraBackend(_ backend: CameraBackend, didUpdateCapabilities capabilities: CameraCapabilities)
    func cameraBackend(_ backend: CameraBackend, didUpdateReadings readings: LiveReadings)
    func cameraBackend(_ backend: CameraBackend, didProduceAnalysis frame: AnalysisFrame)
    /// The moment the shutter fires, once per capture, for the flash animation and haptic. The model also frees
    /// the shutter for the next photo here while this one is still processed and saved.
    func cameraBackendWillCapture(_ backend: CameraBackend)
    func cameraBackend(_ backend: CameraBackend, didUpdateRecordingDuration duration: TimeInterval)
    func cameraBackend(_ backend: CameraBackend, didReceiveControl change: CameraControlChange)
    /// The Camera Control overlay is taking the screen; hide busy UI while it shows.
    func cameraBackend(_ backend: CameraBackend, controlsFullscreenDidChange isFullscreen: Bool)
}
