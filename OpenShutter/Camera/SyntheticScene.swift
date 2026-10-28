import Foundation
import Accelerate
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CameraCore

// The simulator's subject: a street at night, drawn with Core Graphics in linear light so bright lamps keep
// their brightness, then exposed, white balanced and defocused with Core Image like a sensor would see it.

/// How one synthetic frame is exposed, framed and lit.
struct SceneShot: Equatable, Sendable {
    /// Scene clock at the end of the exposure, in seconds. Drives the traffic and the blinking lights.
    var time: Double
    /// How long the shutter stays open; moving lights smear over this time.
    var shutterSeconds: Double
    /// Light product (t × ISO / N²) relative to `SyntheticScene.referenceProduct`. 1 is the scene's correct exposure.
    var gain: Double
    /// Sensor gain, which sets the amount of noise.
    var iso: Double
    var kelvin: Double
    var tint: Double
    /// Defocus blur (Gaussian sigma) as a fraction of the frame width.
    var blur: Double
    var framing: SceneFraming
    /// Flash or torch light on the foreground, 0...1.
    var foregroundLight: Double
    /// Where the meter looks, in normalized frame coordinates (top-left origin). nil meters center weighted.
    var meteringPoint: CGPoint?
    /// A spot or whole frame meter reads only this rect, evenly, in the same coordinates. nil weighs around the point.
    var meteringRect: CGRect? = nil
    var addsNoise: Bool
    /// A stack frame that starts as the one before it ends. Moving lights then draw as pieces of one trail.
    var isBackToBack = false

    /// The shot auto exposure and auto white balance are calibrated against.
    static let reference = SceneShot(
        time: 0, shutterSeconds: 1.0 / 30, gain: 1, iso: 100, kelvin: SyntheticScene.referenceKelvin, tint: 0,
        blur: 0, framing: .reference, foregroundLight: 0, meteringPoint: nil, addsNoise: false
    )
}

/// Which part of the street the frame shows.
struct SceneFraming: Hashable, Sendable {
    /// Magnification relative to the main camera at 1x (0.5 for the ultra wide).
    var zoom: Double
    /// Front camera previews are shown like a mirror.
    var mirrored: Bool

    static let reference = SceneFraming(zoom: 1, mirrored: false)
}

/// What the simulated sensor's meter reads from a frame.
struct SceneMeter: Sendable {
    /// Metered brightness relative to the scene's calibrated mid level, in EV. 0 is correctly exposed.
    var offset: Double
    /// Gray world estimate of the light, for a quick custom white balance.
    var grayWorldKelvin: Double
    var grayWorldTint: Double
    /// Where auto white balance settles: gray world, but keeping part of the night's warmth.
    var autoKelvin: Double
    var autoTint: Double
}

/// One rendered frame: the picture for the preview and the bytes behind it, which never change after rendering.
final class SceneFrame: @unchecked Sendable {
    let image: CGImage
    /// BGRX, 8 bits per channel, sRGB.
    let pixels: NSData
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let shot: SceneShot
    /// nil for unmetered frames (photos), and until the renderer has calibrated its meter.
    let meter: SceneMeter?

    fileprivate init(image: CGImage, pixels: NSData, width: Int, height: Int, bytesPerRow: Int, shot: SceneShot, meter: SceneMeter?) {
        self.image = image
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.shot = shot
        self.meter = meter
    }

    /// The bytes as a CameraCore plane. The view is only valid inside `body`.
    func withPlane<Result>(_ body: (PlaneView) -> Result) -> Result {
        withExtendedLifetime(pixels) {
            body(PlaneView(base: pixels.bytes, width: width, height: height, bytesPerRow: bytesPerRow))
        }
    }
}

/// Renders the street. One instance per queue: it keeps the drawn background and a drawing context between frames.
final class SyntheticScene: @unchecked Sendable {
    /// Light product at which the street comes out as designed: about 1/8 s at ISO 480 at ƒ/1.48,
    /// a dim street at night.
    static let referenceProduct = 26.0
    /// White balance under which the scene's colors look as designed.
    static let referenceKelvin = 4000.0

    let width: Int
    let height: Int

    private var cachedFraming: SceneFraming?
    private var cachedBackground: CGImage?
    private var frameContext: CGContext?
    private var calibration: Calibration?
    private var noiseScratch: [Float] = []
    private var random = SplitMix64(seed: 0x0DDB_1A5E_5BAD_5EED)

    init(width: Int, height: Int) {
        self.width = max(width, 16)
        self.height = max(height, 16)
    }

    // MARK: - Rendering

