import Foundation
import AVFoundation
import UIKit
import CameraCore

/// Records video with AVCaptureMovieFileOutput and saves it to Photos.
final class MovieRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let output = AVCaptureMovieFileOutput()

    /// Thread-safe.
    var isRecording: Bool {
        lock.withLock { activeFile != nil }
    }

    /// Thread-safe. Seconds recorded so far.
    var duration: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock { elapsed(at: now) }
    }

    /// Session queue, after `output` is in the session and the configuration is committed: codec, stabilization
    /// and iOS 27 low light noise reduction for the video connection, limited to what the output and connection
    /// report as available.
    func configureConnection(for settings: VideoSettings) {
        // A file keeps the codec and stabilization it started with.
        guard !isRecording, let connection = output.connection(with: .video) else { return }
        let codec = applyCodec(settings.codec, to: connection)
        applyStabilization(settings.stabilization, to: connection)
        // Last, because the connection's support for it depends on the stabilization mode.
        applyLowLightNoiseReduction(settings.lowLightNoiseReduction, to: connection)
        lock.withLock { configuredCodec = codec }
    }

    /// Session queue. Records to a temporary .mov. `completion` fires once, on the main actor,
    /// after the file is finished and saved to Photos (or failed).
    func start(rotationAngle: CGFloat, location: LocationStamp?, completion: @escaping @MainActor (Result<CaptureResult, Error>) -> Void) {
        guard !isRecording, !output.isRecording else {
            Self.deliver(.failure(CameraError.busy), to: completion)
            return
        }
        // Starting without a live video connection raises an exception instead of reporting an error.
        guard let connection = output.connection(with: .video), connection.isActive, connection.isEnabled else {
            Self.deliver(.failure(CameraError.captureFailed("The camera isn't ready to record yet.")), to: completion)
            return
        }
        let angle = Self.rightAngle(rotationAngle)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        // Also written into the file, so the place survives exports and shares, not only the Photos asset.
        output.metadata = Self.locationMetadata(location)
        let colorMode = Self.recordedColorMode(of: connection)

        let name = "OpenShutter-\(UUID().uuidString).mov"
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let backgroundTime = BackgroundTime()
        DispatchQueue.main.async {
            backgroundTime.begin()
        }
        lock.withLock {
            recordings[name] = Recording(
                location: location,
                date: Date(),
                codec: configuredCodec,
                colorMode: colorMode,
                backgroundTime: backgroundTime,
                completion: completion
            )
            activeFile = name
            startedAt = nil
            finishedDuration = 0
        }
        output.startRecording(to: url, recordingDelegate: self)
    }

    /// Session queue.
    func stop() {
        let now = DispatchTime.now().uptimeNanoseconds
        let wasActive = lock.withLock { () -> Bool in
            guard activeFile != nil else { return false }
            finishedDuration = elapsed(at: now)
            activeFile = nil
            startedAt = nil
            return true
        }
        if wasActive || output.isRecording {
            output.stopRecording()
        }
    }

    /// Marks the moment samples start reaching the file, so `duration` doesn't count pipeline start-up.
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let name = fileURL.lastPathComponent
        lock.withLock {
            if activeFile == name, startedAt == nil {
                startedAt = now
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let now = DispatchTime.now().uptimeNanoseconds
        // Matched by file name: the URL handed back may spell the temporary directory differently.
        let name = outputFileURL.lastPathComponent
        let recording = lock.withLock { () -> Recording? in
            if activeFile == name {
                // Stopped by the system (interruption, full disk, time limit) rather than by stop().
                finishedDuration = elapsed(at: now)
                activeFile = nil
                startedAt = nil
            }
            return recordings.removeValue(forKey: name)
        }
        guard let recording else {
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = await Self.finish(file: outputFileURL, recording: recording, error: error)
            await recording.completion(result)
            await recording.backgroundTime.end()
        }
    }

    // MARK: - State

    /// Unchecked because of `completion`: a main actor closure only ever runs on the main actor, so handing it
    /// to the delegate's queue and back is safe even though its function type isn't marked Sendable.
    private struct Recording: @unchecked Sendable {
        var location: LocationStamp?
        var date: Date
        var codec: VideoCodecChoice?
        var colorMode: VideoColorMode
        var backgroundTime: BackgroundTime
        var completion: @MainActor (Result<CaptureResult, Error>) -> Void
    }

    /// Leaving the app ends a recording, and iOS suspends a backgrounded app within seconds, while finishing a long
    /// file and saving it can take longer. Held from the start of a recording until its result is delivered.
    private final class BackgroundTime: @unchecked Sendable {
        /// Main actor only.
        private var identifier = UIBackgroundTaskIdentifier.invalid

        @MainActor func begin() {
            guard identifier == .invalid else { return }
            identifier = UIApplication.shared.beginBackgroundTask(withName: "Save movie") { [weak self] in
                // Out of time: the save resumes when the app comes back, and ending here keeps iOS from killing it.
                self?.end()
            }
        }

        @MainActor func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    private let lock = NSLock()
    /// Every recording whose file hasn't been delivered yet, by file name. A stopped file can still be
    /// finishing while the next one starts.
    private var recordings: [String: Recording] = [:]
    /// File name of the recording in progress.
    private var activeFile: String?
    /// Uptime in nanoseconds when the first samples were written.
    private var startedAt: UInt64?
    /// Length of the last recording, shown until the next one starts.
    private var finishedDuration: TimeInterval = 0
    private var configuredCodec: VideoCodecChoice?

    /// Caller holds the lock.
    private func elapsed(at now: UInt64) -> TimeInterval {
        guard activeFile != nil else { return finishedDuration }
        guard let startedAt, now > startedAt else { return 0 }
        return Double(now - startedAt) / 1_000_000_000
    }

    // MARK: - Connection setup

    /// The requested codec when the output lists it, else HEVC, else H.264, else the output's own default.
    /// Returns the codec that will record, when it is one of ours.
    private func applyCodec(_ choice: VideoCodecChoice, to connection: AVCaptureConnection) -> VideoCodecChoice? {
        // Keys the connection doesn't list raise an exception, so the codec key is checked like the codec.
        guard output.supportedOutputSettingsKeys(for: connection).contains(AVVideoCodecKey) else { return nil }
        let available = output.availableVideoCodecTypes
        for candidate in [choice, .hevc, .h264] where available.contains(Self.codecType(candidate)) {
            output.setOutputSettings([AVVideoCodecKey: Self.codecType(candidate)], for: connection)
            return candidate
        }
        // A codec picked for an earlier format may not exist on this one; nil restores the default.
        output.setOutputSettings(nil, for: connection)
        return nil
    }

    private static func codecType(_ choice: VideoCodecChoice) -> AVVideoCodecType {
        switch choice {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes4444: return .proRes4444
        }
    }

    /// The first mode in the choice's fallback list that the active format supports, else off.
    private func applyStabilization(_ choice: StabilizationChoice, to connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else { return }
        if choice == .automatic {
            // Auto asks the system to pick among the modes this format supports, so there is nothing to check.
            connection.preferredVideoStabilizationMode = .auto
            return
        }
        guard let format = Self.sourceDevice(of: connection)?.activeFormat else { return }
        let mode = Self.stabilizationCandidates(for: choice).first { format.isVideoStabilizationModeSupported($0) } ?? .off
        connection.preferredVideoStabilizationMode = mode
    }

    /// Strongest first, falling back to milder modes when the format can't do the one asked for.
    private static func stabilizationCandidates(for choice: StabilizationChoice) -> [AVCaptureVideoStabilizationMode] {
        switch choice {
        case .off, .automatic:
            return [.off]
        case .standard:
            return [.standard]
        case .cinematic:
            return [.cinematic, .standard]
        case .cinematicExtended:
            return [.cinematicExtended, .cinematic, .standard]
        case .cinematicExtendedEnhanced:
            return [.cinematicExtendedEnhanced, .cinematicExtended, .cinematic, .standard]
        case .previewOptimized:
            // Apple only runs preview optimized stabilization on preview connections; a movie file would come
            // out unstabilized, so the recording gets standard instead.
            return [.standard]
        case .lowLatency:
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                return [.lowLatency, .standard]
            }
            #endif
            return [.standard]
        }
    }

    /// iOS 27 movie connections switch noise reduction on by themselves at every commit, which would ignore the
    /// setting; turning the automatic behaviour off first is also what makes the setter legal.
    private func applyLowLightNoiseReduction(_ wanted: Bool, to connection: AVCaptureConnection) {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            connection.automaticallyEnablesLowLightVideoNoiseReduction = false
            // Turning it on where the connection doesn't support it raises an exception.
            let enable = wanted && connection.isLowLightVideoNoiseReductionSupported
            if connection.isLowLightVideoNoiseReductionEnabled != enable {
                connection.isLowLightVideoNoiseReductionEnabled = enable
            }
        }
        #endif
    }

    private static func sourceDevice(of connection: AVCaptureConnection) -> AVCaptureDevice? {
        for port in connection.inputPorts {
            if let input = port.input as? AVCaptureDeviceInput, input.device.hasMediaType(.video) {
                return input.device
            }
        }
        return nil
    }

    /// Read from the camera rather than the settings: without an HDR or Log variant of the chosen size and
    /// frame rate, the camera records SDR, and Apple Log 2 may have stepped down to Apple Log.
    private static func recordedColorMode(of connection: AVCaptureConnection) -> VideoColorMode {
        guard let space = sourceDevice(of: connection)?.activeColorSpace else { return .sdr }
        if space == .HLG_BT2020 { return .hdr }
        if space == .appleLog { return .appleLog }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), space == .appleLog2 { return .appleLog2 }
        #endif
        return .sdr
    }

    /// The connection only takes 0, 90, 180 or 270.
    private static func rightAngle(_ degrees: CGFloat) -> CGFloat {
        guard degrees.isFinite else { return 0 }
        let snapped = ((degrees / 90).rounded() * 90).truncatingRemainder(dividingBy: 360)
        return snapped < 0 ? snapped + 360 : snapped
    }

    /// QuickTime location metadata, the ISO 6709 string the Camera app writes ("+37.3349-122.0090+012.300/").
    private static func locationMetadata(_ location: LocationStamp?) -> [AVMetadataItem]? {
        guard let location, location.latitude.isFinite, location.longitude.isFinite,
              abs(location.latitude) <= 90, abs(location.longitude) <= 180 else { return nil }
        var text = String(format: "%+08.4f%+09.4f", location.latitude, location.longitude)
        if location.altitude.isFinite {
            text += String(format: "%+.3f", location.altitude)
        }
        text += "/"
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.value = text as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [item]
    }

    // MARK: - Finishing

    private static func deliver(_ result: Result<CaptureResult, Error>, to completion: @escaping @MainActor (Result<CaptureResult, Error>) -> Void) {
        Task { @MainActor in
            completion(result)
        }
    }

    /// Thumbnail and summary first, because saving moves the file into the library.
    private static func finish(file: URL, recording: Recording, error: Error?) async -> Result<CaptureResult, Error> {
        if let error, !finishedCleanly(error) {
            try? FileManager.default.removeItem(at: file)
            return .failure(CameraError.captureFailed(reason(for: error)))
        }
        let asset = AVURLAsset(url: file)
        let thumbnail = await thumbnail(of: asset)
        let summary = await summary(of: asset, codec: recording.codec, colorMode: recording.colorMode)
        do {
            let identifier = try await PhotoLibrary.saveVideo(at: file, location: recording.location)
            return .success(CaptureResult(
                kind: .video,
                assetIdentifier: identifier,
                thumbnail: thumbnail,
                summary: summary,
                date: recording.date,
                savedToLibrary: true
            ))
        } catch {
            // The app has no other place to show a clip, so a failed save would only leave it filling the disk.
            try? FileManager.default.removeItem(at: file)
            return .failure(error)
        }
    }

    /// Recordings cut short by a full disk, a time limit or an interruption still produce a playable file,
    /// which AVFoundation flags in the error's user info.
    private static func finishedCleanly(_ error: Error) -> Bool {
        let value = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey]
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func reason(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == AVFoundationErrorDomain else { return nsError.localizedDescription }
        switch nsError.code {
        case AVError.Code.diskFull.rawValue:
            return "There isn't enough free storage to record."
        case AVError.Code.sessionWasInterrupted.rawValue:
            return "Recording was interrupted."
        case AVError.Code.mediaServicesWereReset.rawValue:
            return "The camera restarted while recording."
        default:
            return nsError.localizedDescription
        }
    }

    private static func thumbnail(of asset: AVURLAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        // The rotation lives in the track transform, not in the pixels.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        return try? await generator.image(at: .zero).image
    }

    /// "4K · 30 fps · HEVC · HDR · 0:12", from the finished file rather than the request, since the camera may
    /// have fallen back to the nearest format it has.
    private static func summary(of asset: AVURLAsset, codec: VideoCodecChoice?, colorMode: VideoColorMode) async -> String {
        var parts: [String] = []
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, frameRate) = try? await track.load(.naturalSize, .nominalFrameRate) {
            let width = Int(abs(size.width).rounded())
            let height = Int(abs(size.height).rounded())
            if width > 0, height > 0 {
                parts.append(Formatting.resolution(width: width, height: height))
            }
            if frameRate.isFinite, frameRate > 0 {
                parts.append(Formatting.frameRate(Double(frameRate)))
            }
        }
        if let codec {
            parts.append(codec.title)
        }
        if colorMode != .sdr {
            parts.append(colorMode.title)
        }
        if let length = try? await asset.load(.duration), length.isNumeric, length.seconds > 0 {
            parts.append(Formatting.clock(length.seconds))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
