import CoreLocation
import Foundation

/// This Mac's location for Live Earth, when the place to keep in view follows it. Asks Location
/// Services once at launch and whenever the option is turned on, and writes the answer into the
/// settings; a city-level fix is plenty for a whole-Earth view.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    /// Why the last request didn't give a location, for the Customize window.
    @Published private(set) var problem: String?
    @Published private(set) var updating = false

    private let manager = CLLocationManager()

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    private var observer: NSObjectProtocol?
    private var following = false

    /// Asks for the location if the settings follow it, now and whenever they start to (from the
    /// Customize window, a preset or the command line).
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ConfigStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfNewlyFollowing() }
        }
        refreshIfNewlyFollowing()
    }

    private func refreshIfNewlyFollowing() {
        let follows = ConfigStore.shared.config.homeFromDevice
        if follows && !following { request() }
        following = follows
    }

    func request() {
        problem = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            updating = true
            manager.requestWhenInUseAuthorization()   // the answer arrives in the delegate
        case .denied, .restricted:
            problem = "Location access is off for Deep Field. Turn it on in System Settings > Privacy & Security > Location Services."
        default:
            updating = true
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.updating else { return }
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted:
                self.updating = false
                self.problem = "Location access is off for Deep Field. Turn it on in System Settings > Privacy & Security > Location Services."
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.updating = false
            let store = ConfigStore.shared
            guard store.config.homeFromDevice else { return }
            // rounded to about a kilometer: no need to store more than the view can show
            let lat = (loc.coordinate.latitude * 100).rounded() / 100
            let lon = (loc.coordinate.longitude * 100).rounded() / 100
            if store.config.homeLatitude != lat || store.config.homeLongitude != lon {
                store.config.homeLatitude = lat
                store.config.homeLongitude = lon
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.updating = false
            self.problem = "Couldn't find this Mac's location (\(error.localizedDescription))."
        }
    }
}
