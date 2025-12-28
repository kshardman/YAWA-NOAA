//
//  LocationManager.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/28/25.
//


import SwiftUI
import CoreLocation
import Combine

// MARK: - Location

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    private let manager = CLLocationManager()

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
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        } else if status == .denied || status == .restricted {
            errorMessage = "Location access is disabled."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Could not get location."
        print("Location error:", error)
    }
}

// MARK: - NOAA/NWS API models

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
            let p = try await service.fetch7DayPeriods(lat: coord.latitude, lon: coord.longitude)
            periods = p
            errorMessage = nil
        } catch {
            errorMessage = "Forecast unavailable."
        }
    }
}

// MARK: - View

struct ForecastView: View {
    @StateObject private var location = LocationManager()
    @StateObject private var vm = ForecastViewModel()

    var body: some View {
        List {
            if let msg = location.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }
            if let msg = vm.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }

            ForEach(vm.periods.prefix(14)) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(p.name).font(.headline)
                        Spacer()
                        Text("\(p.temperature)°\(p.temperatureUnit)")
                            .font(.headline)
                    }

                    Text(p.shortForecast)
                        .foregroundStyle(.secondary)

                    Text("\(p.windDirection) \(p.windSpeed)")
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
        .navigationTitle("7-Day Forecast")
        .navigationBarTitleDisplayMode(.inline)
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
