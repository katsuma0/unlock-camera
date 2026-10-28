import SwiftUI
import UIKit
import CameraCore

/// The mode strip above the shutter: uppercase titles with the selected one centered in yellow. Swipe or tap to change
/// mode; the strip follows the finger and springs to the mode it lands on.
struct ModeCarousel: View {
    @Binding var mode: CaptureMode

    @Environment(\.legibilityWeight) private var legibilityWeight
    @GestureState private var isTouching = false
    /// Finger travel while swiping, 0 at rest.
    @State private var dragTranslation: CGFloat = 0
    /// Title widths as laid out. Until the first layout pass a UIFont estimate stands in, so the strip starts centered.
    @State private var measuredWidths: [CaptureMode: CGFloat] = [:]

    private let modes = CaptureMode.carouselOrder

    private static let height: CGFloat = 44
    private static let itemPadding: CGFloat = 10
    private static let itemSpacing: CGFloat = 6
    /// How far the strip stretches past the first and last mode, in points.
    private static let rubberLimit: CGFloat = 36
    /// A flick this fast moves one mode even when the finger barely travels, in points per second.
    private static let flickVelocity: CGFloat = 300
    private static let flickDistance: CGFloat = 24

    var body: some View {
        let centers = itemCenters
        let selected = modes.firstIndex(of: mode) ?? 0
        let focus = focusPoint(centers: centers, selected: selected)
        let highlighted = nearest(to: focus, in: centers)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .overlay {
                HStack(spacing: Self.itemSpacing) {
                    ForEach(modes.indices, id: \.self) { position in
                        title(modes[position], isHighlighted: position == highlighted)
                    }
                }
                .fixedSize()
                .offset(x: totalWidth(centers) / 2 - focus)
                .animation(Theme.spring, value: mode)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .contentShape(Rectangle())
            .gesture(swipe(centers: centers, selected: selected))
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                // A swipe the system cancels never reaches onEnded; put the strip back once this update is over.
                Task { @MainActor in
                    guard !isTouching, dragTranslation != 0 else { return }
                    withAnimation(Theme.spring) { dragTranslation = 0 }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Camera mode"))
            .accessibilityValue(Text(Self.spokenName(mode)))
            .accessibilityAdjustableAction { direction in
                step(direction)
            }
    }

    /// The strip's one-word titles, spelled out where the word alone would puzzle a VoiceOver user.
    private static func spokenName(_ mode: CaptureMode) -> String {
        switch mode {
        case .night: return "Night"
        case .long: return "Long exposure"
        case .photo: return "Photo"
        case .manual: return "Manual"
        case .video: return "Video"
        }
    }

    private func title(_ item: CaptureMode, isHighlighted: Bool) -> some View {
        Text(item.title)
            .font(Theme.modeFont)
            .tracking(1)
            .foregroundStyle(isHighlighted ? Theme.accent : Theme.primaryText)
            .animation(Theme.snappy, value: isHighlighted)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                measuredWidths[item] = width
            }
            .padding(.horizontal, Self.itemPadding)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Theme.spring) { choose(item) }
            }
    }

    // MARK: - Layout

    /// Center of every title along the strip, from its leading edge.
    private var itemCenters: [CGFloat] {
        var centers: [CGFloat] = []
        var x: CGFloat = 0
        for item in modes {
            let width = itemWidth(item)
            centers.append(x + width / 2)
            x += width + Self.itemSpacing
        }
        return centers
    }

    private func totalWidth(_ centers: [CGFloat]) -> CGFloat {
        guard let lastCenter = centers.last, let last = modes.last else { return 0 }
        return lastCenter + itemWidth(last) / 2
    }

    private func itemWidth(_ item: CaptureMode) -> CGFloat {
        (measuredWidths[item] ?? estimatedTextWidth(item)) + 2 * Self.itemPadding
    }

    private func estimatedTextWidth(_ item: CaptureMode) -> CGFloat {
        let weight: UIFont.Weight = legibilityWeight == .bold ? .bold : .semibold
        let font = UIFont.systemFont(ofSize: 13, weight: weight)
        let size = (item.title as NSString).size(withAttributes: [.font: font, .kern: 1])
        return ceil(size.width)
    }

    /// The point of the strip that sits under the middle of the screen, rubber-banded past the first and last mode.
    private func focusPoint(centers: [CGFloat], selected: Int) -> CGFloat {
        guard let first = centers.first, let last = centers.last, centers.indices.contains(selected) else { return 0 }
        let raw = centers[selected] - dragTranslation
        if raw < first { return first - Self.rubber(first - raw) }
        if raw > last { return last + Self.rubber(raw - last) }
        return raw
    }

    private static func rubber(_ distance: CGFloat) -> CGFloat {
        rubberLimit * (1 - 1 / (distance * 0.55 / rubberLimit + 1))
    }

    private func nearest(to x: CGFloat, in centers: [CGFloat]) -> Int {
        var best = 0
        var bestDistance = CGFloat.infinity
        for (position, center) in centers.enumerated() where abs(center - x) < bestDistance {
            best = position
            bestDistance = abs(center - x)
        }
        return best
    }

    // MARK: - Interaction

    private func swipe(centers: [CGFloat], selected: Int) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isTouching) { _, touching, _ in
                touching = true
            }
            .onChanged { value in
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                finishSwipe(value, centers: centers, selected: selected)
            }
    }

    private func finishSwipe(_ value: DragGesture.Value, centers: [CGFloat], selected: Int) {
        guard centers.indices.contains(selected) else {
            withAnimation(Theme.spring) { dragTranslation = 0 }
            return
        }
        let translation = value.translation.width
        let velocity = value.velocity.width
        // Coast a little past the release point, but much less than a scroll view would: one swipe is a mode or two.
        let coast = (value.predictedEndTranslation.width - translation) * 0.35
        var target = nearest(to: centers[selected] - translation - (coast.isFinite ? coast : 0), in: centers)
        if target == selected, abs(velocity) > Self.flickVelocity || abs(translation) > Self.flickDistance {
            // A short flick still moves one mode, like the Camera app.
            let direction = abs(velocity) > Self.flickVelocity ? velocity : translation
            target = selected + (direction < 0 ? 1 : -1)
        }
        target = min(max(target, 0), modes.count - 1)
        withAnimation(Theme.spring) {
            dragTranslation = 0
            choose(modes[target])
        }
    }

    private func step(_ direction: AccessibilityAdjustmentDirection) {
        guard let current = modes.firstIndex(of: mode) else { return }
        let next: Int
        switch direction {
        case .increment: next = current + 1
        case .decrement: next = current - 1
        @unknown default: return
        }
        guard modes.indices.contains(next) else { return }
        withAnimation(Theme.spring) { choose(modes[next]) }
    }

    private func choose(_ item: CaptureMode) {
        guard item != mode else { return }
        mode = item
        // The model refuses a mode change while a capture runs; only click when the change took.
        if mode == item { Haptics.tick() }
    }
}
