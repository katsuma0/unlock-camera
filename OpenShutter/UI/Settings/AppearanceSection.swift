import SwiftUI
import CameraCore

/// How the app looks and handles, whether Advanced settings is on or off: light or dark for Settings, the accent
/// color, and the pages for the buttons and haptics, Camera Control, accessibility and what the camera keeps between
/// launches.
struct LookAndControlsSection: View {
    let model: CameraModel

    var body: some View {
        let accent = model.settings.appearance.accent

        Section {
            SettingsPicker("Appearance", selection: model.settingBinding(\.appearance.scheme),
                           options: AppearanceScheme.allCases, label: \.title)
            AccentColorRow(selection: accent, mode: model.settings.mode) { choice in
                Haptics.tick()
                model.updateSettings { $0.appearance.accent = choice }
            }
            NavigationLink("Accessibility") {
                AccessibilitySettingsView(model: model)
            }
            // Its own view: it reads the list and the camera, which this section has no need to redraw for. It shows
            // only on an iPhone with Camera Control.
            CameraControlRow(model: model)
            NavigationLink("Buttons and haptics") {
                ButtonsAndHapticsView(model: model)
            }
            if model.showsAdvancedSettings {
                Toggle("Switch lenses while zooming", isOn: model.settingBinding(\.controls.autoLensSwitching))
            }
            NavigationLink("Preserve settings") {
                PreserveSettingsView(model: model)
            }
        } header: {
            Text("Look and controls")
                .settingsHeader()
        } footer: {
            Text("Appearance changes Settings, not the camera.")
        }
    }
}

/// Swatches instead of a menu, because menus draw their icons in one color and the point here is the color. Each
/// swatch is the accent as it would draw here, so in a light sheet it shows the deeper shade Settings would use. The
/// strip under them shows the choice as the camera would wear it, on black.
private struct AccentColorRow: View {
    let selection: AccentChoice
    let mode: CaptureMode
    let onSelect: (AccentChoice) -> Void

    var body: some View {
        // Seven swatches beside the label don't fit a 375 pt wide phone, so the label sits above them and the
        // swatches share the row's width.
        VStack(alignment: .leading, spacing: 6) {
            Text("Accent color")
            HStack(spacing: 0) {
                ForEach(AccentChoice.allCases) { choice in
                    swatch(choice)
                }
            }
            AccentPreviewStrip(accent: AppearanceStore.color(for: selection), mode: mode)
                .padding(.bottom, 4)
        }
        .padding(.top, 2)
    }

    private func swatch(_ choice: AccentChoice) -> some View {
        let isSelected = choice == selection
        let color = AppearanceStore.color(for: choice)
        return Button {
            guard !isSelected else { return }
            onSelect(choice)
        } label: {
            GlassSwatch(color: color)
                .frame(width: 26, height: 26)
                .padding(4)
                // The ring is the swatch's own color, so the choice reads as that color lit up rather than as a
                // frame laid over it; its shape, not its hue, is what tells it apart.
                .overlay(Circle().strokeBorder(color, lineWidth: 2).opacity(isSelected ? 1 : 0))
                .animation(Theme.fade, value: isSelected)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        // Borderless, or a tap anywhere on the row would fire every swatch at once.
        .buttonStyle(.borderless)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A bead of the color with light caught on its top edge, so the swatches read as the same glass the camera's
/// controls are made of. Drawn, not a system glass effect, so the color itself stays true on every iOS.
private struct GlassSwatch: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .overlay {
                Circle()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
                    .padding(2)
                    .blendMode(.plusLighter)
            }
            .overlay {
                Circle()
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), Color.black.opacity(0.18)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            }
            .shadow(color: color.opacity(0.35), radius: 3, y: 1)
    }
}

/// The camera's mode names with the current one in the accent, and a chip with the small A, on the camera's black:
/// what the choice will look like there, without leaving Settings.
private struct AccentPreviewStrip: View {
    let accent: Color
    let mode: CaptureMode

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(withChip: true)
            strip(withChip: false)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        // The camera's shade of each accent, as it is drawn on black.
        .environment(\.colorScheme, .dark)
        .animation(Theme.fade, value: mode)
        .accessibilityHidden(true)
    }

    private func strip(withChip: Bool) -> some View {
        HStack(spacing: 14) {
            ForEach(CaptureMode.carouselOrder) { entry in
                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(Theme.smallCapsTracking)
                    .foregroundStyle(entry == mode.carouselMode ? accent : Theme.secondaryText)
                    .fixedSize()
            }
            if withChip {
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("ISO")
                        .foregroundStyle(Theme.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: SmallAutoMark.spacing(for: 7)) {
                        Text("400")
                            .foregroundStyle(Theme.primaryText)
                        SmallAutoMark(size: 7)
                    }
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.raisedFill, in: Capsule())
                .fixedSize()
            }
        }
    }
}
