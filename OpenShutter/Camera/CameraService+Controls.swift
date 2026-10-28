import Foundation
import AVFoundation
import CoreMedia
import CameraCore

// Focus, white balance, points of interest, torch, zoom and the device options from Settings, on the session
// queue. Every setter sits behind its support flag: AVFoundation raises an exception for unsupported values.
extension CameraService {
    /// Zoom ramp speed in powers of two per second: as quick as the Camera app's lens buttons, slow enough that
    /// the change doesn't read as a cut.
    nonisolated static let zoomRampRate: Float = 6

    /// A smudge builds up over minutes, so one check a minute catches it at almost no cost.
    nonisolated static let smudgeDetectionInterval = CMTime(value: 60, timescale: 1)

    // MARK: Focus

    nonisolated func applyFocus() {
        // The stack holds focus where it was while it runs, and applies the request again when it ends.
        guard let device = activeCamera?.device, !stackInProgress, Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        switch focusRequest {
        case .continuousAuto:
            if device.focusMode != .continuousAutoFocus, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        case .autoOnce:
            // Setting the mode again starts a new scan at the point of interest, even when it is already set.
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        case .locked:
            if device.focusMode != .locked, device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
        case .manual(let position):
            guard position.isFinite, device.isLockingFocusWithCustomLensPositionSupported,
                  device.isFocusModeSupported(.locked) else { return }
            device.setFocusModeLocked(lensPosition: Float(min(max(position, 0), 1)), completionHandler: nil)
        }
    }

    // MARK: White balance

