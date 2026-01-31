//
//  ForecastViewModel.swift
//  YAWA
//
//  Created by Keith Sharman on 1/30/26.
//

import SwiftUI
import Combine
import CoreLocation


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
        print("[NET] loadifneeded")
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
        print("[NET] loadalertsifneeded")
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
        print("[NET] refresh for coord")
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
        print("[NET] fetchactivealerts")
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
        print("[NET] fetch7dayperiods")
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


