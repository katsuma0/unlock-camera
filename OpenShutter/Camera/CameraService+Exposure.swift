import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import CameraCore

// Exposure runs on the session queue with the device locked. Auto and AE lock use the device's own modes,
// fixed values use custom exposure, and mixes of fixed and auto values ("priority" modes) run in hardware on
// iOS 27 where the format accepts the combination, through CameraCore.SoftwareAE everywhere else.
extension CameraService {
    /// What an exposure request comes down to on the active camera.
    private enum ExposureTarget {
        case auto(locked: Bool)
        /// Every parameter fixed. A nil aperture means the lens's own opening.
        case manual(seconds: Double, iso: Double, aperture: Double?)
        /// nil members are left to auto exposure.
        case priority(ExposureLocks)
    }

    /// Session queue. Applies `exposureRequest` to the active camera.
    nonisolated func applyExposure() {
        // Replaces any exposure still on its way: its completion handler must leave the device alone, and what the end
        // of a stack asked for no longer stands in for the device's report.
        exposureGeneration &+= 1
        restoreTarget = nil
        // The stack owns exposure while it runs, and applies the request again when it ends.
        guard let camera = activeCamera, !stackInProgress else { return }
        let device = camera.device
        let request = exposureRequest
        let format = device.activeFormat
        let target = Self.exposureTarget(
            for: request,
            format: format,
            variableAperture: CapabilitiesBuilder.apertureInfo(device: device, format: format).variable,
            customSupported: device.isExposureModeSupported(.custom)
        )
        switch target {
        case .auto(let locked):
            stopSoftwareAE()
            applyAutoExposure(request, locked: locked, device: device)
        case .manual(let seconds, let iso, let aperture):
            stopSoftwareAE()
            applyManualExposure(seconds: seconds, iso: iso, aperture: aperture, bias: request.bias, device: device)
        case .priority(let locks):
            if applyNativePriority(locks, request: request, device: device) {
                stopSoftwareAE()
            } else {
                startSoftwareAE(locks, request: request, device: device)
            }
        }
    }

    nonisolated private static func exposureTarget(for request: ExposureRequest, format: AVCaptureDevice.Format,
                                                   variableAperture: Bool, customSupported: Bool) -> ExposureTarget {
        var locks = request.locks
        // A fixed iris has nothing to lock.
        if !variableAperture { locks.aperture = nil }
        guard customSupported, !locks.isAllAuto else { return .auto(locked: request.aeLocked) }
        // Past the longest frame the sensor takes, the shot is stacked. The preview then runs at the longest frame
        // and makes up the missing stops with ISO, so it looks like the merged result.
        let longest = CapabilitiesBuilder.secondsRange(of: format).upperBound
        if let seconds = locks.seconds, seconds > longest {
            locks.seconds = longest
            locks.iso = locks.iso.map { $0 * seconds / longest }
        }
        if let seconds = locks.seconds, let iso = locks.iso, locks.aperture != nil || !variableAperture {
            return .manual(seconds: seconds, iso: iso, aperture: locks.aperture)
        }
        return .priority(locks)
    }

    // MARK: Auto and manual

