import Foundation
import Photos
import CameraCore

/// The photos and videos taken with the app, across launches. Stub: the gallery builder fills it in.
@MainActor
@Observable
final class CaptureLibrary: NSObject {
    /// Keeps what was just saved, so the gallery can list it later.
    func record(_ results: [CaptureResult]) {}

    /// Keeps an edited copy saved next to `original`.
    func recordCopy(id: String, of original: PHAsset) {}
}
