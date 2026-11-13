import Foundation

// The simple interface shows a handful of settings and runs the rest on their defaults. Turning the advanced
// interface off resets everything it alone shows, so nothing invisible keeps changing the pictures; turning it back
// on restores those settings from a snapshot taken at that moment, along with what the simple interface had fewer
// choices for.

extension CameraSettings {
    /// Aspect ratios the simple drawer offers.
    public static let simpleAspects: [AspectRatio] = [.fourThree, .square, .sixteenNine]
    /// Self timer choices of the simple drawer, in seconds.
    public static let simpleDelays: [Double] = [0, 3, 10]
    public static let simpleGrids: [GridStyle] = [.off, .thirds]
    /// What the Camera Control carries in the simple interface: nothing that leads to MANUAL.
    public static let simpleCameraControlItems: [CameraControlItem] = [.zoom, .lens, .exposureBias]

    /// The advanced-only settings as the simple interface runs them: the defaults, with the viewfinder's
    /// measuring tools off.
    private static let simpleBaseline: CameraSettings = {
        var settings = CameraSettings()
        settings.display.histogram = .off
        settings.display.zebras = false
        settings.display.peaking = .off
        settings.display.falseColor = false
        settings.display.showReadout = false
        settings.display.clippingWarnings = false
        return settings
    }()

    /// Copies every setting that only the advanced interface shows from `source`. The one list both directions
    /// share, so a setting can't be reset on the way out and forgotten on the way back.
    private mutating func copyAdvancedFields(from source: CameraSettings) {
        manual.shutter = source.manual.shutter
        manual.iso = source.manual.iso
        manual.aperture = source.manual.aperture
        whiteBalance = source.whiteBalance
        focus = source.focus

        capture.rawFormat = source.capture.rawFormat
        capture.quality = source.capture.quality
        capture.resolution = source.capture.resolution
        capture.processing = source.capture.processing
        capture.depth = source.capture.depth
        capture.constantColor = source.capture.constantColor
        capture.lensCorrection = source.capture.lensCorrection
        capture.bracket = source.capture.bracket

        exposure = source.exposure
        focusOptions = source.focusOptions

        display.histogram = source.display.histogram
        display.zebras = source.display.zebras
        display.zebraThreshold = source.display.zebraThreshold
        display.peaking = source.display.peaking
        display.peakingColor = source.display.peakingColor
        display.peakingSensitivity = source.display.peakingSensitivity
        display.falseColor = source.display.falseColor
        display.showReadout = source.display.showReadout
        display.clippingWarnings = source.display.clippingWarnings

        night.stability = source.night.stability
        night.alignFrames = source.night.alignFrames
        night.maxISO = source.night.maxISO

        longExposure.maxBulbSeconds = source.longExposure.maxBulbSeconds

        video.codec = source.video.codec
        video.colorMode = source.video.colorMode
        video.stabilization = source.video.stabilization
        video.audio = source.video.audio
        video.windNoiseReduction = source.video.windNoiseReduction
        video.lowLightNoiseReduction = source.video.lowLightNoiseReduction
        video.showShutterAngle = source.video.showShutterAngle

        controls.cameraControlItems = source.controls.cameraControlItems
        controls.autoLensSwitching = source.controls.autoLensSwitching
    }

    /// These settings as the simple interface runs them. Everything only the advanced interface shows goes back to
    /// automatic or its default, and the settings both share are narrowed to the choices the simple one offers.
    /// Applying it twice changes nothing more. `restoringAdvanced(from:)` gives back each setting narrowed here.
    public func simplified() -> CameraSettings {
        var settings = self
        settings.copyAdvancedFields(from: Self.simpleBaseline)
        settings.interface.advanced = false

        if settings.mode == .manual {
            settings.mode = .photo
        }
        // RAW is off now, so a RAW-only setup needs a processed format again.
        if settings.capture.processedFormat == .none {
            settings.capture.processedFormat = .heif
        }
        if !Self.simpleAspects.contains(where: { $0.matches(settings.capture.aspect) }) {
            settings.capture.aspect = .fourThree
        }
        // The self timer stays, at the longest delay the simple drawer offers; the intervalometer goes.
        let delay = Self.simpleDelays.last(where: { $0 <= settings.capture.schedule.delay }) ?? 0
        settings.capture.schedule = CaptureSchedule(delay: delay)
        if !Self.simpleGrids.contains(settings.display.grid) {
            settings.display.grid = .thirds
        }

        // A scene follows its recipe again and takes the offered time closest to its own. Custom is no scene of
        // the simple interface, so it starts over on Water.
        let long = settings.longExposure
        if let recipe = long.recipe {
            settings.longExposure.apply(long.scene)
            settings.longExposure.seconds = recipe.nearestDuration(to: long.seconds)
        } else {
            settings.longExposure.apply(.water)
        }
        return settings
    }

    /// These settings with the advanced interface on, taking back every advanced-only setting from `snapshot`,
    /// the settings as they were when the advanced interface was last turned off. Without a snapshot they start
    /// from the defaults. Settings both interfaces share keep their current values, except what going simple had
    /// to narrow: a frame shape, timer or grid it doesn't offer, a RAW-only format, a long exposure set by hand or
    /// a scene's time off its list. Each of those comes back while it is still where narrowing left it. The mode
    /// stays where it is.
    public func restoringAdvanced(from snapshot: CameraSettings?) -> CameraSettings {
        var settings = self
        settings.copyAdvancedFields(from: snapshot ?? .default)
        settings.interface.advanced = true
        if let snapshot {
            // A value that differs from the narrowed one was picked in the simple interface since, and stays.
            // The long exposure goes as a whole: a scene with another setup's blend or frame would be neither.
            // Its bulb limit is an advanced setting, which like the rest of them has no say in the comparison.
            let narrowed = snapshot.simplified()
            var current = self
            current.copyAdvancedFields(from: narrowed)
            func restore<Value: Equatable>(_ path: WritableKeyPath<CameraSettings, Value>) {
                if current[keyPath: path] == narrowed[keyPath: path] {
                    settings[keyPath: path] = snapshot[keyPath: path]
                }
            }
            restore(\.capture.processedFormat)
            restore(\.capture.aspect)
            restore(\.capture.schedule)
            restore(\.display.grid)
            restore(\.longExposure)
        }
        if !settings.capture.isValid {
            settings.capture.processedFormat = .heif
        }
        return settings
    }
}
