import SwiftUI
import CameraCore

/// The tripod and hold-still status over the picture in NIGHT, LONG and a stacked MANUAL shutter. Those shots stand or
/// fall on a still phone, so the status is large, on a backing of its own that reads over a white sky or a black one,
/// and never takes a touch, so taps still focus.
///
/// Place it at the top of the open part of the frame, 12 pt down. It shows exactly while `model.steadyStatus` has a
/// message (the model drops it under the Camera Control's overlay and the battery saver's black screen, and while the
/// steady sign is switched off). It is as tall as its pill, and has no height while hidden, so toasts and badges can
/// move below it by its measured height. It takes the width it is offered and centers the pill with 16 pt to spare on
/// each side. With the phone on its side the pill moves to the edge that is then the person's top and reads upright
/// there; the banner is then as tall as the pill is long.
struct SteadyBanner: View {
    let model: CameraModel

    var body: some View {
        SteadyBannerSlot(model: model, message: model.steadyStatus)
            // The controls under the picture cap their text the same way, so the pill keeps to the top band.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Reads the phone's turn on its own, so the motion updates redraw this slot and leave the pill alone.
private struct SteadyBannerSlot: View {
    let model: CameraModel
    let message: SteadyMessage?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let turns = model.motion.quarterTurns
        let degrees = model.motion.iconRotationDegrees
        let reduceMotion = systemReduceMotion || AppearanceStore.shared.reduceMotion
        // The screen fades the sign out under the open quick settings panel but keeps its room, and Settings covers
        // it while the camera and the motion sensor run on, so the wave would go on flowing where nobody sees it.
        // The Camera Control's overlay hides the panel.
        let isCovered = (model.isDrawerOpen && !model.controlsFullscreen) || model.isSettingsPresented
        ZStack {
            if let message {
                // One pill for as long as a status shows: a new state changes its words and colour in place. Two
                // pills crossing, one fading out under the other, read as a smear while a phone held by hand flips
                // between moving and steady.
                SteadyPill(message: message, pulse: model.motion.isAvailable ? model.motionPulse : nil,
                           isHidden: isCovered)
                    // At once, too. A fade between two states draws the words of both over each other for as long
                    // as it runs, and that is the frame a screenshot catches. A control that changes the state
                    // inside an animation of its own must not reach the pill either.
                    .animation(nil, value: message)
                    .modifier(PersonsTop(degrees: degrees, sideways: turns % 2 != 0))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.horizontal, turns % 2 == 0 ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: Self.alignment(turns))
        // Only the pill coming and going fades.
        .animation(Theme.fade, value: message != nil)
        .animation(Theme.fade, value: turns)
        .modifier(SteadyAnnouncements(message: message, isHidden: model.dimmer.isDimmed || model.controlsFullscreen))
        .allowsHitTesting(false)
    }

    /// The person's top edge: the right one with the top of the phone to the left, the left one the other way.
    private static func alignment(_ turns: Int) -> Alignment {
        switch turns {
        case 1: return .trailing
        case 3: return .leading
        default: return .center
        }
    }
}

/// Turns the pill upright for the person, the short way round as every upright label turns. On its side it is laid
/// out turned, so it takes the room it covers and can't reach over the top controls.
private struct PersonsTop: ViewModifier {
    let degrees: Double
    let sideways: Bool

    func body(content: Content) -> some View {
        if sideways {
            let layout = QuarterTurnLayout()
            layout {
                content.uprightRotation(degrees)
            }
        } else {
            content.uprightRotation(degrees)
        }
    }
}

/// Lays its one view out a quarter turn round: the view is offered the height as its width and the width as its
/// height, and the layout is as wide as the view is tall. The caller turns the view to match.
private struct QuarterTurnLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.height, height: proposal.width))
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                   proposal: ProposedViewSize(width: bounds.height, height: bounds.width))
    }
}

// MARK: - The sign

/// One state of the steady sign, drawn straight on the picture like the histogram: no box behind it, the words and
/// the icon carried by a soft shadow, and beside them a line that flows as a wave while the phone moves. A warning
/// shows in its colour (orange, the words and the icon) rather than on a filled block. A calm state fades to 70
/// percent after 3 s, and every new state starts at full strength.
private struct SteadyPill: View {
    let message: SteadyMessage
    /// The live movement, where a sensor reports it.
    let pulse: MotionPulse?
    /// The quick settings panel or Settings is over the sign.
    let isHidden: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 22
    @State private var isQuiet = false

