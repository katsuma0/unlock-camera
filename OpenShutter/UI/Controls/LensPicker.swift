import SwiftUI
import CameraCore

/// Lens buttons like the Camera app's: small glass circles for the back lenses, the active one larger and yellow,
/// reading the live zoom when it sits between two buttons. Touch and hold opens the zoom dial.
struct LensPicker: View {
    let presets: [LensPreset]
    let activeID: String?
    let displayZoom: Double
    var rotation: Double = 0
    var onSelect: (LensPreset) -> Void
    var onZoomDial: () -> Void = {}

    /// The zoom reading at the moment the active button changed. Readings arrive about ten times a second, so right
    /// after a switch the value still belongs to the previous lens; it is ignored until it moves.
    @State private var zoomAtSwitch: Double?

    /// Tap targets stay at 44 pt even though the circles are smaller.
    private static let hitSize: CGFloat = 44
    private static let holdDuration = 0.45

    var body: some View {
        let shown = backPresets
        Group {
            if !shown.isEmpty {
                HStack(spacing: 2) {
                    ForEach(shown) { preset in
                        button(for: preset)
                    }
                }
                .padding(.horizontal, 3)
                .background(Capsule().fill(Color.white.opacity(0.07)).padding(.vertical, 1))
                .animation(Theme.spring, value: activeID)
                .onChange(of: activeID) {
                    zoomAtSwitch = displayZoom
                }
                .onChange(of: displayZoom) { _, newValue in
                    if let stale = zoomAtSwitch, abs(newValue - stale) > 0.005 {
                        zoomAtSwitch = nil
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Lenses"))
            }
        }
    }

    // MARK: - Presets

    /// Back lenses only: the flip button owns the front camera. LensPreset carries no lens kind, so a front preset is
    /// recognized as a second button with the same label as a back one and dropped. The backends list back cameras
    /// first, and the main camera usually has a second (2x) preset, so the back one wins either way.
    private var backPresets: [LensPreset] {
        var presetsPerLens: [String: Int] = [:]
        for preset in presets {
            presetsPerLens[preset.lensID, default: 0] += 1
        }
        let ordered = presets.enumerated().sorted { a, b in
            a.element.displayZoom != b.element.displayZoom ? a.element.displayZoom < b.element.displayZoom : a.offset < b.offset
        }.map(\.element)

        var result: [LensPreset] = []
        var slotForLabel: [String: Int] = [:]
        for preset in ordered {
            guard let slot = slotForLabel[preset.label] else {
                slotForLabel[preset.label] = result.count
                result.append(preset)
                continue
            }
            let kept = result[slot]
            if presetsPerLens[kept.lensID, default: 0] < 2, presetsPerLens[preset.lensID, default: 0] > 1 {
                result[slot] = preset
            }
        }
        return result
    }

    /// The live zoom, when it can be trusted and differs visibly from the button's own value.
    private func liveZoom(for preset: LensPreset) -> Double? {
        guard zoomAtSwitch == nil, displayZoom.isFinite, displayZoom > 0,
              displayZoom >= preset.displayZoom - 0.05,
              abs(displayZoom - preset.displayZoom) >= 0.05 else { return nil }
        return displayZoom
    }

    // MARK: - Buttons

    private func button(for preset: LensPreset) -> some View {
        let isActive = preset.id == activeID
        let diameter = isActive ? Theme.controlSize : Theme.smallControlSize
        let title = isActive ? liveZoom(for: preset).map { LensMath.zoomLabel($0, selected: true) } ?? preset.selectedLabel : preset.label
        return Text(title)
            .font(.system(size: isActive ? 13 : 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
            .contentTransition(.numericText())
            .uprightRotation(rotation)
            .frame(width: diameter, height: diameter)
            .cameraGlass(in: Circle())
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
            .gesture(
                // The long press has to fail before the tap counts, so holding never also selects on lift.
                LongPressGesture(minimumDuration: Self.holdDuration)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        switch result {
                        case .first: openZoomDial(from: preset)
                        case .second: onSelect(preset)
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityName(for: preset, isActive: isActive)))
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
            .accessibilityHint(Text(isActive ? "Touch and hold to open the zoom dial." : ""))
            .accessibilityAction { onSelect(preset) }
            .accessibilityAction(named: Text("Zoom dial")) { openZoomDial(from: preset) }
    }

    private func openZoomDial(from preset: LensPreset) {
        if preset.id == activeID {
            Haptics.tap()
        } else {
            // Selecting goes through CameraModel.select, which plays its own haptic for the lens change.
            onSelect(preset)
        }
        onZoomDial()
    }

    private func accessibilityName(for preset: LensPreset, isActive: Bool) -> String {
        let zoom = isActive ? liveZoom(for: preset) ?? preset.displayZoom : preset.displayZoom
        let rounded = ((zoom.isFinite ? zoom : 1) * 10).rounded() / 10
        return "\(rounded.formatted())x zoom"
    }
}
