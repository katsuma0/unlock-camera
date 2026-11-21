import SwiftUI
import CameraCore

/// The Viewfinder page of the full list: the tools drawn over the picture to judge exposure, focus and a steady hold. The grid and
/// the level are not here but in the Camera section of the first page, which the short list has too. Zebras and false
/// color show where highlights clip, so the camera has no separate clipping warning.
struct ViewfinderSettingsView: View {
    let model: CameraModel

    var body: some View {
        let display = model.settings.display

        Form {
            Section {
                SettingsPicker("Histogram", selection: model.settingBinding(\.display.histogram),
                             options: HistogramStyle.allCases, label: \.title)
                Toggle("Exposure readout", isOn: model.settingBinding(\.display.showReadout))
                // The same switch as NIGHT's top bar, under the bar's name for it, so the sign can come back from any
                // mode.
                Toggle(TopBarItem.steadySign.title, isOn: model.settingBinding(\.display.showSteadySign))
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
                Text("Stripes mark highlights about to clip.")
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
                Text("Outlines the edges that are in focus.")
            }

            Section {
                Toggle("False color", isOn: model.settingBinding(\.display.falseColor))
                if display.falseColor {
                    FalseColorLegend()
                }
            } footer: {
                Text("Paints brightness as color.")
            }
        }
        .navigationTitle("Viewfinder")
        .navigationBarTitleDisplayMode(.inline)
    }
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
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
