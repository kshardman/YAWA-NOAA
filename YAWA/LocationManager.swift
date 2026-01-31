//
//  LocationManager.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/28/25.
//


import SwiftUI
import CoreLocation
import Combine
import MapKit
import Foundation
import UIKit

extension Notification.Name {
    static let yawaHomeSettingsDidChange = Notification.Name("yawaHomeSettingsDidChange")
}

//city search

@MainActor
final class CitySearchViewModel: ObservableObject {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    @Published var query: String = ""
    @Published var results: [Result] = []
    @Published var isSearching = false

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = []; return }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.resultTypes = [.address]   // city/state hits well

        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.compactMap { item in
                guard let name = item.placemark.locality ?? item.name else { return nil }
                let state = item.placemark.administrativeArea ?? ""
                return Result(title: name, subtitle: state, coordinate: item.placemark.coordinate)
            }
        } catch {
            results = []
        }
    }
}


// MARK: - Location

import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject {

    @Published var coordinate: CLLocationCoordinate2D?
    @Published var lastLocationDate: Date?
    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?
    @Published var locationName: String?   // City, ST for display

    private let manager = CLLocationManager()
    private var lastGeocodedCoord: CLLocationCoordinate2D?
    private let geocoder = CLGeocoder()
    private var isGeocoding = false
    
    // Cache reverse-geocoded country codes for favorites (avoid repeated geocoder calls)
    private var countryCodeCache: [String: String] = [:]

    private var homeEnabledCache: Bool = false
    private var homeLatCache: Double = 0
    private var homeLonCache: Double = 0

    private var homeSettingsObserver: AnyCancellable?
    private var foregroundObserver: AnyCancellable?

    private func cacheKey(for coord: CLLocationCoordinate2D) -> String {
        // Round to reduce churn from tiny coordinate jitter
        let lat = String(format: "%.4f", coord.latitude)
        let lon = String(format: "%.4f", coord.longitude)
        return "\(lat),\(lon)"
    }

    /// Best-effort ISO country code for a coordinate (e.g. "US", "CA").
    func countryCode(for coord: CLLocationCoordinate2D) async -> String? {
        let key = cacheKey(for: coord)
        if let cached = countryCodeCache[key] { return cached }

        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(loc)
            let code = placemarks.first?.isoCountryCode
            if let code { countryCodeCache[key] = code }
            return code
        } catch {
            return nil
        }
    }
    
    

    // Burst-update control
    private var stopWorkItem: DispatchWorkItem?
    private var isBursting = false
    
    // MARK: - Home label (app-defined)

    private let homeRadiusMeters: CLLocationDistance = 100   // fixed: 100 meters

    private var homeCoordinate: CLLocationCoordinate2D? {
        guard homeEnabledCache else { return nil }
        let lat = homeLatCache
        let lon = homeLonCache
        guard !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func isAtHome(_ location: CLLocation) -> Bool {
        guard let home = homeCoordinate else { return false }
        let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
        return location.distance(from: homeLoc) <= homeRadiusMeters
    }

    /// True when the current GPS fix is within the Home radius.
    var isCurrentlyAtHome: Bool {
        guard let c = coordinate else { return false }
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return isAtHome(loc)
    }
    
    

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100 // meters (helps reduce noise)
        
        let d = UserDefaults.standard
        homeEnabledCache = d.bool(forKey: "homeEnabled")
        homeLatCache = d.double(forKey: "homeLat")
        homeLonCache = d.double(forKey: "homeLon")

        homeSettingsObserver = NotificationCenter.default
            .publisher(for: .yawaHomeSettingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let d = UserDefaults.standard
                self.homeEnabledCache = d.bool(forKey: "homeEnabled")
                self.homeLatCache = d.double(forKey: "homeLat")
                self.homeLonCache = d.double(forKey: "homeLon")
                self.applyHomeLabelToCurrentFix(forceGeocode: true)
            }

        foregroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyHomeLabelToCurrentFix(forceGeocode: false)
            }
    }

    /// Call on launch / when app becomes active
    func request() {
        errorMessage = nil

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse, .authorizedAlways:
            startBurstUpdate()

        case .denied, .restricted:
            // Optional message:
            // errorMessage = "Location access is disabled. Enable it in Settings."
            break

        @unknown default:
            break
        }
    }

    /// Manual “try again”
    func refresh() {
        errorMessage = nil
        startBurstUpdate()
    }

    // MARK: - Burst location update

    private func startBurstUpdate() {
        guard !isBursting else { return }
        isBursting = true

        // Cancel any previous stop timer
        stopWorkItem?.cancel()

        manager.startUpdatingLocation()

        // Safety stop so we never run forever
        let work = DispatchWorkItem { [weak self] in
            self?.manager.stopUpdatingLocation()
            self?.isBursting = false
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func stopBurstUpdate() {
        manager.stopUpdatingLocation()
        isBursting = false
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }

    // MARK: - Reverse geocode (City, ST)

    private func reverseGeocodeIfNeeded(for location: CLLocation) async {
        // Prevent overlapping reverse-geocode calls during burst updates
        guard !isGeocoding else { return }
        isGeocoding = true
        defer { isGeocoding = false }
        // If we're at Home, prefer the simple label and skip geocoding.
        if isAtHome(location) {
            self.locationName = "Home"
            return
        }
        if let last = lastGeocodedCoord {
            let dLat = abs(last.latitude - location.coordinate.latitude)
            let dLon = abs(last.longitude - location.coordinate.longitude)
            if dLat < 0.01 && dLon < 0.01 { return }
        }
        lastGeocodedCoord = location.coordinate

        geocoder.cancelGeocode()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let place = placemarks.first else { return }

            let city = place.locality
            let state = place.administrativeArea

            if let city, let state { self.locationName = "\(city), \(state)" }
            else if let city { self.locationName = city }
            else if let state { self.locationName = state }
            else { self.locationName = nil }
        } catch {
            // silent fail is fine
        }
    }

    private func applyHomeLabelToCurrentFix(forceGeocode: Bool) {
        guard let c = coordinate else { return }
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)

        if forceGeocode {
            lastGeocodedCoord = nil
        }

        if isAtHome(loc) {
            locationName = "Home"
        } else {
            Task { [weak self] in
                await self?.reverseGeocodeIfNeeded(for: loc)
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // If we just got authorized, immediately try to get a fix.
            startBurstUpdate()

        case .denied, .restricted:
            break

        case .notDetermined:
            break

        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Don’t show an error for transient failures; optional:
        // errorMessage = error.localizedDescription
        isBursting = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
//        print("LOC:", loc.coordinate.latitude, loc.coordinate.longitude, "acc:", loc.horizontalAccuracy)
        // Ignore very old cached fixes
        if abs(loc.timestamp.timeIntervalSinceNow) > 30 { return }

        // Update coordinate + timestamp immediately
        self.coordinate = loc.coordinate
        self.lastLocationDate = loc.timestamp

        // Stop when accuracy is reasonable (prevents battery drain)
        if loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= 150 {
            stopBurstUpdate()
        }

        // Async reverse geocode safely
        let goodEnough = (loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= 150)
        if goodEnough || !isBursting {
            Task { [weak self] in
                await self?.reverseGeocodeIfNeeded(for: loc)
            }
        }
    }
}

// MARK: - NOAA/NWS API models


/// Minimal “any” decoder so Geometry can exist even if you never use it
struct AnyDecodable: Decodable {}






// MARK: - View

func conditionsSymbolAndColor(
    for text: String,
    isNight: Bool
) -> (symbol: String, color: Color) {

    let t = text.lowercased()

    if t.contains("thunder") {
        return ("cloud.bolt.rain.fill", .purple)
    }

    if t.contains("snow") || t.contains("sleet") || t.contains("ice") {
        return ("cloud.snow.fill", .cyan)
    }

    if t.contains("rain") || t.contains("shower") || t.contains("drizzle") {
        return ("cloud.rain.fill", .blue)
    }

    if t.contains("fog") || t.contains("mist") || t.contains("haze") {
        return ("cloud.fog.fill", .gray)
    }

    if t.contains("overcast") || t.contains("cloudy") {
        return ("cloud.fill", .gray)
    }

    if t.contains("partly") || t.contains("mostly") {
        return isNight
            ? ("cloud.moon.fill", .gray)
            : ("cloud.sun.fill", .yellow)
    }

    if t.contains("clear") || t.contains("sunny") {
        return isNight
            ? ("moon.stars.fill", .gray)
            : ("sun.max.fill", .yellow)
    }

    return ("cloud.fill", .secondary)
}












