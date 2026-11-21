import SwiftUI
import UIKit
import Photos
import CameraCore

/// The full-screen viewer: one asset a page, swiped sideways, always on black, as photos are judged in Photos. A tap
/// shows or hides the bars. The back button and a swipe down lead to the grid. Info, or a swipe up on a photo, raises
/// the info panel under it.
struct GalleryViewer: View {
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
    /// Where the info panel is. The body reads only whether it is open; the finger is read by InfoRoom and the
    /// panel's layer alone.
    @State private var motion = InfoPanelMotion()
    @State private var facts = PhotoFactsStore()
    @State private var editing: AssetTarget?
    @State private var shareURLs: [URL]?
    @State private var isPreparingShare = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    init(library: CaptureLibrary, startID: String, zoomSpace: Namespace.ID, onShow: @escaping (String) -> Void) {
        self.library = library
        self.startID = startID
        self.zoomSpace = zoomSpace
        self.onShow = onShow
        _currentID = State(initialValue: startID)
    }

    var body: some View {
        let assets = library.assets
        let current = currentID.flatMap { assets?.asset(id: $0) }
        // A video's own controls take its taps, and VoiceOver needs the buttons, so the bars stay up for both. The
        // info panel hides them while it is up, and they come back as they were.
        let showsChrome = voiceOver || current?.mediaType == .video || (chromeVisible && !motion.isOpen)
        ZStack {
            Color.black
                .ignoresSafeArea()
            if let assets {
                pager(assets)
            }
        }
        // Above the pager, under the bars.
        .overlay(alignment: .bottom) {
            if let current, current.mediaType == .image {
                InfoPanelLayer(motion: motion, asset: current,
                               kind: library.entry(for: current.localIdentifier)?.kind, store: facts,
                               manager: library.imageManager)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsChrome, let current, let badge = LivePhotoBadge(for: current) {
                badge
                    .padding(.top, 10)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewerTitle(date: current?.creationDate,
                            position: currentID.flatMap { assets?.index(of: $0) }, total: assets?.count ?? 0)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                bottomButtons(for: current)
                    // Thin, as the camera's top bar draws its glyphs.
                    .fontWeight(.light)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(showsChrome ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar, .bottomBar)
        // Solid, as the info panel is, so the bars read the same over any photo.
        .toolbarBackground(InfoPanelStyle.fill, for: .navigationBar, .bottomBar)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        // The camera hides it too, and over black its text would follow a light list's dark style.
        .statusBarHidden(true)
        // Keyed on the tap and the page, not on showsChrome: the panel hides the bars inside its own animation, which
        // this would otherwise replace for the photo and the panel too.
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: current?.mediaType == .video)
        .environment(\.colorScheme, .dark)
        .galleryZoomTransition(sourceID: currentID ?? startID, in: zoomSpace)
        .background {
            SharePresenter(urls: $shareURLs) {
                GalleryFiles.clearShares()
            }
            WindowInsetProbe { [motion] top, bottom in
                motion.setSafeArea(top: top, bottom: bottom)
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
            // The panel stays up from photo to photo and shows each; a video has none.
            if library.assets?.asset(id: id)?.mediaType != .image { motion.close() }
            onShow(id)
        }
        .fullScreenCover(item: $editing) { target in
            // The editor stays dark, like the viewer, even when the grid behind it is light.
            PhotoEditorView(asset: target.asset, library: library)
                .preferredColorScheme(.dark)
        }
        .alert(failureTitle, isPresented: failureShown) {
            Button("OK", role: .cancel) {}
        }
    }

    // Kept out of the modifier chain: inline, the alert's title and binding take Swift 6.2 about 20 s to type-check.
    private var failureTitle: String { failure ?? "" }

    private var failureShown: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private func pager(_ assets: AssetList) -> some View {
        let manager = library.imageManager
        let motion = motion
        let isOpen = motion.isOpen
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(assets.identifiers, id: \.self) { id in
                        ZStack {
                            Color.black
                            if let asset = assets.asset(id: id) {
                                InfoRoom(motion: motion, aspect: Self.aspect(of: asset)) {
                                    GalleryPage(asset: asset, manager: manager, isCurrent: id == currentID,
                                                isZoomed: $isZoomed, zoomEnabled: !isOpen,
                                                infoSwipe: infoSwipe(for: asset), onInfoDrag: motion.track,
                                                onTap: tapped)
                                }
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
                // The bar's accent already colours it; the heart filling is the change, swapped crisply.
                .contentTransition(AppearanceStore.shared.reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .disabled(!(asset?.canPerform(.properties) ?? false))
        .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
        if isPhoto {
            Spacer()
            Button {
                motion.toggle()
            } label: {
                // The bars show over an open panel only for VoiceOver, so only VoiceOver hears the other name.
                Label(motion.isOpen ? "Hide info" : "Info", systemImage: motion.isOpen ? "info.circle.fill" : "info.circle")
            }
            .accessibilityHint("Shows how the photo was taken.")
            // The editor's own rule: a loop or bounce passes canPerform(.content) but can't be edited there.
            if let asset, PhotoEditSession.isEditable(asset) {
                Spacer()
                Button {
                    editing = AssetTarget(asset: asset)
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

    /// A tap on the photo lowers the panel when it is up, else shows or hides the bars.
    private func tapped() {
        if motion.isOpen {
            motion.close()
        } else {
            chromeVisible.toggle()
        }
    }

    /// Which way a drag on this page moves the panel: up to raise it, down to lower it. None for a video, a zoomed
    /// photo, which pans, or with VoiceOver, which has the Info button and the escape gesture.
    private func infoSwipe(for asset: PHAsset) -> InfoSwipeDirection? {
        guard asset.mediaType == .image, !isZoomed, !voiceOver else { return nil }
        return motion.isOpen ? .down : .up
    }

    /// Width over height, for the photo's place above the panel. nil for a video or a photo of no known size.
    private static func aspect(of asset: PHAsset) -> Double? {
        guard asset.mediaType == .image, asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
        return Double(asset.pixelWidth) / Double(asset.pixelHeight)
    }

    private func share(_ asset: PHAsset?) {
        guard let asset, !isPreparingShare else { return }
        isPreparingShare = true
        let manager = library.imageManager
        Task {
            defer { isPreparingShare = false }
            do {
                shareURLs = [try await AssetRequests.exportCopy(of: asset, into: GalleryFiles.newShareFolder(),
                                                                 manager: manager)]
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
        GalleryHaptics.favorite()
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
}

/// The date over the picture, and under it where the picture sits in the gallery, "12 / 214". How it was shot is in
/// the info panel.
private struct ViewerTitle: View {
    let date: Date?
    /// Zero-based; nil while the page is unknown.
    let position: Int?
    let total: Int

    var body: some View {
        VStack(spacing: 1) {
            Text(GalleryText.dateLine(date))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let position, total > 1 {
                Text("\(position + 1) / \(total)")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .tracking(0.6)
                    .foregroundStyle(InfoPanelStyle.tertiary)
                    .lineLimit(1)
                    .accessibilityLabel("\(position + 1) of \(total)")
            }
        }
        // Two lines have to fit the bar's height.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .combine)
    }
}

/// The gallery's own touch: a soft tap for a favorite, softer than the camera's controls, as a heart is not a
/// setting. It keeps to the camera's haptics switch, its strength and its quiet during a stack.
@MainActor
enum GalleryHaptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)

    static func favorite() {
        guard Haptics.isEnabled, !Haptics.isSuppressed else { return }
        switch Haptics.strength {
        case .light: soft.impactOccurred(intensity: 0.5)
        case .normal: soft.impactOccurred(intensity: 0.8)
        case .strong: soft.impactOccurred(intensity: 1)
        }
    }
}

private struct AssetTarget: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
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
