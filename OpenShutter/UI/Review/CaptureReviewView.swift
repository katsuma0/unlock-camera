import SwiftUI
import UIKit

/// The captures from this session, as a section of the gallery's pages that can't read the library: without read
/// access the thumbnails the camera kept are all the app can show. Nothing when the session has none.
struct SessionCapturesList: View {
    let model: CameraModel

    var body: some View {
        let captures = model.recentCaptures
        // The summaries are shutter speeds and ISO values, which belong to the advanced interface.
        let detailed = model.isAdvanced
        if !captures.isEmpty {
            Section {
                ForEach(captures) { capture in
                    CaptureRow(capture: capture, detailed: detailed)
                }
            } header: {
                Text(Self.countLabel(captures.count))
            }
        }
    }

    private static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 capture this session" : "\(count) captures this session"
    }
}

/// The way into the Photos app, shared by the gallery and the thumbnail's menu.
@MainActor
enum PhotosApp {
    /// Opens Photos and reports whether that worked.
    static func open(completion: @escaping @MainActor (Bool) -> Void) {
        guard let url = URL(string: "photos-redirect://") else {
            completion(false)
            return
        }
        let application = UIApplication.shared
        // canOpenURL only answers for schemes listed in LSApplicationQueriesSchemes and says no to the rest,
        // so it can rule Photos out only when the app declared the scheme. open(_:) needs no declaration.
        if schemeDeclared, !application.canOpenURL(url) {
            completion(false)
            return
        }
        application.open(url, options: [:]) { success in
            completion(success)
        }
    }

    private static var schemeDeclared: Bool {
        let schemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String]
        return schemes?.contains("photos-redirect") ?? false
    }
}

extension CaptureResult.Kind {
    /// What a capture is called in the session list and by VoiceOver on the thumbnail. The simple interface tells
    /// photos from videos and leaves it there.
    func title(detailed: Bool) -> String {
        guard detailed else { return self == .video ? "Video" : "Photo" }
        switch self {
        case .photo: return "Photo"
        case .raw: return "RAW photo"
        case .bracket: return "Bracket frame"
        case .stack: return "Stacked exposure"
        case .video: return "Video"
        }
    }
}

/// One capture with the thumbnail the camera kept. The list follows the appearance setting, so its text uses the
/// system's colors rather than the camera's white.
private struct CaptureRow: View {
    let capture: CaptureResult
    /// The advanced interface names the kind of capture and shows its exposure.
    let detailed: Bool

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.kind.title(detailed: detailed))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if detailed, !capture.summary.isEmpty {
                    Text(capture.summary)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(capture.date, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
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
                .fill(Color(uiColor: .tertiarySystemFill))
            if let image = capture.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: Self.symbol(for: capture.kind))
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            if capture.thumbnail != nil, capture.kind != .photo {
                // On the picture, so light on a dark disc in either appearance.
                Image(systemName: Self.symbol(for: capture.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(4)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
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
