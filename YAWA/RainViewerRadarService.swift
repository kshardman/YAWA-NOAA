//
//  RainViewerWeatherMapsResponse.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


import Foundation

struct RainViewerWeatherMapsResponse: Decodable {
    struct Frame: Decodable {
        let time: Int
        let path: String
    }
    struct Radar: Decodable {
        let past: [Frame]?
        let nowcast: [Frame]?
    }

    let version: String
    let generated: Int
    let host: String
    let radar: Radar
}

/// Fetches the latest RainViewer radar frame catalog.
/// Docs: https://api.rainviewer.com/public/weather-maps.json  [oai_citation:3‡Rain Viewer](https://www.rainviewer.com/api/weather-maps-api.html)
final class RainViewerRadarService {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadRevalidatingCacheData
        self.session = URLSession(configuration: cfg)
    }

    func fetchWeatherMaps() async throws -> RainViewerWeatherMapsResponse {
        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RainViewerWeatherMapsResponse.self, from: data)
    }

    /// Choose a reasonable default frame: latest "past" if available, else latest "nowcast".
    func pickDefaultFrame(from maps: RainViewerWeatherMapsResponse) -> RainViewerWeatherMapsResponse.Frame? {
        if let past = maps.radar.past, let last = past.last { return last }
        if let now = maps.radar.nowcast, let last = now.last { return last }
        return nil
    }
}