    var body: some View {
        let warning = message.isWarning
        // Orange, not the accent: the accent is yellow by default, and a yellow word over a lit street is lost.
        let ink = warning ? Theme.warning : Theme.primaryText
        let iconInk = warning ? ink : (message.isIconAccented ? Theme.accent : Theme.primaryText)
        // With no backing, the shadow is what keeps white words apart from a white sky.
        let shade = contrast == .increased || AppearanceStore.shared.solidControls ? 0.95 : 0.75
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                SteadyIconView(icon: message.icon, size: iconSize)
                    .foregroundStyle(iconInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.title)
                        .font(.headline)
                    if let detail = message.detail {
                        Text(detail)
                            .font(.footnote.weight(.medium))
                            .opacity(0.9)
                    }
                }
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            // On the words and the icon only. The line redraws with every frame while it flows, and a shadow over
            // the whole sign would be drawn again with it; the line carries its own.
            .shadow(color: .black.opacity(shade), radius: 3)
            .shadow(color: .black.opacity(shade * 0.5), radius: 10)
            // The words keep their room first: on a narrow phone at the largest text the line gives some of its own.
            .layoutPriority(1)
            if let pulse {
                MotionLine(pulse: pulse, shade: shade, isHidden: isHidden)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 40)
        .opacity(isQuiet ? 0.7 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(message.spoken))
        // The sign stays while its state changes, so every state starts its own count at full strength.
        .task(id: message) {
            if isQuiet { isQuiet = false }
            guard Self.quietens(message) else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { isQuiet = true }
        }
    }

    /// States that only confirm all is well step back once they have been read.
    private static func quietens(_ message: SteadyMessage) -> Bool {
        message == .steady || message == .capturing
    }
}

/// The phone's movement as a sound wave across the sign: a flat line while the phone is still, and a wave that flows
/// while it moves, taller and quicker the more it moves (MotionWave). Drawn like the histogram, with no box, its ends
/// running out into the picture. Coloured by how much the phone moves now, green when still, then yellow, orange and
/// red, so a glance says whether it is ready. Frames are drawn only while the wave shows: a phone at rest on a tripod
/// draws none at all.
private struct MotionLine: View {
    let pulse: MotionPulse
    /// The sign's shadow strength, for the line's own shade.
    let shade: Double
    /// Nothing shows the line (the quick settings panel or Settings is over the sign): it lies flat and reads no
    /// movement until that closes.
    let isHidden: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var clock = WaveClock()
    /// Set while the wave shows, and kept after the phone comes to rest until it lies flat: the frames run until
    /// then.
    @State private var isFlowing = false

    /// The line's length beside the words, and the least it keeps when longer words need the room.
    private static let length: CGFloat = 96
    private static let shortest: CGFloat = 64
    private static let height: CGFloat = 24
    /// Drawn this far past that room on every side, so the shade isn't cut where the wave comes close to the edge.
    private static let bleed: CGFloat = 4
    /// The two faint waves inside the main one, drawn first: their height against the main wave's (below 0, upside
    /// down), how far they trail it in cycles, their strength and their thickness.
    private static let echoes: [(scale: Double, lag: Double, opacity: Double, width: CGFloat)] = [
        (-0.35, 0.14, 0.35, 1),
        (0.6, 0.07, 0.5, 1.2),
    ]
    private static let lineWidth: CGFloat = 2
    /// The faint waves come in with the first ripple, over this much of the wave's height, so a flat line is one line.
    private static let echoesIn = 0.1
    /// How many times the task waits for the wave to lie flat before it lays it flat. The wave only calms while frames
    /// come in; with none (the app in the background) it would wait for ever.
    private static let flatChecks = 4

