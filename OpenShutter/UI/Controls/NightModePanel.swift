import SwiftUI
import CameraCore

/// NIGHT's row above the chips and the lens buttons: what the shot will take, on a dark pill that reads over any
/// picture, and for the long exposure scenes the bulb switch. NIGHT holds two kinds of shot. The night shot averages
/// its frames for a clean picture in low light. The long exposure scenes, and Custom, combine them the scene's way:
/// added like one long shutter, averaged into blur, or the brightest kept for trails.
///
/// The scene is chosen from the button left of the shutter (NightSceneMenuItems). How long a shot runs is the moon
/// chip's, beside the lens buttons (LensRowShutterChip). Whether the shot needs a tripod, and whether the phone is
/// steady, is the status pill's over the picture (SteadyBanner); the top bar's tripod button shows or hides it.
struct NightModePanel: View {
    let model: CameraModel

    var body: some View {
        let isLong = model.settings.mode == .long
        let long = model.settings.longExposure
        let locked = model.activity.isBusy
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Centred in the room the bulb switch leaves. The switch is pinned to the edge, so it keeps its
                // place under the finger when a tap on it changes the pill's text.
                NightPlanPill(model: model, isLong: isLong)
                    .frame(maxWidth: .infinity)
                if isLong {
                    BulbButton(model: model, isOn: long.bulb)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.edge)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(locked)
        .opacity(locked ? Theme.Dim.held : 1)
        .animation(Theme.snappy, value: isLong)
        .animation(Theme.snappy, value: locked)
    }
}

// MARK: - Scene

/// The rows of the scene menu, for the button left of the shutter: the night shot first, then Manual night (the
/// Custom scene, with every control by hand), then the long exposure scenes. Picking a long exposure scene loads its blend, time, bulb, frame and alignment; changing any
/// of those but the time by hand makes the scene Custom.
struct NightSceneMenuItems: View {
    let model: CameraModel
    /// nil is the night shot.
    let scene: LongExposureScene?

    var body: some View {
        Section {
            HoldMenuChoice(NightText.nightTitle, icon: Image(systemName: NightText.nightSymbol), isOn: scene == nil) {
                model.selectNightScene(nil)
            }
        }
        Section {
            HoldMenuChoice(NightText.manualNightTitle, icon: SceneSymbols.image(for: .custom), isOn: scene == .custom) {
                model.selectNightScene(.custom)
            }
        }
        Section {
            ForEach(LongExposureScene.presets) { preset in
                HoldMenuChoice(preset.title, icon: SceneSymbols.image(for: preset), isOn: preset == scene) {
                    model.selectNightScene(preset)
                }
            }
        }
    }
}

/// Each scene's symbol, found once. Finding it asks the system for every candidate name, which is too much for a
/// body that runs again with every settings change.
@MainActor
enum SceneSymbols {
    private static let images: [LongExposureScene: Image] = Dictionary(
        uniqueKeysWithValues: LongExposureScene.allCases.map { ($0, Image(firstAvailableSystemName: $0.symbolNames)) }
    )

    static func image(for scene: LongExposureScene) -> Image {
        images[scene] ?? Image(systemName: "circle")
    }
}

// MARK: - Bulb and the frame shutter

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
        .buttonStyle(NightChipStyle(isActive: isOn))
        .accessibilityLabel(Text("Bulb"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityHint(Text("Exposes for as long as you hold the shutter. Or tap once to start and again to stop."))
    }
}

/// The menu for the shutter of each Blur or Trails frame, laid over the plan pill. Auto exposure stays under its own
/// limit and drifts with the light, so star trails need a fixed one: every frame equally bright, and up to the
/// longest shutter the sensor has. Its own view, with inputs that change only with the frame shutter: the pill under
/// it follows the 10 Hz plan, and a menu built there would be rebuilt with every reading.
private struct FrameMenuLayer: View {
    let model: CameraModel
    let press: PressTracker
    /// "Auto" or the frame shutter, never the plan.
    let value: String

    var body: some View {
        MenuOnTapLayer(press: press, label: "Frame shutter", value: value,
                       hint: "Shows the shutter choices for each frame.") {
            FrameMenuRows(model: model)
        }
    }
}

/// The rows of the frame shutter menu. They read the frame shutter themselves, so the layer above them stays as it is.
private struct FrameMenuRows: View {
    let model: CameraModel

