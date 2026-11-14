import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import os
import CameraCore

/// What the editor draws and writes. One Core Image chain makes the preview while a dial turns, the full-size photo
/// saved to Photos and every frame of a Live Photo, so the preview shows what gets saved. The file it writes keeps
/// the photo's metadata, the app's own XMP fields included.
enum EditRenderer {
    /// An HDR photo keeps its brighter highlights through an edit only with this on. It stays off until an edited HDR
    /// photo has been checked on an HDR iPhone: its highlights still glow in Photos, its colors match the standard
    /// range picture, and the photo info tool still finds the camera's metadata. Until then an edit saves the standard
    /// range picture, which every screen shows the same way.
    static let keepsHDR = false

    /// The preview's long side in pixels: sharp on a phone screen, and quick enough to redraw at every dial step.
    static let previewLongSide = 1600

    /// The side of the square look previews, in pixels.
    static let lookPreviewSide = 160

    /// The photo the preview draws from, decoded once per editor.
    struct Preview: Sendable {
        /// The photo upright, at most `previewLongSide` on its long side.
        let image: CGImage
        /// The full-size photo's upright size in pixels.
        let photoSize: CGSize
        /// `image` relative to the full-size photo, at most 1.
        let renderScale: CGFloat
    }

    /// A finished edit as file data.
    struct Encoded: Sendable {
        let data: Data
        let type: UTType
    }

    enum Failure: Error {
        case unreadable
        case notRendered
        case notEncoded
    }

    // MARK: - The chain

    /// `recipe` drawn on `image`, an upright photo. `renderScale` is its size relative to the full-size photo, 1 for
    /// the saved file, so sharpening reaches as far at every size. The order is EditParameters': the turns and the
    /// mirror, straighten, the crop, then exposure, highlights and shadows, the tone curve, contrast, brightness and
    /// saturation, vibrance, warmth and tint, the look, sharpening, and the vignette last, so it centres on the
    /// final frame.
    static func apply(_ recipe: EditRecipe, to image: CIImage, renderScale: CGFloat) -> CIImage {
        let p = recipe.parameters
        var output = image
        if p.usesOrientation, let orientation = CGImagePropertyOrientation(rawValue: UInt32(p.orientation)) {
            output = atOrigin(output.oriented(orientation))
        }
        if p.usesStraighten {
            let filter = CIFilter.straighten()
            filter.inputImage = output
            filter.angle = Float(p.straightenAngle)
            // The filter scales the turned picture up until it fills its frame again; what lands outside goes.
            output = (filter.outputImage ?? output).cropped(to: output.extent)
        }
        if let crop = recipe.crop {
            output = atOrigin(output.cropped(to: pixelRect(crop, in: output.extent)))
        }
        let frame = output.extent
        guard !frame.isEmpty, !frame.isInfinite else { return image }

        if p.usesExposure {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(p.ev)
            output = filter.outputImage ?? output
        }
        if p.usesHighlightShadow {
            let filter = CIFilter.highlightShadowAdjust()
            // The edge pixels repeat outward, so nothing dark seeps in at the border.
            filter.inputImage = output.clampedToExtent()
            filter.highlightAmount = Float(p.highlightAmount)
            filter.shadowAmount = Float(p.shadowAmount)
            filter.radius = Float(EditParameters.highlightShadowRadius)
            output = (filter.outputImage ?? output).cropped(to: frame)
        }
        if p.usesToneCurve, p.toneCurve.count == 5 {
            output = toneCurve(p.toneCurve, on: output)
        }
        if p.usesColorControls {
            output = colorControls(p, on: output)
        }
        if p.usesVibrance {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(p.vibrance)
            output = filter.outputImage ?? output
        }
        if p.usesTemperatureAndTint {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            let own = CIVector(x: CGFloat(EditParameters.neutral.temperature), y: CGFloat(EditParameters.neutral.tint))
            let target = CIVector(x: CGFloat(p.targetNeutral.temperature), y: CGFloat(p.targetNeutral.tint))
            filter.neutral = whitePointsSwapped ? target : own
            filter.targetNeutral = whitePointsSwapped ? own : target
            output = filter.outputImage ?? output
        }
        if let name = p.lookFilterName, let filter = CIFilter(name: name) {
            filter.setValue(output, forKey: kCIInputImageKey)
            output = filter.outputImage ?? output
        }
        if p.usesSharpen {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output.clampedToExtent()
            filter.sharpness = Float(p.sharpness)
            filter.radius = Float(EditParameters.sharpenRadius * Double(validScale(renderScale)))
            output = (filter.outputImage ?? output).cropped(to: frame)
        }
        if p.usesVignette {
            let filter = CIFilter.vignette()
            filter.inputImage = output.cropped(to: frame)
            filter.intensity = Float(p.vignetteIntensity)
            filter.radius = Float(EditParameters.vignetteRadius)
            output = filter.outputImage ?? output
        }
        return output.cropped(to: frame)
    }

