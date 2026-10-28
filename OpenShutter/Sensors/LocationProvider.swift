import Foundation
import CoreLocation

/// Supplies GPS for photo metadata, only while the user has location tagging on.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var latest: LocationStamp?
    private let manager = CLLocationManager()
    private var wanted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    /// Starts or stops updates. Asks for When In Use permission the first time it is enabled.
    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        guard enabled else {
            manager.stopUpdatingLocation()
            latest = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    /// A fix older than five minutes says where you were, not where the photo was taken.
    var current: LocationStamp? {
        guard let latest, Date().timeIntervalSince(latest.timestamp) < 300 else { return nil }
        return latest
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.wanted else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        let stamp = LocationStamp(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
        Task { @MainActor in
            self.latest = stamp
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location is optional metadata; a failed fix just means the next photo has no GPS.
    }
}