    var body: some View {
        // The frame the shot will use, which for a scene that closes the iris is longer than its own.
        let frameSeconds = model.longFrameSeconds
        let range = model.capabilities.exposure.seconds
        let ascending = ShutterSpeed.scale(minSeconds: range.lowerBound, maxSeconds: range.upperBound, step: .full)
        // Longest first, right under Auto: the long end is what a fixed frame is for.
        let speeds = Array(ascending.reversed())
        // The model clamps to the lens's range, which can leave the value just off a stop; the nearest one is checked.
        let clamped = frameSeconds.map { min(max($0, range.lowerBound), range.upperBound) }
        let checked = clamped.map { ShutterSpeed(seconds: $0).nearest(in: speeds).seconds }
        // The checked stop can stand for a scene's frame that sits between stops. Picking it again keeps the
        // scene instead of turning it into Custom at that stop.
        Picker("Frame shutter", selection: Binding(get: { checked }, set: { if $0 != checked { select($0) } })) {
            Text("Auto").tag(Double?.none)
            ForEach(speeds, id: \.self) { speed in
                Text(speed.label).tag(Double?.some(speed.seconds))
            }
        }
        .pickerStyle(.inline)
    }

    private func select(_ seconds: Double?) {
        Haptics.tick()
        model.setLongExposureFrameSeconds(seconds)
    }
}

// MARK: - Plan

/// What the shot will take: "12 frames × 1/4s" beside a stack, the frames the camera merges into one picture. The ISO
/// is left to the readout line or the ISO chip, which show the one the frames use; with the readout switched off the
/// pill still names it. In a Blur or Trails scene the pill is also the menu for the shutter of each frame, the middle
/// value on it, and wears a chevron to say so. The night shot and Real set their frames themselves.
private struct NightPlanPill: View {
    let model: CameraModel
    let isLong: Bool
    @State private var press = PressTracker()

    var body: some View {
        let long = model.settings.longExposure
        let plan = isLong ? model.longPlan : model.nightPlan
        // Bulb has no length to plan, so the line gives the limit from Settings, where the exposure stops by itself.
        let bulbLimit = isLong && long.bulb ? long.maxBulbSeconds : nil
        let showsISO = !NightText.isoShownElsewhere(model)
        let text = NightText.plan(plan, bulbLimit: bulbLimit, showsISO: showsISO)
        let spoken = NightText.plan(plan, bulbLimit: bulbLimit, showsISO: showsISO, spoken: true)
        // One frame is a plain exposure: nothing is stacked.
        let stacked = plan.frameCount > 1 || bulbLimit != nil
        // The frame shutter is a shutter speed, which only the phones with manual shutter speeds offer.
        if isLong, long.blend != .additive, model.allowsManualShutter {
            let frame = model.longFrameSeconds
            // VoiceOver finds two elements here: the plan, read only, and the frame shutter's menu.
            PlanPillFace(text: text, stacked: stacked, opensMenu: true)
                .scaleEffect(press.isPressed ? 0.94 : 1)
                .animation(Theme.snappy, value: press.isPressed)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Plan"))
                .accessibilityValue(Text(spoken))
                .overlay {
                    FrameMenuLayer(model: model, press: press,
                                   value: frame.map { ShutterSpeed(seconds: $0).label } ?? "Auto")
                }
        } else {
            PlanPillFace(text: text, stacked: stacked, opensMenu: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Plan"))
                .accessibilityValue(Text(spoken))
        }
    }
}

/// The pill itself. Its backing is its own and dark, not glass: glass takes its tone from the scene, and this is a
/// line of numbers to read over a lit street as well as a black sky.
private struct PlanPillFace: View {
    let text: String
    /// The shot merges several frames: the stack glyph leads the line. Drawn only, since in Blur and Trails
    /// the pill is the frame shutter's menu and has no second tap to give; the spoken plan says "stacked".
    let stacked: Bool
    let opensMenu: Bool

