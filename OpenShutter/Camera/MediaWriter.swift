import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import CameraCore

struct EncodedImage: @unchecked Sendable {
    var data: Data
    /// UTType identifier: "public.heic", "public.jpeg".
    var typeIdentifier: String
    var pixelSize: PixelSize
    var thumbnail: CGImage?
}

/// EXIF facts for images the app builds itself (stacks, simulator shots).
struct CaptureMetadata: Sendable {
    var exposureSeconds: Double
    var iso: Double
    var aperture: Double
    var focalLength35mm: Double?
    var lensModel: String
    /// Goes into EXIF UserComment, e.g. "Stacked 30 × 1s, Real".
    var comment: String?
    var date: Date
    var location: LocationStamp?
}

enum MediaWriter {
    /// Encodes an upright CGImage as HEIF or JPEG (`.none` is treated as HEIF) with EXIF, TIFF and GPS
    /// dictionaries from `metadata`. HEIF falls back to JPEG if the encoder is unavailable.
    static func encode(_ image: CGImage, as format: ProcessedFormat, quality: Double, metadata: CaptureMetadata) throws -> EncodedImage {
        guard image.width > 0, image.height > 0 else {
            throw CameraError.captureFailed("The image is empty.")
        }
        var options = properties(for: metadata)
        options[kCGImageDestinationLossyCompressionQuality] = compressionQuality(quality)
        // Camera originals carry a small preview that file browsers and share sheets show without a full decode.
        options[kCGImageDestinationEmbedThumbnail] = true
        let pixels = opaque(image)
        let types: [UTType] = format == .jpeg ? [.jpeg] : [.heic, .jpeg]
        for type in types {
            // Some Simulator hosts and older devices have no HEVC encoder; the destination or the
            // finalize step fails there, and JPEG still gets the shot saved.
            guard let data = write(pixels, as: type, properties: options, auxiliary: []) else { continue }
            return EncodedImage(
                data: data,
                typeIdentifier: type.identifier,
                pixelSize: PixelSize(width: image.width, height: image.height),
                thumbnail: thumbnail(of: image, maxPixelSize: thumbnailPixelSize)
            )
        }
        throw CameraError.captureFailed("The image couldn't be encoded.")
    }

    /// Crops encoded photo data (HEIF or JPEG from AVCapturePhoto) to `aspect` in the photo's displayed
    /// orientation, keeps its metadata, and re-encodes in the same format. Returns the data untouched
    /// when `aspect` is 4:3.
    static func crop(_ data: Data, to aspect: AspectRatio, quality: Double) throws -> EncodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw CameraError.captureFailed("The photo data couldn't be read.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let sourceType = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = imageOrientation(in: properties)
        let storedWidth = intValue(properties[kCGImagePropertyPixelWidth]) ?? 0
        let storedHeight = intValue(properties[kCGImagePropertyPixelHeight]) ?? 0

        func untouched() -> EncodedImage {
            EncodedImage(
                data: data,
                typeIdentifier: sourceType,
                pixelSize: displayedSize(width: storedWidth, height: storedHeight, orientation: orientation),
                thumbnail: thumbnail(from: data, maxPixelSize: thumbnailPixelSize)
            )
        }

        // 4:3 is the whole sensor, and a crop that keeps every pixel is not worth a second encode.
        if aspect.matches(.fourThree) { return untouched() }
        if storedWidth > 0, storedHeight > 0,
           cropRect(aspect, width: storedWidth, height: storedHeight, orientation: orientation) == nil {
            return untouched()
        }

        let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, index, decodeOptions) else {
            throw CameraError.captureFailed("The photo couldn't be decoded.")
        }
        // The crop is sized in displayed orientation and, being centered, covers the same pixels whether it
        // is cut before or after the EXIF rotation. Cutting the stored pixels and keeping the orientation tag
        // saves decoding a rotated copy of a 48 MP frame and keeps the HDR gain map, stored the same way, aligned.
        guard let rect = cropRect(aspect, width: image.width, height: image.height, orientation: orientation) else {
            return untouched()
        }
        guard let cropped = image.cropping(to: rect) else {
            throw CameraError.captureFailed("The photo couldn't be cropped.")
        }

