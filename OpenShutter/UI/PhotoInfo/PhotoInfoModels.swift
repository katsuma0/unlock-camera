import Foundation
import Observation
import Photos
import PhotosUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers
import CameraCore

// The state behind the photo info pages. Reading and cleaning run off the main actor; these keep what the pages show
// and own the temporary copies, which go when the page that made them goes.

/// One picture's info page: the file read, the metadata removal and where the clean copy went.
@MainActor
@Observable
final class PhotoInfoModel {
    enum Phase {
        /// `progress` is how far an iCloud original has downloaded, when Photos says.
        case loading(progress: Double?)
        case ready(PhotoInfo)
        case unavailable(String)
    }

    enum CopyState {
        case idle
        case working
        case ready(MetadataStripper.CleanCopy)
        case failed(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    let source: PhotoInfoSource
    private(set) var phase: Phase = .loading(progress: nil)
    /// A library photo's files: edited, original, RAW, as it has them.
    private(set) var versions: [PhotoInfoAssetFile.Version] = []
    private(set) var version: PhotoInfoAssetFile.Version?
    /// Changes when another version is picked, so the page reads again.
    private(set) var generation = 0
    var mode: StripMode = .default {
        didSet {
            if mode != oldValue { resetCopy() }
        }
    }
    private(set) var copy: CopyState = .idle
    private(set) var save: SaveState = .idle
    /// Save to Files writes the clean copy's bytes, read off the main actor first.
    private(set) var exportData: Data?
    var isExporting = false

    @ObservationIgnored private let workspace = PhotoInfoWorkspace()
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var fileFolder: URL?
    @ObservationIgnored private var copyFolder: URL?

    /// Does nothing else: SwiftUI makes one each time the page's parent redraws and keeps only the first.
    init(source: PhotoInfoSource) {
        self.source = source
    }

    var isCopying: Bool {
        if case .working = copy { return true }
        return false
    }

    func select(_ version: PhotoInfoAssetFile.Version?) {
        guard let version, version != self.version, !isCopying else { return }
        self.version = version
        generation += 1
    }

    /// Reads the picture, first writing a library photo's file out of Photos.
    func load() async {
        // Not awaited: the sweep leaves folders in use alone, so the read needn't wait for it.
        Task.detached(priority: .utility) { PhotoInfoFiles.sweep() }
        switch source {
        case .file(let url):
            await read(url)
        case .asset(let asset):
            await loadAsset(asset)
        }
    }

    private func loadAsset(_ asset: PHAsset) async {
        guard asset.mediaType == .image else {
            phase = .unavailable("Photo info reads pictures. It can't read videos yet.")
            return
        }
        if versions.isEmpty {
            versions = PhotoInfoAssetFile.versions(of: asset)
            version = versions.first
        }
        guard let version else {
            phase = .unavailable("This photo's file isn't available.")
            return
        }
        phase = .loading(progress: nil)
        resetCopy()
        if let folder = fileFolder {
            workspace.discard(folder)
            fileFolder = nil
        }
        do {
            let folder = try workspace.makeFolder()
            fileFolder = folder
            let url = try await PhotoInfoAssetFile.export(version, of: asset, into: folder) { [weak self] value in
                Task { @MainActor in self?.downloaded(value) }
            }
            // A version picked meanwhile has its own read under way.
            guard !Task.isCancelled else { return }
            await read(url)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unavailable("The photo couldn't be loaded from your library.")
        }
    }

    private func downloaded(_ value: Double) {
        guard case .loading = phase, value.isFinite else { return }
        phase = .loading(progress: min(max(value, 0), 1))
    }

    private func read(_ url: URL) async {
        fileURL = url
        do {
            let info = try await Task.detached(priority: .userInitiated) {
                try PhotoInfoReader.read(url: url)
            }.value
            guard !Task.isCancelled else { return }
            phase = .ready(info)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unavailable("This file can't be read.")
        }
    }

    /// Writes the clean copy. One at a time: a large photo decodes to hundreds of megabytes.
    func makeCopy() async {
        guard let url = fileURL, case .ready(let info) = phase, !isCopying else { return }
        resetCopy()
        copy = .working
        let mode = self.mode
        // Under Everything the name goes too: camera files, this app's among them, are often named after the second
        // they were taken. Location only keeps it, since that copy keeps the date anyway.
        let name = mode == .everything ? "Photo" : info.fileName
        do {
            let folder = try workspace.makeFolder()
            copyFolder = folder
            let clean = try await Task.detached(priority: .userInitiated) {
                try MetadataStripper.cleanCopy(of: url, mode: mode, into: folder, originalName: name)
            }.value
            copy = .ready(clean)
            Haptics.success()
        } catch let failure as MetadataStripper.Failure {
            copy = .failed(failure.errorDescription ?? "The copy couldn't be cleaned.")
        } catch {
            copy = .failed("The copy couldn't be made.")
        }
    }

    /// Adds the clean copy to Photos as a new photo. It is not one the app took, so the gallery doesn't list it.
    func saveToPhotos() async {
        guard case .ready(let clean) = copy, save != .saving, save != .saved else { return }
        save = .saving
        do {
            let url = clean.url
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            _ = try await PhotoLibrary.savePhoto(primary: data, primaryType: clean.typeIdentifier, raw: nil,
                                                 livePhotoMovie: nil, location: nil)
            save = .saved
            Haptics.success()
        } catch {
            save = .failed(error.localizedDescription)
        }
    }

    func prepareExport() async {
        guard case .ready(let clean) = copy, !isExporting else { return }
        let url = clean.url
        exportData = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        isExporting = exportData != nil
    }

    func finishExport() {
        isExporting = false
        exportData = nil
    }

    private func resetCopy() {
        if let folder = copyFolder {
            workspace.discard(folder)
            copyFolder = nil
        }
        copy = .idle
        save = .idle
        exportData = nil
    }
}

/// The page that picks a photo from Photos or Files.
@MainActor
@Observable
final class PhotoInfoTool {
    struct OpenedFile: Identifiable, Hashable {
        let id = UUID()
        let url: URL

