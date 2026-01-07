import SwiftUI
import Combine
import CoreLocation

struct ContentView: View {
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var viewModel = WeatherViewModel()
    @StateObject private var location = LocationManager()

    @StateObject private var searchVM = CitySearchViewModel()
    
    // Forecast VM for inline daily forecast list
    @StateObject private var forecastVM = ForecastViewModel()

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore
    
    @State private var selectedDetail: DetailPayload?

    private struct DetailPayload: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dyn

    // Manual refresh UI state
    @State private var isManualRefreshing = false

    // Sheets
    @State private var showingSettings = false
    @State private var showingLocations = false

    // When picking a favorite we force NOAA, but we remember what user had selected
    @State private var previousSourceRaw: String? = nil

    @AppStorage("currentConditionsSource")
    private var sourceRaw: String = CurrentConditionsSource.noaa.rawValue

    private var source: CurrentConditionsSource {
        get { CurrentConditionsSource(rawValue: sourceRaw) ?? .noaa }
        set { sourceRaw = newValue.rawValue }
    }

    private var isA11y: Bool { dyn.isAccessibilitySize }

    // Heights adapt automatically (about ~20% shorter than your older tiles)
    private var miniMinHeight: CGFloat { isA11y ? 84 : 68 }
    private var bigMinHeight: CGFloat { isA11y ? 190 : 150 }

    // Font tuning
    private var miniValueFont: Font { isA11y ? .title3.weight(.semibold) : .headline }
    private var miniIconFont: Font { isA11y ? .title3 : .headline }

    private var tempFontSize: CGFloat { isA11y ? 54 : 48 }
    private var tempIconFont: Font { isA11y ? .title2 : .title3 }

    private var tileBackground: some ShapeStyle {
        Color(.secondarySystemBackground)
    }

    private var headerLocationText: String {
        if source == .pws { return "" } // don’t show stale NOAA location in PWS mode
        return selection.selectedFavorite?.displayName ?? viewModel.currentLocationLabel
    }

