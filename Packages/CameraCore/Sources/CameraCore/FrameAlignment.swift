import Foundation

/// Translation between two frames of a stack, in pixels of the images that were compared.
public struct AlignmentResult: Hashable, Sendable {
    public var dx: Double
    public var dy: Double
    /// 0...1: how clearly the best match beat the rest of the search window. Near 0 the shift is a guess.
    public var confidence: Double

    public init(dx: Double, dy: Double, confidence: Double) {
        self.dx = dx
        self.dy = dy
        // NaN fails the comparison and lands on 0, the value that tells callers not to trust the shift.
        self.confidence = confidence > 0 ? min(confidence, 1) : 0
    }

    public static let zero = AlignmentResult(dx: 0, dy: 0, confidence: 0)
}

/// Registration and sharpness scoring for stacked captures. A global translation is the model because the
/// frames of a stack are a fraction of a second apart, where hand shake shows up mostly as a shift.
public enum FrameAlignment {
    /// The coarse search runs on a level no larger than this, so its cost stays fixed for any input size.
    static let coarseLongSide = 64
    /// Smaller inputs leave too few pixels for a search window to mean anything.
    static let minimumSide = 8
    /// Halving stops before a level gets this thin, where a refinement step would span the whole level.
    static let minimumLevelSide = 4
    static let refineRadius = 2
    /// Below this a frame has nothing to lock onto: a lens cap, a black frame, a blank wall.
    static let flatVariance = 1e-8

    /// Global translation with moving(x + dx, y + dy) ~ reference(x, y): the content moved by (dx, dy) from
    /// reference to moving. To align `moving` onto `reference`, shift it by (-dx, -dy).
    /// Coarse to fine: exhaustive SAD search on the smallest 2x box pyramid level within
    /// +/-ceil(maxShift / 2^levels), +/-2 refinement at each finer level, then a parabolic sub-pixel fit
    /// (at most 0.5 px). A coarse winner other than (0, 0) is refined alongside a second hypothesis, no motion;
    /// the lower cost one level above full size (or at full size when that is the next level) picks the one that
    /// finishes. Only the central 80% of each level is compared. The result stays within +/-maxShift.
    /// Images of different sizes, smaller than 8x8, or flat (variance ~0) return `.zero`, as does maxShift <= 0.
    /// confidence = clamp(1 - bestSAD / meanSADOfSearchWindow, 0, 1), from the coarse exhaustive window. It is 0
    /// when the cost still falls just past the final search window, because then the content moved further than
    /// maxShift (or the refinement lost track) and the returned shift is not the real motion.
    public static func estimateTranslation(reference: LumaImage, moving: LumaImage, maxShift: Int = 48) -> AlignmentResult {
        let width = reference.width
        let height = reference.height
        guard width == moving.width, height == moving.height,
              width >= minimumSide, height >= minimumSide,
              reference.pixels.count == width * height, moving.pixels.count == width * height,
              !isFlat(reference), !isFlat(moving) else { return .zero }
        // A shift as large as the image can't be measured, and the cap keeps the range math far from overflow.
        let limit = min(maxShift, max(width, height))
        // A single candidate is its own mean, so the answer would be (0, 0) with confidence 0 anyway.
        guard limit > 0 else { return .zero }
        let references = pyramid(reference)
        let movings = pyramid(moving)
        let coarsest = references.count - 1

        /// The whole shift range when `previous` is nil (the coarsest level), otherwise +/-refineRadius around
        /// twice the shift found one level up.
        func searchLevel(_ level: Int, around previous: (x: Int, y: Int)?) -> Match {
            let ref = references[level]
            let region = centralRegion(width: ref.width, height: ref.height)
            let scale = 1 << level
            let reach = (limit + scale - 1) / scale
            // Keeping half of the compared area inside the overlap stops a sliver of overlap from winning by luck.
            let rangeX = min(reach, (region.right - region.left) / 2)
            let rangeY = min(reach, (region.bottom - region.top) / 2)
            let window: Window
            if let previous {
                let cx = min(max(previous.x * 2, -rangeX), rangeX)
                let cy = min(max(previous.y * 2, -rangeY), rangeY)
                window = Window(xs: max(cx - refineRadius, -rangeX)...min(cx + refineRadius, rangeX),
                                ys: max(cy - refineRadius, -rangeY)...min(cy + refineRadius, rangeY),
                                centerX: cx, centerY: cy)
            } else {
                window = Window(xs: -rangeX...rangeX, ys: -rangeY...rangeY, centerX: 0, centerY: 0)
            }
            return search(ref, movings[level], region: region, window: window, subpixel: level == 0)
        }

        /// Follows a shift found at `level` down through `last`, a finer level. nil when a cost is not finite.
        func refine(x: Int, y: Int, from level: Int, through last: Int) -> Match? {
            var shift = (x: x, y: y)
            var match: Match?
            for finer in stride(from: level - 1, through: last, by: -1) {
                let next = searchLevel(finer, around: shift)
                guard next.cost.isFinite else { return nil }
                shift = (next.x, next.y)
                match = next
            }
            return match
        }

        let coarse = searchLevel(coarsest, around: nil)
        guard coarse.cost.isFinite else { return .zero }
        // Only the coarse window is wide enough to show whether the winner stands out, and noise is
        // averaged away at that scale, so a dim noisy frame that aligns well still scores high.
        var confidence = coarse.meanCost > 0 ? 1 - coarse.cost / coarse.meanCost : 0
        var match = coarse
        if coarsest > 0 {
            // A repeating scene, such as a lit window grid, can make the coarse winner a whole pattern pitch off,
            // and +/-2 per level never finds the way back. Hand shake keeps the real shift small, so no motion is
            // refined as well. The two compete one level above full size, where a search costs a quarter as much,
            // and only the better one is refined at full size.
            let compared = coarsest > 1 ? 1 : 0
            guard var best = refine(x: coarse.x, y: coarse.y, from: coarsest, through: compared) else { return .zero }
            if coarse.x != 0 || coarse.y != 0 {
                guard let noMotion = refine(x: 0, y: 0, from: coarsest, through: compared) else { return .zero }
                // A tie keeps the coarse winner, the better match on the level that saw the whole range.
                if noMotion.cost < best.cost {
                    best = noMotion
                }
            }
            if compared > 0 {
                guard let full = refine(x: best.x, y: best.y, from: compared, through: 0) else { return .zero }
                best = full
            }
            match = best
        }
        // The coarse window rounds up, so its confidence can come from a match past maxShift that the
        // clamped result never reaches. A winner an outside neighbour beats is pinned at a limit.
        if match.beatenOutsideWindow {
            confidence = 0
        }
        let bound = Double(limit)
        return AlignmentResult(dx: min(max(Double(match.x) + match.fractionX, -bound), bound),
                               dy: min(max(Double(match.y) + match.fractionY, -bound), bound),
                               confidence: confidence)
    }

