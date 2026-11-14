import Foundation
import Photos
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CameraCore

/// The app's assets that one fetch found, newest first, hidden ones left out. PHFetchResult has no Collection
/// conformance, and copying thousands of assets into an array up front would load every one of them at once; this
/// keeps the fetch result and reads an asset only when a cell or a page asks for it.
struct AssetList: RandomAccessCollection, Sendable {
    let result: PHFetchResult<PHAsset>
    /// Local identifiers in list order, read once while fetching: cheap ids for the grid and the pager, which would
    /// otherwise load every asset to compare them.
    let identifiers: [String]
    /// Where each listed asset sits in `result`. A hidden asset has no entry.
    private let positions: [Int]
    private let indexByID: [String: Int]

    var startIndex: Int { 0 }
    var endIndex: Int { positions.count }

    subscript(position: Int) -> PHAsset {
        result.object(at: positions[position])
    }

    func index(of id: String) -> Int? {
        indexByID[id]
    }

    func asset(id: String) -> PHAsset? {
        index(of: id).map { self[$0] }
    }

    /// Reads every asset of `result` once, so it belongs off the main thread.
    init(result: PHFetchResult<PHAsset>) {
        var positions: [Int] = []
        var identifiers: [String] = []
        positions.reserveCapacity(result.count)
        identifiers.reserveCapacity(result.count)
        for position in 0..<result.count {
            let asset = result.object(at: position)
            // A second guard after the fetch option: a photo moved to the Hidden album, which Face ID locks, must
            // never show up here.
            guard !asset.isHidden else { continue }
            positions.append(position)
            identifiers.append(asset.localIdentifier)
        }
        self.result = result
        self.positions = positions
        self.identifiers = identifiers
        indexByID = Dictionary(identifiers.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
    }

    /// The assets behind `identifiers` that the app may see now, newest first by creation date.
    static func fetch(_ identifiers: [String]) -> AssetList {
        let options = PHFetchOptions()
        // A fetch by identifier includes hidden assets unless the options say otherwise.
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return AssetList(result: PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options))
    }
}

/// One step of a request: a better version of what was asked for, or how far an iCloud download has come.
enum AssetUpdate<Value: Sendable>: Sendable {
    case value(Value, isFinal: Bool)
    case progress(Double)
}

/// PhotoKit requests for the gallery, each as a stream that ends when the request does. A request whose reading task
/// is cancelled (a cell scrolled away, a page closed) is cancelled with it. PhotoKit may then never call its handler,
/// so a plain continuation could wait forever; a stream simply ends.
enum AssetRequests {
    /// A square-ish picture for a grid cell or the camera's thumbnail. A quick low-quality one may come first.
    static func thumbnail(for asset: PHAsset, pixelSide: CGFloat,
                          manager: PHImageManager) -> AsyncStream<AssetUpdate<UIImage>> {
        image(for: asset, pixelSize: CGSize(width: pixelSide, height: pixelSide), contentMode: .aspectFill,
              manager: manager, reportsProgress: false)
    }

    /// A picture that fills the viewer, fitted inside `pixelSize`, with the progress of an iCloud download.
    static func fullImage(for asset: PHAsset, pixelSize: CGSize,
                          manager: PHImageManager) -> AsyncStream<AssetUpdate<UIImage>> {
        image(for: asset, pixelSize: pixelSize, contentMode: .aspectFit, manager: manager, reportsProgress: true)
    }

    static func livePhoto(for asset: PHAsset, pixelSize: CGSize,
                          manager: PHImageManager) -> AsyncStream<AssetUpdate<PHLivePhoto>> {
        stream(start: { continuation in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.progressHandler = { progress, _, _, _ in
                continuation.yield(.progress(progress))
            }
            return manager.requestLivePhoto(for: asset, targetSize: pixelSize, contentMode: .aspectFit,
                                            options: options) { livePhoto, info in
                let isFinal = !isDegraded(info)
                if let livePhoto {
                    continuation.yield(.value(livePhoto, isFinal: isFinal))
                }
                if isFinal { continuation.finish() }
            }
        }, cancel: { manager.cancelImageRequest($0) })
    }

