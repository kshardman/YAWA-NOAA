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

// MARK: - Location

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    // City, ST for display
    @Published var locationName: String?

    private let manager = CLLocationManager()
    private var lastGeocodedCoord: CLLocationCoordinate2D?
    

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

//    @available(iOS, deprecated: 26.0)
    private func reverseGeocodeIfNeeded(for location: CLLocation) async {
        if let last = lastGeocodedCoord {
            let dLat = abs(last.latitude - location.coordinate.latitude)
            let dLon = abs(last.longitude - location.coordinate.longitude)
            if dLat < 0.01 && dLon < 0.01 { return }
        }
        lastGeocodedCoord = location.coordinate

        let pm = MKPlacemark(
            coordinate: location.coordinate,
            addressDictionary: nil
        )

        let city = pm.locality
        let state = pm.administrativeArea

        await MainActor.run {
            if let city, let state {
                locationName = "\(city), \(state)"
            } else if let city {
                locationName = city
            } else if let state {
                locationName = state
            } else {
                locationName = nil
            }
        }
    }
}


// MARK: - NOAA/NWS API models

struct NWSAlertsResponse: Decodable {
    struct Feature: Decodable, Identifiable {
        struct Properties: Decodable {
            let event: String
            let headline: String?
            let severity: String?
            let urgency: String?
            let areaDesc: String?
        }

        let id: String
        let properties: Properties
    }

    let features: [Feature]
}

struct NWSPointsResponse: Decodable {
    struct Properties: Decodable {
        let forecast: String
    }
    let properties: Properties
}

struct NWSForecastResponse: Decodable {
    struct Properties: Decodable {
        let periods: [Period]
    }
    struct Period: Decodable, Identifiable {
        let number: Int
        let name: String
        let startTime: String
        let endTime: String
        let isDaytime: Bool
        let temperature: Int
        let temperatureUnit: String
        let windSpeed: String
        let windDirection: String
        let shortForecast: String

        var id: Int { number }
    }
    let properties: Properties
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

        let decoded = try JSONDecoder().decode(NWSForecastResponse.self, from: forecastData)
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

    func loadIfNeeded(for coord: CLLocationCoordinate2D) async {
        // Prevent refetch spam from minor GPS jitter
        if let last = lastCoord,
           abs(last.latitude - coord.latitude) < 0.01,
           abs(last.longitude - coord.longitude) < 0.01,
           !periods.isEmpty {
            return
        }
        lastCoord = coord
        await refresh(for: coord)
    }

    func refresh(for coord: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let periodsTask = service.fetch7DayPeriods(lat: coord.latitude, lon: coord.longitude)
            async let alertsTask  = service.fetchActiveAlerts(lat: coord.latitude, lon: coord.longitude)

            periods = try await periodsTask
            alerts  = try await alertsTask

            errorMessage = nil
        } catch {
            errorMessage = "Forecast unavailable."
        }
    }
    
    
}

// MARK: - View

private func forecastSymbol(for text: String, isDaytime: Bool) -> String {
    let t = text.lowercased()

    if t.contains("thunder") { return "cloud.bolt.rain.fill" }
    if t.contains("snow") { return "snowflake" }
    if t.contains("sleet") || t.contains("ice") { return "cloud.sleet.fill" }
    if t.contains("rain") || t.contains("showers") { return "cloud.rain.fill" }
    if t.contains("fog") || t.contains("haze") { return "cloud.fog.fill" }
    if t.contains("wind") { return "wind" }

    if t.contains("cloud") {
        return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
    }

    if t.contains("sun") || t.contains("clear") {
        return isDaytime ? "sun.max.fill" : "moon.stars.fill"
    }

    return "cloud.fill"
}

private struct DailyForecast: Identifiable {
    let id: Int
    let name: String

    let day: NWSForecastResponse.Period
    let night: NWSForecastResponse.Period?

    var highText: String { "\(day.temperature)°\(day.temperatureUnit)" }

    var lowText: String {
        if let night {
            return "\(night.temperature)°\(night.temperatureUnit)"
        } else {
            return "\(day.temperature)°\(day.temperatureUnit)"
        }
    }
}

private func combineDayNight(_ periods: [NWSForecastResponse.Period]) -> [DailyForecast] {
    var out: [DailyForecast] = []
    var i = 0

    while i < periods.count {
        let p = periods[i]

        if p.isDaytime {
            let next = (i + 1 < periods.count) ? periods[i + 1] : nil
            let night = (next?.isDaytime == false) ? next : nil

            out.append(DailyForecast(
                id: p.number,
                name: p.name,
                day: p,
                night: night
            ))

            i += (night == nil ? 1 : 2)
        } else {
            // If we start on a night period for some reason, skip it
            i += 1
        }
    }

    return out
}

struct ForecastView: View {
    @StateObject private var location = LocationManager()
    @StateObject private var vm = ForecastViewModel()

    private struct AlertBanner: View {
        let alert: NWSAlertsResponse.Feature

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: symbolForSeverity(alert.properties.severity))
                        .foregroundStyle(.orange)

                    Text(alert.properties.event)
                        .font(.headline)

                    Spacer()
                }

                if let headline = alert.properties.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let area = alert.properties.areaDesc, !area.isEmpty {
                    Text(area)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }

        private func symbolForSeverity(_ severity: String?) -> String {
            switch severity?.lowercased() {
            case "extreme", "severe": return "exclamationmark.octagon.fill"
            case "moderate": return "exclamationmark.triangle.fill"
            default: return "info.circle.fill"
            }
        }
        
    }
    
    
    var body: some View {
        List {
            if let top = vm.alerts.first {
                Section {
                    AlertBanner(alert: top)
                }
            }
            if let msg = location.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }
            if let msg = vm.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }

            ForEach(combineDayNight(Array(vm.periods.prefix(14)))) { d in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(d.name).font(.headline)

                        Spacer()

                        // High / Low
                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.headline)
                    }

                    HStack(spacing: 8) {
                        // Use DAY symbol (recommended)
                        Image(systemName: forecastSymbol(for: d.day.shortForecast, isDaytime: true))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                            .font(.title2)

                        // If you want "symbols only", delete the Text line below
                        Text(d.day.shortForecast)
                            .foregroundStyle(.secondary)
                    }

                    // Optional: keep wind from DAY only (recommended) or remove entirely
                    Text("\(d.day.windDirection) \(d.day.windSpeed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .overlay {
            if vm.isLoading && vm.periods.isEmpty {
                ProgressView("Loading forecast…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("7-Day Forecast")
                        .font(.headline)
                    Text(location.locationName ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            location.request()
        }
        .onReceive(location.$coordinate) { coord in
            guard let coord else { return }
            Task { await vm.loadIfNeeded(for: coord) }
        }
        .refreshable {
            guard let coord = location.coordinate else { return }
            await vm.refresh(for: coord)
        }
    }
}
