import Foundation

/// A single-channel image with values in 0...1, row-major, top-left origin.
public struct LumaImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: fill, count: max(0, width) * max(0, height)))
    }

    /// Reads with coordinates clamped to the image, so filters can sample past the border.
    @inlinable
    public subscript(x: Int, y: Int) -> Float {
        get {
            let cx = Swift.min(Swift.max(x, 0), width - 1)
            let cy = Swift.min(Swift.max(y, 0), height - 1)
            return pixels[cy * width + cx]
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            pixels[y * width + x] = newValue
        }
    }

    public var isEmpty: Bool { width == 0 || height == 0 }
}

/// A non-owning view of 8-bit planar pixel data, such as one plane of a CVPixelBuffer.
/// The caller keeps the memory alive (and locked) for as long as the view is used.
public struct PlaneView {
    public let base: UnsafeRawPointer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    /// Byte at column `x` (in bytes, not pixels) of row `y`. No bounds checks; callers stay inside the plane.
    @inlinable
    public func byte(x: Int, y: Int) -> UInt8 {
        base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)
    }
}
