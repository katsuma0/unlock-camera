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
    /// The copy of a new shot that flies here from the picture. The square keeps its last picture until it lands.
    let flight: CaptureFlight
    @State private var press = PressTracker()
    /// The picture the square shows. It trails the newest one while a shot is on its way here, and a frame that
    /// draws the new key before onChange has seen it still shows this one, so the square never shows the new shot
    /// ahead of its copy.
    @State private var shown: ThumbnailPicture?
    @Namespace private var galleryZoom
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let library = model.library
        let activity = model.activity
        let isHidden = activity == .recording || activity == .stacking
        let canOpen = Self.canOpen(model)
        let picture = ThumbnailPicture(capture: model.lastCapture, library: library)
        // The same key draws the live picture, so an image that changes under one key still comes through.
        let face = shown.map { $0.key == picture.key ? picture : $0 } ?? picture
        Button {
            Self.showGallery(model)
        } label: {
            Upright(model: model) {
                ThumbnailImage(picture: face)
            }
        }
        // With nothing to show a tap does nothing, so the square stays still under the finger.
        .buttonStyle(PressScaleButtonStyle(isPressed: press.isPressed && canOpen))
        .disabled(!canOpen)
        .accessibilityLabel("Photos")
        .accessibilityValue(picture.spokenValue)
        .accessibilityHint("Shows the photos and videos you took. Touch and hold to open Photos.")
        .accessibilityAction(named: "Open Photos") { Self.openPhotos(model) }
        // Laid over the disabled button as well: Photos can be opened before anything has been captured.
        .overlay {
            ThumbnailTouchLayer(model: model, press: press)
        }
        .matchedTransitionSource(id: GalleryZoom.thumbnail, in: galleryZoom)
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(CaptureFlight.space))
        } action: { frame in
            flight.thumbnailFrame = frame
        }
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .animation(Theme.fade, value: isHidden)
        .fullScreenCover(isPresented: $model.isReviewPresented) {
            GalleryView(model: model)
                .galleryZoomTransition(sourceID: GalleryZoom.thumbnail, in: galleryZoom)
        }
        .onChange(of: picture.key, initial: true) { _, key in
            guard shown != nil else {
                shown = picture
                return
            }
            if launchFlight(for: key) { return }
            // Anything that is not a fresh shot, and every shot with Reduce Motion: the squares cross-fade.
            withAnimation(.easeInOut(duration: 0.25)) { shown = picture }
        }
        .onAppear {
            // The newest photo comes back after a relaunch, but only where access was already given: this never asks.
            library.loadLatestThumbnail(pixelSide: (ThumbnailImage.side * displayScale).rounded(.up))
        }
    }

    /// Sends a copy of the shot just taken from the picture to the square, where it takes the square's place as it
    /// lands. Only for this session's newest capture, once its thumbnail exists: a Night shot or a HEIF photo
    /// arrives some time after the blink, and its flight starts then, as the picture is ready. False where nobody
    /// would see it fly, and the square cross-fades instead.
    private func launchFlight(for key: String?) -> Bool {
        guard let key, let capture = model.lastCapture, key == capture.id.uuidString, let image = capture.thumbnail,
              !AppearanceStore.shared.reduceMotion,
              model.activity != .recording, model.activity != .stacking,
              !model.isReviewPresented, !model.controlsFullscreen, !model.dimmer.isDimmed else { return false }
        let model = self.model
        return flight.launch(image: image, key: key, degrees: model.motion.iconRotationDegrees) {
            // The newest picture as it lands, built afresh: a later shot that took over the flight lands as its own.
            var still = Transaction(animation: nil)
            still.disablesAnimations = true
            withTransaction(still) {
                shown = ThumbnailPicture(capture: model.lastCapture, library: model.library)
            }
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

/// What the square shows: this session's last capture while it still exists (as edited, once it is), else the
/// newest photo the library shows, which brings the last photo back after a relaunch and steps past one deleted in
/// the gallery.
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
            if let id = capture.assetIdentifier, let image = library.latestThumbnail, library.latestThumbnailID == id,
               library.assets?.asset(id: id)?.hasAdjustments ?? false {
                // Edited in the gallery or in Photos, so the library's picture shows the edit. An unedited capture
                // keeps its own picture: the fetch after each shot would otherwise swap the square for the same one.
                key = id
                self.image = Image(uiImage: image)
            } else {
                key = capture.id.uuidString
                image = capture.thumbnail.map { Image(decorative: $0, scale: 1) }
            }
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

    /// The thumbnail's VoiceOver value: the exposure the camera reported, or for a photo from the library its stored
    /// summary where there is one.
    var spokenValue: String {
        if let capture { return capture.summary }
        if let entry {
            if !entry.summary.isEmpty { return entry.summary }
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
        // A tap already opens the gallery, so the menu only adds the way out to Photos.
        Button {
            ThumbnailButton.openPhotos(model)
        } label: {
            Label("Open Photos", systemImage: "photo.on.rectangle")
        }
    }
}

private struct ThumbnailImage: View {
    static let side: CGFloat = 48

    let picture: ThumbnailPicture

    var body: some View {
        let side = Self.side
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.trackFill)
            if let image = picture.image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .id(picture.key)
                    // A new shot arrives on its flying copy, which takes this place without a change of size, so
                    // only the pictures that come without one fade.
                    .transition(.opacity)
            }
            if picture.isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .legibleShadow()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // A fine rim like the chips': a hairline round an empty well, a brighter thin line round a picture,
                // which needs more to stand apart from a dark photo.
                .strokeBorder(picture.image == nil ? Theme.hairline : Color.white.opacity(0.85),
                              lineWidth: picture.image == nil ? Theme.hairlineWidth : 1)
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

/// PressScaleStyle's look, which also takes a press that lands on a layer above the button, such as its touch and
/// hold menu.
private struct PressScaleButtonStyle: ButtonStyle {
    var isPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isPressed
        configuration.label
            .scaleEffect(pressed ? PressScaleStyle().scale : 1)
            .animation(Theme.snappy, value: pressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Capture flight

/// A small copy of the shot just taken, gliding from the picture frame into the thumbnail after the blink. The
/// thumbnail asks for it and measures where it lands; the camera screen draws it over the controls
/// (CaptureFlightLayer), from the frame it lays out. Only what is drawn moves: the photo is saved and the next shot
/// can be taken while it flies.
@MainActor
@Observable
final class CaptureFlight {
    /// The coordinate space the camera screen lays its layers out in, the whole screen.
    nonisolated static let space = "camera"

    struct Shot: Identifiable {
        let id = UUID()
        let image: CGImage
        let key: String
        /// The turn the thumbnail wears, so the copy reads upright as the square does.
        let degrees: Double
    }

    /// The copy in the air.
    private(set) var shot: Shot?
    /// The thumbnail's frame in the camera's space. Not observed: the copy reads it once, as it sets off.
    @ObservationIgnored var thumbnailFrame: CGRect?
    @ObservationIgnored private var landing: (() -> Void)?

    /// A copy longer in the air than this has lost its view (the screen went away under it), and lands anyway, so
    /// the square never keeps an old picture.
    private static let longestFlight: UInt64 = 900_000_000

    /// Starts a flight, or false where there is nowhere to land. A newer shot takes over a copy still in the air,
    /// and only the newest lands.
    func launch(image: CGImage, key: String, degrees: Double, landed: @escaping () -> Void) -> Bool {
        guard let frame = thumbnailFrame, frame.width > 1, frame.height > 1 else { return false }
        let next = Shot(image: image, key: key, degrees: degrees)
        shot = next
        landing = landed
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.longestFlight)
            self?.land(next.id)
        }
        return true
    }

    /// The copy reached the square: the square takes the picture over in the same update the copy goes.
    func land(_ id: UUID) {
        guard shot?.id == id else { return }
        let landed = landing
        landing = nil
        var still = Transaction(animation: nil)
        still.disablesAnimations = true
        withTransaction(still) {
            shot = nil
            landed?()
        }
    }
}