    /// Variance of the 4-neighbour Laplacian over interior pixels. Sharper images score higher. < 3x3 -> 0.
    public static func sharpness(_ image: LumaImage) -> Double {
        let width = image.width
        let height = image.height
        guard width >= 3, height >= 3, image.pixels.count == width * height else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        image.pixels.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return }
            var y = 1
            while y < height - 1 {
                let row = p + y * width
                let above = row - width
                let below = row + width
                // Per-row Float sums keep Double conversions out of the inner loop, which matters in Debug builds.
                var rowSum: Float = 0
                var rowSquares: Float = 0
                var x = 1
                while x < width - 1 {
                    // Paired sums make the Laplacian of a uniform area exactly 0 instead of rounding noise.
                    let laplacian = (above[x] + below[x]) + (row[x - 1] + row[x + 1]) - 4 * row[x]
                    rowSum += laplacian
                    rowSquares += laplacian * laplacian
                    x += 1
                }
                sum += Double(rowSum)
                sumSquares += Double(rowSquares)
                y += 1
            }
        }
        let count = Double((width - 2) * (height - 2))
        let mean = sum / count
        return max(sumSquares / count - mean * mean, 0)
    }

    /// Indices (ascending) of frames whose sharpness >= keepFraction * median. Never empty for non-empty input:
    /// the sharpest frame (the first one on ties) is always kept. NaN scores are left out of the median and never
    /// pass the threshold; if every score is NaN, frame 0 is kept so the stack still has a frame.
    public static func framesToKeep(sharpness: [Double], keepFraction: Double = 0.6) -> [Int] {
        guard !sharpness.isEmpty else { return [] }
        var sharpest = -1
        for (index, value) in sharpness.enumerated() where !value.isNaN {
            if sharpest < 0 || value > sharpness[sharpest] {
                sharpest = index
            }
        }
        guard sharpest >= 0 else { return [0] }
        let sorted = sharpness.filter { !$0.isNaN }.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        let threshold = keepFraction * median
        var kept: [Int] = []
        for (index, value) in sharpness.enumerated() where index == sharpest || value >= threshold {
            kept.append(index)
        }
        return kept
    }

    // MARK: - Internals

    /// Half-open pixel rectangle.
    private struct Region {
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int
    }

    private struct Window {
        var xs: ClosedRange<Int>
        var ys: ClosedRange<Int>
        var centerX: Int
        var centerY: Int
    }

    private struct Match {
        var x = 0
        var y = 0
        var cost = Double.infinity
        var meanCost = 0.0
        var fractionX = 0.0
        var fractionY = 0.0
        /// A neighbour just outside the window scored lower, so the window stopped short of the real minimum.
        var beatenOutsideWindow = false
    }

    /// Level 0 is the input; each next level halves both sides with a 2x2 box filter.
    static func pyramid(_ image: LumaImage) -> [LumaImage] {
        var levels = [image]
        var last = image
        while levels.count == 1 || max(last.width, last.height) > coarseLongSide,
              min(last.width, last.height) / 2 >= minimumLevelSide {
            last = halved(last)
            levels.append(last)
        }
        return levels
    }

    /// 2x2 box average. An odd last row or column is dropped, so level coordinates stay exact multiples of 2.
    static func halved(_ image: LumaImage) -> LumaImage {
        let sourceWidth = image.width
        let width = image.width / 2
        let height = image.height / 2
        guard width > 0, height > 0, image.pixels.count == sourceWidth * image.height else {
            return LumaImage(width: 0, height: 0)
        }
        var pixels = [Float](repeating: 0, count: width * height)
        image.pixels.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
                var y = 0
                while y < height {
                    let top = src + 2 * y * sourceWidth
                    let bottom = top + sourceWidth
                    let out = dst + y * width
                    var x = 0
                    while x < width {
                        let i = 2 * x
                        out[x] = ((top[i] + top[i + 1]) + (bottom[i] + bottom[i + 1])) * 0.25
                        x += 1
                    }
                    y += 1
                }
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    /// One pass with every pixel taken relative to the first: a uniform frame then measures exactly 0, and the
    /// mean-of-squares cancellation stays orders of magnitude below the threshold.
    static func isFlat(_ image: LumaImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, image.pixels.count == width * height else { return true }
        var variance = 0.0
        image.pixels.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return }
            let pivot = p[0]
            var sum = 0.0
            var squares = 0.0
            var y = 0
            while y < height {
                let row = p + y * width
                var rowSum: Float = 0
                var rowSquares: Float = 0
                var x = 0
                while x < width {
                    let d = row[x] - pivot
                    rowSum += d
                    rowSquares += d * d
                    x += 1
                }
                sum += Double(rowSum)
                squares += Double(rowSquares)
                y += 1
            }
            let count = Double(width * height)
            let mean = sum / count
            variance = squares / count - mean * mean
        }
        // NaN fails the comparison too, so frames with invalid pixels count as flat.
        return !(variance > flatVariance)
    }

    /// Central 80%: the borders are where content enters and leaves between frames, so they only add mismatch.
    private static func centralRegion(width: Int, height: Int) -> Region {
        let marginX = Int((Double(width) * 0.1).rounded())
        let marginY = Int((Double(height) * 0.1).rounded())
        return Region(left: marginX, top: marginY, right: width - marginX, bottom: height - marginY)
    }

    /// Scores every candidate in `window` and keeps the lowest cost. With `subpixel`, also fits the parabola
    /// through the neighbours of the winner, computing any that fall outside the window.
    private static func search(_ reference: LumaImage, _ moving: LumaImage, region: Region, window: Window,
                               subpixel: Bool) -> Match {
        let width = reference.width
        let height = reference.height
        var match = Match()
        reference.pixels.withUnsafeBufferPointer { referenceBuffer in
            moving.pixels.withUnsafeBufferPointer { movingBuffer in
                guard let ref = referenceBuffer.baseAddress, let mov = movingBuffer.baseAddress else { return }
                let columns = window.xs.count
                var costs = [Double](repeating: .infinity, count: columns * window.ys.count)
                var total = 0.0
                var evaluated = 0
                var bestDistance = Int.max
                for dy in window.ys {
                    for dx in window.xs {
                        let c = cost(ref, mov, width: width, height: height, region: region, dx: dx, dy: dy)
                        costs[(dy - window.ys.lowerBound) * columns + (dx - window.xs.lowerBound)] = c
                        guard c.isFinite else { continue }
                        total += c
                        evaluated += 1
                        let ox = dx - window.centerX
                        let oy = dy - window.centerY
                        let distance = ox * ox + oy * oy
                        // Equal scores go to the candidate nearest the centre, so ties never drift the estimate.
                        if c < match.cost || (c == match.cost && distance < bestDistance) {
                            match.x = dx
                            match.y = dy
                            match.cost = c
                            bestDistance = distance
                        }
                    }
                }
                match.meanCost = evaluated > 0 ? total / Double(evaluated) : 0
                guard subpixel, match.cost.isFinite else { return }
                // Neighbours past the shift range are scored too: a shift just inside the limit keeps its
                // sub-pixel part, and the caller clamps the final value to the limit anyway.
                func costAt(_ dx: Int, _ dy: Int) -> Double {
                    if window.xs.contains(dx), window.ys.contains(dy) {
                        return costs[(dy - window.ys.lowerBound) * columns + (dx - window.xs.lowerBound)]
                    }
                    return cost(ref, mov, width: width, height: height, region: region, dx: dx, dy: dy)
                }
                let minusX = costAt(match.x - 1, match.y)
                let plusX = costAt(match.x + 1, match.y)
                let minusY = costAt(match.x, match.y - 1)
                let plusY = costAt(match.x, match.y + 1)
                // Inside the window nothing beats the winner, so only an outside neighbour can.
                match.beatenOutsideWindow = minusX < match.cost || plusX < match.cost
                    || minusY < match.cost || plusY < match.cost
                match.fractionX = parabolicOffset(minus: minusX, center: match.cost, plus: plusX)
                match.fractionY = parabolicOffset(minus: minusY, center: match.cost, plus: plusY)
            }
        }
        return match
    }

    /// Mean absolute difference between reference(x, y) and moving(x + dx, y + dy) over the part of `region`
    /// where the moving sample exists. A mean rather than a sum, so candidates with less overlap compete fairly.
    private static func cost(_ reference: UnsafePointer<Float>, _ moving: UnsafePointer<Float>, width: Int,
                             height: Int, region: Region, dx: Int, dy: Int) -> Double {
        let left = max(region.left, -dx)
        let right = min(region.right, width - dx)
        let top = max(region.top, -dy)
        let bottom = min(region.bottom, height - dy)
        guard right > left, bottom > top else { return .infinity }
        let run = right - left
        let zero: Float = 0
        var total = 0.0
        var y = top
        while y < bottom {
            var r = reference + (y * width + left)
            var m = moving + ((y + dy) * width + left + dx)
            let blockEnd = r + (run - run % 4)
            let rowEnd = r + run
            // Four partial sums let the adds overlap instead of each waiting for the previous one.
            var s0: Float = 0
            var s1: Float = 0
            var s2: Float = 0
            var s3: Float = 0
            while r < blockEnd {
                let d0 = r[0] - m[0]
                let d1 = r[1] - m[1]
                let d2 = r[2] - m[2]
                let d3 = r[3] - m[3]
                // A comparison instead of abs(), which is a generic call in Debug builds.
                s0 += d0 < zero ? -d0 : d0
                s1 += d1 < zero ? -d1 : d1
                s2 += d2 < zero ? -d2 : d2
                s3 += d3 < zero ? -d3 : d3
                r += 4
                m += 4
            }
            while r < rowEnd {
                let d = r.pointee - m.pointee
                s0 += d < zero ? -d : d
                r += 1
                m += 1
            }
            total += Double((s0 + s1) + (s2 + s3))
            y += 1
        }
        return total / Double(run * (bottom - top))
    }

    /// Vertex of the parabola through the costs at -1, 0 and +1, clamped to +/-0.5.
    static func parabolicOffset(minus: Double, center: Double, plus: Double) -> Double {
        let curvature = minus - 2 * center + plus
        // A flat or downward-opening triple has no minimum to move toward, so the integer position stands.
        guard minus.isFinite, plus.isFinite, curvature > 0 else { return 0 }
        let offset = (minus - plus) / (2 * curvature)
        return min(max(offset, -0.5), 0.5)
    }
}
