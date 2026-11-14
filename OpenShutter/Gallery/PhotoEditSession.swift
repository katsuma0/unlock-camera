import Foundation
import Photos
import CoreImage
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import os
import CameraCore

/// One photo open in the editor. It asks Photos for the photo, with the original and this app's earlier edit when
/// there is one; keeps the recipe the controls change; redraws the preview off the main actor, the newest recipe
/// winning while a dial turns; and saves, either into the photo as an edit Photos can take off again, or as a new
/// photo beside it.
@MainActor
@Observable
final class PhotoEditSession {
    enum Status: Equatable {
        /// Waiting for Photos. `progress` runs 0...1 while the original comes down from iCloud.
        case loading(progress: Double?)
        case ready
        /// Nothing to edit; the text says why.
        case unavailable(String)
    }

    enum Activity: Equatable {
        case saving
        case savingCopy
        case reverting
    }

    let asset: PHAsset
    /// The photo carries an edit, from here or from Photos, so "Revert to original" applies.
    let canRevert: Bool
    private(set) var status = Status.loading(progress: nil)
    private(set) var activity: Activity?
    /// The edit. The controls write it at dial speed, and each write asks for a new preview.
    var recipe = EditRecipe.identity {
        didSet { recipeChanged(from: oldValue) }
    }
    /// The recipe differs from the one the photo opened with. Stored, so the views that show it don't redraw at every
    /// dial step.
    private(set) var hasChanges = false
    /// The edit at preview size.
    private(set) var preview: UIImage?
    /// The photo without this edit, for the touch and hold comparison.
    private(set) var original: UIImage?
    private(set) var lookPreviews: [EditRecipe.Look: UIImage] = [:]
    /// Live Photos get colors only this round: a crop or a turn would have to reach every frame of the video too.
    private(set) var isLivePhoto: Bool
    /// The full-size photo upright, in pixels, which the crop presets measure.
    private(set) var photoSize = CGSize.zero

    private let library: CaptureLibrary
    @ObservationIgnored private var context: CIContext?
    @ObservationIgnored private var input: PHContentEditingInput?
    @ObservationIgnored private var base: EditRenderer.Preview?
    @ObservationIgnored private var startRecipe = EditRecipe.identity
    @ObservationIgnored private var pendingPreview: EditRecipe?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isClosed = false

    /// Cheap: SwiftUI makes one each time the editor view is built and keeps the first, and nothing starts before
    /// `load()`.
    init(asset: PHAsset, library: CaptureLibrary) {
        self.asset = asset
        self.library = library
        canRevert = asset.hasAdjustments && asset.canPerform(.content)
        isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
    }

    // MARK: - Opening

    /// Opens the photo once. Closing the editor before it is done cancels the request.
    func load() async {
        guard !hasStarted else { return }
        hasStarted = true
        guard Self.isEditable(asset) else {
            status = .unavailable(Self.notEditableText)
            return
        }
        let input: PHContentEditingInput
        do {
            input = try await requestInput()
        } catch {
            if !isClosed, !(error is CancellationError) {
                Self.log.error("No editing input: \(error.localizedDescription, privacy: .public)")
                status = .unavailable(Self.notOpenedText)
            }
            return
        }
        guard !isClosed else { return }
        guard let url = input.fullSizeImageURL else {
            status = .unavailable(Self.notOpenedText)
            return
        }
        let orientation = Self.orientation(of: input)
        let context = makeContext()
        let base = await Task.detached(priority: .userInitiated) {
            EditRenderer.loadPreview(url: url, orientation: orientation, context: context)
        }.value
        guard !isClosed else { return }
        guard let base else {
            status = .unavailable(Self.notOpenedText)
            return
        }
        let live = input.livePhoto != nil
        var restored = EditRecipe.identity
        // Photos hands over the original only with adjustment data this version reads; otherwise the input is the
        // photo as it shows now, and the edit starts from there.
        if let data = input.adjustmentData,
           EditRecipe.canRead(formatIdentifier: data.formatIdentifier, formatVersion: data.formatVersion) {
            restored = EditRecipe.decoded(from: data.data)
        }
        if live {
            restored = restored.colorOnly
        }
        self.input = input
        self.base = base
        isLivePhoto = live
        photoSize = base.photoSize
        let unedited = UIImage(cgImage: base.image)
        original = unedited
        startRecipe = restored
        if restored.isIdentity {
            preview = unedited
        }
        // An earlier edit draws its first preview from here.
        recipe = restored
        status = .ready
        loadLookPreviews(base, context: context)
    }

