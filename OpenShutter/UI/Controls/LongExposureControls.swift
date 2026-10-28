import SwiftUI
import CameraCore

/// LONG mode: how the frames combine, bulb, the total duration, the frame shutter for Blur and Trails, and the frames
/// the shot will take. Sits under the manual strip, whose shutter chip opens the same duration dial.
struct LongExposureControls: View {
    @Bindable var model: CameraModel

    var body: some View {
        let long = model.settings.longExposure
        let locked = model.activity.isBusy
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BlendPicker(model: model, selection: long.blend)
                Spacer(minLength: 4)
                DurationButton(model: model, long: long, isSelected: model.activeDial == .shutter)
                BulbButton(model: model, isOn: long.bulb)
            }
            HStack(spacing: 8) {
                // Overlaid, so the outgoing caption fades out in place instead of sharing the row with the new one.
                ZStack(alignment: .leading) {
                    // Beside the frame chip a second line is free, since the chip makes the row that tall anyway.
                    Text(long.blend.detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(long.blend == .additive ? 1 : 2)
                        .minimumScaleFactor(0.8)
                        .id(long.blend)
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                // Real always exposes each frame as long as the sensor allows, so only Blur and Trails pick one.
                if long.blend != .additive {
                    FrameMenu(model: model, frameSeconds: long.frameSeconds, range: model.capabilities.exposure.seconds)
                        .transition(.opacity)
                }
            }
            LongPlanLine(model: model)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .animation(Theme.snappy, value: long.blend)
        .animation(Theme.snappy, value: locked)
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

    var body: some View {
        let text = long.bulb ? "Max " + Formatting.compactDuration(long.maxBulbSeconds) : ShutterSpeed(seconds: long.seconds).label
        Button {
            Haptics.tick()
            withAnimation(Theme.spring) {
                model.activeDial = model.activeDial == .shutter ? nil : .shutter
            }
        } label: {
            HStack(spacing: 5) {
                UprightImage(model: model, systemName: "timer")
                Text(text)
                    .contentTransition(.numericText(value: long.seconds))
            }
        }
        .buttonStyle(LongChipStyle(isActive: !long.bulb, isSelected: isSelected))
        // With bulb the hold sets the length; the dial would only change the frame size.
        .disabled(long.bulb)
        .animation(Theme.snappy, value: text)
        .accessibilityLabel(Text(long.bulb ? "Bulb limit" : "Exposure duration"))
        .accessibilityValue(Text(text))
        .accessibilityHint(Text(long.bulb ? "Bulb stops on its own at this limit." : "Shows the duration dial."))
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
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
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
