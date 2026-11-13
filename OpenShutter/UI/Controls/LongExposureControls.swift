import SwiftUI
import CameraCore

/// LONG mode. The simple interface picks a scene, one of the times that scene offers, and reads its tip. The advanced
/// one has the scene as a menu, with how the frames combine, bulb, the total duration, the frame shutter for Blur and
/// Trails, and the frames the shot will take; it sits under the manual strip, whose shutter chip opens the same
/// duration dial.
struct LongExposureControls: View {
    @Bindable var model: CameraModel

    var body: some View {
        let long = model.settings.longExposure
        let locked = model.activity.isBusy
        Group {
            if model.isAdvanced {
                AdvancedLongPanel(model: model, long: long, durationDialOpen: model.activeDial == .shutter)
            } else {
                SimpleLongPanel(model: model, long: long)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .animation(Theme.snappy, value: locked)
    }
}

// MARK: - Simple

private struct SimpleLongPanel: View {
    let model: CameraModel
    let long: LongExposureSettings

    var body: some View {
        VStack(spacing: 4) {
            SceneStrip(model: model, selection: long.scene)
            // One row either way, so the panel keeps its height from scene to scene.
            ZStack {
                if long.bulb {
                    Text("Tap the shutter to start and again to stop.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                } else {
                    SceneDurationRow(model: model, scene: long.scene, seconds: long.seconds)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            // Overlaid, so the outgoing tip fades out in place instead of sharing the lines with the new one.
            ZStack {
                Text(long.scene.tip)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    // Two lines whatever the tip needs, so the controls above don't move when the scene changes.
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.8)
                    .id(long.scene)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
        // The controls sit in a fixed band above the shutter; the largest text sizes would push them up the picture.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(Theme.snappy, value: long.scene)
    }
}

/// The times the scene offers, the current one yellow.
private struct SceneDurationRow: View {
    let model: CameraModel
    let scene: LongExposureScene
    let seconds: Double

    var body: some View {
        HStack(spacing: 8) {
            ForEach(scene.recipe?.durations ?? [], id: \.self) { duration in
                let isSelected = abs(duration - seconds) < 0.01
                Button {
                    guard !isSelected else { return }
                    Haptics.tick()
                    model.setLongExposureSeconds(duration)
                } label: {
                    Text(Formatting.compactDuration(duration))
                }
                .buttonStyle(SceneChipStyle(isSelected: isSelected))
                .accessibilityLabel(Text(HoldMenuText.spokenTime(duration)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Duration"))
    }
}

// MARK: - Advanced

private struct AdvancedLongPanel: View {
    let model: CameraModel
    let long: LongExposureSettings
    let durationDialOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The scene leads, since it sets the rest. Its name needs the room the blend picker had here, so the
            // picker moved down a row, to where its caption used to stand alone.
            HStack(spacing: 8) {
                SceneMenu(model: model, scene: long.scene)
                Spacer(minLength: 4)
                DurationButton(model: model, long: long, isSelected: durationDialOpen)
                BulbButton(model: model, isOn: long.bulb)
            }
            HStack(spacing: 8) {
                BlendPicker(model: model, selection: long.blend)
                // Real always exposes each frame as long as the sensor allows, so only Blur and Trails pick one.
                // Their frame chip takes the room Real's caption has: beside the picker there is space for one of
                // the two, and each segment's VoiceOver hint carries the caption either way.
                if long.blend == .additive {
                    Text(long.blend.detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    Spacer(minLength: 4)
                    FrameMenu(model: model, frameSeconds: long.frameSeconds, range: model.capabilities.exposure.seconds)
                        .transition(.opacity)
                }
            }
            LongPlanLine(model: model)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.snappy, value: long.blend)
    }
}

// MARK: - Scene

/// The scene as a menu chip: its symbol and name, yellow while a scene's recipe is in force. Picking a scene loads
/// its blend, time and frame into the controls beside it; changing one of those by hand shows Custom here.
private struct SceneMenu: View {
    let model: CameraModel
    let scene: LongExposureScene

    var body: some View {
        Menu {
            Section {
                ForEach(LongExposureScene.presets) { preset in
                    HoldMenuChoice(preset.title, icon: SceneSymbols.image(for: preset), isOn: preset == scene) {
                        model.setLongExposureScene(preset)
                    }
                }
            }
            Section {
                HoldMenuChoice(LongExposureScene.custom.title, icon: SceneSymbols.image(for: .custom), isOn: scene == .custom) {
                    model.setLongExposureScene(.custom)
                }
            }
        } label: {
            HStack(spacing: 5) {
                SceneIcon(model: model, scene: scene)
                Text(scene.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .font(Theme.chipFont)
            .foregroundStyle(scene == .custom ? Theme.primaryText : Theme.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .cameraGlass(in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        // In the picker's order whichever way the menu opens, Custom last.
        .menuOrder(.fixed)
        .animation(Theme.snappy, value: scene)
        .accessibilityLabel(Text("Scene"))
        .accessibilityValue(Text(scene.title))
        .accessibilityHint(Text(scene.tip))
    }
}

// MARK: - Blend

private struct BlendPicker: View {
    let model: CameraModel
    let selection: StackBlend
    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StackBlend.allCases) { blend in
                Button {
                    guard blend != selection else { return }
                    Haptics.tick()
                    withAnimation(Theme.snappy) {
                        model.setLongExposureBlend(blend)
                    }
                } label: {
                    Text(blend.title)
                        .font(Theme.chipFont)
                        .foregroundStyle(blend == selection ? Theme.accent : Theme.primaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background {
                            if blend == selection {
                                Capsule()
                                    .fill(Theme.primaryText.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: selectionSpace)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(blend.title))
                .accessibilityHint(Text(blend.detail))
                .accessibilityAddTraits(blend == selection ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .background {
            Capsule()
                .fill(Color.clear)
                .frame(height: 34)
                .cameraGlass(in: Capsule())
        }
    }
}

// MARK: - Duration and bulb

private struct DurationButton: View {
    let model: CameraModel
    let long: LongExposureSettings
    let isSelected: Bool
    @State private var isPressed = false

    var body: some View {
        let text = long.bulb ? "Max " + Formatting.compactDuration(long.maxBulbSeconds) : ShutterSpeed(seconds: long.seconds).label
        HStack(spacing: 5) {
            UprightImage(model: model, systemName: "timer")
            Text(text)
                .contentTransition(.numericText(value: long.seconds))
        }
        .modifier(LongChipLook(isActive: !long.bulb, isSelected: isSelected, isPressed: isPressed))
        .overlay {
            // With bulb the hold sets the length; the dial would only change the frame size.
            if !long.bulb {
                DurationTouchLayer(model: model, isPressed: $isPressed)
            }
        }
        .animation(Theme.snappy, value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(long.bulb ? "Bulb limit" : "Exposure duration"))
        .accessibilityValue(Text(text))
        .accessibilityHint(Text(long.bulb ? "Bulb stops on its own at this limit." : "Shows the duration dial. " + HoldMenuText.hint))
        .accessibilityAction {
            guard !long.bulb else { return }
            LongDial.toggleDuration(model)
        }
        .disabled(long.bulb)
    }
}

/// The button's tap and its touch and hold menu, as a layer over the face.
private struct DurationTouchLayer: View {
    let model: CameraModel
    @Binding var isPressed: Bool

    var body: some View {
        HoldMenuLayer(isPressed: $isPressed) {
            LongDial.toggleDuration(model)
        } options: {
            DurationMenu(model: model)
        }
    }
}

private struct DurationMenu: View {
    let model: CameraModel

    /// From the shortest time worth stacking to the dial's longest.
    private static let durations: [Double] = [1, 2, 4, 8, 15, 30, 60, 300, 600, 1800]

    var body: some View {
        let seconds = model.settings.longExposure.seconds
        Section("Duration") {
            ForEach(Self.durations, id: \.self) { duration in
                HoldMenuChoice(HoldMenuText.time(duration), isOn: abs(duration - seconds) < 0.01) {
                    model.setLongExposureSeconds(duration)
                }
            }
        }
    }
}

@MainActor
private enum LongDial {
    static func toggleDuration(_ model: CameraModel) {
        Haptics.tick()
        withAnimation(Theme.spring) {
            model.activeDial = model.activeDial == .shutter ? nil : .shutter
        }
    }
}

private struct BulbButton: View {
    let model: CameraModel
    let isOn: Bool

    var body: some View {
        Button {
            Haptics.tap()
            let turningOn = !isOn
            // The duration dial means nothing once the hold sets the length.
            if turningOn, model.activeDial == .shutter {
                withAnimation(Theme.spring) { model.activeDial = nil }
            }
            model.setBulb(turningOn)
        } label: {
            Text("BULB")
                .tracking(0.6)
        }
        .buttonStyle(LongChipStyle(isActive: isOn, isSelected: false))
        .accessibilityLabel(Text("Bulb"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityHint(Text("Exposes for as long as you hold the shutter. Or tap once to start and again to stop."))
    }
}

/// Shutter for each Blur or Trails frame. Auto exposure stays under its own limit and drifts with the light, so star
/// trails need a fixed one: every frame equally bright, and up to the longest shutter the sensor has.
private struct FrameMenu: View {
    let model: CameraModel
    let frameSeconds: Double?
    let range: ClosedRange<Double>

    var body: some View {
        let ascending = ShutterSpeed.scale(minSeconds: range.lowerBound, maxSeconds: range.upperBound, step: .full)
        // Longest first, right under Auto: the long end is what a fixed frame is for.
        let speeds = Array(ascending.reversed())
        // The model clamps to the lens's range, which can leave the value just off a stop; the nearest one is checked.
        // The request and the plan clamp the frame to this lens's range, so the label does too.
        let clamped = frameSeconds.map { min(max($0, range.lowerBound), range.upperBound) }
        let checked = clamped.map { ShutterSpeed(seconds: $0).nearest(in: speeds).seconds }
        let fixed = clamped.map { ShutterSpeed(seconds: $0) }
        let text = fixed?.label ?? "Auto"
        Menu {
            Picker("Frame shutter", selection: Binding(get: { checked }, set: select)) {
                Text("Auto").tag(Double?.none)
                ForEach(speeds, id: \.self) { speed in
                    Text(speed.label).tag(Double?.some(speed.seconds))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text("Frame")
                    .opacity(0.8)
                Text(text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .font(Theme.chipFont)
            .foregroundStyle(fixed == nil ? Theme.primaryText : Theme.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .cameraGlass(in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .animation(Theme.snappy, value: text)
        .accessibilityLabel(Text("Frame shutter"))
        .accessibilityValue(Text(fixed.map { $0.isFraction ? $0.label + " of a second" : $0.label } ?? "Auto"))
        .accessibilityHint(Text("The shutter for each frame. Auto lets the camera pick it."))
    }

    private func select(_ seconds: Double?) {
        Haptics.tick()
        model.setLongExposureFrameSeconds(seconds)
    }
}

// MARK: - Plan

private struct LongPlanLine: View {
    let model: CameraModel

    var body: some View {
        let long = model.settings.longExposure
        let plan = model.longPlan
        let text = LongText.plan(plan, bulb: long.bulb)
        let focal = model.capabilities.lens.equivalentFocalLength * max(model.readings.zoomFactor, 1)
        let needsTripod = LongText.needsTripod(plan: plan, align: long.align,
                                               handheldLimit: ExposureMath.handheldLimit(equivalentFocalLength: focal))
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.readoutFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // Rolls only inside an explicit animation: with auto frames the plan follows the 10 Hz readings.
                .contentTransition(.numericText())
                .accessibilityLabel(Text("Plan: " + text))
            Spacer(minLength: 4)
            if needsTripod {
                TripodHint(model: model)
                    .transition(.opacity)
            }
        }
        .animation(Theme.snappy, value: needsTripod)
    }
}

/// Reads motion on its own, so the 30 Hz attitude updates only redraw this hint.
private struct TripodHint: View {
    let model: CameraModel

    var body: some View {
        let steady = model.motion.isSteady
        HStack(spacing: 4) {
            TripodGlyph()
                .frame(width: 10, height: 11)
                .uprightRotation(model.motion.iconRotationDegrees)
            Text(steady ? "Steady" : "Use a tripod")
        }
        .font(Theme.readoutFont)
        .foregroundStyle(steady ? Theme.accent : Theme.primaryText)
        .fixedSize()
        .animation(Theme.snappy, value: steady)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(steady ? "The phone is steady" : "This exposure needs a tripod or a steady surface"))
    }
}

/// SF Symbols has no tripod, so a small one is drawn here: a camera head on three legs.
private struct TripodGlyph: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let head = CGRect(x: width * 0.2, y: 0, width: width * 0.6, height: height * 0.3)
            context.fill(Path(roundedRect: head, cornerRadius: height * 0.07), with: .foreground)
            let top = CGPoint(x: width * 0.5, y: height * 0.34)
            var legs = Path()
            for foot in [CGPoint(x: width * 0.1, y: height), CGPoint(x: width * 0.5, y: height), CGPoint(x: width * 0.9, y: height)] {
                legs.move(to: top)
                legs.addLine(to: foot)
            }
            context.stroke(legs, with: .foreground, style: StrokeStyle(lineWidth: max(1, width * 0.13), lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct UprightImage: View {
    let model: CameraModel
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .uprightRotation(model.motion.iconRotationDegrees)
    }
}

private struct LongChipStyle: ButtonStyle {
    var isActive: Bool
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(LongChipLook(isActive: isActive, isSelected: isSelected, isPressed: configuration.isPressed))
    }
}

/// A glass capsule in a 44 pt touch area: yellow while its setting is in force, outlined while its dial is open.
private struct LongChipLook: ViewModifier {
    var isActive: Bool
    var isSelected: Bool
    var isPressed: Bool

    func body(content: Content) -> some View {
        content
            .font(Theme.chipFont)
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .cameraGlass(in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Theme.accent.opacity(isSelected ? 0.8 : 0), lineWidth: 1)
            }
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: isPressed)
            .animation(Theme.spring, value: isSelected)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private enum LongText {
    /// "30 frames × 1s · ISO 100", or for bulb "Bulb: 1s frames · ISO 100".
    static func plan(_ plan: StackPlan, bulb: Bool) -> String {
        let speed = ShutterSpeed(seconds: plan.frameSeconds)
        let shutter = speed.isFraction ? speed.label + "s" : speed.label
        let iso = ISOScale.label(plan.iso)
        if bulb {
            return "Bulb: \(shutter) frames \u{00B7} \(iso)"
        }
        let frames = plan.frameCount == 1 ? "1 frame" : "\(plan.frameCount) frames"
        return "\(frames) \u{00D7} \(shutter) \u{00B7} \(iso)"
    }

    static func needsTripod(plan: StackPlan, align: Bool, handheldLimit: Double) -> Bool {
        // Real adds light over the whole duration, so any movement smears the picture.
        if plan.blend == .additive { return true }
        // Each frame on its own is longer than a steady hand can hold this lens.
        if plan.frameSeconds > handheldLimit { return true }
        // Without alignment, a handheld phone smears the background along with the moving subject.
        return !align
    }
}
