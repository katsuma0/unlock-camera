import Foundation

/// Interleaved float image (channels 1...4), row-major, top-left origin. Values are linear light and unclamped,
/// so highlights that stack above 1 survive until the final scale.
public struct FloatImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var pixels: [Float]

    /// Negative sides become 0 and channels are clamped to 1...4, so a bad size gives a usable image, not a trap.
    public init(width: Int, height: Int, channels: Int, fill: Float = 0) {
        let w = max(width, 0)
        let h = max(height, 0)
        let c = min(max(channels, 1), 4)
        self.init(width: w, height: h, channels: c, pixels: [Float](repeating: fill, count: w * h * c))
    }

    public init(width: Int, height: Int, channels: Int, pixels: [Float]) {
        precondition(width >= 0 && height >= 0 && channels >= 1 && channels <= 4
                     && pixels.count == width * height * channels,
                     "pixel count must equal width * height * channels, with 1...4 channels")
        self.width = width
        self.height = height
        self.channels = channels
        self.pixels = pixels
    }

    /// Reads with coordinates (and channel) clamped to the image, so filters can sample past the border.
    /// Writes outside the image are ignored.
    @inlinable
    public subscript(x: Int, y: Int, c: Int) -> Float {
        get {
            guard width > 0, height > 0, channels > 0 else { return 0 }
            let cx = Swift.min(Swift.max(x, 0), width - 1)
            let cy = Swift.min(Swift.max(y, 0), height - 1)
            let cc = Swift.min(Swift.max(c, 0), channels - 1)
            let index = (cy * width + cx) * channels + cc
            // `pixels` is public and can stop matching the size; reading 0 beats trapping.
            return index < pixels.count ? pixels[index] : 0
        }
        set {
            guard x >= 0, y >= 0, c >= 0, x < width, y < height, c < channels else { return }
            let index = (y * width + x) * channels + c
            guard index < pixels.count else { return }
            pixels[index] = newValue
        }
    }
}

/// CPU reference implementation of the stacking math the app runs on the GPU. The simulator backend uses it
/// directly and the tests pin the math.
public struct StackAccumulator: Sendable {
    public private(set) var count: Int
    public let blend: StackBlend
    let width: Int
    let height: Int
    let channels: Int
    /// Running mean for additive and average, running max for lighten. Additive stores the mean too: the caller
    /// applies the frame count once at the end (StackPlan.outputScale), so stored values stay near one frame's range.
    private var storage: [Float]

    /// Sizes are clamped like FloatImage's fill initializer; frames must then match the clamped size.
    public init(width: Int, height: Int, channels: Int, blend: StackBlend) {
        let empty = FloatImage(width: width, height: height, channels: channels)
        self.width = empty.width
        self.height = empty.height
        self.channels = empty.channels
        self.storage = empty.pixels
        self.blend = blend
        self.count = 0
    }

    /// Adds a frame (must match size and channels, otherwise ignored). The frame content is moved by
    /// (shiftX, shiftY) pixels first: content at (x, y) lands at (x + shiftX, y + shiftY); destination pixels with
    /// no source take the nearest edge source pixel (clamped sampling).
    /// additive and average keep a running mean: mean += (frame - mean) / count. lighten keeps a per-channel max
    /// that skips NaN samples.
    public mutating func add(_ frame: FloatImage, shiftX: Int = 0, shiftY: Int = 0) {
        guard frame.width == width, frame.height == height, frame.channels == channels,
              frame.pixels.count == storage.count else { return }
        count += 1
        guard !storage.isEmpty else { return }
        // The first frame is copied, so lighten keeps negative values instead of comparing them with the zero fill.
        let kernel: Kernel = count == 1 ? .copy : (blend == .lighten ? .maximum : .mean)
        // Dividing (not multiplying by 1/count) keeps every step bit-exact with the documented formula.
        let divisor = Float(count)
        let w = width
        let h = height
        let c = channels
        // Beyond one image size every pixel samples the same edge, so larger shifts change nothing;
        // clamping first keeps the index math away from overflow.
        let sx = min(max(shiftX, -w), w)
        let sy = min(max(shiftY, -h), h)
        // Destination columns [left, right) have a source column; the rest repeat the nearest edge column.
        let left = min(max(sx, 0), w)
        let right = min(max(w + sx, 0), w)
        let rowLength = w * c
        frame.pixels.withUnsafeBufferPointer { source in
            storage.withUnsafeMutableBufferPointer { destination in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
                var y = 0
                while y < h {
                    var sourceY = y - sy
                    if sourceY < 0 {
                        sourceY = 0
                    } else if sourceY >= h {
                        sourceY = h - 1
                    }
                    let sourceRow = src + sourceY * rowLength
                    let row = dst + y * rowLength
                    var x = 0
                    while x < left {
                        Self.apply(kernel, row + x * c, sourceRow, c, divisor)
                        x += 1
                    }
                    if right > left {
                        Self.apply(kernel, row + left * c, sourceRow + (left - sx) * c, (right - left) * c, divisor)
                    }
                    x = right
                    while x < w {
                        Self.apply(kernel, row + x * c, sourceRow + (w - 1) * c, c, divisor)
                        x += 1
                    }
                    y += 1
                }
            }
        }
    }

    /// Running mean or max, multiplied by `scale`. count == 0 returns zeros.
    public func result(scale: Double = 1) -> FloatImage {
        guard count > 0 else { return FloatImage(width: width, height: height, channels: channels) }
        var pixels = storage
        if scale != 1 {
            let factor = Float(scale)
            let n = pixels.count
            pixels.withUnsafeMutableBufferPointer { buffer in
                guard let p = buffer.baseAddress else { return }
                var i = 0
                while i < n {
                    p[i] *= factor
                    i += 1
                }
            }
        }
        return FloatImage(width: width, height: height, channels: channels, pixels: pixels)
    }

    private enum Kernel {
        case copy, mean, maximum
    }

    /// One contiguous run of floats. Plain while loops because this runs per frame in Debug builds too,
    /// where iterators and closures cost more than the arithmetic.
    private static func apply(_ kernel: Kernel, _ destination: UnsafeMutablePointer<Float>,
                              _ source: UnsafePointer<Float>, _ length: Int, _ count: Float) {
        var i = 0
        switch kernel {
        case .copy:
            destination.update(from: source, count: length)
        case .mean:
            while i < length {
                destination[i] += (source[i] - destination[i]) / count
                i += 1
            }
        case .maximum:
            while i < length {
                let value = source[i]
                // `!(<=)` also passes when either side is NaN and `value == value` drops a NaN sample, so a NaN
                // stored from the first frame gives way to the next real value. Common path: one comparison.
                if !(value <= destination[i]), value == value {
                    destination[i] = value
                }
                i += 1
            }
        }
    }
}
