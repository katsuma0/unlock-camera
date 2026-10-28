import Foundation
import Photos
import CoreLocation
import UniformTypeIdentifiers
import CameraCore

enum PhotoLibrary {
    /// Add-only access is all the app needs to save. Returns true when saving is allowed.
    static func ensureAddAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// Saves one photo asset. `primary` is the processed HEIF/JPEG, or the DNG when shooting RAW only.
    /// `raw` is the paired DNG when shooting RAW plus HEIF/JPEG (stored as the alternate resource).
    /// `livePhotoMovie` is moved into the library. Returns the asset's localIdentifier.
    static func savePhoto(primary: Data, primaryType: String, raw: Data?, livePhotoMovie: URL?, location: LocationStamp?) async throws -> String? {
        guard await ensureAddAccess() else { throw accessDenied }
        let identifier = IdentifierBox()
        let clLocation = location.flatMap(makeLocation)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: primary, options: resourceOptions(type: primaryType))
                if let raw {
                    request.addResource(with: .alternatePhoto, data: raw, options: resourceOptions(type: rawTypeIdentifier))
                }
                if let livePhotoMovie {
                    let movieOptions = resourceOptions(type: UTType.quickTimeMovie.identifier)
                    movieOptions.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: livePhotoMovie, options: movieOptions)
                }
                request.location = clLocation
                identifier.set(request.placeholderForCreatedAsset?.localIdentifier)
            }
        } catch {
            throw CameraError.saveFailed(error.localizedDescription)
        }
        return identifier.value
    }

    /// Moves the movie at `url` into the library.
    static func saveVideo(at url: URL, location: LocationStamp?) async throws -> String? {
        guard await ensureAddAccess() else { throw accessDenied }
        let identifier = IdentifierBox()
        let clLocation = location.flatMap(makeLocation)
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.quickTimeMovie.identifier
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = resourceOptions(type: type)
                // A long recording is gigabytes; moving avoids a second copy on a phone that may be nearly full.
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
                request.location = clLocation
                identifier.set(request.placeholderForCreatedAsset?.localIdentifier)
            }
        } catch {
            throw CameraError.saveFailed(error.localizedDescription)
        }
        return identifier.value
    }

    // MARK: - Helpers

    /// UTType.rawImage is the generic camera RAW type; Photos wants the DNG type for the alternate resource.
    private static let rawTypeIdentifier = "com.adobe.raw-image"

    private static var accessDenied: CameraError {
        .saveFailed("Allow Open Shutter to add photos in Settings.")
    }

    private static func resourceOptions(type: String) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = type
        return options
    }

    private static func makeLocation(_ stamp: LocationStamp) -> CLLocation? {
        let coordinate = CLLocationCoordinate2D(latitude: stamp.latitude, longitude: stamp.longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let altitude = stamp.altitude.isFinite ? stamp.altitude : 0
        let horizontal = stamp.horizontalAccuracy.isFinite ? stamp.horizontalAccuracy : -1
        // The stamp keeps no vertical accuracy. A negative value would tell Photos the altitude is invalid,
        // so the horizontal figure stands in when the altitude is a real reading.
        let vertical = stamp.altitude.isFinite ? max(horizontal, 0) : -1
        return CLLocation(coordinate: coordinate, altitude: altitude, horizontalAccuracy: horizontal,
                          verticalAccuracy: vertical, timestamp: stamp.timestamp)
    }
}

/// The change block runs on a Photos queue; the identifier it creates is read after the await.
private final class IdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? { lock.withLock { stored } }

    func set(_ identifier: String?) {
        lock.withLock { stored = identifier }
    }
}
