import CoreLocation
import Foundation
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "location")

/// One-shot location for a single poop. Never tracks continuously.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var waiting: [(PoopLocation?) -> Void] = []
    private var authWaiters: [(Bool) -> Void] = []
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Shows the system prompt if needed. Returns whether location is usable.
    func requestAuthorization() async -> Bool {
        if isAuthorized { return true }
        if isDenied { return false }
        return await withCheckedContinuation { cont in
            authWaiters.append { cont.resume(returning: $0) }
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Fetches one location fix and a readable place label. Calls back with nil on failure.
    func locateOnce(_ completion: @escaping (PoopLocation?) -> Void) {
        guard isAuthorized else { completion(nil); return }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        manager.requestLocation()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
    }

    private func finish(_ location: PoopLocation?) {
        timeoutTask?.cancel()
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0(location) }
    }

    private func resolve(_ cl: CLLocation) {
        let base = PoopLocation(latitude: cl.coordinate.latitude, longitude: cl.coordinate.longitude, accuracy: cl.horizontalAccuracy, capturedAt: cl.timestamp)
        geocoder.reverseGeocodeLocation(cl) { [weak self] placemarks, error in
            var loc = base
            if let p = placemarks?.first {
                loc.placeName = p.areasOfInterest?.first ?? p.name
                loc.locality = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea
                loc.country = p.country
                loc.countryCode = p.isoCountryCode
            } else if let error {
                log.info("reverse geocode failed: \(error.localizedDescription, privacy: .public)")
            }
            let result = loc
            Task { @MainActor in self?.finish(result) }
        }
    }

    /// Forward lookup for manual location edits ("Toyama Station").
    func search(_ text: String) async -> [PoopLocation] {
        do {
            let marks = try await geocoder.geocodeAddressString(text)
            return marks.compactMap { p in
                guard let c = p.location?.coordinate else { return nil }
                return PoopLocation(latitude: c.latitude, longitude: c.longitude, placeName: p.areasOfInterest?.first ?? p.name, locality: p.locality, country: p.country, countryCode: p.isoCountryCode)
            }
        } catch {
            return []
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.status != .notDetermined else { return }
            let ok = self.isAuthorized
            let waiters = self.authWaiters
            self.authWaiters = []
            waiters.forEach { $0(ok) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.resolve(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.info("location failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in self.finish(nil) }
    }
}