    /// The stored picture turned and mirrored as its EXIF orientation says, its extent at the origin.
    static func upright(_ image: CIImage, _ orientation: CGImagePropertyOrientation) -> CIImage {
        atOrigin(orientation == .up ? image : image.oriented(orientation))
    }

    // MARK: - Preview

    /// Decodes the photo at `url` for the preview: upright, at most `previewLongSide` on its long side. nil when
    /// ImageIO can't read it.
    static func loadPreview(url: URL, orientation: CGImagePropertyOrientation, context: CIContext) -> Preview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        // A thumbnail decode reads a 48 MP photo at the size asked for, in a fraction of a full decode. It keeps the
        // stored orientation: the input's own orientation turns it below, as it turns the full-size photo.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: previewLongSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let stored = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              let image = render(upright(CIImage(cgImage: stored), orientation), context: context) else { return nil }
        let storedWidth = number(properties[kCGImagePropertyPixelWidth]) ?? Double(stored.width)
        let storedHeight = number(properties[kCGImagePropertyPixelHeight]) ?? Double(stored.height)
        let photo = swapsAxes(orientation)
            ? CGSize(width: storedHeight, height: storedWidth)
            : CGSize(width: storedWidth, height: storedHeight)
        let photoLong = max(photo.width, photo.height)
        let previewLong = CGFloat(max(image.width, image.height))
        let scale = photoLong > 0 ? min(1, previewLong / photoLong) : 1
        return Preview(image: image, photoSize: photo, renderScale: scale)
    }

    /// `recipe` on the preview picture.
    static func renderPreview(_ recipe: EditRecipe, from preview: Preview, context: CIContext) -> CGImage? {
        render(apply(recipe, to: CIImage(cgImage: preview.image), renderScale: preview.renderScale), context: context)
    }

    /// Each look on a small square from the middle of the photo, for the look buttons.
    static func lookPreviews(of preview: Preview, context: CIContext) -> [EditRecipe.Look: CGImage] {
        let image = CIImage(cgImage: preview.image)
        let extent = image.extent
        let side = min(extent.width, extent.height)
        guard side >= 1 else { return [:] }
        let square = CGRect(x: ((extent.width - side) / 2).rounded(.down), y: ((extent.height - side) / 2).rounded(.down),
                            width: side, height: side)
        let scale = filterScale(CGFloat(lookPreviewSide) / side)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = atOrigin(image.cropped(to: square))
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let scaled = filter.outputImage else { return [:] }
        // Lanczos leaves a fractional edge, which would draw as a faint line.
        let whole = max(1, (side * scale).rounded(.down))
        let small = scaled.cropped(to: CGRect(x: 0, y: 0, width: whole, height: whole))
        var result: [EditRecipe.Look: CGImage] = [:]
        for look in EditRecipe.Look.allCases {
            let picture = look == .none ? small : apply(EditRecipe(look: look), to: small, renderScale: scale)
            if let rendered = render(picture, context: context) {
                result[look] = rendered
            }
        }
        return result
    }

    // MARK: - The saved file

    /// `recipe` on the full-size photo at `url`, as file data in the first of `types` ImageIO can write, with the
    /// photo's metadata. nil `types` means the photo's own format when it is HEIF or JPEG, then HEIF, then JPEG.
    /// `keepsLivePairing` false leaves out Apple's maker note, which pairs a Live Photo's still with its video: a
    /// still saved on its own must not claim a video it doesn't have.
    static func encodedEdit(_ recipe: EditRecipe, url: URL, orientation: CGImagePropertyOrientation, types: [UTType]?,
                            keepsLivePairing: Bool, context: CIContext) throws -> Encoded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let candidates = types ?? ownTypes(source)

        if keepsHDR, candidates.contains(.heic), hasGainMap(source, index: index),
           let data = hdrEdit(recipe, url: url, orientation: orientation, properties: properties,
                              keepsLivePairing: keepsLivePairing, context: context) {
            return Encoded(data: carryingXMP(from: source, index: index, into: data), type: .heic)
        }

        // The decode, the filters' buffers and the 8-bit picture of a 48 MP photo add up to several hundred MB; the
        // pool hands the temporary ones back before the encoder takes its own.
        let picture: CGImage? = autoreleasepool {
            guard let photo = CIImage(contentsOf: url) else { return nil }
            return render(apply(recipe, to: upright(photo, orientation), renderScale: 1), context: context)
        }
        guard let picture else { throw Failure.notRendered }
        let written = fileProperties(properties, width: picture.width, height: picture.height,
                                     keepsLivePairing: keepsLivePairing)
        let pixels = opaque(picture)
        for type in candidates {
            // Some Simulator hosts and older phones have no HEVC encoder; the next type still saves the edit.
            guard let data = autoreleasepool(invoking: { write(pixels, as: type, properties: written) }) else { continue }
            return Encoded(data: carryingXMP(from: source, index: index, into: data), type: type)
        }
        throw Failure.notEncoded
    }

    /// The edit's HDR version: the photo decoded with its gain map applied, edited, and written as HEIF with a
    /// standard range picture plus an ISO gain map that brings the highlights back on HDR screens. nil when a step
    /// fails, and the edit is saved in standard range instead. Used only while `keepsHDR` is on.
    private static func hdrEdit(_ recipe: EditRecipe, url: URL, orientation: CGImagePropertyOrientation,
                                properties: [CFString: Any], keepsLivePairing: Bool, context: CIContext) -> Data? {
        autoreleasepool {
            guard let photo = CIImage(contentsOf: url, options: [.expandToHDR: true]),
                  let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
            let edited = apply(recipe, to: upright(photo, orientation), renderScale: 1)
            let extent = edited.extent
            guard !extent.isEmpty, !extent.isInfinite,
                  let picture = context.createCGImage(edited, from: extent, format: .RGBAh, colorSpace: space) else {
                return nil
            }
            var options = fileProperties(properties, width: picture.width, height: picture.height,
                                         keepsLivePairing: keepsLivePairing)
            // The encoder works out the standard range picture and the gain map from the HDR one.
            options[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
            return write(opaque(picture), as: .heic, properties: options)
        }
    }

    /// The photo's own properties for the edited picture: upright, at its new size, without the subject area, which
    /// pointed into the frame before the crop and the turns.
    private static func fileProperties(_ source: [CFString: Any], width: Int, height: Int,
                                       keepsLivePairing: Bool) -> [CFString: Any] {
        var output = source
        output[kCGImagePropertyOrientation] = 1
        output[kCGImagePropertyPixelWidth] = width
        output[kCGImagePropertyPixelHeight] = height
        var tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        output[kCGImagePropertyTIFFDictionary] = tiff
        var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = width
        exif[kCGImagePropertyExifPixelYDimension] = height
        exif.removeValue(forKey: kCGImagePropertyExifSubjectArea)
        exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation)
        output[kCGImagePropertyExifDictionary] = exif
        if !keepsLivePairing {
            output.removeValue(forKey: kCGImagePropertyMakerAppleDictionary)
        }
        output[kCGImageDestinationLossyCompressionQuality] = quality
        // The camera's embedded preview showed the unedited picture; this writes one of the edit.
        output[kCGImageDestinationEmbedThumbnail] = true
        return output
    }

    /// The photo's own format when it is HEIF or JPEG, then HEIF, then JPEG.
    private static func ownTypes(_ source: CGImageSource) -> [UTType] {
        let own = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        var types: [UTType] = []
        if let own, own.conforms(to: .jpeg) {
            types.append(.jpeg)
        }
        for type in [UTType.heic, .jpeg] where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    // MARK: - Metadata

    /// XMP namespaces an edited file keeps: the app's own fields (a stack's real duration), the name and copyright,
    /// the tool that made the photo, rating and IPTC captions. EXIF and TIFF travel in the properties already, and
    /// the rest describes the unedited picture, such as its gain map or face regions in the old frame.
    private static let carriedNamespaces: Set<String> = [
        ShotXMP.namespace,
        kCGImageMetadataNamespaceDublinCore as String,
        kCGImageMetadataNamespaceXMPBasic as String,
        kCGImageMetadataNamespaceXMPRights as String,
        kCGImageMetadataNamespaceIPTCCore as String,
        kCGImageMetadataNamespaceIPTCExtension as String,
    ]

    /// `data` with the photo's XMP from `carriedNamespaces` merged in, copied rather than encoded again. Writing
    /// properties alone carries EXIF, TIFF, GPS and IPTC but no XMP. When the copy would lose anything, `data` comes
    /// back as it was: the camera's facts are in EXIF either way.
    private static func carryingXMP(from source: CGImageSource, index: Int, into data: Data) -> Data {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return data }
        let carried = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(carried, ShotXMP.namespace as CFString,
                                                        ShotXMP.prefix as CFString, &error) else {
            log.error("XMP namespace refused: \(describe(error), privacy: .public)")
            return data
        }
        var firstPath: String?
        for tag in tags {
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                  carriedNamespaces.contains(namespace),
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            let path = prefix + ":" + name
            if CGImageMetadataSetTagWithPath(carried, nil, path as CFString, tag), firstPath == nil {
                firstPath = path
            }
        }
        guard let firstPath,
              let edited = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(edited) else { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type,
                                                                 CGImageSourceGetCount(edited), nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: carried,
            kCGImageDestinationMergeMetadata: true,
        ]
        // The copy is written as this returns; finalizing the destination afterwards is not allowed.
        guard CGImageDestinationCopyImageSource(destination, edited, options as CFDictionary, &error) else {
            log.error("XMP carry-over failed: \(describe(error), privacy: .public)")
            return data
        }
        let copy = output as Data
        if let lost = loss(from: edited, to: copy, expecting: firstPath) {
            log.error("XMP carry-over dropped \(lost, privacy: .public); the edit is saved without it")
            return data
        }
        return copy
    }

    /// What the copy lost compared with the edited file, or nil when it kept everything and gained the XMP. Reading
    /// properties decodes no pixels, so this takes milliseconds.
    private static func loss(from edited: CGImageSource, to copy: Data, expecting path: String) -> String? {
        guard let copied = CGImageSourceCreateWithData(copy as CFData, nil) else { return "the file" }
        guard CGImageSourceGetCount(copied) == CGImageSourceGetCount(edited) else { return "images" }
        let index = CGImageSourceGetPrimaryImageIndex(edited)
        let before = CGImageSourceCopyPropertiesAtIndex(edited, index, nil) as? [CFString: Any] ?? [:]
        let after = CGImageSourceCopyPropertiesAtIndex(copied, index, nil) as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation]
        where (before[key] as? NSNumber) != (after[key] as? NSNumber) {
            return key as String
        }
        let groups = [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
                      kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary]
        for group in groups where before[group] != nil && after[group] == nil {
            return group as String
        }
        if hasGainMap(edited, index: index), !hasGainMap(copied, index: index) {
            return "the gain map"
        }
        guard let written = CGImageSourceCopyMetadataAtIndex(copied, index, nil),
              CGImageMetadataCopyTagWithPath(written, nil, path as CFString) != nil else { return "the XMP" }
        return nil
    }

    // MARK: - Helpers

    /// The quality Photos' own edits are saved at: the edit is a render, and the original stays in the library.
    private static let quality = 0.92

    /// Whether CITemperatureAndTint reads its two white points the other way round from EditParameters' reading of
    /// the header. A Simulator check settles it: warmth +1 must turn a gray patch yellow (red above blue) and tint +1
    /// magenta (green lowest). If both come out reversed, this turns true.
    private static let whitePointsSwapped = false

    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)

    private static let log = Logger(subsystem: "ca.katsuma.openshutter", category: "Editor")

    /// CIToneCurve already applies its points to values as the eye sees them (its header: "a perceptual (gamma 2)
    /// version of the working space"), so it takes linear light as it is. Its `extrapolate` switch is iOS 26 only and
    /// stays off, so an edit renders alike on every iOS; a value exposure pushed past white clips at the curve.
    private static func toneCurve(_ points: [EditParameters.CurvePoint], on image: CIImage) -> CIImage {
        let point = points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = point[0]
        curve.point1 = point[1]
        curve.point2 = point[2]
        curve.point3 = point[3]
        curve.point4 = point[4]
        return curve.outputImage ?? image
    }

    /// CIColorControls pivots contrast at 0.5 and adds brightness as a bias, both meant for values as the eye sees
    /// them, so it runs between the sRGB tone curve and its inverse. In Core Image's linear light, contrast would
    /// pivot too dark and darken the whole picture.
    private static func colorControls(_ p: EditParameters, on image: CIImage) -> CIImage {
        let toPerceptual = CIFilter.linearToSRGBToneCurve()
        toPerceptual.inputImage = image
        guard let perceptual = toPerceptual.outputImage else { return image }
        let controls = CIFilter.colorControls()
        controls.inputImage = perceptual
        controls.contrast = Float(p.contrast)
        controls.brightness = Float(p.brightness)
        controls.saturation = Float(p.saturation)
        guard let adjusted = controls.outputImage else { return image }
        let toLinear = CIFilter.sRGBToneCurveToLinear()
        toLinear.inputImage = adjusted
        return toLinear.outputImage ?? image
    }

    /// An 8-bit Display P3 picture of `image`: the range and the colors a phone photo holds.
    static func render(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, let displayP3 else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: displayP3)
    }

    /// `image` moved so its extent starts at the origin, where the crop and the vignette measure from.
    private static func atOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin.x.isFinite, origin.y.isFinite, origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// A crop in 0...1 with a top-left origin, as whole pixels of `extent`, whose y runs up.
    private static func pixelRect(_ crop: CropRect, in extent: CGRect) -> CGRect {
        let left = (extent.minX + CGFloat(crop.x) * extent.width).rounded()
        let right = (extent.minX + CGFloat(crop.maxX) * extent.width).rounded()
        let top = (extent.maxY - CGFloat(crop.y) * extent.height).rounded()
        let bottom = (extent.maxY - CGFloat(crop.maxY) * extent.height).rounded()
        let rect = CGRect(x: left, y: bottom, width: max(right - left, 1), height: max(top - bottom, 1))
        let inside = rect.intersection(extent)
        return inside.isEmpty ? extent : inside
    }

    private static func swapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }

    private static func validScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }

    /// A downscale factor Lanczos can use: shrinking only, never to nothing.
    private static func filterScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(scale, 1)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func hasGainMap(_ source: CGImageSource, index: Int) -> Bool {
        [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap].contains { type in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) != nil
        }
    }

    /// One picture written as `type`, or nil when ImageIO refuses.
    private static func write(_ image: CGImage, as type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    /// Core Image renders with an alpha channel, which a photo file only carries as extra size and which some viewers
    /// draw wrongly. The renders are opaque, so the same bytes are read with the alpha skipped, without a copy.
    private static func opaque(_ image: CGImage) -> CGImage {
        let skip: CGImageAlphaInfo
        switch image.alphaInfo {
        case .premultipliedLast, .last: skip = .noneSkipLast
        case .premultipliedFirst, .first: skip = .noneSkipFirst
        default: return image
        }
        guard !image.isMask, image.bitsPerPixel == 4 * image.bitsPerComponent,
              let space = image.colorSpace, space.model == .rgb,
              let provider = image.dataProvider else { return image }
        // Byte order and float components stay as rendered; only the alpha changes.
        let others = image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue
        let info = CGBitmapInfo(rawValue: others | skip.rawValue)
        return CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                       bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space,
                       bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) ?? image
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "no reason given" }
        return (error.takeRetainedValue() as Error).localizedDescription
    }
}
