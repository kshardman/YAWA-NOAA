import SwiftUI
import UIKit
import Combine
import CoreLocation

struct ContentView: View {
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var viewModel = WeatherViewModel()
    @StateObject private var location = LocationManager()
    
    @EnvironmentObject private var favorites: FavoritesStore
    
    @State private var showingLocations = false
    @State private var selectedFavorite: FavoriteLocation? = nil
    @State private var previousSourceRaw: String? = nil
    
    
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    // Manual refresh UI state (spinner + “Refreshing…”)
    @State private var isManualRefreshing = false

    // Settings sheet
    @State private var showingSettings = false

    private var tileBackground: some ShapeStyle {
        Color(.secondarySystemBackground)
    }
 
    @AppStorage("currentConditionsSource")
    private var sourceRaw: String = CurrentConditionsSource.noaa.rawValue

    private var source: CurrentConditionsSource {
        get { CurrentConditionsSource(rawValue: sourceRaw) ?? .noaa }
        set { sourceRaw = newValue.rawValue }
    }
    
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {

                        // MARK: Header (no background)
                        VStack(spacing: 10) {
                            VStack(spacing: 2) {
                                Text("Current Conditions")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)

                                let headerLocation = selectedFavorite?.displayName ?? viewModel.currentLocationLabel
                                let isCurrentGPS = (selectedFavorite == nil) && (source == .noaa)

                                if !headerLocation.isEmpty {
                                    HStack(spacing: 6) {
                                        Text(headerLocation)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        
                                        if isCurrentGPS {
                                            Image(systemName: "location.circle")
                                                .imageScale(.small)
                                                .foregroundStyle(.secondary)
                                        }

                                    }
                                }
                                
                                if source == .pws, !viewModel.pwsLabel.isEmpty {
                                    Text("\(viewModel.pwsLabel) • PWS")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            // Spinner + animated text change
                            UpdatedStatusRow(
                                text: isManualRefreshing ? "Refreshing…" : viewModel.lastUpdatedText,
                                isRefreshing: isManualRefreshing,
                                color: .secondary
                            )
                            .animation(.easeInOut(duration: 0.25), value: isManualRefreshing)
                            .animation(.easeInOut(duration: 0.25), value: viewModel.lastUpdated)

                            if !networkMonitor.isOnline {
                                pill("Offline — showing last update", "wifi.slash")
                            }

                            if let msg = viewModel.errorMessage {
                                pill(msg, "exclamationmark.triangle.fill")
                            }

                            if viewModel.isStale {
                                pill("STALE", "clock.badge.exclamationmark")
                            }
                        }

                        // MARK: Tiles
                        VStack(spacing: 14) {

                            // Row 1: Temperature (big)
                            tile(
                                "thermometer",
                                .red,
                                viewModel.temp,
                                "Temp",
                                valueFont: .system(size: 44, weight: .semibold)
                            )

                            // Row 2: Wind + Conditions/Rain
                            HStack(spacing: 14) {
                                tile("wind", .teal, viewModel.windDisplay, "Wind")

                                if source == .noaa {
                                    let hour = Calendar.current.component(.hour, from: Date())
                                    let isNight = hour < 6 || hour >= 18
                                    let sym = conditionsSymbolAndColor(for: viewModel.conditions, isNight: isNight)

                                    tile(sym.symbol, sym.color, viewModel.conditions, "Conditions")
                                } else {
                                    tile("cloud.rain", .blue, viewModel.precipitation, "Rain today")
                                }
                            }

                            // Row 3: Humidity + Pressure
                            HStack(spacing: 14) {
                                wideTile("drop", .blue, viewModel.humidity, "Humidity")
                                wideTile("gauge", .orange, viewModel.pressure, "Pressure")
                            }
                        }

                        // MARK: 7-Day Forecast Card
                        NavigationLink {
                            ForecastView()
                        } label: {
                            ZStack {
                                // Centered content
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar")
                                        .font(.title3)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.blue)

                                    VStack(alignment: .center, spacing: 2) {
                                        Text("Daily Forecast")
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text("Tap to view NOAA outlooks")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)

                                // Right chevron overlay
                                HStack {
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(cardBackground())
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                // ✅ IMPORTANT: refreshable MUST be on ScrollView
                .refreshable {
                    isManualRefreshing = true
                    defer { isManualRefreshing = false }

                    if let f = selectedFavorite {
                        await viewModel.fetchCurrentFromNOAA(
                            lat: f.coordinate.latitude,
                            lon: f.coordinate.longitude,
                            locationName: f.displayName
                        )
                    } else {
                        await viewModel.refreshCurrentConditions(
                            source: source,
                            coord: location.coordinate,
                            locationName: location.locationName
                        )
                    }

                    successHaptic()
                }
                }
            .task {
                viewModel.loadCached()
                location.request()

                // Optional: kick a refresh right away if we already have a coord
                await viewModel.refreshCurrentConditions(
                    source: source,
                    coord: location.coordinate,
                    locationName: location.locationName
                )
            }
            .onReceive(location.$coordinate) { coord in
                guard coord != nil else { return }
                Task {
                    await viewModel.refreshCurrentConditions(
                        source: source,
                        coord: location.coordinate,
                        locationName: location.locationName
                    )
                }
            }
                .onReceive(location.$locationName) { name in
                    guard let name, !name.isEmpty else { return }
                    viewModel.currentLocationLabel = name
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await viewModel.refreshCurrentConditions(
                            source: source,
                            coord: location.coordinate,
                            locationName: location.locationName
                        )
                    }
                }
                .onChange(of: sourceRaw) { oldValue, newValue in
                    if newValue == CurrentConditionsSource.pws.rawValue {
                        selectedFavorite = nil
                    }
                }
                .onChange(of: sourceRaw) { _, _ in
                    Task {
                        await viewModel.refreshCurrentConditions(
                            source: source,
                            coord: location.coordinate,
                            locationName: location.locationName
                        )
                    }
                }
                .navigationTitle("Nimbus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {

                    Button {
                        showingLocations = true
                    } label: {
                        Image(systemName: "star.circle")
                    }
                    .accessibilityLabel("Choose location")

                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingLocations) {
                NavigationStack {
                    List {

                        Section {
                            Button {
                                selectedFavorite = nil
                                showingLocations = false

                                if let coord = location.coordinate {
                                    Task {
                                        await viewModel.fetchCurrentFromNOAA(
                                            lat: coord.latitude,
                                            lon: coord.longitude,
                                            locationName: location.locationName
                                        )
                                    }
                                } else {
                                    location.request()
                                }
                            } label: {
                                HStack {
                                    Text("Current Location")
                                    Spacer()
                                    if selectedFavorite == nil { Image(systemName: "checkmark") }
                                }
                            }
                        }

                        Section("Favorites") {
                            if favorites.favorites.isEmpty {
                                Text("No favorites yet.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(favorites.favorites) { f in
                                    Button {
                                        selectedFavorite = f
                                        showingLocations = false

                                        // Save the user's current source (once) so we can restore it when they go back to Current Location
                                        if previousSourceRaw == nil {
                                            previousSourceRaw = sourceRaw
                                        }

                                        // Favorites always use NOAA current conditions
                                        sourceRaw = CurrentConditionsSource.noaa.rawValue
                                        viewModel.pwsLabel = ""   // hide PWS station label immediately

                                        Task {
                                            await viewModel.fetchCurrentFromNOAA(
                                                lat: f.coordinate.latitude,
                                                lon: f.coordinate.longitude,
                                                locationName: f.displayName
                                            )
                                        }
                                    } label: {
                                        HStack {
                                            Text(f.displayName)
                                            Spacer()
                                            if selectedFavorite?.id == f.id {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Locations")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingLocations = false }
                        }
                    }
                }
            }
        }
    }

    // MARK: - UI components

    private func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.tertiarySystemBackground))   // ✅ closest List row match
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        scheme == .light
                            ? Color.black.opacity(0.08)
                            : Color.white.opacity(0.04),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(scheme == .light ? 0.10 : 0.03),
                radius: scheme == .light ? 12 : 6,
                y: scheme == .light ? 6 : 3
            )
    }

    private func pill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }

    func tile(
        _ systemImage: String,
        _ color: Color,
        _ value: String,
        _ label: String,
        valueFont: Font = .title3
    ) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.title2)

            Text(value)
                .font(valueFont)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    func wideTile(
        _ systemImage: String,
        _ color: Color,
        _ value: String,
        _ label: String
    ) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.title2)

            Text(value)
                .font(.title3)                // slightly smaller than title2
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .background(tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Animated updated row + spinner

private struct UpdatedStatusRow: View {
    let text: String
    let isRefreshing: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
                    .transition(.opacity.combined(with: .scale))
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(color)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
    }
}

// MARK: - Helpers

private func successHaptic() {
    let gen = UINotificationFeedbackGenerator()
    gen.prepare()
    gen.notificationOccurred(.success)
}



#Preview { ContentView() }
