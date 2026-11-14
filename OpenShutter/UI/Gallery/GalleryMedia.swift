import SwiftUI
import UIKit
import Photos
import PhotosUI
import AVKit
// VideoPlayer lives in AVKit's SwiftUI overlay. Xcode loads it from the imports above; naming it keeps it visible to
// compilers that don't load cross-import overlays on their own.
import _AVKit_SwiftUI
import CameraCore

/// One page of the viewer: a photo, a Live Photo or a video, fitted on black.
struct GalleryPage: View {
    let asset: PHAsset
    let manager: PHImageManager
    /// The page on screen. The others stop playing and drop their zoom.
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    let onTap: () -> Void

    var body: some View {
        Group {
            if asset.mediaType == .video {
                VideoPage(asset: asset, manager: manager, isCurrent: isCurrent)
            } else if asset.mediaSubtypes.contains(.photoLive) {
                LivePhotoPage(asset: asset, manager: manager, isCurrent: isCurrent, onTap: onTap)
            } else {
                PhotoPage(asset: asset, manager: manager, isCurrent: isCurrent, isZoomed: $isZoomed, onTap: onTap)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// What a page asks PhotoKit for. Rounded to whole pixels so a layout pass that moves by a fraction doesn't start
/// the request again.
private struct PageRequest: Hashable {
    let version: AssetVersion
    let width: Int
    let height: Int

    /// Twice the screen's pixels, so a pinch has detail to show before it goes soft.
    init(_ asset: PHAsset, size: CGSize, scale: CGFloat) {
        version = AssetVersion(asset)
        width = Self.pixels(size.width * scale * 2)
        height = Self.pixels(size.height * scale * 2)
    }

    var pixelSize: CGSize { CGSize(width: width, height: height) }

    /// A layout pass can hand over a size that isn't finite, which Int(_:) can't take.
    private static func pixels(_ value: CGFloat) -> Int {
        guard value.isFinite, value >= 1 else { return 1 }
        return Int(min(value, 16_384).rounded(.up))
    }
}

// MARK: - Photo

private struct PhotoPage: View {
    let asset: PHAsset
    let manager: PHImageManager
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var progress: Double?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let request = PageRequest(asset, size: proxy.size, scale: displayScale)
            ZoomableImage(image: image, isCurrent: isCurrent, isZoomed: $isZoomed, onTap: onTap)
                .overlay {
                    DownloadRing(progress: progress)
                }
                .task(id: request) {
                    await load(request)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GalleryText.kindTitle(of: asset))
        .accessibilityValue(GalleryText.dateLine(asset.creationDate))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction {
            onTap()
        }
    }

    private func load(_ request: PageRequest) async {
        for await update in AssetRequests.fullImage(for: asset, pixelSize: request.pixelSize, manager: manager) {
            switch update {
            case .value(let picture, let isFinal):
                image = picture
                if isFinal { progress = nil }
            case .progress(let fraction):
                progress = fraction
            }
        }
        progress = nil
    }
}

/// A photo that pinches to 4x and double taps to 2.5x, centred while smaller than the page.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    let onTap: () -> Void

    func makeUIView(context: Context) -> ZoomingImageView {
        ZoomingImageView(frame: .zero)
    }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        let zoomed = $isZoomed
        view.onTap = onTap
        view.onZoomChange = { isZoomedNow in
            if zoomed.wrappedValue != isZoomedNow { zoomed.wrappedValue = isZoomedNow }
        }
        view.setImage(image)
        if !isCurrent { view.resetZoom() }
    }
}

/// The scroll view behind ZoomableImage, laid out like Apple's photo scroller: the picture fits the page at zoom 1
/// and stays centred while it is smaller than the page.
private final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    var onTap: (() -> Void)?
    var onZoomChange: ((Bool) -> Void)?

