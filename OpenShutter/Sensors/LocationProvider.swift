import Foundation
import CoreLocation
import CameraCore

/// Supplies GPS for photo and video metadata, only while the user has location tagging on. The model turns it on
/// while the camera is in front with tags on and off in the background, so the most precise fix and the compass run
/// only while a shot can use them.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private var fix: LocationStamp?
    /// Where the back of the phone faces, while the compass is sure of it.
    private var heading: (degrees: Double, isTrueNorth: Bool)?
    private let manager = CLLocationManager()
    private var wanted = false

    /// The compass is believed only within this many degrees.
    nonisolated private static let headingTolerance = 30.0

    override init() {
        super.init()
        manager.delegate = self
        // Apple's Camera tags photos to a few metres; the cost is paid only while tags are on and the camera is in use.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Every fix, so a phone that stays put on a tripod still has a fresh one when a long session's next shot ends.
        manager.distanceFilter = kCLDistanceFilterNone
        // A phone on a tripod looks like a stop to iOS, which would pause updates and let the fix go stale.
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 2
    }

    /// Starts or stops updates. Asks for When In Use permission the first time it is enabled.
    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        guard enabled else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            fix = nil
            heading = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates()
        default:
            break
        }
    }

    /// A fix older than five minutes says where you were, not where the photo was taken. The heading goes with it
    /// only while the compass is sure of it.
    var current: LocationStamp? {
        guard var fix, Date().timeIntervalSince(fix.timestamp) < 300 else { return nil }
        if let heading {
            fix.heading = heading.degrees
            fix.headingIsTrueNorth = heading.isTrueNorth
        }
        return fix
    }

    private func startUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.wanted else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.startUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        // Core Location marks what a fix doesn't know with negative values; those stay out of the files.
        let speed = location.speed >= 0 && location.speedAccuracy >= 0 ? location.speed : nil
        let course = location.course >= 0 && location.courseAccuracy >= 0 ? location.course : nil
        let stamp = LocationStamp(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            verticalAccuracy: location.verticalAccuracy,
            speed: speed,
            course: course
        )
        Task { @MainActor in
            guard self.wanted else { return }
            self.fix = stamp
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let reading = Self.reading(newHeading)
        Task { @MainActor in
            guard self.wanted else { return }
            self.heading = reading
        }
    }

    /// nil while the compass isn't sure. True north needs a location fix; until there is one, magnetic north is
    /// still a direction.
    nonisolated private static func reading(_ heading: CLHeading) -> (degrees: Double, isTrueNorth: Bool)? {
        let accuracy = heading.headingAccuracy
        guard accuracy >= 0, accuracy <= headingTolerance else { return nil }
        if heading.trueHeading >= 0 { return (heading.trueHeading, true) }
        if heading.magneticHeading >= 0 { return (heading.magneticHeading, false) }
        return nil
    }

    /// The calibration figure would cover the viewfinder; an uncalibrated compass is left out of the files instead.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location is optional metadata; a failed fix just means the next photo has no GPS.
    }
}