    var body: some View {
        HStack(spacing: 6) {
            if stacked {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12 * Theme.labelScale, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            }
            Text(text)
                // Rolls only inside an explicit animation: the plan follows the 10 Hz light readings.
                .contentTransition(.numericText())
            if opensMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
        }
        .font(Theme.labelFont.weight(.medium).monospacedDigit())
        .foregroundStyle(Theme.primaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 14)
        .frame(height: 30)
        // The scrim: white on it over a white sky is about 5.7:1, and darker where the person asked for more
        // contrast or less transparency.
        .background {
            Capsule()
                .fill(Theme.scrim)
                .overlay { Capsule().strokeBorder(Theme.scrimEdge, lineWidth: 0.5) }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        // Only a change between one frame and several fades the glyph; the text follows the light readings.
        .animation(Theme.snappy, value: stacked)
    }
}

// MARK: - Looks and words

/// A glass capsule in a 44 pt touch area, yellow while its setting is in force.
private struct NightChipStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.chipFont)
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.chipPadding)
            .frame(height: Theme.chipHeight)
            .cameraGlass(in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

enum NightText {
    /// The night shot's name in the scene menu.
    static let nightTitle = "Night"
    /// The Custom scene's name in NIGHT: a long exposure with the chips of MANUAL and NIGHT's own controls.
    static let manualNightTitle = "Manual night"

    /// The scene's full name, with Custom as NIGHT calls it.
    static func title(_ scene: LongExposureScene?) -> String {
        guard let scene else { return nightTitle }
        return scene == .custom ? manualNightTitle : scene.title
    }
    /// The night shot's symbol, in the menu and on the button that opens it.
    static let nightSymbol = "moon.fill"
    /// What the night shot does, for VoiceOver.
    static let nightDetail = "Averages frames for a clean, bright picture."

    /// The ISO the frames use is on screen already: the ISO chip of Manual night, or the readout line the night shot
    /// and the other scenes show above the lens buttons, which Settings can switch off.
    @MainActor
    static func isoShownElsewhere(_ model: CameraModel) -> Bool {
        let settings = model.settings
        if settings.mode == .long, settings.longExposure.scene == .custom {
            return model.capabilities.supportsCustomExposure
        }
        return settings.display.showReadout
    }

    /// "12 frames × 1/4s", or with a bulb limit "Bulb · 1s frames · max 30m". `showsISO` adds the frames' ISO
    /// ("12 frames × 1/4s · ISO 640") for when nothing else on screen shows it. `spoken` writes the plan out for
    /// VoiceOver, which would read "30m" as thirty meters and "1/4s" as a fraction: "12 frames of 1/4 of a second,
    /// stacked", "Bulb, frames of 1 second, up to 30 minutes".
    static func plan(_ plan: StackPlan, bulbLimit: Double?, showsISO: Bool, spoken: Bool = false) -> String {
        let speed = ShutterSpeed(seconds: plan.frameSeconds)
        let iso = showsISO ? ISOScale.label(plan.iso) : nil
        if spoken {
            let each = spokenDuration(speed.seconds)
            var parts: [String]
            if let bulbLimit {
                parts = ["Bulb", "frames of \(each)", "up to \(HoldMenuText.spokenTime(bulbLimit))"]
            } else if plan.frameCount == 1 {
                parts = ["1 frame of \(each)"]
            } else {
                parts = ["\(plan.frameCount) frames of \(each), stacked"]
            }
            // After the frames, as the line has it.
            if let iso { parts.insert(iso, at: bulbLimit == nil ? 1 : 2) }
            return parts.joined(separator: ", ")
        }
        let shutter = speed.isFraction ? speed.label + "s" : speed.label
        if let bulbLimit {
            let limit = Formatting.compactDuration(bulbLimit)
            return (["Bulb", "\(shutter) frames"] + (iso.map { [$0] } ?? []) + ["max \(limit)"])
                .joined(separator: " \u{00B7} ")
        }
        let frames = plan.frameCount == 1 ? "1 frame" : "\(plan.frameCount) frames"
        let line = "\(frames) \u{00D7} \(shutter)"
        return iso.map { line + " \u{00B7} " + $0 } ?? line
    }

    /// "1/4 of a second", "0.5 seconds", "15 seconds", "5 minutes", rounded as the dials' labels are: VoiceOver
    /// reads "1/4s" as a fraction and "5m" as five meters.
    static func spokenDuration(_ seconds: Double) -> String {
        let speed = ShutterSpeed(seconds: seconds)
        if speed.isFraction { return speed.label + " of a second" }
        let shown = speed.seconds < 10 ? (speed.seconds * 10).rounded() / 10 : speed.seconds.rounded()
        if shown >= 1, shown == shown.rounded() { return HoldMenuText.spokenTime(shown) }
        return "\(shown.formatted()) seconds"
    }
}