    /// A display frame: sRGB, with sensor noise, plus what the meter reads from it. `metered` false skips the
    /// meter, which a photo doesn't need.
    func renderFrame(_ shot: SceneShot, metered: Bool = true) -> SceneFrame? {
        if metered && calibration == nil {
            calibration = calibrate()
        }
        let rowBytes = width * 4
        guard let pixels = renderDisplayBytes(shot, rowBytes: rowBytes), let space = Self.sRGBSpace,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        // No alpha: the layer can draw it without blending, and the noise pass may touch the padding byte.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let meter = metered ? calibration.flatMap { calibration in
            statistics(of: pixels.bytes, rowBytes: rowBytes, shot: shot).flatMap { Self.meter(from: $0, calibration: calibration) }
        } : nil
        return SceneFrame(image: image, pixels: pixels, width: width, height: height, bytesPerRow: rowBytes, shot: shot, meter: meter)
    }

    /// Linear sensor values, clipped to 0...1 like a sensor's full well, RGBA with alpha 1. For stacking.
    func renderLinear(_ shot: SceneShot) -> FloatImage? {
        guard let image = exposedImage(for: shot) else { return nil }
        let pixelCount = width * height
        var pixels = [Float](repeating: 0, count: pixelCount * 4)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            Self.ciContext.render(image, toBitmap: base, rowBytes: width * 16,
                                  bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                  format: .RGBAf, colorSpace: Self.linearSpace)
            return true
        }
        guard rendered else { return nil }
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            if shot.addsNoise {
                addNoise(toLinear: base, count: buffer.count, sigma: Float(Self.noiseLevels(iso: shot.iso) * Self.linearNoisePerLevel))
            }
            var low: Float = 0
            var high: Float = 1
            vDSP_vclip(base, 1, &low, &high, base, 1, vDSP_Length(buffer.count))
            var one: Float = 1
            vDSP_vfill(&one, base + 3, 4, vDSP_Length(pixelCount))
        }
        return FloatImage(width: width, height: height, channels: 4, pixels: pixels)
    }

    /// Frees the drawn background and the drawing buffers. The next frame draws them again.
    func releaseCaches() {
        cachedFraming = nil
        cachedBackground = nil
        frameContext = nil
        noiseScratch = []
    }

    /// Turns linear RGBA (a stack result) into an sRGB picture: optionally enlarged, mirrored and cropped.
    static func displayImage(fromLinear image: FloatImage, upscale: Double = 1, mirrored: Bool = false,
                             aspect: AspectRatio? = nil) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, image.channels == 4, image.pixels.count == width * height * 4,
              let space = sRGBSpace else { return nil }
        var pixels = image.pixels
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            // The accumulator scales alpha along with the color, but Core Image reads the buffer as premultiplied.
            var one: Float = 1
            vDSP_vfill(&one, base + 3, 4, vDSP_Length(width * height))
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        var output = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                             format: .RGBAf, colorSpace: linearSpace)
        if upscale.isFinite, upscale > 1.001 {
            let scale = CIFilter.lanczosScaleTransform()
            scale.inputImage = output
            scale.scale = Float(upscale)
            scale.aspectRatio = 1
            guard let scaled = scale.outputImage else { return nil }
            output = scaled
        }
        let extent = output.extent
        if mirrored {
            output = output.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.minX + extent.maxX, ty: 0))
        }
        var rect = extent
        if let aspect {
            let crop = aspect.centeredCrop(width: Double(extent.width), height: Double(extent.height))
            // The crop is top-left based; Core Image's y axis points up.
            rect = CGRect(x: extent.minX + CGFloat(crop.x), y: extent.maxY - CGFloat(crop.y + crop.height),
                          width: CGFloat(crop.width), height: CGFloat(crop.height)).integral.intersection(extent)
        }
        guard !rect.isEmpty else { return nil }
        return ciContext.createCGImage(output, from: rect, format: .RGBA8, colorSpace: space)
    }

    // MARK: - White balance model

    /// A black body's color at `kelvin` as a camera sees it, relative to green. Camera color filters overlap much
    /// more than sRGB primaries, so the sRGB ratios are compressed (square root) to stay in a camera's gain range.
    static func lightColor(kelvin: Double) -> (red: Double, blue: Double) {
        let t = clamped(kelvin.isFinite ? kelvin : referenceKelvin, 1600...25000)
        let t2 = t * t
        // Krystek's fit of the Planckian locus in CIE 1960 (u, v).
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t2) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t2)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t2) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t2)
        let d = 2 * u - 8 * v + 4
        let x = 3 * u / d
        let y = 2 * v / d
        let bigX = x / y
        let bigZ = (1 - x - y) / y
        let r = 3.2406 * bigX - 1.5372 - 0.4986 * bigZ
        let g = -0.9689 * bigX + 1.8758 + 0.0415 * bigZ
        let b = 0.0557 * bigX - 0.2040 + 1.0570 * bigZ
        guard g > 0, r.isFinite, b.isFinite else { return (1, 1) }
        return (max(r / g, 1e-4).squareRoot(), max(b / g, 1e-4).squareRoot())
    }

    /// Per-channel gains a camera set to `kelvin` and `tint` applies. Positive tint takes out green.
    static func whiteBalanceGains(kelvin: Double, tint: Double) -> (red: Double, green: Double, blue: Double) {
        let light = lightColor(kelvin: kelvin)
        let t = tint.isFinite ? clamped(tint, WhiteBalanceMath.tintRange) : 0
        return (1 / light.red, pow(2, -t / 300), 1 / light.blue)
    }

    /// The light that would make these average colors (before white balance) neutral.
    static func grayWorld(red: Double, green: Double, blue: Double) -> (kelvin: Double, tint: Double)? {
        guard red > 1e-6, green > 1e-6, blue > 1e-6, red.isFinite, green.isFinite, blue.isFinite else { return nil }
        let target = log(blue / red)
        var best = temperatureTable[0]
        for entry in temperatureTable where abs(entry.logRatio - target) < abs(best.logRatio - target) {
            best = entry
        }
        let kelvin = 1e6 / best.mired
        let light = lightColor(kelvin: kelvin)
        let neutral = (red / light.red + blue / light.blue) / 2
        guard neutral > 0 else { return nil }
        let tint = 300 * log2(green / neutral)
        return (kelvin, tint.isFinite ? clamped(tint, WhiteBalanceMath.tintRange) : 0)
    }

    // MARK: - Pipeline

    private struct Calibration {
        /// Metered luminance of the reference shot.
        var luminance: Double
        /// Gray world of the reference shot, which auto white balance treats as neutral.
        var mired: Double
        var tint: Double
    }

    private struct Statistics {
        var luminance: Double
        var red: Double
        var green: Double
        var blue: Double
    }

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private static let ciContext: CIContext = {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let linearSpace {
            options[.workingColorSpace] = linearSpace
        }
        return CIContext(options: options)
    }()

    /// Blur beyond a sixteenth of the frame width costs time and shows nothing new. A share of the width, not
    /// pixels, so a photo at twice the preview size is as soft as the preview that framed it.
    private static let maxBlurFraction = 1.0 / 16

    /// Measures the reference shot, so "correctly exposed" and "neutral" mean what the scene was designed for
    /// regardless of how the drawing averages out.
    private func calibrate() -> Calibration? {
        let rowBytes = width * 4
        let shot = SceneShot.reference
        guard let pixels = renderDisplayBytes(shot, rowBytes: rowBytes),
              let stats = statistics(of: pixels.bytes, rowBytes: rowBytes, shot: shot), stats.luminance > 1e-5,
              let gray = Self.grayWorld(red: stats.red, green: stats.green, blue: stats.blue) else { return nil }
        return Calibration(luminance: stats.luminance, mired: 1e6 / gray.kelvin, tint: gray.tint)
    }

    private func renderDisplayBytes(_ shot: SceneShot, rowBytes: Int) -> NSMutableData? {
        guard let image = exposedImage(for: shot), let space = Self.sRGBSpace,
              let pixels = NSMutableData(length: rowBytes * height) else { return nil }
        Self.ciContext.render(image, toBitmap: pixels.mutableBytes, rowBytes: rowBytes,
                              bounds: CGRect(x: 0, y: 0, width: width, height: height),
                              format: .BGRA8, colorSpace: space)
        if shot.addsNoise {
            addNoise(toBytes: pixels.mutableBytes.assumingMemoryBound(to: UInt8.self), count: rowBytes * height,
                     sigma: Float(Self.noiseLevels(iso: shot.iso)))
        }
        return pixels
    }

    /// The scene times exposure and white balance, defocused and mirrored as asked. Linear, unclipped.
    private func exposedImage(for shot: SceneShot) -> CIImage? {
        guard let scene = sceneImage(for: shot) else { return nil }
        let source = CIImage(cgImage: scene)
        let extent = source.extent
        let gains = Self.whiteBalanceGains(kelvin: shot.kelvin, tint: shot.tint)
        let gain = shot.gain.isFinite && shot.gain > 0 ? shot.gain : 1
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = source
        matrix.rVector = CIVector(x: CGFloat(gain * gains.red), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(gain * gains.green), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(gain * gains.blue), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard var image = matrix.outputImage else { return nil }
        let sigma = shot.blur.isFinite ? min(shot.blur, Self.maxBlurFraction) * Double(width) : 0
        if sigma > 0.35 {
            image = Self.defocused(image, sigma: sigma, extent: extent)
        }
        if shot.framing.mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.minX + extent.maxX, ty: 0))
        }
        return image
    }

    /// Defocus happens before clipping, so out-of-focus lamps bloom into bright discs like real bokeh.
    private static func defocused(_ image: CIImage, sigma: Double, extent: CGRect) -> CIImage {
        // A wide blur looks the same on a smaller copy and costs a fraction; Lanczos keeps small lights from aliasing away.
        var shrink: Double = sigma > 14 ? 0.25 : (sigma > 6 ? 0.5 : 1)
        var work = image
        if shrink < 1 {
            let scale = CIFilter.lanczosScaleTransform()
            scale.inputImage = image
            scale.scale = Float(shrink)
            scale.aspectRatio = 1
            if let scaled = scale.outputImage {
                work = scaled
            } else {
                shrink = 1
            }
        }
        work = work.clampedToExtent().applyingGaussianBlur(sigma: sigma * shrink)
        if shrink < 1 {
            work = work.transformed(by: CGAffineTransform(scaleX: CGFloat(1 / shrink), y: CGFloat(1 / shrink)))
        }
        return work.cropped(to: extent)
    }

    /// The drawn street for this shot: the cached background plus everything that moves.
    private func sceneImage(for shot: SceneShot) -> CGImage? {
        guard let background = background(for: shot.framing), let space = Self.linearSpace else { return nil }
        if frameContext == nil {
            frameContext = Self.makeContext(width: width, height: height)
        }
        guard let context = frameContext else { return nil }
        var painter = ScenePainter(context: context, space: space, framing: shot.framing, width: width, height: height)
        painter.joinsTrails = shot.isBackToBack
        context.saveGState()
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)
        painter.enterWorld()
        painter.drawMovingParts(time: shot.time, shutter: max(shot.shutterSeconds, 1e-5), foregroundLight: shot.foregroundLight)
        context.restoreGState()
        return context.makeImage()
    }

    private func background(for framing: SceneFraming) -> CGImage? {
        if framing == cachedFraming, let cachedBackground {
            return cachedBackground
        }
        guard let space = Self.linearSpace, let context = Self.makeContext(width: width, height: height) else { return nil }
        let painter = ScenePainter(context: context, space: space, framing: framing, width: width, height: height)
        context.saveGState()
        painter.enterWorld()
        painter.drawStill()
        context.restoreGState()
        let image = context.makeImage()
        cachedFraming = framing
        cachedBackground = image
        return image
    }

    /// Half-float linear light keeps lamps hundreds of times brighter than the walls, which exposure changes need.
    /// Should the format be unavailable, 8-bit sRGB still draws everything, only with lights clipped at white.
    private static func makeContext(width: Int, height: Int) -> CGContext? {
        if let linearSpace {
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGImageComponentInfo.float.rawValue
                | CGImageByteOrderInfo.order16Little.rawValue
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                                       space: linearSpace, bitmapInfo: info) {
                return context
            }
        }
        guard let sRGBSpace else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: sRGBSpace, bitmapInfo: info)
    }

    // MARK: - Meter

    /// Linear values for 8-bit sRGB codes.
    private static let linearTable: [Double] = (0..<256).map { code in
        let value = Double(code) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Samples about 4000 pixels. Luminance is weighted around the metering point (or the center), or read evenly
    /// inside the metering rect; colors are a plain average for gray world. Both are taken before white balance, as
    /// a camera meters raw sensor data.
    private func statistics(of bytes: UnsafeRawPointer, rowBytes: Int, shot: SceneShot) -> Statistics? {
        let gains = Self.whiteBalanceGains(kelvin: shot.kelvin, tint: shot.tint)
        let table = Self.linearTable
        let data = bytes.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)
        let spot = shot.meteringPoint
        let area = shot.meteringRect
        let centerX = Double(spot?.x ?? 0.5)
        let centerY = Double(spot?.y ?? 0.5)
        let sigma = spot == nil ? 0.32 : 0.12
        let floor = spot == nil ? 0.15 : 0.04
        let spread = 2 * sigma * sigma
        let aspect = Double(height) / Double(width)
        var weighted = 0.0
        var weights = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var samples = 0.0
        var y = stepY / 2
        while y < height {
            let row = data + y * rowBytes
            let v = Double(y) / Double(height)
            let dy = (v - centerY) * aspect
            var x = stepX / 2
            while x < width {
                let pixel = row + x * 4
                let b = table[Int(pixel[0])] / gains.blue
                let g = table[Int(pixel[1])] / gains.green
                let r = table[Int(pixel[2])] / gains.red
                let u = Double(x) / Double(width)
                let dx = u - centerX
                let weight: Double
                if let area {
                    weight = area.contains(CGPoint(x: u, y: v)) ? 1 : 0
                } else {
                    weight = floor + exp(-(dx * dx + dy * dy) / spread)
                }
                weighted += weight * (0.2126 * r + 0.7152 * g + 0.0722 * b)
                weights += weight
                red += r
                green += g
                blue += b
                samples += 1
                x += stepX
            }
            y += stepY
        }
        guard weights > 0, samples > 0 else { return nil }
        return Statistics(luminance: weighted / weights, red: red / samples, green: green / samples, blue: blue / samples)
    }

    private static func meter(from stats: Statistics, calibration: Calibration) -> SceneMeter? {
        let offset = log2(max(stats.luminance, 1e-7) / calibration.luminance)
        guard offset.isFinite else { return nil }
        // In near darkness the colors are mostly noise, so white balance keeps to the calibrated light.
        let gray = stats.luminance > calibration.luminance / 256
            ? grayWorld(red: stats.red, green: stats.green, blue: stats.blue)
            : nil
        let grayKelvin = gray?.kelvin ?? 1e6 / calibration.mired
        let grayTint = gray?.tint ?? calibration.tint
        // Auto white balance follows only part of the change, so lamplight keeps some of its warmth.
        let autoMired = 1e6 / referenceKelvin + 0.6 * (1e6 / grayKelvin - calibration.mired)
        let autoKelvin = autoMired > 0 ? clamped(1e6 / autoMired, WhiteBalanceMath.kelvinRange) : WhiteBalanceMath.kelvinRange.upperBound
        let autoTint = clamped(0.6 * (grayTint - calibration.tint), WhiteBalanceMath.tintRange)
        return SceneMeter(offset: clamped(offset, -16...16),
                          grayWorldKelvin: clamped(grayKelvin, WhiteBalanceMath.kelvinRange),
                          grayWorldTint: grayTint,
                          autoKelvin: autoKelvin,
                          autoTint: autoTint)
    }

    /// Ratio of blue to red light for every mired from 100 to 500 (10000 K to 2000 K), for the gray world search.
    private static let temperatureTable: [(mired: Double, logRatio: Double)] = stride(from: 100.0, through: 500.0, by: 1.0).map { mired in
        let light = lightColor(kelvin: 1e6 / mired)
        return (mired, log(light.blue / light.red))
    }

    // MARK: - Noise

    /// Standard deviation of the noise in 8-bit levels: barely there at base ISO, grainy at the top.
    private static func noiseLevels(iso: Double) -> Double {
        guard iso.isFinite, iso > 0 else { return 0 }
        return 0.45 * pow(iso / 50, 0.62)
    }

    /// Converts noise levels to linear values in the shadows, where noise shows.
    private static let linearNoisePerLevel = 1.0 / (255 * 4.3)

    private static let noiseChunk = 1 << 18

    /// A million uniform values with unit variance, read from a random offset each frame so the grain moves.
    private static let noiseTable: [Float] = {
        var generator = SplitMix64(seed: 0x00C0_FFEE_0F_5EED)
        let spread = Float(3.0.squareRoot())
        return (0..<(1 << 20)).map { _ in Float(generator.unit()) * 2 * spread - spread }
    }()

    /// Adds noise to 8-bit samples with vDSP, which keeps it to a few milliseconds even in Debug builds.
    private func addNoise(toBytes bytes: UnsafeMutablePointer<UInt8>, count: Int, sigma: Float) {
        guard sigma > 0.05, count > 0 else { return }
        let chunk = Self.noiseChunk
        if noiseScratch.count < chunk {
            noiseScratch = [Float](repeating: 0, count: chunk)
        }
        var position = Int(random.next() % UInt64(Self.noiseTable.count))
        var scale = sigma
        var low: Float = 0
        var high: Float = 255
        noiseScratch.withUnsafeMutableBufferPointer { scratch in
            Self.noiseTable.withUnsafeBufferPointer { table in
                guard let work = scratch.baseAddress, let noise = table.baseAddress, !table.isEmpty else { return }
                var done = 0
                while done < count {
                    let length = min(chunk, count - done)
                    vDSP_vfltu8(bytes + done, 1, work, 1, vDSP_Length(length))
                    var filled = 0
                    while filled < length {
                        let run = min(length - filled, table.count - position)
                        vDSP_vsma(noise + position, 1, &scale, work + filled, 1, work + filled, 1, vDSP_Length(run))
                        filled += run
                        position = (position + run) % table.count
                    }
                    vDSP_vclip(work, 1, &low, &high, work, 1, vDSP_Length(length))
                    vDSP_vfixru8(work, 1, bytes + done, 1, vDSP_Length(length))
                    done += length
                }
            }
        }
    }

    private func addNoise(toLinear values: UnsafeMutablePointer<Float>, count: Int, sigma: Float) {
        guard sigma > 0, count > 0 else { return }
        var position = Int(random.next() % UInt64(Self.noiseTable.count))
        var scale = sigma
        Self.noiseTable.withUnsafeBufferPointer { table in
            guard let noise = table.baseAddress, !table.isEmpty else { return }
            var done = 0
            while done < count {
                let run = min(count - done, table.count - position)
                vDSP_vsma(noise + position, 1, &scale, values + done, 1, values + done, 1, vDSP_Length(run))
                done += run
                position = (position + run) % table.count
            }
        }
    }
}

