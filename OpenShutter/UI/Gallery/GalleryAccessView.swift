import SwiftUI
import UIKit
import Photos
import PhotosUI

/// The gallery while it can't read the library: before the person was asked, after a no, or under restrictions. It
/// says what access would show and how to give it, and lists this session's captures, which the camera kept itself.
struct GalleryAccessView: View {
    let model: CameraModel
    let library: CaptureLibrary
    @State private var isAsking = false
    @State private var photosFailed = false

    var body: some View {
        let access = library.access
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Your photos from Open Shutter")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.message(for: access))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons(for: access)
                        .padding(.top, 4)
                    if photosFailed {
                        Text("Photos couldn't be opened.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            SessionCapturesList(model: model)
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut(duration: 0.2), value: photosFailed)
    }

    @ViewBuilder
    private func buttons(for access: LibraryAccess) -> some View {
        // Buttons in a list row need styles of their own: plain ones would all fire on any tap in the row.
        VStack(spacing: 10) {
            switch access {
            case .notAsked:
                Button {
                    askForAccess()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(GalleryProminentButtonStyle())
                .disabled(isAsking)
                .accessibilityHint("Asks for access to your photo library.")
                openPhotosButton
            case .denied:
                Button {
                    model.openAppSettings()
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(GalleryProminentButtonStyle())
                openPhotosButton
            case .restricted, .full, .limited:
                openPhotosButton
            }
        }
    }

    private var openPhotosButton: some View {
        Button {
            photosFailed = false
            PhotosApp.open { opened in
                photosFailed = !opened
            }
        } label: {
            Text("Open Photos")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Leaves Open Shutter and opens the Photos app.")
    }

    private func askForAccess() {
        isAsking = true
        Task {
            await library.requestAccess()
            isAsking = false
        }
    }

    private static func message(for access: LibraryAccess) -> String {
        switch access {
        case .notAsked, .full, .limited:
            return "To show and edit the photos and videos you take here, Open Shutter needs access to your "
                + "library. With Limited Access it sees only the photos you pick and the ones it takes."
        case .denied:
            return "Open Shutter can't see your library. Turn on access in Settings to see your photos here."
        case .restricted:
            return "Open Shutter can't see your library. Access to it is restricted on this iPhone."
        }
    }
}

/// The one-line note over the grid in limited mode, with the way to share more photos.
struct LimitedAccessBanner: View {
    /// Photos taken here that the limited selection leaves out.
    let missingCount: Int
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Shutter sees only some of your photos.")
                    .foregroundStyle(.primary)
                if missingCount > 0 {
                    Text("Some photos taken here aren't shared with Open Shutter.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button("Change", action: onChange)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityHint("Picks which photos Open Shutter can see.")
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The limited library picker has no SwiftUI modifier, so a hidden controller presents it. A selection change
/// reaches the library through its change observer, so nothing comes back here.
struct LimitedLibraryPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard isPresented, !coordinator.isScheduled else { return }
        coordinator.isScheduled = true
        let request = $isPresented
        // UIKit refuses a presentation in the middle of a view update, so it waits for the update to end.
        Task { @MainActor in
            coordinator.isScheduled = false
            request.wrappedValue = false
            guard controller.presentedViewController == nil else { return }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        }
    }

    final class Coordinator {
        var isScheduled = false
    }
}

/// A filled capsule in the accent, with the text color the accent needs in each appearance. The system's
/// prominent style draws white text, which can't be read on the yellow camera shade in a dark list.
struct GalleryProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentLabel(configuration: configuration)
    }

    private struct ProminentLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.accent, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Capsule())
                .animation(Theme.snappy, value: configuration.isPressed)
        }
    }
}