    private let imageView = UIImageView()
    /// The page size the picture was last fitted to.
    private var fittedBounds: CGSize = .zero
    /// Off while the zoom changes from code inside a view update, which mustn't write SwiftUI state.
    private var reportsZoom = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        // An HDR picture shows as HDR when the decoded image carries it.
        imageView.preferredImageDynamicRange = .high
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        let reshaped = !Self.sameShape(imageView.image?.size, image?.size)
        imageView.image = image
        // A sharper copy of the same picture keeps the zoom; a different shape fits again.
        if reshaped { fit() }
    }

    func resetZoom() {
        guard zoomScale > minimumZoomScale else { return }
        setZoom(minimumZoomScale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBounds { fit() }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        if reportsZoom { onZoomChange?(zoomScale > minimumZoomScale + 0.01) }
    }

    private func fit() {
        fittedBounds = bounds.size
        setZoom(minimumZoomScale)
        let size = fittedSize()
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerImage()
    }

    /// Zooms from code without writing SwiftUI state on the spot; the new state follows once the update is over.
    private func setZoom(_ scale: CGFloat) {
        let wasZoomed = zoomScale > minimumZoomScale + 0.01
        reportsZoom = false
        zoomScale = scale
        reportsZoom = true
        let isZoomed = zoomScale > minimumZoomScale + 0.01
        if wasZoomed != isZoomed {
            DispatchQueue.main.async { [weak self] in
                self?.onZoomChange?(isZoomed)
            }
        }
    }

    private func fittedSize() -> CGSize {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds.size }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func centerImage() {
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        if frame.origin != imageView.frame.origin { imageView.frame = frame }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    @objc private func singleTapped() {
        onTap?()
    }

    private static func sameShape(_ a: CGSize?, _ b: CGSize?) -> Bool {
        guard let a, let b, a.height > 0, b.height > 0 else { return a == nil && b == nil }
        return abs(a.width / a.height - b.width / b.height) < 0.01
    }
}

// MARK: - Live Photo

/// Touch and hold plays it, through the view's own gesture, as in Photos.
private struct LivePhotoPage: View {
    let asset: PHAsset
    let manager: PHImageManager
    let isCurrent: Bool
    let onTap: () -> Void
    @State private var livePhoto: PHLivePhoto?
    @State private var progress: Double?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let request = PageRequest(asset, size: proxy.size, scale: displayScale)
            LivePhotoCanvas(livePhoto: livePhoto, isCurrent: isCurrent, onTap: onTap)
                .overlay {
                    DownloadRing(progress: progress)
                }
                .task(id: request) {
                    await load(request)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GalleryText.kindTitle(of: asset))
        .accessibilityValue(GalleryText.dateLine(asset.creationDate))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction {
            onTap()
        }
    }

    private func load(_ request: PageRequest) async {
        for await update in AssetRequests.livePhoto(for: asset, pixelSize: request.pixelSize, manager: manager) {
            switch update {
            case .value(let picture, let isFinal):
                livePhoto = picture
                if isFinal { progress = nil }
            case .progress(let fraction):
                progress = fraction
            }
        }
        progress = nil
    }
}

private struct LivePhotoCanvas: UIViewRepresentable {
    let livePhoto: PHLivePhoto?
    let isCurrent: Bool
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        // A tap shows or hides the chrome; touch and hold stays the view's own playback gesture.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onTap = onTap
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        if !isCurrent { view.stopPlayback() }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: (() -> Void)?

        @objc func tapped() {
            onTap?()
        }
    }
}

/// Apple's own Live badge, drawn to sit over a picture.
struct LivePhotoBadge: View {
    var body: some View {
        Image(uiImage: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))
            .accessibilityLabel("Live Photo")
    }
}

// MARK: - Video

private struct VideoPage: View {
    let asset: PHAsset
    let manager: PHImageManager
    let isCurrent: Bool
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                Label("This video couldn't be loaded.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.7))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Only a new video loads again: a favorite also changes the asset, and the video shouldn't restart.
        .task(id: asset.localIdentifier) {
            guard player == nil else { return }
            if let item = await AssetRequests.playerItem(for: asset, manager: manager) {
                player = AVPlayer(playerItem: item)
            } else if !Task.isCancelled {
                failed = true
            }
        }
        .onChange(of: isCurrent) { _, current in
            if !current { player?.pause() }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Shared pieces

/// How far an iCloud download has come, while the full picture is on its way.
private struct DownloadRing: View {
    let progress: Double?

    var body: some View {
        if let progress, progress < 1 {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.03, progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)
            .accessibilityElement()
            .accessibilityLabel("Downloading from iCloud")
            .accessibilityValue(Formatting.percent(progress))
        }
    }
}

/// The gallery's words for dates, kinds and VoiceOver, in one place so the grid and the viewer say the same.
@MainActor
enum GalleryText {
    /// "Today at 10:41", "Yesterday at 18:02", "3 Nov 2026 at 09:15", in the phone's language.
    static func dateLine(_ date: Date?) -> String {
        guard let date else { return "" }
        return relativeDate.string(from: date)
    }

    /// Photo, Live Photo or Video: what Photos calls them, in both interfaces.
    static func kindTitle(of asset: PHAsset) -> String {
        if asset.mediaType == .video { return "Video" }
        return asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "Photo"
    }

    /// The advanced interface also names what the camera made: a RAW photo, a stack, a bracket frame, a copy.
    static func detailTitle(_ kind: CapturedAssetKind?) -> String? {
        switch kind {
        case .raw: return "RAW photo"
        case .stack: return "Stacked exposure"
        case .bracket: return "Bracket frame"
        case .edit: return "Edited copy"
        case .photo, .video, nil: return nil
        }
    }

    /// "Photo, today at 10:41", "Video, 12 seconds, today at 10:41". `detail` replaces the kind's name.
    static func spokenDescription(of asset: PHAsset, detail: String?) -> String {
        var parts = [detail ?? kindTitle(of: asset)]
        if asset.mediaType == .video, asset.duration.isFinite, asset.duration > 0 {
            let seconds = Int(asset.duration.rounded())
            parts.append(Duration.seconds(max(1, seconds)).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .wide)))
        }
        if asset.isFavorite { parts.append("Favorite") }
        let date = dateLine(asset.creationDate)
        if !date.isEmpty { parts.append(date) }
        return parts.joined(separator: ", ")
    }

    private static let relativeDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
