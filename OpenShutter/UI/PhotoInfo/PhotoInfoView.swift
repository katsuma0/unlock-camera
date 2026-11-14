import SwiftUI
import UIKit
import Photos
import MapKit
import _MapKit_SwiftUI
import UniformTypeIdentifiers
import CameraCore

/// Where the photo info tool reads a picture from.
enum PhotoInfoSource {
    /// A file picked from Photos or Files, copied into the app's temporary folder.
    case file(URL)
    /// A photo in the library, read from its original resource.
    case asset(PHAsset)
}

/// Everything a picture's file says about it, and a copy without it. It sits inside the caller's navigation stack:
/// the photo info tool pushes it in Settings, and the gallery's viewer shows it in a sheet with a stack of its own.
struct PhotoInfoView: View {
    let source: PhotoInfoSource

    @State private var model: PhotoInfoModel

    init(source: PhotoInfoSource) {
        self.source = source
        _model = State(initialValue: PhotoInfoModel(source: source))
    }

    var body: some View {
        PhotoInfoPage(model: model)
            .navigationTitle("Photo info")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: model.generation) { await model.load() }
    }
}

// MARK: - Page

private struct PhotoInfoPage: View {
    let model: PhotoInfoModel

    var body: some View {
        switch model.phase {
        case .loading(let progress):
            PhotoInfoLoading(progress: progress)
                .background(Color(uiColor: .systemGroupedBackground))
        case .unavailable(let message):
            ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
                .background(Color(uiColor: .systemGroupedBackground))
        case .ready(let info):
            PhotoInfoList(info: info, model: model)
        }
    }
}

