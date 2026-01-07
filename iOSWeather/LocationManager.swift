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

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    // City, ST for display
    @Published var locationName: String?

    private let manager = CLLocationManager()
    private var lastGeocodedCoord: CLLocationCoordinate2D?
    private let geocoder = CLGeocoder()

    
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        errorMessage = nil
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func refresh() {
        errorMessage = nil
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            errorMessage = "Location access is disabled."
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        coordinate = loc.coordinate
        Task { await reverseGeocodeIfNeeded(for: loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Could not get location."
        print("Location error:", error)
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

            await MainActor.run {
                if let city, let state { self.locationName = "\(city), \(state)" }
                else if let city { self.locationName = city }
                else if let state { self.locationName = state }
                else { self.locationName = nil }
            }
        } catch {
            // silent fail is fine
        }
    }
}


// MARK: - NOAA/NWS API models

import Foundation

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












