//
//  RadarView.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


import SwiftUI

struct RadarView: View {
    let target: RadarTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isLoading = true
    @State private var estimatedProgress: Double = 0
    
    @State private var reloadToken = 0
    
    // Tune these later
    private let radarZoom: Double = 9
    
    var body: some View {
        NavigationStack {
            ZStack {
                YAWATheme.sky.ignoresSafeArea()

                if let url = Self.makeNwsWeatherLoopURL(
                    latitude: target.latitude,
                    longitude: target.longitude,
                    zoom: radarZoom
                ) {
                    RadarWebView(
                        url: url,
                        reloadToken: reloadToken,
                        isLoading: $isLoading,
                        estimatedProgress: $estimatedProgress
                    )
                        .ignoresSafeArea(edges: .bottom)

                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView(value: estimatedProgress)
                                .tint(.white)
                                .frame(maxWidth: 240)

                            Text("Loading radar…")
                                .font(.footnote)
                                .foregroundStyle(YAWATheme.textSecondary)
                        }
                        .padding(16)
                        .background(YAWATheme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(YAWATheme.cardStroke, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                } else {
                    VStack(spacing: 10) {
                        Text("Radar unavailable")
                            .font(.headline)
                            .foregroundStyle(YAWATheme.textPrimary)
                        Text("Could not build radar URL.")
                            .font(.footnote)
                            .foregroundStyle(YAWATheme.textSecondary)
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    static func makeNwsWeatherLoopURL(latitude: Double, longitude: Double, zoom: Double) -> URL? {
        var components = URLComponents(string: "https://www.weather.gov/zse/WeatherLoop")
        components?.queryItems = [
            .init(name: "lt", value: String(format: "%.5f", latitude)),
            .init(name: "ln", value: String(format: "%.5f", longitude)),
            .init(name: "zm", value: String(format: "%.1f", zoom)),
            .init(name: "rad", value: "2"),      // radar on
            .init(name: "ltg", value: "1"),      // lightning on (optional)
            .init(name: "namr", value: "2"),     // base reflectivity (common)
            .init(name: "frames", value: "7"),
            .init(name: "intvl", value: "10"),
            .init(name: "label", value: "0"),
            .init(name: "mobile", value: "")
        ]
        return components?.url
    }
    
//    /// NWS Sat/Radar/Lightning loop viewer centered on a point.
//    /// Documented URL parameters include lt, ln, zm, hidemenu, nolabel, etc.  [oai_citation:1‡National Weather Service](https://www.weather.gov/zse/SatRad?utm_source=chatgpt.com)
//    static func makeNwsSatRadURL(latitude: Double, longitude: Double, zoom: Int) -> URL? {
//        var components = URLComponents(string: "https://www.weather.gov/zse/SatRad")
//        components?.queryItems = [
//            .init(name: "lt", value: String(format: "%.5f", latitude)),
//            .init(name: "ln", value: String(format: "%.5f", longitude)),
//            .init(name: "zm", value: "\(max(0, min(12, zoom)))"),
//            .init(name: "hidemenu", value: "1"),
//            .init(name: "nolabel", value: "1")
//        ]
//        return components?.url
//    }
}
