//
//  WeatherService.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/15/25.
//


import Foundation

struct WeatherService {
    enum ServiceError: Error {
        case missingConfigFile
        case missingKey(String)
        case invalidURL
        case httpStatus(Int)
        case noObservations
        case missingPWSCredentials
    }

    struct WeatherResponse: Decodable { let observations: [Observation] }

    struct Observation: Decodable {
        struct Imperial: Decodable {
            let temp: Double
            let windSpeed: Double
            let pressure: Double
            let precipTotal: Double
            let windGust: Double
        }
        let winddir: Double
        let humidity: Double
        let imperial: Imperial
        let lat: Double?
        let lon: Double?
    }

    struct Snapshot: Codable {
        let tempF: Int
        let humidityPct: Int
        let windSpeed: Int
        let windGust: Int
        let windDirDegrees: Int
        let windDirText: String
        let pressure: String
        let precip: String
        let lastUpdated: Date
    }

    // MARK: - Public API

    func fetchCurrent() async throws -> Snapshot {
        // Prefer user-entered values from Settings (AppStorage), fall back to bundled config.plist
        let defaults = UserDefaults.standard
        let storedStation = (defaults.string(forKey: "pwsStationID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedKey = (defaults.string(forKey: "pwsApiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let stationID: String
        let apiKey: String

        if !storedStation.isEmpty && !storedKey.isEmpty {
            stationID = storedStation
            apiKey = storedKey
        } else {
            // Fallback to bundled config.plist for backwards compatibility
            let cfgStation = (try? configValue("stationID"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cfgKey = (try? configValue("WU_API_KEY"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !cfgStation.isEmpty, !cfgKey.isEmpty else {
                throw ServiceError.missingPWSCredentials
            }

            stationID = cfgStation
            apiKey = cfgKey
        }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.weather.com"
        comps.path = "/v2/pws/observations/current"
        comps.queryItems = [
            URLQueryItem(name: "stationId", value: stationID),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "units", value: "e"),
            URLQueryItem(name: "apiKey", value: apiKey)
        ]

        guard let url = comps.url else { throw ServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ServiceError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(WeatherResponse.self, from: data)
        guard let obs = decoded.observations.first else { throw ServiceError.noObservations }

        // Persist PWS station coordinate (if present) so PWS-mode forecast can anchor to the station
        if let lat = obs.lat, let lon = obs.lon {
            defaults.set(lat, forKey: "pwsStationLat")
            defaults.set(lon, forKey: "pwsStationLon")
        }

        let windDeg = Int(obs.winddir)
        let windText = compassDirection(from: windDeg)

        return Snapshot(
            tempF: Int(obs.imperial.temp),
            humidityPct: Int(obs.humidity),
            windSpeed: Int(obs.imperial.windSpeed),
            windGust: Int(obs.imperial.windGust),
            windDirDegrees: windDeg,
            windDirText: windText,
            pressure: String(format: "%.2f", obs.imperial.pressure),
            precip: String(format: "%.2f", obs.imperial.precipTotal),
            lastUpdated: Date()
        )
    }
    // MARK: - Config

    private func configValue(_ key: String) throws -> String {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            throw ServiceError.missingConfigFile
        }

        guard let value = plist[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ServiceError.missingKey(key)
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compassDirection(from degrees: Int) -> String {
        let directions = [
            "N", "NNE", "NE", "ENE",
            "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW",
            "W", "WNW", "NW", "NNW"
        ]
        let index = Int((Double(degrees) / 22.5).rounded()) % 16
        return directions[index]
    }
}
