import SwiftUI
import CoreLocation
import CameraCore

/// The settings sheet. Every control reads `model.settings` and writes through `model.updateSettings`, which saves
/// the change and re-applies it to the camera.
///
/// The form follows the interface level. The advanced one lists everything: rows the current camera can't use stay
/// visible but disabled, and their section footer says why, so nobody hunts for a switch that silently does nothing.
/// The simple one lists the few settings the simple interface runs on, in plain words.
struct SettingsView: View {
    @Bindable var model: CameraModel

    @Environment(\.dismiss) private var dismiss
    /// Made on first appearance: a default value would build a new location manager on every parent update.
    @State private var locationAccess: LocationPermissionWatcher? = nil

    var body: some View {
        NavigationStack {
            Form {
                InterfaceSection(model: model)
                InterfaceLevelSections(model: model, locationAccess: locationAccess)
                LookAndControlsSection(model: model)
                PhotoToolsSection()
                AboutSection(model: model)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // On the stack rather than the form, so the pages pushed from it get green switches too.
        .toggleStyle(SettingsSwitchStyle())
        .sheetAppearance()
        .onAppear {
            if locationAccess == nil {
                locationAccess = LocationPermissionWatcher()
            }
        }
    }
}

// MARK: - Interface level

/// The switch between the simple and the advanced interface. It leads the form at both levels, because it decides
/// what the rest of the form lists.
private struct InterfaceSection: View {
    let model: CameraModel

    private static let explanation = "Adds manual mode, RAW, the histogram and the detailed settings. Turning it off puts everything they changed back on automatic; turning it on again brings your settings back."
    private static let busyNote = "This can't change while a shot is in progress."

    var body: some View {
        // The model refuses the change under a running shot and says so in a toast, which this sheet covers. The
        // same conditions gray the switch out here, with the reason in the footer.
        let isBusy = !model.canChangeInterface
        Section {
            Toggle("Advanced controls", isOn: Binding(
                get: { model.isAdvanced },
                set: { model.setAdvanced($0) }
            ))
            .disabled(isBusy)
            .accessibilityHint(isBusy ? Self.busyNote : "")
        } footer: {
            SettingsFooter([Self.explanation, isBusy ? Self.busyNote : nil])
        }
    }
}

/// The sections of the interface in use, simple or advanced. Reading that here keeps it out of the form's own
/// body, which would otherwise re-run with every setting.
private struct InterfaceLevelSections: View {
    let model: CameraModel
    let locationAccess: LocationPermissionWatcher?

    var body: some View {
        if model.isAdvanced {
            CaptureSection(model: model, locationAccess: locationAccess)
            ExposureSection(model: model)
            FocusSection(model: model)
            ViewfinderSection(model: model)
            NightSection(model: model)
            LongExposureSection(model: model)
            BatterySaverSection(model: model)
            VideoSection(model: model)
            ControlsSection(model: model)
            CameraDetailsSection(capabilities: model.capabilities)
        } else {
            // The buttons and haptics the simple form listed here have their own page, linked from Look and
            // controls at both levels.
            SimplePhotosSection(model: model, locationAccess: locationAccess)
            SimpleViewfinderSection(model: model)
            BatterySaverSection(model: model)
            SimpleVideoSection(model: model)
        }
    }
}

// MARK: - Simple interface

// The simple form lists only what the simple interface runs on and names things by what they do. Everything else
// is on automatic there, so a row for it would describe something nobody can see.

private struct SimplePhotosSection: View {
    let model: CameraModel
    let locationAccess: LocationPermissionWatcher?

    var body: some View {
        let capture = model.settings.capture
        let photo = PhotoSupport(model.capabilities, isVideoMode: model.settings.mode == .video)

        Section {
            SettingsPicker("Format", selection: model.settingBinding(\.capture.processedFormat),
                         options: Self.formats(current: capture.processedFormat, photo: photo), label: Self.formatTitle)
            // Unlike the advanced form, a row the current camera can't use is left out: a dimmed switch and its
            // reason are more than this short form should carry.
            if photo.livePhoto {
                Toggle("Live Photos", isOn: model.settingBinding(\.capture.livePhoto))
            }
            Toggle("Mirror the front camera", isOn: model.settingBinding(\.capture.mirrorFront))
            Toggle("Location tags", isOn: model.settingBinding(\.capture.saveLocation))
            if capture.saveLocation, locationAccess?.isDenied == true {
                Button("Open Settings") { model.openAppSettings() }
            }
            if photo.silentShutter {
                Toggle("Quiet shutter", isOn: model.settingBinding(\.capture.silentShutter))
            }
            Toggle("Prioritize faster shooting", isOn: model.settingBinding(\.capture.prioritizeSpeed))
        } header: {
            Text("Photos")
        } footer: {
            SettingsFooter(Self.notes(capture: capture, photo: photo, access: locationAccess))
        }
    }

    /// High efficiency first, the default. The saved format keeps its row on a camera without it.
    private static func formats(current: ProcessedFormat, photo: PhotoSupport) -> [ProcessedFormat] {
        pickerOptions(photo.heif ? [.heif, .jpeg] : [.jpeg], current: current)
    }

    private static func formatTitle(_ format: ProcessedFormat) -> String {
        switch format {
        case .heif: return "High efficiency"
        case .jpeg: return "Most compatible"
        // Goes with RAW only, which this interface keeps off.
        case .none: return format.title
        }
    }

    private static func notes(capture: CaptureOptions, photo: PhotoSupport, access: LocationPermissionWatcher?) -> [String?] {
        var notes: [String?] = ["High efficiency photos take less space. Most compatible photos open in any app."]
        if capture.processedFormat == .heif, !photo.heif {
            notes.append("The current camera can't save high efficiency photos, so it saves most compatible ones.")
        }
        if photo.livePhoto {
            // The model records the Live movie in PHOTO only; unsaid, the switch would seem dead in the other modes.
            notes.append("Only photo mode takes Live Photos.")
        }
        notes.append(locationProblem(enabled: capture.saveLocation, access: access)
            ?? "Location tags add where each photo and video was taken. Location is only read while they are on.")
        notes.append("Every photo also records how it was taken, such as the lens and the camera's settings.")
        notes.append(simpleSpeedNote)
        return notes
    }
}

/// The simple interface's words for prioritize faster shooting; the advanced one names what gives way.
private let simpleSpeedNote = "Prioritize faster shooting keeps up when you take photos quickly, at a slightly lower quality, on iPhones that can."

private struct SimpleVideoSection: View {
    let model: CameraModel

    var body: some View {
        Section {
            Toggle("Allow audio playback", isOn: model.settingBinding(\.video.allowAudioPlayback))
        } header: {
            Text("Video")
        } footer: {
            Text(audioPlaybackNote)
        }
    }
}

/// What allowing audio playback means for the recording, for both forms.
private let audioPlaybackNote = "Music and other apps keep playing while you film. The microphone can pick them up."

/// Battery saver, at both levels. The setting is shared, and the steady status on the camera tells when it applies.
private struct BatterySaverSection: View {
    let model: CameraModel

    var body: some View {
        Section {
            Toggle("Battery saver", isOn: model.settingBinding(\.display.dimDuringLongShots))
        } footer: {
            Text("Darkens the screen during night and long exposure shots of 10 seconds or more, once the phone is steady. Touch the screen to see the shot. It lights up again when the shot ends.")
        }
    }
}

private struct SimpleViewfinderSection: View {
    let model: CameraModel

    var body: some View {
        Section {
            Toggle("Grid", isOn: gridBinding)
            Toggle("Level", isOn: model.settingBinding(\.display.showLevel))
        } header: {
            Text("Viewfinder")
        } footer: {
            Text("The grid divides the picture into thirds. The level line changes color when the phone is straight.")
        }
    }

    /// The simple interface has one grid, the thirds: the one its list offers besides Off, as in the drawer.
    private var gridBinding: Binding<Bool> {
        Binding(
            get: { model.settings.display.grid != .off },
            set: { isOn in
                let grid = CameraSettings.simpleGrids.first(where: { $0 != .off }) ?? .thirds
                model.updateSettings { $0.display.grid = isOn ? grid : .off }
            }
        )
    }
}

// MARK: - Capture

private struct CaptureSection: View {
    let model: CameraModel
    let locationAccess: LocationPermissionWatcher?

    var body: some View {
        let capture = model.settings.capture
        let photo = PhotoSupport(model.capabilities, isVideoMode: model.settings.mode == .video)

        Section {
            SettingsPicker("Format", selection: model.settingBinding(\.capture.processedFormat),
                         options: Self.formats(capture: capture, photo: photo)) { format in
                format == .none ? "RAW only" : format.title
            }
            SettingsPicker("RAW", selection: model.settingBinding(\.capture.rawFormat),
                         options: pickerOptions(Self.rawFormats(photo), current: capture.rawFormat), label: \.title)
                // Stays usable while RAW is set, so it can still be switched off on a camera without RAW.
                .disabled(!photo.bayerRAW && !photo.proRAW && capture.rawFormat == .none)
            SettingsPicker("Resolution", selection: model.settingBinding(\.capture.resolution),
                         options: pickerOptions(Self.resolutions(photo), current: capture.resolution), label: \.title)
            // Stays usable with RAW only: Night, Long exposure and the RAW-only fallback still save HEIF or JPEG.
            SettingsSlider(title: "Quality", value: capture.quality, range: 0.5...1, step: 0.05,
                          format: Formatting.percent) { quality in
                model.updateSettings { $0.capture.quality = quality }
            }
        } header: {
            Text("Capture")
        } footer: {
            SettingsFooter(Self.captureNotes(capture: capture, photo: photo, presets: model.lensPresets))
        }

        Section {
            Picker("Aspect ratio", selection: aspectBinding) {
                ForEach(Self.aspectOptions(current: capture.aspect)) { ratio in
                    Text(ratio.label).tag(ratio)
                }
            }
            CustomAspectRow(aspect: capture.aspect) { ratio in
                // The row saves a half-typed ratio as it goes away, and turning the advanced interface off takes
                // it away. By then the settings are the simple ones, which keep to their own three shapes.
                guard model.isAdvanced else { return }
                model.updateSettings { $0.capture.aspect = ratio }
            }
        } footer: {
            Text("Photos are cropped to this shape; video keeps the whole frame. For any other shape, enter its long and short sides under Custom, from 1 to 100.")
        }

        Section {
            SettingsPicker("Processing", selection: model.settingBinding(\.capture.processing),
                         options: pickerOptions(Self.processingLevels(photo), current: capture.processing), label: \.title)
            Toggle("Prioritize faster shooting", isOn: model.settingBinding(\.capture.prioritizeSpeed))
        } footer: {
            SettingsFooter([
                capture.processing.detail,
                Self.processingLimitNote(capture.processing, photo: photo),
                "Manual exposure always uses Minimal, so the shutter and ISO you set are kept.",
                "Prioritize faster shooting lets the camera lower the quality of photos taken in quick succession so it keeps up, on iPhones that support it.",
            ])
        }

        Section {
            Toggle("Live Photo", isOn: model.settingBinding(\.capture.livePhoto))
                .disabled(!photo.livePhoto || capture.rawFormat != .none)
            Toggle("Depth", isOn: model.settingBinding(\.capture.depth))
                .disabled(!photo.depth)
            Toggle("Constant color", isOn: model.settingBinding(\.capture.constantColor))
                .disabled(!photo.constantColor)
            Toggle("Lens correction", isOn: model.settingBinding(\.capture.lensCorrection))
                .disabled(!photo.lensCorrection)
            Toggle("Mirror front camera", isOn: model.settingBinding(\.capture.mirrorFront))
        } footer: {
            SettingsFooter(Self.featureNotes(capture: capture, photo: photo))
        }

        // The system refuses to mute the shutter where the law requires the sound, so the row only shows where it works.
        if photo.silentShutter {
            Section {
                Toggle("Silent shutter", isOn: model.settingBinding(\.capture.silentShutter))
            } footer: {
                Text("Not available in every region.")
            }
        }

        Section {
            Toggle("Location tags", isOn: model.settingBinding(\.capture.saveLocation))
            if capture.saveLocation, locationAccess?.isDenied == true {
                Button("Open Settings") { model.openAppSettings() }
            }
            SettingsTextRow(title: "Your name", value: capture.artist, prompt: "None") { name in
                model.updateSettings { $0.capture.artist = name }
            }
            SettingsTextRow(title: "Copyright", value: capture.copyright, prompt: "None") { line in
                model.updateSettings { $0.capture.copyright = line }
            }
        } header: {
            Text("Photo details")
        } footer: {
            SettingsFooter([
                Self.locationNote(enabled: capture.saveLocation, access: locationAccess),
                "Your name and the copyright line go into every photo and video, for apps that show who took it. Leave them empty to save neither.",
                "Every photo also records how it was taken: lens, focal length, shutter, ISO, aperture, white balance, exposure compensation and mode.",
            ])
        }
    }

    /// A saved ratio within half a percent of a preset reads as that preset, as in the quick settings drawer.
    private var aspectBinding: Binding<AspectRatio> {
        Binding(
            get: {
                let aspect = model.settings.capture.aspect
                return AspectRatio.presets.first(where: { $0.matches(aspect) }) ?? aspect
            },
            set: { ratio in model.updateSettings { $0.capture.aspect = ratio } }
        )
    }

    /// A custom ratio gets its own row, or the menu would show no selection.
    private static func aspectOptions(current: AspectRatio) -> [AspectRatio] {
        let presets = AspectRatio.presets
        return presets.contains(where: { $0.matches(current) }) ? presets : presets + [current]
    }

    /// "RAW only" is offered only while RAW is on, because every shot needs at least one file.
    private static func formats(capture: CaptureOptions, photo: PhotoSupport) -> [ProcessedFormat] {
        var supported: [ProcessedFormat] = [.jpeg]
        if photo.heif { supported.append(.heif) }
        if capture.rawFormat != .none { supported.append(.none) }
        return pickerOptions(supported, current: capture.processedFormat)
    }

    private static func rawFormats(_ photo: PhotoSupport) -> [RawFormat] {
        var supported: [RawFormat] = [.none]
        if photo.bayerRAW { supported.append(.bayer) }
        if photo.proRAW { supported.append(.proRAW) }
        return supported
    }

    /// The photo pipeline takes the largest size up to 10% above a megapixel choice, so a choice is only real when
    /// the camera has a size between 80% and 110% of it. Anything else would quietly deliver a different size.
    private static func resolutions(_ photo: PhotoSupport) -> [PhotoResolution] {
        guard let sizes = photo.sizes else { return PhotoResolution.allCases }
        return PhotoResolution.allCases.filter { resolution in
            guard let target = resolution.targetMegapixels else { return true }
            let wanted = Double(target) * 1_000_000
            return sizes.contains { size in
                let pixels = Double(size.pixelCount)
                return pixels >= wanted * 0.8 && pixels <= wanted * 1.1
            }
        }
    }

    private static func processingLevels(_ photo: PhotoSupport) -> [ProcessingLevel] {
        let levels = ProcessingLevel.allCases
        let limit = levels.firstIndex(of: photo.maxProcessing) ?? levels.count - 1
        return Array(levels.prefix(limit + 1))
    }

    private static func processingLimitNote(_ level: ProcessingLevel, photo: PhotoSupport) -> String? {
        let levels = ProcessingLevel.allCases
        guard let wanted = levels.firstIndex(of: level), let limit = levels.firstIndex(of: photo.maxProcessing),
              wanted > limit else { return nil }
        return "The current camera tops out at \(photo.maxProcessing.title)."
    }

    private static func captureNotes(capture: CaptureOptions, photo: PhotoSupport, presets: [LensPreset]) -> [String?] {
        var notes: [String?] = []
        if !photo.isReported {
            notes.append("In video mode the camera doesn't report its photo features, so the photo choices here aren't checked against it. Switch to a photo mode to see which ones the current camera supports.")
        }
        notes += rawNotes(capture: capture, photo: photo, presets: presets)
        if capture.processedFormat == .heif, !photo.heif {
            notes.append("The current camera can't save HEIF, so photos are saved as JPEG.")
        }
        if capture.processedFormat == .none {
            notes.append("Quality still applies to Night mode and long exposure photos, which are never RAW.")
        }
        if let sizes = photo.sizes {
            if !resolutions(photo).contains(capture.resolution) {
                notes.append("\(capture.resolution.title) isn't available with the current camera, so photos use the closest size.")
            }
            if let largest = sizes.last {
                notes.append("Largest photo with the current camera: \(largest.width)\u{00D7}\(largest.height) (\(largest.megapixelLabel)).")
            }
        }
        var unavailable = UnavailableFeatures()
        unavailable.note("HEIF", supported: photo.heif)
        unavailable.note("RAW", supported: photo.bayerRAW || photo.proRAW)
        notes.append(unavailable.text)
        return notes
    }

    /// Says what a shot really saves. The photo pipeline swaps ProRAW for Bayer RAW where ProRAW is missing,
    /// drops Bayer RAW at any zoom but a lens's own 1x, and saves a HEIF when RAW alone isn't possible.
    private static func rawNotes(capture: CaptureOptions, photo: PhotoSupport, presets: [LensPreset]) -> [String?] {
        let saved: RawFormat
        switch capture.rawFormat {
        case .none: return []
        case .proRAW: saved = photo.proRAW ? .proRAW : (photo.bayerRAW ? .bayer : .none)
        case .bayer: saved = photo.bayerRAW ? .bayer : .none
        }
        let fallback = photo.heif ? "HEIF" : "JPEG"
        let processed = capture.processedFormat == .jpeg ? "JPEG" : fallback
        guard saved != .none else {
            return [capture.processedFormat == .none
                ? "The current camera can't shoot RAW, so photos are saved as \(fallback)."
                : "The current camera can't shoot RAW, so only the \(processed) is saved."]
        }
        var notes: [String?] = []
        if saved != capture.rawFormat {
            notes.append("The current camera can't shoot \(capture.rawFormat.title), so it saves \(saved.title) instead.")
        }
        notes.append(capture.processedFormat == .none
            ? "Each shot saves only the \(saved.title) file."
            : "Each shot saves \(saved.title) and \(processed) together.")
        if saved == .bayer {
            // With RAW only a zoomed shot still saves something, because the pipeline falls back to HEIF or JPEG.
            let outcome = capture.processedFormat == .none ? "save a \(fallback) instead" : "skip it"
            // Older Pro phones have a real 2x lens, so the zoomed buttons are named from the presets, not assumed.
            let cropped = presets.filter { abs($0.zoomFactor - 1) > 0.01 }.map(\.selectedLabel)
            notes.append(cropped.first.map { "RAW is saved only at each lens's own zoom; zoomed views such as \($0) \(outcome)." }
                ?? "RAW is saved only at each lens's own zoom; zoomed photos \(outcome).")
        }
        return notes
    }

    private static func featureNotes(capture: CaptureOptions, photo: PhotoSupport) -> [String?] {
        var notes: [String?] = []
        if capture.rawFormat != .none, photo.livePhoto {
            notes.append("Live Photo is off while RAW is on.")
        }
        if capture.depth, photo.depth {
            // Depth maps come at the sensor's own 4:3, and the photo pipeline embeds them only there.
            notes.append(capture.aspect.matches(.fourThree)
                ? "Depth is saved only with 4:3 photos that have no RAW file."
                : "Depth is saved only with 4:3 photos that have no RAW file, so photos at \(capture.aspect.label) have none.")
        }
        if photo.constantColor {
            // The photo pipeline skips it without a flash, with RAW, and with locked white balance (Apple's advice).
            notes.append("Constant color uses the flash to remove the color cast of room light. It needs the flash on or set to auto, auto white balance, and RAW off.")
        }
        if photo.lensCorrection {
            notes.append("Lens correction straightens stretched edges, mostly on the ultra wide.")
        }
        notes.append("Mirror front camera saves selfies the way the preview shows them.")
        var unavailable = UnavailableFeatures()
        unavailable.note("Live Photo", supported: photo.livePhoto)
        unavailable.note("depth", supported: photo.depth)
        unavailable.note("constant color", supported: photo.constantColor)
        unavailable.note("lens correction", supported: photo.lensCorrection)
        notes.append(unavailable.text)
        return notes
    }

    private static func locationNote(enabled: Bool, access: LocationPermissionWatcher?) -> String {
        locationProblem(enabled: enabled, access: access)
            ?? "Location tags add where each photo and video was taken. Location is only read while they are on."
    }
}

/// What the photo side of the current camera can do, as the Capture rows need it. VIDEO takes the photo output
/// out of the session, so the capabilities there read as "no HEIF, no RAW, no Live Photo" and list the video
/// format's sizes. Rather than gray out every photo row, VIDEO leaves every choice open; the photo pipeline
/// checks each one against the output again when a photo is taken.
private struct PhotoSupport {
    /// iOS delivers 24 MP only through deferred photo delivery, which the photo pipeline keeps off, so asking
    /// for it would quietly save a 12 MP photo.
    private static let deferredOnlySize = PixelSize(width: 5712, height: 4284)

    /// False in VIDEO, where nothing below comes from the camera.
    let isReported: Bool
    let heif: Bool
    let bayerRAW: Bool
    let proRAW: Bool
    let livePhoto: Bool
    let depth: Bool
    let constantColor: Bool
    let lensCorrection: Bool
    /// Stays false in VIDEO: the row only shows where the system allows a silent shutter.
    let silentShutter: Bool
    let maxProcessing: ProcessingLevel
    /// Sizes a photo can come out at, ascending. nil in VIDEO, where every size choice is offered.
    let sizes: [PixelSize]?

    init(_ caps: CameraCapabilities, isVideoMode: Bool) {
        isReported = !isVideoMode
        silentShutter = !isVideoMode && caps.shutterSoundSuppressionSupported
        if isVideoMode {
            heif = true
            bayerRAW = true
            proRAW = true
            livePhoto = true
            depth = true
            constantColor = true
            lensCorrection = true
            maxProcessing = .maximum
            sizes = nil
        } else {
            heif = caps.heifSupported
            bayerRAW = caps.rawSupported
            proRAW = caps.proRAWSupported
            livePhoto = caps.livePhotoSupported
            depth = caps.depthSupported
            constantColor = caps.constantColorSupported
            lensCorrection = caps.geometricCorrectionSupported || caps.contentAwareCorrectionSupported
            maxProcessing = caps.maxProcessing
            sizes = caps.photoDimensions.filter { $0 != Self.deferredOnlySize }
        }
    }
}

/// Any shape the presets miss, from its two sides: 1.85 and 1 for cinema, 7 and 6 for a squarer frame. Typed
/// sides are saved when editing ends, so a half-typed number never reaches the crop. A lone side that crosses the
/// saved other side waits for that side too: 1.85 typed as the long side of 4:3 is half of 1.85:1, not 3:1.85.
private struct CustomAspectRow: View {
    let aspect: AspectRatio
    let onCommit: (AspectRatio) -> Void

    private enum Side: Hashable {
        case long, short
    }

    /// Text typed but not saved yet; nil shows the saved side.
    @State private var longText: String?
    @State private var shortText: String?
    @FocusState private var editing: Side?

    private static let range = 1.0...100.0

    var body: some View {
        HStack(spacing: 6) {
            Text("Custom")
            Spacer(minLength: 8)
            field("Long side", draft: $longText, saved: aspect.long, side: .long)
            Text(":")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field("Short side", draft: $shortText, saved: aspect.short, side: .short)
        }
        // Moving from one field to the other keeps the draft; leaving both saves it.
        .onChange(of: editing) { _, side in
            if side == nil { commit() }
        }
        // A preset picked while a side is half typed wins, instead of being overwritten by the draft on Done.
        .onChange(of: aspect) {
            longText = nil
            shortText = nil
        }
        // Closing Settings with the keyboard still up keeps what was typed, even a side still waiting for the other.
        .onDisappear { commit(force: true) }
        .toolbar {
            // The decimal pad has no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = nil }
            }
        }
    }

    // Plain text rather than a formatted value field, which may hand over its value only after the focus change
    // that saves it.
    private func field(_ title: String, draft: Binding<String?>, saved: Double, side: Side) -> some View {
        TextField(title, text: Binding(get: { draft.wrappedValue ?? Self.text(saved) }, set: { draft.wrappedValue = $0 }))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($editing, equals: side)
            .frame(width: 64)
    }

    private func commit(force: Bool = false) {
        guard longText != nil || shortText != nil else { return }
        let long = Self.side(longText)
        let short = Self.side(shortText)
        // Saved now, the sides would swap and the side typed next would pair with the wrong one: 1.85 and then 1
        // over 4:3 would save 3:1.
        if !force, (long == nil) != (short == nil),
           (long.map { $0 < aspect.short } ?? false) || (short.map { $0 > aspect.long } ?? false) {
            return
        }
        let typed = AspectRatio(long ?? aspect.long, short ?? aspect.short)
        longText = nil
        shortText = nil
        // 16 and 9, or 1.78 and 1, is a preset, so it takes the preset's name and checkmark.
        let ratio = AspectRatio.presets.first(where: { $0.matches(typed) }) ?? typed
        if ratio != aspect {
            onCommit(ratio)
        }
    }

    private static func text(_ side: Double) -> String {
        side.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// The typed number in the user's locale (a decimal comma too), to two decimals within 1 to 100. nil when
    /// nothing usable was typed, which keeps the saved side.
    private static func side(_ text: String?) -> Double? {
        guard let text, let value = try? Double(text, format: .number), value.isFinite else { return nil }
        return min(max((value * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }
}

// MARK: - Exposure

private struct ExposureSection: View {
    let model: CameraModel

    /// Slowest first, the way the limit reads on a camera menu.
    private static let autoExposureLimits: [Double] = [
        1, 1.0 / 2, 1.0 / 4, 1.0 / 8, 1.0 / 15, 1.0 / 30, 1.0 / 60, 1.0 / 125, 1.0 / 250, 1.0 / 500,
    ]

    /// Ratios of aperture area between frames (AVFoundation's unit). At 30 fps, 1.25 crosses an f/1.5 to f/4 iris
    /// in about a third of a second, 1.05 in about one and a half, 1.02 in about three.
    private static let apertureSpeeds: [(ratio: Double, title: String)] = [
        (1.25, "Fast"), (1.05, "Smooth"), (1.02, "Very smooth"),
    ]

    var body: some View {
        let exposure = model.settings.exposure
        let caps = model.capabilities

        Section {
            Picker("Auto exposure limit", selection: model.settingBinding(\.exposure.aeMaxShutter)) {
                Text("Auto").tag(Double?.none)
                ForEach(Self.limitOptions(current: exposure.aeMaxShutter, longest: caps.exposure.seconds.upperBound),
                        id: \.self) { seconds in
                    Text(ShutterSpeed(seconds: seconds).label).tag(Double?.some(seconds))
                }
            }
            SettingsPicker("Metering area", selection: model.settingBinding(\.exposure.meteringArea),
                         options: MeteringArea.allCases, label: \.title)
                .disabled(!caps.supportsMeteringArea)
            SettingsPicker("Face-driven exposure", selection: model.settingBinding(\.exposure.faceDriven),
                         options: TriState.allCases, label: \.title)
                .disabled(!caps.faceDrivenAutoExposureSupported)
            Toggle("Low light boost", isOn: model.settingBinding(\.exposure.lowLightBoost))
                .disabled(!caps.lowLightBoostSupported)
            Toggle("Global tone mapping", isOn: model.settingBinding(\.exposure.globalToneMapping))
                .disabled(!caps.globalToneMappingSupported)
            SettingsPicker("Video HDR", selection: model.settingBinding(\.exposure.videoHDR),
                         options: TriState.allCases, label: \.title)
                .disabled(!Self.videoHDRAvailable(caps))
            Picker("Aperture speed", selection: model.settingBinding(\.exposure.apertureRateLimit)) {
                Text("Auto").tag(Double?.none)
                ForEach(Self.speedOptions(current: exposure.apertureRateLimit), id: \.ratio) { option in
                    Text(option.title).tag(Double?.some(option.ratio))
                }
            }
            .disabled(!caps.supportsVariableAperture)
        } header: {
            Text("Exposure")
        } footer: {
            SettingsFooter(Self.notes(caps: caps))
        }
    }

    /// Limits the current camera can expose for, plus the saved one so the menu always shows a selection.
    private static func limitOptions(current: Double?, longest: Double) -> [Double] {
        // The same 2% slack as the shutter dials, so a camera that reports a hair under 1 s still offers 1 s.
        let reachable = autoExposureLimits.filter { $0 <= longest * 1.02 }
        guard let current, !reachable.contains(current) else { return reachable }
        return (reachable + [current]).sorted(by: >)
    }

    private static func speedOptions(current: Double?) -> [(ratio: Double, title: String)] {
        guard let current, !apertureSpeeds.contains(where: { $0.ratio == current }) else { return apertureSpeeds }
        // A saved ratio from elsewhere still needs a row, or the menu would show nothing selected.
        let custom = (ratio: current, title: String(format: "%.2f\u{00D7} per frame", current))
        return (apertureSpeeds + [custom]).sorted { $0.ratio > $1.ratio }
    }

    /// The active format's flag alone would gray this out in photo modes, where a photo format is active even
    /// though the lens records HDR video. Any HDR-capable format of the lens makes the setting worth having.
    private static func videoHDRAvailable(_ caps: CameraCapabilities) -> Bool {
        caps.videoHDRSupported || caps.formats.contains(where: \.supportsVideoHDR)
    }

    private static func notes(caps: CameraCapabilities) -> [String?] {
        var notes: [String?] = [
            // The model hands VIDEO a limit of one frame instead, so the picker doesn't apply there.
            "Auto exposure limit is the slowest shutter auto exposure may pick. A faster limit keeps moving subjects sharp and raises ISO instead; a slower one keeps ISO down in dim light but blurs motion. In video mode the frame rate sets the limit.",
        ]
        if caps.supportsMeteringArea {
            notes.append("Metering area sets what auto exposure measures: Auto reads the area around the point you tap, Spot only a small spot there, and Whole frame the entire picture.")
        }
        if caps.globalToneMappingSupported {
            notes.append("Global tone mapping uses one tone curve for the whole frame and turns off multi-frame fusion.")
        }
        if caps.supportsVariableAperture {
            notes.append("Aperture speed sets how quickly auto exposure may move the iris. Smooth suits video.")
        } else if !UnavailableFeatures.runsIOS27 {
            notes.append("Aperture speed needs iOS 27 and a lens with a variable aperture.")
        } else if !UnavailableFeatures.hasIOS27Code {
            notes.append("Aperture speed needs an Xcode 27 build and a lens with a variable aperture.")
        } else {
            notes.append("Aperture speed needs a lens with a variable aperture.")
        }
        var unavailable = UnavailableFeatures()
        unavailable.noteFromIOS26("metering area", supported: caps.supportsMeteringArea)
        unavailable.note("face-driven exposure", supported: caps.faceDrivenAutoExposureSupported)
        unavailable.note("low light boost", supported: caps.lowLightBoostSupported)
        unavailable.note("global tone mapping", supported: caps.globalToneMappingSupported)
        unavailable.note("video HDR", supported: videoHDRAvailable(caps))
        notes.append(unavailable.text)
        return notes
    }
}

// MARK: - Focus

private struct FocusSection: View {
    let model: CameraModel

    var body: some View {
        let caps = model.capabilities

        Section {
            SettingsPicker("Focus range", selection: model.settingBinding(\.focusOptions.range),
                         options: FocusRange.allCases, label: \.title)
                .disabled(!caps.focusRangeRestrictionSupported)
            Toggle("Smooth autofocus", isOn: model.settingBinding(\.focusOptions.smooth))
                .disabled(!caps.smoothFocusSupported)
            SettingsPicker("Face-driven focus", selection: model.settingBinding(\.focusOptions.faceDriven),
                         options: TriState.allCases, label: \.title)
                .disabled(!caps.faceDrivenAutoFocusSupported)
            Toggle("Subject tracking", isOn: model.settingBinding(\.focusOptions.continuousTracking))
                .disabled(!caps.continuousAFTrackingSupported)
        } header: {
            Text("Focus")
        } footer: {
            SettingsFooter(Self.notes(caps: caps))
        }
    }

    private static func notes(caps: CameraCapabilities) -> [String?] {
        var unavailable = UnavailableFeatures()
        unavailable.note("focus range", supported: caps.focusRangeRestrictionSupported)
        unavailable.note("smooth autofocus", supported: caps.smoothFocusSupported)
        unavailable.note("face-driven focus", supported: caps.faceDrivenAutoFocusSupported)
        unavailable.noteFromIOS27("subject tracking", supported: caps.continuousAFTrackingSupported)
        return [
            "Near and Far keep autofocus from searching the whole range. Smooth autofocus makes gentler focus changes for video.",
            "Subject tracking keeps focus on a moving subject.",
            unavailable.text,
        ]
    }
}

// MARK: - Viewfinder

private struct ViewfinderSection: View {
    let model: CameraModel

    var body: some View {
        let display = model.settings.display

        Section {
            SettingsPicker("Grid", selection: model.settingBinding(\.display.grid),
                         options: GridStyle.allCases, label: \.title)
            Toggle("Level", isOn: model.settingBinding(\.display.showLevel))
            SettingsPicker("Histogram", selection: model.settingBinding(\.display.histogram),
                         options: HistogramStyle.allCases, label: \.title)
            Toggle("Exposure readout", isOn: model.settingBinding(\.display.showReadout))
            Toggle("Clipping warning", isOn: model.settingBinding(\.display.clippingWarnings))
        } header: {
            Text("Viewfinder")
        } footer: {
            Text("The readout runs along the bottom of the viewfinder: shutter, ISO, aperture, EV, white balance and focus (narrow phones drop focus, then white balance). The clipping warning appears when highlights lose detail.")
        }

        Section {
            Toggle("Zebras", isOn: model.settingBinding(\.display.zebras))
            if display.zebras {
                SettingsSlider(title: "Zebra level", value: display.zebraThreshold, range: 0.7...1, step: 0.01,
                              format: Formatting.percent) { level in
                    model.updateSettings { $0.display.zebraThreshold = level }
                }
            }
        } footer: {
            Text("Stripes cover everything at or above the zebra level, so highlights about to clip stand out.")
        }

        Section {
            SettingsPicker("Focus peaking", selection: model.settingBinding(\.display.peaking),
                         options: PeakingMode.allCases, label: \.title)
            if display.peaking != .off {
                PeakingColorRow(selection: display.peakingColor) { color in
                    model.updateSettings { $0.display.peakingColor = color }
                }
                SettingsSlider(title: "Sensitivity", value: display.peakingSensitivity, range: 0...1, step: 0.05,
                              format: Formatting.percent) { sensitivity in
                    model.updateSettings { $0.display.peakingSensitivity = sensitivity }
                }
            }
        } footer: {
            Text("Peaking outlines edges that are in focus. Manual focus shows it only while you focus by hand. Higher sensitivity marks softer edges too.")
        }

        Section {
            Toggle("False color", isOn: model.settingBinding(\.display.falseColor))
            if display.falseColor {
                FalseColorLegend()
            }
        } footer: {
            Text("False color paints brightness as color: purple and blue for deep shadows, green for middle gray, pink for skin, yellow and red for highlights about to clip.")
        }
    }
}

// MARK: - Night

private struct NightSection: View {
    let model: CameraModel

    private static let maxISOChoices: [Double] = [800, 1600, 3200, 6400, 12800]
    /// Night shots rarely want more than a few stops either way; the dial on the camera screen covers the rest.
    private static let biasLimit = 3.0

    var body: some View {
        let night = model.settings.night
        let caps = model.capabilities
        let biasRange = Self.biasRange(caps.biasRange, current: night.biasEV)

        Section {
            SettingsPicker("Stability", selection: model.settingBinding(\.night.stability),
                         options: NightStabilityChoice.allCases, label: \.title)
            Toggle("Align frames", isOn: model.settingBinding(\.night.alignFrames))
            SettingsPicker("Maximum ISO", selection: model.settingBinding(\.night.maxISO),
                         options: pickerNumbers(Self.maxISOChoices, current: night.maxISO), label: ISOScale.label)
            Stepper(value: biasBinding(range: biasRange), in: biasRange, step: 1.0 / 3.0) {
                HStack {
                    Text("Exposure")
                    Spacer()
                    Text(EVFormat.label(night.biasEV) + " EV")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(biasRange.upperBound - biasRange.lowerBound < 1.0 / 3.0)
        } header: {
            Text("Night mode")
        } footer: {
            SettingsFooter(Self.notes(night: night, caps: caps))
        }
    }

    /// Snapped to thirds so repeated steps can't drift into values like 0.9999.
    private func biasBinding(range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { model.settings.night.biasEV },
            set: { newValue in
                let snapped = min(max(EVFormat.snap(newValue, step: .third), range.lowerBound), range.upperBound)
                model.updateSettings { $0.night.biasEV = snapped }
            }
        )
    }

    /// The device's bias range, capped at three stops, widened to keep a value set from the camera screen reachable.
    private static func biasRange(_ device: ClosedRange<Double>, current: Double) -> ClosedRange<Double> {
        let reach = min(biasLimit, max(0, -device.lowerBound), max(0, device.upperBound))
        let thirds = (reach * 3).rounded(.down) / 3
        let safeCurrent = current.isFinite ? current : 0
        return min(-thirds, safeCurrent)...max(thirds, safeCurrent)
    }

    private static func notes(night: NightSettings, caps: CameraCapabilities) -> [String?] {
        var notes: [String?] = [
            "Auto uses longer frames while the phone is held still. Tripod uses the longest frames the camera allows.",
            "Align frames lines up the frames to undo small hand movements. Night mode keeps each frame at or below the maximum ISO.",
        ]
        let deviceMax = caps.exposure.iso.upperBound
        if night.maxISO > deviceMax {
            notes.append("The current camera tops out at \(ISOScale.label(deviceMax)).")
        }
        return notes
    }
}

// MARK: - Long exposure

private struct LongExposureSection: View {
    let model: CameraModel

    private static let bulbLimits: [Double] = [60, 120, 300, 600, 900, 1800]

    var body: some View {
        let long = model.settings.longExposure

        Section {
            SettingsPicker("Blend", selection: model.settingBinding(\.longExposure.blend),
                         options: StackBlend.allCases, label: \.title)
            Toggle("Align frames", isOn: model.settingBinding(\.longExposure.align))
            SettingsPicker("Bulb limit", selection: model.settingBinding(\.longExposure.maxBulbSeconds),
                         options: pickerNumbers(Self.bulbLimits, current: long.maxBulbSeconds), label: Self.durationLabel)
        } header: {
            Text("Long exposure")
        } footer: {
            SettingsFooter([
                "\(long.blend.title): \(long.blend.detail)",
                "Align frames corrects small camera movement between frames. A bulb exposure stops on its own at the bulb limit.",
            ])
        }
    }

    private static func durationLabel(_ seconds: Double) -> String {
        // A saved value comes back from disk as any Double, and Int(_:) traps on one out of range.
        guard seconds.isFinite, seconds > 0, seconds < 360_000 else { return "Custom" }
        let whole = Int(seconds.rounded())
        return whole >= 60 && whole % 60 == 0 ? "\(whole / 60) min" : Formatting.compactDuration(seconds)
    }
}

// MARK: - Video

private struct VideoSection: View {
    let model: CameraModel

    var body: some View {
        let video = model.settings.video
        let caps = model.capabilities
        let formats = caps.formats

        Section {
            SettingsPicker("Resolution", selection: fittedBinding(\.resolution, formats: formats),
                         options: pickerOptions(VideoFormatChoices.resolutions(colorMode: video.colorMode, formats: formats),
                                          current: video.resolution),
                         label: \.title)
            SettingsPicker("Frame rate", selection: fittedBinding(\.frameRate, formats: formats),
                         options: pickerNumbers(VideoFormatChoices.frameRates(resolution: video.resolution,
                                                                         colorMode: video.colorMode, formats: formats),
                                                 current: video.frameRate),
                         label: Self.frameRateLabel)
            SettingsPicker("Codec", selection: model.settingBinding(\.video.codec),
                         options: pickerOptions(caps.videoCodecs, current: video.codec), label: \.title)
            SettingsPicker("Color", selection: fittedBinding(\.colorMode, formats: formats),
                         options: pickerOptions(caps.colorModes, current: video.colorMode), label: \.title)
            SettingsPicker("Stabilization", selection: model.settingBinding(\.video.stabilization),
                         options: pickerOptions(caps.stabilizationModes, current: video.stabilization), label: \.title)
            Toggle("Record sound", isOn: model.settingBinding(\.video.audio))
            // Without sound the camera leaves the audio session alone, so other apps keep playing anyway.
            Toggle("Allow audio playback", isOn: model.settingBinding(\.video.allowAudioPlayback))
                .disabled(!video.audio)
            Toggle("Wind noise reduction", isOn: model.settingBinding(\.video.windNoiseReduction))
                .disabled(!video.audio)
            Toggle("Low light noise reduction", isOn: model.settingBinding(\.video.lowLightNoiseReduction))
                .disabled(!caps.lowLightVideoNoiseReductionSupported)
            Toggle("Shutter angle", isOn: model.settingBinding(\.video.showShutterAngle))
        } header: {
            Text("Video")
        } footer: {
            SettingsFooter(Self.notes(video: video, caps: caps, isVideoMode: model.settings.mode == .video))
        }
    }

    /// Writes one field, then moves resolution and frame rate to the nearest combination a format can record,
    /// so a pick in one menu never leaves the others asking for something the camera doesn't have.
    private func fittedBinding<Value>(_ keyPath: WritableKeyPath<VideoSettings, Value>,
                                      formats: [FormatDescriptor]) -> Binding<Value> {
        Binding(
            get: { model.settings.video[keyPath: keyPath] },
            set: { newValue in
                model.updateSettings { settings in
                    settings.video[keyPath: keyPath] = newValue
                    settings.video = VideoFormatChoices.fitted(settings.video, formats: formats)
                }
            }
        )
    }

    /// The saved rate is shown even when the camera lacks it, and Formatting.frameRate converts to Int, which
    /// traps on a value out of range.
    private static func frameRateLabel(_ fps: Double) -> String {
        guard fps.isFinite, fps > 0, fps < 10_000 else { return "Custom" }
        return Formatting.frameRate(fps)
    }

    /// Codecs, stabilization and noise reduction describe the active format and movie output, which only exist in
    /// VIDEO; resolution, frame rate and color come from every format of the lens and hold in any mode.
    private static func notes(video: VideoSettings, caps: CameraCapabilities, isVideoMode: Bool) -> [String?] {
        var notes: [String?] = ["Choices follow what the current camera can record."]
        var recordable = VideoFormatChoices.isRecordable(video, formats: caps.formats) && caps.colorModes.contains(video.colorMode)
        if isVideoMode {
            recordable = recordable && caps.videoCodecs.contains(video.codec)
                && caps.stabilizationModes.contains(video.stabilization)
        } else {
            notes.append("Codec, stabilization and noise reduction choices are complete while video is the active mode.")
        }
        if !recordable {
            notes.append("The current camera can't record these settings exactly, so video uses the closest it has.")
        }
        notes.append(audioPlaybackNote)
        notes.append("Wind noise reduction takes the rumble of wind out of the sound, on iPhones that support it.")
        notes.append("Shutter angle shows the shutter in degrees while filming; 180\u{00B0} gives the classic film look.")
        var unavailable = UnavailableFeatures()
        unavailable.noteFromIOS27("low light noise reduction", supported: caps.lowLightVideoNoiseReductionSupported)
        notes.append(unavailable.text)
        return notes
    }
}

/// What the current camera's formats can record, so the video menus only offer combinations that exist.
private enum VideoFormatChoices {
    /// Offered before the camera has listed its formats; nothing is filtered or fitted until it has.
    static let fallbackFrameRates: [Double] = [24, 25, 30, 60]

    static func resolutions(colorMode: VideoColorMode, formats: [FormatDescriptor]) -> [VideoResolution] {
        guard !formats.isEmpty else { return VideoResolution.allCases }
        return FormatSelector.availableResolutions(colorMode: colorMode, among: formats)
    }

    static func frameRates(resolution: VideoResolution, colorMode: VideoColorMode, formats: [FormatDescriptor]) -> [Double] {
        guard !formats.isEmpty else { return fallbackFrameRates }
        return FormatSelector.availableFrameRates(resolution: resolution, colorMode: colorMode, among: formats)
    }

    static func isRecordable(_ video: VideoSettings, formats: [FormatDescriptor]) -> Bool {
        guard !formats.isEmpty else { return true }
        let requirement = VideoRequirement(resolution: video.resolution, frameRate: video.frameRate, colorMode: video.colorMode)
        return FormatSelector.bestVideoFormat(for: requirement, among: formats) != nil
    }

    static func fitted(_ video: VideoSettings, formats: [FormatDescriptor]) -> VideoSettings {
        guard !formats.isEmpty else { return video }
        var result = video
        let sizes = resolutions(colorMode: result.colorMode, formats: formats)
        if !sizes.contains(result.resolution), let nearest = nearestResolution(to: result.resolution, in: sizes) {
            result.resolution = nearest
        }
        let rates = frameRates(resolution: result.resolution, colorMode: result.colorMode, formats: formats)
        if !rates.contains(where: { abs($0 - result.frameRate) < 0.01 }),
           let nearest = rates.min(by: { abs($0 - result.frameRate) < abs($1 - result.frameRate) }) {
            result.frameRate = nearest
        }
        return result
    }

    /// Ties go to the larger size: stepping off an unsupported size, people rarely want less detail.
    private static func nearestResolution(to wanted: VideoResolution, in sizes: [VideoResolution]) -> VideoResolution? {
        let order = VideoResolution.allCases
        guard let target = order.firstIndex(of: wanted) else { return sizes.last }
        return sizes.min { a, b in
            let indexA = order.firstIndex(of: a) ?? 0
            let indexB = order.firstIndex(of: b) ?? 0
            let distanceA = abs(indexA - target)
            let distanceB = abs(indexB - target)
            return distanceA != distanceB ? distanceA < distanceB : indexA > indexB
        }
    }
}

// MARK: - Controls

private struct ControlsSection: View {
    let model: CameraModel

    var body: some View {
        let controls = model.settings.controls

        // The hardware buttons and haptics have their own page, linked from Look and controls at both levels.
        Section {
            NavigationLink {
                CameraControlItemsView(model: model)
            } label: {
                LabeledContent("Camera Control", value: model.capabilities.supportsCameraControls
                    ? "\(controls.cameraControlItems.count) of \(CameraControlItemsView.limit)"
                    : "Not on this iPhone")
            }
            Toggle("Switch lenses while zooming", isOn: model.settingBinding(\.controls.autoLensSwitching))
        } header: {
            Text("Controls")
        } footer: {
            Text("Switching lenses while zooming moves to the next lens as you pinch or drag the zoom wheel past it, like the Camera app.")
        }
    }
}

/// Chooses and orders the controls Camera Control offers. The system shows them in this order.
private struct CameraControlItemsView: View {
    static let limit = 6

    let model: CameraModel
    /// Always editing, so the reorder handles show without an Edit button.
    @State private var editMode: EditMode = .active

    var body: some View {
        let chosen = model.settings.controls.cameraControlItems
        let others = CameraControlItem.allCases.filter { !chosen.contains($0) }
        let caps = model.capabilities

        List {
            Section {
                ForEach(chosen) { item in
                    ControlItemLabel(item: item, note: Self.note(for: item, caps: caps))
                }
                .onMove { source, destination in
                    model.updateSettings { $0.controls.cameraControlItems.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    model.updateSettings { $0.controls.cameraControlItems.remove(atOffsets: offsets) }
                }
            } header: {
                Text("Included")
            } footer: {
                Text(chosen.isEmpty
                    ? "Camera Control shows no app controls. Add some below."
                    : "Drag to change the order. Up to \(Self.limit) controls, on iPhone models with Camera Control.")
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { item in
                        let note = Self.note(for: item, caps: caps)
                        Button {
                            add(item)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .green)
                                    .font(.title3)
                                    .accessibilityHidden(true)
                                ControlItemLabel(item: item, note: note)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        // Borderless keeps the button tappable while the list is in edit mode.
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .disabled(chosen.count >= Self.limit)
                        .accessibilityLabel("Add \(item.title)")
                        // The label above replaces the visible text, so the camera note is read as a hint instead.
                        .accessibilityHint(note ?? "")
                    }
                } header: {
                    Text("More controls")
                } footer: {
                    if chosen.count >= Self.limit {
                        Text("Camera Control holds \(Self.limit) controls. Remove one to add another.")
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Camera Control")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: removeDuplicates)
    }

    private func add(_ item: CameraControlItem) {
        model.updateSettings { settings in
            guard !settings.controls.cameraControlItems.contains(item),
                  settings.controls.cameraControlItems.count < Self.limit else { return }
            settings.controls.cameraControlItems.append(item)
        }
    }

    /// Rows are identified by item, so a damaged saved list with repeats would confuse the list's editing.
    private func removeDuplicates() {
        let items = model.settings.controls.cameraControlItems
        var seen = Set<CameraControlItem>()
        let unique = items.filter { seen.insert($0).inserted }
        guard unique.count != items.count else { return }
        model.updateSettings { $0.controls.cameraControlItems = unique }
    }

    /// Matches what the Camera Control bridge skips, so a control that won't appear says so here.
    private static func note(for item: CameraControlItem, caps: CameraCapabilities) -> String? {
        let available: Bool
        switch item {
        case .zoom: available = caps.zoomRange.upperBound > caps.zoomRange.lowerBound
        // The bridge leaves the picker out on the selfie camera and on a phone with one back lens.
        case .lens: available = !caps.lens.isFront
        case .exposureBias: available = caps.biasRange.upperBound > caps.biasRange.lowerBound
        case .shutter, .iso: available = caps.supportsCustomExposure
        case .aperture:
            return caps.supportsVariableAperture ? nil : "Only on lenses with a variable aperture"
        case .whiteBalance: available = caps.supportsCustomWhiteBalance
        case .focus: available = caps.supportsManualFocus
        case .mode: available = true
        }
        return available ? nil : "Not on the current camera"
    }
}

private struct ControlItemLabel: View {
    let item: CameraControlItem
    let note: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.symbolName)
                .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Camera and about

private struct CameraDetailsSection: View {
    let capabilities: CameraCapabilities

    var body: some View {
        Section {
            NavigationLink {
                CapabilitiesView(capabilities: capabilities)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(capabilities.lens.name)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Camera")
        } footer: {
            Text("Everything the current camera reports to apps.")
        }
    }

    private var summary: String {
        let lens = capabilities.lens
        let range = capabilities.exposure.aperture
        let aperture = capabilities.supportsVariableAperture
            ? ApertureScale.label(range.lowerBound) + "\u{2013}" + ApertureScale.compactLabel(range.upperBound)
            : ApertureScale.label(lens.aperture)
        var parts = [LensMath.focalLengthLabel(lens.equivalentFocalLength), aperture]
        if !capabilities.formatSummary.isEmpty {
            parts.append(capabilities.formatSummary)
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct AboutSection: View {
    let model: CameraModel

    @State private var isConfirmingReset = false

    var body: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            if model.isSimulated {
                LabeledContent("Camera", value: "Simulated")
            }
            Button("Reset all settings", role: .destructive) {
                isConfirmingReset = true
            }
            .confirmationDialog("Reset all settings?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive, action: resetAll)
                Button("Cancel", role: .cancel) {}
            } message: {
                // Simple is the default interface, so the advanced one says that the reset leaves it on.
                Text(model.isAdvanced
                    ? "Every setting goes back to its default, including the look, the top bar and the buttons. Advanced controls stay on, and the accessibility options stay as they are. Photos and videos you took stay in your library."
                    : "Every setting goes back to its default, including the look, the top bar and the buttons. The accessibility options stay as they are. Photos and videos you took stay in your library.")
            }
        } header: {
            Text("About")
        }
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }()

    private func resetAll() {
        let formats = model.capabilities.formats
        model.updateSettings { settings in
            // The look, the top bar and the button mapping start over with the rest.
            var fresh = CameraSettings.default
            // Simple or advanced, and the answered first-launch question, belong to the interface, not the
            // camera: resetting them would swap the screen behind the sheet, or ask the question again.
            fresh.interface = settings.interface
            // Accessibility options are what someone needs to use the app at all, so a reset never takes them away.
            fresh.accessibility = settings.accessibility
            // Mode, lens and zoom say where the camera is, not how it is set up; resetting them would make the
            // preview jump to another lens behind the sheet.
            fresh.mode = settings.mode
            fresh.lensID = settings.lensID
            fresh.zoom = settings.zoom
            // The default 4K 30 isn't on every lens, and the saved values should say what VIDEO really records.
            fresh.video = VideoFormatChoices.fitted(fresh.video, formats: formats)
            // The defaults switch on tools only the advanced interface shows, such as the histogram and the
            // readout. The simple one gets the defaults the way it runs them.
            settings = fresh.interface.advanced ? fresh : fresh.simplified()
        }
        // The simple interface keeps the advanced one's settings put away for its switch to bring back. They are
        // reset too, or turning the switch on later would undo this reset.
        model.forgetAdvancedSettings()
        // An open dial would keep editing a value that just went back to auto, or a tint that no longer applies.
        model.activeDial = nil
        Haptics.success()
    }
}

// MARK: - Building blocks

/// Why photos carry no place, or only a rough one, while location tags are on; nil when nothing is in the way.
@MainActor
private func locationProblem(enabled: Bool, access: LocationPermissionWatcher?) -> String? {
    guard enabled, let access else { return nil }
    if access.isDenied {
        return "Location access is off for Open Shutter, so photos won't include where they were taken."
    }
    if access.isAuthorized, !access.isPrecise {
        return "Precise Location is off for Open Shutter, so photos get an approximate place."
    }
    return nil
}

/// Swatches instead of a menu, because menus draw their icons in one color and the point here is the color.
private struct PeakingColorRow: View {
    let selection: PeakingColor
    let onSelect: (PeakingColor) -> Void

    var body: some View {
        // Five 44 pt swatches beside the label overflow a 375 pt wide phone at the larger text sizes, so the
        // swatches move under the label when the row runs out of room.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Text("Color")
                Spacer(minLength: 8)
                swatches
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Color")
                swatches
            }
        }
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(PeakingColor.allCases) { color in
                let isSelected = color == selection
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(Self.swatch(color))
                        // Primary, so the rim stays visible on a light sheet too.
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                        .frame(width: 24, height: 24)
                        .padding(4)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2).opacity(isSelected ? 1 : 0))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // Borderless, or a tap anywhere on the row would fire every swatch at once.
                .buttonStyle(.borderless)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private static func swatch(_ color: PeakingColor) -> Color {
        let rgba = color.rgba
        return Color(red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }
}

/// The false color bands from black to white, taken from the same mapping the overlay uses so they can't disagree.
private struct FalseColorLegend: View {
    private struct Band {
        var start: Double
        var end: Double
        var color: RGBA8?
    }

    /// Runs of one color across the luma range; a thousand samples resolve the 1% red band at the top.
    private static let bands: [Band] = {
        let samples = 1000
        var bands: [Band] = []
        for index in 0..<samples {
            let start = Double(index) / Double(samples)
            let end = Double(index + 1) / Double(samples)
            let color = OverlayRenderer.falseColor(luma: (start + end) / 2)
            if let last = bands.last, last.color == color {
                bands[bands.count - 1].end = end
            } else {
                bands.append(Band(start: start, end: end, color: color))
            }
        }
        return bands
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                for band in Self.bands {
                    let rect = CGRect(x: band.start * size.width, y: 0,
                                      width: (band.end - band.start) * size.width, height: size.height)
                    if let color = band.color {
                        context.fill(Path(rect), with: .color(Self.color(color)))
                    } else {
                        // Outside the bands the overlay leaves the picture alone, so show plain brightness.
                        let gradient = Gradient(colors: [Color(white: band.start), Color(white: band.end)])
                        context.fill(Path(rect), with: .linearGradient(gradient,
                                                                       startPoint: CGPoint(x: rect.minX, y: 0),
                                                                       endPoint: CGPoint(x: rect.maxX, y: 0)))
                    }
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            HStack {
                Text("Black")
                Spacer()
                Text("White")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("False color scale")
        .accessibilityValue("Purple and blue for deep shadows, green for middle gray, pink for skin, yellow and red for clipping highlights")
    }

    private static func color(_ rgba: RGBA8) -> Color {
        Color(red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }
}

/// Whether the app may read location, so the location row can say why photos carry no place.
/// LocationProvider owns the real updates; this one only watches the permission.
@MainActor
@Observable
private final class LocationPermissionWatcher: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus = .notDetermined
    private(set) var isPrecise = true

    @ObservationIgnored private let manager = CLLocationManager()

    var isDenied: Bool { status == .denied || status == .restricted }
    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    override init() {
        super.init()
        manager.delegate = self
        refresh()
    }

    private func refresh() {
        status = manager.authorizationStatus
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refresh()
        }
    }
}
