import Foundation
import ImageIO
import CameraCore

/// Readable names and values for what ImageIO reports, keyed by ImageIO's own constants so no key string is guessed.
/// A key the tables don't have keeps its standard name, split into words. The tool shows a file's own data, so the
/// names are the standard ones, in sentence case.
enum PhotoInfoNames {
    typealias Formatter = (_ value: Any, _ siblings: [String: Any]) -> String?

    // MARK: - Groups

    /// The shot first, then the place and the people, then how the file is stored, then other makers' notes.
    private static let groupOrder: [String] = [
        kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
        kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyPNGDictionary, kCGImagePropertyGIFDictionary, kCGImagePropertyJFIFDictionary,
        kCGImagePropertyHEIFDictionary, kCGImagePropertyHEICSDictionary, kCGImagePropertyWebPDictionary,
        kCGImagePropertyAVISDictionary, kCGImagePropertyTGADictionary, kCGImagePropertyOpenEXRDictionary,
        kCGImagePropertyDNGDictionary, kCGImagePropertyRawDictionary, kCGImagePropertyCIFFDictionary,
        kCGImageProperty8BIMDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
    ].map { $0 as String }

    private static let groupTitles = table([
        (kCGImagePropertyExifDictionary, "Exif"),
        (kCGImagePropertyTIFFDictionary, "TIFF"),
        (kCGImagePropertyGPSDictionary, "GPS"),
        (kCGImagePropertyIPTCDictionary, "IPTC"),
        (kCGImagePropertyMakerAppleDictionary, "Apple camera data (undocumented)"),
        (kCGImagePropertyExifAuxDictionary, "Exif auxiliary"),
        (kCGImagePropertyPNGDictionary, "PNG"),
        (kCGImagePropertyGIFDictionary, "GIF"),
        (kCGImagePropertyJFIFDictionary, "JFIF"),
        (kCGImagePropertyHEIFDictionary, "HEIF"),
        (kCGImagePropertyHEICSDictionary, "HEIF sequence"),
        (kCGImagePropertyWebPDictionary, "WebP"),
        (kCGImagePropertyAVISDictionary, "AVIF sequence"),
        (kCGImagePropertyTGADictionary, "TGA"),
        (kCGImagePropertyOpenEXRDictionary, "OpenEXR"),
        (kCGImagePropertyDNGDictionary, "DNG"),
        (kCGImagePropertyRawDictionary, "RAW"),
        (kCGImagePropertyCIFFDictionary, "Canon CIFF"),
        (kCGImageProperty8BIMDictionary, "Photoshop"),
        (kCGImagePropertyMakerCanonDictionary, "Canon maker notes"),
        (kCGImagePropertyMakerNikonDictionary, "Nikon maker notes"),
        (kCGImagePropertyMakerMinoltaDictionary, "Minolta maker notes"),
        (kCGImagePropertyMakerFujiDictionary, "Fujifilm maker notes"),
        (kCGImagePropertyMakerOlympusDictionary, "Olympus maker notes"),
        (kCGImagePropertyMakerPentaxDictionary, "Pentax maker notes"),
    ])

    static func sortedGroups(_ names: some Sequence<String>) -> [String] {
        names.sorted { first, second in
            let a = groupOrder.firstIndex(of: first) ?? Int.max
            let b = groupOrder.firstIndex(of: second) ?? Int.max
            return a != b ? a < b : first < second
        }
    }

    static func groupTitle(_ name: String) -> String {
        groupTitles[name] ?? name.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }

    static let gps = kCGImagePropertyGPSDictionary as String
    static let makerApple = kCGImagePropertyMakerAppleDictionary as String

    // MARK: - Key names

    /// The name for `key` in `group` (nil: the image's own top-level properties).
    static func title(group: String?, key: String) -> String {
        if group == makerApple {
            // Apple doesn't document these; the number is all there is to go by.
            return "Apple tag " + key
        }
        // A dictionary nested in another, such as the container's "{FileContents}".
        if key.hasPrefix("{") {
            return groupTitles[key] ?? MetadataFormat.readableKey(groupTitle(key))
        }
        let names = group.flatMap { keyTitles[$0] } ?? (group == nil ? topTitles : [:])
        return names[key] ?? MetadataFormat.readableKey(key)
    }

    private static let topTitles = table([
        (kCGImagePropertyPixelWidth, "Pixel width"),
        (kCGImagePropertyPixelHeight, "Pixel height"),
        (kCGImagePropertyDPIWidth, "Horizontal resolution (dpi)"),
        (kCGImagePropertyDPIHeight, "Vertical resolution (dpi)"),
        (kCGImagePropertyDepth, "Bit depth"),
        (kCGImagePropertyOrientation, "Orientation"),
        (kCGImagePropertyIsFloat, "Floating-point samples"),
        (kCGImagePropertyIsIndexed, "Indexed color"),
        (kCGImagePropertyHasAlpha, "Transparency"),
        (kCGImagePropertyColorModel, "Color model"),
        (kCGImagePropertyProfileName, "Color profile"),
        (kCGImagePropertyPrimaryImage, "Primary image"),
        (kCGImagePropertyFileSize, "File size"),
        (kCGImagePropertyImageCount, "Image count"),
    ])

