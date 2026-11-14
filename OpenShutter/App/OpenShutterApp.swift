import SwiftUI

@main
struct OpenShutterApp: App {
    @State private var model: CameraModel

    init() {
        // The model copies the look settings out as it loads them, so the hook comes first: the first frame then
        // already has the person's accent. The model leaves the views' types alone and calls through this.
        CameraModel.onLookChange = { appearance, accessibility in
            AppearanceStore.shared.update(appearance: appearance, accessibility: accessibility)
        }
        _model = State(initialValue: CameraModel(backend: OpenShutterApp.makeBackend()))
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model)
                .preferredColorScheme(.dark)
        }
    }

    /// The Simulator has no camera, so it gets the synthetic one. Launch with "-simulatedCamera" to try
    /// the synthetic camera on a phone too.
    @MainActor
    static func makeBackend() -> CameraBackend {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        let forced = ProcessInfo.processInfo.arguments.contains("-simulatedCamera")
        // No device lookup here: it wakes the camera server on the main thread before the first frame, and
        // CameraService already reports a missing camera from its own queue.
        if isSimulator || forced {
            return SimulatedCamera()
        }
        return CameraService()
    }
}
