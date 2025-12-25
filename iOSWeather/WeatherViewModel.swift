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

    // MARK: - Numeric values (logic/theme-facing)

    @Published var temperatureF: Double?
    @Published var precipitationInches: Double?

    // MARK: - Fetch tracking

    @Published var lastFetchAttempt: Date?
    @Published var lastSuccess: Date?
    @Published private(set) var isFetching = false
    @Published var isRefreshingUI: Bool = false
    private var pendingForceRefresh = false
    private var activeFetchTask: Task<Bool, Never>?

    private let service = WeatherService()
    
    var windDisplay: String {
        let windValue = extractInt(from: wind)
        let gustValue = extractInt(from: windGust)

        if windValue == 0 && gustValue == 0 {
            return "CALM"
        }

        let dir = windDirection.isEmpty ? "" : "\(windDirection) "
        let base = "\(windValue)"
        let gust = gustValue > windValue ? "G\(gustValue)" : ""

        return dir + base + gust
    }

    private func extractInt(from text: String) -> Int {
        let pattern = #"[-+]?\d+"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return Int(text[range]) ?? 0
        }
        return 0
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
    
    // MARK: - Private helpers

    private func apply(_ snap: WeatherService.Snapshot) {

        // ---- Numeric values (used for theme logic) ----
        temperatureF = Double(snap.tempF)
        precipitationInches = Double(snap.precip) ?? 0.0

        // ---- Display strings ----
        temp = "\(snap.tempF)°F"
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
