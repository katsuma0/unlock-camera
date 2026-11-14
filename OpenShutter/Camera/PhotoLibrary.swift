import Foundation
import Photos
import CoreLocation
import UniformTypeIdentifiers
import CameraCore

enum PhotoLibrary {
    /// Every file of a capture is named "OpenShutter_20261114_221345_A1B2.HEIC" in Photos, so the app's own photos
    /// can be told apart from the rest of the library later.
    static let filenamePrefix = "OpenShutter_"

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
    /// `livePhotoMovie` is moved into the library. `creationDate` is when the shot was taken (a stack's first frame),
    /// so Photos sorts it there; nil lets Photos use the file's own date. `isCapture` names the files with the app's
    /// prefix; leave it off for anything the app didn't take. Returns the asset's localIdentifier.
    static func savePhoto(primary: Data, primaryType: String, raw: Data?, livePhotoMovie: URL?, location: GeoTag?,
                          creationDate: Date? = nil, isCapture: Bool = false) async throws -> String? {
        guard await ensureAddAccess() else { throw accessDenied }
        let identifier = IdentifierBox()
        let clLocation = location.flatMap(makeLocation)
        let name = isCapture ? baseName(for: creationDate ?? Date()) : nil
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: primary, options: resourceOptions(type: primaryType, name: name))
                if let raw {
                    request.addResource(with: .alternatePhoto, data: raw,
                                        options: resourceOptions(type: rawTypeIdentifier, name: name))
                }
                if let livePhotoMovie {
                    let movieOptions = resourceOptions(type: UTType.quickTimeMovie.identifier, name: name)
                    movieOptions.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: livePhotoMovie, options: movieOptions)
                }
                request.location = clLocation
                if let creationDate {
                    request.creationDate = creationDate
                }
                identifier.set(request.placeholderForCreatedAsset?.localIdentifier)
            }
        } catch {
            throw CameraError.saveFailed(error.localizedDescription)
        }
        return identifier.value
    }

    /// Moves the movie at `url` into the library. `creationDate` and `isCapture` as for photos.
    static func saveVideo(at url: URL, location: GeoTag?, creationDate: Date? = nil,
                          isCapture: Bool = false) async throws -> String? {
        guard await ensureAddAccess() else { throw accessDenied }
        let identifier = IdentifierBox()
        let clLocation = location.flatMap(makeLocation)
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.quickTimeMovie.identifier
        let name = isCapture ? baseName(for: creationDate ?? Date()) : nil
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = resourceOptions(type: type, name: name)
                // A long recording is gigabytes; moving avoids a second copy on a phone that may be nearly full.
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
                request.location = clLocation
                if let creationDate {
                    request.creationDate = creationDate
                }
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

    /// `name` without an extension; each resource adds its own, as Apple's IMG_0001.HEIC and IMG_0001.MOV pair up.
    private static func resourceOptions(type: String, name: String?) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = type
        if let name {
            let ending = fileExtension(for: type)
            options.originalFilename = ending.isEmpty ? name : name + "." + ending
        }
        return options
    }

    /// "OpenShutter_20261114_221345_A1B2": the local time of the shot, then a few characters that keep the frames
    /// of one bracket, all taken in the same second, apart.
    private static func baseName(for date: Date) -> String {
        // ExifFormat builds the text from calendar fields, so no formatter is shared between the capture queues.
        let clock = ExifFormat.exifDate(date, timeZone: .current)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "_")
        let tag = UUID().uuidString.prefix(4)
        return filenamePrefix + clock + "_" + tag
    }

    /// Upper case, as Apple's Camera names its files.
    private static func fileExtension(for type: String) -> String {
        guard let uti = UTType(type) else { return "" }
        if uti.conforms(to: .heic) || uti.conforms(to: .heif) { return "HEIC" }
        if uti.conforms(to: .jpeg) { return "JPG" }
        if uti.identifier == rawTypeIdentifier || uti.conforms(to: .rawImage) { return "DNG" }
        if uti.conforms(to: .quickTimeMovie) { return "MOV" }
        return uti.preferredFilenameExtension?.uppercased() ?? ""
    }

    private static func makeLocation(_ tag: GeoTag) -> CLLocation? {
        let coordinate = CLLocationCoordinate2D(latitude: tag.latitude, longitude: tag.longitude)
        guard tag.hasValidCoordinates, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let horizontal = tag.horizontalAccuracy.isFinite ? tag.horizontalAccuracy : -1
        // A negative vertical accuracy tells Photos the altitude is unknown, which is what Core Location said.
        let altitude = tag.hasValidAltitude ? tag.altitude : 0
        let vertical = tag.hasValidAltitude ? tag.verticalAccuracy : -1
        let course = tag.course.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? -1
        let speed = tag.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? -1
        return CLLocation(coordinate: coordinate, altitude: altitude, horizontalAccuracy: horizontal,
                          verticalAccuracy: vertical, course: course, speed: speed, timestamp: tag.timestamp)
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
