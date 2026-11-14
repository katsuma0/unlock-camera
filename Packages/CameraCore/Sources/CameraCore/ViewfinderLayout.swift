import Foundation

/// Where the photo frame and the camera picture sit on a portrait screen, in points with a top-left origin.
///
/// The tallest frame is 16:9 across the full width, starting under the status bar, as in Apple's Camera. Every other
/// shape is the largest of its kind inside that region. Shapes up to the height of 4:3 keep the centre that the 4:3
/// frame has under the top bar; taller ones slide only as far as they must to stay inside the region. The picture is
/// the whole camera image, scaled so that the photo's centred crop lands exactly on the frame. It can reach past the
/// screen's sides (16:9 and every taller shape) or above and below the frame (1:1 and 5:4).
public struct ViewfinderLayout: Hashable, Sendable {
    /// The 16:9 region: full width, from the safe area's top edge.
    public var region: CropRect
    /// The photo frame. In VIDEO, the whole picture.
    public var frame: CropRect
    /// The whole camera image at the frame's scale.
    public var picture: CropRect

    /// - Parameters:
    ///   - screenWidth: The screen's width in portrait.
    ///   - screenHeight: The screen's height in portrait.
    ///   - safeTop: The safe area's top inset (status bar, sensor housing).
    ///   - topBarHeight: The top bar under the safe area's top edge. A 4:3 frame starts below it.
    ///   - shape: The photo's aspect ratio, or nil for the whole picture (VIDEO).
    ///   - imageAspect: Width over height of the camera image as the portrait preview shows it: 3/4 for photo
    ///     formats, 9/16 for video formats.
    public init(screenWidth: Double, screenHeight: Double, safeTop: Double, topBarHeight: Double,
                shape: AspectRatio?, imageAspect: Double) {
        let width = Self.positive(screenWidth)
        let height = Self.positive(screenHeight)
        let top = min(Self.nonNegative(safeTop), height)
        let bar = Self.nonNegative(topBarHeight)
        // 16:9 at full width, unless a screen is ever too short for it.
        let regionHeight = min(width * 16 / 9, height - top)
        let regionWidth = regionHeight * 9 / 16
        region = CropRect(x: (width - regionWidth) / 2, y: top, width: regionWidth, height: regionHeight)

        let image = imageAspect.isFinite && imageAspect > 0 ? imageAspect : 3.0 / 4.0
        // The crop in the image's own 0...1 coordinates: the same centred crop photos and stacks are cut to.
        let crop = shape?.normalizedCrop(imageAspect: image) ?? .unit
        let frameAspect = crop.height > 0 ? crop.width * image / crop.height : image
        let regionAspect = regionWidth / max(regionHeight, .leastNonzeroMagnitude)
        var frameWidth = regionWidth
        var frameHeight = regionHeight
        if frameAspect >= regionAspect {
            frameHeight = frameAspect > 0 ? regionWidth / frameAspect : regionHeight
        } else {
            frameWidth = regionHeight * frameAspect
        }
        // Today's 4:3 frame centre, just under the top bar.
        let anchor = top + bar + regionWidth * 2 / 3
        let lowest = region.y + frameHeight / 2
        let highest = region.maxY - frameHeight / 2
        let centerY = lowest <= highest ? min(max(anchor, lowest), highest) : region.y + regionHeight / 2
        frame = CropRect(x: width / 2 - frameWidth / 2, y: centerY - frameHeight / 2, width: frameWidth, height: frameHeight)

        let pictureWidth = crop.width > 0 ? frameWidth / crop.width : frameWidth
        let pictureHeight = crop.height > 0 ? frameHeight / crop.height : frameHeight
        picture = CropRect(x: frame.x - crop.x * pictureWidth, y: frame.y - crop.y * pictureHeight,
                           width: pictureWidth, height: pictureHeight)
    }

    /// Height of the band above the frame, from the screen's top edge.
    public var topBand: Double { frame.y }

    /// Height of the band below the frame, to the screen's bottom edge.
    public func bottomBand(screenHeight: Double) -> Double { max(0, screenHeight - frame.maxY) }

    /// The part of the frame nothing covers: inside the screen's width, below `top` (the top bar's bottom edge) and
    /// above `bottom` (the controls' top edge). Overlays that must not sit under a button are placed in it. Empty,
    /// with a height of 0, when the controls reach the top bar.
    public func openArea(screenWidth: Double, top: Double, bottom: Double) -> CropRect {
        let width = Self.positive(screenWidth)
        let minX = min(max(frame.x, 0), width)
        let maxX = max(min(frame.maxX, width), minX)
        let minY = max(frame.y, top.isFinite ? top : frame.y)
        let maxY = max(min(frame.maxY, bottom.isFinite ? bottom : frame.maxY), minY)
        return CropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where the bottom controls go in the iOS 26 order: the lens buttons and the shutter inside the region's bottom,
    /// the row with the thumbnail, the modes and the flip button in the band under it. Anchored to the region, which is
    /// the same for every shape, so nothing moves when the shape changes.
    ///
    /// - Parameters:
    ///   - screenHeight: The screen's height in portrait.
    ///   - safeBottom: The safe area's bottom inset (the home indicator).
    ///   - modeRowHeight: Height of the row the band has to hold.
    public func controls(screenHeight: Double, safeBottom: Double, modeRowHeight: Double) -> Controls {
        // Apple's distances on the 402 pt phone of the owner's screenshot, scaled with the width.
        let scale = region.width / Controls.referenceWidth
        let bottom = region.maxY
        let band = Self.positive(screenHeight) - Self.nonNegative(safeBottom) - bottom
        let row = Self.nonNegative(modeRowHeight)
        let fits = band.isFinite && band >= row + 2 * Controls.bandMargin
        return Controls(shutterY: bottom - Controls.shutterRise * scale,
                        lensY: bottom - Controls.lensRise * scale,
                        modeRowY: fits ? bottom + band / 2 : nil)
    }

    /// Vertical centres of the bottom controls, in screen points.
    public struct Controls: Hashable, Sendable {
        /// Centre of the shutter: on the picture at 16:9, its disc inside the frame's bottom edge.
        public var shutterY: Double
        /// Centre of the lens buttons when nothing sits between them and the shutter.
        public var lensY: Double
        /// Centre of the row with the thumbnail, the modes and the flip button, in the middle of the band under the
        /// region. nil when that band is too short for the row (iPhone SE): the controls then stack up from the
        /// screen's bottom edge in their earlier order.
        public var modeRowY: Double?

        /// The width Apple's distances below were measured on.
        public static let referenceWidth = 402.0
        /// The shutter's centre above the region's bottom edge on that phone.
        public static let shutterRise = 56.0
        /// The lens buttons' centre above the region's bottom edge on that phone.
        public static let lensRise = 149.0
        /// The least room the band keeps above and below the mode row.
        public static let bandMargin = 4.0
    }

    private static func positive(_ value: Double) -> Double { value.isFinite && value > 0 ? value : 1 }
    private static func nonNegative(_ value: Double) -> Double { value.isFinite && value > 0 ? value : 0 }
}
