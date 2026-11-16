import Combine
import CoreLocation
import Foundation

/// Keeps the latest location fix so each captured packet can be tagged with where it was heard.
/// Port of the location code in Android's `MagicMakerForegroundService.kt`.
@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// The newest fix, or nil while there is none. As on Android it is used however old it is.
    private(set) var latest: (lat: Double, lng: Double, accuracy: Double)?

    private let manager = CLLocationManager()
    private var status: CLAuthorizationStatus = .notDetermined
    private var wantsUpdates = false
    private var isUpdating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        // Standing still must not end the updates; the app only runs them while it is open.
        manager.pausesLocationUpdatesAutomatically = false
        status = manager.authorizationStatus
    }

    /// Asks for when-in-use permission the first time, then keeps `latest` up to date.
    /// Without permission nothing happens and `latest` stays nil.
    func start() {
        wantsUpdates = true
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    func stop() {
        wantsUpdates = false
        if isUpdating {
            manager.stopUpdatingLocation()
            isUpdating = false
        }
    }

    var isAuthorized: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// The location permission in a few words, for a status line.
    var authorizationDescription: String {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return "Location ready"
        case .denied:
            return "Allow Location in Settings"
        case .restricted:
            return "Location restricted"
        case .notDetermined:
            return "Location not requested"
        default:
            return "Location unavailable"
        }
    }

    private func beginUpdates() {
        // Start from the last known fix, as Android does, until a fresh one arrives.
        if latest == nil, let known = manager.location, known.horizontalAccuracy >= 0 {
            apply(
                lat: known.coordinate.latitude,
                lng: known.coordinate.longitude,
                accuracy: known.horizontalAccuracy
            )
        }
        if !isUpdating {
            manager.startUpdatingLocation()
            isUpdating = true
        }
    }

    private func apply(lat: Double, lng: Double, accuracy: Double) {
        // Only the first fix is announced; later ones are read when a packet is tagged.
        if latest == nil {
            objectWillChange.send()
        }
        latest = (lat: lat, lng: lng, accuracy: accuracy)
    }

    private func authorizationChanged(to newStatus: CLAuthorizationStatus) {
        if newStatus != status {
            objectWillChange.send()
            status = newStatus
        }
        if isAuthorized {
            if wantsUpdates {
                beginUpdates()
            }
        } else {
            if isUpdating {
                manager.stopUpdatingLocation()
                isUpdating = false
            }
            // Permission withdrawn: stop tagging packets with the old position.
            latest = nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationChanged(to: newStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        // A negative accuracy marks a fix with no usable coordinate.
        let accuracy: Double = last.horizontalAccuracy
        guard accuracy >= 0 else { return }
        let lat: Double = last.coordinate.latitude
        let lng: Double = last.coordinate.longitude
        Task { @MainActor in
            self.apply(lat: lat, lng: lng, accuracy: accuracy)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix is not fatal: updates continue and the last good fix stays in `latest`.
    }
}