    var body: some View {
        // Read here, not in the timeline's closure, so the pulse's updates redraw this view and nothing around it. Not
        // read while hidden, so a hand's tremor redraws nothing behind the panel or Settings either.
        let level = isHidden ? 0 : pulse.level
        let moving = level > MotionPulse.stillLevel
        // Reduce Motion: the wave keeps still and only its height follows the movement.
        let flowing = !(systemReduceMotion || AppearanceStore.shared.reduceMotion)
        let shadow = Color.black.opacity(shade)
        Color.clear
            .frame(minWidth: Self.shortest, idealWidth: Self.length, maxWidth: Self.length)
            .frame(height: Self.height)
            .overlay {
                // Paused at once when covered, rather than after a calm-down nobody would see.
                TimelineView(.animation(paused: isHidden || (!moving && !isFlowing))) { timeline in
                    let wave = clock.advance(to: timeline.date, target: level, flowing: flowing)
                    Canvas { context, size in
                        Self.draw(wave, shadow: shadow, in: &context, size: size)
                    }
                }
                .padding(-Self.bleed)
            }
            .onChange(of: moving, initial: true) { _, isMoving in
                if isMoving, !isFlowing { isFlowing = true }
            }
            // Laid flat while covered, so the wave grows from flat to the movement there is when the cover goes.
            .onChange(of: isHidden) { _, hidden in
                guard hidden else { return }
                clock.settle()
                if isFlowing { isFlowing = false }
            }
            // Once the phone is still the wave calms by itself, and the frames stop when it lies flat. Nothing else
            // redraws this view then, so a task waits for that.
            .task(id: moving) {
                guard !moving else { return }
                for _ in 0..<Self.flatChecks {
                    let wait = clock.secondsToFlat
                    guard wait > 0 else { break }
                    try? await Task.sleep(for: .seconds(wait + 1.0 / 60))
                    guard !Task.isCancelled else { return }
                }
                clock.settle()
                guard isFlowing else { return }
                isFlowing = false
                // Once per calm, as the wave comes to lie flat and green, never while it stays flat. A cover over
                // the sign lays it flat by the other path and says nothing.
                if !isHidden { Haptics.settle() }
            }
            .accessibilityHidden(true)
    }