// MARK: - Helpers

/// NaN lands on the lower bound, so it never reaches a filter or the meter.
private func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    guard !value.isNaN else { return range.lowerBound }
    return min(max(value, range.lowerBound), range.upperBound)
}

/// Small, fast and reproducible, so the street is the same on every launch.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }
}

/// Scene-referred light in linear RGB, already tinted by the reference light, so a camera balanced for
/// `SyntheticScene.referenceKelvin` shows exactly the designed color.
private struct Radiance: Sendable {
    var r: Double
    var g: Double
    var b: Double

    /// The color as it should look at the reference exposure, in sRGB 0...255, times `intensity` for lights
    /// brighter than white.
    init(_ red: Double, _ green: Double, _ blue: Double, _ intensity: Double = 1) {
        let light = Self.referenceLight
        r = Self.linear(red) * intensity * light.red
        g = Self.linear(green) * intensity
        b = Self.linear(blue) * intensity * light.blue
    }

    private init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func scaled(_ factor: Double) -> Radiance {
        Radiance(r: r * factor, g: g * factor, b: b * factor)
    }

    private static let referenceLight = SyntheticScene.lightColor(kelvin: SyntheticScene.referenceKelvin)

    private static func linear(_ code: Double) -> Double {
        let value = min(max(code / 255, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

// MARK: - The street

/// Places in the world, in units of the main camera's 1x frame (768 × 1024, top-left origin, about 4 cm each).
private enum World {
    static let referenceSize = CGSize(width: 768, height: 1024)
    static let center = CGPoint(x: 384, y: 512)

    static let skyTop: CGFloat = -700
    static let skyBottom: CGFloat = 800
    static let groundFloorTop: CGFloat = 690
    static let streetLine: CGFloat = 770
    static let curbTop: CGFloat = 798
    static let roadTop: CGFloat = 803
    static let laneMarkY: CGFloat = 904
    static let roadBottom: CGFloat = 1012
    static let nearSidewalkTop: CGFloat = 1024
    static let bottom: CGFloat = 1800
    static let left: CGFloat = -800
    static let right: CGFloat = 1600

    static let moon = CGPoint(x: 150, y: 96)
    static let moonRadius: CGFloat = 21
    static let lampBulb = CGPoint(x: 566, y: 553)
    static let antennaTip = CGPoint(x: 388, y: 168)
    static let chartFrame = CGRect(x: 318, y: 506, width: 140, height: 108)
    static let neonCenter = CGPoint(x: 43, y: 666)

    static let farLaneY: CGFloat = 862
    static let nearLaneY: CGFloat = 950
    /// Lanes run past both edges of the ultra wide view, so cars appear and leave out of frame.
    static let laneWest: CGFloat = -660
    static let laneEast: CGFloat = 1440
    static let nearSpeed = 290.0
    static let farSpeed = 236.0
    static let trafficPeriod = 19.0
    static let blinkPeriod = 2.0
    static let blinkOn = 0.45
}

private struct SceneLayout: Sendable {
    struct Window: Sendable {
        var rect: CGRect
        var light: Radiance?
        var hasCurtain: Bool
        var hasMullion: Bool
    }

    enum Storefront: Sendable {
        case shutter, dark, neon
        case lit(Radiance)
        case sign(Radiance)
    }

    enum Roof: Sendable {
        case plain, waterTower, antenna, airConditioners
    }

    struct Building: Sendable {
        var frame: CGRect
        var face: Radiance
        var trim: Radiance
        var windows: [Window]
        var isOffice: Bool
        var storefront: Storefront
        var roof: Roof
    }

    struct Star: Sendable {
        var center: CGPoint
        /// In output pixels: stars stay points at any zoom.
        var radius: CGFloat
        var light: Radiance
    }

    enum Lane: Sendable {
        case near, far
    }

    struct Car: Sendable {
        var lane: Lane
        /// When the car enters its lane, within each traffic period.
        var offset: Double
        var length: CGFloat
        var body: Radiance
    }

    struct Patch: Sendable {
        var rect: CGRect
        var light: Radiance
    }

    /// A building one street further back: a hazy silhouette with a few lit windows.
    struct Silhouette: Sendable {
        var frame: CGRect
        var lights: [CGRect]
    }

    let buildings: [Building]
    let skyline: [Silhouette]
    let stars: [Star]
    let cars: [Car]
    let chart: [Patch]
    /// One window shows a television's flicker instead of a steady light.
    let televisionWindow: CGRect?

    static let shared = SceneLayout()

    private struct BuildingSpec {
        var minX: CGFloat
        var maxX: CGFloat
        var top: CGFloat
        var face: Radiance
        var litShare: Double
        var isOffice: Bool
        var storefront: Storefront
        var roof: Roof
    }

    private init() {
        var random = SplitMix64(seed: 0x57EE_7A7_1111)
        let specs: [BuildingSpec] = [
            BuildingSpec(minX: -440, maxX: -232, top: 430, face: Radiance(19, 18, 22), litShare: 0.45, isOffice: false,
                         storefront: .shutter, roof: .plain),
            BuildingSpec(minX: -228, maxX: -44, top: 350, face: Radiance(23, 21, 25), litShare: 0.5, isOffice: false,
                         storefront: .lit(Radiance(200, 226, 255, 0.85)), roof: .plain),
            BuildingSpec(minX: -40, maxX: 132, top: 470, face: Radiance(17, 17, 21), litShare: 0.4, isOffice: false,
                         storefront: .neon, roof: .waterTower),
            BuildingSpec(minX: 136, maxX: 302, top: 390, face: Radiance(21, 22, 27), litShare: 0.65, isOffice: true,
                         storefront: .lit(Radiance(255, 228, 188, 0.7)), roof: .plain),
            BuildingSpec(minX: 306, maxX: 470, top: 258, face: Radiance(18, 18, 23), litShare: 0.45, isOffice: false,
                         storefront: .dark, roof: .antenna),
            BuildingSpec(minX: 474, maxX: 640, top: 436, face: Radiance(22, 20, 23), litShare: 0.4, isOffice: false,
                         storefront: .dark, roof: .plain),
            BuildingSpec(minX: 644, maxX: 822, top: 368, face: Radiance(20, 19, 23), litShare: 0.5, isOffice: false,
                         storefront: .lit(Radiance(255, 192, 120, 0.9)), roof: .airConditioners),
            BuildingSpec(minX: 826, maxX: 1002, top: 488, face: Radiance(18, 18, 22), litShare: 0.45, isOffice: false,
                         storefront: .sign(Radiance(255, 70, 50, 2.2)), roof: .plain),
            BuildingSpec(minX: 1006, maxX: 1240, top: 404, face: Radiance(21, 20, 24), litShare: 0.5, isOffice: false,
                         storefront: .lit(Radiance(222, 238, 255, 0.85)), roof: .plain),
        ]
        var buildings: [Building] = []
        var television: CGRect?
        for (index, spec) in specs.enumerated() {
            var windows = spec.isOffice
                ? Self.officeWindows(spec, random: &random)
                : Self.homeWindows(spec, random: &random)
            // The fifth building's third floor has someone watching television.
            if index == 5, windows.count > 7 {
                television = windows[7].rect
                windows[7].light = nil
            }
            buildings.append(Building(frame: CGRect(x: spec.minX, y: spec.top, width: spec.maxX - spec.minX,
                                                    height: World.curbTop - spec.top),
                                      face: spec.face, trim: spec.face.scaled(1.6), windows: windows,
                                      isOffice: spec.isOffice, storefront: spec.storefront, roof: spec.roof))
        }
        self.buildings = buildings
        televisionWindow = television
        skyline = Self.makeSkyline(random: &random)
        stars = Self.makeStars(random: &random)
        cars = Self.makeCars(random: &random)
        chart = Self.makeChart()
    }

    private static func homeWindows(_ spec: BuildingSpec, random: inout SplitMix64) -> [Window] {
        let size = CGSize(width: 26, height: 34)
        let pitch: CGFloat = 48
        let floorHeight: CGFloat = 75
        let width = spec.maxX - spec.minX
        let columns = max(1, Int((width - 28 + (pitch - size.width)) / pitch))
        let span = CGFloat(columns) * pitch - (pitch - size.width)
        let startX = spec.minX + (width - span) / 2
        let warm = [Radiance(255, 196, 124), Radiance(255, 176, 102), Radiance(240, 228, 206), Radiance(196, 214, 255)]
        var windows: [Window] = []
        var y = spec.top + 28
        while y + size.height <= World.groundFloorTop - 14 {
            for column in 0..<columns {
                let rect = CGRect(x: startX + CGFloat(column) * pitch, y: y, width: size.width, height: size.height)
                // The color chart's light box hangs on this facade; no windows behind it.
                if rect.intersects(World.chartFrame.insetBy(dx: -8, dy: -8)) { continue }
                var light: Radiance?
                if random.unit() < spec.litShare {
                    let roll = random.unit()
                    let tone = roll < 0.5 ? warm[0] : (roll < 0.72 ? warm[1] : (roll < 0.86 ? warm[2] : warm[3]))
                    light = tone.scaled(0.45 + 0.5 * random.unit())
                }
                windows.append(Window(rect: rect, light: light, hasCurtain: random.unit() < 0.35,
                                      hasMullion: random.unit() < 0.6))
            }
            y += floorHeight
        }
        return windows
    }

    private static func officeWindows(_ spec: BuildingSpec, random: inout SplitMix64) -> [Window] {
        var windows: [Window] = []
        var y = spec.top + 24
        while y + 30 <= World.groundFloorTop - 12 {
            let lit = random.unit() < spec.litShare
            let rect = CGRect(x: spec.minX + 12, y: y, width: spec.maxX - spec.minX - 24, height: 30)
            windows.append(Window(rect: rect, light: lit ? Radiance(214, 230, 255, 0.55 + 0.3 * random.unit()) : nil,
                                  hasCurtain: false, hasMullion: true))
            y += 52
        }
        return windows
    }

    /// Fills the sky between and above the street's buildings, so gaps between them show more city, not sky.
    private static func makeSkyline(random: inout SplitMix64) -> [Silhouette] {
        var skyline: [Silhouette] = []
        var x = World.left
        while x < World.right {
            let width = CGFloat(60 + 90 * random.unit())
            let top = CGFloat(330 + 230 * random.unit())
            var lights: [CGRect] = []
            var y = top + 14
            while y < World.groundFloorTop {
                var column = x + 8
                while column < x + width - 12 {
                    if random.unit() < 0.12 {
                        lights.append(CGRect(x: column, y: y, width: 6, height: 8))
                    }
                    column += 16
                }
                y += 26
            }
            skyline.append(Silhouette(frame: CGRect(x: x, y: top, width: width, height: World.streetLine - top), lights: lights))
            x += width + CGFloat(6 * random.unit())
        }
        return skyline
    }

    private static func makeStars(random: inout SplitMix64) -> [Star] {
        var stars: [Star] = []
        for _ in 0..<210 {
            let x = World.left + CGFloat(random.unit()) * (World.right - World.left)
            // Denser high up: the glow of the city hides faint stars near the rooftops.
            let y = World.skyTop + CGFloat(pow(random.unit(), 1.25)) * (520 - World.skyTop)
            let brightness = 0.12 + pow(random.unit(), 3.2) * 2.4
            let fade = Double(min(max((520 - y) / 260, 0), 1))
            let roll = random.unit()
            let tone = roll < 0.2 ? Radiance(205, 220, 255) : (roll < 0.32 ? Radiance(255, 236, 205) : Radiance(255, 255, 255))
            stars.append(Star(center: CGPoint(x: x, y: y), radius: CGFloat(0.55 + 0.35 * min(brightness, 2)),
                              light: tone.scaled(brightness * fade)))
        }
        return stars
    }

    private static func makeCars(random: inout SplitMix64) -> [Car] {
        let bodies = [Radiance(40, 42, 48), Radiance(70, 20, 24), Radiance(30, 34, 40), Radiance(92, 94, 98),
                      Radiance(20, 22, 26), Radiance(46, 40, 30)]
        var cars: [Car] = []
        for offset in [0.0, 3.4, 7.9, 11.6, 15.3] {
            cars.append(Car(lane: .near, offset: offset, length: CGFloat(108 + 16 * random.unit()),
                            body: bodies[Int(random.next() % UInt64(bodies.count))]))
        }
        for offset in [1.7, 5.6, 9.8, 13.2, 17.1] {
            cars.append(Car(lane: .far, offset: offset, length: CGFloat(108 + 16 * random.unit()),
                            body: bodies[Int(random.next() % UInt64(bodies.count))]))
        }
        return cars
    }

    /// The 24 patches of a ColorChecker in a light box lit at the reference white balance, so the patches read
    /// true when the camera is balanced for it.
    private static func makeChart() -> [Patch] {
        let colors: [(Double, Double, Double)] = [
            (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
            (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
            (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
            (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
        ]
        let size: CGFloat = 20
        let gap: CGFloat = 3
        let originX = World.chartFrame.minX + (World.chartFrame.width - (6 * size + 5 * gap)) / 2
        let originY = World.chartFrame.minY + (World.chartFrame.height - (4 * size + 3 * gap)) / 2
        return colors.enumerated().map { index, color in
            let column = CGFloat(index % 6)
            let row = CGFloat(index / 6)
            return Patch(rect: CGRect(x: originX + column * (size + gap), y: originY + row * (size + gap), width: size, height: size),
                         light: Radiance(color.0, color.1, color.2, 0.85))
        }
    }
}

// MARK: - Drawing

/// Draws the world with Core Graphics. Colors are linear radiance, so values above 1 are lights brighter than white.
private struct ScenePainter {
    let context: CGContext
    let space: CGColorSpace
    /// The part of the world in frame.
    let view: CGRect
    let pixelsPerUnit: CGFloat
    let height: Int
    /// Moving lights draw as pieces of one trail, for a stack's back-to-back frames.
    var joinsTrails = false

    init(context: CGContext, space: CGColorSpace, framing: SceneFraming, width: Int, height: Int) {
        self.context = context
        self.space = space
        self.height = height
        let zoom = framing.zoom.isFinite && framing.zoom > 0 ? CGFloat(framing.zoom) : 1
        let viewWidth = World.referenceSize.width / zoom
        let viewHeight = viewWidth * CGFloat(height) / CGFloat(max(width, 1))
        view = CGRect(x: World.center.x - viewWidth / 2, y: World.center.y - viewHeight / 2, width: viewWidth, height: viewHeight)
        pixelsPerUnit = CGFloat(width) / viewWidth
    }

    /// From here on the context draws in world units with a top-left origin.
    func enterWorld() {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: pixelsPerUnit, y: pixelsPerUnit)
        context.translateBy(x: -view.minX, y: -view.minY)
    }

    /// Everything that stands still; drawn once per framing.
    func drawStill() {
        let layout = SceneLayout.shared
        drawSky()
        drawMoon()
        drawStars(layout.stars)
        drawSkyline(layout.skyline)
        for building in layout.buildings {
            drawBuilding(building)
        }
        // The street lamp lights the facades around it.
        glow(at: World.lampBulb, radius: 380, light: Radiance(92, 70, 48),
             falloff: [(0, 0.85), (0.25, 0.42), (0.6, 0.1), (1, 0)], additive: true)
        drawChart(layout.chart)
        drawNeon()
        drawStreet(layout.buildings)
        drawLamp()
    }

    /// Everything that moves or changes, for the frame ending at `time` with the shutter open for `shutter` seconds.
    func drawMovingParts(time: Double, shutter: Double, foregroundLight: Double) {
        let layout = SceneLayout.shared
        if let window = layout.televisionWindow {
            drawTelevision(in: window, time: time, shutter: shutter)
        }
        drawBlinker(time: time, shutter: shutter)
        for car in layout.cars {
            drawCar(car, time: time, shutter: shutter)
        }
        drawForegroundLight(foregroundLight)
    }

    // MARK: Primitives

    func isVisible(_ rect: CGRect) -> Bool {
        rect.intersects(view.insetBy(dx: -2, dy: -2))
    }

    func color(_ light: Radiance, alpha: Double = 1) -> CGColor {
        let components = [CGFloat(light.r), CGFloat(light.g), CGFloat(light.b), CGFloat(alpha)]
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0, alpha: CGFloat(alpha))
    }

    func fill(_ rect: CGRect, _ light: Radiance, alpha: Double = 1) {
        guard isVisible(rect) else { return }
        context.setFillColor(color(light, alpha: alpha))
        context.fill(rect)
    }

    func fillEllipse(_ rect: CGRect, _ light: Radiance, alpha: Double = 1) {
        guard isVisible(rect) else { return }
        context.setFillColor(color(light, alpha: alpha))
        context.fillEllipse(in: rect)
    }

    func fillRounded(_ rect: CGRect, radius: CGFloat, _ light: Radiance, alpha: Double = 1) {
        guard isVisible(rect), rect.width > 0, rect.height > 0 else { return }
        let corner = min(radius, rect.width / 2, rect.height / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setFillColor(color(light, alpha: alpha))
        context.fillPath()
    }

    func gradient(_ stops: [(location: CGFloat, light: Radiance, alpha: Double)]) -> CGGradient? {
        guard stops.count >= 2 else { return nil }
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        for stop in stops {
            components += [CGFloat(stop.light.r), CGFloat(stop.light.g), CGFloat(stop.light.b), CGFloat(stop.alpha)]
            locations.append(stop.location)
        }
        return CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: stops.count)
    }

    /// Light falling off around a point. Additive glows add their light (keep them below white); the others paint
    /// over what is there, which lets cores brighter than white stay bright.
    func glow(at center: CGPoint, radius: CGFloat, light: Radiance, falloff: [(CGFloat, Double)], additive: Bool,
              squash: CGFloat = 1) {
        let bounds = CGRect(x: center.x - radius, y: center.y - radius * squash, width: radius * 2, height: radius * 2 * squash)
        guard radius > 0, squash > 0, isVisible(bounds),
              let gradient = gradient(falloff.map { (location: $0.0, light: light, alpha: $0.1) }) else { return }
        context.saveGState()
        if additive {
            context.setBlendMode(.plusLighter)
        }
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1, y: squash)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        context.restoreGState()
    }

    func verticalGradient(in rect: CGRect, from top: CGFloat, to bottom: CGFloat,
                          _ stops: [(location: CGFloat, light: Radiance, alpha: Double)], additive: Bool = false) {
        guard isVisible(rect), let gradient = gradient(stops) else { return }
        context.saveGState()
        if additive {
            context.setBlendMode(.plusLighter)
        }
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: top), end: CGPoint(x: rect.minX, y: bottom),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    func line(from start: CGPoint, to end: CGPoint, width: CGFloat, _ light: Radiance, alpha: Double = 1) {
        context.setStrokeColor(color(light, alpha: alpha))
        context.setLineWidth(width)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    // MARK: Still parts

    private func drawSky() {
        let span = World.skyBottom - World.skyTop
        func at(_ y: CGFloat) -> CGFloat { (y - World.skyTop) / span }
        // Deep blue overhead, warming toward the city glow above the rooftops.
        verticalGradient(in: view, from: World.skyTop, to: World.skyBottom, [
            (at(-700), Radiance(3, 4, 12), 1),
            (at(-150), Radiance(6, 9, 22), 1),
            (at(150), Radiance(12, 15, 32), 1),
            (at(420), Radiance(30, 26, 38), 1),
            (at(600), Radiance(52, 38, 40), 1),
            (at(800), Radiance(60, 44, 42), 1),
        ])
    }

    private func drawMoon() {
        let center = World.moon
        let radius = World.moonRadius
        glow(at: center, radius: radius * 6, light: Radiance(110, 116, 150),
             falloff: [(0, 0.5), (0.18, 0.28), (0.45, 0.07), (1, 0)], additive: true)
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        guard isVisible(disc) else { return }
        let surface = Radiance(255, 249, 232, 7)
        context.saveGState()
        context.addEllipse(in: disc)
        context.clip()
        // Limb darkening: the edge of the disc is a little dimmer than the middle.
        if let shading = gradient([(0, surface, 1), (0.75, surface.scaled(0.92), 1), (1, surface.scaled(0.74), 1)]) {
            context.drawRadialGradient(shading, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        let maria: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-0.42, -0.5, 0.5, 0.42), (0.02, -0.38, 0.44, 0.36), (-0.2, 0.0, 0.56, 0.34),
            (0.28, 0.12, 0.34, 0.3), (-0.62, 0.05, 0.26, 0.4), (0.05, 0.42, 0.3, 0.2),
        ]
        for (x, y, w, h) in maria {
            fillEllipse(CGRect(x: center.x + x * radius, y: center.y + y * radius, width: w * radius, height: h * radius),
                        surface.scaled(0.6), alpha: 0.8)
        }
        let craters: [(CGFloat, CGFloat, CGFloat)] = [
            (0.12, 0.66, 0.08), (-0.5, 0.52, 0.06), (0.55, -0.3, 0.05), (-0.18, -0.72, 0.05),
        ]
        for (x, y, r) in craters {
            fillEllipse(CGRect(x: center.x + (x - r) * radius, y: center.y + (y - r) * radius,
                               width: 2 * r * radius, height: 2 * r * radius),
                        surface.scaled(1.08))
        }
        context.restoreGState()
    }

    private func drawStars(_ stars: [SceneLayout.Star]) {
        let unitsPerPixel = 1 / pixelsPerUnit
        for star in stars {
            let radius = star.radius * unitsPerPixel
            fillEllipse(CGRect(x: star.center.x - radius, y: star.center.y - radius, width: radius * 2, height: radius * 2), star.light)
        }
    }

    private func drawSkyline(_ skyline: [SceneLayout.Silhouette]) {
        // Haze lifts distant walls a little above the near ones.
        let face = Radiance(27, 24, 31)
        let light = Radiance(255, 200, 140, 0.4)
        for building in skyline where isVisible(building.frame) {
            fill(building.frame, face)
            for window in building.lights {
                fill(window, light)
            }
        }
    }

    private func drawBuilding(_ building: SceneLayout.Building) {
        let frame = building.frame
        // Roof details stick out above the facade.
        guard isVisible(frame.insetBy(dx: -40, dy: -110)) else { return }
        drawRoof(building)
        fill(frame, building.face)
        fill(CGRect(x: frame.minX - 3, y: frame.minY - 5, width: frame.width + 6, height: 7), building.trim)
        var ledge = frame.minY + 75
        while ledge < World.groundFloorTop {
            fill(CGRect(x: frame.minX, y: ledge - 4, width: frame.width, height: 3), building.trim.scaled(0.8))
            ledge += 75
        }
        // Light bouncing up from the street.
        verticalGradient(in: frame, from: World.streetLine, to: World.streetLine - 230,
                         [(0, Radiance(40, 30, 24), 1), (1, Radiance(40, 30, 24), 0)], additive: true)
        for window in building.windows where isVisible(window.rect) {
            if building.isOffice {
                drawOfficeWindow(window, frame: building.trim)
            } else {
                drawWindow(window, frame: building.trim)
            }
        }
        drawStorefront(building)
    }

    private func drawWindow(_ window: SceneLayout.Window, frame: Radiance) {
        let rect = window.rect
        if let light = window.light {
            fill(rect, light)
            if window.hasCurtain {
                fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.42, height: rect.height), light.scaled(0.5))
            }
        } else {
            fill(rect, Radiance(10, 11, 15))
            // Dark glass still reflects a little sky at the top.
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.35), Radiance(18, 20, 28))
        }
        if window.hasMullion {
            fill(CGRect(x: rect.midX - 1, y: rect.minY, width: 2, height: rect.height), frame)
            fill(CGRect(x: rect.minX, y: rect.minY + rect.height * 0.4 - 1, width: rect.width, height: 2), frame)
        }
        fill(CGRect(x: rect.minX - 2, y: rect.maxY, width: rect.width + 4, height: 3), frame.scaled(1.3))
    }

    private func drawOfficeWindow(_ window: SceneLayout.Window, frame: Radiance) {
        let rect = window.rect
        fill(rect, window.light ?? Radiance(12, 13, 18))
        var x = rect.minX + 22
        while x < rect.maxX - 4 {
            fill(CGRect(x: x - 1, y: rect.minY, width: 2, height: rect.height), frame)
            x += 22
        }
    }

    private func drawStorefront(_ building: SceneLayout.Building) {
        let frame = building.frame
        let glass = CGRect(x: frame.minX + 14, y: World.groundFloorTop + 8, width: frame.width - 28,
                           height: World.streetLine - World.groundFloorTop - 8)
        guard isVisible(glass) else { return }
        // Awning or sign band above the shop.
        fill(CGRect(x: frame.minX + 8, y: World.groundFloorTop - 2, width: frame.width - 16, height: 9), building.trim.scaled(0.9))
        switch building.storefront {
        case .shutter:
            fill(glass, Radiance(36, 35, 38))
            var y = glass.minY + 5
            while y < glass.maxY {
                fill(CGRect(x: glass.minX, y: y, width: glass.width, height: 1.5), Radiance(24, 23, 26))
                y += 6
            }
        case .dark:
            fill(glass, Radiance(11, 11, 14))
            fill(CGRect(x: glass.midX - 14, y: glass.minY + 10, width: 28, height: glass.height - 10), Radiance(7, 7, 9))
        case .neon:
            fill(glass, Radiance(92, 62, 52))
            fill(CGRect(x: glass.minX + glass.width * 0.62, y: glass.minY + 8, width: 26, height: glass.height - 8), Radiance(20, 16, 18))
        case .lit(let light):
            fill(glass, light)
            var x = glass.minX + glass.width / 3
            while x < glass.maxX - 2 {
                fill(CGRect(x: x - 1.5, y: glass.minY, width: 3, height: glass.height), Radiance(24, 22, 24))
                x += glass.width / 3
            }
            // Shelves and a counter in the window.
            fill(CGRect(x: glass.minX + 6, y: glass.maxY - 22, width: glass.width - 12, height: 22), light.scaled(0.35))
        case .sign(let light):
            fill(glass, Radiance(13, 12, 15))
            fillRounded(CGRect(x: glass.midX - 34, y: glass.minY + 6, width: 68, height: 14), radius: 3, light)
        }
    }

    private func drawRoof(_ building: SceneLayout.Building) {
        let frame = building.frame
        let dark = Radiance(15, 15, 18)
        switch building.roof {
        case .plain:
            break
        case .waterTower:
            let centerX = frame.midX - 6
            for leg in [-24, -8, 8, 24] as [CGFloat] {
                fill(CGRect(x: centerX + leg - 1.5, y: frame.minY - 34, width: 3, height: 34), dark)
            }
            fill(CGRect(x: centerX - 30, y: frame.minY - 86, width: 60, height: 52), dark)
            context.beginPath()
            context.move(to: CGPoint(x: centerX - 33, y: frame.minY - 86))
            context.addLine(to: CGPoint(x: centerX, y: frame.minY - 108))
            context.addLine(to: CGPoint(x: centerX + 33, y: frame.minY - 86))
            context.closePath()
            context.setFillColor(color(dark))
            context.fillPath()
            // Moonlight catches one edge of the tank.
            fill(CGRect(x: centerX - 30, y: frame.minY - 86, width: 3, height: 52), Radiance(34, 36, 46))
        case .antenna:
            let tip = World.antennaTip
            fill(CGRect(x: tip.x - 1.5, y: tip.y, width: 3, height: frame.minY - tip.y), dark)
            for (offset, span) in [(18, 22), (40, 34), (62, 26)] as [(CGFloat, CGFloat)] {
                fill(CGRect(x: tip.x - span / 2, y: tip.y + offset, width: span, height: 2), dark)
            }
            fill(CGRect(x: tip.x - 12, y: frame.minY - 10, width: 24, height: 10), dark)
        case .airConditioners:
            for x in [frame.minX + 22, frame.minX + 74, frame.maxX - 58] {
                fill(CGRect(x: x, y: frame.minY - 20, width: 36, height: 20), dark)
                fillEllipse(CGRect(x: x + 10, y: frame.minY - 17, width: 15, height: 14), Radiance(24, 24, 28))
            }
        }
    }

    private func drawChart(_ patches: [SceneLayout.Patch]) {
        let frame = World.chartFrame
        guard isVisible(frame.insetBy(dx: -130, dy: -130)) else { return }
        glow(at: CGPoint(x: frame.midX, y: frame.midY), radius: 130, light: Radiance(180, 180, 180),
             falloff: [(0, 0.14), (0.5, 0.05), (1, 0)], additive: true)
        fillRounded(frame, radius: 4, Radiance(14, 14, 16))
        for patch in patches {
            fill(patch.rect, patch.light)
        }
    }

    private func drawNeon() {
        let center = World.neonCenter
        guard isVisible(CGRect(x: center.x - 130, y: center.y - 130, width: 260, height: 260)) else { return }
        let pink = Radiance(255, 70, 170)
        glow(at: center, radius: 125, light: pink, falloff: [(0, 0.32), (0.35, 0.12), (1, 0)], additive: true)
        let tube = CGPath(roundedRect: CGRect(x: center.x - 65, y: center.y - 16, width: 130, height: 32),
                          cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // A wide faint stroke under the tube makes the gas glow.
        context.addPath(tube)
        context.setStrokeColor(color(pink.scaled(0.9), alpha: 0.22))
        context.setLineWidth(10)
        context.strokePath()
        context.addPath(tube)
        context.setStrokeColor(color(Radiance(255, 90, 185, 3)))
        context.setLineWidth(3.4)
        context.strokePath()
        line(from: CGPoint(x: center.x - 49, y: center.y), to: CGPoint(x: center.x + 49, y: center.y), width: 8,
             Radiance(80, 235, 255).scaled(0.9), alpha: 0.2)
        line(from: CGPoint(x: center.x - 49, y: center.y), to: CGPoint(x: center.x + 49, y: center.y), width: 3,
             Radiance(80, 235, 255, 2.4))
        context.restoreGState()
    }

    private func drawStreet(_ buildings: [SceneLayout.Building]) {
        let wide = CGRect(x: view.minX - 4, y: 0, width: view.width + 8, height: 0)
        fill(CGRect(x: wide.minX, y: World.streetLine, width: wide.width, height: World.curbTop - World.streetLine), Radiance(38, 36, 39))
        fill(CGRect(x: wide.minX, y: World.curbTop, width: wide.width, height: World.roadTop - World.curbTop), Radiance(62, 59, 58))
        let road = CGRect(x: wide.minX, y: World.roadTop, width: wide.width, height: World.roadBottom - World.roadTop)
        verticalGradient(in: road, from: road.minY, to: road.maxY,
                         [(0, Radiance(19, 19, 23), 1), (1, Radiance(27, 26, 29), 1)])
        var dash = (floor((view.minX - 70) / 110)) * 110
        while dash < view.maxX + 70 {
            fill(CGRect(x: dash, y: World.laneMarkY, width: 62, height: 5), Radiance(66, 64, 60))
            dash += 110
        }
        fill(CGRect(x: wide.minX, y: World.roadBottom, width: wide.width, height: World.nearSidewalkTop - World.roadBottom),
             Radiance(60, 58, 57))
        let sidewalk = CGRect(x: wide.minX, y: World.nearSidewalkTop, width: wide.width,
                              height: World.bottom - World.nearSidewalkTop)
        verticalGradient(in: sidewalk, from: sidewalk.minY, to: sidewalk.maxY,
                         [(0, Radiance(23, 22, 25), 1), (1, Radiance(30, 29, 31), 1)])
        if isVisible(sidewalk) {
            // Paving joints, spaced wider toward the camera.
            for y in [1110, 1212, 1332, 1474, 1642] as [CGFloat] {
                fill(CGRect(x: wide.minX, y: y, width: wide.width, height: 2), Radiance(15, 14, 17))
            }
            var x = (floor((view.minX - 160) / 160)) * 160
            while x < view.maxX + 160 {
                fill(CGRect(x: x, y: World.nearSidewalkTop, width: 2, height: sidewalk.height), Radiance(16, 15, 18))
                x += 160
            }
            for x in [120, 980] as [CGFloat] {
                fillRounded(CGRect(x: x - 8, y: 1068, width: 16, height: 84), radius: 5, Radiance(26, 26, 29))
                fill(CGRect(x: x - 8, y: 1074, width: 16, height: 4), Radiance(70, 66, 60))
            }
        }
        // Light spilling from lit shop windows onto the far sidewalk.
        for building in buildings {
            if case .lit(let light) = building.storefront {
                glow(at: CGPoint(x: building.frame.midX, y: World.streetLine + 8), radius: building.frame.width * 0.55,
                     light: light, falloff: [(0, 0.35), (1, 0)], additive: true, squash: 0.22)
            }
        }
        // The lamp's pool of light, and its reflection in the damp asphalt.
        glow(at: CGPoint(x: World.lampBulb.x, y: 822), radius: 320, light: Radiance(130, 100, 70),
             falloff: [(0, 0.9), (0.4, 0.4), (1, 0)], additive: true, squash: 0.28)
        glow(at: CGPoint(x: World.lampBulb.x, y: 905), radius: 24, light: Radiance(150, 110, 70),
             falloff: [(0, 0.8), (0.5, 0.3), (1, 0)], additive: true, squash: 4.2)
        glow(at: CGPoint(x: World.neonCenter.x, y: 884), radius: 20, light: Radiance(160, 44, 118),
             falloff: [(0, 0.4), (1, 0)], additive: true, squash: 3.4)
    }

    private func drawLamp() {
        let bulb = World.lampBulb
        guard isVisible(CGRect(x: bulb.x - 170, y: bulb.y - 170, width: 340, height: World.curbTop - bulb.y + 170)) else { return }
        let iron = Radiance(30, 30, 34)
        fill(CGRect(x: 600, y: bulb.y - 6, width: 7, height: World.curbTop - bulb.y), iron)
        // The side of the pole facing the lamp catches its light.
        fill(CGRect(x: 600, y: bulb.y + 4, width: 2, height: World.curbTop - bulb.y - 10), Radiance(66, 56, 46))
        fill(CGRect(x: 596, y: World.curbTop - 14, width: 15, height: 14), Radiance(28, 28, 31))
        fill(CGRect(x: bulb.x - 6, y: bulb.y - 7, width: 47, height: 4), iron)
        context.beginPath()
        context.move(to: CGPoint(x: bulb.x - 20, y: bulb.y - 10))
        context.addLine(to: CGPoint(x: bulb.x + 22, y: bulb.y - 10))
        context.addLine(to: CGPoint(x: bulb.x + 16, y: bulb.y))
        context.addLine(to: CGPoint(x: bulb.x - 14, y: bulb.y))
        context.closePath()
        context.setFillColor(color(Radiance(26, 26, 30)))
        context.fillPath()
        glow(at: bulb, radius: 160, light: Radiance(255, 210, 150), falloff: [(0, 0.55), (0.12, 0.3), (0.4, 0.08), (1, 0)], additive: true)
        glow(at: bulb, radius: 24, light: Radiance(255, 226, 184, 4), falloff: [(0, 0.9), (0.3, 0.4), (1, 0)], additive: false)
        fillEllipse(CGRect(x: bulb.x - 12, y: bulb.y - 2, width: 24, height: 7), Radiance(255, 242, 220, 26))
    }

    // MARK: Moving parts

    private func drawTelevision(in rect: CGRect, time: Double, shutter: Double) {
        guard isVisible(rect) else { return }
        // A screen's flicker averaged over the exposure: long exposures see a steady glow.
        let samples = shutter > 0.2 ? 7 : 1
        var level = 0.0
        for index in 0..<samples {
            let t = time - shutter * (Double(index) + 0.5) / Double(samples)
            level += 0.32 + 0.18 * sin(t * 7.3) * sin(t * 2.9 + 1.3) + 0.1 * sin(t * 23)
        }
        fill(rect, Radiance(170, 195, 255, max(level / Double(samples), 0.04)))
    }

    private func drawBlinker(time: Double, shutter: Double) {
        let tip = World.antennaTip
        guard isVisible(CGRect(x: tip.x - 20, y: tip.y - 20, width: 40, height: 40)) else { return }
        let share = Self.onShare(from: time - shutter, to: time, period: World.blinkPeriod, onDuration: World.blinkOn)
        guard share > 0 else { return }
        glow(at: tip, radius: 18, light: Radiance(255, 50, 40, 1.4), falloff: [(0, 0.6 * share), (1, 0)], additive: false)
        fillEllipse(CGRect(x: tip.x - 2.4, y: tip.y - 2.4, width: 4.8, height: 4.8), Radiance(255, 60, 48, 5 * share))
    }

    /// Fraction of [start, end] during which a light blinking on for `onDuration` every `period` is lit.
    private static func onShare(from start: Double, to end: Double, period: Double, onDuration: Double) -> Double {
        let length = end - start
        guard length.isFinite, start.isFinite else { return 0 }
        if length < 1e-6 {
            return end - floor(end / period) * period < onDuration ? 1 : 0
        }
        var lit = 0.0
        var cycle = floor(start / period)
        while cycle * period <= end {
            let on = cycle * period
            lit += max(0, min(end, on + onDuration) - max(start, on))
            cycle += 1
        }
        return min(lit / length, 1)
    }

    private func drawCar(_ car: SceneLayout.Car, time: Double, shutter: Double) {
        let near = car.lane == .near
        let speed = near ? World.nearSpeed : World.farSpeed
        let direction: CGFloat = near ? 1 : -1
        let laneY = near ? World.nearLaneY : World.farLaneY
        let entryX = near ? World.laneWest : World.laneEast
        let crossing = Double(World.laneEast - World.laneWest) / speed
        let start = time - shutter
        // The car is on the road during [entry, entry + crossing] once every period; at most two passes touch one exposure.
        let pass = floor((time - car.offset) / World.trafficPeriod)
        for index in [pass - 1, pass] {
            let entry = car.offset + index * World.trafficPeriod
            let from = max(start, entry)
            let to = min(time, entry + crossing)
            guard to >= from else { continue }
            let frontA = entryX + direction * CGFloat((from - entry) * speed)
            let frontB = entryX + direction * CGFloat((to - entry) * speed)
            drawCarPass(car, frontFrom: frontA, frontTo: frontB, direction: direction, laneY: laneY,
                        travelDuringShutter: CGFloat(speed * shutter), presence: (to - from) / shutter)
        }
    }

    /// One car smeared from where its front was when the shutter opened (or it arrived) to where it ended up.
    private func drawCarPass(_ car: SceneLayout.Car, frontFrom: CGFloat, frontTo: CGFloat, direction: CGFloat, laneY: CGFloat,
                             travelDuringShutter: CGFloat, presence: Double) {
        let length = car.length
        let lowX = min(frontFrom, frontTo) - (direction > 0 ? length : 0)
        let highX = max(frontFrom, frontTo) + (direction > 0 ? 0 : length)
        guard isVisible(CGRect(x: lowX - 120, y: laneY - 70, width: highX - lowX + 240, height: 100)) else { return }
        let travel = abs(frontTo - frontFrom)
        // A moving body covers each spot for only part of the exposure, so it shows through faintly when smeared.
        let opacity = min(max(Double(length / (length + travelDuringShutter)) * min(presence, 1), 0.02), 1)
        fillRounded(CGRect(x: lowX, y: laneY - 30, width: highX - lowX, height: 26), radius: 9, car.body, alpha: opacity)
        let cabinInset = length * 0.22
        if highX - lowX > cabinInset * 2 + 4 {
            fillRounded(CGRect(x: lowX + cabinInset, y: laneY - 46, width: highX - lowX - cabinInset * 2, height: 18),
                        radius: 7, car.body.scaled(0.8), alpha: opacity)
        }
        if travel < 3 {
            let wheels = direction > 0 ? [frontTo - length * 0.2, frontTo - length * 0.8] : [frontTo + length * 0.2, frontTo + length * 0.8]
            for x in wheels {
                fillEllipse(CGRect(x: x - 9, y: laneY - 13, width: 18, height: 18), Radiance(8, 8, 10))
            }
        }
        // A light moving d per exposure lights each pixel on its path for (size / d) of the time.
        let headSize: CGFloat = 7.2
        let tailSize: CGFloat = 6
        let headStrength = Double(headSize / (headSize + travelDuringShutter))
        let tailStrength = Double(tailSize / (tailSize + travelDuringShutter))
        let rearFrom = frontFrom - direction * length
        let rearTo = frontTo - direction * length
        let inset = direction * 4
        // Headlights sit lower than the tail lights, so a long exposure draws a white and a red trail per lane.
        // Lamps this much brighter than the street are what keeps trails bright after seconds of exposure.
        // Both halos go down before either core: a car that moves farther than its length in one exposure takes its
        // tail light along the headlight's path, and that halo laid over the white trail would dim it.
        for part in [StreakPart.halo, .core] {
            streak(from: CGPoint(x: frontFrom - inset, y: laneY - 13), to: CGPoint(x: frontTo - inset, y: laneY - 13),
                   size: headSize, light: Radiance(255, 246, 230, 40).scaled(headStrength), part: part)
            streak(from: CGPoint(x: rearFrom + inset, y: laneY - 21), to: CGPoint(x: rearTo + inset, y: laneY - 21),
                   size: tailSize, light: Radiance(255, 30, 24, 12).scaled(tailStrength), part: part)
        }
        glow(at: CGPoint(x: frontTo + direction * 78, y: laneY + 2), radius: 86, light: Radiance(255, 240, 220),
             falloff: [(0, 0.24 * headStrength * min(presence, 1)), (1, 0)], additive: true, squash: 0.12)
    }

    /// The soft halo and the bright core of a light, drawn in separate passes so no halo covers another light's core.
    private enum StreakPart {
        case halo, core
    }

    /// One part of a point light dragged from `start` to `end`: a bright core with a soft halo around it.
    private func streak(from start: CGPoint, to end: CGPoint, size: CGFloat, light: Radiance, part: StreakPart) {
        let bounds = CGRect(x: min(start.x, end.x) - size * 4, y: min(start.y, end.y) - size * 4,
                            width: abs(end.x - start.x) + size * 8, height: abs(end.y - start.y) + size * 8)
        guard isVisible(bounds) else { return }
        let still = hypot(end.x - start.x, end.y - start.y) < size * 0.25
        // Only a level trail can end on pixel boundaries; cars drive straight across, so theirs always are.
        if joinsTrails, !still, start.y == end.y {
            trailPiece(from: start.x, to: end.x, y: end.y, size: size, light: light, part: part)
            return
        }
        switch part {
        case .halo:
            // The halo is a gradient, not a wide stroke: hard-edged halos read as gray pills around the lights.
            glow(at: end, radius: size * 3, light: light.scaled(0.3), falloff: [(0, 0.55), (0.35, 0.18), (1, 0)], additive: false)
            guard !still else { return }
            context.saveGState()
            context.setLineCap(.round)
            line(from: start, to: end, width: size * 2.2, light.scaled(0.22), alpha: 0.35)
            context.restoreGState()
        case .core:
            if still {
                fillEllipse(CGRect(x: end.x - size / 2, y: end.y - size / 2, width: size, height: size), light)
                return
            }
            context.saveGState()
            context.setLineCap(.round)
            line(from: start, to: end, width: size, light)
            context.restoreGState()
        }
    }

    /// What one of a stack's back-to-back frames adds to a light trail. A streak's halo at its end and its round
    /// ends would leave a bead wherever two frames meet; here the halo runs along the piece and the ends are
    /// square, so the pieces join into an even trail whether the stack adds, averages or lightens them.
    private func trailPiece(from startX: CGFloat, to endX: CGFloat, y: CGFloat, size: CGFloat, light: Radiance,
                            part: StreakPart) {
        let left = nearestPixelEdge(min(startX, endX))
        let right = nearestPixelEdge(max(startX, endX))
        guard right > left else { return }
        switch part {
        case .halo:
            let halo = light.scaled(0.3)
            let band = CGRect(x: left, y: y - size * 3, width: right - left, height: size * 6)
            // The streak's halo falloff, mirrored across the trail.
            verticalGradient(in: band, from: band.minY, to: band.maxY,
                             [(0, halo, 0), (0.325, halo, 0.18), (0.5, halo, 0.55), (0.675, halo, 0.18), (1, halo, 0)])
            fill(CGRect(x: left, y: y - size * 1.1, width: right - left, height: size * 2.2), light.scaled(0.22), alpha: 0.35)
        case .core:
            fill(CGRect(x: left, y: y - size / 2, width: right - left, height: size), light)
        }
    }

    /// An end between pixels leaves each pixel to exactly one frame. Antialiasing would split the pixel where two
    /// pieces meet between both frames, and a lightened stack keeps only the brighter part: a dark seam.
    private func nearestPixelEdge(_ x: CGFloat) -> CGFloat {
        ((x - view.minX) * pixelsPerUnit).rounded() / pixelsPerUnit + view.minX
    }

    /// Flash or torch: strong on the pavement near the camera, almost nothing on the far side of the street.
    private func drawForegroundLight(_ strength: Double) {
        guard strength.isFinite, strength > 0.001 else { return }
        let rect = CGRect(x: view.minX, y: World.streetLine + 20, width: view.width, height: World.bottom - World.streetLine - 20)
        let white = Radiance(255, 252, 245)
        verticalGradient(in: rect, from: rect.minY, to: rect.maxY, [
            (0, white, 0),
            (0.3, white, 0.08 * min(strength, 1)),
            (1, white, 0.34 * min(strength, 1)),
        ], additive: true)
    }
}
