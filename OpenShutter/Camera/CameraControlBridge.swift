import Foundation
import AVFoundation
import CameraCore

/// Puts shutter, ISO, aperture, white balance and focus on the iPhone 16+ Camera Control
/// (the hardware button's light-press overlay), next to Apple's system zoom and exposure sliders.
final class CameraControlBridge: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    /// Called on the controls queue when the user moves one of our controls.
    var onChange: (@Sendable (CameraControlChange) -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    /// Called on the controls queue when the overlay enters or leaves its fullscreen appearance.
    var onFullscreenChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { fullscreenHandler } }
        set { lock.withLock { fullscreenHandler = newValue } }
    }

    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /// Session queue, inside begin/commitConfiguration. Replaces all controls on `session` with ones for
    /// `state`. Does nothing when the session doesn't support controls.
    func install(on session: AVCaptureSession, device: AVCaptureDevice, state: CameraControlState) {
        guard session.supportsControls else {
            lock.withLock {
                layout = nil
                entries = []
                pendingEcho = [:]
                currentDevice = nil
            }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let wanted = Self.layout(for: state, device: device, session: session)
        let installed = lock.withLock { () -> [Entry]? in
            latestState = state
            stateArrival = now
            currentDevice = device
            return layout == wanted ? entries : nil
        }

        // A new state can arrive while a finger is still on the button (a closing dial, a pick that changed the
        // mode). Rebuilding then would reset the overlay under it, so unchanged controls only get new values.
        if let installed, Self.isInstalled(installed, on: session) {
            scheduleValues(from: state, for: installed, device: device, sparingRecentTouches: true)
            attachDelegate(to: session)
            return
        }

        for control in session.controls {
            session.removeControl(control)
        }
        var added: [Entry] = []
        let limit = session.maxControlsCount
        for item in wanted.items where added.count < limit {
            let entry = makeEntry(for: item, layout: wanted, device: device)
            guard session.canAddControl(entry.control) else { continue }
            session.addControl(entry.control)
            added.append(entry)
        }
        lock.withLock {
            layout = wanted
            entries = added
            lastTouch = [:]
            pendingEcho = [:]
        }
        scheduleValues(from: state, for: added, device: device, sparingRecentTouches: false)
        attachDelegate(to: session)
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        let snapshot = lock.withLock {
            (state: latestState, entries: entries, arrival: stateArrival, touches: lastTouch, device: currentDevice)
        }
        guard let state = snapshot.state else { return }
        // The model takes a value picked here without sending its state back, so a control moved since the latest
        // state already shows the right value and that older state would pull it back. A mode or lens it accepts
        // always comes back as a new state (a new mode, or a new active lens button), so those two pickers follow
        // the state, which also undoes a pick refused while busy. In PHOTO and NIGHT every accepted value pick
        // switches to MANUAL, which also sends a newer state, so there a control touched since the state can only
        // be showing a refused pick, and every control follows the state. Every other control is brought up to
        // date, which restores updates skipped under a finger.
        let autoMode = state.mode == .photo || state.mode == .night
        let behind = snapshot.entries.filter { entry in
            entry.item == .mode || entry.item == .lens || autoMode
                || (snapshot.touches[entry.item] ?? 0) <= snapshot.arrival
        }
        applyValues(Self.targets(from: state, for: behind, device: snapshot.device), sparingRecentTouches: false)
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        setFullscreen(true)
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        setFullscreen(false)
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        // Exit normally arrives first; this covers the overlay going away without it.
        setFullscreen(false)
    }

    // MARK: - State

    /// One control we added and the values behind it.
    private struct Entry {
        let item: CameraControlItem
        let control: AVCaptureControl
        /// Values behind picker indexes 1...n; index 0 is Auto. Empty for sliders and system controls.
        let stops: [Double]
    }

    /// What the installed controls were built from. Anything else needs new controls.
    private struct Layout: Equatable {
        var session: ObjectIdentifier
        var deviceID: String
        var items: [CameraControlItem]
        var shutterStops: [Double]
        var isoStops: [Double]
        var apertureStops: [Double]
        var lensTitles: [String]
    }

    private enum Target {
        case index(Int)
        case value(Float)

        func matches(_ other: Target) -> Bool {
            switch (self, other) {
            case let (.index(a), .index(b)): return a == b
            case let (.value(a), .value(b)): return abs(a - b) <= CameraControlBridge.valueTolerance
            default: return false
            }
        }
    }

    private let lock = NSLock()
    private var changeHandler: (@Sendable (CameraControlChange) -> Void)?
    private var fullscreenHandler: (@Sendable (Bool) -> Void)?
    private var layout: Layout?
    private var entries: [Entry] = []
    private var latestState: CameraControlState?
    /// Uptime in nanoseconds when `latestState` arrived.
    private var stateArrival: UInt64 = 0
    /// The camera the controls belong to. Only read, for the focus and white balance it chose on its own.
    private weak var currentDevice: AVCaptureDevice?
    /// Uptime in nanoseconds of the user's last move on each control.
    private var lastTouch: [CameraControlItem: UInt64] = [:]
    /// The value this bridge last set on each control, until the control reports anything. Apple doesn't say
    /// whether a value set in code comes back through the action; if it does, it is the model's own value
    /// snapped to a stop or step, and sending it back would quietly move the model.
    private var pendingEcho: [CameraControlItem: Target] = [:]
    private var isFullscreen = false

    /// How long after the user's last move a control ignores values coming back from the model, which lag
    /// behind the finger and would otherwise pull the control backwards.
    private static let touchGrace: UInt64 = 700_000_000
    /// Slider values closer than this count as the same.
    private static let valueTolerance: Float = 0.0001
    private static let kelvinRange: ClosedRange<Float> = 2000...10000
    private static let kelvinStep: Float = 100
    /// Daylight, shown for automatic white balance when the camera's own temperature can't be read.
    private static let neutralKelvin = 5500.0
    /// The middle of the lens travel, shown for autofocus when the lens position can't be read.
    private static let neutralFocus = 0.5

    // MARK: - Building controls

    private static func layout(for state: CameraControlState, device: AVCaptureDevice, session: AVCaptureSession) -> Layout {
        let shutterStops = usableStops(state.shutterStops)
        let isoStops = usableStops(state.isoStops)
        let apertureStops = usableStops(state.apertureStops)
        let customExposure = device.isExposureModeSupported(.custom)
        var seen = Set<CameraControlItem>()
        let items = state.items.filter { item in
            guard seen.insert(item).inserted else { return false }
            switch item {
            // The system sliders raise an exception for a device that can't zoom or take an exposure bias.
            case .zoom: return device.activeFormat.videoMaxZoomFactor > 1
            // A picker with one title has nothing to pick. The selfie camera has no spot among the back lenses, and a
            // new picker starts on the first one, which would show as current there and couldn't be picked.
            case .lens: return state.lensTitles.count > 1 && device.position != .front
            case .exposureBias: return device.maxExposureTargetBias > device.minExposureTargetBias
            case .shutter: return customExposure && !shutterStops.isEmpty
            case .iso: return customExposure && !isoStops.isEmpty
            case .aperture: return !apertureStops.isEmpty
            case .whiteBalance: return device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            case .focus: return device.isLockingFocusWithCustomLensPositionSupported
            case .mode: return true
            }
        }
        return Layout(
            session: ObjectIdentifier(session),
            deviceID: device.uniqueID,
            items: items,
            shutterStops: shutterStops,
            isoStops: isoStops,
            apertureStops: apertureStops,
            lensTitles: state.lensTitles
        )
    }

    /// Stops that can be labelled and compared on a log scale.
    private static func usableStops(_ stops: [Double]) -> [Double] {
        stops.filter { $0.isFinite && $0 > 0 }
    }

    private func makeEntry(for item: CameraControlItem, layout: Layout, device: AVCaptureDevice) -> Entry {
        let control: AVCaptureControl
        var stops: [Double] = []
        switch item {
        case .zoom:
            control = AVCaptureSystemZoomSlider(device: device)
        case .lens:
            let picker = AVCaptureIndexPicker("Lens", symbolName: item.symbolName, localizedIndexTitles: layout.lensTitles)
            picker.accessibilityIdentifier = "cameraControl.\(item.rawValue)"
            picker.setActionQueue(queue) { [weak self] index in
                self?.pickerMoved(item, index: index, stops: [])
            }
            control = picker
        case .exposureBias:
            control = AVCaptureSystemExposureBiasSlider(device: device)
        case .shutter:
            stops = layout.shutterStops
            control = makePicker(item, title: "Shutter", stops: stops) { ShutterSpeed(seconds: $0).label }
        case .iso:
            stops = layout.isoStops
            control = makePicker(item, title: "ISO", stops: stops) { ISOScale.compactLabel($0) }
        case .aperture:
            stops = layout.apertureStops
            control = makePicker(item, title: "Aperture", stops: stops) { ApertureScale.label($0) }
        case .whiteBalance:
            let slider = AVCaptureSlider("Kelvin", symbolName: item.symbolName, in: Self.kelvinRange, step: Self.kelvinStep)
            slider.localizedValueFormat = "%@K"
            slider.prominentValues = Self.presetKelvins()
            slider.accessibilityIdentifier = "cameraControl.\(item.rawValue)"
            slider.setActionQueue(queue) { [weak self] value in
                self?.sliderMoved(item, value: value)
            }
            control = slider
        case .focus:
            let slider = AVCaptureSlider("Focus", symbolName: item.symbolName, in: 0...1)
            slider.accessibilityIdentifier = "cameraControl.\(item.rawValue)"
            slider.setActionQueue(queue) { [weak self] value in
                self?.sliderMoved(item, value: value)
            }
            control = slider
        case .mode:
            // The uppercase titles are the carousel's styling; the system overlay sets its own type, where
            // title case matches the other pickers.
            let titles = CaptureMode.carouselOrder.map { $0.title.capitalized }
            let picker = AVCaptureIndexPicker("Mode", symbolName: item.symbolName, localizedIndexTitles: titles)
            picker.accessibilityIdentifier = "cameraControl.\(item.rawValue)"
            picker.setActionQueue(queue) { [weak self] index in
                self?.pickerMoved(item, index: index, stops: [])
            }
            control = picker
        }
        return Entry(item: item, control: control, stops: stops)
    }

    /// "Auto" first, then one title per stop. Controls need their action before the session accepts them.
    private func makePicker(_ item: CameraControlItem, title: String, stops: [Double], label: (Double) -> String) -> AVCaptureIndexPicker {
        let titles = ["Auto"] + stops.map(label)
        let picker = AVCaptureIndexPicker(title, symbolName: item.symbolName, localizedIndexTitles: titles)
        picker.accessibilityIdentifier = "cameraControl.\(item.rawValue)"
        picker.setActionQueue(queue) { [weak self] index in
            self?.pickerMoved(item, index: index, stops: stops)
        }
        return picker
    }

    /// Preset temperatures inside the slider's range, one per spot on the scale (flash sits on daylight).
    private static func presetKelvins() -> [Float] {
        var values: [Float] = []
        for preset in WhiteBalancePreset.allCases {
            guard let kelvin = preset.kelvin, kelvin.isFinite else { continue }
            let value = Float(kelvin)
            guard kelvinRange.contains(value), !values.contains(where: { abs($0 - value) < 150 }) else { continue }
            values.append(value)
        }
        return values.sorted()
    }

    private func attachDelegate(to session: AVCaptureSession) {
        if (session.controlsDelegate as AnyObject?) !== self {
            session.setControlsDelegate(self, queue: queue)
        }
    }

    private static func isInstalled(_ entries: [Entry], on session: AVCaptureSession) -> Bool {
        let current = Set(session.controls.map { ObjectIdentifier($0) })
        let ours = Set(entries.map { ObjectIdentifier($0.control) })
        return current == ours
    }

    // MARK: - User input (controls queue)

    private func pickerMoved(_ item: CameraControlItem, index: Int, stops: [Double]) {
        guard acceptMove(item, reported: .index(index)) else { return }
        let change: CameraControlChange
        switch item {
        case .mode:
            guard CaptureMode.carouselOrder.indices.contains(index) else { return }
            change = .mode(CaptureMode.carouselOrder[index])
        case .lens:
            guard index >= 0 else { return }
            change = .lens(index)
        case .shutter, .iso, .aperture:
            // Index 0 is Auto; anything past the stops is ignored rather than read as Auto.
            guard index >= 0, index <= stops.count else { return }
            let value: Double? = index == 0 ? nil : stops[index - 1]
            switch item {
            case .shutter: change = .shutter(value)
            case .iso: change = .iso(value)
            default: change = .aperture(value)
            }
        case .zoom, .exposureBias, .whiteBalance, .focus:
            return
        }
        onChange?(change)
    }

    private func sliderMoved(_ item: CameraControlItem, value: Float) {
        guard acceptMove(item, reported: .value(value)) else { return }
        guard value.isFinite else { return }
        let range = Self.kelvinRange
        switch item {
        case .whiteBalance:
            onChange?(.kelvin(Double(min(max(value, range.lowerBound), range.upperBound))))
        case .focus:
            onChange?(.focus(Double(min(max(value, 0), 1))))
        case .zoom, .lens, .exposureBias, .shutter, .iso, .aperture, .mode:
            break
        }
    }

    /// Notes the user's move, or returns false for the echo of a value this bridge set. Any report clears the
    /// pending echo, so the next real move always goes through.
    private func acceptMove(_ item: CameraControlItem, reported: Target) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock { () -> Bool in
            if let expected = pendingEcho.removeValue(forKey: item), expected.matches(reported) {
                return false
            }
            lastTouch[item] = now
            return true
        }
    }

    private func setFullscreen(_ fullscreen: Bool) {
        let handler = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            guard isFullscreen != fullscreen else { return nil }
            isFullscreen = fullscreen
            return fullscreenHandler
        }
        handler?(fullscreen)
    }

    // MARK: - Values from the model

    /// Picker indexes and slider values may only change on the action queue, so they are set from there.
    private func scheduleValues(from state: CameraControlState, for entries: [Entry], device: AVCaptureDevice,
                                sparingRecentTouches: Bool) {
        let targets = Self.targets(from: state, for: entries, device: device)
        guard !targets.isEmpty else { return }
        queue.async { [weak self] in
            self?.applyValues(targets, sparingRecentTouches: sparingRecentTouches)
        }
    }

    /// Controls queue.
    private func applyValues(_ targets: [(Entry, Target)], sparingRecentTouches: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        for (entry, target) in targets where Self.needsChange(entry.control, to: target) {
            // Checked together under the lock: values queued just before a rebuild belong to controls it removed,
            // and their pending echo would swallow the first move on the new control of the same kind.
            let claimed = lock.withLock { () -> Bool in
                guard entries.contains(where: { $0.control === entry.control }) else { return false }
                if sparingRecentTouches, let touched = lastTouch[entry.item], now < touched + Self.touchGrace {
                    return false
                }
                pendingEcho[entry.item] = target
                return true
            }
            guard claimed else { continue }
            switch target {
            case .index(let index):
                (entry.control as? AVCaptureIndexPicker)?.selectedIndex = index
            case .value(let value):
                (entry.control as? AVCaptureSlider)?.value = value
            }
        }
    }

    /// The control can take `target` and doesn't show it yet. An index out of range raises an exception.
    private static func needsChange(_ control: AVCaptureControl, to target: Target) -> Bool {
        switch target {
        case .index(let index):
            guard let picker = control as? AVCaptureIndexPicker else { return false }
            return index >= 0 && index < picker.numberOfIndexes && picker.selectedIndex != index
        case .value(let value):
            guard let slider = control as? AVCaptureSlider else { return false }
            return abs(slider.value - value) > valueTolerance
        }
    }

    /// What each control should show for `state`. Values are clamped (and snapped to the slider's step)
    /// before they get here, because an out-of-range value raises an exception.
    private static func targets(from state: CameraControlState, for entries: [Entry], device: AVCaptureDevice?) -> [(Entry, Target)] {
        // Automatic white balance and focus have no spot on their sliders, so the sliders show what the camera
        // picked on its own; the first touch then continues from the preview instead of jumping to the middle.
        let liveKelvin = state.kelvin == nil && entries.contains { $0.item == .whiteBalance }
            ? device.flatMap(currentKelvin(of:)) : nil
        let liveFocus = state.lensPosition == nil && entries.contains { $0.item == .focus }
            ? device.flatMap(currentLensPosition(of:)) : nil
        return entries.compactMap { entry -> (Entry, Target)? in
            switch entry.item {
            case .shutter:
                return pickerIndex(for: state.shutter, stops: entry.stops).map { (entry, .index($0)) }
            case .iso:
                return pickerIndex(for: state.iso, stops: entry.stops).map { (entry, .index($0)) }
            case .aperture:
                return pickerIndex(for: state.aperture, stops: entry.stops).map { (entry, .index($0)) }
            case .mode:
                return CaptureMode.carouselOrder.firstIndex(of: state.mode).map { (entry, .index($0)) }
            case .lens:
                // An index past the picker's titles raises; the selfie camera has no spot on it.
                guard let index = state.lensIndex, state.lensTitles.indices.contains(index) else { return nil }
                return (entry, .index(index))
            case .whiteBalance:
                let kelvin = state.kelvin.flatMap { $0.isFinite ? $0 : nil } ?? liveKelvin ?? neutralKelvin
                let snapped = (Float(kelvin) / kelvinStep).rounded() * kelvinStep
                return (entry, .value(min(max(snapped, kelvinRange.lowerBound), kelvinRange.upperBound)))
            case .focus:
                let position = state.lensPosition.flatMap { $0.isFinite ? $0 : nil } ?? liveFocus ?? neutralFocus
                return (entry, .value(Float(min(max(position, 0), 1))))
            case .zoom, .exposureBias:
                // Apple's system sliders follow the device themselves.
                return nil
            }
        }
    }

    /// The temperature automatic white balance is using, or nil when the device reports nothing usable.
    private static func currentKelvin(of device: AVCaptureDevice) -> Double? {
        let maxGain = max(1, device.maxWhiteBalanceGain)
        func legal(_ gain: Float) -> Float {
            gain.isFinite ? min(max(gain, 1), maxGain) : 1
        }
        let gains = device.deviceWhiteBalanceGains
        // Gains outside 1...maxWhiteBalanceGain make the conversion raise an exception.
        let legalGains = AVCaptureDevice.WhiteBalanceGains(redGain: legal(gains.redGain), greenGain: legal(gains.greenGain),
                                                           blueGain: legal(gains.blueGain))
        let kelvin = Double(device.temperatureAndTintValues(for: legalGains).temperature)
        return kelvin.isFinite && kelvin > 0 ? kelvin : nil
    }

    private static func currentLensPosition(of device: AVCaptureDevice) -> Double? {
        let position = Double(device.lensPosition)
        return position.isFinite ? position : nil
    }

    /// 0 for Auto (nil), else 1 + the stop closest on a log scale. nil leaves the control as it is.
    private static func pickerIndex(for value: Double?, stops: [Double]) -> Int? {
        guard let value else { return 0 }
        guard value.isFinite, value > 0, !stops.isEmpty else { return nil }
        var best = 0
        var bestDistance = Double.infinity
        for (index, stop) in stops.enumerated() {
            let distance = abs(log2(stop / value))
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best + 1
    }
}