    private static let keyTitles: [String: [String: String]] = [
        kCGImagePropertyExifDictionary as String: table([
            (kCGImagePropertyExifExposureTime, "Exposure time"),
            (kCGImagePropertyExifFNumber, "F-number"),
            (kCGImagePropertyExifExposureProgram, "Exposure program"),
            (kCGImagePropertyExifSpectralSensitivity, "Spectral sensitivity"),
            (kCGImagePropertyExifISOSpeedRatings, "ISO speed ratings"),
            (kCGImagePropertyExifOECF, "Opto-electric conversion function"),
            (kCGImagePropertyExifSensitivityType, "Sensitivity type"),
            (kCGImagePropertyExifStandardOutputSensitivity, "Standard output sensitivity"),
            (kCGImagePropertyExifRecommendedExposureIndex, "Recommended exposure index"),
            (kCGImagePropertyExifISOSpeed, "ISO speed"),
            (kCGImagePropertyExifVersion, "Exif version"),
            (kCGImagePropertyExifDateTimeOriginal, "Date and time original"),
            (kCGImagePropertyExifDateTimeDigitized, "Date and time digitized"),
            (kCGImagePropertyExifOffsetTime, "Time zone offset"),
            (kCGImagePropertyExifOffsetTimeOriginal, "Time zone offset original"),
            (kCGImagePropertyExifOffsetTimeDigitized, "Time zone offset digitized"),
            (kCGImagePropertyExifSubsecTime, "Subsecond time"),
            (kCGImagePropertyExifSubsecTimeOriginal, "Subsecond time original"),
            (kCGImagePropertyExifSubsecTimeDigitized, "Subsecond time digitized"),
            (kCGImagePropertyExifComponentsConfiguration, "Components configuration"),
            (kCGImagePropertyExifCompressedBitsPerPixel, "Compressed bits per pixel"),
            (kCGImagePropertyExifShutterSpeedValue, "Shutter speed value"),
            (kCGImagePropertyExifApertureValue, "Aperture value"),
            (kCGImagePropertyExifBrightnessValue, "Brightness value"),
            (kCGImagePropertyExifExposureBiasValue, "Exposure bias"),
            (kCGImagePropertyExifMaxApertureValue, "Maximum aperture value"),
            (kCGImagePropertyExifSubjectDistance, "Subject distance"),
            (kCGImagePropertyExifMeteringMode, "Metering mode"),
            (kCGImagePropertyExifLightSource, "Light source"),
            (kCGImagePropertyExifFlash, "Flash"),
            (kCGImagePropertyExifFocalLength, "Focal length"),
            (kCGImagePropertyExifSubjectArea, "Subject area"),
            (kCGImagePropertyExifMakerNote, "Maker note"),
            (kCGImagePropertyExifUserComment, "User comment"),
            (kCGImagePropertyExifFlashPixVersion, "FlashPix version"),
            (kCGImagePropertyExifColorSpace, "Color space"),
            (kCGImagePropertyExifPixelXDimension, "Pixel X dimension"),
            (kCGImagePropertyExifPixelYDimension, "Pixel Y dimension"),
            (kCGImagePropertyExifRelatedSoundFile, "Related sound file"),
            (kCGImagePropertyExifFlashEnergy, "Flash energy"),
            (kCGImagePropertyExifSpatialFrequencyResponse, "Spatial frequency response"),
            (kCGImagePropertyExifFocalPlaneXResolution, "Focal plane X resolution"),
            (kCGImagePropertyExifFocalPlaneYResolution, "Focal plane Y resolution"),
            (kCGImagePropertyExifFocalPlaneResolutionUnit, "Focal plane resolution unit"),
            (kCGImagePropertyExifSubjectLocation, "Subject location"),
            (kCGImagePropertyExifExposureIndex, "Exposure index"),
            (kCGImagePropertyExifSensingMethod, "Sensing method"),
            (kCGImagePropertyExifFileSource, "File source"),
            (kCGImagePropertyExifSceneType, "Scene type"),
            (kCGImagePropertyExifCFAPattern, "CFA pattern"),
            (kCGImagePropertyExifCustomRendered, "Custom rendered"),
            (kCGImagePropertyExifExposureMode, "Exposure mode"),
            (kCGImagePropertyExifWhiteBalance, "White balance"),
            (kCGImagePropertyExifDigitalZoomRatio, "Digital zoom ratio"),
            (kCGImagePropertyExifFocalLenIn35mmFilm, "Focal length in 35 mm film"),
            (kCGImagePropertyExifSceneCaptureType, "Scene capture type"),
            (kCGImagePropertyExifGainControl, "Gain control"),
            (kCGImagePropertyExifContrast, "Contrast"),
            (kCGImagePropertyExifSaturation, "Saturation"),
            (kCGImagePropertyExifSharpness, "Sharpness"),
            (kCGImagePropertyExifDeviceSettingDescription, "Device setting description"),
            (kCGImagePropertyExifSubjectDistRange, "Subject distance range"),
            (kCGImagePropertyExifImageUniqueID, "Image unique ID"),
            (kCGImagePropertyExifCameraOwnerName, "Camera owner name"),
            (kCGImagePropertyExifBodySerialNumber, "Body serial number"),
            (kCGImagePropertyExifLensSpecification, "Lens specification"),
            (kCGImagePropertyExifLensMake, "Lens make"),
            (kCGImagePropertyExifLensModel, "Lens model"),
            (kCGImagePropertyExifLensSerialNumber, "Lens serial number"),
            (kCGImagePropertyExifGamma, "Gamma"),
            (kCGImagePropertyExifCompositeImage, "Composite image"),
            (kCGImagePropertyExifSourceImageNumberOfCompositeImage, "Source images in composite"),
            (kCGImagePropertyExifSourceExposureTimesOfCompositeImage, "Source exposure times of composite"),
        ]),
        kCGImagePropertyTIFFDictionary as String: table([
            (kCGImagePropertyTIFFCompression, "Compression"),
            (kCGImagePropertyTIFFPhotometricInterpretation, "Photometric interpretation"),
            (kCGImagePropertyTIFFDocumentName, "Document name"),
            (kCGImagePropertyTIFFImageDescription, "Image description"),
            (kCGImagePropertyTIFFMake, "Make"),
            (kCGImagePropertyTIFFModel, "Model"),
            (kCGImagePropertyTIFFOrientation, "Orientation"),
            (kCGImagePropertyTIFFXResolution, "X resolution"),
            (kCGImagePropertyTIFFYResolution, "Y resolution"),
            (kCGImagePropertyTIFFResolutionUnit, "Resolution unit"),
            (kCGImagePropertyTIFFSoftware, "Software"),
            (kCGImagePropertyTIFFTransferFunction, "Transfer function"),
            (kCGImagePropertyTIFFDateTime, "Date and time"),
            (kCGImagePropertyTIFFArtist, "Artist"),
            (kCGImagePropertyTIFFHostComputer, "Host computer"),
            (kCGImagePropertyTIFFCopyright, "Copyright"),
            (kCGImagePropertyTIFFWhitePoint, "White point"),
            (kCGImagePropertyTIFFPrimaryChromaticities, "Primary chromaticities"),
            (kCGImagePropertyTIFFTileWidth, "Tile width"),
            (kCGImagePropertyTIFFTileLength, "Tile length"),
            (kCGImagePropertyTIFFXPosition, "X position"),
            (kCGImagePropertyTIFFYPosition, "Y position"),
        ]),
        kCGImagePropertyGPSDictionary as String: table([
            (kCGImagePropertyGPSVersion, "GPS version"),
            (kCGImagePropertyGPSLatitudeRef, "Latitude reference"),
            (kCGImagePropertyGPSLatitude, "Latitude"),
            (kCGImagePropertyGPSLongitudeRef, "Longitude reference"),
            (kCGImagePropertyGPSLongitude, "Longitude"),
            (kCGImagePropertyGPSAltitudeRef, "Altitude reference"),
            (kCGImagePropertyGPSAltitude, "Altitude"),
            (kCGImagePropertyGPSTimeStamp, "Time stamp (UTC)"),
            (kCGImagePropertyGPSSatellites, "Satellites"),
            (kCGImagePropertyGPSStatus, "Status"),
            (kCGImagePropertyGPSMeasureMode, "Measure mode"),
            (kCGImagePropertyGPSDOP, "Dilution of precision"),
            (kCGImagePropertyGPSSpeedRef, "Speed unit"),
            (kCGImagePropertyGPSSpeed, "Speed"),
            (kCGImagePropertyGPSTrackRef, "Direction of movement reference"),
            (kCGImagePropertyGPSTrack, "Direction of movement"),
            (kCGImagePropertyGPSImgDirectionRef, "Image direction reference"),
            (kCGImagePropertyGPSImgDirection, "Image direction"),
            (kCGImagePropertyGPSMapDatum, "Map datum"),
            (kCGImagePropertyGPSDestLatitudeRef, "Destination latitude reference"),
            (kCGImagePropertyGPSDestLatitude, "Destination latitude"),
            (kCGImagePropertyGPSDestLongitudeRef, "Destination longitude reference"),
            (kCGImagePropertyGPSDestLongitude, "Destination longitude"),
            (kCGImagePropertyGPSDestBearingRef, "Destination bearing reference"),
            (kCGImagePropertyGPSDestBearing, "Destination bearing"),
            (kCGImagePropertyGPSDestDistanceRef, "Destination distance unit"),
            (kCGImagePropertyGPSDestDistance, "Destination distance"),
            (kCGImagePropertyGPSProcessingMethod, "Processing method"),
            (kCGImagePropertyGPSAreaInformation, "Area information"),
            (kCGImagePropertyGPSDateStamp, "Date stamp (UTC)"),
            (kCGImagePropertyGPSDifferental, "Differential correction"),
            (kCGImagePropertyGPSHPositioningError, "Horizontal positioning error"),
        ]),
        kCGImagePropertyIPTCDictionary as String: table([
            (kCGImagePropertyIPTCObjectName, "Object name"),
            (kCGImagePropertyIPTCKeywords, "Keywords"),
            (kCGImagePropertyIPTCCaptionAbstract, "Caption"),
            (kCGImagePropertyIPTCHeadline, "Headline"),
            (kCGImagePropertyIPTCByline, "By-line"),
            (kCGImagePropertyIPTCBylineTitle, "By-line title"),
            (kCGImagePropertyIPTCCredit, "Credit"),
            (kCGImagePropertyIPTCSource, "Source"),
            (kCGImagePropertyIPTCCopyrightNotice, "Copyright notice"),
            (kCGImagePropertyIPTCRightsUsageTerms, "Rights usage terms"),
            (kCGImagePropertyIPTCContact, "Contact"),
            (kCGImagePropertyIPTCCreatorContactInfo, "Creator contact info"),
            (kCGImagePropertyIPTCWriterEditor, "Writer or editor"),
            (kCGImagePropertyIPTCCity, "City"),
            (kCGImagePropertyIPTCSubLocation, "Sublocation"),
            (kCGImagePropertyIPTCProvinceState, "Province or state"),
            (kCGImagePropertyIPTCCountryPrimaryLocationCode, "Country code"),
            (kCGImagePropertyIPTCCountryPrimaryLocationName, "Country"),
            (kCGImagePropertyIPTCContentLocationCode, "Content location code"),
            (kCGImagePropertyIPTCContentLocationName, "Content location"),
            (kCGImagePropertyIPTCExtLocationCreated, "Location created"),
            (kCGImagePropertyIPTCExtLocationShown, "Location shown"),
            (kCGImagePropertyIPTCDateCreated, "Date created"),
            (kCGImagePropertyIPTCTimeCreated, "Time created"),
            (kCGImagePropertyIPTCDigitalCreationDate, "Digital creation date"),
            (kCGImagePropertyIPTCDigitalCreationTime, "Digital creation time"),
            (kCGImagePropertyIPTCOriginatingProgram, "Originating program"),
            (kCGImagePropertyIPTCProgramVersion, "Program version"),
            (kCGImagePropertyIPTCStarRating, "Star rating"),
            (kCGImagePropertyIPTCCategory, "Category"),
            (kCGImagePropertyIPTCSupplementalCategory, "Supplemental category"),
            (kCGImagePropertyIPTCSpecialInstructions, "Special instructions"),
            (kCGImagePropertyIPTCImageOrientation, "Image orientation"),
            (kCGImagePropertyIPTCLanguageIdentifier, "Language"),
        ]),
        kCGImagePropertyExifAuxDictionary as String: table([
            (kCGImagePropertyExifAuxLensInfo, "Lens info"),
            (kCGImagePropertyExifAuxLensModel, "Lens model"),
            (kCGImagePropertyExifAuxSerialNumber, "Serial number"),
            (kCGImagePropertyExifAuxLensID, "Lens ID"),
            (kCGImagePropertyExifAuxLensSerialNumber, "Lens serial number"),
            (kCGImagePropertyExifAuxImageNumber, "Image number"),
            (kCGImagePropertyExifAuxFlashCompensation, "Flash compensation"),
            (kCGImagePropertyExifAuxOwnerName, "Owner name"),
            (kCGImagePropertyExifAuxFirmware, "Firmware"),
        ]),
        kCGImagePropertyPNGDictionary as String: table([
            (kCGImagePropertyPNGGamma, "Gamma"),
            (kCGImagePropertyPNGInterlaceType, "Interlace type"),
            (kCGImagePropertyPNGXPixelsPerMeter, "Horizontal pixels per meter"),
            (kCGImagePropertyPNGYPixelsPerMeter, "Vertical pixels per meter"),
            (kCGImagePropertyPNGsRGBIntent, "sRGB intent"),
            (kCGImagePropertyPNGChromaticities, "Chromaticities"),
            (kCGImagePropertyPNGAuthor, "Author"),
            (kCGImagePropertyPNGCopyright, "Copyright"),
            (kCGImagePropertyPNGCreationTime, "Creation time"),
            (kCGImagePropertyPNGDescription, "Description"),
            (kCGImagePropertyPNGModificationTime, "Modification time"),
            (kCGImagePropertyPNGSoftware, "Software"),
            (kCGImagePropertyPNGTitle, "Title"),
            (kCGImagePropertyPNGComment, "Comment"),
            (kCGImagePropertyPNGDisclaimer, "Disclaimer"),
            (kCGImagePropertyPNGWarning, "Warning"),
            (kCGImagePropertyPNGSource, "Source"),
            (kCGImagePropertyPNGCompressionFilter, "Compression filter"),
            (kCGImagePropertyPNGTransparency, "Transparency"),
            (kCGImagePropertyPNGPixelsAspectRatio, "Pixel aspect ratio"),
            (kCGImagePropertyAPNGLoopCount, "Loop count"),
            (kCGImagePropertyAPNGDelayTime, "Delay time"),
            (kCGImagePropertyAPNGUnclampedDelayTime, "Unclamped delay time"),
            (kCGImagePropertyAPNGFrameInfoArray, "Frames"),
            (kCGImagePropertyAPNGCanvasPixelWidth, "Canvas width"),
            (kCGImagePropertyAPNGCanvasPixelHeight, "Canvas height"),
        ]),
        kCGImagePropertyGIFDictionary as String: table([
            (kCGImagePropertyGIFLoopCount, "Loop count"),
            (kCGImagePropertyGIFDelayTime, "Delay time"),
            (kCGImagePropertyGIFUnclampedDelayTime, "Unclamped delay time"),
            (kCGImagePropertyGIFImageColorMap, "Color map"),
            (kCGImagePropertyGIFHasGlobalColorMap, "Global color map"),
            (kCGImagePropertyGIFFrameInfoArray, "Frames"),
            (kCGImagePropertyGIFCanvasPixelWidth, "Canvas width"),
            (kCGImagePropertyGIFCanvasPixelHeight, "Canvas height"),
        ]),
        kCGImagePropertyJFIFDictionary as String: table([
            (kCGImagePropertyJFIFVersion, "JFIF version"),
            (kCGImagePropertyJFIFXDensity, "Horizontal density"),
            (kCGImagePropertyJFIFYDensity, "Vertical density"),
            (kCGImagePropertyJFIFDensityUnit, "Density unit"),
            (kCGImagePropertyJFIFIsProgressive, "Progressive"),
        ]),
        kCGImagePropertyDNGDictionary as String: table([
            (kCGImagePropertyDNGVersion, "DNG version"),
            (kCGImagePropertyDNGBackwardVersion, "DNG backward version"),
            (kCGImagePropertyDNGUniqueCameraModel, "Unique camera model"),
            (kCGImagePropertyDNGLocalizedCameraModel, "Localized camera model"),
            (kCGImagePropertyDNGCameraSerialNumber, "Camera serial number"),
            (kCGImagePropertyDNGLensInfo, "Lens info"),
        ]),
    ]

