import SwiftUI
import UIKit
import Photos
import CameraCore

/// The full-screen viewer: one asset a page, swiped sideways, always on black, as photos are judged in Photos. A tap
/// shows or hides the bars. The back button and a swipe down lead to the grid.
struct GalleryViewer: View {
    let model: CameraModel
    let library: CaptureLibrary
    let startID: String
    let zoomSpace: Namespace.ID
    /// Tells the gallery which asset is on screen, so the grid can scroll to it for the way back.
    let onShow: (String) -> Void

    @State private var currentID: String?
    /// Where the current page sat, so a deleted page hands over to its neighbour.
    @State private var lastIndex = 0
    @State private var chromeVisible = true
    @State private var isZoomed = false
    /// Favorites as tapped, until the library catches up.
    @State private var favorites: [String: Bool] = [:]
    /// A stack's duration from its file, by asset.
    @State private var stackLines: [String: String] = [:]
    @State private var editing: AssetTarget?
    @State private var inspecting: AssetTarget?
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    init(model: CameraModel, library: CaptureLibrary, startID: String, zoomSpace: Namespace.ID,
         onShow: @escaping (String) -> Void) {
        self.model = model
        self.library = library
        self.startID = startID
        self.zoomSpace = zoomSpace
        self.onShow = onShow
        _currentID = State(initialValue: startID)
    }

