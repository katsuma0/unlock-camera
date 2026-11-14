import SwiftUI
import UIKit
import Photos
import CameraCore

/// The gallery, presented over the camera from its thumbnail. Like the Camera app it opens on the newest photo, and
/// its back button leads to the grid. Without read access it explains why and lists this session's captures.
/// The grid follows the appearance setting; the viewer stays black.
struct GalleryView: View {
    let model: CameraModel
    @State private var path: [String]
    @State private var gridScrollID: String?
    /// The newest photo was still on its way into the list when the gallery opened; it opens once it lands.
    @State private var opensNewestWhenFetched: Bool
    @State private var showsLimitedPicker = false
    @Namespace private var zoomSpace

    init(model: CameraModel) {
        self.model = model
        let library = model.library
        let newest = library.assets?.identifiers.first
        let isCurrent = library.access.canRead && library.assets != nil && !library.isFetching
        let start = isCurrent ? newest : nil
        _path = State(initialValue: start.map { [$0] } ?? [])
        _gridScrollID = State(initialValue: start)
        _opensNewestWhenFetched = State(initialValue: library.access.canRead && !isCurrent)
    }

    var body: some View {
        let library = model.library
        NavigationStack(path: $path) {
            GalleryHome(model: model, library: library, zoomSpace: zoomSpace, scrollID: $gridScrollID,
                        onOpen: open, onChangeShared: { showsLimitedPicker = true })
                .navigationDestination(for: String.self) { id in
                    GalleryViewer(model: model, library: library, startID: id, zoomSpace: zoomSpace) { shown in
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
            if !canRead {
                path = []
                opensNewestWhenFetched = false
            }
        }
        .onChange(of: library.assets.map { ObjectIdentifier($0.result) }) {
            openNewestIfWaiting()
        }
    }

    private func open(_ id: String) {
        opensNewestWhenFetched = false
        path.append(id)
    }

    private func openNewestIfWaiting() {
        let library = model.library
        guard opensNewestWhenFetched, !library.isFetching else { return }
        opensNewestWhenFetched = false
        guard path.isEmpty, let newest = library.assets?.identifiers.first else { return }
        gridScrollID = newest
        path = [newest]
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

    var body: some View {
        let access = library.access
        Group {
            if access.canRead {
                GalleryGrid(model: model, library: library, zoomSpace: zoomSpace, scrollID: $scrollID,
                            onOpen: onOpen, onChangeShared: onChangeShared)
            } else {
                GalleryAccessView(model: model, library: library)
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    model.isReviewPresented = false
                }
                .accessibilityHint("Goes back to the camera.")
            }
            if access.canRead {
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
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .alert("Photos couldn't be opened.", isPresented: $photosFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func openPhotos() {
        PhotosApp.open { opened in
            photosFailed = !opened
        }
    }
}