    // MARK: - Rows that identify someone

    private static let personalKeys: [String: Set<String>] = [
        kCGImagePropertyExifDictionary as String: names([
            kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifBodySerialNumber,
            kCGImagePropertyExifLensSerialNumber,
        ]),
        kCGImagePropertyExifAuxDictionary as String: names([
            kCGImagePropertyExifAuxSerialNumber, kCGImagePropertyExifAuxLensSerialNumber,
            kCGImagePropertyExifAuxOwnerName,
        ]),
        kCGImagePropertyTIFFDictionary as String: names([
            kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFHostComputer,
        ]),
        kCGImagePropertyIPTCDictionary as String: names([
            kCGImagePropertyIPTCByline, kCGImagePropertyIPTCBylineTitle, kCGImagePropertyIPTCCredit,
            kCGImagePropertyIPTCCopyrightNotice, kCGImagePropertyIPTCContact, kCGImagePropertyIPTCCreatorContactInfo,
            kCGImagePropertyIPTCWriterEditor, kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation,
            kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationCode,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCContentLocationCode,
            kCGImagePropertyIPTCContentLocationName, kCGImagePropertyIPTCExtLocationCreated,
            kCGImagePropertyIPTCExtLocationShown,
        ]),
        kCGImagePropertyPNGDictionary as String: names([kCGImagePropertyPNGAuthor, kCGImagePropertyPNGCopyright]),
        kCGImagePropertyDNGDictionary as String: names([kCGImagePropertyDNGCameraSerialNumber]),
    ]

