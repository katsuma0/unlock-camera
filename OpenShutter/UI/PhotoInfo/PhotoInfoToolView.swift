import SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers

/// Settings > Photo info: pick a picture from Photos or Files and see everything saved in it. The picker runs
/// outside the app, so this needs no library access; the file is read from a copy that goes when the page closes.
struct PhotoInfoToolView: View {
    @State private var tool = PhotoInfoTool()
    @State private var pickedItem: PhotosPickerItem?
    @State private var showsFiles = false

    var body: some View {
        List {
            Section {
                // `.current` hands over the file as Photos keeps it (HEIF, DNG, PNG), so nothing is converted and
                // its metadata comes along.
                PhotosPicker(selection: $pickedItem, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                .modifier(KeepPickedLocation())
                Button {
                    showsFiles = true
                } label: {
                    Label("Choose from Files", systemImage: "folder")
                }
            } footer: {
                Text("The photo you pick stays as it is. Photo info reads a copy and deletes it when you leave this page.")
            }
            .disabled(tool.isOpening)
            PickedSection(tool: tool)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Photo info")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $tool.shown) { file in
            PhotoInfoView(source: .file(file.url))
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: false) { result in
            Task { await tool.open(result) }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            // Cleared so the same photo can be picked again.
            pickedItem = nil
            Task { await tool.open(item) }
        }
        .task { await tool.sweep() }
    }
}

/// Opening, a failure, or the last file opened with a way back to it.
private struct PickedSection: View {
    let tool: PhotoInfoTool

    var body: some View {
        switch tool.status {
        case .opening:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Opening the photo")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        case .failed(let message):
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            EmptyView()
        }
        if let recent = tool.recent {
            Section {
                NavigationLink {
                    PhotoInfoView(source: .file(recent.url))
                } label: {
                    Text(recent.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if tool.rawSource != nil {
                    Button("Show the RAW file") {
                        Task { await tool.openRAW() }
                    }
                    .disabled(tool.isOpening)
                }
            } header: {
                Text("Last opened")
            } footer: {
                if tool.rawSource != nil {
                    Text("This photo also has a RAW file, with its own details.")
                }
            }
        }
    }
}

/// The picker keeps a photo's location unless told otherwise. iOS 27 adds a setting for it, which this sets to keep
/// everything, since showing the location is part of the point.
private struct KeepPickedLocation: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content.photosPickerMetadataOptions([])
        } else {
            content
        }
        #else
        content
        #endif
    }
}