    private static func draw(_ wave: MotionWave, shadow: Color, in context: inout GraphicsContext, size: CGSize) {
        let room = CGRect(origin: .zero, size: size).insetBy(dx: bleed, dy: bleed)
        guard room.width > 1, room.height > 1 else { return }
        let rgb = MotionPulse.color(for: wave.level)
        let along = GraphicsContext.Shading.linearGradient(
            ink(Color(red: rgb.red, green: rgb.green, blue: rgb.blue)),
            startPoint: CGPoint(x: room.minX, y: room.midY), endPoint: CGPoint(x: room.maxX, y: room.midY))
        // The main wave's 2 pt stroke stays inside the room at its tallest.
        let reach = Double(room.height / 2 - 2)
        let echoStrength = min(wave.amplitude / echoesIn, 1)
        // The shade is drawn with the line, so it fades out at the ends with it and keeps the line apart from a white
        // sky without a shadow pass over the sign.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: shadow, radius: 2))
            if echoStrength > 0 {
                for echo in echoes {
                    layer.opacity = echo.opacity * echoStrength
                    let path = wavePath(lift: wave.amplitude * echo.scale * reach, phase: wave.phase - echo.lag,
                                        in: room)
                    layer.stroke(path, with: along,
                                 style: StrokeStyle(lineWidth: echo.width, lineCap: .round, lineJoin: .round))
                }
                layer.opacity = 1
            }
            let path = wavePath(lift: wave.amplitude * reach, phase: wave.phase, in: room)
            layer.stroke(path, with: along, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    /// The wave across `rect`, `lift` points tall at most, one point to each point of length; a straight line at 0.
    private static func wavePath(lift: Double, phase: Double, in rect: CGRect) -> Path {
        var path = Path()
        guard lift != 0, lift.isFinite else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
        let count = max(Int(rect.width.rounded(.up)), 2)
        for index in 0...count {
            let along = Double(index) / Double(count)
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(along),
                                y: rect.midY - CGFloat(lift * MotionWave.shape(at: along, phase: phase)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// The line's colour along its length, clear at both ends.
    private static func ink(_ color: Color) -> Gradient {
        Gradient(stops: fade.map { Gradient.Stop(color: color.opacity($0.opacity), location: $0.location) })
    }

    /// How strong the line is along its length, 0 to 1. It fades in over a little more than a fifth of the length from
    /// each end, eased so neither end of a fade shows as an edge: the line runs out into the picture with no tip.
    private static let fade: [(location: CGFloat, opacity: Double)] = {
        let ramp: CGFloat = 0.22
        let steps = 6
        let rising = (0...steps).map { step -> (location: CGFloat, opacity: Double) in
            let t = Double(step) / Double(steps)
            return (location: ramp * CGFloat(t), opacity: t * t * (3 - 2 * t))
        }
        return rising + rising.reversed().map { (location: 1 - $0.location, opacity: $0.opacity) }
    }()
}

/// The wave and the time it was last moved on to, kept across the timeline's frames. Not observed: the timeline
/// asks for every frame itself, and a write here must not start another update.
@MainActor
private final class WaveClock {
    private var wave = MotionWave()
    private var last: Date?

    /// Frames come 1/120 to 1/60 s apart while the wave shows; a longer gap is a pause.
    private static let longestGap: TimeInterval = 0.1

    var secondsToFlat: Double { wave.secondsToFlat }

    /// The wave at `date`. A date the clock has seen, or an earlier one, moves nothing, and neither does the first
    /// frame after a pause: a gap that long is the timeline starting again, and one step across it would throw the
    /// wave from flat to most of its height in a single frame.
    func advance(to date: Date, target: Double, flowing: Bool) -> MotionWave {
        if let last {
            let seconds = date.timeIntervalSince(last)
            if seconds > 0, seconds < Self.longestGap { wave.advance(by: seconds, toward: target, flowing: flowing) }
        }
        if last.map({ date > $0 }) ?? true { last = date }
        return wave
    }

    /// Flat, and the next frame starts its count afresh: a pause between waves is no step to take.
    func settle() {
        wave.settle()
        last = nil
    }
}

private struct SteadyIconView: View {
    let icon: SteadyIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .tripod:
            TripodGlyph()
                .frame(width: size * 10 / 11, height: size)
        case .hand:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.82, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - VoiceOver

/// VoiceOver hears the pill change between moving and steady before the shot, a bump or a drift during it, and "Keep
/// the phone still" once as it starts. At most once every 3 s: a change inside that wait is said when the wait is
/// over, and only if it still holds and differs from what was said last. A pill that comes back after the dark
/// screen or the Camera Control's overlay hid it belongs to the same shot, so its start isn't said again.
private struct SteadyAnnouncements: ViewModifier {
    let message: SteadyMessage?
    /// The model takes the pill away under the battery saver's dark screen and the Camera Control's overlay.
    let isHidden: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var latest: SteadyMessage?
    @State private var lastSaid: String?
    @State private var lastSaidAt = Date.distantPast
    /// Counts changes that came too soon after the last announcement; the newest state is said when the wait ends.
    @State private var deferred = 0
    /// The pill was hidden while frames came in. The shot goes on under the dark screen and the overlay, so the
    /// pill that comes back is still that shot's.
    @State private var hiddenInShot = false

    private static let interval: TimeInterval = 3

    func body(content: Content) -> some View {
        content
            .onChange(of: message) { old, new in
                guard voiceOver else { return }
                latest = new
                // Only a pill hidden mid-shot comes back to the same shot. No pill can also come before a new one:
                // the overlay was up at the press, or an intervalometer starts the next shot as soon as the last
                // one's frames are all in, with no steady reading shown in between.
                let returning = old == nil && hiddenInShot
                hiddenInShot = new == nil && isHidden && old?.isDuringShot == true
                guard let new else { return }
                if new.isDuringShot, old?.isDuringShot != true, !returning {
                    // Speak status says "Keep the phone still" itself when a long shot starts.
                    if !AppearanceStore.shared.speakStatus { say(new.spoken) }
                    return
                }
                guard Self.isNews(from: old, to: new) else { return }
                if Date().timeIntervalSince(lastSaidAt) >= Self.interval {
                    say(new.spoken)
                } else {
                    deferred &+= 1
                }
            }
            .onChange(of: isHidden) { _, hidden in
                // Shown again with no pill: that shot has all its frames or was stopped, so the next pill is a new
                // shot's.
                if !hidden, message == nil { hiddenInShot = false }
            }
            .task(id: deferred) {
                guard deferred > 0 else { return }
                let wait = Self.interval - Date().timeIntervalSince(lastSaidAt)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, let latest, Self.isWorthSaying(latest), latest.spoken != lastSaid else { return }
                say(latest.spoken)
            }
    }

    private func say(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
        lastSaid = text
        lastSaidAt = Date()
    }

    /// Moving to steady or back before the shot, and a bump or a drift during it. What the shot needs changing while
    /// the phone moves is the person's own doing, and the pill coming back on target isn't news.
    private static func isNews(from old: SteadyMessage?, to new: SteadyMessage) -> Bool {
        switch new {
        case .bumped, .drifted:
            return true
        case .steady, .useTripod, .holdStill:
            guard let old, old.isFramingReading else { return false }
            return (old == .steady) != (new == .steady)
        default:
            return false
        }
    }

    private static func isWorthSaying(_ message: SteadyMessage) -> Bool {
        message.isFramingReading || message == .bumped || message == .drifted
    }
}

private extension SteadyMessage {
    /// Frames are coming in.
    var isDuringShot: Bool {
        switch self {
        case .capturing, .drifted, .bumped: return true
        default: return false
        }
    }

    /// Before the shot, with a sensor that tells moving from steady.
    var isFramingReading: Bool {
        self == .steady || self == .useTripod || self == .holdStill
    }
}
