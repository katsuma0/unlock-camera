import SwiftUI
import Photos
import CameraCore

/// The photo editor, opened over the gallery's viewer. Adjust and Looks work on every photo, Crop on stills. Done
/// saves the edit into the photo, which Photos keeps the original of and can take off again; Save as copy leaves
/// the photo as it was and adds the edit beside it. The editor stays dark whatever the Settings look, since photos
/// are judged on black.
struct PhotoEditorView: View {
    let asset: PHAsset
    let library: CaptureLibrary

    @State private var session: PhotoEditSession
    @State private var tab = EditorTab.adjust
    @State private var adjustment = EditorAdjustment.exposure
    @State private var isStraightening = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingRevert = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(asset: PHAsset, library: CaptureLibrary) {
        self.asset = asset
        self.library = library
        _session = State(initialValue: PhotoEditSession(asset: asset, library: library))
    }

    var body: some View {
        let isReady = session.status == .ready && session.activity == nil
        VStack(spacing: 0) {
            EditorTopBar(session: session, cancel: cancel, done: done, saveCopy: saveCopy) {
                isConfirmingRevert = true
            }
            EditorCanvas(session: session, showsGrid: isStraightening) {
                dismiss()
            }
            EditorToolPanel(session: session, tab: $tab, adjustment: $adjustment, isStraightening: $isStraightening)
                .disabled(!isReady)
                .opacity(session.status == .ready ? 1 : 0.4)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay {
            if let activity = session.activity {
                EditorBusyOverlay(activity: activity)
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        // A swipe that closes the cover would lose the edit, or leave a save running behind it.
        .interactiveDismissDisabled(session.hasChanges || session.activity != nil)
        .task {
            await session.load()
        }
        .onDisappear {
            session.close()
        }
        .confirmationDialog("Discard changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                dismiss()
            }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Revert to original?", isPresented: $isConfirmingRevert, titleVisibility: .visible) {
            Button("Revert to original", role: .destructive, action: revert)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This takes every edit off the photo, including edits made in Photos.")
        }
        .alert(failure ?? "", isPresented: isShowingFailure) {
            Button("OK", role: .cancel) {}
        }
    }

    private var isShowingFailure: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )
    }

    private func cancel() {
        if session.hasChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func done() {
        guard session.activity == nil else { return }
        guard session.hasChanges else {
            dismiss()
            return
        }
        Task {
            if await session.save() {
                dismiss()
            } else {
                failure = "The edit couldn't be saved."
            }
        }
    }

    private func saveCopy() {
        guard session.activity == nil else { return }
        Task {
            if await session.saveCopy() {
                dismiss()
            } else {
                failure = "The copy couldn't be saved."
            }
        }
    }

    private func revert() {
        guard session.activity == nil else { return }
        Task {
            if await session.revert() {
                dismiss()
            } else {
                failure = "The original couldn't be restored."
            }
        }
    }
}

// MARK: - Top bar

/// Cancel on the left; on the right a menu with Save as copy and Revert to original, then Done, whose touch and
/// hold offers Save as copy too.
private struct EditorTopBar: View {
    let session: PhotoEditSession
    let cancel: () -> Void
    let done: () -> Void
    let saveCopy: () -> Void
    let revert: () -> Void

    var body: some View {
        let isReady = session.status == .ready && session.activity == nil
        HStack(spacing: 4) {
            Button(action: cancel) {
                Text("Cancel")
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.activity != nil)
            Spacer(minLength: 8)
            Menu {
                Button("Save as copy", systemImage: "plus.square.on.square", action: saveCopy)
                if session.canRevert {
                    Button("Revert to original", systemImage: "arrow.uturn.backward", role: .destructive,
                           action: revert)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .disabled(!isReady)
            .accessibilityLabel(Text("More"))
            Menu {
                Button("Save as copy", systemImage: "plus.square.on.square", action: saveCopy)
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isReady ? Theme.accent : Theme.tertiaryText)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            } primaryAction: {
                done()
            }
            .menuIndicator(.hidden)
            .disabled(!isReady)
            .accessibilityLabel(Text("Done"))
            .accessibilityHint(Text("Saves the edit. Touch and hold to save it as a copy."))
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }
}

// MARK: - Picture

/// The edit at preview size. Touch and hold shows the photo without it.
private struct EditorCanvas: View {
    let session: PhotoEditSession
    /// The thirds grid, while the straighten dial is held.
    let showsGrid: Bool
    let close: () -> Void

    @GestureState private var isPressing = false
    /// VoiceOver's way to the comparison, which has no touch and hold.
    @State private var isComparingForVoiceOver = false

    var body: some View {
        let isComparing = (isPressing || isComparingForVoiceOver) && session.original != nil
        ZStack {
            switch session.status {
            case .loading:
                EditorLoading(progress: session.downloadProgress)
            case .unavailable(let text):
                EditorNotice(text: text, close: close)
            case .ready:
                if let image = isComparing ? session.original : session.preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            if showsGrid, !isComparing {
                                ThirdsGrid()
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Photo"))
                        .accessibilityValue(Text(isComparing ? "Original" : "Edited"))
                        .accessibilityHint(Text("Touch and hold to see the original."))
                        .accessibilityAction(named: Text(isComparing ? "Show the edit" : "Show the original")) {
                            isComparingForVoiceOver.toggle()
                        }
                } else {
                    ProgressView()
                        .tint(Theme.primaryText)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Off until there is a picture to compare, so it can't stand in front of the notice's Close button.
        .gesture(compare, including: session.status == .ready ? .all : .subviews)
        .overlay(alignment: .top) {
            if isComparing {
                Text("Original")
                    .font(Theme.chipFont)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .cameraGlass(in: Capsule())
                    .padding(.top, 14)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Down is the original, up is the edit again. Gesture state resets by itself however the touch ends.
    private var compare: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressing) { _, pressing, _ in
                pressing = true
            }
    }
}

private struct EditorLoading: View {
    let progress: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                    .frame(width: 180)
                Text("Getting the photo from iCloud")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ProgressView()
                    .tint(Theme.primaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EditorNotice: View {
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Button("Close", action: close)
                .buttonStyle(GlassChipButtonStyle())
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 32)
    }
}

/// Lines at thirds, to line a horizon or a wall up against while straightening.
private struct ThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for share in [1.0 / 3, 2.0 / 3] {
                let x = size.width * share
                let y = size.height * share
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(Color.white.opacity(0.55)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Holds the editor still while Photos saves, which can take a few seconds for a 48 MP photo.
private struct EditorBusyOverlay: View {
    let activity: PhotoEditSession.Activity

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.primaryText)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .cameraGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var title: String {
        switch activity {
        case .saving: return "Saving"
        case .savingCopy: return "Saving a copy"
        case .reverting: return "Restoring the original"
        }
    }
}