    /// GPS fields, serial numbers, owner and artist names, copyright and the computer a file came from: what can
    /// point at a person, a device or a place.
    static func isPersonal(group: String?, key: String) -> Bool {
        guard let group else { return false }
        return group == gps || personalKeys[group]?.contains(key) == true
    }

    static func isPersonal(xmpNamespace namespace: String, name: String) -> Bool {
        typealias Namespace = MetadataStripPlan.XMPNamespace
        switch namespace {
        case Namespace.exif: return name.hasPrefix("GPS")
        case Namespace.photoshop:
            return ["City", "State", "Country", "Credit", "AuthorsPosition", "CaptionWriter"].contains(name)
        case Namespace.iptcCore: return ["Location", "CountryCode", "CreatorContactInfo"].contains(name)
        case Namespace.iptcExtension: return name.hasPrefix("Location")
        case Namespace.dublinCore: return name == "creator" || name == "rights"
        case Namespace.xmpRights: return true
        case Namespace.tiff: return ["Artist", "Copyright", "HostComputer"].contains(name)
        case Namespace.exifAux: return ["SerialNumber", "LensSerialNumber", "OwnerName"].contains(name)
        case Namespace.exifEX: return ["BodySerialNumber", "LensSerialNumber", "CameraOwnerName"].contains(name)
        default: return false
        }
    }

