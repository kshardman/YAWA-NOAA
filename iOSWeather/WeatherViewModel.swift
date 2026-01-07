//
//  WeatherViewModel.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/17/25.
//


//
//  WeatherViewModel.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/15/25.
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class WeatherViewModel: ObservableObject {

    // MARK: - Display values (UI-facing)

    @Published var temp: String = "--"
    @Published var humidity: String = "--"
    @Published var wind: String = "--"
    @Published var windDirection: String = ""
    @Published var pressure: String = "--"
    @Published var precipitation: String = "--"
    @Published var windGust: String = "--"
    @Published var windDirectionDegrees: Int = 0
    @Published var lastUpdated: Date?
    @Published var errorMessage: String? = nil
    @Published var conditions: String = "—"
    @Published var noaaStationName: String = ""
    @Published var noaaStationId: String = ""

    // MARK: - Numeric values (logic/theme-facing)

    @Published var temperatureF: Double?
    @Published var precipitationInches: Double?
    @Published var currentLocationLabel: String = ""
    @Published var pwsStationName: String = ""
    @Published var pwsLabel: String = ""

    // MARK: - Fetch tracking

    @Published var lastFetchAttempt: Date?
    @Published var lastSuccess: Date?
    @Published private(set) var isFetching = false
    @Published var isRefreshingUI: Bool = false
    
    @Published var noaaStationID: String = ""   // DEBUG
    
    private var pendingForceRefresh = false
    private var activeFetchTask: Task<Bool, Never>?

    private let service = WeatherService()
    private let noaaCurrent = NOAACurrentConditionsService()
   
    // ✅ Visual cue: clear tile values while we fetch new data
    func setLoadingPlaceholders() {
        temp = "--"
        humidity = "--"
        wind = "--"
        pressure = "--"
        precipitation = "--"
        windGust = "--"
        windDirection = ""
        windDirectionDegrees = 0

        // Conditions tile: you can use "—" or "--"
        conditions = "—"

        // Optional: clear station label so it doesn’t look stale during refresh
        // noaaStationId = ""
        // noaaStationName = ""

        errorMessage = nil
    }
    
    /// True when one or more key tiles are missing/unknown
    var isNOAADataPartial: Bool {
        // Any tile showing placeholder / missing data
        temp == "—" ||
        humidity == "—" ||
        windDisplay == "—" ||
        pressure == "—" ||
        conditions.isEmpty
    }
  
    
    var windDisplay: String {
        let windValue = extractInt(from: wind)
        let gustValue = extractInt(from: windGust)

        if windValue == 0 && gustValue == 0 {
            return "CALM"
        }

        // Gust only
        if windValue == 0 && gustValue > 0 {
            return "Gust \(gustValue)"
        }

        let dir = windDirection.isEmpty ? "" : "\(windDirection) "
        let gust = gustValue > windValue ? " G\(gustValue)" : ""

        return "\(dir)\(windValue)\(gust)"
    }
    
    
    private func extractInt(from text: String) -> Int {
        let pattern = #"[-+]?\d+"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return Int(text[range]) ?? 0
        }
        return 0
    }
 
    // MARK: - PWS helpers
       func loadPwsLabelIfNeeded() {
           guard pwsLabel.isEmpty else { return }
           pwsLabel = (try? configValue("stationID")) ?? ""
       }

    // MARK: - Derived UI state

    var isStale: Bool {
        guard let lastUpdated else { return false }
        return Date().timeIntervalSince(lastUpdated) > 900   // 15 minutes
    }

    var lastUpdatedText: String {
        guard let lastUpdated else { return "—" }

        let delta = Date().timeIntervalSince(lastUpdated)
        if delta < 60 {
            return "Updated just now"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named

        let relative = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        return "Updated \(relative)"
    }
    // MARK: - Public API

    func loadCached() {
        guard let snap = WeatherCache.load() else { return }
        apply(snap)
    }
    
    func refreshCurrentConditions(
        source: CurrentConditionsSource,
        coord: CLLocationCoordinate2D?,
        locationName: String?
    ) async {
        switch source {
        case .noaa:
            guard let coord else {
                errorMessage = "Location unavailable."
                return
            }
            await fetchCurrentFromNOAA(
                lat: coord.latitude,
                lon: coord.longitude,
                locationName: locationName ?? currentLocationLabel
            )

        case .pws:
            loadPwsLabelIfNeeded()
            _ = await fetchWeather(force: true)
        }
    }
    
    /// Fetches weather from the network.
    /// - force: bypasses cooldown (used for pull-to-refresh)
    @discardableResult
    func fetchWeather(force: Bool = false) async -> Bool {

        // If manual refresh, cancel whatever is currently running and start fresh
        if force {
            activeFetchTask?.cancel()
            pendingForceRefresh = false
            errorMessage = nil
        }

        // If a task is already running and this isn't forced, just return
        if let task = activeFetchTask, !task.isCancelled {
            if force { pendingForceRefresh = true }
            return false
        }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }

            self.isFetching = true
            defer { self.isFetching = false }

            do {
                let snap = try await self.service.fetchCurrent()
                self.apply(snap)
                WeatherCache.save(snap)
                self.lastSuccess = Date()
                self.errorMessage = nil

                if force {
                    self.lastUpdated = Date()   // ✅ Updated just now on manual refresh
                }

                return true
            } catch {
                // Cancellation is expected when we force-refresh
                if error is CancellationError { return false }
                if let urlErr = error as? URLError, urlErr.code == .cancelled { return false }

                self.errorMessage = userFriendly(error)
                return false
            }
        }

        activeFetchTask = task
        let ok = await task.value
        activeFetchTask = nil

        // If a force refresh was queued during a non-forced fetch, run it now
        if pendingForceRefresh {
            pendingForceRefresh = false
            return await fetchWeather(force: true)
        }

        return ok
    }

