import SwiftUI
import CoreLocation

struct RadarView: View {
    let target: RadarTarget

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var errorText: String?

    @State private var host: String?
    @State private var frames: [RainViewerWeatherMapsResponse.Frame] = []
    @State private var frameIndex: Int = 0

    @State private var isPlaying = false
    @State private var tickTask: Task<Void, Never>?

    private let service = RainViewerRadarService()

    // Consumer-friendly: start close (MapKit controls zoom; this is “radius shown”)
    private let initialRadiusMeters: CLLocationDistance = 60_000 //  tweak as desired

    var body: some View {
        NavigationStack {
            ZStack {
                YAWATheme.sky.ignoresSafeArea()

                if let host, !frames.isEmpty {
                    let frame = frames[frameIndex]

                    RadarMapView(
                        center: CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude),
                        initialRadiusMeters: initialRadiusMeters,
                        overlay: .init(host: host, framePath: frame.path, opacity: 0.70)
                    )
                    .ignoresSafeArea(edges: .bottom)

                } else if let errorText {
                    VStack(spacing: 10) {
                        Text("Radar unavailable")
                            .font(.headline)
                            .foregroundStyle(YAWATheme.textPrimary)
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(YAWATheme.textSecondary)
                    }
                    .padding()
                }

                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
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
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(frames.count < 2)
                    .accessibilityLabel(isPlaying ? "Pause radar" : "Play radar")
                }
            }
            .task {
                await loadFrames()
            }
            .onDisappear {
                stopTick()
            }
        }
    }

    private func loadFrames() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let maps = try await service.fetchWeatherMaps()
            guard let frame = service.pickDefaultFrame(from: maps) else {
                errorText = "No radar frames available."
                return
            }

            self.host = maps.host
            // Use “past” for playback; it’s usually 2 hours in 10-min steps.  [oai_citation:8‡Rain Viewer](https://www.rainviewer.com/api/weather-maps-api.html)
            let past = maps.radar.past ?? [frame]
            self.frames = past
            self.frameIndex = max(0, past.count - 1) // start at latest
        } catch {
            errorText = "Couldn’t load radar tiles."
        }
    }

    private func togglePlay() {
        if isPlaying {
            stopTick()
        } else {
            startTick()
        }
    }

    private func startTick() {
        stopTick()
        isPlaying = true

        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                // Step backward through time, loop
                if frames.isEmpty { return }
                frameIndex = (frameIndex - 1 + frames.count) % frames.count
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s per frame
            }
        }
    }

    private func stopTick() {
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
    }
}