    /// Something to play a video with. iCloud videos stream.
    static func playerItem(for asset: PHAsset, manager: PHImageManager) async -> AVPlayerItem? {
        await first(of: stream(start: { (continuation: AsyncStream<AVPlayerItem>.Continuation) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            return manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                if let item {
                    continuation.yield(item)
                }
                continuation.finish()
            }
        }, cancel: { manager.cancelImageRequest($0) }))
    }

    /// Writes the asset as it looks now (with its edits) into `folder` and returns the file, for sharing. A Live
    /// Photo goes as its still.
    static func exportCopy(of asset: PHAsset, into folder: URL, manager: PHImageManager) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = baseName(for: asset)
        if asset.mediaType == .video {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                    ?? resources.first(where: { $0.type == .video }) else {
                throw ExportError.unavailable
            }
            let ending = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "mov"
            let url = folder.appendingPathComponent(name + "." + ending.uppercased())
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            return url
        }
        let stream = stream(start: { (continuation: AsyncStream<ImageFile>.Continuation) in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            return manager.requestImageDataAndOrientation(for: asset, options: options) { data, type, _, _ in
                if let data {
                    continuation.yield(ImageFile(data: data, type: type))
                }
                continuation.finish()
            }
        }, cancel: { manager.cancelImageRequest($0) })
        guard let file = await first(of: stream) else { throw ExportError.unavailable }
        let ending = file.type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
        let url = folder.appendingPathComponent(name + "." + ending.uppercased())
        try file.data.write(to: url, options: .atomic)
        return url
    }

    /// The app's own XMP fields in the asset's camera file, such as a stack's frame count and frame time. Read from
    /// the original resource: an edit's rendered file doesn't carry them.
    static func appValues(of asset: PHAsset) async -> [ShotXMP.Field: String] {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) else { return [:] }
        let collected = DataCollector()
        let manager = PHAssetResourceManager.default()
        let stream = stream(start: { (continuation: AsyncStream<Data>.Continuation) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            return manager.requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                collected.append(chunk)
            }, completionHandler: { error in
                if error == nil {
                    continuation.yield(collected.data)
                }
                continuation.finish()
            })
        }, cancel: { manager.cancelDataRequest($0) })
        guard let data = await first(of: stream) else { return [:] }
        return appValues(in: data)
    }

    static func appValues(in data: Data) -> [ShotXMP.Field: String] {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
        else { return [:] }
        var values: [ShotXMP.Field: String] = [:]
        // Matched by namespace, not by prefix: a file edited elsewhere may name the namespace differently.
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            if let namespace = CGImageMetadataTagCopyNamespace(tag) as String?, namespace == ShotXMP.namespace,
               let name = CGImageMetadataTagCopyName(tag) as String?, let field = ShotXMP.Field(rawValue: name),
               let value = CGImageMetadataTagCopyValue(tag) as? String {
                values[field] = value
            }
            return true
        }
        return values
    }

    // MARK: - Helpers

    enum ExportError: Error {
        case unavailable
    }

    private struct ImageFile: Sendable {
        let data: Data
        let type: String?
    }

    /// Chunks of a resource's data, which arrive one after another on PhotoKit's queue.
    private final class DataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ chunk: Data) {
            lock.withLock { buffer.append(chunk) }
        }

        var data: Data {
            lock.withLock { buffer }
        }
    }

    private static func image(for asset: PHAsset, pixelSize: CGSize, contentMode: PHImageContentMode,
                              manager: PHImageManager, reportsProgress: Bool) -> AsyncStream<AssetUpdate<UIImage>> {
        stream(start: { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            // "Optimize iPhone Storage" keeps only small versions on the phone.
            options.isNetworkAccessAllowed = true
            if reportsProgress {
                options.progressHandler = { progress, _, _, _ in
                    continuation.yield(.progress(progress))
                }
            }
            return manager.requestImage(for: asset, targetSize: pixelSize, contentMode: contentMode,
                                        options: options) { image, info in
                let isFinal = !isDegraded(info)
                if let image {
                    continuation.yield(.value(image, isFinal: isFinal))
                }
                // The last call, with or without a picture: an error and a cancellation also end here.
                if isFinal { continuation.finish() }
            }
        }, cancel: { manager.cancelImageRequest($0) })
    }

    /// `start` makes the request and returns its id. The handler may run before `start` returns; finishing then
    /// leaves nothing to cancel.
    private static func stream<Element>(
        start: (AsyncStream<Element>.Continuation) -> Int32,
        cancel: @escaping @Sendable (Int32) -> Void
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let requestID = start(continuation)
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    cancel(requestID)
                }
            }
        }
    }

    private static func first<Element>(of stream: AsyncStream<Element>) async -> Element? {
        for await element in stream {
            return element
        }
        return nil
    }

    private static func isDegraded(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
    }

    /// "OpenShutter_20261114_221345", like the names the camera gives its files.
    private static func baseName(for asset: PHAsset) -> String {
        let clock = ExifFormat.exifDate(asset.creationDate ?? Date(), timeZone: .current)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "_")
        return PhotoLibrary.filenamePrefix + clock
    }
}