//    @MainActor
    @MainActor
    func fetchCurrentFromNOAA(lat: Double, lon: Double, locationName: String? = nil) async {
        do {
            let result = try await noaaCurrent.fetchLatestObservation(lat: lat, lon: lon)
            noaaStationID = result.stationId
            noaaStationName = result.stationName ?? ""
            let o = result.obs

            // Temperature (degC -> F)
            if let c = o.temperature?.value {
                let f = NOAAUnits.cToF(c)
                temp = "\(Int(f.rounded()))°"   // 👈 change here
            } else {
                temp = "—"
            }

            // Humidity (%)
            if let h = o.relativeHumidity?.value {
                humidity = "\(Int(h.rounded()))%"
            } else {
                humidity = "—"
            }

            // Wind (m/s -> mph), direction degrees -> compass
            let windMph = (o.windSpeed?.value).map {
                NOAAUnits.speedToMph(value: $0, unitCode: o.windSpeed?.unitCode)
            } ?? 0

            let gustMph = (o.windGust?.value).map {
                NOAAUnits.speedToMph(value: $0, unitCode: o.windGust?.unitCode)
            } ?? 0

            let windDeg = Int((o.windDirection?.value ?? 0).rounded())
            let dirText = NOAAUnits.degreesToCompass(windDeg)

            let w = Int(windMph.rounded())
            let g = Int(gustMph.rounded())

            if w == 0 && g == 0 {
                wind = "0 mph"
                windGust = "0 mph"
                windDirection = ""
                // (windDisplay will become CALM via your computed property)
            } else {
                windDirection = dirText
                wind = "\(w) mph"
                windGust = "\(g) mph"
                // windDisplay computed property will format nicely
            }

            // Pressure (Pa -> inHg)
            if let pa = o.barometricPressure?.value {
                let inHg = NOAAUnits.paToInHg(pa)
                pressure = String(format: "%.2f", inHg)
            } else {
                pressure = "—"
            }

            // NOAA conditions text
            conditions = o.textDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
            
            precipitation = "—"
            lastUpdated = Date()
            lastSuccess = Date()

            // ✅ Only update the label when we have a real city/state.
            // Never overwrite a good label with the fallback.
            if let locationName, !locationName.isEmpty {
                currentLocationLabel = locationName
            } else if currentLocationLabel.isEmpty {
                currentLocationLabel = "Current Location"
            }

            errorMessage = nil

        } catch {
            // ✅ Treat cancellations as normal (don’t show an error)
            if error is CancellationError { return }
            if let urlErr = error as? URLError, urlErr.code == .cancelled { return }

            // Optional: log the real error while debugging
            print("NOAA current conditions error:", error)

            errorMessage = "NOAA current conditions unavailable."
        }
    }
    
    
    // MARK: - Private helpers

    private func apply(_ snap: WeatherService.Snapshot) {

        // ---- Numeric values (used for theme logic) ----
        temperatureF = Double(snap.tempF)
        precipitationInches = Double(snap.precip) ?? 0.0

        // ---- Display strings ----
        temp = "\(snap.tempF)°"
        humidity = "\(snap.humidityPct)%"
        wind = "\(snap.windSpeed)"
        windGust = "\(snap.windGust)"
        windDirectionDegrees = snap.windDirDegrees
        windDirection = snap.windDirText
        pressure = snap.pressure
        precipitation = String(format: "%.2f in", Double(snap.precip) ?? 0.0)
        lastUpdated = snap.lastUpdated
    }
}

// MARK: - Error formatting

private func userFriendly(_ error: Error) -> String {

    if let e = error as? WeatherService.ServiceError {
        switch e {
        case .missingConfigFile:
            return "Missing config.plist in app bundle"
        case .missingKey(let key):
            return "Missing \(key) in config.plist"
        default:
            return "Weather service error"
        }
    }

    if let url = error as? URLError {
        switch url.code {
        case .notConnectedToInternet:
            return "No internet connection"
        case .timedOut:
            return "Network request timed out"
        case .cannotFindHost, .cannotConnectToHost:
            return "Cannot reach server"
        case .networkConnectionLost:
            return "Network connection was lost"
        default:
            return "Network error"
        }
    }

    return "Something went wrong"
}

private func extractNumber(from text: String) -> Int {
    let pattern = #"[-+]?\d+"#
    if let range = text.range(of: pattern, options: .regularExpression) {
        return Int(text[range]) ?? 0
    }
    return 0
}


// MARK: - Simple cache

enum WeatherCache {
    private static let key = "latestWeatherSnapshot"

    static func save(_ snap: WeatherService.Snapshot) {
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> WeatherService.Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WeatherService.Snapshot.self, from: data)
    }
}
