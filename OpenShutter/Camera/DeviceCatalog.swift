import Foundation
import AVFoundation
import CoreMedia
import CameraCore

/// The physical cameras the app drives one at a time. Virtual multi-lens devices are left out on purpose:
/// Apple documents that they reject custom exposure, custom lens positions and custom white balance gains,
/// which are the whole point of this app. Switching lenses swaps the session input instead.
struct DeviceCatalog {
    struct Camera {
        let device: AVCaptureDevice
        let lens: LensInfo
    }

    /// Back cameras ordered by focal length, then the front camera.
    let cameras: [Camera]
    /// Lens picker buttons, ascending display zoom.
    let presets: [LensPreset]

    var lenses: [LensInfo] { cameras.map(\.lens) }

    var isEmpty: Bool { cameras.isEmpty }

    func camera(id: String?) -> Camera? {
        guard let id else { return nil }
        return cameras.first { $0.device.uniqueID == id }
    }

    /// The main back camera, the one the Camera app opens with.
    var defaultCamera: Camera? {
        cameras.first { $0.lens.kind == .wide } ?? cameras.first { !$0.lens.isFront } ?? cameras.first
    }

    /// Session queue: discovery can block while the camera system wakes up.
    static func discover() -> DeviceCatalog {
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices
        let frontCandidates = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front
        ).devices
        // The plain front camera takes custom exposure; TrueDepth is only the fallback on hardware without one.
        // Picked by type, because the order of a discovery session's devices isn't documented.
        let front = frontCandidates.first { $0.deviceType == .builtInWideAngleCamera } ?? frontCandidates.first

        let measuredBack = back.map { device in
            (device: device, kind: kind(of: device), focal: equivalentFocalLength(of: device))
        }
        .sorted { $0.focal < $1.focal }

        // Zoom numbers are relative to the main camera, like the "1×" button in the Camera app.
        let reference = measuredBack.first(where: { $0.kind == .wide })?.focal
            ?? measuredBack.first?.focal
            ?? 0

        var cameras: [Camera] = measuredBack.map { entry in
            let relative = reference > 0 ? roundedZoom(LensMath.relativeZoom(focalLength: entry.focal, reference: reference)) : 1
            return Camera(device: entry.device, lens: lensInfo(entry.device, kind: entry.kind, focal: entry.focal, relativeZoom: relative))
        }
        if let front {
            let lens = lensInfo(front, kind: .front, focal: equivalentFocalLength(of: front), relativeZoom: 1)
            cameras.append(Camera(device: front, lens: lens))
        }
        return DeviceCatalog(cameras: cameras, presets: makePresets(for: cameras))
    }

    // MARK: - Lens facts

    static func kind(of device: AVCaptureDevice) -> LensInfo.Kind {
        if device.position == .front { return .front }
        switch device.deviceType {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInWideAngleCamera: return .wide
        case .builtInTelephotoCamera: return .telephoto
        default: return .external
        }
    }

    /// 35 mm equivalent focal length. iOS 26 reports Apple's nominal value; earlier systems only give the
    /// field of view of a format, so it is derived from the full-sensor photo format.
    static func equivalentFocalLength(of device: AVCaptureDevice) -> Double {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let nominal = Double(device.nominalFocalLengthIn35mmFilm)
            if nominal.isFinite, nominal > 0 { return nominal }
        }
        #endif
        let format = photoFormat(of: device)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        // The field of view runs along the long side, so the sensor's shape matters for the diagonal.
        let aspect = dimensions.width > 0 && dimensions.height > 0 ? Double(dimensions.width) / Double(dimensions.height) : 4.0 / 3.0
        let focal = LensMath.equivalentFocalLength(horizontalFOV: Double(format.videoFieldOfView), aspect: aspect)
        if focal.isFinite, focal > 0 { return focal }
        // Only reached when the format reports no field of view; typical iPhone values keep the zoom maths sane.
        switch kind(of: device) {
        case .ultraWide: return 13
        case .telephoto: return 77
        case .front: return 23
        case .wide, .external: return 24
        }
    }

    /// The format the `.photo` session preset selects: full sensor, highest photo quality. Field of view and
    /// the secondary native zoom factors are read from it so they match what the session will run.
    static func photoFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format {
        device.formats.first { $0.isHighestPhotoQualitySupported } ?? device.activeFormat
    }

    /// f-number at the lens's default opening. Variable apertures (iOS 27) report their resting value.
    static func defaultAperture(of device: AVCaptureDevice) -> Double {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let resting = Double(photoFormat(of: device).defaultLensAperture)
            if resting.isFinite, resting > 0 { return resting }
        }
        #endif
        let fixed = Double(device.lensAperture)
        return fixed.isFinite && fixed > 0 ? fixed : 1.8
    }

    /// Apple labels lenses with round numbers (13 mm on a 24 mm main camera is ".5", 77 mm is "3"), so values
    /// within 10% of one snap to it. Anything else keeps one decimal, like the 2.5x of older telephotos.
    static func roundedZoom(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let marks: [Double] = [0.5, 1, 2, 3, 4, 5, 8, 10]
        if let mark = marks.first(where: { abs(value - $0) / $0 < 0.1 }) { return mark }
        return (value * 10).rounded() / 10
    }

    private static func lensInfo(_ device: AVCaptureDevice, kind: LensInfo.Kind, focal: Double, relativeZoom: Double) -> LensInfo {
        LensInfo(
            id: device.uniqueID,
            kind: kind,
            name: device.localizedName,
            equivalentFocalLength: focal,
            relativeZoom: relativeZoom,
            aperture: defaultAperture(of: device)
        )
    }

    // MARK: - Presets

    private static func makePresets(for cameras: [Camera]) -> [LensPreset] {
        var back: [LensPreset] = cameras.filter { !$0.lens.isFront }.map {
            LensPreset(lensID: $0.lens.id, zoomFactor: 1, displayZoom: $0.lens.relativeZoom)
        }
        // A 48 MP camera reads out its central 12 MP at 2x without upscaling, which the Camera app offers as its
        // own button: "2" on the main camera, "8" on a 48 MP 4x telephoto. Skip it where another button already
        // sits, like a real 2x telephoto, or the main camera's 1x for the ultra wide's crop.
        for camera in cameras where !camera.lens.isFront && offersNativeTwoTimes(camera.device) {
            let display = 2 * camera.lens.relativeZoom
            if !back.contains(where: { abs($0.displayZoom - display) < 0.15 }) {
                back.append(LensPreset(lensID: camera.lens.id, zoomFactor: 2, displayZoom: display))
            }
        }
        back.sort { $0.displayZoom < $1.displayZoom }
        let front = cameras.filter { $0.lens.isFront }.map {
            LensPreset(lensID: $0.lens.id, zoomFactor: 1, displayZoom: 1)
        }
        // Stable merge: at equal display zoom the back camera comes first.
        return (back + front).enumerated().sorted { a, b in
            a.element.displayZoom != b.element.displayZoom ? a.element.displayZoom < b.element.displayZoom : a.offset < b.offset
        }.map(\.element)
    }

    private static func offersNativeTwoTimes(_ device: AVCaptureDevice) -> Bool {
        let format = photoFormat(of: device)
        guard format.videoMaxZoomFactor >= 2 else { return false }
        return format.secondaryNativeResolutionZoomFactors.contains { abs($0 - 2) < 0.01 }
    }
}
