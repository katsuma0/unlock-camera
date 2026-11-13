import SwiftUI
import CameraCore

// The row above the mode carousel: the lens buttons and, beside them, the brightness chip. In a file of its own so
// the zoom work and the camera screen's layout don't share one file.

struct LensRow: View {
    let model: CameraModel

    var body: some View {
        let mode = model.settings.mode
        // The advanced interface has the EV chip on the manual strip in the other modes. The simple one has no
        // strip, so its brightness chip belongs here in every mode; it only shows while there is something to see.
        let showsExposure = !model.isAdvanced || mode == .photo || mode == .night
        ZStack {
            LensPickerSlot(model: model)
            if showsExposure {
                ExposureChip(model: model)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// Reads readings and motion on its own, so the 10 Hz zoom label redraws only the lens buttons.
private struct LensPickerSlot: View {
    let model: CameraModel

    var body: some View {
        let isFront = model.capabilities.lens.isFront
        LensPicker(
            presets: model.backLensPresets,
            activeID: model.activePresetID,
            displayZoom: model.readings.displayZoom,
            rotation: model.motion.iconRotationDegrees,
            onSelect: { preset in
                // Picking a lens says the zooming is done.
                if model.activeDial == .zoom {
                    withAnimation(Theme.spring) { model.activeDial = nil }
                }
                // The model refuses a lens change while filming, since it would reconfigure the session under the
                // movie file. Zooming the recording lens to the button's value keeps the button doing something.
                if model.activity == .recording {
                    Haptics.tap()
                    model.setDisplayZoom(preset.displayZoom, animated: true)
                    return
                }
                model.select(preset)
            },
            onZoomDial: {
                withAnimation(Theme.spring) {
                    model.activeDial = model.activeDial == .zoom ? nil : .zoom
                }
            }
        )
        // The back lens buttons mean nothing on the selfie camera; the flip button brings the back camera back.
        .opacity(isFront ? 0 : 1)
        .allowsHitTesting(!isFront)
        .accessibilityHidden(isFront)
    }
}

/// Exposure compensation for the modes without a manual strip. Tap opens the dial, touch and hold lists a few
/// values and the way back to zero. The advanced interface shows it all the time. In the simple one, brightness is
/// set on the viewfinder's sun, and the chip only shows while it is off zero or its dial is open, so an untouched
/// camera has nothing here to set.
private struct ExposureChip: View {
    let model: CameraModel
    @State private var press = PressTracker()

    var body: some View {
        let advanced = model.isAdvanced
        let bias = Self.bias(model)
        let isAdjusted = abs(bias) >= 0.05
        let isOpen = model.activeDial == .bias
        let isShown = advanced || isAdjusted || isOpen
        let locked = Self.isLocked(model.activity)

        ZStack {
            if isShown {
                HStack(spacing: 4) {
                    // Only the glyph turns with the phone, as on the strip's chips; the whole chip turned upright
                    // would stand out of its row. The simple interface wears the viewfinder's sun.
                    Upright(model: model) {
                        Image(systemName: advanced ? "plusminus.circle" : "sun.max.fill")
                    }
                    Text(EVFormat.label(bias))
                        .contentTransition(.numericText(value: bias))
                }
                .font(Theme.chipFont)
                .foregroundStyle(isAdjusted || isOpen ? Theme.accent : Theme.primaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .cameraGlass(in: Capsule())
                .overlay {
                    if isOpen {
                        Capsule().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1)
                    }
                }
                .scaleEffect(press.isPressed ? 0.94 : 1)
                .animation(Theme.snappy, value: press.isPressed)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { Self.toggleDial(model) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(advanced ? "Exposure compensation" : "Brightness")
                .accessibilityValue(EVFormat.label(bias))
                .accessibilityHint(advanced ? "Opens the exposure dial. Touch and hold for more options."
                                            : "Opens the brightness dial. Touch and hold for more options.")
                .accessibilityAction { Self.toggleDial(model) }
                .accessibilityAction(named: "Reset") { Self.reset(model) }
                .overlay {
                    ExposureChipTouchLayer(model: model, press: press)
                }
                // Locked along with the strip and the dial it opens, menu included: a bracket takes each frame at the
                // current exposure. Not dimmed while capturing, because every single photo passes through it. Saving
                // follows only stacks and recordings, long enough to show the chip is resting.
                .disabled(locked)
                .opacity(model.activity == .saving ? 0.45 : 1)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        // Keyed to adjusted or not, not the value: a drag of the EV dial changes it on every tick, and the digits
        // would never finish rolling.
        .animation(Theme.snappy, value: isAdjusted)
        .animation(Theme.snappy, value: isShown)
    }

    fileprivate static func toggleDial(_ model: CameraModel) {
        Haptics.tap()
        withAnimation(Theme.spring) {
            model.activeDial = model.activeDial == .bias ? nil : .bias
        }
    }

    fileprivate static func reset(_ model: CameraModel) {
        guard abs(bias(model)) >= 0.05 else { return }
        model.setBias(0)
        Haptics.stop()
    }

    /// NIGHT keeps its own compensation; setBias and the dial follow the mode the same way.
    fileprivate static func bias(_ model: CameraModel) -> Double {
        model.settings.mode == .night ? model.settings.night.biasEV : model.settings.manual.bias
    }

    /// Changing exposure while a shot, a stack or a bracket runs would end up in the picture.
    private static func isLocked(_ activity: CaptureActivity) -> Bool {
        switch activity {
        case .capturing, .stacking, .saving: return true
        case .idle, .countdown, .recording: return false
        }
    }
}

/// The chip's tap and its touch and hold menu, laid over the chip. Its own view with inputs that never change, so
/// the chip's redraws with every tick of the dial leave the system's menu button alone.
private struct ExposureChipTouchLayer: View {
    let model: CameraModel
    let press: PressTracker

    var body: some View {
        MenuOnHoldLayer(press: press) {
            ExposureChip.toggleDial(model)
        } options: {
            ExposureChipOptions(model: model)
        }
    }
}

/// Back to zero, then whole stops either way.
private struct ExposureChipOptions: View {
    let model: CameraModel

    /// Darkest first.
    private static let steps: [Double] = [-2, -1, 1, 2]

    var body: some View {
        let advanced = model.isAdvanced
        let bias = ExposureChip.bias(model)
        let range = model.capabilities.biasRange
        // Titled like the dial the chip opens.
        Section(advanced ? "Exposure" : "Brightness") {
            Button {
                ExposureChip.reset(model)
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(abs(bias) < 0.05)
            ForEach(Self.steps.filter { range.contains($0) }, id: \.self) { step in
                Toggle(isOn: Binding(get: { abs(bias - step) < 0.05 }, set: { _ in choose(step) })) {
                    // The advanced interface names the unit; the simple one counts in steps of brightness.
                    Text(advanced ? EVFormat.label(step) + " EV" : EVFormat.label(step))
                }
            }
        }
    }

    private func choose(_ step: Double) {
        Haptics.tick()
        model.setBias(step)
    }
}

/// Rotates its content with the phone. Reading motion here instead of in the parent keeps the 30 Hz attitude
/// updates from redrawing whole control rows.
private struct Upright<Content: View>: View {
    let model: CameraModel
    // Built once in init: a stored closure never compares equal, so SwiftUI could never skip this view.
    let content: Content

    init(model: CameraModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        content.uprightRotation(model.motion.iconRotationDegrees)
    }
}