private struct PhotoInfoLoading: View {
    let progress: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("Downloading from iCloud")
            } else {
                ProgressView()
                Text("Reading the photo")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The whole list. Everything in it was made by the reader, so a redraw only lays it out; the parts that change
/// (the version picker, the copy) read the model in views of their own.
private struct PhotoInfoList: View {
    let info: PhotoInfo
    let model: PhotoInfoModel

    var body: some View {
        List {
            HeaderSection(info: info, model: model)
            if !info.summary.isEmpty {
                Section {
                    ForEach(info.summary) { PhotoInfoRowView(row: $0) }
                } header: {
                    Text("Summary")
                }
            }
            if let location = info.location {
                LocationSection(location: location, rows: info.locationRows)
            }
            if !info.appRows.isEmpty {
                Section {
                    ForEach(info.appRows) { PhotoInfoRowView(row: $0) }
                } header: {
                    Text("Open Shutter")
                } footer: {
                    Text("How Open Shutter took this photo.")
                }
            }
            RemoveMetadataSection(model: model, info: info)
            ForEach(info.sections) { section in
                Section {
                    OutlineGroup(section.rows, children: \.nested) { row in
                        PhotoInfoRowView(row: row)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer {
                        Text(footer)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Rows of a list come and go as it scrolls, so the exporter hangs off a view that stays.
        .background { CleanCopyExporter(model: model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CopyAllButton(text: info.plainText)
            }
        }
    }
}

// MARK: - Header

private struct HeaderSection: View {
    let info: PhotoInfo
    let model: PhotoInfoModel

    var body: some View {
        Section {
            if let thumbnail = info.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            VersionPicker(model: model)
            Group {
                LabeledContent("Name", value: info.fileName)
                LabeledContent("Type", value: info.typeName)
                if let size = info.sizeText {
                    LabeledContent("Size", value: size)
                }
                if let bytes = info.fileSize {
                    LabeledContent("File size", value: Formatting.fileSize(bytes: bytes))
                }
                if info.imageCount > 1 {
                    LabeledContent("Pictures in the file", value: String(info.imageCount))
                }
            }
            .textSelection(.enabled)
        } footer: {
            if info.hasPersonalRows {
                Text("Details marked \(Image(systemName: PhotoInfoRowView.personalSymbol)) can point to you, your phone or a place.")
            }
        }
    }
}

/// Edited, Original and RAW, for a library photo that has more than one file.
private struct VersionPicker: View {
    let model: PhotoInfoModel

    var body: some View {
        if model.versions.count > 1 {
            Picker("Version", selection: Binding(get: { model.version }, set: { model.select($0) })) {
                ForEach(model.versions) { version in
                    Text(version.title).tag(Optional(version))
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isCopying)
        }
    }
}

// MARK: - Rows

private struct PhotoInfoRowView: View {
    let row: PhotoInfoRow

    static let personalSymbol = "hand.raised.fill"

    var body: some View {
        LabeledContent {
            Text(row.value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            HStack(spacing: 4) {
                Text(row.title)
                if row.isPersonal {
                    Image(systemName: Self.personalSymbol)
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.isPersonal ? "Can point to you, your phone or a place." : "")
    }
}

// MARK: - Location

private struct LocationSection: View {
    let location: PhotoInfoLocation
    let rows: [PhotoInfoRow]

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        Section {
            // A picture of the spot, not a map to explore: the list scrolls past it.
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1000,
                                                            longitudinalMeters: 1000)),
                interactionModes: []) {
                Marker("Photo", coordinate: coordinate)
            }
            .frame(height: 180)
            .listRowInsets(EdgeInsets())
            .id(location.text)
            .accessibilityLabel("Map of where the photo was taken")
            ForEach(rows) { PhotoInfoRowView(row: $0) }
            if let url = location.mapsURL {
                Link(destination: url) {
                    Label("Open in Maps", systemImage: "map")
                }
            }
        } header: {
            Text("Location")
        }
    }
}

// MARK: - Remove metadata

private struct RemoveMetadataSection: View {
    @Bindable var model: PhotoInfoModel
    let info: PhotoInfo

    var body: some View {
        Section {
            Picker("Remove", selection: $model.mode) {
                ForEach(StripMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(model.isCopying)
            CopyResult(model: model)
        } header: {
            Text("Remove metadata")
        } footer: {
            SettingsFooter([model.mode.note, holdings, "The original stays as it is."])
        }
    }

    /// What the file holds, by the same kinds the result names.
    private var holdings: String {
        guard !info.categories.isEmpty else { return "This photo holds no metadata to remove." }
        return "This photo holds: " + info.categories.map(\.label).joined(separator: ", ") + "."
    }
}

/// Save to Files for the clean copy.
private struct CleanCopyExporter: View {
    @Bindable var model: PhotoInfoModel

    var body: some View {
        Color.clear
            .fileExporter(isPresented: $model.isExporting,
                          document: model.exportData.map { CleanCopyDocument(data: $0) },
                          contentType: exportType, defaultFilename: exportName) { _ in
                model.finishExport()
            }
    }

    private var cleanCopy: MetadataStripper.CleanCopy? {
        if case .ready(let clean) = model.copy { return clean }
        return nil
    }

    private var exportType: UTType {
        cleanCopy.flatMap { UTType($0.typeIdentifier) } ?? .image
    }

    /// Without its extension: the exporter adds the one its type uses.
    private var exportName: String? {
        cleanCopy.map { ($0.fileName as NSString).deletingPathExtension }
    }
}

/// Make a copy, then the copy's result and where it can go.
private struct CopyResult: View {
    let model: PhotoInfoModel

    var body: some View {
        switch model.copy {
        case .idle:
            Button("Make a copy") {
                Task { await model.makeCopy() }
            }
        case .working:
            HStack(spacing: 12) {
                ProgressView()
                Text("Making a copy")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await model.makeCopy() }
            }
        case .ready(let clean):
            Text(clean.summary)
            ForEach(clean.notes, id: \.self) { note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Copy", value: copyName(clean))
            ShareLink(item: clean.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            SaveToPhotosRow(model: model)
            Button {
                Task { await model.prepareExport() }
            } label: {
                Label("Save to Files", systemImage: "folder")
            }
        }
    }

    /// "IMG_0001 no metadata.HEIC, 2.1 MB".
    private func copyName(_ clean: MetadataStripper.CleanCopy) -> String {
        guard let bytes = clean.byteCount else { return clean.fileName }
        return clean.fileName + ", " + Formatting.fileSize(bytes: bytes)
    }
}

private struct SaveToPhotosRow: View {
    let model: PhotoInfoModel

    var body: some View {
        switch model.save {
        case .idle:
            button
        case .saving:
            HStack(spacing: 12) {
                ProgressView()
                Text("Saving to Photos")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        case .failed(let message):
            button
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var button: some View {
        Button {
            Task { await model.saveToPhotos() }
        } label: {
            Label("Save to Photos", systemImage: "photo.badge.plus")
        }
    }
}

/// The clean copy's bytes for the Files exporter, whose type is known only once the copy exists.
private struct CleanCopyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.image] }
    static var writableContentTypes: [UTType] { [.image, .heic, .heif, .jpeg, .png, .tiff, .gif, .bmp] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Copy all

private struct CopyAllButton: View {
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Haptics.success()
        } label: {
            Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
