import SwiftUI
import CameraCore

// The last capture's thumbnail beside the shutter. In a file of its own so the gallery work and the camera screen's
// layout don't share one file.

struct ThumbnailButton: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let capture = model.lastCapture
        let activity = model.activity
        let isHidden = activity == .recording || activity == .stacking
        let hasCaptures = !model.recentCaptures.isEmpty
        Button {
            Self.showRecent(model)
        } label: {
            Upright(model: model) {
                ThumbnailImage(capture: capture)
            }
        }
        // Before the first capture a tap has nothing to show, so the square stays still under the finger.
        .buttonStyle(PressScaleButtonStyle(isPressed: press.isPressed && hasCaptures))
        .disabled(!hasCaptures)
        .accessibilityLabel("Recent captures")
        .accessibilityValue(Self.spokenValue(capture, detailed: model.isAdvanced))
        .accessibilityHint("Touch and hold for more options.")
        .accessibilityAction(named: "Open Photos") { Self.openPhotos(model) }
        // Laid over the disabled button as well: Photos can be opened before anything has been captured.
        .overlay {
            ThumbnailTouchLayer(model: model, press: press)
        }
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .animation(Theme.spring, value: capture?.id)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
    }

    fileprivate static func showRecent(_ model: CameraModel) {
        guard !model.recentCaptures.isEmpty else { return }
        Haptics.tap()
        model.isDrawerOpen = false
        model.isReviewPresented = true
    }

    /// The review sheet's way into Photos, without the sheet.
    fileprivate static func openPhotos(_ model: CameraModel) {
        Haptics.tap()
        model.isDrawerOpen = false
        PhotosApp.open { opened in
            if !opened {
                model.showToast("Photos couldn't be opened.", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// The exposure summary is shutter speed and ISO, which the simple interface never shows or says.
    private static func spokenValue(_ capture: CaptureResult?, detailed: Bool) -> String {
        guard let capture else { return "None yet" }
        return detailed ? capture.summary : capture.kind.title(detailed: false)
    }
}

/// The thumbnail's tap and its touch and hold menu, laid over it. Its own view with inputs that never change, so a
/// new capture or a turn of the phone redraws the picture and leaves the system's menu button alone.
private struct ThumbnailTouchLayer: View {
    let model: CameraModel
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            ThumbnailButton.showRecent(model)
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
            ThumbnailButton.showRecent(model)
        } label: {
            Label("Show recent", systemImage: "clock")
        }
        .disabled(model.recentCaptures.isEmpty)
    }
}

private struct ThumbnailImage: View {
    let capture: CaptureResult?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let image = capture?.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .id(capture?.id)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if capture?.kind == .video {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(capture == nil ? 0.25 : 0.9), lineWidth: 1.5)
        }
        .frame(width: 48, height: 48)
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