    // MARK: - Values

    /// Readable text for a value the tables know, or nil for the plain rendering. `siblings` is the dictionary the
    /// value sits in, where a GPS reference lives next to its value.
    static func value(group: String?, key: String, value: Any, siblings: [String: Any]) -> String? {
        let formatters = group.flatMap { valueFormatters[$0] } ?? (group == nil ? topFormatters : [:])
        return formatters[key]?(value, siblings)
    }

    private static let topFormatters = formatterTable([
        (kCGImagePropertyOrientation, { value, _ in int(value).map(MetadataFormat.orientation) }),
        (kCGImagePropertyHasAlpha, { value, _ in yesNo(value) }),
        (kCGImagePropertyIsFloat, { value, _ in yesNo(value) }),
        (kCGImagePropertyIsIndexed, { value, _ in yesNo(value) }),
        (kCGImagePropertyPrimaryImage, { value, _ in yesNo(value) }),
        (kCGImagePropertyDepth, { value, _ in int(value).map { "\($0) bits per sample" } }),
        (kCGImagePropertyFileSize, { value, _ in int(value).map { Formatting.fileSize(bytes: Int64($0)) } }),
    ])

    private static let valueFormatters: [String: [String: Formatter]] = [
        kCGImagePropertyExifDictionary as String: formatterTable([
            (kCGImagePropertyExifExposureTime, { value, _ in number(value).flatMap(shutterText) }),
            (kCGImagePropertyExifFNumber, { value, _ in positive(value).map(ApertureScale.label) }),
            (kCGImagePropertyExifExposureProgram, { value, _ in int(value).map(MetadataFormat.exposureProgram) }),
            (kCGImagePropertyExifExposureBiasValue, { value, _ in number(value).map(evText) }),
            (kCGImagePropertyExifFocalLength, { value, _ in positive(value).map(millimetres) }),
            (kCGImagePropertyExifFocalLenIn35mmFilm, { value, _ in positive(value).map(LensMath.focalLengthLabel) }),
            (kCGImagePropertyExifShutterSpeedValue, { value, _ in
                number(value).flatMap { apex in shutterText(pow(2, -apex)).map { decimal(apex, 2) + " (" + $0 + ")" } }
            }),
            (kCGImagePropertyExifApertureValue, { value, _ in number(value).map(apertureFromAPEX) }),
            (kCGImagePropertyExifMaxApertureValue, { value, _ in number(value).map(apertureFromAPEX) }),
            (kCGImagePropertyExifBrightnessValue, { value, _ in number(value).map { decimal($0, 2) } }),
            (kCGImagePropertyExifSubjectDistance, { value, _ in number(value).map { decimal($0, 2) + " m" } }),
            (kCGImagePropertyExifMeteringMode, { value, _ in int(value).map(MetadataFormat.meteringMode) }),
            (kCGImagePropertyExifLightSource, { value, _ in int(value).map(MetadataFormat.lightSource) }),
            (kCGImagePropertyExifFlash, { value, _ in int(value).map(MetadataFormat.flash) }),
            (kCGImagePropertyExifSensingMethod, { value, _ in int(value).map(MetadataFormat.sensingMethod) }),
            (kCGImagePropertyExifSceneType, { value, _ in int(value).map(MetadataFormat.sceneType) }),
            (kCGImagePropertyExifCustomRendered, { value, _ in int(value).map(MetadataFormat.customRendered) }),
            (kCGImagePropertyExifExposureMode, { value, _ in int(value).map(MetadataFormat.exposureMode) }),
            (kCGImagePropertyExifWhiteBalance, { value, _ in int(value).map(MetadataFormat.whiteBalance) }),
            (kCGImagePropertyExifSceneCaptureType, { value, _ in int(value).map(MetadataFormat.sceneCaptureType) }),
            (kCGImagePropertyExifCompositeImage, { value, _ in int(value).map(MetadataFormat.compositeImage) }),
            (kCGImagePropertyExifColorSpace, { value, _ in int(value).map(MetadataFormat.colorSpace) }),
            (kCGImagePropertyExifLensSpecification, { value, _ in MetadataFormat.lensSpecification(numbers(value)) }),
            (kCGImagePropertyExifDigitalZoomRatio, { value, _ in
                number(value).map { $0 > 0 ? decimal($0, 2) + "x" : "Not used" }
            }),
            (kCGImagePropertyExifGainControl, { value, _ in
                int(value).map { named($0, [0: "None", 1: "Low gain up", 2: "High gain up", 3: "Low gain down",
                                             4: "High gain down"]) }
            }),
            (kCGImagePropertyExifContrast, { value, _ in
                int(value).map { named($0, [0: "Normal", 1: "Soft", 2: "Hard"]) }
            }),
            (kCGImagePropertyExifSaturation, { value, _ in
                int(value).map { named($0, [0: "Normal", 1: "Low", 2: "High"]) }
            }),
            (kCGImagePropertyExifSharpness, { value, _ in
                int(value).map { named($0, [0: "Normal", 1: "Soft", 2: "Hard"]) }
            }),
            (kCGImagePropertyExifSubjectDistRange, { value, _ in
                int(value).map { named($0, [0: "Unknown", 1: "Macro", 2: "Close", 3: "Distant"]) }
            }),
            (kCGImagePropertyExifFileSource, { value, _ in int(value).map { named($0, [3: "Digital camera"]) } }),
            (kCGImagePropertyExifVersion, { value, _ in version(value) }),
            (kCGImagePropertyExifFlashPixVersion, { value, _ in version(value) }),
        ]),
        kCGImagePropertyTIFFDictionary as String: formatterTable([
            (kCGImagePropertyTIFFOrientation, { value, _ in int(value).map(MetadataFormat.orientation) }),
            (kCGImagePropertyTIFFResolutionUnit, { value, _ in
                int(value).map { named($0, [1: "None", 2: "Inches", 3: "Centimeters"]) }
            }),
            (kCGImagePropertyTIFFCompression, { value, _ in
                int(value).map { named($0, [1: "Uncompressed", 5: "LZW", 6: "JPEG", 7: "JPEG", 8: "Deflate",
                                             32773: "PackBits"]) }
            }),
            (kCGImagePropertyTIFFPhotometricInterpretation, { value, _ in
                int(value).map { named($0, [0: "White is zero", 1: "Black is zero", 2: "RGB", 3: "Palette",
                                             5: "CMYK", 6: "YCbCr", 8: "CIELab"]) }
            }),
        ]),
        kCGImagePropertyGPSDictionary as String: formatterTable([
            (kCGImagePropertyGPSLatitude, { value, siblings in
                number(value).flatMap { MetadataFormat.latitude($0, ref: text(siblings[latitudeRef])) }
            }),
            (kCGImagePropertyGPSLongitude, { value, siblings in
                number(value).flatMap { MetadataFormat.longitude($0, ref: text(siblings[longitudeRef])) }
            }),
            (kCGImagePropertyGPSDestLatitude, { value, siblings in
                number(value).flatMap { MetadataFormat.latitude($0, ref: text(siblings[destLatitudeRef])) }
            }),
            (kCGImagePropertyGPSDestLongitude, { value, siblings in
                number(value).flatMap { MetadataFormat.longitude($0, ref: text(siblings[destLongitudeRef])) }
            }),
            (kCGImagePropertyGPSAltitude, { value, siblings in
                number(value).flatMap { MetadataFormat.altitude($0, ref: siblings[altitudeRef].flatMap(int)) }
            }),
            (kCGImagePropertyGPSAltitudeRef, { value, _ in
                int(value).map { named($0, [0: "Above sea level", 1: "Below sea level"]) }
            }),
            (kCGImagePropertyGPSSpeed, { value, siblings in
                number(value).flatMap { MetadataFormat.speed($0, ref: text(siblings[speedRef])) }
            }),
            (kCGImagePropertyGPSImgDirection, { value, siblings in
                number(value).flatMap { MetadataFormat.direction($0, ref: text(siblings[imgDirectionRef])) }
            }),
            (kCGImagePropertyGPSDestBearing, { value, siblings in
                number(value).flatMap { MetadataFormat.direction($0, ref: text(siblings[destBearingRef])) }
            }),
            (kCGImagePropertyGPSTrack, { value, siblings in
                number(value).flatMap { MetadataFormat.direction($0, ref: text(siblings[trackRef])) }
            }),
            (kCGImagePropertyGPSHPositioningError, { value, _ in
                number(value).flatMap(MetadataFormat.positioningError)
            }),
            (kCGImagePropertyGPSVersion, { value, _ in version(value) }),
        ]),
        kCGImagePropertyJFIFDictionary as String: formatterTable([
            (kCGImagePropertyJFIFVersion, { value, _ in version(value) }),
            (kCGImagePropertyJFIFIsProgressive, { value, _ in yesNo(value) }),
        ]),
        kCGImagePropertyDNGDictionary as String: formatterTable([
            (kCGImagePropertyDNGVersion, { value, _ in version(value) }),
            (kCGImagePropertyDNGBackwardVersion, { value, _ in version(value) }),
        ]),
    ]