    var body: some View {
        let assets = library.assets
        let current = currentID.flatMap { assets?.asset(id: $0) }
        // A video's own controls take its taps, and VoiceOver needs the buttons, so the bars stay up for both.
        let showsChrome = chromeVisible || current?.mediaType == .video || voiceOver
        ZStack {
            Color.black
                .ignoresSafeArea()
            if let assets {
                pager(assets)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsChrome, let current, current.mediaSubtypes.contains(.photoLive), current.mediaType == .image {
                LivePhotoBadge()
                    .padding(.top, 10)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewerTitle(model: model, library: library, asset: current,
                            stackLine: currentID.flatMap { stackLines[$0] })
            }
            ToolbarItemGroup(placement: .bottomBar) {
                bottomButtons(for: current)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(showsChrome ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar, .bottomBar)
        .toolbarBackground(Color.black.opacity(0.72), for: .navigationBar, .bottomBar)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        // The camera hides it too, and over black its text would follow a light list's dark style.
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .environment(\.colorScheme, .dark)
        .galleryZoomTransition(sourceID: currentID ?? startID, in: zoomSpace)
        .background {
            SharePresenter(url: $shareURL) {
                GalleryFiles.clearShares()
            }
        }
        .onAppear {
            keepCurrentPage()
        }
        .onChange(of: assets.map { ObjectIdentifier($0.result) }) {
            keepCurrentPage()
        }
        .onChange(of: currentID) { _, id in
            isZoomed = false
            guard let id else { return }
            if let index = library.assets?.index(of: id) { lastIndex = index }
            onShow(id)
        }
        .task(id: currentID) {
            await loadStackLine()
        }
        .fullScreenCover(item: $editing) { target in
            // The editor stays dark, like the viewer, even when the grid behind it is light.
            PhotoEditorView(asset: target.asset, library: library)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $inspecting) { target in
            NavigationStack {
                PhotoInfoView(source: .asset(target.asset))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                inspecting = nil
                            }
                        }
                    }
            }
            .sheetAppearance()
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func pager(_ assets: AssetList) -> some View {
        let manager = library.imageManager
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(assets.identifiers, id: \.self) { id in
                        ZStack {
                            Color.black
                            if let asset = assets.asset(id: id) {
                                GalleryPage(asset: asset, manager: manager, isCurrent: id == currentID,
                                            isZoomed: $isZoomed, onTap: toggleChrome)
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            // A zoomed photo pans instead of turning the page.
            .scrollDisabled(isZoomed)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .onAppear {
                if let currentID { proxy.scrollTo(currentID) }
            }
        }
    }

    @ViewBuilder
    private func bottomButtons(for asset: PHAsset?) -> some View {
        let isPhoto = asset?.mediaType == .image
        let isFavorite = asset.map { favorites[$0.localIdentifier] ?? $0.isFavorite } ?? false
        Button {
            share(asset)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(asset == nil || isPreparingShare)
        Spacer()
        Button {
            toggleFavorite(asset)
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
        }
        .disabled(!(asset?.canPerform(.properties) ?? false))
        if isPhoto {
            Spacer()
            Button {
                inspecting = asset.map(AssetTarget.init)
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .accessibilityHint("Shows everything saved inside the photo.")
            if asset?.canPerform(.content) ?? false {
                Spacer()
                Button {
                    editing = asset.map(AssetTarget.init)
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
            }
        }
        Spacer()
        Button(role: .destructive) {
            delete(asset)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!(asset?.canPerform(.delete) ?? false))
        .accessibilityHint("Moves it to Recently Deleted in Photos.")
    }

    // MARK: - Actions

    private func toggleChrome() {
        chromeVisible.toggle()
    }

    private func share(_ asset: PHAsset?) {
        guard let asset, !isPreparingShare else { return }
        isPreparingShare = true
        let manager = library.imageManager
        Task {
            defer { isPreparingShare = false }
            do {
                shareURL = try await AssetRequests.exportCopy(of: asset, into: GalleryFiles.newShareFolder(),
                                                               manager: manager)
            } catch {
                failure = asset.mediaType == .video ? "This video couldn't be shared." : "This photo couldn't be shared."
            }
        }
    }

    private func toggleFavorite(_ asset: PHAsset?) {
        guard let asset else { return }
        let id = asset.localIdentifier
        let isOn = !(favorites[id] ?? asset.isFavorite)
        favorites[id] = isOn
        Haptics.tap()
        Task {
            do {
                try await library.setFavorite(asset, isOn)
            } catch {
                favorites[id] = nil
                failure = "The favorite couldn't be changed."
            }
        }
    }

    private func delete(_ asset: PHAsset?) {
        guard let asset else { return }
        Task {
            do {
                // iOS asks first. The page leaves once the library has caught up (keepCurrentPage).
                try await library.delete(asset)
            } catch {
                if !CaptureLibrary.isCancellation(error) { failure = "This couldn't be deleted." }
            }
        }
    }

    /// The page on screen went away (deleted here or in Photos, or no longer shared): its neighbour takes over,
    /// and the grid comes back when nothing is left.
    private func keepCurrentPage() {
        guard let assets = library.assets else { return }
        // A favorite the library now reports needs no stand-in, and a stale one would hide a change made in Photos.
        let unconfirmed = favorites.filter { id, isOn in assets.asset(id: id).map { $0.isFavorite != isOn } ?? false }
        if unconfirmed.count != favorites.count { favorites = unconfirmed }
        if let currentID, let index = assets.index(of: currentID) {
            lastIndex = index
            return
        }
        guard !assets.isEmpty else {
            dismiss()
            return
        }
        currentID = assets.identifiers[min(max(lastIndex, 0), assets.count - 1)]
    }

    /// A stack's EXIF exposure time is one frame's for Blur, Trails and NIGHT, so its duration comes from the app's
    /// XMP fields in the file. Only the advanced interface shows it.
    private func loadStackLine() async {
        guard model.isAdvanced, let id = currentID, stackLines[id] == nil,
              library.entry(for: id)?.kind == .stack, let asset = library.assets?.asset(id: id) else { return }
        let values = await AssetRequests.appValues(of: asset)
        if let line = ShotXMP.stackSummary(values) {
            stackLines[id] = line
        }
    }
}

/// The date over the picture and, in the advanced interface, how it was shot. A view of its own, so a settings
/// change redraws only this line and not the pager.
private struct ViewerTitle: View {
    let model: CameraModel
    let library: CaptureLibrary
    let asset: PHAsset?
    let stackLine: String?

    var body: some View {
        let entry = asset.flatMap { library.entry(for: $0.localIdentifier) }
        // The summary is shutter speed, ISO and aperture, which the simple interface never shows.
        let detail = model.isAdvanced ? (stackLine ?? entry?.summary) : nil
        VStack(spacing: 1) {
            Text(GalleryText.dateLine(asset?.creationDate))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }
}

private struct AssetTarget: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// Copies written for the share sheet. They are personal photos, so they go as soon as the sheet closes, and with
/// the gallery.
@MainActor
enum GalleryFiles {
    private static var shareRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GalleryShare", isDirectory: true)
    }

    /// An empty folder of its own for each share, so a file name never collides with an earlier one.
    static func newShareFolder() -> URL {
        shareRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func clearShares() {
        try? FileManager.default.removeItem(at: shareRoot)
    }
}

/// The system share sheet for a file, presented from a hidden controller: it takes a file known only once the
/// export is done, which ShareLink can't.
private struct SharePresenter: UIViewControllerRepresentable {
    @Binding var url: URL?
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let url, !coordinator.isPresenting else { return }
        coordinator.isPresenting = true
        let binding = $url
        let finish = onFinish
        // UIKit refuses a presentation in the middle of a view update, so it waits for the update to end.
        Task { @MainActor in
            let done = {
                coordinator.isPresenting = false
                binding.wrappedValue = nil
                finish()
            }
            guard controller.view.window != nil, controller.presentedViewController == nil else {
                done()
                return
            }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = controller.view
            sheet.completionWithItemsHandler = { _, _, _, _ in
                done()
            }
            controller.present(sheet, animated: true)
        }
    }

    final class Coordinator {
        var isPresenting = false
    }
}

extension View {
    /// The zoom from a thumbnail or grid cell into what it opens, and back. Reduce Motion, in the app or in iOS,
    /// keeps the plain slide.
    @MainActor
    @ViewBuilder
    func galleryZoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        if AppearanceStore.shared.reduceMotion {
            self
        } else {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}
