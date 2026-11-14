import SwiftUI
import CameraCore

/// The tripod and hold-still status over the picture in NIGHT, LONG and a stacked MANUAL shutter. Those shots stand or
/// fall on a still phone, so the status is large, on a backing of its own that reads over a white sky or a black one,
/// and never takes a touch, so taps still focus.
///
/// Place it at the top of the open part of the frame, 12 pt down. It shows exactly while `model.steadyStatus` has a
/// message (the model drops it under the Camera Control's overlay and the battery saver's black screen). It is as
/// tall as its pill, and has no height while hidden, so toasts and badges can move below it by its measured height.
/// It takes the width it is offered and centers the pill with 16 pt to spare on each side. With the phone on its side
/// the pill moves to the edge that is then the person's top and reads upright there; the banner is then as tall as
/// the pill is long.
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
        ZStack {
            if let message {
                SteadyPill(message: message)
                    .modifier(PersonsTop(degrees: degrees, sideways: turns % 2 != 0))
                    // A new state, or a turn of the phone, fades the old pill out where it was and the new one in.
                    .id(PillKey(message: message, turns: turns))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.horizontal, turns % 2 == 0 ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: Self.alignment(turns))
        .animation(.easeInOut(duration: 0.2), value: message)
        .animation(.easeInOut(duration: 0.2), value: turns)
        .modifier(SteadyAnnouncements(message: message))
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

private struct PillKey: Hashable {
    let message: SteadyMessage
    let turns: Int
}

/// Turns the pill upright for the person. On its side it is laid out turned, so it takes the room it covers and
/// can't reach over the top controls.
private struct PersonsTop: ViewModifier {
    let degrees: Double
    let sideways: Bool

    func body(content: Content) -> some View {
        if sideways {
            let layout = QuarterTurnLayout()
            layout {
                content.rotationEffect(.degrees(degrees))
            }
        } else {
            content.rotationEffect(.degrees(degrees))
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

// MARK: - The pill

/// One state of the pill. A warning is filled with the accent and lettered in the colour that reads on it; the rest
/// are dark with white text. A calm state fades to 70 percent after 3 s, and every new state starts at full strength.
private struct SteadyPill: View {
    let message: SteadyMessage
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 22
    @State private var isQuiet = false

    var body: some View {
        let warning = message.isWarning
        let ink = warning ? Theme.onAccent : Theme.primaryText
        let iconInk = warning ? ink : (message.isIconAccented ? Theme.accent : Theme.primaryText)
        // Glass tints itself after the scene and can't promise contrast for the one thing that has to be read.
        // White on 60 percent black over a white sky is about 5.7:1.
        let backing = contrast == .increased || reduceTransparency || AppearanceStore.shared.solidControls ? 0.85 : 0.6
        let shape = RoundedRectangle(cornerRadius: message.detail == nil ? 20 : 16, style: .continuous)
        HStack(spacing: 10) {
            SteadyIconView(icon: message.icon, size: iconSize)
                .foregroundStyle(iconInk)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.title)
                    .font(.headline)
                if let detail = message.detail {
                    Text(detail)
                        .font(.footnote.weight(.medium))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 40)
        .background {
            if warning {
                // The border and the shadow keep a yellow pill apart from a yellow scene: sodium lamps, sunsets.
                shape.fill(Theme.accent)
                    .overlay { shape.strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.35), radius: 8)
            } else {
                shape.fill(Color.black.opacity(backing))
                    .overlay { shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5) }
            }
        }
        .opacity(isQuiet ? 0.7 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(message.spoken))
        .task {
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
                .font(.system(size: size * 0.82, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// SF Symbols has no tripod, so one is drawn here: a camera head on three legs, in the foreground style. Shared by
/// the pill and the panels.
struct TripodGlyph: View {
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

// MARK: - VoiceOver

/// VoiceOver hears the pill change between moving and steady before the shot, a bump or a drift during it, and "Keep
/// the phone still" once as it starts. At most once every 3 s: a change inside that wait is said when the wait is
/// over, and only if it still holds and differs from what was said last.
private struct SteadyAnnouncements: ViewModifier {
    let message: SteadyMessage?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var latest: SteadyMessage?
    @State private var lastSaid: String?
    @State private var lastSaidAt = Date.distantPast
    /// Counts changes that came too soon after the last announcement; the newest state is said when the wait ends.
    @State private var deferred = 0

    private static let interval: TimeInterval = 3

    func body(content: Content) -> some View {
        content
            .onChange(of: message) { old, new in
                guard voiceOver else { return }
                latest = new
                guard let new else { return }
                if new.isDuringShot, old?.isDuringShot != true {
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
