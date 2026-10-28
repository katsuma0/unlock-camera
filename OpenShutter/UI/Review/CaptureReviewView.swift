import SwiftUI
import UIKit

/// The captures from this session with their exposure summaries, and a way into Photos.
struct CaptureReviewView: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var openFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if model.recentCaptures.isEmpty {
                    ContentUnavailableView(
                        "No captures yet",
                        systemImage: "camera",
                        description: Text("Photos and videos you take while the app is open appear here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(model.recentCaptures) { capture in
                                CaptureRow(capture: capture)
                            }
                        } header: {
                            Text(Self.countLabel(model.recentCaptures.count))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Recent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                openInPhotosBar
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The rows use the camera's white text, so the sheet stays dark like Settings and the timer sheet.
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var openInPhotosBar: some View {
        VStack(spacing: 8) {
            Button {
                openPhotos()
            } label: {
                Label("Open in Photos", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in Photos")
            .accessibilityHint("Leaves Open Shutter and opens the Photos app.")
            if openFailed {
                Text("Photos couldn't be opened.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: openFailed)
    }

    private func openPhotos() {
        guard let url = URL(string: "photos-redirect://") else {
            openFailed = true
            return
        }
        let application = UIApplication.shared
        // canOpenURL only answers for schemes listed in LSApplicationQueriesSchemes and says no to the rest,
        // so it can rule Photos out only when the app declared the scheme. open(_:) needs no declaration.
        if Self.photosSchemeDeclared, !application.canOpenURL(url) {
            openFailed = true
            return
        }
        openFailed = false
        application.open(url, options: [:]) { success in
            openFailed = !success
        }
    }

    private static var photosSchemeDeclared: Bool {
        let schemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String]
        return schemes?.contains("photos-redirect") ?? false
    }

    private static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 capture this session" : "\(count) captures this session"
    }
}

private struct CaptureRow: View {
    let capture: CaptureResult

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(for: capture.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                if !capture.summary.isEmpty {
                    Text(capture.summary)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                Text(capture.date, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                if !capture.savedToLibrary {
                    Label("Not saved to Photos", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let image = capture.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: Self.symbol(for: capture.kind))
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.secondaryText)
            }
            if capture.thumbnail != nil, capture.kind != .photo {
                Image(systemName: Self.symbol(for: capture.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(4)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }

    private static func title(for kind: CaptureResult.Kind) -> String {
        switch kind {
        case .photo: return "Photo"
        case .raw: return "RAW photo"
        case .bracket: return "Bracket frame"
        case .stack: return "Stacked exposure"
        case .video: return "Video"
        }
    }

    private static func symbol(for kind: CaptureResult.Kind) -> String {
        switch kind {
        case .photo: return "photo"
        case .raw: return "r.square"
        case .bracket: return "square.stack.3d.up"
        case .stack: return "moon.stars"
        case .video: return "video.fill"
        }
    }
}
