import SwiftUI

/// The bands around the photo frame: the whole screen with the frame cut out, in black. They stay solid until the
/// picture is live and has settled, then fade to see-through, so wherever the camera has picture outside the frame
/// (above and below 1:1 and 5:4, beside 2:1 and wider) it shows there, darkened. Around 16:9, 4:3, 3:2 and VIDEO the
/// camera has nothing outside the frame, so the bands look black either way.
struct FrameBands: View {
    /// The photo frame, in the coordinates of the screen this view covers.
    let frame: CGRect
    /// Solid black: no live picture yet, a veil up, or a frame that just moved.
    let solid: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    /// The see-through bands' darkness. Apple's show the picture at about a third of the frame's brightness.
    static let seeThroughOpacity = 0.65

    var body: some View {
        ZStack {
            BandShape(cutout: frame)
                .fill(Color.black, style: FillStyle(eoFill: true))
                // Reduce Transparency asks for solid backgrounds, and a dimmed picture is a transparent one.
                .opacity(solid || reduceTransparency ? 1 : Self.seeThroughOpacity)
                .animation(solid ? .easeIn(duration: 0.12) : .easeOut(duration: 0.5), value: solid)
            // Over black bands at night this hairline is the only thing that shows where the photo ends.
            FrameEdges(frame: frame)
                .stroke(Color.white.opacity(0.3), lineWidth: 1 / max(displayScale, 1))
        }
        .frameMotion(value: frame)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private typealias AnimatableRect = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>

private extension CGRect {
    var animatableRect: AnimatableRect {
        AnimatablePair(AnimatablePair(origin.x, origin.y), AnimatablePair(size.width, size.height))
    }

    init(_ value: AnimatableRect) {
        self.init(x: value.first.first, y: value.first.second, width: value.second.first, height: value.second.second)
    }
}

/// The view's whole rectangle with the frame cut out (even-odd fill).
private struct BandShape: Shape {
    var cutout: CGRect

    var animatableData: AnimatableRect {
        get { cutout.animatableRect }
        set { cutout = CGRect(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(cutout)
        return path
    }
}

/// The frame's edges that run inside the view. An edge on the screen's own edge would be drawn half off screen, and
/// there is no band beside it to set it apart from.
private struct FrameEdges: Shape {
    var frame: CGRect

    var animatableData: AnimatableRect {
        get { frame.animatableRect }
        set { frame = CGRect(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard frame.width > 1, frame.height > 1, frame.minX.isFinite, frame.minY.isFinite else { return path }
        let margin: CGFloat = 1
        if frame.minY > rect.minY + margin {
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        }
        if frame.maxY < rect.maxY - margin {
            path.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        }
        if frame.minX > rect.minX + margin {
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
        }
        if frame.maxX < rect.maxX - margin {
            path.move(to: CGPoint(x: frame.maxX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        }
        return path
    }
}
