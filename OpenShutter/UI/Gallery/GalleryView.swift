import SwiftUI
import UIKit
import Photos
import CameraCore

/// The gallery, presented over the camera from its thumbnail. It opens on the grid, scrolled to the newest photo at
/// the bottom; a cell opens the viewer. Without read access it explains why and lists this session's captures.
/// The grid follows the appearance setting; the viewer stays black.
struct GalleryView: View {
    let model: CameraModel
    @State private var path: [String] = []
    @State private var gridScrollID: String?
    @State private var showsLimitedPicker = false
    @Namespace private var zoomSpace

    var body: some View {
        let library = model.library
        NavigationStack(path: $path) {
            GalleryHome(model: model, library: library, zoomSpace: zoomSpace, scrollID: $gridScrollID,
                        onOpen: open, onChangeShared: { showsLimitedPicker = true })
                .navigationDestination(for: String.self) { id in
                    GalleryViewer(library: library, startID: id, zoomSpace: zoomSpace) { shown in
                        gridScrollID = shown
                    }
                }
        }
        .sheetAppearance()
        .background {
            LimitedLibraryPresenter(isPresented: $showsLimitedPicker)
        }
        .onAppear {
            // Access may have changed in the Settings app since the last look.
            library.refreshAccess()
        }
        .onDisappear {
            GalleryFiles.clearShares()
            library.imageManager.stopCachingImagesForAllAssets()
        }
        .onChange(of: library.access.canRead) { _, canRead in
            // Access lost: back to the page that explains it.
            if !canRead { path = [] }
        }
    }

    private func open(_ id: String) {
        path.append(id)
    }
}

/// The gallery's first page: the grid when the library can be read, the explanation when it can't.
private struct GalleryHome: View {
    let model: CameraModel
    let library: CaptureLibrary
    let zoomSpace: Namespace.ID
    @Binding var scrollID: String?
    let onOpen: (String) -> Void
    let onChangeShared: () -> Void
    @State private var photosFailed = false
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    /// A share of the selected photos being copied out, for its progress card.
    @State private var sharing: ShareJob?
    @State private var shareTask: Task<Void, Never>?
    @State private var shareURLs: [URL]?
    @State private var failure: String?

    var body: some View {
        let access = library.access
        let hasPhotos = !(library.assets?.isEmpty ?? true)
        Group {
            if access.canRead {
                GalleryGrid(library: library, zoomSpace: zoomSpace, scrollID: $scrollID, isSelecting: isSelecting,
                            selection: $selection, onOpen: onOpen, onChangeShared: onChangeShared,
                            onAction: perform)
            } else {
                GalleryAccessView(model: model, library: library)
            }
        }
        .overlay {
            if let sharing {
                ShareProgressCard(job: sharing) {
                    shareTask?.cancel()
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.fade, value: sharing == nil)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Back is gone while selecting, so a stray tap there doesn't throw the selection away.
            if !isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.isReviewPresented = false
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Camera")
                    .accessibilityHint("Goes back to the camera.")
                }
            }
            if access.canRead, hasPhotos || isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        setSelecting(!isSelecting)
                    }
                }
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        shareSelection()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selection.isEmpty || sharing != nil)
                    Spacer()
                    Button(role: .destructive) {
                        deleteSelection()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty || sharing != nil)
                }
            }
            if access.canRead, !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            openPhotos()
                        } label: {
                            Label("Open Photos", systemImage: "photo.on.rectangle")
                        }
                        if access == .limited {
                            Button {
                                onChangeShared()
                            } label: {
                                Label("Change shared photos", systemImage: "photo.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .alert("Photos couldn't be opened.", isPresented: $photosFailed) {
            Button("OK", role: .cancel) {}
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .background {
            SharePresenter(urls: $shareURLs) {
                GalleryFiles.clearShares()
            }
        }
        .onChange(of: library.assets.map { ObjectIdentifier($0.result) }) {
            // Deleted here or in Photos, or no longer shared: a tick on a photo that's gone would share nothing.
            guard isSelecting else { return }
            let shown = library.assets.map { Set($0.identifiers) } ?? []
            selection.formIntersection(shown)
            if shown.isEmpty { setSelecting(false) }
        }
        .onChange(of: access.canRead) { _, canRead in
            if !canRead { setSelecting(false) }
        }
    }

    private var title: String {
        guard isSelecting else { return "Gallery" }
        return selection.isEmpty ? "Select photos" : "\(selection.count) selected"
    }

    private func setSelecting(_ isOn: Bool) {
        if !isOn {
            shareTask?.cancel()
        }
        withAnimation(Theme.snappy) {
            isSelecting = isOn
            selection = []
        }
    }

    /// The selected assets in grid order, oldest first.
    private func selectedAssets() -> [PHAsset] {
        guard let assets = library.assets else { return [] }
        return assets.identifiers.filter(selection.contains).compactMap { assets.asset(id: $0) }
    }

    private func deleteSelection() {
        let doomed = selectedAssets().filter { $0.canPerform(.delete) }
        guard !doomed.isEmpty else {
            failure = "These couldn't be deleted."
            return
        }
        Task {
            do {
                // iOS asks once for all of them.
                try await library.delete(doomed)
                setSelecting(false)
            } catch {
                if !CaptureLibrary.isCancellation(error) {
                    failure = "These couldn't be deleted."
                }
            }
        }
    }

    /// A cell's touch-and-hold menu.
    private func perform(_ action: GridAction, on asset: PHAsset) {
        switch action {
        case .share:
            share([asset])
        case .favorite:
            GalleryHaptics.favorite()
            Task {
                do {
                    try await library.setFavorite(asset, !asset.isFavorite)
                } catch {
                    failure = "The favorite couldn't be changed."
                }
            }
        case .delete:
            Task {
                do {
                    try await library.delete(asset)
                } catch {
                    if !CaptureLibrary.isCancellation(error) { failure = "This couldn't be deleted." }
                }
            }
        }
    }

    private func shareSelection() {
        share(selectedAssets())
    }

    private func share(_ chosen: [PHAsset]) {
        guard !chosen.isEmpty, sharing == nil else { return }
        sharing = ShareJob(total: chosen.count)
        let manager = library.imageManager
        shareTask = Task {
            let urls = await GalleryFiles.exportCopies(of: chosen, manager: manager) { done in
                sharing?.done = done
            }
            let cancelled = Task.isCancelled
            sharing = nil
            shareTask = nil
            if cancelled {
                GalleryFiles.clearShares()
            } else if urls.isEmpty {
                failure = chosen.count == 1 ? "This couldn't be shared." : "These couldn't be shared."
            } else {
                // Any that failed are left out; the rest still go.
                shareURLs = urls
            }
        }
    }

    private func openPhotos() {
        PhotosApp.open { opened in
            photosFailed = !opened
        }
    }
}
