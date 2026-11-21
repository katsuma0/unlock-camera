import SwiftUI
import UIKit
import Photos

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

    /// Copies of several assets for one share, in the order given, one at a time. Each goes in a folder of its own:
    /// the files are named by the second they were taken, so a burst or a photo and its edit would overwrite each
    /// other in one folder. The ones that fail are left out; a cancelled task returns what it has so far.
    static func exportCopies(of assets: [PHAsset], manager: PHImageManager,
                             progress: (Int) -> Void) async -> [URL] {
        let folder = newShareFolder()
        var urls: [URL] = []
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled { break }
            let place = folder.appendingPathComponent(String(index), isDirectory: true)
            if let url = try? await AssetRequests.exportCopy(of: asset, into: place, manager: manager) {
                urls.append(url)
            }
            progress(index + 1)
        }
        return urls
    }
}

/// How far a share of several photos has come, for its progress card.
struct ShareJob: Equatable {
    var done = 0
    let total: Int
}

/// The card over the grid while the photos for a share are copied out, which can take a while from iCloud.
struct ShareProgressCard: View {
    let job: ShareJob
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                .frame(width: 180)
            Text("Preparing \(min(job.done + 1, job.total)) of \(job.total)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
                .font(.subheadline.weight(.semibold))
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The system share sheet for files, presented from a hidden controller: it takes files known only once the
/// export is done, which ShareLink can't.
struct SharePresenter: UIViewControllerRepresentable {
    @Binding var urls: [URL]?
    let onFinish: () -> Void

    init(urls: Binding<[URL]?>, onFinish: @escaping () -> Void) {
        _urls = urls
        self.onFinish = onFinish
    }

    /// One file, as the viewer shares it.
    init(url: Binding<URL?>, onFinish: @escaping () -> Void) {
        _urls = Binding(get: { url.wrappedValue.map { [$0] } },
                        set: { url.wrappedValue = $0?.first })
        self.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let urls, !urls.isEmpty, !coordinator.isPresenting else { return }
        coordinator.isPresenting = true
        let binding = $urls
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
            let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
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