        var name: String { url.lastPathComponent }
    }

    enum Status: Equatable {
        case idle
        case opening
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The file whose info page is open; setting it opens the page.
    var shown: OpenedFile?
    /// The last file opened, offered again on the page.
    private(set) var recent: OpenedFile?
    /// The last photo picked, while it also has a RAW file to show.
    private(set) var rawSource: PhotosPickerItem?

    @ObservationIgnored private let workspace = PhotoInfoWorkspace()
    /// The copies of the current pick. A new pick replaces them, so a long session keeps one photo's files only.
    @ObservationIgnored private var pickFolders: [URL] = []

    var isOpening: Bool { status == .opening }

    func open(_ item: PhotosPickerItem) async {
        guard !isOpening else { return }
        status = .opening
        do {
            guard let file = try await item.loadTransferable(type: PickedImageFile.self) else {
                status = .failed("This photo couldn't be opened.")
                return
            }
            replacePick(with: file.folder)
            let types = item.supportedContentTypes
            let hasRAW = types.contains(where: PhotoInfoFiles.isRAW)
            let hasOther = types.contains { $0.conforms(to: .image) && !PhotoInfoFiles.isRAW($0) }
            // Offered only when the file that came isn't the RAW one already.
            let pickedRAW = UTType(filenameExtension: file.url.pathExtension).map(PhotoInfoFiles.isRAW) ?? false
            rawSource = hasRAW && hasOther && !pickedRAW ? item : nil
            show(file.url)
        } catch {
            status = .failed("This photo couldn't be opened.")
        }
    }

    func openRAW() async {
        guard let item = rawSource, !isOpening else { return }
        status = .opening
        do {
            guard let file = try await item.loadTransferable(type: PickedRawFile.self) else {
                status = .failed("The RAW file couldn't be opened.")
                return
            }
            workspace.adopt(file.folder)
            pickFolders.append(file.folder)
            show(file.url, keepsRecent: true)
        } catch {
            status = .failed("The RAW file couldn't be opened.")
        }
    }

    func open(_ result: Result<[URL], Error>) async {
        guard !isOpening else { return }
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure = result { status = .failed("This file couldn't be opened.") }
            return
        }
        status = .opening
        do {
            let copy = try await Task.detached(priority: .userInitiated) {
                try PhotoInfoFiles.importCopy(ofPicked: url)
            }.value
            replacePick(with: copy.deletingLastPathComponent())
            rawSource = nil
            show(copy)
        } catch {
            status = .failed("This file couldn't be opened.")
        }
    }

    /// Clears copies an earlier run left behind, such as one that crashed with a page open.
    func sweep() async {
        await Task.detached(priority: .utility) { PhotoInfoFiles.sweep() }.value
    }

    private func replacePick(with folder: URL) {
        for old in pickFolders {
            workspace.discard(old)
        }
        workspace.adopt(folder)
        pickFolders = [folder]
    }

    private func show(_ url: URL, keepsRecent: Bool = false) {
        let file = OpenedFile(url: url)
        if !keepsRecent { recent = file }
        status = .idle
        shown = file
    }
}
