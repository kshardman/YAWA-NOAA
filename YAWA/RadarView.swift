import SwiftUI

struct RadarView: View {
    let target: RadarTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isLoading = true
    @State private var estimatedProgress: Double = 0

    // Tune these later
    private let zoomLevel = 7

    var body: some View {
        NavigationStack {
            ZStack {
                YAWATheme.sky.ignoresSafeArea()

                if let url = Self.makeNwsSatRadURL(
                    latitude: target.latitude,
                    longitude: target.longitude,
                    zoom: zoomLevel
                ) {
                    RadarWebView(url: url, isLoading: $isLoading, estimatedProgress: $estimatedProgress)
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
                        // Force reload by “changing” the URL: simplest is open in Safari for now
                        if let url = Self.makeNwsSatRadURL(
                            latitude: target.latitude,
                            longitude: target.longitude,
                            zoom: zoomLevel
                        ) {
                            openURL(url)
                        }
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel("Open in Safari")
                }
            }
        }
    }

    /// NWS Sat/Radar/Lightning loop viewer centered on a point.
    /// Documented URL parameters include lt, ln, zm, hidemenu, nolabel, etc.  [oai_citation:1‡National Weather Service](https://www.weather.gov/zse/SatRad?utm_source=chatgpt.com)
    static func makeNwsSatRadURL(latitude: Double, longitude: Double, zoom: Int) -> URL? {
        var components = URLComponents(string: "https://www.weather.gov/zse/SatRad")
        components?.queryItems = [
            .init(name: "lt", value: String(format: "%.5f", latitude)),
            .init(name: "ln", value: String(format: "%.5f", longitude)),
            .init(name: "zm", value: "\(max(0, min(12, zoom)))"),
            .init(name: "hidemenu", value: "1"),
            .init(name: "nolabel", value: "1")
        ]
        return components?.url
    }
}