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

    // Burst-update control
    private var stopWorkItem: DispatchWorkItem?
    private var isBursting = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100 // meters (helps reduce noise)
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
//        if loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= 500 {
//            stopBurstUpdate()
 //       }

        // Async reverse geocode safely
        Task { [weak self] in
            await self?.reverseGeocodeIfNeeded(for: loc)
        }
    }
}

// MARK: - NOAA/NWS API models

struct NWSAlertsResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable, Identifiable {
        // NOAA uses a string id like the full URL
        let id: String

        // ✅ IMPORTANT: NOAA frequently returns geometry: null
        let geometry: Geometry?

        let properties: Properties
    }

    struct Geometry: Decodable {
        let type: String
        let coordinates: [[[Double]]]? // keep loose; often polygon/multipolygon
    }

    struct Properties: Decodable {
        let event: String
        let severity: String?
        let headline: String?
        let areaDesc: String?
        let descriptionText: String?
        let instructionText: String?

        enum CodingKeys: String, CodingKey {
            case event
            case severity
            case headline
            case areaDesc
            case descriptionText = "description"
            case instructionText = "instruction"
        }
    }
}

/// Minimal “any” decoder so Geometry can exist even if you never use it
struct AnyDecodable: Decodable {}

struct NWSPointsResponse: Decodable {
    struct Properties: Decodable {
        let forecast: String
        let observationStations: String
    }
    let properties: Properties
}

struct NWSForecastResponse: Decodable {

    struct Properties: Decodable {
        let periods: [Period]
    }

    let properties: Properties

    struct Period: Decodable, Identifiable {
        let number: Int
        var id: Int { number }

        let name: String
        let startTime: Date            // ✅ ADD
        let isDaytime: Bool
        let temperature: Int
        let temperatureUnit: String
        let windSpeed: String
        let windDirection: String
        let shortForecast: String
        let detailedForecast: String?
        let probabilityOfPrecipitation: ProbabilityOfPrecipitation?
    }

    struct ProbabilityOfPrecipitation: Decodable {
        let value: Double?
    }
}

enum NOAAServiceError: Error {
    case invalidURL
    case badStatus(Int)
}

// MARK: - NOAA Service

final class NOAAService {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    func fetchActiveAlerts(lat: Double, lon: Double) async throws -> [NWSAlertsResponse.Feature] {
        guard let url = URL(string: "https://api.weather.gov/alerts/active?point=\(lat),\(lon)") else {
            throw NOAAServiceError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("iOSWeather (personal app)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAAServiceError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(NWSAlertsResponse.self, from: data)
        return decoded.features
    }
    
    func fetch7DayPeriods(lat: Double, lon: Double) async throws -> [NWSForecastResponse.Period] {
        // 1) points endpoint
        guard let pointsURL = URL(string: "https://api.weather.gov/points/\(lat),\(lon)") else {
            throw NOAAServiceError.invalidURL
        }

        var pointsReq = URLRequest(url: pointsURL)
        pointsReq.setValue("iOSWeather (personal app)", forHTTPHeaderField: "User-Agent")
        pointsReq.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (pointsData, pointsResp) = try await session.data(for: pointsReq)
        if let http = pointsResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAAServiceError.badStatus(http.statusCode)
        }

        let points = try JSONDecoder().decode(NWSPointsResponse.self, from: pointsData)

        // 2) forecast url from points
        guard let forecastURL = URL(string: points.properties.forecast) else {
            throw NOAAServiceError.invalidURL
        }

        var forecastReq = URLRequest(url: forecastURL)
        forecastReq.setValue("iOSWeather (personal app)", forHTTPHeaderField: "User-Agent")
        forecastReq.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (forecastData, forecastResp) = try await session.data(for: forecastReq)
        if let http = forecastResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAAServiceError.badStatus(http.statusCode)
        }

 //       let decoded = try JSONDecoder().decode(NWSForecastResponse.self, from: forecastData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NWSForecastResponse.self, from: forecastData)
        return decoded.properties.periods
    }
}

// MARK: - Forecast VM


@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var periods: [NWSForecastResponse.Period] = []
    @Published var alerts: [NWSAlertsResponse.Feature] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = NOAAService()
    private var lastCoord: CLLocationCoordinate2D?
//    private let notifyStore = AlertNotificationStore()
    
    @MainActor
    private func notifyOnNewAlerts(locationTitle: String?) async {
        guard !alerts.isEmpty else { return }

        // Notify only the top N to avoid spam if many are active
        for a in alerts.prefix(2) {
            // Pick a stable id
            let id = a.id   // (this is the Feature.id string, which you printed earlier)

            // ✅ De-dupe
            if NotificationsManager.shared.hasNotifiedAlert(id: id) {
                continue
            }
            NotificationsManager.shared.markAlertNotified(id: id)

            // Build title/body from fields you actually have in your model
            let event = a.properties.event
            let headline = a.properties.headline ?? a.properties.areaDesc ?? ""
            let place = (locationTitle?.isEmpty == false) ? " • \(locationTitle!)" : ""

            await NotificationsManager.shared.postNewAlertNotification(
                title: "\(event)\(place)",
                body: headline,
                id: id
            )
        }
    }
    
    // ✅ Visual cue: clear stale rows/alerts while we fetch new data
    func setLoadingPlaceholders() {
        periods = []
        alerts = []
        errorMessage = nil
        // leave isLoading to refresh()
    }

    func loadIfNeeded(for coord: CLLocationCoordinate2D) async {
        // Always keep alerts current (they can change independently of periods)
        await loadAlertsIfNeeded(for: coord)

        // Prevent refetch spam for periods from minor GPS jitter
        if let last = lastCoord,
           abs(last.latitude - coord.latitude) < 0.01,
           abs(last.longitude - coord.longitude) < 0.01,
           !periods.isEmpty {
            return
        }

        lastCoord = coord
        await refresh(for: coord)   // refresh loads periods + alerts
    }

    private func loadAlertsIfNeeded(for coord: CLLocationCoordinate2D) async {
        // If we already have alerts and coord is basically the same, skip
        if let last = lastCoord,
           abs(last.latitude - coord.latitude) < 0.01,
           abs(last.longitude - coord.longitude) < 0.01,
           !alerts.isEmpty {
            return
        }

        do {
            alerts = try await service.fetchActiveAlerts(lat: coord.latitude, lon: coord.longitude)
            // Don’t stomp a forecast error message with an alerts success
        } catch {
            // Don't show “Forecast unavailable” just because alerts failed
            // Keep prior alerts (or leave empty) silently
        }
    }

    func refresh(for coord: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        // 1) Periods are required. If this fails, show the forecast error.
        do {
            periods = try await service.fetch7DayPeriods(lat: coord.latitude, lon: coord.longitude)
            errorMessage = nil
        } catch {
            // ✅ Treat cancellations as normal (don’t show an error)
            if error is CancellationError { return }
            if let urlErr = error as? URLError, urlErr.code == .cancelled { return }

            errorMessage = "Forecast unavailable."
            return
        }

        // 2) Alerts are best-effort. If this fails, don't show a forecast error.
        do {
            alerts = try await service.fetchActiveAlerts(lat: coord.latitude, lon: coord.longitude)
//            print("🚨 alerts fetched:", alerts.map { $0.properties.event ?? "?" })
//            print("🚨 alert ids:", alerts.map { $0.id })
            // ✅ notify once per new alert id (after alerts are updated)
            await notifyOnNewAlerts(locationTitle: nil)
        } catch {
            // Keep existing alerts (nice UX), or clear if you prefer:
            // alerts = []
        }
    }
}

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












