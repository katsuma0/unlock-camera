import Foundation
import Photos
import UniformTypeIdentifiers
import CoreTransferable

// The photo info tool works on copies. A picture picked from Photos or Files, or a library photo's file, is copied
// into the app's temporary folder before ImageIO opens it, and the clean copies are written next to it. They are
// copies of personal photos, so each one sits in a folder of its own that goes away with the page that made it.

enum PhotoInfoFiles {
    /// tmp/PhotoInfo. iOS also empties tmp by itself while the app isn't running.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhotoInfo", isDirectory: true)
    }

    /// A new, empty folder, left alone by `sweep()` until `remove(_:)`.
    static func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Held before it exists, so a sweep running at the same moment can't take it.
        registry.insert(folder.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            registry.remove(folder.lastPathComponent)
            throw error
        }
        return folder
    }

    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        registry.remove(folder.lastPathComponent)
    }

    /// Removes the folders nothing holds: an import that finished after its page closed, or a run that ended in a
    /// crash.
    static func sweep() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where !registry.contains(name) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// A copy of `file` in a new folder, under its own name. A picker's file can be the original itself, so it is
    /// copied, never moved.
    static func importCopy(of file: URL, named name: String? = nil) throws -> URL {
        let folder = try makeFolder()
        do {
            let copy = folder.appendingPathComponent(safeName(name ?? file.lastPathComponent), isDirectory: false)
            try FileManager.default.copyItem(at: file, to: copy)
            return copy
        } catch {
            remove(folder)
            throw error
        }
    }

    /// A file the Files picker returned. It may sit in another app's storage or in iCloud Drive without being
    /// downloaded, so it is read through a file coordinator, which waits for the download. Blocks; call it off the
    /// main actor.
    static func importCopy(ofPicked url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try importCopy(of: readable, named: url.lastPathComponent) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// A name the file system takes, keeping the extension ImageIO reads the type hint from.
    static func safeName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "Photo" + trimmed : trimmed
    }

    /// Camera RAW types and DNG, which UTType doesn't count as camera RAW.
    static func isRAW(_ type: UTType) -> Bool {
        type.conforms(to: .rawImage) || type.conforms(to: .dng)
    }

    static func isRAW(typeIdentifier: String) -> Bool {
        UTType(typeIdentifier).map(isRAW) ?? false
    }

    private static let registry = FolderRegistry()
}

/// The folder names in use. Imports finish on the picker's queue and pages close on the main one.
private final class FolderRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()

    func insert(_ name: String) {
        lock.withLock { _ = names.insert(name) }
    }

    func remove(_ name: String) {
        lock.withLock { _ = names.remove(name) }
    }

    func contains(_ name: String) -> Bool {
        lock.withLock { names.contains(name) }
    }
}

/// The folders one page made. They are deleted when the page goes, however it goes.
final class PhotoInfoWorkspace: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [URL] = []

    func makeFolder() throws -> URL {
        let folder = try PhotoInfoFiles.makeFolder()
        lock.withLock { folders.append(folder) }
        return folder
    }

    /// Takes over the folder an import made, so it goes with this page.
    func adopt(_ folder: URL) {
        lock.withLock { folders.append(folder) }
    }

    /// Deletes one folder now, such as a clean copy that a newer one replaced.
    func discard(_ folder: URL) {
        lock.withLock { folders.removeAll { $0 == folder } }
        PhotoInfoFiles.remove(folder)
    }

    deinit {
        for folder in folders {
            PhotoInfoFiles.remove(folder)
        }
    }
}

// MARK: - Photos picker

/// A picture from the photo picker. With the picker's `.current` encoding the file arrives as Photos stores it, so
/// nothing is converted and its metadata comes along.
struct PickedImageFile: Transferable {
    let url: URL

    var folder: URL { url.deletingLastPathComponent() }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedImageFile(url: try PhotoInfoFiles.importCopy(of: received.file))
        }
    }
}

/// The RAW file of a RAW plus HEIF or JPEG photo, which the picker offers as a second representation.
struct PickedRawFile: Transferable {
    let url: URL

    var folder: URL { url.deletingLastPathComponent() }

    static var transferRepresentation: some TransferRepresentation {
        // A DNG is not a "camera RAW" type to UTType, so both are asked for.
        FileRepresentation(importedContentType: .dng) { received in
            PickedRawFile(url: try PhotoInfoFiles.importCopy(of: received.file))
        }
        FileRepresentation(importedContentType: .rawImage) { received in
            PickedRawFile(url: try PhotoInfoFiles.importCopy(of: received.file))
        }
    }
}

// MARK: - Library photos

/// The files of a library photo that the photo info tool can read.
enum PhotoInfoAssetFile {
    enum Version: String, CaseIterable, Identifiable, Sendable {
        /// Photos' render of an edited photo.
        case edited
        /// The file as it was saved.
        case original
        /// The RAW file of a RAW plus HEIF or JPEG photo.
        case raw

        var id: String { rawValue }

        var title: String {
            switch self {
            case .edited: return "Edited"
            case .original: return "Original"
            case .raw: return "RAW"
            }
        }

        fileprivate var resourceType: PHAssetResourceType {
            switch self {
            case .edited: return .fullSizePhoto
            case .original: return .photo
            case .raw: return .alternatePhoto
            }
        }
    }

    /// The versions the asset has, edited first: that is the picture the gallery shows and a share sends.
    static func versions(of asset: PHAsset) -> [Version] {
        let types = Set(PHAssetResource.assetResources(for: asset).map(\.type))
        return Version.allCases.filter { types.contains($0.resourceType) }
    }

    /// Writes the version's file into `folder` and returns it. An original kept only in iCloud is downloaded;
    /// `progress` reports how far, on any queue.
    static func export(_ version: Version, of asset: PHAsset, into folder: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == version.resourceType }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = folder.appendingPathComponent(PhotoInfoFiles.safeName(fileName(of: resource)), isDirectory: false)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options)
        return target
    }

    /// The name the file had when it was saved ("IMG_0001.HEIC"), or "Photo" with its type's extension.
    private static func fileName(of resource: PHAssetResource) -> String {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return named(resource.filename) ?? fallbackName(resource)
        }
        #endif
        return named(resource.originalFilename) ?? fallbackName(resource)
    }

    private static func named(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    private static func fallbackName(_ resource: PHAssetResource) -> String {
        let ending = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
        return ending.map { "Photo." + $0 } ?? "Photo"
    }
}
