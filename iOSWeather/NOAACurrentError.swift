import Foundation

enum NOAACurrentError: Error {
    case invalidURL
    case badStatus(Int)
    case noStations
    case noLatestObservation
}

final class NOAACurrentConditionsService {

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    // Main entrypoint: fetch the latest observation near a coordinate
    func fetchLatestObservation(lat: Double, lon: Double) async throws -> (stationName: String?, stationId: String, obs: NWSLatestObservationResponse.Properties) {

        // 1) points endpoint -> observationStations URL
        let pointsURL = try makeURL("https://api.weather.gov/points/\(lat),\(lon)")
        var pointsReq = URLRequest(url: pointsURL)
        applyNOAAHeaders(&pointsReq)

        let (pointsData, pointsResp) = try await session.data(for: pointsReq)
        try validate(pointsResp)

        let points = try JSONDecoder().decode(NWSPointsResponse.self, from: pointsData)

        // 2) stations list
        let stationsURL = try makeURL(points.properties.observationStations)
        var stationsReq = URLRequest(url: stationsURL)
        applyNOAAHeaders(&stationsReq)

        let (stationsData, stationsResp) = try await session.data(for: stationsReq)
        try validate(stationsResp)

        let stations = try JSONDecoder().decode(NWSStationsResponse.self, from: stationsData)
        guard let first = stations.features.first else { throw NOAACurrentError.noStations }

        let stationId = first.properties.stationIdentifier
        let stationName = first.properties.name

        // 3) latest observation from that station
        let latestURL = try makeURL("https://api.weather.gov/stations/\(stationId)/observations/latest")
        var latestReq = URLRequest(url: latestURL)
        applyNOAAHeaders(&latestReq)

        let (latestData, latestResp) = try await session.data(for: latestReq)
        try validate(latestResp)

        let decoded = try JSONDecoder().decode(NWSLatestObservationResponse.self, from: latestData)

        return (stationName: stationName, stationId: stationId, obs: decoded.properties)
    }

    // MARK: - Helpers

    private func applyNOAAHeaders(_ req: inout URLRequest) {
        // NOAA asks for a valid User-Agent. Keep it consistent.
        req.setValue("Nimbus (personal app)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
    }

    private func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAACurrentError.badStatus(http.statusCode)
        }
    }

    private func makeURL(_ s: String) throws -> URL {
        guard let url = URL(string: s) else { throw NOAACurrentError.invalidURL }
        return url
    }
}