    nonisolated func applyWhiteBalance() {
        guard let device = activeCamera?.device, !stackInProgress, Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        let customGains = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            && device.isWhiteBalanceModeSupported(.locked)
        switch whiteBalanceRequest {
        case .auto:
            setAutoWhiteBalance(device)
        case .locked:
            guard device.isWhiteBalanceModeSupported(.locked) else {
                setAutoWhiteBalance(device)
                return
            }
            // The current gains are accepted even where custom gains are not.
            lockWhiteBalance(AVCaptureDevice.currentWhiteBalanceGains, device: device, measured: nil)
        case .temperature(let kelvin, let tint):
            guard customGains else {
                setAutoWhiteBalance(device)
                return
            }
            // Any temperature converts (the gains are made legal afterwards), so presets outside the dial's range,
            // like candlelight, keep their value; the bounds only keep nonsense out of the conversion.
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(Self.clamp(kelvin, to: 1000...40_000)),
                tint: Float(Self.clamp(tint, to: WhiteBalanceMath.tintRange))
            )
            lockWhiteBalance(Self.legalGains(device.deviceWhiteBalanceGains(for: values), device: device), device: device,
                             measured: nil)
        case .grayWorld:
            guard customGains else {
                setAutoWhiteBalance(device)
                return
            }
            let gains = Self.legalGains(device.grayWorldDeviceWhiteBalanceGains, device: device)
            let measured = device.temperatureAndTintValues(for: gains)
            lockWhiteBalance(gains, device: device,
                             measured: (kelvin: Double(measured.temperature), tint: Double(measured.tint)))
        }
    }

    /// Device locked.
    nonisolated private func setAutoWhiteBalance(_ device: AVCaptureDevice) {
        // A lock still landing no longer matters.
        whiteBalanceLockGeneration &+= 1
        whiteBalanceLockPending = false
        if device.whiteBalanceMode != .continuousAutoWhiteBalance,
           device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    /// Device locked. Readings report "adjusting" until the gains are in effect, so the model doesn't adopt a
    /// reading taken before the lock. `measured` is the color temperature of a gray world lock.
    nonisolated private func lockWhiteBalance(_ gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice,
                                              measured: (kelvin: Double, tint: Double)?) {
        whiteBalanceLockGeneration &+= 1
        let generation = whiteBalanceLockGeneration
        whiteBalanceLockPending = true
        device.setWhiteBalanceModeLocked(with: gains) { [weak self] _ in
            self?.sessionQueue.async { self?.whiteBalanceLockLanded(generation, measured: measured) }
        }
        // A handler that never comes (the session stopped mid-change) must not leave the readings adjusting.
        sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.whiteBalanceLockLanded(generation, measured: nil)
        }
    }

    nonisolated private func whiteBalanceLockLanded(_ generation: Int, measured: (kelvin: Double, tint: Double)?) {
        guard generation == whiteBalanceLockGeneration else { return }
        whiteBalanceLockPending = false
        // Gray world measures whatever is in front of the lens. Once measured it is a color temperature, which
        // carries over to another lens; measuring again there would pick up a different scene.
        if let measured, case .grayWorld = whiteBalanceRequest {
            whiteBalanceRequest = .temperature(kelvin: measured.kelvin, tint: measured.tint)
        }
    }

    /// Gains the setter accepts: the smallest channel at exactly 1 and none above maxWhiteBalanceGain. The
    /// conversions and the gray world estimate can fall outside that range, and the setter raises for them.
    nonisolated static func legalGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                       device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = max(1, device.maxWhiteBalanceGain)
        let normalized = WhiteBalanceMath.normalized(
            CameraCore.WhiteBalanceGains(red: Double(gains.redGain), green: Double(gains.greenGain), blue: Double(gains.blueGain)),
            maxGain: Double(maxGain)
        )
        let converted = AVCaptureDevice.WhiteBalanceGains(
            redGain: Float(normalized.red), greenGain: Float(normalized.green), blueGain: Float(normalized.blue)
        )
        // Double to Float can land a hair outside the range again.
        return clamped(converted, maxGain: maxGain)
    }

    nonisolated private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Points of interest

    nonisolated func applyPointOfInterest(_ point: CGPoint, focus: Bool, exposure: Bool) {
        guard let device = activeCamera?.device, !stackInProgress, point.x.isFinite, point.y.isFinite else { return }
        let wantsFocus = focus && device.isFocusPointOfInterestSupported
        let wantsExposure = exposure && device.isExposurePointOfInterestSupported
        guard wantsFocus || wantsExposure, Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        // A new point only counts once the mode is set again. Locked and custom modes ignore points; the
        // request that follows the tap sets their mode.
        if wantsFocus {
            device.focusPointOfInterest = clamped
            let mode = device.focusMode
            if mode == .continuousAutoFocus || mode == .autoFocus {
                device.focusMode = mode
            }
        }
        if wantsExposure {
            device.exposurePointOfInterest = clamped
            meteringPointPending = true
            // The new point brought back the camera's own rect around it, which the metering area may replace.
            meteringPoint = clamped
            appliedMeteringRect = nil
            applyMeteringArea(device)
            let mode = device.exposureMode
            if mode == .continuousAutoExposure || mode == .autoExpose {
                device.exposureMode = mode
            }
        }
    }

    // MARK: Stacks

    /// Session queue, at the start of a stack: focus and white balance stay exactly where they are for every
    /// frame. The requests are untouched and come back when the stack ends.
    nonisolated func holdFocusAndWhiteBalance(_ device: AVCaptureDevice) {
        guard Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.locked) {
            // The current position is accepted even on lenses without custom positions.
            device.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition, completionHandler: nil)
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
        }
    }

    // MARK: Torch

    nonisolated func applyTorch() {
        guard let device = activeCamera?.device, device.hasTorch, Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        if let level = torchLevel, level.isFinite, level > 0, device.isTorchModeSupported(.on), device.isTorchAvailable {
            // The setter raises outside (0, 1]; the floor keeps a tiny level from rounding to 0 as a Float.
            let wanted = min(max(Float(level), 0.01), 1)
            do {
                try device.setTorchModeOn(level: wanted)
            } catch {
                // More than a warm torch can give right now; its brightest current level still lights the scene.
                try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            }
        } else if device.torchMode != .off, device.isTorchModeSupported(.off) {
            device.torchMode = .off
        }
    }

    // MARK: Zoom

    nonisolated func applyZoom(animated: Bool) {
        // Zoom belongs to the stack while it runs; the target is applied when it ends.
        guard let device = activeCamera?.device, !stackInProgress else { return }
        // Values outside this range raise; it is also the capabilities' zoom range, so the dial and the device agree.
        let range = CapabilitiesBuilder.zoomRange(of: device)
        let wanted = zoomTarget.isFinite ? min(max(zoomTarget, range.lowerBound), range.upperBound) : range.lowerBound
        let factor = CGFloat(depthSafeZoom(wanted, device: device, within: range))
        guard Self.lockForChanges(device) else { return }
        defer { device.unlockForConfiguration() }
        if animated {
            device.ramp(toVideoZoomFactor: factor, withRate: Self.zoomRampRate)
        } else if device.isRampingVideoZoom || abs(device.videoZoomFactor - factor) > 0.0001 {
            device.videoZoomFactor = factor
        }
        appliedZoomTarget = zoomTarget
    }

    /// With depth delivery on, some formats only allow zoom inside listed ranges and raise outside them.
    nonisolated private func depthSafeZoom(_ factor: Double, device: AVCaptureDevice, within range: ClosedRange<Double>) -> Double {
        guard session.outputs.contains(photoOutput), photoOutput.isDepthDataDeliveryEnabled else { return factor }
        let format = device.activeFormat
        guard !format.zoomFactorsOutsideOfVideoZoomRangesForDepthDeliverySupported else { return factor }
        let allowed = format.supportedVideoZoomRangesForDepthDataDelivery.map { Double($0.lowerBound)...Double($0.upperBound) }
        guard !allowed.isEmpty, !allowed.contains(where: { $0.contains(factor) }) else { return factor }
        let edges = allowed.flatMap { [$0.lowerBound, $0.upperBound] }
        let nearest = edges.min { abs($0 - factor) < abs($1 - factor) } ?? factor
        return min(max(nearest, range.lowerBound), range.upperBound)
    }

    // MARK: Device options

    /// Session queue. Settings-level device preferences, plus the photo output setup that needs a
    /// reconfiguration. Runs after every lens and format change too, because both reset most of these.
    nonisolated func applyDeviceOptions() {
        guard let device = activeCamera?.device, let options = deviceOptions else { return }
        session.beginConfiguration()
        if Self.lockForChanges(device) {
            configure(device, with: options)
            device.unlockForConfiguration()
        }
        if session.outputs.contains(photoOutput) {
            PhotoCaptureCoordinator.configureOutput(photoOutput, options: options, capabilities: sessionCapabilities)
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            attachFocusTrackingOutput(Self.wantsFocusTracking(options, format: device.activeFormat))
        }
        #endif
        session.commitConfiguration()
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            requestTrackedObjects(Self.wantsFocusTracking(options, format: device.activeFormat))
        }
        #endif
    }

    /// Device locked.
    nonisolated private func configure(_ device: AVCaptureDevice, with options: DeviceOptions) {
        let format = device.activeFormat
        var restartExposure = false
        var restartFocus = false

        if CapabilitiesBuilder.supportsAutoExposure(device) {
            switch options.faceDrivenAE {
            case .automatic:
                if !device.automaticallyAdjustsFaceDrivenAutoExposureEnabled {
                    device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
                    restartExposure = true
                }
            case .on, .off:
                // The manual switch raises while the automatic one is on.
                if device.automaticallyAdjustsFaceDrivenAutoExposureEnabled {
                    device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
                    restartExposure = true
                }
                let enabled = options.faceDrivenAE == .on
                if device.isFaceDrivenAutoExposureEnabled != enabled {
                    device.isFaceDrivenAutoExposureEnabled = enabled
                    restartExposure = true
                }
            }
        }
        if CapabilitiesBuilder.supportsAutoFocus(device) {
            switch options.faceDrivenAF {
            case .automatic:
                if !device.automaticallyAdjustsFaceDrivenAutoFocusEnabled {
                    device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = true
                    restartFocus = true
                }
            case .on, .off:
                if device.automaticallyAdjustsFaceDrivenAutoFocusEnabled {
                    device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
                    restartFocus = true
                }
                let enabled = options.faceDrivenAF == .on
                if device.isFaceDrivenAutoFocusEnabled != enabled {
                    device.isFaceDrivenAutoFocusEnabled = enabled
                    restartFocus = true
                }
            }
        }
        if device.isLowLightBoostSupported, device.automaticallyEnablesLowLightBoostWhenAvailable != options.lowLightBoost {
            device.automaticallyEnablesLowLightBoostWhenAvailable = options.lowLightBoost
        }
        // Switching it off is always allowed; it can only be on where the format supports it.
        let toneMapping = options.globalToneMapping && format.isGlobalToneMappingSupported
        if device.isGlobalToneMappingEnabled != toneMapping {
            device.isGlobalToneMappingEnabled = toneMapping
        }
        if format.isVideoHDRSupported {
            switch options.videoHDR {
            case .automatic:
                if !device.automaticallyAdjustsVideoHDREnabled {
                    device.automaticallyAdjustsVideoHDREnabled = true
                }
            case .on, .off:
                // isVideoHDREnabled raises while the device manages it.
                if device.automaticallyAdjustsVideoHDREnabled {
                    device.automaticallyAdjustsVideoHDREnabled = false
                }
                let enabled = options.videoHDR == .on
                if device.isVideoHDREnabled != enabled {
                    device.isVideoHDREnabled = enabled
                }
            }
        }
        if device.isAutoFocusRangeRestrictionSupported {
            let restriction: AVCaptureDevice.AutoFocusRangeRestriction
            switch options.focusRange {
            case .none: restriction = .none
            case .near: restriction = .near
            case .far: restriction = .far
            }
            if device.autoFocusRangeRestriction != restriction {
                device.autoFocusRangeRestriction = restriction
                restartFocus = true
            }
        }
        if device.isSmoothAutoFocusSupported, device.isSmoothAutoFocusEnabled != options.smoothFocus {
            device.isSmoothAutoFocusEnabled = options.smoothFocus
            restartFocus = true
        }
        if device.isGeometricDistortionCorrectionSupported,
           device.isGeometricDistortionCorrectionEnabled != options.geometricCorrection {
            device.isGeometricDistortionCorrectionEnabled = options.geometricCorrection
        }
        #if compiler(>=6.2)
        // A format change switches detection off by itself, which is one reason this runs after every change.
        if #available(iOS 26.0, *), format.isCameraLensSmudgeDetectionSupported,
           device.isCameraLensSmudgeDetectionEnabled != options.smudgeDetection {
            device.setCameraLensSmudgeDetectionEnabled(options.smudgeDetection, detectionInterval: Self.smudgeDetectionInterval)
        }
        #endif
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let tracking = Self.wantsFocusTracking(options, format: format)
            if device.isContinuousAutoFocusTrackingEnabled != tracking {
                device.isContinuousAutoFocusTrackingEnabled = tracking
                restartFocus = true
            }
            if CapabilitiesBuilder.apertureInfo(device: device, format: format).variable {
                let rate = Self.apertureRateLimit(options.apertureRateLimit)
                if device.autoExposureLensApertureRateLimit != rate {
                    device.autoExposureLensApertureRateLimit = rate
                }
            }
        }
        #endif
        // Face detection, focus range, smooth focus and tracking only take effect when the auto mode is set again.
        if restartExposure, device.exposureMode == .continuousAutoExposure {
            device.exposureMode = .continuousAutoExposure
        }
        if restartFocus, device.focusMode == .continuousAutoFocus {
            device.focusMode = .continuousAutoFocus
        }
    }

    /// 0 lets the system choose. Anything else must be at least 1 (1 freezes the iris) or the setter raises;
    /// past 100 times the light per frame there is no limit left to speak of.
    nonisolated static func apertureRateLimit(_ value: Double?) -> Float {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return Float(min(max(value, 1), 100))
    }

    // MARK: Tracking autofocus (iOS 27)

    /// Inside begin/commitConfiguration, before the input or the format changes. The tracked object type comes
    /// and goes with the format, and the output raises for a type it no longer lists.
    nonisolated func clearFocusTrackingTypes() {
        guard let output = metadataOutput, !output.metadataObjectTypes.isEmpty else { return }
        output.metadataObjectTypes = []
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    nonisolated private static func wantsFocusTracking(_ options: DeviceOptions, format: AVCaptureDevice.Format) -> Bool {
        options.continuousAFTracking && format.isContinuousAutoFocusTrackingSupported
    }

    /// Inside begin/commitConfiguration. Tracking autofocus only runs while a metadata output asks for the
    /// tracked object, so the output is in the session exactly while tracking is on.
    @available(iOS 27.0, *)
    nonisolated private func attachFocusTrackingOutput(_ enabled: Bool) {
        if enabled {
            let output = metadataOutput ?? AVCaptureMetadataOutput()
            metadataOutput = output
            guard !session.outputs.contains(output) else { return }
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        } else if let output = metadataOutput, session.outputs.contains(output) {
            output.metadataObjectTypes = []
            session.removeOutput(output)
        }
    }

    /// After commitConfiguration, once the output's available types describe the committed format.
    @available(iOS 27.0, *)
    nonisolated private func requestTrackedObjects(_ enabled: Bool) {
        guard let output = metadataOutput, session.outputs.contains(output) else { return }
        let available = output.availableMetadataObjectTypes.contains(.focusTrackedObject)
        let wanted: [AVMetadataObject.ObjectType] = enabled && available ? [.focusTrackedObject] : []
        if output.metadataObjectTypes != wanted {
            output.metadataObjectTypes = wanted
        }
    }
    #endif
}

extension CameraService: AVCaptureMetadataOutputObjectsDelegate {
    /// Metadata queue. Tracking autofocus needs someone receiving the tracked object to keep running. The object
    /// itself isn't drawn: the reticle marks where the person tapped, as in the Camera app.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {}
}
