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
    
    private let instanceID = UUID()
    
    @State private var didLoadFrames = false
    
    @State private var didStartPlayback = false
    
    // Consumer-friendly: start close (MapKit controls zoom; this is “radius shown”)
    private let initialRadiusMeters: CLLocationDistance = 75_000 //  tweak as desired

    var body: some View {
        NavigationStack {
            ZStack {
                YAWATheme.sky.ignoresSafeArea()

                if let host, !frames.isEmpty {
                    let frame = frames[frameIndex]

                    RadarMapView(
                        center: CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude),
                        initialRadiusMeters: initialRadiusMeters,
                        overlay: .init(
                            host: host,
                            framePath: frame.path,
                            opacity: 0.7
                        ),
                        animateTransition: didStartPlayback
  //                      animateTransition: isPlaying
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
//            .task {
//                await loadFrames()
//            }
            .task {
//                print("RadarView instance:", instanceID)
                guard !didLoadFrames else { return }
                didLoadFrames = true
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

//        print("loadFrames() CALLED", Date())
        
        do {
            let maps = try await service.fetchWeatherMaps()

            // Pick a fallback frame in case "past" is empty
            guard let fallbackFrame = service.pickDefaultFrame(from: maps) else {
                errorText = "No radar frames available."
                return
            }

            self.host = maps.host

            // Keep playback lightweight: last 8 frames only
            let past = maps.radar.past ?? []
            let trimmed = Array(past.suffix(8))

            self.frames = trimmed.isEmpty ? [fallbackFrame] : trimmed
            self.frameIndex = max(0, self.frames.count - 1)
        } catch {
            errorText = "Couldn’t load radar tiles."
        }        // remove this sometime
    }

    private func togglePlay() {
        if isPlaying {
            stopTick()
        } else {
            didStartPlayback = false
            startTick()
        }
    }

    private func startTick() {
        stopTick()
        isPlaying = true

        tickTask = Task { @MainActor in
            guard frames.count >= 2 else { return }

            while !Task.isCancelled {
                // wait first so Play doesn’t instantly jump
//                try? await Task.sleep(nanoseconds: 1_350_000_000)
                try? await Task.sleep(nanoseconds: 1_350_000_000)
                didStartPlayback = true
                frameIndex = (frameIndex - 1 + frames.count) % frames.count

                guard !Task.isCancelled else { return }
                guard !frames.isEmpty else { return }

                frameIndex = (frameIndex - 1 + frames.count) % frames.count
            }
        }
    }

    private func stopTick() {
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
    }
}
