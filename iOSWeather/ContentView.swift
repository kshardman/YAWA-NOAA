import SwiftUI
import Combine
import UIKit
import CoreLocation

struct ContentView: View {
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var viewModel = WeatherViewModel()
    @StateObject private var location = LocationManager()

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    // Manual refresh UI state (spinner + “Refreshing…”)
    @State private var isManualRefreshing = false

    // Sheets
    @State private var showingSettings = false
    @State private var showingLocations = false

    // When we auto-force NOAA because user picked a favorite while in PWS mode,
    // we’ll restore the previous mode when they go back to “Current Location”.
    @State private var previousSourceRaw: String? = nil

    // Settings source picker
    @AppStorage("currentConditionsSource")
    private var sourceRaw: String = CurrentConditionsSource.noaa.rawValue

    private var source: CurrentConditionsSource {
        get { CurrentConditionsSource(rawValue: sourceRaw) ?? .noaa }
        set { sourceRaw = newValue.rawValue }
    }

    // MARK: - Header derived values (avoid `let` inside ViewBuilder)
    private var headerLocationText: String {
        selection.selectedFavorite?.displayName ?? viewModel.currentLocationLabel
    }

    private var showCurrentLocationGlyph: Bool {
        // Only show location.circle when we are using GPS-driven NOAA,
        // not when a favorite is selected, and not for PWS mode.
        selection.selectedFavorite == nil && source == .noaa
    }

    private var tileBackground: some ShapeStyle {
        Color(.secondarySystemBackground)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {

                        // MARK: Header
                        VStack(spacing: 10) {
                            VStack(spacing: 2) {
                                Text("Current Conditions")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)

                                let headerText: String = {
                                    if source == .pws {
                                        return viewModel.pwsLabel.isEmpty
                                            ? "Personal Weather Station"
                                            : "\(viewModel.pwsLabel) • PWS"
                                    } else {
                                        return selection.selectedFavorite?.displayName
                                            ?? viewModel.currentLocationLabel
                                    }
                                }()

                                let showCurrentLocationGlyph =
                                    source == .noaa && selection.selectedFavorite == nil

                                if !headerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(spacing: 6) {
                                        Text(headerText)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)

                                        if showCurrentLocationGlyph {
                                            Image(systemName: "location.circle")
                                                .imageScale(.small)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    Text("Current Location")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }

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
                                    let isNightNow = isNightHourNow()
                                    let sym = conditionsSymbolAndColor(for: viewModel.conditions, isNight: isNightNow)
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

                        // MARK: Forecast card
                        NavigationLink {
                            ForecastView(initialSelection: selection.selectedFavorite)
                        } label: {
                            ZStack {
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
                // ✅ refreshable MUST be on ScrollView
                .refreshable {
                    isManualRefreshing = true
                    defer { isManualRefreshing = false }
                    await refreshNow()
                    successHaptic()
                }
                .task {
                    viewModel.loadCached()
                    location.request()
                    await refreshNow()
                }
                .onReceive(location.$coordinate) { coord in
                    guard coord != nil else { return }
                    guard selection.selectedFavorite == nil else { return } // don’t override favorite selection
                    Task { await refreshNow() }
                }
                .onReceive(location.$locationName) { name in
                    guard selection.selectedFavorite == nil else { return }
                    guard let name, !name.isEmpty else { return }
                    viewModel.currentLocationLabel = name
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await refreshNow() }
                }
                .onChange(of: sourceRaw) { _, newValue in
                    // If user switches to PWS, favorites are no longer applicable
                    if newValue == CurrentConditionsSource.pws.rawValue {
                        selection.selectedFavorite = nil
                        previousSourceRaw = nil
                        viewModel.pwsLabel = ""
                    }
                    Task { await refreshNow() }
                }
            }
            .navigationTitle("Nimbus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {

                    Button { showingLocations = true } label: {
                        Image(systemName: "star.circle")
                    }
                    .accessibilityLabel("Choose location")

                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingLocations) {
                locationsSheet
            }
        }
    }

    // MARK: - Locations sheet
    private var locationsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        // Switch back to "Current Location"
                        selection.selectedFavorite = nil

                        // Restore previous source if we had forced NOAA for a favorite
                        if let prev = previousSourceRaw {
                            sourceRaw = prev
                            previousSourceRaw = nil
                        }

                        // If not in PWS, clear any stale PWS label
                        if source != .pws {
                            viewModel.pwsLabel = ""
                        }

                        Task { await refreshNow() }
                        showingLocations = false
                    } label: {
                        HStack {
                            Text("Current Location")
                            Spacer()
                            if selection.selectedFavorite == nil { Image(systemName: "checkmark") }
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
                                // Selecting a favorite implies NOAA current conditions
                                if previousSourceRaw == nil {
                                    previousSourceRaw = sourceRaw
                                }

                                sourceRaw = CurrentConditionsSource.noaa.rawValue
                                viewModel.pwsLabel = ""

                                selection.selectedFavorite = f

                                Task { await refreshNow() }
                                showingLocations = false
                            } label: {
                                HStack {
                                    Text(f.displayName)
                                    Spacer()
                                    if selection.selectedFavorite?.id == f.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                favorites.remove(favorites.favorites[i])
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

    // MARK: - Refresh routing
    private func refreshNow() async {
        if let f = selection.selectedFavorite {
            // Favorites always imply NOAA
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
    }

    private func isNightHourNow() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 || hour >= 18
    }

    // MARK: - UI components
    private func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.tertiarySystemBackground))
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

    private func tile(
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

    private func wideTile(
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
                .font(.title3)
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

#Preview {
    ContentView()
        .environmentObject(FavoritesStore())
        .environmentObject(LocationSelectionStore())
}
