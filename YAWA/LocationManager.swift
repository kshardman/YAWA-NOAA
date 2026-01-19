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
    let properties: Properties

    struct Properties: Decodable {
        let periods: [Period]
    }

    struct Period: Decodable, Identifiable {
        let number: Int
        var id: Int { number }

        let name: String
        let startTime: Date
        let endTime: Date
        let isDaytime: Bool

        let temperature: Int?          // ✅ was Int
        let temperatureUnit: String?   // ✅ usually String, but make optional-safe

        let shortForecast: String
        let detailedForecast: String?
        let probabilityOfPrecipitation: ProbabilityOfPrecipitation?

        struct ProbabilityOfPrecipitation: Decodable {
            let value: Int?
        }
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
        guard NotificationsManager.shared.alertsNotificationsEnabled else { return }

        for a in alerts.prefix(2) {
            let id = a.id

            if NotificationsManager.shared.hasNotifiedAlert(id: id) {
                continue
            }

            let event = a.properties.event
            let headline = a.properties.headline ?? a.properties.areaDesc ?? ""
            let place = (locationTitle?.isEmpty == false) ? " • \(locationTitle!)" : ""

            let didSchedule = await NotificationsManager.shared.postNewAlertNotification(
                title: "\(event)\(place)",
                body: headline,
                id: id
            )

            // ✅ Only mark as notified if we actually scheduled it
            if didSchedule {
                NotificationsManager.shared.markAlertNotified(id: id)
            }
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
//            print("🌦️ forecast refresh lat=\(coord.latitude) lon=\(coord.longitude)")
            periods = try await service.fetch7DayPeriods(lat: coord.latitude, lon: coord.longitude)
            errorMessage = nil
        } catch {
            // ✅ Treat cancellations as normal (don’t show an error)
            if error is CancellationError { return }
            if let urlErr = error as? URLError, urlErr.code == .cancelled { return }
//            print("🌦️ forecast ERROR:", error)
            errorMessage = "Forecast unavailable at this time."
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

// MARK: - WeatherAPI.com 3-day Forecast

struct WeatherAPIForecastResponse: Decodable {
    struct Forecast: Decodable {
        let forecastday: [ForecastDay]
    }

    struct ForecastDay: Decodable, Identifiable {
        var id: String { date }

        let date: String               // "yyyy-MM-dd"
        let day: Day

        struct Day: Decodable {
            let maxtemp_f: Double
            let mintemp_f: Double
            let daily_chance_of_rain: Int?
            let condition: Condition

            struct Condition: Decodable {
                let text: String
            }

            enum CodingKeys: String, CodingKey {
                case maxtemp_f, mintemp_f, daily_chance_of_rain, condition
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                maxtemp_f = try c.decode(Double.self, forKey: .maxtemp_f)
                mintemp_f = try c.decode(Double.self, forKey: .mintemp_f)
                condition = try c.decode(Condition.self, forKey: .condition)

                // WeatherAPI may return this as either a string or a number depending on plan/endpoint.
                if let i = try? c.decode(Int.self, forKey: .daily_chance_of_rain) {
                    daily_chance_of_rain = i
                } else if let s = try? c.decode(String.self, forKey: .daily_chance_of_rain), let i = Int(s) {
                    daily_chance_of_rain = i
                } else {
                    daily_chance_of_rain = nil
                }
            }
        }
    }

    let forecast: Forecast
}

enum WeatherAPIServiceError: Error {
    case missingKey
    case invalidURL
    case badStatus(Int)
}

final class WeatherAPIService {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    func fetchForecast(lat: Double, lon: Double, apiKey: String) async throws -> [WeatherAPIForecastResponse.ForecastDay] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WeatherAPIServiceError.missingKey }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.weatherapi.com"
        comps.path = "/v1/forecast.json"
        comps.queryItems = [
            URLQueryItem(name: "key", value: trimmed),
            URLQueryItem(name: "q", value: "\(lat),\(lon)"),
            URLQueryItem(name: "days", value: "7"),
//            URLQueryItem(name: "days", value: "\(days)"),
            URLQueryItem(name: "aqi", value: "no"),
            URLQueryItem(name: "alerts", value: "no")
        ]

        guard let url = comps.url else { throw WeatherAPIServiceError.invalidURL }

        var req = URLRequest(url: url)
        req.setValue("Yawa NOAA (personal app)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WeatherAPIServiceError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(WeatherAPIForecastResponse.self, from: data)
        return decoded.forecast.forecastday
    }
}

@MainActor
final class WeatherAPIForecastViewModel: ObservableObject {
    struct DayRow: Identifiable, Equatable {
        let id: String                 // "yyyy-MM-dd"
        let weekday: String            // "Sun"
        let dateText: String           // "1/18"
        let conditionText: String
        let hiF: Int
        let loF: Int
        let chanceRain: Int?
    }

    @Published var days: [DayRow] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = WeatherAPIService()
    private var lastCoord: CLLocationCoordinate2D?

    private let weekdayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = "EEE"
        return df
    }()

    
    private let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = "M/d"
        return df
    }()
    
    private let dateParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    func loadIfNeeded(for coord: CLLocationCoordinate2D) async {
        if let last = lastCoord,
           abs(last.latitude - coord.latitude) < 0.01,
           abs(last.longitude - coord.longitude) < 0.01,
           !days.isEmpty {
            return
        }

        lastCoord = coord
        await refresh(for: coord)
    }

    func refresh(for coord: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        let key = (UserDefaults.standard.string(forKey: "weatherApiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else {
            days = []
            errorMessage = "Enter a WeatherAPI key in Settings to enable forecast."
            return
        }

        do {
            let forecastDays = try await service.fetchForecast(lat: coord.latitude, lon: coord.longitude, apiKey: key)

            days = forecastDays.map { fd in
                let date = fd.date

                let weekday: String
                let dateText: String
                if let parsed = dateParser.date(from: date) {
                    weekday = weekdayFormatter.string(from: parsed)
                    dateText = shortDateFormatter.string(from: parsed)
                } else {
                    weekday = date
                    dateText = ""
                }

                let hi = Int(fd.day.maxtemp_f.rounded())
                let lo = Int(fd.day.mintemp_f.rounded())
                let chance: Int? = fd.day.daily_chance_of_rain

                return DayRow(
                    id: date,
                    weekday: weekday,
                    dateText: dateText,
                    conditionText: fd.day.condition.text,
                    hiF: hi,
                    loF: lo,
                    chanceRain: chance
                )
            }

            errorMessage = nil
        } catch {
            if error is CancellationError { return }
            if let urlErr = error as? URLError, urlErr.code == .cancelled { return }

            days = []

            if let svc = error as? WeatherAPIServiceError {
                switch svc {
                case .missingKey:
                    errorMessage = "Enter a WeatherAPI key in Settings to enable forecast."
                case .invalidURL:
                    errorMessage = "Forecast configuration error."
                case .badStatus(let code):
                    if code == 401 || code == 403 {
                        errorMessage = "WeatherAPI rejected the key (HTTP \(code)). Check your key in Settings."
                    } else if code == 429 {
                        errorMessage = "WeatherAPI rate limit hit (HTTP 429). Try again later."
                    } else {
                        errorMessage = "WeatherAPI request failed (HTTP \(code))."
                    }
                }
                return
            }

            // Fallback
            errorMessage = "Forecast unavailable at this time."
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












