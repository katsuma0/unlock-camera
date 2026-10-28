import SwiftUI

@main
struct OpenShutterApp: App {
    @State private var model = CameraModel(backend: OpenShutterApp.makeBackend())

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