        var output = properties
        output[kCGImagePropertyPixelWidth] = cropped.width
        output[kCGImagePropertyPixelHeight] = cropped.height
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = cropped.width
        exif[kCGImagePropertyExifPixelYDimension] = cropped.height
        // The subject area and location are given in uncropped pixel coordinates and would point at the wrong place.
        exif.removeValue(forKey: kCGImagePropertyExifSubjectArea)
        exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation)
        output[kCGImagePropertyExifDictionary] = exif
        output[kCGImageDestinationLossyCompressionQuality] = compressionQuality(quality)
        // The camera's embedded preview showed the uncropped frame and is not carried over; this writes a new one.
        output[kCGImageDestinationEmbedThumbnail] = true

        // Gain maps are plain pixel grids and crop cleanly. Depth and portrait mattes are left out: they carry
        // camera calibration tied to the full frame, which a crop would silently invalidate.
        var gainMaps: [(type: CFString, info: [CFString: Any])] = []
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [CFString: Any],
                  let croppedInfo = croppedAuxiliaryInfo(info, crop: rect, imageWidth: image.width, imageHeight: image.height)
            else { continue }
            gainMaps.append((type, croppedInfo))
        }

        var types: [UTType] = [UTType(sourceType) ?? .jpeg]
        if !types.contains(.jpeg) { types.append(.jpeg) }
        for type in types {
            // The gain map is a bonus: if the encoder refuses it, the cropped SDR photo is still worth saving.
            let encoded = write(cropped, as: type, properties: output, auxiliary: gainMaps)
                ?? (gainMaps.isEmpty ? nil : write(cropped, as: type, properties: output, auxiliary: []))
            guard let encoded else { continue }
            let photo = displayedSize(width: image.width, height: image.height, orientation: orientation)
            return EncodedImage(
                data: encoded,
                typeIdentifier: type.identifier,
                pixelSize: displayedSize(width: cropped.width, height: cropped.height, orientation: orientation),
                thumbnail: croppedPreview(source, index: index, aspect: aspect, photo: photo)
                    ?? drawThumbnail(cropped, orientation: orientation, maxPixelSize: thumbnailPixelSize)
            )
        }
        throw CameraError.captureFailed("The cropped photo couldn't be encoded.")
    }

    /// Small upright preview of encoded data, honouring EXIF orientation.
    static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        // An embedded preview costs almost nothing to read, while decoding a 48 MP HEIF takes a noticeable
        // moment. It is used when it is close to the size asked for (or smaller than the photo itself).
        let embedded = makeThumbnail(source, index: index, maxPixelSize: maxPixelSize, decodeFullImage: false)
        if let embedded {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let photoLongSide = max(intValue(properties[kCGImagePropertyPixelWidth]) ?? 0,
                                    intValue(properties[kCGImagePropertyPixelHeight]) ?? 0)
            let wanted = photoLongSide > 0 ? min(maxPixelSize, photoLongSide) : maxPixelSize
            if max(embedded.width, embedded.height) * 4 >= wanted * 3 { return embedded }
        }
        // A DNG has no quick full decode (it would be a whole RAW develop), so its preview is kept even if small.
        let isRaw = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }?.conforms(to: .rawImage) ?? false
        if isRaw, let embedded { return embedded }
        return makeThumbnail(source, index: index, maxPixelSize: maxPixelSize, decodeFullImage: true) ?? embedded
    }

    static func thumbnail(of image: CGImage, maxPixelSize: Int) -> CGImage? {
        drawThumbnail(image, orientation: .up, maxPixelSize: maxPixelSize)
    }

    /// ImageIO property dictionary (EXIF, TIFF, GPS) for `metadata`.
    static func properties(for metadata: CaptureMetadata) -> [CFString: Any] {
        let localTime = exifDate(metadata.date, timeZone: .current)
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: localTime,
            kCGImagePropertyExifDateTimeDigitized: localTime,
            kCGImagePropertyExifOffsetTimeOriginal: utcOffset(for: metadata.date),
            kCGImagePropertyExifOffsetTimeDigitized: utcOffset(for: metadata.date),
        ]
        if isPositive(metadata.exposureSeconds) {
            exif[kCGImagePropertyExifExposureTime] = metadata.exposureSeconds
            // APEX values let viewers that ignore ExposureTime show the shutter too.
            exif[kCGImagePropertyExifShutterSpeedValue] = -log2(metadata.exposureSeconds)
        }
        if isPositive(metadata.iso) {
            exif[kCGImagePropertyExifISOSpeedRatings] = [Int(min(metadata.iso, 1_000_000).rounded())]
        }
        if isPositive(metadata.aperture) {
            exif[kCGImagePropertyExifFNumber] = metadata.aperture
            exif[kCGImagePropertyExifApertureValue] = 2 * log2(metadata.aperture)
        }
        if let focal = metadata.focalLength35mm, isPositive(focal) {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = Int(min(focal, 100_000).rounded())
        }
        if !metadata.lensModel.isEmpty {
            exif[kCGImagePropertyExifLensMake] = "Apple"
            exif[kCGImagePropertyExifLensModel] = metadata.lensModel
        }
        if let comment = metadata.comment, !comment.isEmpty {
            exif[kCGImagePropertyExifUserComment] = comment
        }

        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFSoftware: "Open Shutter",
            kCGImagePropertyTIFFOrientation: 1,
            kCGImagePropertyTIFFDateTime: localTime,
        ]
        var result: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyOrientation: 1,
        ]
        if let location = metadata.location, let gps = gpsDictionary(location) {
            result[kCGImagePropertyGPSDictionary] = gps
        }
        return result
    }

    /// "1/250 · ISO 100 · ƒ/1.8".
    static func summary(exposureSeconds: Double, iso: Double, aperture: Double) -> String {
        // A value the source didn't record is left out rather than shown as "ISO 0".
        var parts: [String] = []
        if isPositive(exposureSeconds) { parts.append(ShutterSpeed(seconds: exposureSeconds).label) }
        if isPositive(iso) { parts.append(ISOScale.label(iso)) }
        if isPositive(aperture) { parts.append(ApertureScale.label(aperture)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Helpers

    /// Long side of the thumbnails attached to results; sharp in the review grid at 3x.
    private static let thumbnailPixelSize = 400

    private static func isPositive(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    private static func compressionQuality(_ quality: Double) -> Double {
        quality.isFinite ? min(max(quality, 0), 1) : 0.9
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func imageOrientation(in properties: [CFString: Any]) -> CGImagePropertyOrientation {
        guard let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value else { return .up }
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    private static func swapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }

    private static func displayedSize(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> PixelSize {
        swapsAxes(orientation) ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }

    /// Whole-pixel centered crop of the stored width x height image, sized for how it is displayed, or nil
    /// when it would keep the whole frame. Sizing on the displayed shape matters for a square sensor, which
    /// counts as landscape: rotated, the stored image's landscape is the viewer's portrait.
    private static func cropRect(_ aspect: AspectRatio, width: Int, height: Int, orientation: CGImagePropertyOrientation) -> CGRect? {
        let swapped = swapsAxes(orientation)
        let shown = swapped ? (width: height, height: width) : (width: width, height: height)
        let crop = aspect.centeredCrop(width: Double(shown.width), height: Double(shown.height))
        var cropWidth = min(shown.width, Int(crop.width.rounded()))
        var cropHeight = min(shown.height, Int(crop.height.rounded()))
        if swapped { swap(&cropWidth, &cropHeight) }
        guard cropWidth > 0, cropHeight > 0, cropWidth < width || cropHeight < height else { return nil }
        return CGRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, width: cropWidth, height: cropHeight)
    }

    /// `decodeFullImage` false reads the embedded preview when there is one (and decodes otherwise).
    private static func makeThumbnail(_ source: CGImageSource, index: Int, maxPixelSize: Int, decodeFullImage: Bool) -> CGImage? {
        let creation = decodeFullImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent
        let options: [CFString: Any] = [
            creation: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// The camera's embedded preview cut to `aspect`, so a cropped photo's thumbnail isn't drawn from every pixel
    /// of the crop. Nil when there is no preview of the photo's shape, or none big enough to stand in for one drawn.
    private static func croppedPreview(_ source: CGImageSource, index: Int, aspect: AspectRatio, photo: PixelSize) -> CGImage? {
        // Neither creation key: without an embedded preview this returns nil instead of decoding the photo again.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard photo.width > 0, photo.height > 0,
              let preview = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              preview.width > 0, preview.height > 0 else { return nil }
        // A preview of another shape, or one left unrotated, would frame the thumbnail differently from the photo.
        let previewShape = Double(preview.width) / Double(preview.height)
        let photoShape = Double(photo.width) / Double(photo.height)
        guard abs(previewShape / photoShape - 1) < 0.02 else { return nil }
        var cut = preview
        if let rect = cropRect(aspect, width: preview.width, height: preview.height, orientation: .up) {
            guard let cropped = preview.cropping(to: rect) else { return nil }
            cut = cropped
        }
        // The same size test thumbnail(from:) applies to the uncropped preview.
        return max(cut.width, cut.height) * 4 >= thumbnailPixelSize * 3 ? cut : nil
    }

    /// One image, its properties and optional auxiliary images written as `type`; nil when ImageIO refuses.
    private static func write(_ image: CGImage, as type: UTType, properties: [CFString: Any],
                              auxiliary: [(type: CFString, info: [CFString: Any])]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        for item in auxiliary {
            CGImageDestinationAddAuxiliaryDataInfo(destination, item.type, item.info as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    /// Core Image renders RGBA, but an alpha plane in a HEIF photo only adds size and confuses some viewers.
    /// The renders are opaque, so the same bytes are reinterpreted with the alpha byte skipped (no copy).
    private static func opaque(_ image: CGImage) -> CGImage {
        let skip: CGImageAlphaInfo
        switch image.alphaInfo {
        case .premultipliedLast, .last: skip = .noneSkipLast
        case .premultipliedFirst, .first: skip = .noneSkipFirst
        default: return image
        }
        guard !image.isMask, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let space = image.colorSpace, space.model == .rgb,
              let provider = image.dataProvider else { return image }
        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let info = CGBitmapInfo(rawValue: byteOrder | skip.rawValue)
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) ?? image
    }

    /// Downscales `image` into a bitmap of at most `maxPixelSize` on the long side, applying the EXIF
    /// `orientation` on the way so the result is upright.
    private static func drawThumbnail(_ image: CGImage, orientation: CGImagePropertyOrientation, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, image.width > 0, image.height > 0 else { return nil }
        let width = Double(image.width)
        let height = Double(image.height)
        let displayed = swapsAxes(orientation) ? (width: height, height: width) : (width: width, height: height)
        let scale = min(1, Double(maxPixelSize) / max(displayed.width, displayed.height))
        if scale == 1, orientation == .up { return image }
        let targetWidth = max(1, Int((displayed.width * scale).rounded()))
        let targetHeight = max(1, Int((displayed.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: drawableColorSpace(for: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: Double(targetWidth) / displayed.width, y: Double(targetHeight) / displayed.height)
        context.concatenate(orientationTransform(orientation, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Maps the stored image drawn at (0, 0, width, height) onto its displayed orientation in Core Graphics'
    /// bottom-left-origin space.
    private static func orientationTransform(_ orientation: CGImagePropertyOrientation, width: Double, height: Double) -> CGAffineTransform {
        switch orientation {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        }
    }

    /// 8-bit bitmap contexts only take standard-range RGB spaces; anything else draws through Display P3,
    /// which holds every color an iPhone camera produces.
    private static func drawableColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput, !CGColorSpaceUsesExtendedRange(space) {
            return space
        }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// The same region of a gain map, which is usually stored at a fraction of the photo's resolution.
    private static func croppedAuxiliaryInfo(_ info: [CFString: Any], crop: CGRect, imageWidth: Int, imageHeight: Int) -> [CFString: Any]? {
        guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
              let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let mapWidth = intValue(description[kCGImagePropertyWidth]), mapWidth > 0,
              let mapHeight = intValue(description[kCGImagePropertyHeight]), mapHeight > 0,
              let bytesPerRow = intValue(description[kCGImagePropertyBytesPerRow]),
              let format = (description[kCGImagePropertyPixelFormat] as? NSNumber)?.uint32Value,
              let bytesPerPixel = bytesPerPixel(format),
              imageWidth > 0, imageHeight > 0, bytesPerRow >= mapWidth * bytesPerPixel,
              data.count >= bytesPerRow * (mapHeight - 1) + mapWidth * bytesPerPixel
        else { return nil }
        // The crop maps onto the gain map only if both are stored the same way round. A map with the other shape
        // would brighten the wrong areas once cut, so the photo goes without it.
        let photoShape = Double(imageWidth) / Double(imageHeight)
        let mapShape = Double(mapWidth) / Double(mapHeight)
        guard abs(mapShape / photoShape - 1) < 0.05 else { return nil }

        let scaleX = Double(mapWidth) / Double(imageWidth)
        let scaleY = Double(mapHeight) / Double(imageHeight)
        let x0 = min(mapWidth - 1, max(0, Int((crop.minX * scaleX).rounded(.down))))
        let y0 = min(mapHeight - 1, max(0, Int((crop.minY * scaleY).rounded(.down))))
        let x1 = min(mapWidth, max(x0 + 1, Int((crop.maxX * scaleX).rounded(.up))))
        let y1 = min(mapHeight, max(y0 + 1, Int((crop.maxY * scaleY).rounded(.up))))
        let width = x1 - x0
        let height = y1 - y0
        let rowBytes = width * bytesPerPixel

        var pixels = Data(count: rowBytes * height)
        let copied = pixels.withUnsafeMutableBytes { destination -> Bool in
            data.withUnsafeBytes { source -> Bool in
                guard let to = destination.baseAddress, let from = source.baseAddress else { return false }
                for row in 0..<height {
                    let start = (y0 + row) * bytesPerRow + x0 * bytesPerPixel
                    guard start + rowBytes <= source.count else { return false }
                    (to + row * rowBytes).copyMemory(from: from + start, byteCount: rowBytes)
                }
                return true
            }
        }
        guard copied else { return nil }

        var newDescription = description
        newDescription[kCGImagePropertyWidth] = width
        newDescription[kCGImagePropertyHeight] = height
        newDescription[kCGImagePropertyBytesPerRow] = rowBytes
        var newInfo = info
        newInfo[kCGImageAuxiliaryDataInfoData] = pixels
        newInfo[kCGImageAuxiliaryDataInfoDataDescription] = newDescription
        return newInfo
    }

    /// Bytes per pixel of the packed formats ImageIO uses for gain maps; anything else is dropped.
    private static func bytesPerPixel(_ format: OSType) -> Int? {
        switch format {
        case kCVPixelFormatType_OneComponent8: return 1
        case kCVPixelFormatType_OneComponent16, kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_TwoComponent8: return 2
        case kCVPixelFormatType_24RGB, kCVPixelFormatType_24BGR: return 3
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA,
             kCVPixelFormatType_32ARGB, kCVPixelFormatType_32ABGR: return 4
        case kCVPixelFormatType_64RGBAHalf: return 8
        case kCVPixelFormatType_128RGBAFloat: return 16
        default: return nil
        }
    }

    private static func gpsDictionary(_ location: LocationStamp) -> [CFString: Any]? {
        guard location.latitude.isFinite, location.longitude.isFinite,
              abs(location.latitude) <= 90, abs(location.longitude) <= 180 else { return nil }
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let stamp = exifDate(location.timestamp, timeZone: utc)
        let parts = stamp.split(separator: " ")
        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef: location.longitude >= 0 ? "E" : "W",
        ]
        if parts.count == 2 {
            gps[kCGImagePropertyGPSDateStamp] = String(parts[0])
            gps[kCGImagePropertyGPSTimeStamp] = String(parts[1])
        }
        if location.altitude.isFinite {
            gps[kCGImagePropertyGPSAltitude] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = location.altitude >= 0 ? 0 : 1
        }
        if location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = location.horizontalAccuracy
        }
        return gps
    }

    /// "yyyy:MM:dd HH:mm:ss" as EXIF wants it, built from calendar fields so no shared formatter is needed
    /// across the capture queues.
    private static func exifDate(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04ld:%02ld:%02ld %02ld:%02ld:%02ld",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// "+01:00": EXIF stores local time, and this says which zone it was.
    private static func utcOffset(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        return (seconds < 0 ? "-" : "+") + String(format: "%02ld:%02ld", minutes / 60, minutes % 60)
    }
}