    /// The editing input, with the original whenever the adjustment data is this app's.
    private func requestInput() async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.canHandleAdjustmentData = { data in
            EditRecipe.canRead(formatIdentifier: data.formatIdentifier, formatVersion: data.formatVersion)
        }
        // With Optimize iPhone Storage the original may be in iCloud only.
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress, _ in
            guard let self else { return }
            Task { @MainActor in self.downloaded(progress) }
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // The preview is decoded from the full-size file, so Photos needn't make a display-size copy as well.
            options.skipsDisplaySizeImage = true
        }
        #endif
        let request = InputRequest(asset: asset)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(options: options, continuation: continuation)
            }.input
        } onCancel: {
            request.cancel()
        }
    }

    private func downloaded(_ progress: Double) {
        guard case .loading = status, progress.isFinite else { return }
        status = .loading(progress: min(max(progress, 0), 1))
    }

    private func loadLookPreviews(_ base: EditRenderer.Preview, context: CIContext) {
        Task { [weak self] in
            let looks = await Task.detached(priority: .utility) {
                EditRenderer.lookPreviews(of: base, context: context)
            }.value
            guard let self, !self.isClosed else { return }
            self.lookPreviews = looks.mapValues { UIImage(cgImage: $0) }
        }
    }

    /// One context per editor: the preview and the save share its caches, and none of it outlives the editor.
    private func makeContext() -> CIContext {
        if let context { return context }
        let made = CIContext(options: [.cacheIntermediates: false, .name: "PhotoEditor"])
        context = made
        return made
    }

    // MARK: - Preview

    private func recipeChanged(from old: EditRecipe) {
        guard recipe != old else { return }
        let changed = recipe != startRecipe
        if hasChanges != changed {
            hasChanges = changed
        }
        schedulePreview()
    }

    /// Renders the newest recipe once the render before it is done, so a dial that moves faster than the renders
    /// skips the steps in between instead of falling behind.
    private func schedulePreview() {
        guard base != nil, !isClosed else { return }
        pendingPreview = recipe
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            await self?.renderPendingPreviews()
        }
    }

    private func renderPendingPreviews() async {
        while !isClosed, let next = pendingPreview, let base, let context {
            pendingPreview = nil
            let image: CGImage?
            if next.isIdentity {
                image = base.image
            } else {
                image = await Task.detached(priority: .userInitiated) {
                    EditRenderer.renderPreview(next, from: base, context: context)
                }.value
            }
            guard !isClosed else { break }
            if let image {
                preview = UIImage(cgImage: image)
            }
        }
        previewTask = nil
    }

    // MARK: - Saving

    /// Saves the edit into the photo. Photos keeps the original and can go back to it at any time. False when it
    /// couldn't be saved; the edit stays open.
    func save() async -> Bool {
        guard let input, status == .ready, activity == nil, asset.canPerform(.content) else { return false }
        activity = .saving
        defer { activity = nil }
        do {
            let output = PHContentEditingOutput(contentEditingInput: input)
            output.adjustmentData = PHAdjustmentData(formatIdentifier: EditRecipe.formatIdentifier,
                                                     formatVersion: EditRecipe.formatVersion,
                                                     data: try recipe.encoded())
            if isLivePhoto {
                try await renderLivePhoto(input, into: output)
            } else {
                try await renderStill(input, into: output)
            }
            let asset = self.asset
            let edit = EditOutput(output: output)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = edit.output
            }
            return true
        } catch {
            Self.log.error("Edit not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Saves the edit as a new photo next to this one, which stays as it was, and lists it in the gallery. A Live
    /// Photo's copy is a still. False when it couldn't be saved.
    func saveCopy() async -> Bool {
        guard let input, let url = input.fullSizeImageURL, let context, status == .ready, activity == nil else {
            return false
        }
        activity = .savingCopy
        defer { activity = nil }
        do {
            let orientation = Self.orientation(of: input)
            let recipe = isLivePhoto ? self.recipe.colorOnly : self.recipe
            let edit = try await Task.detached(priority: .userInitiated) {
                try EditRenderer.encodedEdit(recipe, url: url, orientation: orientation, types: nil,
                                             keepsLivePairing: false, context: context)
            }.value
            let identifier = try await Self.addCopy(edit, of: asset)
            library.recordCopy(id: identifier, of: asset)
            return true
        } catch {
            Self.log.error("Copy not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Takes every edit off the photo, this app's and Photos' alike. Photos needs the original files on the phone
    /// first, so any that are only in iCloud come down. False when it couldn't.
    func revert() async -> Bool {
        guard canRevert, activity == nil, asset.canPerform(.content) else { return false }
        activity = .reverting
        defer { activity = nil }
        do {
            try await Self.downloadOriginals(of: asset)
            let asset = self.asset
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            }
            return true
        } catch {
            Self.log.error("Not reverted: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The editor is going away: stop drawing and let go of the photo's files.
    func close() {
        isClosed = true
        previewTask?.cancel()
        previewTask = nil
        pendingPreview = nil
        input = nil
    }

    private func renderStill(_ input: PHContentEditingInput, into output: PHContentEditingOutput) async throws {
        guard let url = input.fullSizeImageURL, let context else { throw EditRenderer.Failure.unreadable }
        let orientation = Self.orientation(of: input)
        let types = Self.renderTypes(for: output)
        let recipe = self.recipe
        let edit = try await Task.detached(priority: .userInitiated) {
            try EditRenderer.encodedEdit(recipe, url: url, orientation: orientation, types: types,
                                         keepsLivePairing: true, context: context)
        }.value
        let target = try Self.renderedURL(for: edit.type, in: output)
        try await Task.detached(priority: .userInitiated) {
            try edit.data.write(to: target, options: .atomic)
        }.value
    }

    private func renderLivePhoto(_ input: PHContentEditingInput, into output: PHContentEditingOutput) async throws {
        guard let live = PHLivePhotoEditingContext(livePhotoEditingInput: input) else {
            throw EditRenderer.Failure.unreadable
        }
        let colors = recipe.colorOnly
        // Photos calls this for the still and for every video frame, off the main thread.
        live.frameProcessor = { frame, _ in
            EditRenderer.apply(colors, to: frame.image, renderScale: frame.renderScale)
        }
        try await live.saveLivePhoto(to: output, options: nil)
    }

    // MARK: - Helpers

    private static let notEditableText = "This photo can't be edited here."
    private static let notOpenedText = "The photo couldn't be opened."

    private static let log = Logger(subsystem: "ca.katsuma.openshutter", category: "Editor")

    /// Stills and Live Photos. Animated images and looping videos would need a render of their own.
    private static func isEditable(_ asset: PHAsset) -> Bool {
        guard asset.mediaType == .image, asset.canPerform(.content) else { return false }
        switch asset.playbackStyle {
        case .image, .livePhoto: return true
        default: return false
        }
    }

    private static func orientation(of input: PHContentEditingInput) -> CGImagePropertyOrientation {
        CGImagePropertyOrientation(rawValue: UInt32(clamping: input.fullSizeImageOrientation)) ?? .up
    }

    /// HEIF when Photos takes it (the camera's own format, half the size of JPEG), then Photos' default, then JPEG.
    private static func renderTypes(for output: PHContentEditingOutput) -> [UTType] {
        let supported = output.supportedRenderedContentTypes
        var types: [UTType] = []
        if supported.contains(.heic) {
            types.append(.heic)
        }
        if let preferred = output.defaultRenderedContentType, !types.contains(preferred) {
            types.append(preferred)
        }
        if !types.contains(.jpeg) {
            types.append(.jpeg)
        }
        return types
    }

    private static func renderedURL(for type: UTType, in output: PHContentEditingOutput) throws -> URL {
        do {
            return try output.renderedContentURL(for: type)
        } catch {
            // The URL without a type takes JPEG, which every version of Photos reads.
            guard type == .jpeg else { throw error }
            return output.renderedContentURL
        }
    }

    private static func addCopy(_ edit: EditRenderer.Encoded, of original: PHAsset) async throws -> String {
        let name = copyName(for: original.creationDate ?? Date(), type: edit.type)
        let created = CreatedIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = edit.type.identifier
            options.originalFilename = name
            request.addResource(with: .photo, data: edit.data, options: options)
            // Taken when and where the original was, so Photos sorts and maps the copy beside it.
            request.creationDate = original.creationDate
            request.location = original.location
            created.set(request.placeholderForCreatedAsset?.localIdentifier)
        }
        guard let identifier = created.value else { throw CopyFailure.noAsset }
        return identifier
    }

    /// "OpenShutter_20261114_221345_A1B2.HEIC", the name the camera gives its own files, so a copy made here counts
    /// as the app's own too. The time is the original's.
    private static func copyName(for date: Date, type: UTType) -> String {
        let clock = ExifFormat.exifDate(date, timeZone: .current)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "_")
        let tag = UUID().uuidString.prefix(4)
        let ending = type.conforms(to: .jpeg) ? "JPG" : (type.preferredFilenameExtension?.uppercased() ?? "HEIC")
        return PhotoLibrary.filenamePrefix + clock + "_" + tag + "." + ending
    }

    /// The original resources, the ones a revert goes back to. Reading one brings it down from iCloud when needed;
    /// the bytes themselves aren't kept.
    private static func downloadOriginals(of asset: PHAsset) async throws {
        let originals: Set<PHAssetResourceType> = [.photo, .alternatePhoto, .pairedVideo, .video, .audio]
        let manager = PHAssetResourceManager.default()
        for resource in PHAssetResource.assetResources(for: asset) where originals.contains(resource.type) {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.requestData(for: resource, options: options, dataReceivedHandler: { _ in }) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private enum CopyFailure: Error {
    case noAsset
}

/// The output travels into Photos' change block, which runs on a Photos queue after the editor has finished with it.
private struct EditOutput: @unchecked Sendable {
    let output: PHContentEditingOutput
}

/// One editing input request that resumes its continuation exactly once: with the input, with the failure, or with a
/// cancellation when the editor closes first, after which Photos may never call back.
private final class InputRequest: @unchecked Sendable {
    /// The input crosses from Photos' queue to the main actor, which is the only place it is used afterwards.
    struct Delivered: @unchecked Sendable {
        let input: PHContentEditingInput
    }

    private let asset: PHAsset
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Delivered, Error>?
    private var requestID: PHContentEditingInputRequestID?
    private var isCancelled = false

    init(asset: PHAsset) {
        self.asset = asset
    }

    func start(options: PHContentEditingInputRequestOptions, continuation: CheckedContinuation<Delivered, Error>) {
        let proceeds: Bool = lock.withLock {
            guard !isCancelled else { return false }
            self.continuation = continuation
            return true
        }
        guard proceeds else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let id = asset.requestContentEditingInput(with: options) { [self] input, info in
            if let input {
                finish(.success(Delivered(input: input)))
            } else {
                finish(.failure(Self.failure(from: info)))
            }
        }
        let cancelsNow: Bool = lock.withLock {
            requestID = id
            return isCancelled
        }
        if cancelsNow {
            asset.cancelContentEditingInputRequest(id)
        }
    }

    func cancel() {
        let id: PHContentEditingInputRequestID? = lock.withLock {
            isCancelled = true
            return requestID
        }
        if let id {
            asset.cancelContentEditingInputRequest(id)
        }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Delivered, Error>) {
        let pending: CheckedContinuation<Delivered, Error>? = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }

    private static func failure(from info: [AnyHashable: Any]) -> Error {
        if (info[PHContentEditingInputCancelledKey] as? NSNumber)?.boolValue == true {
            return CancellationError()
        }
        return info[PHContentEditingInputErrorKey] as? Error ?? EditRenderer.Failure.unreadable
    }
}

/// The change block runs on a Photos queue; the identifier it creates is read after the await.
private final class CreatedIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? { lock.withLock { stored } }

    func set(_ identifier: String?) {
        lock.withLock { stored = identifier }
    }
}
