import SwiftUI
import CameraCore

/// The live histogram in a small glass panel: luma as a white area, RGB as three channels that add up to
/// white where they overlap.
struct HistogramView: View {
    let histogram: Histogram
    let style: HistogramStyle

    var body: some View {
        if style != .off {
            Canvas { context, size in
                HistogramPlot(histogram: histogram, style: style).draw(in: &context, size: size)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(width: 120, height: 60)
            .cameraGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(style == .rgb ? "RGB histogram" : "Histogram")
            .accessibilityValue(HistogramPlot.summary(of: histogram))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

private struct HistogramPlot {
    let histogram: Histogram
    let style: HistogramStyle

    /// 64 bars across about 106 points: fine enough to read, coarse enough that sampling noise doesn't fizz.
    private static let bucketCount = 64

    private static let channels: [(HistogramChannel, Color)] = [
        (.red, Color(red: 1, green: 0.23, blue: 0.2)),
        (.green, Color(red: 0.2, green: 0.95, blue: 0.32)),
        (.blue, Color(red: 0.26, green: 0.5, blue: 1)),
    ]

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        drawGuides(in: &context, size: size)
        switch style {
        case .off:
            return
        case .luma:
            drawLuma(in: &context, size: size)
        case .rgb:
            let heights = Self.heights(Self.channels.map { histogram.bucketed($0.0, count: Self.bucketCount) })
            // A luma-only analysis (the simulated camera measures luma alone) leaves the colour bins empty.
            guard !heights.isEmpty else {
                drawLuma(in: &context, size: size)
                return
            }
            // Additive blending turns overlapping channels white, so a neutral scene reads as a white curve.
            context.blendMode = .plusLighter
            for (values, channel) in zip(heights, Self.channels) {
                context.fill(Self.area(values, size: size), with: .color(channel.1.opacity(0.85)))
            }
        }
    }

    private func drawLuma(in context: inout GraphicsContext, size: CGSize) {
        let heights = Self.heights([histogram.bucketed(.luma, count: Self.bucketCount)])
        guard let luma = heights.first else { return }
        context.fill(Self.area(luma, size: size), with: .color(.white.opacity(0.8)))
    }

    /// Quarter, half and three quarter marks, the way a camera's histogram is ruled.
    private func drawGuides(in context: inout GraphicsContext, size: CGSize) {
        var guides = Path()
        for fraction in [0.25, 0.5, 0.75] {
            let x = size.width * fraction
            guides.move(to: CGPoint(x: x, y: 0))
            guides.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(guides, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
    }

    /// Square roots keep dark tails visible next to a tall peak. Scaling to the tallest inner bucket stops
    /// a pile of clipped whites or crushed blacks from flattening the rest; those end spikes simply hit the top.
    private static func heights(_ channels: [[UInt32]]) -> [[CGFloat]] {
        let compressed = channels.map { values in values.map { Double($0).squareRoot() } }
        var peak = 0.0
        for values in compressed where values.count > 2 {
            for value in values[1..<(values.count - 1)] where value > peak {
                peak = value
            }
        }
        if peak <= 0 {
            for values in compressed {
                for value in values where value > peak {
                    peak = value
                }
            }
        }
        guard peak > 0 else { return [] }
        return compressed.map { values in values.map { CGFloat(min($0 / peak, 1)) } }
    }

    private static func area(_ heights: [CGFloat], size: CGSize) -> Path {
        var path = Path()
        guard heights.count > 1 else { return path }
        let step = size.width / CGFloat(heights.count - 1)
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, height) in heights.enumerated() {
            path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height * (1 - height)))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    /// A spoken summary for VoiceOver: where most of the tones sit, and whether highlights clip.
    static func summary(of histogram: Histogram) -> String {
        var total = 0.0
        var weighted = 0.0
        var clipped = 0.0
        for (bin, count) in histogram.luma.enumerated() {
            let samples = Double(count)
            total += samples
            weighted += samples * Double(bin)
            if bin >= 250 {
                clipped += samples
            }
        }
        guard total > 0 else { return "No signal" }
        let mean = weighted / total / 255
        let tones: String
        if mean < 0.3 {
            tones = "Mostly shadows"
        } else if mean > 0.7 {
            tones = "Mostly highlights"
        } else {
            tones = "Mostly midtones"
        }
        return clipped / total > 0.02 ? tones + ", highlights clipping" : tones
    }
}
