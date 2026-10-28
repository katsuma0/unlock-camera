import SwiftUI
import UIKit
import CameraCore

/// Everything the active camera reports to apps. Read-only and copyable, so what an iPhone allows can be checked
/// or pasted into a bug report instead of guessed.
struct CapabilitiesView: View {
    let capabilities: CameraCapabilities

    @State private var copied = false

    var body: some View {
        let groups = CapabilityReport.groups(for: capabilities)
        let formats = capabilities.formats
        let report = CapabilityReport.text(groups: groups, formats: formats)

        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        CapabilityRowView(row: row)
                    }
                } header: {
                    if group.showsIntro {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(CapabilityReport.intro)
                                .textCase(nil)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(group.title)
                        }
                    } else {
                        Text(group.title)
                    }
                } footer: {
                    if let footer = group.footer {
                        Text(footer)
                    }
                }
            }

            Section {
                if formats.isEmpty {
                    Text("No formats reported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(formats, id: \.index) { format in
                        FormatRowView(format: format)
                    }
                }
            } header: {
                Text("Formats (\(formats.count))")
            } footer: {
                Text("Every format this camera offers, in the order iOS lists them. Video mode picks among these.")
            }
        }
        .listStyle(.insetGrouped)
        .textSelection(.enabled)
        .navigationTitle("Camera Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: report) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                    Haptics.success()
                } label: {
                    Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

// MARK: - Rows

private struct CapabilityRow: Identifiable {
    enum Value {
        case text(String)
        case flag(Bool)
    }

    let label: String
    let value: Value

    var id: String { label }

    init(_ label: String, text: String) {
        self.label = label
        value = .text(text)
    }

    init(_ label: String, flag: Bool) {
        self.label = label
        value = .flag(flag)
    }
}

private struct CapabilityGroup: Identifiable {
    let title: String
    let rows: [CapabilityRow]
    var footer: String?
    var showsIntro = false

    var id: String { title }
}

private struct CapabilityRowView: View {
    let row: CapabilityRow

    var body: some View {
        switch row.value {
        case .text(let text):
            LabeledContent(row.label) {
                Text(text)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
        case .flag(let supported):
            HStack {
                Text(row.label)
                Spacer()
                Image(systemName: supported ? "checkmark" : "minus")
                    .fontWeight(.semibold)
                    .foregroundStyle(supported ? Theme.accent : Color.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.label)
            .accessibilityValue(supported ? "Yes" : "No")
        }
    }
}

private struct FormatRowView: View {
    let format: FormatDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(FormatText.title(format))
                    .monospacedDigit()
                Spacer()
                Text("#\(format.index)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(FormatText.traits(format))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(FormatText.ranges(format))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Report

/// The screen and the copied text come from the same rows, so what gets pasted is exactly what was shown.
private enum CapabilityReport {
    static var intro: String {
        let intro = "What this camera reports to apps. Values come straight from iOS."
        guard buildLacksIOS27Features else { return intro }
        return intro + " This build was made with Xcode 26, which leaves out iOS 27 features such as variable aperture and priority modes, so they read as missing."
    }

    /// iOS 27 features are compiled only by Xcode 27 (Swift 6.4). On iOS 27 an Xcode 26 build would otherwise seem
    /// to show a camera without them.
    private static var buildLacksIOS27Features: Bool {
        #if compiler(>=6.4)
        return false
        #else
        if #available(iOS 27.0, *) { return true }
        return false
        #endif
    }

    static func groups(for c: CameraCapabilities) -> [CapabilityGroup] {
        [lens(c), exposure(c), priority(c), focus(c), whiteBalance(c), photo(c), image(c), video(c)]
    }

    static func text(groups: [CapabilityGroup], formats: [FormatDescriptor]) -> String {
        var lines = [intro, ""]
        for group in groups {
            lines.append(group.title.uppercased())
            for row in group.rows {
                switch row.value {
                case .text(let text):
                    lines.append("\(row.label): \(text.replacingOccurrences(of: "\n", with: "; "))")
                case .flag(let supported):
                    lines.append("\(row.label): \(supported ? "yes" : "no")")
                }
            }
            // The notes say how to read the rows (software priority, VIDEO without photo features), so they travel too.
            if let footer = group.footer {
                lines.append(footer)
            }
            lines.append("")
        }
        lines.append("FORMATS (\(formats.count))")
        for format in formats {
            let parts = ["#\(format.index)", FormatText.title(format), FormatText.traits(format), FormatText.ranges(format)]
            lines.append(parts.joined(separator: " \u{00B7} "))
        }
        return lines.joined(separator: "\n")
    }

    private static func lens(_ c: CameraCapabilities) -> CapabilityGroup {
        var rows = [
            CapabilityRow("Name", text: c.lens.name),
            CapabilityRow("Type", text: kindTitle(c.lens.kind)),
            CapabilityRow("Focal length", text: LensMath.focalLengthLabel(c.lens.equivalentFocalLength) + ", 35 mm equivalent"),
            CapabilityRow("Relative zoom", text: LensMath.zoomLabel(c.lens.relativeZoom, selected: true)),
            CapabilityRow("Aperture", text: apertureText(c)),
        ]
        if !c.apertureStops.isEmpty {
            rows.append(CapabilityRow("Aperture stops", text: c.apertureStops.map(ApertureScale.label).joined(separator: ", ")))
        }
        let zoom = rangeLabel(LensMath.zoomLabel(c.zoomRange.lowerBound, selected: true),
                              LensMath.zoomLabel(c.zoomRange.upperBound, selected: true))
        rows.append(CapabilityRow("Zoom range", text: zoom))
        if !c.formatSummary.isEmpty {
            rows.append(CapabilityRow("Active format", text: c.formatSummary))
        }
        rows.append(CapabilityRow("Device ID", text: c.lens.id))
        return CapabilityGroup(title: "Lens", rows: rows, showsIntro: true)
    }

    private static func exposure(_ c: CameraCapabilities) -> CapabilityGroup {
        let ranges = c.exposure
        let shutter = rangeLabel(ShutterSpeed(seconds: ranges.seconds.lowerBound).label,
                                 ShutterSpeed(seconds: ranges.seconds.upperBound).label)
        let iso = rangeLabel(ISOScale.compactLabel(ranges.iso.lowerBound), ISOScale.compactLabel(ranges.iso.upperBound))
        let rows = [
            CapabilityRow("Shutter", text: shutter),
            CapabilityRow("ISO", text: iso),
            CapabilityRow("Exposure compensation",
                          text: "\(EVFormat.label(c.biasRange.lowerBound)) to \(EVFormat.label(c.biasRange.upperBound)) EV"),
            CapabilityRow("Auto exposure limit", text: ShutterSpeed(seconds: ranges.maxAutoSeconds).label),
            CapabilityRow("Manual exposure", flag: c.supportsCustomExposure),
            CapabilityRow("Variable aperture", flag: c.supportsVariableAperture),
            CapabilityRow("Metering area", flag: c.supportsMeteringArea),
        ]
        return CapabilityGroup(title: "Exposure", rows: rows)
    }

    private static func priority(_ c: CameraCapabilities) -> CapabilityGroup {
        let rows = [
            CapabilityRow("Shutter priority", flag: c.nativePriority.shutter),
            CapabilityRow("ISO priority", flag: c.nativePriority.iso),
            CapabilityRow("Aperture priority", flag: c.nativePriority.aperture),
        ]
        return CapabilityGroup(
            title: "Native priority modes",
            rows: rows,
            footer: "Priority modes iOS runs itself, new in iOS 27. Where they're missing, Open Shutter steers exposure in software."
        )
    }

    private static func focus(_ c: CameraCapabilities) -> CapabilityGroup {
        let rows = [
            CapabilityRow("Manual focus", flag: c.supportsManualFocus),
            CapabilityRow("Tap to focus", flag: c.supportsFocusPointOfInterest),
            CapabilityRow("Tap to meter", flag: c.supportsExposurePointOfInterest),
            CapabilityRow("Closest focus", text: c.minimumFocusDistance.map { "\($0) mm" } ?? "Not reported"),
            CapabilityRow("Focus range limits", flag: c.focusRangeRestrictionSupported),
            CapabilityRow("Smooth autofocus", flag: c.smoothFocusSupported),
            CapabilityRow("Face-driven autofocus", flag: c.faceDrivenAutoFocusSupported),
            CapabilityRow("Subject tracking", flag: c.continuousAFTrackingSupported),
        ]
        return CapabilityGroup(title: "Focus", rows: rows)
    }

    private static func whiteBalance(_ c: CameraCapabilities) -> CapabilityGroup {
        let rows = [
            CapabilityRow("Custom white balance", flag: c.supportsCustomWhiteBalance),
            CapabilityRow("Maximum gain", text: number(c.maxWhiteBalanceGain)),
        ]
        return CapabilityGroup(title: "White balance", rows: rows)
    }

    private static func photo(_ c: CameraCapabilities) -> CapabilityGroup {
        let sizes = c.photoDimensions.map { "\($0.width)\u{00D7}\($0.height) \u{00B7} \($0.megapixelLabel)" }
        let rows = [
            CapabilityRow("Photo sizes", text: sizes.isEmpty ? "None reported" : sizes.joined(separator: "\n")),
            CapabilityRow("HEIF", flag: c.heifSupported),
            CapabilityRow("RAW", flag: c.rawSupported),
            CapabilityRow("ProRAW", flag: c.proRAWSupported),
            CapabilityRow("Live Photo", flag: c.livePhotoSupported),
            CapabilityRow("Depth", flag: c.depthSupported),
            CapabilityRow("Constant color", flag: c.constantColorSupported),
            CapabilityRow("Silent shutter", flag: c.shutterSoundSuppressionSupported),
            CapabilityRow("Flash", flag: c.hasFlash),
            CapabilityRow("Distortion correction", flag: c.geometricCorrectionSupported),
            CapabilityRow("Content-aware distortion correction", flag: c.contentAwareCorrectionSupported),
            CapabilityRow("Exposure brackets", text: c.maxBracketCount > 0 ? "Up to \(c.maxBracketCount) photos" : "None"),
            CapabilityRow("Most processing", text: c.maxProcessing.title),
        ]
        var notes: [String] = []
        // VIDEO takes the photo output out of the session. Every iPhone's photo output offers HEVC and brackets,
        // so both missing at once means there is no photo output to ask, not a camera without photo features.
        if !c.heifSupported && c.maxBracketCount == 0 {
            notes.append("Video mode takes the photo output out of the session, so iOS reports no photo features right now. Open this screen from a photo mode to see them.")
        }
        // CapabilitiesBuilder drops 24 MP from the sizes, so the list can't tell whether this lens has it. Only 48 MP
        // sensors offer it, so those get the reason it's missing.
        if c.photoDimensions.contains(where: { $0.pixelCount >= 40_000_000 }) {
            notes.append("On iPhones with 24 MP, iOS delivers 5712\u{00D7}4284 only through deferred photo delivery. Open Shutter keeps that off, so 24 MP isn't listed or offered.")
        }
        return CapabilityGroup(title: "Photo", rows: rows, footer: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func image(_ c: CameraCapabilities) -> CapabilityGroup {
        let rows = [
            CapabilityRow("Low light boost", flag: c.lowLightBoostSupported),
            CapabilityRow("Global tone mapping", flag: c.globalToneMappingSupported),
            CapabilityRow("Video HDR", flag: c.videoHDRSupported),
            CapabilityRow("Face-driven exposure", flag: c.faceDrivenAutoExposureSupported),
            CapabilityRow("Lens smudge detection", flag: c.smudgeDetectionSupported),
        ]
        return CapabilityGroup(title: "Image", rows: rows)
    }

    private static func video(_ c: CameraCapabilities) -> CapabilityGroup {
        let rows = [
            CapabilityRow("Torch", flag: c.hasTorch),
            CapabilityRow("Codecs", text: list(c.videoCodecs.map(\.title))),
            CapabilityRow("Stabilization", text: list(c.stabilizationModes.map(\.title))),
            CapabilityRow("Color", text: list(c.colorModes.map(\.title))),
            CapabilityRow("Low light noise reduction", flag: c.lowLightVideoNoiseReductionSupported),
        ]
        return CapabilityGroup(title: "Video", rows: rows)
    }

    private static func kindTitle(_ kind: LensInfo.Kind) -> String {
        switch kind {
        case .ultraWide: return "Ultra Wide"
        case .wide: return "Wide"
        case .telephoto: return "Telephoto"
        case .front: return "Front"
        case .external: return "External"
        }
    }

    private static func apertureText(_ c: CameraCapabilities) -> String {
        guard c.supportsVariableAperture else { return ApertureScale.label(c.lens.aperture) }
        let range = c.exposure.aperture
        return rangeLabel(ApertureScale.label(range.lowerBound), ApertureScale.compactLabel(range.upperBound))
    }

    private static func list(_ titles: [String]) -> String {
        titles.isEmpty ? "None reported" : titles.joined(separator: ", ")
    }

    /// Gains like 4.0 read as "4"; anything finer keeps two decimals.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "Not reported" }
        if abs(value - value.rounded()) < 0.005, abs(value) < 1e9 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }
}

/// Labels for one entry of AVCaptureDevice.formats.
private enum FormatText {
    /// "3840×2160 · 1–60 fps"
    static func title(_ format: FormatDescriptor) -> String {
        "\(format.width)\u{00D7}\(format.height) \u{00B7} \(frameRates(format))"
    }

    /// "x420 · HDR · HLG · Apple Log · Apple Log 2 · 10-bit · binned"
    static func traits(_ format: FormatDescriptor) -> String {
        var parts = [format.pixelFormat]
        if format.supportsVideoHDR { parts.append("HDR") }
        if format.supportsHLG { parts.append("HLG") }
        if format.supportsAppleLog { parts.append("Apple Log") }
        if format.supportsAppleLog2 { parts.append("Apple Log 2") }
        if format.is10Bit { parts.append("10-bit") }
        if format.isBinned { parts.append("binned") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "ISO 32–3072 · 1/16000–1s · 106.4° · 12 MP photos"
    static func ranges(_ format: FormatDescriptor) -> String {
        var parts = [
            "ISO " + rangeLabel(ISOScale.compactLabel(format.minISO), ISOScale.compactLabel(format.maxISO)),
            rangeLabel(ShutterSpeed(seconds: format.minExposure).label, ShutterSpeed(seconds: format.maxExposure).label),
        ]
        if format.fieldOfView.isFinite, format.fieldOfView > 0 {
            parts.append(String(format: "%.1f\u{00B0}", format.fieldOfView))
        }
        if format.maxPhotoPixels > 0 {
            // The descriptor keeps only the pixel count; a 1-pixel-high size gives the same megapixel rounding.
            parts.append(Formatting.megapixels(width: format.maxPhotoPixels, height: 1) + " photos")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func frameRates(_ format: FormatDescriptor) -> String {
        guard format.maxFrameRate > 0 else { return "no frame rates" }
        return rangeLabel(rate(format.minFrameRate), rate(format.maxFrameRate)) + " fps"
    }

    private static func rate(_ fps: Double) -> String {
        guard fps.isFinite, fps >= 0, fps < 100_000 else { return "?" }
        return abs(fps - fps.rounded()) < 0.01 ? String(Int(fps.rounded())) : String(format: "%.2f", fps)
    }
}

/// "a–b", or just "a" when both ends read the same.
private func rangeLabel(_ lower: String, _ upper: String) -> String {
    lower == upper ? lower : lower + "\u{2013}" + upper
}
