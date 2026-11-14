import SwiftUI
import CameraCore

/// Lens buttons like the Camera app's: small glass circles for the back lenses, the active one larger and yellow,
/// reading the live zoom when it sits between two buttons. Touch and hold, then drag, to zoom with the wheel.
struct LensPicker: View {
    let presets: [LensPreset]
    let activeID: String?
    let displayZoom: Double
    /// Where a lens button's or VoiceOver's zoom is still gliding to. The active button names it meanwhile, instead
    /// of counting the live zoom on the way ("3.2x, 2.1x" on a zoom out from 4 to 1).
    var zoomTarget: Double? = nil
    var rotation: Double = 0
    /// The zoom wheel stands in for the buttons.
    var isWheelOpen = false
    var onSelect: (LensPreset) -> Void
    /// The hold went through, then every move of the same finger: its horizontal travel in points, nil until it
    /// moves.
    var onHold: (Double?) -> Void = { _ in }
    /// The hold's finger lifted, or the system took the touch away.
    var onHoldEnded: () -> Void = {}
    /// VoiceOver's swipe up (+1) or down (-1) on the active button.
    var onNudge: (Int) -> Void = { _ in }
    /// The ruler zoom dial, now only VoiceOver's "Zoom dial" action.
    var onZoomDial: () -> Void = {}

    /// The zoom reading at the moment the active button changed. Readings arrive about ten times a second, so right
    /// after a switch the value still belongs to the previous lens; it is ignored until it moves.
    @State private var zoomAtSwitch: Double?
    /// True from the moment a hold goes through until its touch ends, however it ends.
    @GestureState private var isHolding = false
    /// The button VoiceOver is on, so a zoom that hands the active role to the next button can take the focus along.
    @AccessibilityFocusState private var focusedID: String?

    /// Tap targets stay at 44 pt even though the circles are smaller.
    private static let hitSize: CGFloat = 44
    private static let holdDuration = 0.30
    /// A finger that slides this far before the hold goes through meant something else.
    private static let holdSlop: CGFloat = 10
    /// Not zero: SwiftUI leaves fully transparent views out of hit testing, and the finger that opened the wheel is
    /// still on one of these buttons.
    private static let hiddenOpacity = 0.001

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
                // Faded, never removed or made untouchable: the gesture that opened the wheel lives on a button and
                // has to keep its touch to the end.
                .opacity(isWheelOpen ? Self.hiddenOpacity : 1)
                .animation(Theme.spring, value: activeID)
                .onChange(of: activeID) { oldValue, newValue in
                    zoomAtSwitch = displayZoom
                    // VoiceOver stepping past the next button's value would otherwise be left on a button that no
                    // longer zooms.
                    if let newValue, oldValue != nil, focusedID == oldValue {
                        focusedID = newValue
                    }
                }
                .onChange(of: displayZoom) { _, newValue in
                    if let stale = zoomAtSwitch, abs(newValue - stale) > 0.005 {
                        zoomAtSwitch = nil
                    }
                }
                .onChange(of: isHolding) { _, holding in
                    guard !holding else { return }
                    // A hold the system cancels never reaches onEnded; look again once this gesture update is over.
                    Task { @MainActor in onHoldEnded() }
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

    /// The zoom the active button names when it differs visibly from the button's own value: a glide's target
    /// while one runs, else the live zoom once it can be trusted.
    private func shownZoom(for preset: LensPreset) -> Double? {
        let zoom: Double
        if let target = zoomTarget {
            zoom = target
        } else {
            guard zoomAtSwitch == nil else { return nil }
            zoom = displayZoom
        }
        guard zoom.isFinite, zoom > 0,
              zoom >= preset.displayZoom - 0.05,
              abs(zoom - preset.displayZoom) >= 0.05 else { return nil }
        return zoom
    }

    // MARK: - Buttons

    private func button(for preset: LensPreset) -> some View {
        let isActive = preset.id == activeID
        let diameter = isActive ? Theme.controlSize : Theme.smallControlSize
        let shown = isActive ? shownZoom(for: preset) : nil
        let title = isActive ? shown.map { LensMath.zoomLabel($0, selected: true) } ?? preset.selectedLabel : preset.label
        // One view whatever the button's role, changing only its values: the active role passes from button to
        // button under a finger dragging the wheel, and a change of view there would cancel the drag.
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
                // The hold has to fail before the tap counts, so holding never also selects on lift. Once it goes
                // through, the same finger drags the wheel, wherever it wanders.
                LongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: Self.holdSlop)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .updating($isHolding) { value, holding, _ in
                        if case .second(true, _) = value { holding = true }
                    }
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        onHold(drag.map { Double($0.translation.width) })
                    }
                    .onEnded { value in
                        guard case .second(true, _) = value else { return }
                        onHoldEnded()
                    }
                    .exclusively(before: TapGesture().onEnded { onSelect(preset) })
            )
            // The accessible button is its own view, so it can change with the role while the drawn one stays put.
            .accessibilityRepresentation {
                LensButtonAccessibility(
                    preset: preset,
                    isActive: isActive,
                    zoom: shown ?? preset.displayZoom,
                    onSelect: onSelect,
                    onNudge: onNudge,
                    onZoomDial: { openZoomDial(from: preset) }
                )
            }
            .accessibilityFocused($focusedID, equals: preset.id)
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
}

/// What VoiceOver gets for one lens button. The active one is the zoom control: swipes step the zoom along the
/// wheel's ticks. The others are plain buttons that pick their lens.
private struct LensButtonAccessibility: View {
    let preset: LensPreset
    let isActive: Bool
    /// The zoom the active button stands at.
    let zoom: Double
    let onSelect: (LensPreset) -> Void
    let onNudge: (Int) -> Void
    let onZoomDial: () -> Void

    var body: some View {
        if isActive {
            Button {
                onSelect(preset)
            } label: {
                Text("Zoom")
            }
            .accessibilityValue(Text(ZoomWheelModel.spokenZoom(zoom)))
            .accessibilityHint(Text("Swipe up or down to zoom."))
            .accessibilityAddTraits(.isSelected)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onNudge(1)
                case .decrement: onNudge(-1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Zoom dial"), onZoomDial)
        } else {
            Button {
                onSelect(preset)
            } label: {
                Text(ZoomWheelModel.spokenZoom(preset.displayZoom) + " zoom")
            }
            .accessibilityAction(named: Text("Zoom dial"), onZoomDial)
        }
    }
}