    static let latitudeRef = kCGImagePropertyGPSLatitudeRef as String
    static let longitudeRef = kCGImagePropertyGPSLongitudeRef as String
    private static let destLatitudeRef = kCGImagePropertyGPSDestLatitudeRef as String
    private static let destLongitudeRef = kCGImagePropertyGPSDestLongitudeRef as String
    static let altitudeRef = kCGImagePropertyGPSAltitudeRef as String
    static let speedRef = kCGImagePropertyGPSSpeedRef as String
    static let imgDirectionRef = kCGImagePropertyGPSImgDirectionRef as String
    private static let destBearingRef = kCGImagePropertyGPSDestBearingRef as String
    private static let trackRef = kCGImagePropertyGPSTrackRef as String

    // MARK: - The app's own fields

    /// What each ShotXMP field is called here. Exhaustive, so a field added in CameraCore gets a name or the build
    /// stops.
    static func appTitle(_ field: ShotXMP.Field) -> String {
        switch field {
        case .version: return "Format version"
        case .mode: return "Mode"
        case .interface: return "Interface"
        case .scene: return "Scene"
        case .exposureControl: return "Exposure control"
        case .bias: return "Exposure compensation"
        case .aeLock: return "Exposure locked"
        case .meteringArea: return "Metering area"
        case .whiteBalance: return "White balance"
        case .whiteBalanceFromScene: return "White balance from the scene"
        case .kelvin: return "Color temperature"
        case .tint: return "Tint"
        case .focus: return "Focus"
        case .lensPosition: return "Lens position"
        case .lens: return "Camera"
        case .lensName: return "Camera name"
        case .zoom: return "Zoom"
        case .zoomFactor: return "Zoom factor"
        case .aspect: return "Aspect ratio"
        case .processing: return "Processing"
        case .flash: return "Flash"
        case .livePhoto: return "Live Photo"
        case .timer: return "Timer"
        case .intervalShot: return "Interval shot"
        case .intervalCount: return "Interval shots"
        case .bracket: return "Bracket"
        case .bracketIndex: return "Bracket photo"
        case .bracketCount: return "Bracket photos"
        case .bracketStep: return "Bracket step"
        case .bracketValue: return "Bracket value"
        case .bracketGroup: return "Bracket set"
        case .blend: return "Blend"
        case .frameSeconds: return "Frame time"
        case .frameCount: return "Frames used"
        case .framesCaptured: return "Frames captured"
        case .framesPlanned: return "Frames planned"
        case .lightSeconds: return "Light time"
        case .captureSeconds: return "Capture time"
        case .sensorISO: return "Sensor ISO"
        case .digitalGain: return "Digital gain"
        case .aligned: return "Frames aligned"
        case .blurRejection: return "Blurry frames left out"
        case .noiseReduction: return "Noise reduction"
        case .bulb: return "Bulb"
        case .stability: return "Stability"
        case .steadyAtStart: return "Steady at the start"
        case .stabilization: return "Stabilization"
        case .codec: return "Codec"
        case .colorMode: return "Color mode"
        case .frameRate: return "Frame rate"
        case .resolution: return "Resolution"
        case .audio: return "Sound"
        case .windNoiseReduction: return "Wind noise reduction"
        case .lowLightNoiseReduction: return "Low light noise reduction"
        case .osVersion: return "iOS version"
        case .simulated: return "Simulated camera"
        }
    }

