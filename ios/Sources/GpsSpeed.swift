// GPS speed reference for calibrating ECU wheel speed.
//
// The phone's GNSS speed is Doppler-derived and absolutely accurate
// (~0.2 mph) but only arrives ~1 Hz with latency — too coarse to time a
// run, ideal as a truth reference. The Engine compares it against ECU
// speed during steady driving and maintains a correction factor, so runs
// are timed on the ECU's 25+ Hz stream scaled to GPS truth.

import CoreLocation
import Foundation

final class GpsSpeed: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var mph: Double?
    @Published var accuracyOK = false
    @Published var authorized = false
    private(set) var lastUpdate = Date.distantPast

    private let manager = CLLocationManager()
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
    }

    func start() {
        guard !started else { return }   // idempotent: safe to call from launch and onboarding
        started = true
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.speed >= 0 else { return }
        let mph = loc.speed * 2.236936
        let ok = loc.speedAccuracy >= 0 && loc.speedAccuracy < 1.0   // < ~2.2 mph 1σ
        DispatchQueue.main.async {
            self.mph = mph
            self.accuracyOK = ok
            self.lastUpdate = Date()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
