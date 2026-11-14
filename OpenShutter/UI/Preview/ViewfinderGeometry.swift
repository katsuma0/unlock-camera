import SwiftUI
import CameraCore

/// The viewfinder's rectangles in screen points with a top-left origin: the camera frame's layout snapped to pixels,
/// and the part of the frame the top bar and the controls leave open. The camera screen lays every viewfinder layer
/// out in this one space, the preview layer's host view included, so a point means the same thing in all of them.
struct ViewfinderGeometry: Equatable {
    /// The whole screen.
    var screen: CGRect
    /// The 16:9 region at full width, the tallest the frame gets. The bottom controls are anchored to it.
    var region: CGRect
    /// The photo frame: the shape the photo is cut to. In VIDEO, the whole picture.
    var frame: CGRect
    /// The whole camera image at the frame's scale. At 16:9 it reaches past the screen's sides.
    var picture: CGRect
    /// The part of the frame under neither the top bar nor the controls, where overlays go.
    var open: CGRect

    static let zero = ViewfinderGeometry(screen: .zero, region: .zero, frame: .zero, picture: .zero, open: .zero)

    init(screen: CGRect, region: CGRect, frame: CGRect, picture: CGRect, open: CGRect) {
        self.screen = screen
        self.region = region
        self.frame = frame
        self.picture = picture
        self.open = open
    }

    /// - Parameters:
    ///   - topBarBottom: The top bar's bottom edge. The open part of the frame starts there or lower.
    ///   - controlsTop: The controls' top edge, or nil before they have been measured.
    ///   - scale: Pixels per point, for snapping the edges to pixels.
    init(layout: ViewfinderLayout, screen: CGSize, topBarBottom: CGFloat, controlsTop: CGFloat?, scale: CGFloat) {
        let pixels = scale.isFinite && scale >= 1 ? scale : 1
        self.screen = CGRect(origin: .zero, size: screen)
        region = Self.snapped(layout.region, scale: pixels)
        frame = Self.snapped(layout.frame, scale: pixels)
        picture = Self.snapped(layout.picture, scale: pixels)
        let bottom = controlsTop.map(Double.init) ?? layout.frame.maxY
        let area = layout.openArea(screenWidth: Double(screen.width), top: Double(topBarBottom), bottom: bottom)
        open = Self.snapped(area, scale: pixels)
    }

    /// The diagonal of the whole camera image as it is laid out, which sets how far a turn of the phone moves the
    /// picture.
    var pictureDiagonal: CGFloat {
        (picture.width * picture.width + picture.height * picture.height).squareRoot()
    }

    /// The frame as far as it shows: at 16:9 the top bar covers its top, down to where the open area starts.
    var visibleFrame: CGRect {
        let top = min(max(frame.minY, open.minY), frame.maxY)
        return CGRect(x: frame.minX, y: top, width: frame.width, height: frame.maxY - top)
    }

    private static func snapped(_ rect: CropRect, scale: CGFloat) -> CGRect {
        func snap(_ value: Double) -> CGFloat {
            guard value.isFinite else { return 0 }
            return (CGFloat(value) * scale).rounded() / scale
        }
        let minX = snap(rect.x)
        let minY = snap(rect.y)
        let maxX = max(snap(rect.maxX), minX)
        let maxY = max(snap(rect.maxY), minY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension View {
    /// Moves a viewfinder layer to where a new frame puts it on the spring the picture uses (Theme.spring), so the
    /// picture, the bands and everything placed by the frame arrive together. With Reduce motion on, in the app or in
    /// iOS, the picture cuts to its new size instead of zooming there, and the layers cut with it.
    func frameMotion<Value: Equatable>(value: Value) -> some View {
        modifier(FrameMotion(value: value))
    }
}

private struct FrameMotion<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        let reduceMotion = systemReduceMotion || AppearanceStore.shared.reduceMotion
        content.animation(reduceMotion ? nil : Theme.spring, value: value)
    }
}