    /// The stored value made readable. The file keeps raw values that never change with the interface, so names
    /// come from CameraCore's own titles where it has them.
    static func appValue(_ field: ShotXMP.Field, _ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "True" { return "Yes" }
        if text == "False" { return "No" }
        let number = Double(text).flatMap { $0.isFinite ? $0 : nil }
        let readable: String?
        switch field {
        case .mode: readable = CaptureMode(rawValue: text).map(modeTitle)
        case .scene: readable = LongExposureScene(rawValue: text)?.title
        case .blend: readable = StackBlend(rawValue: text)?.title
        case .whiteBalance: readable = WhiteBalancePreset(rawValue: text)?.title
        case .processing: readable = ProcessingLevel(rawValue: text)?.title
        case .flash: readable = FlashSetting(rawValue: text)?.title
        case .bracket: readable = BracketKind(rawValue: text)?.title
        case .meteringArea: readable = MeteringArea(rawValue: text)?.title
        case .bias: readable = number.map(evText)
        case .kelvin: readable = number.map { decimal($0, 0) + " K" }
        case .zoom, .zoomFactor, .digitalGain: readable = number.map { decimal($0, 2) + "x" }
        case .timer, .lightSeconds, .captureSeconds: readable = number.map(Formatting.compactDuration)
        case .frameSeconds: readable = number.flatMap(shutterText)
        case .noiseReduction: readable = number.map(Formatting.percent)
        case .frameRate: readable = number.map(Formatting.frameRate)
        case .codec: readable = text.uppercased()
        default: readable = nil
        }
        if let readable { return readable }
        // A raw value that is one camel-case word ("shutterPriority") reads as words; numbers, UUIDs and "16:9"
        // stay as written.
        if !text.isEmpty, text.allSatisfy({ $0.isLetter }) {
            return MetadataFormat.readableKey(text)
        }
        return text
    }

