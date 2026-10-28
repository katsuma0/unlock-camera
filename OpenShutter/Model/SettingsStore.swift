import Foundation
import CameraCore

/// Keeps CameraSettings in UserDefaults as JSON. CameraSettings decodes missing keys with defaults,
/// so new settings in a later version never wipe what the user already set up.
final class SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "camera.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> CameraSettings {
        guard let data = defaults.data(forKey: key) else { return .default }
        return CameraSettings.decoded(from: data)
    }

    func save(_ settings: CameraSettings) {
        guard let data = try? settings.encoded() else { return }
        defaults.set(data, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}
