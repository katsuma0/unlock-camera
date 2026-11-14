import Foundation
import Photos
import UIKit
import os
import CameraCore

/// What the gallery may read of the photo library. Saving needs only add access, which the camera asks for at the
/// first shot; reading back is asked for when the person opens the gallery, and never before.
enum LibraryAccess: Equatable, Sendable {
    case notAsked, full, limited, denied, restricted

    var canRead: Bool { self == .full || self == .limited }
}

/// The photos and videos taken with the app, across launches. PhotoKit can't tell which assets one app created, so
/// the app keeps their identifiers in a file of its own and reads the assets back through them.
///
/// Nothing here reads the library without read access. iOS asks for access at the first read, and that question has
/// to come from the gallery's own button, not on top of the camera.
@MainActor
@Observable
final class CaptureLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var access: LibraryAccess
    /// Every asset the app saved, newest first. Empty until the file has been read.
    private(set) var list = CapturedAssetList()
    /// The stored rows by identifier, built once per change of the list, for the cells' badges.
    private(set) var entries: [String: CapturedAsset] = [:]
    private(set) var isLoaded = false
    /// The recorded assets the library shows now, newest first. nil without read access or before the first fetch.
    private(set) var assets: AssetList?
    /// Recorded assets the last fetch didn't find: deleted, in Recently Deleted, hidden, or outside a limited
    /// selection. The list keeps them: a restored photo comes back with the same identifier.
    private(set) var missingCount = 0
    /// The newest visible asset's picture, so the camera's thumbnail shows the last photo again after a relaunch.
    private(set) var latestThumbnail: UIImage?
    /// The asset `latestThumbnail` shows.
    private(set) var latestThumbnailID: String?

    /// One cache for the grid, the viewer and the thumbnail.
    let imageManager = PHCachingImageManager()

    @ObservationIgnored private var pendingRecords: [CapturedAsset] = []
    /// False when the file exists but couldn't be read: writing then would replace the whole list with this
    /// session's photos.
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveAgain = false
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var fetchAgain = false
    /// Raised when access is lost, so a fetch still running then is thrown away.
    @ObservationIgnored private var fetchGeneration = 0
    /// What the applied fetch asked for, so a photo saved after it isn't mistaken for a deleted one.
    @ObservationIgnored private var fetchedIDs: Set<String> = []
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var latestPixelSide: CGFloat?
    @ObservationIgnored private var latestKey: AssetVersion?
    @ObservationIgnored private var latestTask: Task<Void, Never>?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    nonisolated private static let log = Logger(subsystem: "ca.katsuma.openshutter", category: "Gallery")

    override init() {
        // Reading the status never asks.
        access = Self.currentAccess()
        super.init()
        Task { [weak self] in
            let stored = await Self.readStore()
            self?.finishLoading(stored)
        }
        // Access can change in the Settings app while Open Shutter is away.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
    }

    var hasRecordedAssets: Bool { !list.assets.isEmpty }

    func entry(for id: String) -> CapturedAsset? {
        entries[id]
    }

    /// A fetch is under way, so `assets` may not hold the newest photo yet. Not observed: `assets` changes when it ends.
    var isFetching: Bool { fetchTask != nil }

    /// The last fetch looked for `id` and didn't find it: the asset was deleted or hidden, or isn't shared.
    func isGone(_ id: String) -> Bool {
        guard let assets else { return false }
        return fetchedIDs.contains(id) && assets.index(of: id) == nil
    }

    // MARK: - Access

    /// Reads the status again. Never asks.
    func refreshAccess() {
        setAccess(Self.currentAccess())
    }

    /// The only place that asks for read access, behind the gallery's Continue button.
    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        setAccess(Self.access(for: status))
    }

    private func setAccess(_ new: LibraryAccess) {
        let old = access
        if new != old { access = new }
        if new.canRead {
            // Limited to full shows more photos, so it fetches again too.
            if new != old || (assets == nil && fetchTask == nil) { startReading() }
        } else if old.canRead {
            stopReading()
        }
    }

    nonisolated private static func currentAccess() -> LibraryAccess {
        access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    nonisolated private static func access(for status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        @unknown default: return .denied
        }
    }

    // MARK: - Recording

    /// Keeps what was just saved, so the gallery can list it later. Results that didn't reach Photos are left out.
    func record(_ results: [CaptureResult]) {
        add(results.compactMap { result in
            guard result.savedToLibrary, let id = result.assetIdentifier, !id.isEmpty else { return nil }
            return CapturedAsset(id: id, date: result.date,
                                 kind: CapturedAssetKind(rawValue: result.kind.rawValue) ?? .photo,
                                 summary: result.summary)
        })
    }

    /// Keeps an edited copy saved next to `original`. It takes the original's date, so it sorts beside it, and its
    /// exposure summary, since it is the same shot.
    func recordCopy(id: String, of original: PHAsset) {
        guard !id.isEmpty else { return }
        add([CapturedAsset(id: id, date: original.creationDate ?? Date(), kind: .edit,
                           summary: entries[original.localIdentifier]?.summary ?? "")])
    }

    private func add(_ new: [CapturedAsset]) {
        guard !new.isEmpty else { return }
        guard isLoaded else {
            pendingRecords += new
            return
        }
        var next = list
        next.record(new)
        setList(next)
        scheduleSave()
        scheduleFetch()
    }

    private func setList(_ new: CapturedAssetList) {
        list = new
        entries = new.assetsByID
    }

    private func finishLoading(_ stored: CapturedAssetList?) {
        canSave = stored != nil
        var loaded = stored ?? CapturedAssetList()
        let pending = pendingRecords
        pendingRecords = []
        if !pending.isEmpty { loaded.record(pending) }
        setList(loaded)
        isLoaded = true
        if !pending.isEmpty { scheduleSave() }
        if access.canRead { startReading() }
    }

    // MARK: - Changing assets

    /// iOS asks the person to confirm and moves the asset to Recently Deleted. A refusal throws a cancellation
    /// (`isCancellation`).
    func delete(_ asset: PHAsset) async throws {
        try await Self.performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    func setFavorite(_ asset: PHAsset, _ isOn: Bool) async throws {
        guard asset.canPerform(.properties) else { return }
        try await Self.performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = isOn
        }
    }

    /// The person said no to iOS's own confirmation.
    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.userCancelled.rawValue
    }

    /// Outside the main actor, so the change block isn't taken for main-actor code: PhotoKit runs it on its queue.
    nonisolated private static func performChanges(_ changes: @escaping @Sendable () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(changes)
    }

    // MARK: - Reading the library

    private func startReading() {
        guard access.canRead, isLoaded else { return }
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
        scheduleFetch()
    }

    private func stopReading() {
        fetchGeneration += 1
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            isObserving = false
        }
        assets = nil
        fetchedIDs = []
        missingCount = 0
        latestTask?.cancel()
        latestKey = nil
        latestThumbnail = nil
        latestThumbnailID = nil
    }

    /// One fetch at a time; changes that land meanwhile fetch once more afterwards, with the list as it is then.
    private func scheduleFetch() {
        guard access.canRead, isLoaded else { return }
        fetchAgain = true
        guard fetchTask == nil else { return }
        fetchTask = Task { [weak self] in
            await self?.fetchWhileNeeded()
        }
    }

    private func fetchWhileNeeded() async {
        while fetchAgain, access.canRead {
            fetchAgain = false
            let generation = fetchGeneration
            let identifiers = list.identifiers
            let found = await Self.fetch(identifiers)
            guard generation == fetchGeneration, access.canRead else { continue }
            assets = found
            fetchedIDs = Set(identifiers)
            let missing = max(0, identifiers.count - found.count)
            if missingCount != missing { missingCount = missing }
            refreshLatestThumbnail()
        }
        fetchTask = nil
    }

    /// Off the main thread: it reads every asset once.
    nonisolated private static func fetch(_ identifiers: [String]) async -> AssetList {
        AssetList.fetch(identifiers)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.libraryDidChange(changeInstance)
        }
    }

    /// Edits, deletions and favorites made here or in Photos, and changes to a limited selection, all land here.
    private func libraryDidChange(_ change: PHChange) {
        refreshAccess()
        guard let current = assets, change.changeDetails(for: current.result) != nil else { return }
        scheduleFetch()
    }

    // MARK: - The camera's thumbnail

    /// Keeps the newest visible asset's picture at `pixelSide`, from now on. Asks for nothing without read access.
    func loadLatestThumbnail(pixelSide: CGFloat) {
        guard pixelSide.isFinite, pixelSide > 0 else { return }
        if latestPixelSide != pixelSide {
            latestPixelSide = pixelSide
            latestKey = nil
        }
        refreshLatestThumbnail()
    }

    private func refreshLatestThumbnail() {
        guard let side = latestPixelSide, let assets else { return }
        let newest = assets.first
        let key = newest.map(AssetVersion.init)
        guard key != latestKey else { return }
        latestKey = key
        latestTask?.cancel()
        guard let newest else {
            latestThumbnail = nil
            latestThumbnailID = nil
            return
        }
        let manager = imageManager
        latestTask = Task { [weak self] in
            for await update in AssetRequests.thumbnail(for: newest, pixelSide: side, manager: manager) {
                guard case .value(let image, _) = update, let self else { continue }
                self.latestThumbnail = image
                self.latestThumbnailID = newest.localIdentifier
            }
        }
    }

    // MARK: - The file

    private func scheduleSave() {
        guard canSave else { return }
        saveAgain = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            await self?.saveWhileNeeded()
        }
    }

    /// One write at a time, always of the newest list.
    private func saveWhileNeeded() async {
        while saveAgain {
            saveAgain = false
            await Self.writeStore(list)
        }
        saveTask = nil
    }

    /// Not a setting: Reset all settings leaves it alone. Not UserDefaults either, which loads everything at launch
    /// and would hold thousands of rows.
    nonisolated private static func storeURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: true)
            .appendingPathComponent("CaptureLibrary.json")
    }

    /// The stored list, or nil when the file is there but can't be read now.
    nonisolated private static func readStore() async -> CapturedAssetList? {
        do {
            return CapturedAssetList.decoded(from: try Data(contentsOf: storeURL()))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CapturedAssetList()
        } catch {
            log.error("The gallery list couldn't be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func writeStore(_ list: CapturedAssetList) async {
        do {
            try list.encoded().write(to: storeURL(), options: .atomic)
        } catch {
            log.error("The gallery list couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// An asset as last drawn: the same identifier with a later modification date is an edit to draw again.
struct AssetVersion: Hashable, Sendable {
    let id: String
    let modified: Date?

    init(_ asset: PHAsset) {
        id = asset.localIdentifier
        modified = asset.modificationDate
    }
}