    static func modeTitle(_ mode: CaptureMode) -> String {
        switch mode {
        case .night: return "Night"
        case .long: return "Long exposure"
        case .photo: return "Photo"
        case .manual: return "Manual"
        case .video: return "Video"
        }
    }

    // MARK: - Shared text

    /// "1/250 s", "0.5 s", "30 s".
    static func shutterText(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let speed = ShutterSpeed(seconds: seconds)
        if speed.isFraction { return speed.label + " s" }
        return decimal(seconds, seconds < 10 ? 1 : 0) + " s"
    }

    /// "+0.3 EV", "0 EV".
    static func evText(_ ev: Double) -> String {
        EVFormat.label(ev) + " EV"
    }

    /// "6.765 mm".
    static func millimetres(_ mm: Double) -> String {
        decimal(mm, 3) + " mm"
    }

    static func decimal(_ value: Double, _ decimals: Int) -> String {
        ExifFormat.decimal(value, maxDecimals: decimals)
    }

    /// Plain text for any value ImageIO hands over: numbers without trailing zeros, Yes or No, a byte count for
    /// binary data, short lists joined.
    static func describe(_ value: Any) -> String {
        if let flag = boolean(value) { return flag ? "Yes" : "No" }
        if let number = value as? NSNumber {
            if CFNumberIsFloatType(number as CFNumber) { return decimal(number.doubleValue, 6) }
            return String(number.int64Value)
        }
        if let string = value as? String { return cleaned(string) }
        if let data = value as? Data { return data.count == 1 ? "1 byte" : "\(data.count) bytes" }
        if let array = value as? [Any] { return array.map(describe).joined(separator: ", ") }
        if let dictionary = value as? [String: Any] {
            return dictionary.count == 1 ? "1 value" : "\(dictionary.count) values"
        }
        return String(describing: value)
    }

    /// True for a value that reads well on one line: a number, a flag or text.
    static func isScalar(_ value: Any) -> Bool {
        value is NSNumber || value is String
    }

    static func number(_ value: Any) -> Double? {
        if boolean(value) != nil { return nil }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String { return Double(cleaned(string)) }
        if let array = value as? [Any], array.count == 1 { return number(array[0]) }
        return nil
    }

    static func int(_ value: Any) -> Int? {
        guard let double = number(value), abs(double) < 1e15 else { return nil }
        return Int(double.rounded())
    }

    static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return cleaned(string) }
        if let array = value as? [Any], let first = array.first { return text(first) }
        return nil
    }

    static func numbers(_ value: Any) -> [Double] {
        if let array = value as? [Any] { return array.compactMap(number) }
        return number(value).map { [$0] } ?? []
    }

    /// Text without the trailing spaces and NULs that fixed-size EXIF fields are padded with.
    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    private static func positive(_ value: Any) -> Double? {
        number(value).flatMap { $0 > 0 ? $0 : nil }
    }

    /// "1.69 (ƒ/1.8)": the APEX value and the f-number it stands for.
    private static func apertureFromAPEX(_ apex: Double) -> String {
        decimal(apex, 2) + " (" + ApertureScale.label(pow(2, apex / 2)) + ")"
    }

    /// [2, 3, 2] as "2.3.2"; the version tags are lists of numbers.
    private static func version(_ value: Any) -> String? {
        let parts = numbers(value).map { String(Int($0.rounded())) }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    private static func boolean(_ value: Any) -> Bool? {
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFBooleanGetTypeID() else { return nil }
        return (value as? Bool) ?? false
    }

    private static func yesNo(_ value: Any) -> String? {
        if let flag = boolean(value) { return flag ? "Yes" : "No" }
        return int(value).map { $0 != 0 ? "Yes" : "No" }
    }

    private static func named(_ value: Int, _ names: [Int: String]) -> String {
        names[value] ?? "Unknown (\(value))"
    }

    private static func table(_ pairs: [(CFString, String)]) -> [String: String] {
        Dictionary(pairs.map { ($0.0 as String, $0.1) }, uniquingKeysWith: { first, _ in first })
    }

    private static func names(_ keys: [CFString]) -> Set<String> {
        Set(keys.map { $0 as String })
    }

    private static func formatterTable(_ pairs: [(CFString, Formatter)]) -> [String: Formatter] {
        Dictionary(pairs.map { ($0.0 as String, $0.1) }, uniquingKeysWith: { first, _ in first })
    }
}