    private var showCurrentLocationGlyph: Bool {
        (source == .noaa) && (selection.selectedFavorite == nil)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 18) {

                headerSection

                tilesSection

                // MARK: Inline daily forecast (NOAA only) — scrolls under tiles
                if source == .noaa {

                    // Optional: keep the title “anchored” (so it doesn’t scroll away)
                    // If your inlineForecastSection already includes a "Daily Forecast" title,
                    // you can remove this Text block.
                   Text("Daily Forecast")
                       .font(.title3.weight(.semibold))
                       .foregroundStyle(.primary)
                       .frame(maxWidth: .infinity, alignment: .center)

                    ScrollView(showsIndicators: true) {
                        inlineForecastSection
                            .padding(.bottom, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity) // ✅ takes remaining space so it can scroll
                    .refreshable {
                        isManualRefreshing = true
                        defer { isManualRefreshing = false }

                        await refreshNow()
                        await refreshForecastNow()

                        successHaptic()
                    }

                } else {
                    // In PWS mode there’s no forecast — push content up nicely
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }

        // ============================
        // 🔽 CODE SNIPPET 1 STARTS HERE
        // ============================

        .task {
            location.request()

            viewModel.setLoadingPlaceholders()
            if source == .noaa {
                forecastVM.setLoadingPlaceholders()
            }
            await Task.yield()

            await refreshNow()
            await refreshForecastNow()
        }
        .onReceive(location.$coordinate) { coord in
            guard coord != nil else { return }
            guard selection.selectedFavorite == nil else { return } // don’t override favorite pin

            Task {
                viewModel.setLoadingPlaceholders()
                if source == .noaa {
                    forecastVM.setLoadingPlaceholders()
                }
                await Task.yield()

                await refreshNow()
                await refreshForecastNow()
            }
        }
        .onReceive(location.$locationName) { name in
            guard selection.selectedFavorite == nil else { return }
            guard let name, !name.isEmpty else { return }
            viewModel.currentLocationLabel = name
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }

            Task {
                viewModel.setLoadingPlaceholders()
                if source == .noaa {
                    forecastVM.setLoadingPlaceholders()
                }
                await Task.yield()

                await refreshNow()
                await refreshForecastNow()
            }
        }
        .onChange(of: selection.selectedFavorite?.id) { _, _ in
            // favorite/current location changed — refresh immediately
            Task {
                viewModel.setLoadingPlaceholders()
                if source == .noaa {
                    forecastVM.setLoadingPlaceholders()
                }
                await Task.yield()

                await refreshNow()
                await refreshForecastNow()
            }
        }
        .onChange(of: sourceRaw) { _, newValue in
            if newValue == CurrentConditionsSource.pws.rawValue {
                // switching to PWS makes favorites irrelevant
                selection.selectedFavorite = nil
                previousSourceRaw = nil
                viewModel.pwsLabel = ""
            }

            Task {
                viewModel.setLoadingPlaceholders()
                if source == .noaa {
                    forecastVM.setLoadingPlaceholders()
                }
                await Task.yield()

                await refreshNow()
                await refreshForecastNow()
            }
        }

        // 🔹 Navigation + toolbar MUST be attached here
        .navigationTitle("Nimbus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingLocations = true } label: { Image(systemName: "star.circle") }
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingLocations) {
            locationsSheet
        }
        .sheet(item: $selectedDetail) { detail in
            NavigationStack {
                ScrollView {
                    Text(detail.body)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineSpacing(6)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle(detail.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selectedDetail = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }

        // ============================
        // 🔼 CODE SNIPPET 1 ENDS HERE
        // ============================
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text("Current Conditions")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                if !headerLocationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 6) {
                        Text(headerLocationText)
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

                if source == .pws, !viewModel.pwsLabel.isEmpty {
                    Text("\(viewModel.pwsLabel) • PWS")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
    }

    private var tilesSection: some View {
        HStack(spacing: 14) {

            // Left column: wind + humidity
            VStack(spacing: 14) {
                miniTile("wind", .teal, viewModel.windDisplay)
                miniTile("drop", .blue, viewModel.humidity)
            }
            .frame(maxWidth: .infinity)

            // Center big tile: temperature
            bigTempTile

            // Right column: conditions + pressure
            VStack(spacing: 14) {
                if source == .noaa {
                    let hour = Calendar.current.component(.hour, from: Date())
                    let isNight = hour < 6 || hour >= 18
                    let sym = conditionsSymbolAndColor(for: viewModel.conditions, isNight: isNight)
                    miniTile(sym.symbol, sym.color, viewModel.conditions)
                } else {
                    miniTile("cloud.rain", .blue, viewModel.precipitation)
                }
                miniTile("gauge", .orange, viewModel.pressure)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var inlineForecastSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header row (centered title + spinner on right)
            ZStack {
//                Text("Daily Forecast")
//                    .font(.title3.weight(.semibold))
 //                   .foregroundStyle(.primary)
//                    .frame(maxWidth: .infinity)
//                    .multilineTextAlignment(.center)

                HStack {
                    Spacer()
                    if forecastVM.isLoading && forecastVM.periods.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let msg = forecastVM.errorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Alerts & Advisories
            if let top = forecastVM.alerts.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alerts & Advisories")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    InlineAlertRow(alert: top)

                    if forecastVM.alerts.count > 1 {
                        Text("\(forecastVM.alerts.count - 1) more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            // Forecast rows (restored)
            if !forecastVM.periods.isEmpty {
                let days = Array(combineDayNight(Array(forecastVM.periods.prefix(14))).prefix(7))

                let sideCol: CGFloat = 120   // tweak 110–140 to taste

                ForEach(days) { d in
                    let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)

                    HStack(spacing: 10) {

                        // Left column (fixed)
                        HStack(spacing: 6) {
                            Text(abbreviatedDayName(d.name))
                                .font(.headline)
                            Text(d.dateText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: sideCol, alignment: .leading)

                        // Middle column (true center)
                        VStack(spacing: 2) {
                            Image(systemName: sym.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(sym.color)
                                .font(.title2)

                            if let pop = popText(d.day) {
                                Text(pop)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            } else {
                                Text(" ")
                                    .font(.caption2)
                                    .hidden()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        // Right column (fixed)
                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(width: sideCol, alignment: .trailing)
                    }
                    // ✅ SNIPPET 2: make the whole row tappable and set selectedDetail
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let dayText = d.day.detailedForecast ?? d.day.shortForecast
                        let nightText = d.night?.detailedForecast

                        let body: String
                        if let nightText,
                           !nightText.isEmpty,
                           nightText != dayText {
                            body = "Day: \(dayText)\n\nNight: \(nightText)"
                        } else {
                            body = dayText
                        }

                        selectedDetail = DetailPayload(
                            title: "\(abbreviatedDayName(d.name)) \(d.dateText)",
                            body: body
                        )
                    }
                    .padding(.vertical, 4)

                    if d.id != days.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            } else if !forecastVM.isLoading {
                Text("No forecast yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var bigTempTile: some View {
        VStack(spacing: 10) {
            Image(systemName: "thermometer")
                .foregroundStyle(Color.red)
                .font(tempIconFont)

            Text(viewModel.temp)
                .font(.system(size: tempFontSize, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: bigMinHeight)
        .padding(.vertical, 8)
        .background(tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func miniTile(_ systemImage: String, _ color: Color, _ value: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(miniIconFont)

            Text(value)
                .font(miniValueFont)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: miniMinHeight)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Locations sheet

    private var locationsSheet: some View {
        NavigationStack {
            List {

                // MARK: - Search
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search city, state", text: $searchVM.query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await searchVM.search() } }

                        if searchVM.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if !searchVM.query.isEmpty {
                            Button {
                                searchVM.query = ""
                                searchVM.results = []
                                dismissKeyboard()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: - Search Results
                if !searchVM.results.isEmpty {
                    Section("Results") {
                        ForEach(searchVM.results.prefix(8)) { r in
                            Button {
                                // Selecting a searched city implies NOAA
                                if previousSourceRaw == nil {
                                    previousSourceRaw = sourceRaw
                                }
                                sourceRaw = CurrentConditionsSource.noaa.rawValue
                                viewModel.pwsLabel = ""

                                let f = FavoriteLocation(
                                    title: r.title,
                                    subtitle: r.subtitle,
                                    latitude: r.coordinate.latitude,
                                    longitude: r.coordinate.longitude
                                )

                                favorites.add(f)
                                selection.selectedFavorite = f

                                searchVM.query = ""
                                searchVM.results = []
                                dismissKeyboard()

                                Task {
                                    await refreshNow()
                                    await refreshForecastNow()
                                }
                                
                                showingLocations = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.title)
                                            .font(.headline)

                                        if !r.subtitle.isEmpty {
                                            Text(r.subtitle)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                }

                // MARK: - Current Location
                Section {
                    Button {
                        selection.selectedFavorite = nil

                        if let prev = previousSourceRaw {
                            sourceRaw = prev
                            previousSourceRaw = nil
                        }

                        if source != .pws {
                            viewModel.pwsLabel = ""
                        }

                        searchVM.query = ""
                        searchVM.results = []
                        dismissKeyboard()

                        Task {
                            await refreshNow()
                            await refreshForecastNow()
                        }
                        showingLocations = false
                    } label: {
                        HStack {
                            Text("Current Location")
                            Spacer()
                            if selection.selectedFavorite == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                // MARK: - Favorites
                Section("Favorites") {
                    if favorites.favorites.isEmpty {
                        Text("No favorites yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favorites.favorites) { f in
                            Button {
                                if previousSourceRaw == nil {
                                    previousSourceRaw = sourceRaw
                                }

                                sourceRaw = CurrentConditionsSource.noaa.rawValue
                                viewModel.pwsLabel = ""

                                selection.selectedFavorite = f

                                searchVM.query = ""
                                searchVM.results = []
                                dismissKeyboard()

                                Task {
                                    await refreshNow()
                                    await refreshForecastNow()
                                }
                                showingLocations = false
                            } label: {
                                HStack {
                                    Text(f.displayName)
                                    Spacer()
                                    if selection.selectedFavorite?.id == f.id {
                                        Image(systemName: "checkmark")
                                    }
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
                    Button("Done") {
                        searchVM.query = ""
                        searchVM.results = []
                        dismissKeyboard()
                        showingLocations = false
                    }
                }
            }
        }
    }

    // MARK: - Async refresh

    private func refreshNow(showPlaceholders: Bool = false) async {
        if showPlaceholders {
            viewModel.setLoadingPlaceholders()
            if source == .noaa {
                forecastVM.setLoadingPlaceholders()
            }
            // Give SwiftUI a chance to paint the placeholders
            await Task.yield()
        }

        if let f = selection.selectedFavorite {
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

    private func refreshForecastNow() async {
        guard source == .noaa else { return } // forecasts are NOAA only

        if let f = selection.selectedFavorite {
            await forecastVM.refresh(for: f.coordinate)
            return
        }

        guard let coord = location.coordinate else { return }

        // ✅ when returning to GPS, force refresh (not loadIfNeeded)
        await forecastVM.refresh(for: coord)
    }

    // MARK: - UI helpers

    private func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.tertiarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        scheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.04),
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
}


private struct InlineAlertRow: View {
    let alert: NWSAlertsResponse.Feature

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolForSeverity(alert.properties.severity))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.properties.event)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let headline = alert.properties.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let area = alert.properties.areaDesc, !area.isEmpty {
                    Text(area)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func symbolForSeverity(_ severity: String?) -> String {
        switch severity?.lowercased() {
        case "extreme", "severe": return "exclamationmark.octagon.fill"
        case "moderate": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }
}

private struct LocationsSheet: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore

    @Binding var showingLocations: Bool
    @Binding var sourceRaw: String
    @Binding var previousSourceRaw: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selection.selectedFavorite = nil

                        if let prev = previousSourceRaw {
                            sourceRaw = prev
                            previousSourceRaw = nil
                        }

                        showingLocations = false
                    } label: {
                        HStack {
                            Text("Current Location")
                            Spacer()
                            if selection.selectedFavorite == nil {
                                Image(systemName: "checkmark")
                            }
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
                                if previousSourceRaw == nil {
                                    previousSourceRaw = sourceRaw
                                }

                                sourceRaw = CurrentConditionsSource.noaa.rawValue
                                selection.selectedFavorite = f
                                showingLocations = false
                            } label: {
                                HStack {
                                    Text(f.displayName)
                                    Spacer()
                                    if selection.selectedFavorite?.id == f.id {
                                        Image(systemName: "checkmark")
                                    }
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

private func successHaptic() {
    let gen = UINotificationFeedbackGenerator()
    gen.prepare()
    gen.notificationOccurred(.success)
}

#Preview {
    NavigationStack { ContentView() }
        .environmentObject(FavoritesStore())
        .environmentObject(LocationSelectionStore())
}
