import SwiftUI
import UIKit
import CameraCore

// The last capture's thumbnail beside the shutter, and the gallery it opens. In a file of its own so the gallery
// work and the camera screen's layout don't share one file. The gallery is presented here, so its zoom can grow
// out of the square; keep one ThumbnailButton on screen.

/// Where the gallery's zoom transition starts.
private enum GalleryZoom {
    static let thumbnail = "thumbnail"
}

struct ThumbnailButton: View {
    @Bindable var model: CameraModel
    @State private var press = PressTracker()
    @Namespace private var galleryZoom
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let library = model.library
        let activity = model.activity
        let isHidden = activity == .recording || activity == .stacking
        let canOpen = Self.canOpen(model)
        let picture = ThumbnailPicture(capture: model.lastCapture, library: library)
        Button {
            Self.showGallery(model)
        } label: {
            Upright(model: model) {
                ThumbnailImage(picture: picture)
            }
        }
        // With nothing to show a tap does nothing, so the square stays still under the finger.
        .buttonStyle(PressScaleButtonStyle(isPressed: press.isPressed && canOpen))
        .disabled(!canOpen)
        .accessibilityLabel("Photos")
        .modifier(ThumbnailSpokenValue(model: model, picture: picture))
        .accessibilityHint("Shows the photos and videos you took. Touch and hold for more options.")
        .accessibilityAction(named: "Open Photos") { Self.openPhotos(model) }
        // Laid over the disabled button as well: Photos can be opened before anything has been captured.
        .overlay {
            ThumbnailTouchLayer(model: model, press: press)
        }
        .matchedTransitionSource(id: GalleryZoom.thumbnail, in: galleryZoom)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .animation(Theme.spring, value: picture.key)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .fullScreenCover(isPresented: $model.isReviewPresented) {
            GalleryView(model: model)
                .galleryZoomTransition(sourceID: GalleryZoom.thumbnail, in: galleryZoom)
        }
        .onAppear {
            // The newest photo comes back after a relaunch, but only where access was already given: this never asks.
            library.loadLatestThumbnail(pixelSide: (ThumbnailImage.side * displayScale).rounded(.up))
        }
    }

    /// A capture this session, or any photo taken here before.
    fileprivate static func canOpen(_ model: CameraModel) -> Bool {
        !model.recentCaptures.isEmpty || model.library.hasRecordedAssets
    }

    fileprivate static func showGallery(_ model: CameraModel) {
        guard canOpen(model) else { return }
        Haptics.tap()
        model.isDrawerOpen = false
        model.isReviewPresented = true
    }

    /// The gallery's way into Photos, without the gallery.
    fileprivate static func openPhotos(_ model: CameraModel) {
        Haptics.tap()
        model.isDrawerOpen = false
        PhotosApp.open { opened in
            if !opened {
                model.showToast("Photos couldn't be opened.", symbol: "exclamationmark.triangle")
            }
        }
    }
}

/// What the square shows: this session's last capture while it still exists, else the newest photo the library
/// shows, which brings the last photo back after a relaunch and steps past one deleted in the gallery.
private struct ThumbnailPicture {
    /// Changes when a different picture shows, for the swap animation.
    var key: String?
    var image: Image?
    var isVideo = false
    /// From this session: VoiceOver can name the kind and the exposure the camera reported.
    var capture: CaptureResult?
    /// From the library: the row the app stored for it.
    var entry: CapturedAsset?

    @MainActor
    init(capture: CaptureResult?, library: CaptureLibrary) {
        // A capture that never reached Photos has no identifier and still shows: it is the newest there is.
        if let capture, !(capture.assetIdentifier.map(library.isGone) ?? false) {
            key = capture.id.uuidString
            image = capture.thumbnail.map { Image(decorative: $0, scale: 1) }
            isVideo = capture.kind == .video
            self.capture = capture
        } else if let image = library.latestThumbnail, let id = library.latestThumbnailID {
            let entry = library.entry(for: id)
            key = id
            self.image = Image(uiImage: image)
            isVideo = entry?.kind == .video
            self.entry = entry
        }
    }
}

/// The thumbnail's VoiceOver value. The exposure summary is shutter speed and ISO, which the simple interface never
/// shows or says. Reading the interface level is reading the settings, which dials write many times a second, so it
/// happens in this modifier and not in the button.
private struct ThumbnailSpokenValue: ViewModifier {
    let model: CameraModel
    let picture: ThumbnailPicture

    func body(content: Content) -> some View {
        content.accessibilityValue(Self.value(picture, detailed: model.isAdvanced))
    }

    private static func value(_ picture: ThumbnailPicture, detailed: Bool) -> String {
        if let capture = picture.capture {
            return detailed ? capture.summary : capture.kind.title(detailed: false)
        }
        if let entry = picture.entry {
            if detailed, !entry.summary.isEmpty { return entry.summary }
            return entry.kind == .video ? "Video" : "Photo"
        }
        return "None yet"
    }
}

/// The thumbnail's tap and its touch and hold menu, laid over it. Its own view with inputs that never change, so a
/// new capture or a turn of the phone redraws the picture and leaves the system's menu button alone.
private struct ThumbnailTouchLayer: View {
    let model: CameraModel
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            ThumbnailButton.showGallery(model)
        } options: {
            ThumbnailOptions(model: model)
        }
    }
}

private struct ThumbnailOptions: View {
    let model: CameraModel

    var body: some View {
        Button {
            ThumbnailButton.openPhotos(model)
        } label: {
            Label("Open Photos", systemImage: "photo.on.rectangle")
        }
        Button {
            ThumbnailButton.showGallery(model)
        } label: {
            Label("Show gallery", systemImage: "square.grid.3x3")
        }
        .disabled(!ThumbnailButton.canOpen(model))
    }
}

private struct ThumbnailImage: View {
    static let side: CGFloat = 48

    let picture: ThumbnailPicture

    var body: some View {
        let side = Self.side
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let image = picture.image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .id(picture.key)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if picture.isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(picture.image == nil ? 0.25 : 0.9), lineWidth: 1.5)
        }
        .frame(width: side, height: side)
    }
}

/// Rotates its content with the phone. Reading motion here instead of in the parent keeps the 30 Hz attitude
/// updates from redrawing whole control rows.
private struct Upright<Content: View>: View {
    let model: CameraModel
    // Built once in init: a stored closure never compares equal, so SwiftUI could never skip this view.
    let content: Content

    init(model: CameraModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content.uprightRotation(model.motion.iconRotationDegrees)
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    /// A press that lands on a layer above the button, such as its touch and hold menu.
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isPressed
        configuration.label
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(Theme.snappy, value: pressed)
            .contentShape(Rectangle())
    }
}