    nonisolated private func applyAutoExposure(_ request: ExposureRequest, locked: Bool, device: AVCaptureDevice) {
        restoreFrameDurations(unlessLongerThan: nil)
        guard Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        applyAutoExposureLimit(request.maxAutoSeconds, device: device)
        // A lock held in custom mode, as after a stack, becomes the device's own lock before the bias goes on: custom
        // mode would apply the bias to the meter alone.
        if locked, !meteringPointPending, device.exposureMode == .custom, device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        // In the auto modes and while locked, the bias changes the exposure itself.
        applyBias(request.bias, device: device)
        let meterFirst = meteringPointPending
        meteringPointPending = false
        if locked {
            if meterFirst, device.isExposureModeSupported(.autoExpose) {
                // A lock right after a tap or a lens change meters once at the point and then holds, like AE/AF
                // LOCK in the Camera app. Locking at once would freeze an exposure metered somewhere else.
                applyMeteringArea(device)
                device.exposureMode = .autoExpose
            } else if device.exposureMode != .locked, device.exposureMode != .autoExpose,
                      device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            let areaMoved = applyMeteringArea(device)
            // A moved rect only takes effect once the mode is set, even to the mode the device already has.
            if areaMoved || device.exposureMode != .continuousAutoExposure {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    nonisolated private func applyManualExposure(seconds: Double, iso: Double, aperture: Double?, bias: Double,
                                                 device: AVCaptureDevice) {
        let format = device.activeFormat
        guard let duration = Self.clampedDuration(seconds, in: format) else { return }
        let gain = Self.clampedISO(iso, in: format)
        restoreFrameDurations(unlessLongerThan: duration)
        guard Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        // In custom mode the bias only moves the meter, which is exactly what a manual camera's meter does.
        applyBias(bias, device: device)
        meteringPointPending = false
        setCustomExposure(duration: duration, iso: gain, aperture: aperture, device: device, completion: nil)
    }

    /// iOS 27 runs a priority mode in hardware when the format accepts the combination. false means the caller
    /// has to run it in software.
    nonisolated private func applyNativePriority(_ locks: ExposureLocks, request: ExposureRequest,
                                                 device: AVCaptureDevice) -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let format = device.activeFormat
            var duration = AVCaptureDevice.autoExposureDuration
            if let seconds = locks.seconds {
                guard let locked = Self.clampedDuration(seconds, in: format) else { return false }
                duration = locked
            }
            let iso = locks.iso.map { Self.clampedISO($0, in: format) } ?? AVCaptureDevice.autoISO
            var aperture = AVCaptureDevice.autoLensAperture
            if let fNumber = locks.aperture {
                guard let locked = Self.clampedAperture(fNumber, in: format) else { return false }
                aperture = locked
            }
            // An unsupported combination raises NSInvalidArgumentException, so it is asked first.
            guard format.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) else { return false }
            // Auto exposure keeps streaming frames within activeMaxExposureDuration here, so stretched frames end.
            restoreFrameDurations(unlessLongerThan: nil)
            // A failed lock is another app holding the camera for a moment; the next request tries again, and
            // falling back to the software loop would not get the lock either.
            guard Self.lockForChanges(device) else { return true }
            defer { device.unlockForConfiguration() }
            applyAutoExposureLimit(request.maxAutoSeconds, device: device)
            applyBias(request.bias, device: device)
            meteringPointPending = false
            // The auto parameters follow the meter; setting the mode right after puts a moved rect into effect.
            applyMeteringArea(device)
            device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: nil)
            return true
        }
        #endif
        return false
    }

    // MARK: Software priority loop

    nonisolated private func startSoftwareAE(_ locks: ExposureLocks, request: ExposureRequest, device: AVCaptureDevice) {
        if Self.lockForChanges(device) {
            // Custom mode applies the bias only to the meter, and the loop follows the meter: that is how
            // compensation reaches the auto parameters.
            applyBias(request.bias, device: device)
            // The loop falls back to the device's own limit when the request has none, so a limit an earlier
            // request set must not linger there.
            applyAutoExposureLimit(request.maxAutoSeconds, device: device)
            // The loop steers by the meter, so it meters where the setting says; the first step sets the mode.
            applyMeteringArea(device)
            device.unlockForConfiguration()
        }
        meteringPointPending = false
        softwareAELocks = locks
        // The locked values take effect now; the timer then keeps the auto ones on the meter.
        softwareAEStep(force: true)
        guard softwareAETimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.softwareAEStep(force: false)
        }
        timer.resume()
        softwareAETimer = timer
    }

    /// Session queue. Stops the software priority loop; the device keeps its last values.
    nonisolated func stopSoftwareAE() {
        softwareAETimer?.cancel()
        softwareAETimer = nil
        softwareAELocks = nil
    }

    /// One step of the loop. A timer step follows the meter. A forced step comes with a new request: it applies
    /// the locks at once and moves the auto parameters to keep the current brightness, because the meter still
    /// describes the frames before the change and following it now would overshoot. It also applies when the
    /// result is close, since the device may still be in an auto mode that would ignore the locks.
    nonisolated private func softwareAEStep(force: Bool) {
        guard let locks = softwareAELocks, let camera = activeCamera, !stackInProgress else { return }
        let device = camera.device
        let now = CACurrentMediaTime()
        if !force {
            // The meter needs a few frames to see the last change; stepping sooner would overshoot.
            guard now >= softwareAENextStep, session.isRunning, !session.isInterrupted else { return }
        }
        // After a stack the brightness to keep is the preview's from before it, not the stack's own frame.
        guard let current = (force ? softwareAEStart : nil) ?? Self.currentExposure(of: device) else { return }
        let format = device.activeFormat
        let ranges = softwareAERanges(device: device, format: format)
        let focalLength = camera.lens.equivalentFocalLength * max(Double(device.videoZoomFactor), 1)
        let offset = Double(device.exposureTargetOffset)
        let handheld = ExposureMath.handheldLimit(equivalentFocalLength: focalLength)
        let next = force
            // No dead band, so the auto parameters are solved for the current light even at a zero offset.
            ? SoftwareAE.step(current: current, meterOffset: 0, locks: locks, ranges: ranges, handheldLimit: handheld,
                              deadband: 0)
            : SoftwareAE.step(current: current, meterOffset: offset.isFinite ? offset : 0, locks: locks, ranges: ranges,
                              handheldLimit: handheld)
        // Smaller steps are invisible and would only make the preview shimmer.
        guard force || Self.stopsApart(current, next) > 1.0 / 12 else { return }
        guard let duration = Self.clampedDuration(next.seconds, in: format) else { return }
        let iso = Self.clampedISO(next.iso, in: format)
        // The iris only gets an explicit value when it is locked or the loop moved it; otherwise it stays put.
        let movesIris = ranges.hasVariableAperture
            && (locks.aperture != nil || Self.stops(current.aperture, next.aperture, weight: 2) > 0.01)
        restoreFrameDurations(unlessLongerThan: duration)
        guard Self.lockForChanges(device) else { return }
        var landed: (@Sendable (CMTime) -> Void)?
        if force, softwareAEStart != nil {
            // The first step after a stack; the device reports the stack's frame until this is in effect.
            restoreTarget = ExposureValues(seconds: duration.seconds, iso: Double(iso),
                                           aperture: movesIris ? next.aperture : current.aperture)
            let generation = exposureGeneration
            landed = { [weak self] _ in
                self?.sessionQueue.async { self?.restoreLanded(generation) }
            }
        }
        setCustomExposure(duration: duration, iso: iso, aperture: movesIris ? next.aperture : nil, device: device,
                          completion: landed)
        device.unlockForConfiguration()
        softwareAENextStep = now + max(0.25, max(next.seconds, 1.0 / 30) * 3)
    }

    /// Ranges of the active format, with the AE shutter limit from the request or the device's own default.
    nonisolated private func softwareAERanges(device: AVCaptureDevice, format: AVCaptureDevice.Format) -> ExposureRanges {
        let limit = exposureRequest.maxAutoSeconds
            ?? CapabilitiesBuilder.seconds(device.activeMaxExposureDuration, rounding: .down)
        return ExposureRanges(
            seconds: CapabilitiesBuilder.secondsRange(of: format),
            iso: CapabilitiesBuilder.isoRange(of: format),
            aperture: CapabilitiesBuilder.apertureInfo(device: device, format: format).range,
            maxAutoSeconds: limit
        )
    }

    nonisolated static func currentExposure(of device: AVCaptureDevice) -> ExposureValues? {
        let seconds = device.exposureDuration.seconds
        let iso = Double(device.iso)
        let aperture = Double(device.lensAperture)
        guard seconds.isFinite, seconds > 0, iso.isFinite, iso > 0, aperture.isFinite, aperture > 0 else { return nil }
        return ExposureValues(seconds: seconds, iso: iso, aperture: aperture)
    }

    /// The largest difference between two exposures, parameter by parameter, in stops.
    nonisolated private static func stopsApart(_ a: ExposureValues, _ b: ExposureValues) -> Double {
        max(stops(a.seconds, b.seconds, weight: 1), stops(a.iso, b.iso, weight: 1), stops(a.aperture, b.aperture, weight: 2))
    }

    /// Light goes with the square of the f-number's inverse, hence the weight of 2 for apertures.
    nonisolated private static func stops(_ a: Double, _ b: Double, weight: Double) -> Double {
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { return .infinity }
        return abs(log2(b / a)) * weight
    }

    // MARK: Metering area

    /// Device locked. Sets the iOS 26 exposure rect of interest for the metering area setting: the camera's own rect
    /// around the point of interest, the smallest rect it takes there, or the whole frame. true when the rect
    /// changed, which only takes effect once the exposure mode is set again.
    @discardableResult
    nonisolated func applyMeteringArea(_ device: AVCaptureDevice) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard device.isExposureRectOfInterestSupported else { return false }
            let minimum = device.minExposureRectOfInterestSize
            let area = deviceOptions?.meteringArea ?? .automatic
            guard let wanted = area.rectOfInterest(centerX: Double(meteringPoint.x), centerY: Double(meteringPoint.y),
                                                   minWidth: Double(minimum.width), minHeight: Double(minimum.height)) else {
                // Setting the point again brings back the camera's own rect; only a rect set here has to go.
                guard appliedMeteringRect != nil, device.isExposurePointOfInterestSupported else { return false }
                appliedMeteringRect = nil
                device.exposurePointOfInterest = meteringPoint
                return true
            }
            let rect = CGRect(x: wanted.x, y: wanted.y, width: wanted.width, height: wanted.height)
            // Compared with what was set rather than read back, which the camera may round: setting the mode again
            // for nothing would restart auto exposure.
            if let applied = appliedMeteringRect, Self.isSameRect(applied, rect) { return false }
            device.exposureRectOfInterest = rect
            appliedMeteringRect = rect
            return true
        }
        #endif
        return false
    }

    /// A ten-thousandth of the frame is far below anything the meter can tell apart.
    nonisolated private static func isSameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-4 && abs(a.minY - b.minY) < 1e-4
            && abs(a.width - b.width) < 1e-4 && abs(a.height - b.height) < 1e-4
    }

    // MARK: Stacks

    /// Session queue. Locks exposure to one frame of the stack plan. `completion` receives the device-clock time
    /// of the first frame exposed with it. false when the camera can't take a custom exposure right now.
    nonisolated func applyStackExposure(_ plan: StackPlan, device: AVCaptureDevice,
                                        completion: @escaping @Sendable (CMTime) -> Void) -> Bool {
        guard device.isExposureModeSupported(.custom) else { return false }
        let format = device.activeFormat
        guard let duration = Self.clampedDuration(plan.frameSeconds, in: format) else { return false }
        let iso = Self.clampedISO(plan.iso, in: format)
        guard Self.lockForChanges(device) else { return false }
        defer { device.unlockForConfiguration() }
        // The stack replaces any exposure still on its way.
        exposureGeneration &+= 1
        restoreTarget = nil
        let variable = CapabilitiesBuilder.apertureInfo(device: device, format: format).variable
        setCustomExposure(duration: duration, iso: iso, aperture: variable ? plan.aperture : nil, device: device,
                          completion: completion)
        return true
    }

    /// Session queue, as a stack ends under an AE lock: holds `values`, the exposure the lock had before the stack.
    /// Custom mode sets them exactly, and once they are in effect the device's own lock takes them over
    /// (heldExposureLanded). false when the camera can't take them; the caller then applies the request.
    nonisolated func holdExposure(_ values: ExposureValues) -> Bool {
        guard let device = activeCamera?.device, !stackInProgress, device.isExposureModeSupported(.custom) else { return false }
        let format = device.activeFormat
        guard let duration = Self.clampedDuration(values.seconds, in: format) else { return false }
        let iso = Self.clampedISO(values.iso, in: format)
        stopSoftwareAE()
        guard Self.lockForChanges(device) else { return false }
        defer { device.unlockForConfiguration() }
        meteringPointPending = false
        exposureGeneration &+= 1
        let generation = exposureGeneration
        // The device reports the stack's frame until the hold is in effect.
        restoreTarget = ExposureValues(seconds: duration.seconds, iso: Double(iso), aperture: values.aperture)
        let landed: @Sendable (CMTime) -> Void = { [weak self] _ in
            self?.sessionQueue.async { self?.heldExposureLanded(generation) }
        }
        let variable = CapabilitiesBuilder.apertureInfo(device: device, format: format).variable
        setCustomExposure(duration: duration, iso: iso, aperture: variable ? values.aperture : nil, device: device,
                          completion: landed)
        return true
    }

    /// Session queue: what the end of a stack asked for is in effect, so the device reports it itself from here on.
    /// false when a newer exposure replaced it.
    @discardableResult
    nonisolated private func restoreLanded(_ generation: Int) -> Bool {
        guard generation == exposureGeneration else { return false }
        restoreTarget = nil
        return true
    }

    /// Session queue, once a hold is in effect. Custom mode would apply a bias change to the meter alone, so the hold
    /// becomes the device's own lock, which keeps the same values.
    nonisolated private func heldExposureLanded(_ generation: Int) {
        guard restoreLanded(generation), exposureRequest.aeLocked, !stackInProgress, softwareAELocks == nil,
              !meteringPointPending, let device = activeCamera?.device, device.exposureMode == .custom,
              device.isExposureModeSupported(.locked), Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        device.exposureMode = .locked
    }

    // MARK: Device helpers

    /// Device locked. Explicit values only; a nil aperture leaves the iris where it is.
    nonisolated private func setCustomExposure(duration: CMTime, iso: Float, aperture: Double?, device: AVCaptureDevice,
                                               completion: (@Sendable (CMTime) -> Void)?) {
        noteFrameDurationStretch(duration, device: device)
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), let aperture, let fNumber = Self.clampedAperture(aperture, in: device.activeFormat),
           device.activeFormat.supportsExposureModeCustom(lensAperture: fNumber, duration: duration, iso: iso) {
            device.setExposureModeCustom(lensAperture: fNumber, duration: duration, iso: iso, completionHandler: completion)
            return
        }
        #endif
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: completion)
    }

    /// Device locked. nil gives the limit back to the device's default for the format.
    nonisolated private func applyAutoExposureLimit(_ seconds: Double?, device: AVCaptureDevice) {
        guard let seconds, let limit = Self.clampedDuration(seconds, in: device.activeFormat) else {
            if autoExposureLimitSet {
                device.activeMaxExposureDuration = .invalid
                autoExposureLimitSet = false
            }
            return
        }
        if !autoExposureLimitSet || CMTimeCompare(device.activeMaxExposureDuration, limit) != 0 {
            device.activeMaxExposureDuration = limit
            autoExposureLimitSet = true
        }
    }

    /// Device locked. Written only when the request's bias changes (see `appliedBiasRequest`).
    /// setExposureTargetBias raises outside the device's bias range.
    nonisolated private func applyBias(_ bias: Double, device: AVCaptureDevice) {
        guard bias != appliedBiasRequest else { return }
        let lower = device.minExposureTargetBias
        let upper = device.maxExposureTargetBias
        guard lower <= upper else { return }
        let value = min(max(bias.isFinite ? Float(bias) : 0, lower), upper)
        if abs(device.exposureTargetBias - value) > 0.001 {
            device.setExposureTargetBias(value, completionHandler: nil)
        }
        appliedBiasRequest = bias
    }

    /// Device locked, just before a custom duration is set. A duration longer than the longest frame stretches
    /// the frame duration, and the device keeps it stretched until told otherwise.
    nonisolated private func noteFrameDurationStretch(_ duration: CMTime, device: AVCaptureDevice) {
        guard frameDurationRestoreLimit == nil else { return }
        let longestFrame = device.activeVideoMaxFrameDuration
        guard longestFrame.isNumeric, CMTimeCompare(duration, longestFrame) > 0 else { return }
        frameDurationRestoreLimit = longestFrame.seconds
    }

    /// Device not locked. Gives the format its own frame durations back once exposures fit in them again,
    /// otherwise the preview stays at the slideshow rate of the last long exposure.
    nonisolated private func restoreFrameDurations(unlessLongerThan duration: CMTime?) {
        guard let limit = frameDurationRestoreLimit else { return }
        if let duration, duration.seconds > limit { return }
        applyFrameRateLimits()
    }

    /// lockForConfiguration fails while another app holds the camera; the next request tries again.
    nonisolated static func lockForChanges(_ device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    /// The format's nearest legal duration. Built and clamped as CMTime, because the setters raise
    /// NSRangeException for values a round trip through seconds can push just outside the range.
    nonisolated static func clampedDuration(_ seconds: Double, in format: AVCaptureDevice.Format) -> CMTime? {
        let shortest = format.minExposureDuration
        let longest = format.maxExposureDuration
        guard shortest.isNumeric, longest.isNumeric, CMTimeCompare(shortest, longest) <= 0, !seconds.isNaN else { return nil }
        let bounded = min(max(seconds, shortest.seconds), longest.seconds)
        let wanted = CMTime(seconds: bounded, preferredTimescale: 1_000_000_000)
        guard wanted.isNumeric else { return nil }
        return CMTimeMinimum(CMTimeMaximum(wanted, shortest), longest)
    }

    nonisolated static func clampedISO(_ iso: Double, in format: AVCaptureDevice.Format) -> Float {
        let lowest = format.minISO
        let highest = max(format.maxISO, lowest)
        guard !iso.isNaN else { return lowest }
        return min(max(Float(iso), lowest), highest)
    }

    #if compiler(>=6.4)
    /// nil when the format reports no usable aperture range.
    @available(iOS 27.0, *)
    nonisolated static func clampedAperture(_ fNumber: Double, in format: AVCaptureDevice.Format) -> Float? {
        let widest = format.minLensAperture
        let narrowest = format.maxLensAperture
        guard widest > 0, narrowest >= widest, fNumber.isFinite else { return nil }
        return min(max(Float(fNumber), widest), narrowest)
    }
    #endif
}
