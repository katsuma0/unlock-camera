import SwiftUI
import UIKit
import Photos
import CameraCore

/// The app's photos and videos, newest first, three to a row as in Photos. It follows the appearance setting; the
/// viewer it opens stays black.
struct GalleryGrid: View {
    let model: CameraModel
    let library: CaptureLibrary
    let zoomSpace: Namespace.ID
    /// The asset to keep in view, so the zoom back from the viewer lands on its cell.
    @Binding var scrollID: String?
    let onOpen: (String) -> Void
    let onChangeShared: () -> Void

    @State private var width: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    private static let spacing: CGFloat = 2
    private static let columnCount = 3

    var body: some View {
        let assets = library.assets
        let columns = Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: Self.columnCount)
        let cellPoints = max(0, (width - Self.spacing * CGFloat(Self.columnCount - 1)) / CGFloat(Self.columnCount))
        let pixelSide = (cellPoints * displayScale).rounded(.up)
        ScrollView {
            VStack(spacing: 0) {
                if library.access == .limited {
                    LimitedAccessBanner(missingCount: library.missingCount, onChange: onChangeShared)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                if let assets {
                    LazyVGrid(columns: columns, spacing: Self.spacing) {
                        ForEach(assets.identifiers, id: \.self) { id in
                            GridCell(model: model, library: library, asset: assets.asset(id: id), id: id,
                                     pixelSide: pixelSide, zoomSpace: zoomSpace) {
                                onOpen(id)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
            }
        }
        .scrollPosition(id: $scrollID, anchor: .center)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .overlay {
            if let assets {
                if assets.isEmpty {
                    ContentUnavailableView(
                        "No photos yet",
                        systemImage: "photo.on.rectangle",
                        description: Text("Photos and videos you take with Open Shutter appear here.")
                    )
                }
            } else {
                ProgressView()
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// One square of the grid: the picture, filled and cropped, with what Photos marks on it.
private struct GridCell: View {
    let model: CameraModel
    let library: CaptureLibrary
    let asset: PHAsset?
    let id: String
    /// 0 until the grid knows its width; nothing is asked for before then.
    let pixelSide: CGFloat
    let zoomSpace: Namespace.ID
    let onOpen: () -> Void

    @State private var image: UIImage?

    var body: some View {
        // The kind of capture is a camera term, so only the advanced interface names it.
        let detailed = model.isAdvanced
        let entry = library.entry(for: id)
        Button(action: onOpen) {
            Color(uiColor: .secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let asset, asset.mediaType == .video {
                        Text(Formatting.clock(asset.duration))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if asset?.isFavorite ?? false {
                        Image(systemName: "heart.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if detailed, let symbol = Self.symbol(for: entry?.kind) {
                        Image(systemName: symbol)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(4)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(GridCellButtonStyle())
        .matchedTransitionSource(id: id, in: zoomSpace)
        .accessibilityLabel(asset.map {
            GalleryText.spokenDescription(of: $0, detail: detailed ? GalleryText.detailTitle(entry?.kind) : nil)
        } ?? "Photo")
        .task(id: CellRequest(asset: asset, pixelSide: pixelSide)) {
            await load()
        }
    }

    private func load() async {
        guard let asset, pixelSide > 0 else { return }
        for await update in AssetRequests.thumbnail(for: asset, pixelSide: pixelSide, manager: library.imageManager) {
            if case .value(let picture, _) = update {
                image = picture
            }
        }
    }

    private static func symbol(for kind: CapturedAssetKind?) -> String? {
        switch kind {
        case .raw: return "r.square"
        case .bracket: return "square.stack.3d.up"
        case .stack: return "moon.stars"
        case .photo, .video, .edit, nil: return nil
        }
    }
}

/// A cell asks again when its asset changes (an edit in Photos) or the grid's width does.
private struct CellRequest: Hashable {
    let version: AssetVersion?
    let pixelSide: Int

    init(asset: PHAsset?, pixelSide: CGFloat) {
        version = asset.map(AssetVersion.init)
        self.pixelSide = pixelSide.isFinite ? Int(min(max(pixelSide, 0), 4_096)) : 0
    }
}

private struct GridCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
