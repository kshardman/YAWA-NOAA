import SwiftUI
import Combine
import CoreLocation

struct RadarViewPlaceholder: View {
    let latitude: Double
    let longitude: Double
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Radar coming soon")
                    .font(.title2)
                    .foregroundStyle(YAWATheme.textPrimary)

                Text("\(title)\n\(latitude), \(longitude)")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(YAWATheme.textSecondary)
                    .monospacedDigit()

                Spacer()
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 48))
                    .foregroundStyle(YAWATheme.textTertiary)
                    .padding(.bottom, 8)            }
            .padding()
            .background(YAWATheme.sky.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RadarTarget: Identifiable, Equatable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
    let title: String

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}


struct ContentView: View {
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var viewModel = WeatherViewModel()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var searchVM = CitySearchViewModel()
    @StateObject private var forecastVM = ForecastViewModel()
    @StateObject private var weatherApiForecastViewModel = WeatherAPIForecastViewModel()
    
    
    @State private var lastCurrentRefreshAt: Date? = nil
    @State private var lastForecastRefreshAt: Date? = nil
    @State private var lastRefreshCoord: CLLocationCoordinate2D? = nil
    
    @State private var pendingForegroundRefresh = false

    private let refreshMaxAge: TimeInterval = 15 * 60   // 15 minutes
    private let refreshDistanceMeters: CLLocationDistance = 1500 // ~1.5 km
    

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore
    
    @State private var selectedDetail: DetailPayload?
    @State private var showingAllAlerts = false
    
 //   @State private var showingRadar = false
    @State private var radarTarget: RadarTarget?
    
    
    
    private var effectiveWeatherApiCoordinate: CLLocationCoordinate2D? {
        // In PWS mode, anchor WeatherAPI forecast to the station coordinate (published by WeatherViewModel)
        if source == .pws {
            return viewModel.pwsStationCoordinate
        }
        // Otherwise follow the active (GPS/favorite) coordinate
        return locationManager.coordinate
    }

    private var weatherApiCoordKey: String {
        guard let c = effectiveWeatherApiCoordinate else { return "" }
        let lat = (c.latitude * 100).rounded() / 100
        let lon = (c.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }
    
    
    // nil = “use GPS”; non-nil = user selected a city/favorite
    @State private var selectedCity: CitySearchViewModel.Result?
    
    private var activeRadarTarget: RadarTarget? {
        // 1) If user selected a city/favorite, prefer it
        if let sel = selectedCity {
            let title = sel.subtitle.isEmpty ? sel.title : "\(sel.title), \(sel.subtitle)"
            return RadarTarget(
                latitude: sel.coordinate.latitude,
                longitude: sel.coordinate.longitude,
                title: title
            )
        }

        // 2) Otherwise fall back to GPS
        if let coord = locationManager.coordinate {
            return RadarTarget(
                latitude: coord.latitude,
                longitude: coord.longitude,
                title: locationManager.locationName ?? "Current Location"
            )
        }

        // 3) No location available yet
        return nil
    }
    
    let sideCol: CGFloat = 120 // tweak 110–140 to taste

    private enum DetailBody {
        case text(String)
        case forecast(day: String, night: String?)
        case alert(description: String?, instructions: [String], severity: String?)
    }

    private struct DetailPayload: Identifiable {
        let id = UUID()
        let title: String
        let body: DetailBody

        init(title: String, body: String) {
            self.title = title
            self.body = .text(body)
        }

        init(title: String, day: String, night: String?) {
            self.title = title
            self.body = .forecast(day: day, night: night)
        }

        init(title: String, description: String?, instructions: [String], severity: String?) {
            self.title = title
            self.body = .alert(description: description, instructions: instructions, severity: severity)
        }
    }
    
    struct LegacyAlertSection: Identifiable {
        let id = UUID()
        let title: String
        let paragraphs: [String]
    }
    func parseAlertSections(from text: String) -> [LegacyAlertSection] {
        let cleaned = text
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = [
            ("WHAT", "WHAT"),
            ("WHEN", "WHEN"),
            ("IMPACTS", "IMPACTS")
        ]

        var sections: [LegacyAlertSection] = []

        for (key, title) in patterns {
            if let range = cleaned.range(of: "\(key)...") {
                let start = range.upperBound
 //               let remainder = cleaned[start...]

                let end = patterns
                    .compactMap { cleaned.range(of: "\($0.0)...", range: start..<cleaned.endIndex)?.lowerBound }
                    .min() ?? cleaned.endIndex

                let body = cleaned[start..<end]
                    .replacingOccurrences(of: "\n\n", with: "\n")
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                if !body.isEmpty {
                    sections.append(
                        LegacyAlertSection(title: title.capitalized, paragraphs: body)
                    )
                }
            }
        }

        return sections
    }
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dyn

    // Manual refresh UI state
    @State private var isManualRefreshing = false
    
    @State private var showEasterEgg = false

    private func triggerEasterEgg() {
        showEasterEgg = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            showEasterEgg = false
        }
    }
    // MARK: - Refresh gating (Option A)
 
    private let refreshMinInterval: TimeInterval = 12 * 60   // 12 minutes

    private func shouldRefreshNow(last: Date?) -> Bool {
        guard let last else { return true }
        return Date().timeIntervalSince(last) > refreshMinInterval
    }


    private func recordRefresh(coord: CLLocationCoordinate2D?) {
        lastCurrentRefreshAt = Date()
        lastRefreshCoord = coord
        if source == .noaa { lastForecastRefreshAt = Date() }
    }
    

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
        YAWATheme.card
    }

    private var headerLocationText: String {
        if source == .pws { return "" } // don’t show stale NOAA location in PWS mode
        return selection.selectedFavorite?.displayName ?? (locationManager.locationName ?? "Current Location")
    }

    private var showCurrentLocationGlyph: Bool {
        (source == .noaa) && (selection.selectedFavorite == nil)
    }

    private func isStale(_ date: Date?, maxAge: TimeInterval) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > maxAge
    }

    private func movedEnough(from old: CLLocationCoordinate2D?, to new: CLLocationCoordinate2D?) -> Bool {
        guard let old, let new else { return false }
        let a = CLLocation(latitude: old.latitude, longitude: old.longitude)
        let b = CLLocation(latitude: new.latitude, longitude: new.longitude)
        return a.distance(from: b) >= refreshDistanceMeters
    }
    
    private func maybeRefreshOnActive() async {
        // Favorites: always refresh immediately on active (they're pinned, not GPS dependent)
        if let _ = selection.selectedFavorite {
            viewModel.setLoadingPlaceholders()
            forecastVM.setLoadingPlaceholders()
            await Task.yield()
            await refreshNow()
            await refreshForecastNow()
            lastCurrentRefreshAt = Date()
            lastForecastRefreshAt = Date()
            return
        }

        // Current location mode: ask for a fresh location fix first
        locationManager.request()

        let shouldByAge = isStale(lastCurrentRefreshAt, maxAge: refreshMaxAge)
        let shouldByMove = movedEnough(from: lastRefreshCoord, to: locationManager.coordinate)

        guard shouldByAge || shouldByMove else { return }

        viewModel.setLoadingPlaceholders()
        if source == .noaa { forecastVM.setLoadingPlaceholders() }
        await Task.yield()

        await refreshNow()
        if source == .noaa { await refreshForecastNow() }

        lastCurrentRefreshAt = Date()
        lastForecastRefreshAt = Date()
        lastRefreshCoord = locationManager.coordinate
    }
    
    
    var body: some View {
        rootView
    }

    // MARK: - Root view (extracted to help the compiler)

    private var rootView: some View {
        ZStack {
            YAWATheme.sky.ignoresSafeArea()
            mainStack
        }
        .task { await onFirstAppearTask() }
        .onReceive(locationManager.$coordinate) { coord in
            onCoordinateChange(coord)
        }
        .onChange(of: scenePhase) { _, phase in
            onScenePhaseChange(phase)
        }
        .onChange(of: selection.selectedFavorite?.id) { _, _ in
            Task { await onFavoriteChanged() }
        }
        .onChange(of: sourceRaw) { _, newValue in
            Task { await onSourceChanged(newValue) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { topBarToolbar }
        .tint(YAWATheme.textSecondary)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingLocations) {
            LocationsSheet(
                showingLocations: $showingLocations,
                sourceRaw: $sourceRaw,
                previousSourceRaw: $previousSourceRaw
            )
        }
        .sheet(item: $radarTarget) { target in
            RadarView(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedDetail) { detail in
            alertDetailSheet(detail)
        }
        .sheet(isPresented: $showingAllAlerts) {
            allAlertsSheet
        }
    }

    private var mainStack: some View {
        VStack(spacing: 18) {
            headerSection
                .padding(.top, 8)

            tilesSection

            forecastSection

            if showEasterEgg {
                easterEggOverlay
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

//    private var forecastSection: some View {
//        Group {
////            Text("Daily Forecast")
////                .font(.title3.weight(.semibold))
////                .foregroundStyle(YAWATheme.textPrimary)
////                .frame(maxWidth: .infinity, alignment: .center)
//
//            if source == .noaa {
//                inlineForecastSection
//                    .padding(.bottom, 12)
//                    .frame(maxWidth: .infinity)
//            } else {
//                weatherApiForecastCard
//                    .padding(.bottom, 12)
//                    .frame(maxWidth: .infinity)
//            }
//        }
//        .padding(.top, 6)
//    }
    
    private var forecastSection: some View {
        Group {
            if source == .noaa {
                ScrollView(showsIndicators: false) {
                    inlineForecastSection
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                }
                // ✅ This is the only scrolling region; it takes the remaining height.
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .refreshable {
                    isManualRefreshing = true
                    defer { isManualRefreshing = false }

                    // In GPS mode, proactively ask for a fresh fix before refreshing.
                    if selection.selectedFavorite == nil && source != .pws {
                        locationManager.request()
                    }

                    await refreshNow()
                    await refreshForecastNow()

                    successHaptic()
                }

            } else {
                // PWS / WeatherAPI forecast: keep it in a scroll container too
                // so the overall screen doesn’t need to scroll.
                ScrollView(showsIndicators: false) {
                    weatherApiForecastCard
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .refreshable {
                    isManualRefreshing = true
                    defer { isManualRefreshing = false }

                    await refreshNow()
                    // (WeatherAPI card loads via .task(id: weatherApiCoordKey))
                    successHaptic()
                }
            }
        }
        .padding(.top, 6)
    }
    
    

    private var easterEggOverlay: some View {
        VStack {
            Spacer().frame(height: 10)

            Text("Yawa ✨ Yet Another Weather App")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: showEasterEgg)
        .zIndex(10)
    }

    private var topBarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ToolbarIconButton("star.circle.fill", tint: .white) { showingLocations = true }
            ToolbarIconButton("gearshape.fill", tint: .white) { showingSettings = true }
        }
    }

    // MARK: - Extracted side-effect handlers (compiler-friendly)

    @MainActor
    private func onFirstAppearTask() async {
        await NotificationService.shared.requestAuthorizationIfNeeded()
        locationManager.request()

        viewModel.setLoadingPlaceholders()
        if source == .noaa { forecastVM.setLoadingPlaceholders() }
        await Task.yield()

        await refreshNow()
        if source == .noaa { await refreshForecastNow() }

        recordRefresh(coord: locationManager.coordinate)
    }

    private func onCoordinateChange(_ coord: CLLocationCoordinate2D?) {
        guard let coord else { return }
        guard selection.selectedFavorite == nil else { return }
        guard source != .pws else { return }

        let needs = pendingForegroundRefresh
        || shouldRefreshNow(last: lastCurrentRefreshAt)
        || movedEnough(from: lastRefreshCoord, to: coord)

        guard needs else { return }

        Task {
            pendingForegroundRefresh = false

            viewModel.setLoadingPlaceholders()
            if source == .noaa { forecastVM.setLoadingPlaceholders() }
            await Task.yield()

            await refreshNow()
            if source == .noaa { await refreshForecastNow() }

            recordRefresh(coord: coord)
        }
    }

    private func onScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        guard selection.selectedFavorite == nil else { return }

        pendingForegroundRefresh = true
        locationManager.refresh()
    }

    @MainActor
    private func onFavoriteChanged() async {
        viewModel.setLoadingPlaceholders()
        forecastVM.setLoadingPlaceholders()
        await Task.yield()

        await refreshNow()
        await refreshForecastNow()
    }

    @MainActor
    private func onSourceChanged(_ newValue: String) async {
        if newValue == CurrentConditionsSource.pws.rawValue {
            selection.selectedFavorite = nil
            previousSourceRaw = nil
            viewModel.pwsLabel = ""
        }

        viewModel.setLoadingPlaceholders()
        if source == .noaa { forecastVM.setLoadingPlaceholders() }
        await Task.yield()

        await refreshNow()
        await refreshForecastNow()
    }

    // MARK: - Extracted sheets

    private func splitDayNight(_ text: String) -> (day: String, night: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Look for the exact marker produced by our NOAA/WeatherAPI detail formatting.
        if let r = t.range(of: "\n\nNight...\n") {
            let dayPart = String(t[..<r.lowerBound])
                .replacingOccurrences(of: "Day...\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let nightPart = String(t[r.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (day: dayPart.isEmpty ? t : dayPart, night: nightPart.isEmpty ? nil : nightPart)
        }

        // Day-only; strip the Day label if present.
        let dayOnly = t.replacingOccurrences(of: "Day...\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (day: dayOnly.isEmpty ? t : dayOnly, night: nil)
    }

    private func forecastDetailCard(title: String, day: String, night: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header row (matches Daily Forecast card vibe)
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.textSecondary)

                Text("Daily Forecast")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YAWATheme.textPrimary)

                Spacer()

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(YAWATheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Divider().opacity(0.35)

            // Day sub-card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.textSecondary)

                    Text("Day")
                        .font(.headline)
                        .foregroundStyle(YAWATheme.textPrimary)
                }

                Text(day)
                    .font(.callout)
                    .foregroundStyle(YAWATheme.textPrimary)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(YAWATheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Night sub-card (optional)
            if let night, !night.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.stars.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.textSecondary)

                        Text("Night")
                            .font(.headline)
                            .foregroundStyle(YAWATheme.textPrimary)
                    }

                    Text(night)
                        .font(.callout)
                        .foregroundStyle(YAWATheme.textPrimary)
                        .lineSpacing(6)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(YAWATheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(14)
        .background(YAWATheme.card2)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func alertSymbol(for severity: String?) -> String {
        switch severity?.lowercased() {
        case "extreme", "severe": return "exclamationmark.octagon.fill"
        case "moderate": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private func alertColor(for severity: String?) -> Color {
        switch severity?.lowercased() {
        case "extreme", "severe":
            return Color.red.opacity(0.95)
        case "moderate":
            return Color.orange.opacity(0.9)
        default:
            return Color.secondary.opacity(0.8)
        }
    }

    private func alertDetailSheet(_ detail: DetailPayload) -> some View {
        ZStack {
            // Match the slightly lighter sheet background used elsewhere
            YAWATheme.card2
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch detail.body {
                    case .text(let text):
                        VStack(alignment: .leading, spacing: 12) {
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(YAWATheme.textPrimary)
                                .lineSpacing(6)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                    case .forecast(let day, let night):
                        forecastDetailCard(title: detail.title, day: day, night: night)

                    case .alert(let description, let instructions, let severity):
                        let sym = alertSymbol(for: severity)
                        let sevColor = alertColor(for: severity)

                        VStack(alignment: .leading, spacing: 12) {

                            // Header row (matches Daily Forecast card vibe)
                            HStack(spacing: 10) {
                                Image(systemName: sym)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, sevColor)
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 26, height: 26, alignment: .center)

                                Text(detail.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(YAWATheme.textPrimary)
                                    .lineLimit(2)

                                Spacer(minLength: 0)
                            }

                            Divider().opacity(0.35)

                            if let description, !description.isEmpty {
                                let sections = parseAlertNarrativeSections(from: description)

                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(sections) { s in
                                        VStack(alignment: .leading, spacing: 4) {
                                            if let label = s.label {
                                                Text(label)
                                                    .font(.headline)
                                                    .foregroundStyle(YAWATheme.textPrimary)
                                            }

                                            Text(s.body)
                                                .font(.callout)
                                                .foregroundStyle(YAWATheme.textPrimary)
                                                .lineSpacing(6)
                                                .multilineTextAlignment(.leading)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }

                            if !instructions.isEmpty {
                                Text("What to do")
                                    .font(.headline)
                                    .foregroundStyle(YAWATheme.textPrimary)
                                    .padding(.top, (description?.isEmpty ?? true) ? 0 : 4)

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(instructions, id: \.self) { item in
                                        let cleaned = stripLeadingBullet(item)

                                        HStack(alignment: .top, spacing: 10) {
                                            Text("•")
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(YAWATheme.textPrimary)
                                                .padding(.top, 1)

                                            Text(cleaned)
                                                .font(.callout)
                                                .foregroundStyle(YAWATheme.textPrimary)
                                                .lineSpacing(4)
                                                .multilineTextAlignment(.leading)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }

                            if let severity, !severity.isEmpty {
                                Divider().padding(.top, 6)

                                Text("Severity: \(severity)")
                                    .font(.footnote)
                                    .foregroundStyle(YAWATheme.textSecondary)
                            }
                        }
                        .padding(14)
                        .background(YAWATheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(16)
                .background(YAWATheme.card2)
            }
        }
        .background(YAWATheme.sky)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var allAlertsSheet: some View {
        NavigationStack {
            List {
                ForEach(forecastVM.alerts) { a in
                    InlineAlertRow(alert: a)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingAllAlerts = false
                            openAlertDetail(a)
                        }
                        .listRowBackground(YAWATheme.card2)
                        .listRowSeparator(.hidden)
                }
            }
            .scrollContentBackground(.hidden)
            .background(YAWATheme.sky)
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingAllAlerts = false
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .background(YAWATheme.sky)
        .preferredColorScheme(.dark)
    }
    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Row 1: icon + title (left), location (right)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.textSecondary)

                    Text("Current Conditions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YAWATheme.textPrimary)
                }
                .layoutPriority(1) // keep title readable

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if source == .pws {
                        let label = viewModel.pwsLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(label.isEmpty ? "Personal Weather Station" : label)
                            .font(.subheadline)
                            .foregroundStyle(YAWATheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        let loc = headerLocationText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(loc.isEmpty ? "Current Location" : loc)
                            .font(.subheadline)
                            .foregroundStyle(YAWATheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if showCurrentLocationGlyph {
                            Image(systemName: "location.circle")
                                .imageScale(.small)
                                .foregroundStyle(YAWATheme.textSecondary.opacity(0.9))
                        }
                    }
                }
                .layoutPriority(0) // let this truncate first
            }

//            // Row 2: PWS label (optional)
//            if source == .pws, !viewModel.pwsLabel.isEmpty {
//                Text("\(viewModel.pwsLabel) • PWS")
//                    .font(.caption)
//                    .foregroundStyle(YAWATheme.textTertiary)
//            }

            // Row 3+: pills stack vertically (prevents crowding)
            VStack(alignment: .leading, spacing: 8) {

                if !networkMonitor.isOnline {
                    pill("Offline — showing last update", "wifi.slash")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let msg = viewModel.errorMessage {
                    pill(msg, "exclamationmark.triangle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.isStale {
                    Button {
                        Task {
                            isManualRefreshing = true
                            defer { isManualRefreshing = false }

                            await refreshNow()
                            if source == .noaa { await refreshForecastNow() }

                            successHaptic()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)

                            Text("STALE")
                                .foregroundStyle(.secondary)

                            Image(systemName: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(YAWATheme.textSecondary.opacity(0.8))
                                .padding(.leading, 8)   // breathing room
                        }
                        .fixedSize(horizontal: true, vertical: false) // ✅ prevents full-width expansion
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(0.95)
                }
            }
        }
        .padding(14)
        .background(YAWATheme.card2)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var tilesSection: some View {
        HStack(spacing: 14) {

            // Left column: wind + humidity
            VStack(spacing: 14) {
                miniTile("wind", .teal, viewModel.windDisplay)
                miniTile("humidity.fill", .blue, viewModel.humidity)
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

        private var weatherApiForecastCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.textSecondary)
                    
                    Text("Station Forecast (from WeatherAPI)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YAWATheme.textPrimary)
                    
                    Spacer()
                }
                
                if weatherApiForecastViewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let err = weatherApiForecastViewModel.errorMessage {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(YAWATheme.textSecondary)
                } else if weatherApiForecastViewModel.days.isEmpty {
                    Text("No forecast data.")
                        .font(.subheadline)
                        .foregroundStyle(YAWATheme.textSecondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(weatherApiForecastViewModel.days.enumerated()), id: \.element.id) { index, d in
                            let (sym, color) = conditionsSymbolAndColor(for: d.conditionText, isNight: false)
                            let popText = d.chanceRain.map { "\($0)%" }
                            
                            HStack(spacing: 10) {
                                // Left column (fixed)
                                HStack(spacing: 4) {
                                    Text(d.weekday)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(YAWATheme.textPrimary)
                                    
                                    Text(d.dateText)
                                        .font(.caption)
                                        .foregroundStyle(YAWATheme.textSecondary)
                                }
                                .frame(width: sideCol, alignment: .leading)
                                
                                // Middle column (true center)
                                VStack(spacing: 2) {
                                    Image(systemName: sym)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(color)
                                        .font(.title3)
                                    
                                    Group {
                                        if let popText {
                                            Text(popText)
                                        } else {
                                            Text("00%").hidden() // keeps identical layout/baseline
                                        }
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(YAWATheme.textSecondary)
                                }
                                .frame(height: 34, alignment: .center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                
                                // Right column (fixed)
                                Text("H \(d.hiF)°  L \(d.loF)°")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(YAWATheme.textPrimary)
                                    .frame(width: sideCol, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let parts = splitDayNight(d.detailText)
                                selectedDetail = DetailPayload(
                                    title: "\(d.weekday) \(d.dateText)",
                                    day: parts.day,
                                    night: parts.night
                                )
                            }
                            
                            if index < weatherApiForecastViewModel.days.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
                if source == .pws {
                    Divider()
                        .opacity(0.25)
                        .padding(.top, 6)
                    
                    Text("WeatherAPI rain chance may differ from NOAA PoP.")
                        .font(.caption)
                        .foregroundStyle(YAWATheme.textTertiary)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                }
            }
            .padding(14)
            .background(YAWATheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .task(id: weatherApiCoordKey) {
                guard let coord = effectiveWeatherApiCoordinate else { return }
                
//                print("🌧️ WeatherAPI forecast lookup → lat=\(coord.latitude), lon=\(coord.longitude), source=\(source)")
                
                await weatherApiForecastViewModel.loadIfNeeded(for: coord)
            }
        }

        
        private var inlineForecastSection: some View {
        VStack(alignment: .leading, spacing: 9) { // was 12

            // Header row (centered title + spinner on right)
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.textSecondary)

                Text("Daily Forecast")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YAWATheme.textPrimary)

                Spacer()

                if forecastVM.isLoading && forecastVM.periods.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }

            // Error (only show if not currently loading)
            if let msg = forecastVM.errorMessage, !msg.isEmpty, !forecastVM.isLoading {
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(YAWATheme.textSecondary)
            }

            if let first = forecastVM.alerts.first {
                VStack(alignment: .leading, spacing: 8) {
                    InlineAlertRow(alert: first)
                        .contentShape(Rectangle())
                        .onTapGesture { openAlertDetail(first) }

                    // If there are more, show a tappable "X more…" line that opens list
                    if forecastVM.alerts.count > 1 {
                        Button {
                            showingAllAlerts = true
                        } label: {
                            Text("\(forecastVM.alerts.count - 1) more…")
                                .font(.caption)
                                .foregroundStyle(YAWATheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(YAWATheme.card2)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            // Forecast rows
            if !forecastVM.periods.isEmpty {

//                let sideCol: CGFloat = 120 // tweak 110–140 to taste
                let forecastDays: [DailyForecast] =
                    Array(combineDayNight(Array(forecastVM.periods.prefix(14))).prefix(7))

                ForEach(forecastDays, id: \.id) { d in
 //                   let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)
                    let sym = forecastSymbolAndColor(
                        for: d.day.shortForecast,
                        detailedForecast: d.day.detailedForecast,
                        isDaytime: d.day.isDaytime
                    )

                    HStack(spacing: 10) {

                        // Left column (fixed)
                        HStack(spacing: 4) {
                            Text(weekdayLabel(d.startDate))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(YAWATheme.textPrimary)

                            Text(d.dateText)
                                .font(.caption) // tighter than .subheadline
                                .foregroundStyle(YAWATheme.textSecondary)
                        }
                        .frame(width: sideCol, alignment: .leading)

                        // Middle column (true center)
                        let pop = popText(d.day)

                        VStack(spacing: 2) {
                            Image(systemName: sym.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(sym.color)
                                .font(.title3)
                                .offset(y: iconYOffset(symbol: sym.symbol, hasPop: pop != nil))

                            Group {
                                if let pop {
                                    Text(pop)
                                } else {
                                    Text("00%").hidden()   // ✅ keeps identical layout/baseline
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(YAWATheme.textSecondary)
                        }
                        .frame(height: 34, alignment: .center)          // ✅ locks vertical centering
                        .frame(maxWidth: .infinity, alignment: .center) // keeps true center column
                        
                        // Right column (fixed)
                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(YAWATheme.textPrimary)
                            .frame(width: sideCol, alignment: .trailing)
                    }
 //                   .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let dayText = (d.day.detailedForecast ?? d.day.shortForecast)
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        let nightText = (d.night?.detailedForecast ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedNight = (nightText == dayText) ? "" : nightText

                        // parts/description code left for now (see instructions).

                        selectedDetail = DetailPayload(
                            title: "\(abbreviatedDayName(d.name)) \(d.dateText)",
                            day: dayText,
                            night: normalizedNight.isEmpty ? nil : normalizedNight
                        )
                    }

                    // If you want dividers between rows, add them here:
                    if d.id != forecastDays.last?.id {
                        Divider()
                            .opacity(0.5)
 //                           .overlay(YAWATheme.divider)   // <— use your theme divider opacity
                        }
                }

            }
        }
        .padding(14)
        .background(YAWATheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

//  MARK: OPENRADAR
    private func openRadar() {
        // compute the new target first
        let newTarget: RadarTarget?

        if let fav: FavoriteLocation = selection.selectedFavorite {
            newTarget = RadarTarget(latitude: fav.latitude, longitude: fav.longitude, title: fav.displayName)
        } else if let coord = locationManager.coordinate {
            newTarget = RadarTarget(latitude: coord.latitude, longitude: coord.longitude, title: locationManager.locationName ?? "Current Location")
        } else {
            newTarget = RadarTarget(latitude: 0, longitude: 0, title: "Location unavailable")
        }

        // If sheet is already open, reset then set so SwiftUI re-presents with new item
        if radarTarget != nil {
            radarTarget = nil
            DispatchQueue.main.async {
                radarTarget = newTarget
            }
        } else {
            radarTarget = newTarget
        }
    }
    
    private var bigTempTile: some View {
        ZStack {
            VStack {
                // Top: thermometer
                Image(systemName: "thermometer")
                    .foregroundStyle(.red)
                    .font(tempIconFont)
                    .padding(.top, 10)

                Spacer(minLength: 8)

                // Middle: temperature
                Text(viewModel.temp)
                    .font(.system(size: tempFontSize, weight: .semibold))
                    .foregroundStyle(YAWATheme.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Spacer(minLength: 12)

                // Bottom: radar button
                Button {
                    openRadar()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Radar")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YAWATheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: bigMinHeight * 1.15)
        .background(YAWATheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }


    private func miniTile(_ systemImage: String, _ color: Color, _ value: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .font(miniIconFont)

            Text(value)
                .font(miniValueFont)
                .foregroundStyle(YAWATheme.textPrimary)   // ✅ important for dark sky
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

    
    // MARK: - Async refresh

    private func refreshNow() async {
        if let f = selection.selectedFavorite {
 //           print("🛰️ NOAA refresh → favorite \(f.displayName) lat=\(f.coordinate.latitude), lon=\(f.coordinate.longitude)")
            // Favorites always imply NOAA
            await viewModel.fetchCurrentFromNOAA(
                lat: f.coordinate.latitude,
                lon: f.coordinate.longitude,
                locationName: f.displayName
            )
        } else {
            await viewModel.refreshCurrentConditions(
                source: source,
                coord: locationManager.coordinate,
                locationName: nil
            )
        }
    }

    private func refreshForecastNow() async {
        guard source == .noaa else { return } // forecasts are NOAA only

        if let f = selection.selectedFavorite {
            await forecastVM.refresh(for: f.coordinate)
            return
        }

        guard let coord = locationManager.coordinate else { return }

        // ✅ when returning to GPS, force refresh (not loadIfNeeded)
        await forecastVM.refresh(for: coord)
    }

    // MARK: - UI helpers
    
    private func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE") // Mon, Tue, etc.
        return f.string(from: date)
    }
    
    
    private struct LabeledBlock: Identifiable, Hashable {
        let id = UUID()
        let title: String      // e.g. "What", "When", "Impacts"
        let text: String
    }

    private func parseLabeledBlocks(from description: String) -> [LabeledBlock] {
        // Normalize line endings + collapse weird wraps
        let cleaned = description
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")     // NOAA wraps aggressively
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // We’ll look for these “LABEL...text” segments
        let labels: [(key: String, title: String)] = [
            ("WHAT...", "What"),
            ("WHEN...", "When"),
            ("WHERE...", "Where"),
            ("IMPACTS...", "Impacts"),
            ("ADDITIONAL DETAILS...", "Additional details")
        ]

        // Find all label positions
        var hits: [(start: Int, key: String, title: String)] = []
        for (key, title) in labels {
            var searchStart = cleaned.startIndex
            while let range = cleaned.range(of: key, range: searchStart..<cleaned.endIndex) {
                let idx = cleaned.distance(from: cleaned.startIndex, to: range.lowerBound)
                hits.append((idx, key, title))
                searchStart = range.upperBound
            }
        }

        hits.sort { $0.start < $1.start }
        guard !hits.isEmpty else {
            return cleaned.isEmpty ? [] : [LabeledBlock(title: "Details", text: cleaned)]
        }

        func slice(_ from: Int, _ to: Int) -> String {
            let s = cleaned.index(cleaned.startIndex, offsetBy: from)
            let e = cleaned.index(cleaned.startIndex, offsetBy: to)
            return String(cleaned[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var blocks: [LabeledBlock] = []

        for i in 0..<hits.count {
            let cur = hits[i]
            let nextStart = (i + 1 < hits.count) ? hits[i + 1].start : cleaned.count

            // Skip the label itself
            let labelEnd = cur.start + cur.key.count
            if labelEnd >= nextStart { continue }

            var body = slice(labelEnd, nextStart)
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))

            if !body.isEmpty {
                blocks.append(LabeledBlock(title: cur.title, text: body))
            }
        }

        return blocks
    }
    func parseInstructionItems(from text: String) -> [String] {
        // Normalize line endings and collapse weird spacing
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 1) Split into rough paragraphs first (blank lines)
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var items: [String] = []

        for para in paragraphs {
            // 2) Within each paragraph, NOAA sometimes uses inline bullets like " ... . • Next thing ..."
            // Split on "•" anywhere, not just at line starts.
            let parts = para
                .components(separatedBy: "•")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for part in parts {
                // 3) Also split on leading "-" list style if present (rare)
                // but DON'T break normal hyphens inside sentences.
                if part.hasPrefix("-") {
                    let cleaned = part.drop(while: { $0 == "-" || $0 == " " })
                    let s = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { items.append(s) }
                } else {
                    items.append(part)
                }
            }
        }

        // 4) Final cleanup: remove any accidental leading bullets/dashes and collapse internal newlines
        let cleaned = items
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .map { $0.replacingOccurrences(of: "  ", with: " ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return cleaned
    }

    
    
    private func normalizeParagraphNewlines(_ s: String) -> String {
        // 1) Normalize line endings
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")

        // 2) Split into paragraphs on blank lines
        let paragraphs = t
            .components(separatedBy: CharacterSet.newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { lines -> String in
                // Join line-wrapped content into one paragraph line
                lines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }

        // 3) Re-join paragraphs with a single blank line between
        t = paragraphs.joined(separator: "\n\n")

        // 4) Collapse repeated spaces
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func formatNOAAAlertBody(_ raw: String) -> String {
        // Goal: remove NOAA hard-wrapped line breaks (which make lines end early)
        // while preserving real paragraph breaks and keeping bullet/header lines intact.

        // 1) Normalize line endings
        let s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = s.components(separatedBy: "\n")

        var out: [String] = []
        var currentParagraph = ""

        // Tracks whether the last emitted line was a star/bullet/header that may have wrapped
        var lastLineCanContinue = false

        func flushParagraph() {
            let trimmed = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(trimmed)
            }
            currentParagraph = ""
        }

        func appendBlankLine() {
            // Avoid stacking multiple blank lines
            if out.last != "" {
                out.append("")
            }
            lastLineCanContinue = false
        }

        func isHeaderLike(_ t: String) -> Bool {
            let upper = t.uppercased()
            return upper.hasSuffix("...") && upper == upper
        }

        func isBulletLike(_ t: String) -> Bool {
            t.hasPrefix("*") || t.hasPrefix("•") || t.hasPrefix("-")
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                flushParagraph()
                appendBlankLine()
                continue
            }

            let bullet = isBulletLike(t)
            let header = isHeaderLike(t)

            // If the previous emitted line was a star/bullet/header and NOAA wrapped the value
            // onto the next line(s) without repeating the bullet, stitch it back together.
            if !bullet && !header && lastLineCanContinue {
                if let last = out.last, last != "" {
                    out[out.count - 1] = last + " " + t
                } else if !currentParagraph.isEmpty {
                    currentParagraph += " " + t
                } else {
                    currentParagraph = t
                }
                continue
            }

            // Treat bullet-ish lines and NOAA section headers as standalone lines.
            // This keeps lists readable while still fixing mid-sentence wraps.
            if bullet || header {
                flushParagraph()
                out.append(t)

                // Star bullets like "* WHERE..." frequently wrap onto following lines.
                // Allow continuation only for lines that look like NOAA bullets/headers.
                if t.hasPrefix("*") && t.contains("...") {
                    lastLineCanContinue = true
                } else {
                    lastLineCanContinue = false
                }
                continue
            }

            // Normal prose: join hard-wrapped lines into a single paragraph.
            lastLineCanContinue = false
            if currentParagraph.isEmpty {
                currentParagraph = t
            } else {
                currentParagraph += " " + t
            }
        }

        flushParagraph()

        // Trim any trailing blank line
        while out.last == "" { out.removeLast() }

        return out.joined(separator: "\n")
    }
    
    private func openAlertDetail(_ alert: NWSAlertsResponse.Feature) {
        let p = alert.properties

        let description: String? = {
            guard let desc = p.descriptionText, !desc.isEmpty else { return nil }

            // Rollback: keep NOAA narrative formatting; only normalize line endings.
            let cleaned = formatNOAAAlertBody(desc)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? nil : cleaned
        }()

        let instructions: [String] = {
            guard let instr = p.instructionText, !instr.isEmpty else { return [] }
            let formattedInstr = formatNOAAInstructions(instr)
            return parseInstructionItems(from: formattedInstr)
        }()

        selectedDetail = DetailPayload(
            title: p.event,
            description: description,
            instructions: instructions,
            severity: p.severity
        )
    }

    private func normalizeInlineSpacing(_ s: String) -> String {
        // Collapse repeated spaces
        var out = s.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)

        // Remove weird space before punctuation
        out = out.replacingOccurrences(of: " .", with: ".")
                 .replacingOccurrences(of: " ,", with: ",")
                 .replacingOccurrences(of: " ;", with: ";")
                 .replacingOccurrences(of: " :", with: ":")

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatNOAAInstructions(_ raw: String) -> String {
        // 1) Normalize newlines
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")

        // 2) Split into paragraphs on blank lines
        let paragraphs = s
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 3) For each paragraph:
        //    - remove any leading bullets/stars/dashes on each line
        //    - join hard-wrapped lines into one line
        //    - collapse extra spaces
        let cleaned: [String] = paragraphs.map { para in
            let lines = para
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line in
                    // Strip common NOAA list markers if present
                    line
                        .replacingOccurrences(of: #"^[\*\-\u2022]+\s*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression) // (1) style
                }

            // Join wrapped lines into one paragraph
            var joined = lines.joined(separator: " ")

            // Collapse repeated spaces
            joined = joined.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

            return joined
        }

        // 4) Bullet each paragraph
        return cleaned.map { "• \($0)" }.joined(separator: "\n")
    }

    private func normalizeLines(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
    }

    private func bulletizeNOAAStarLine(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("*") else { return nil }

        var s = trimmedLine
        s.removeFirst()
        s = s.trimmingCharacters(in: .whitespaces)

        if let r = s.range(of: "...") {
            let label = s[..<r.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

            // (Removed WHERE bullet dropping)

            let value = s[r.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !label.isEmpty, !value.isEmpty else { return nil }
            return "• \(label.capitalized): \(value)"
        }

        return "• \(s)"
    }

    private func isAllCapsHeader(_ s: String) -> Bool {
        // Heuristic: mostly letters/spaces and already uppercase
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 4 else { return false }
        return letters.allSatisfy { String($0) == String($0).uppercased() }
    }
    
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

private struct AlertNarrativeSection: Identifiable {
    let id = UUID()
    let label: String?
    let body: String
}

private func stripLeadingBullet(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)

    // remove common leading bullet styles NOAA text sometimes includes
    while t.hasPrefix("•") || t.hasPrefix("-") || t.hasPrefix("• ") || t.hasPrefix("- ") {
        t = t
            .replacingOccurrences(of: "•", with: "", options: .anchored)
            .replacingOccurrences(of: "-", with: "", options: .anchored)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return t
}

/// Parses NOAA-style narrative like:
/// "WHAT...text\n\nWHEN...text\n\nIMPACTS...text"
private func parseAlertNarrativeSections(from text: String) -> [AlertNarrativeSection] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // labels you care about (add more if you want)
    let labels = ["WHAT", "WHEN", "WHERE", "IMPACTS", "ADDITIONAL DETAILS", "PRECAUTIONARY/PREPAREDNESS ACTIONS"]
    // Intentionally unused (rollback to the warning state per request)
    let labelPattern = labels.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

    let labelRegex = labels.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

    // Match: LABEL... body (until next LABEL... or end)
    let pattern = #"(?s)(?:^|\n)\s*(\#(labelRegex))\s*\.{3}\s*(.*?)(?=(?:\n\s*(?:\#(labelRegex))\s*\.{3})|\z)"#

    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
        return [AlertNarrativeSection(label: nil, body: normalized)]
    }

    let ns = normalized as NSString
    let matches = re.matches(in: normalized, options: [], range: NSRange(location: 0, length: ns.length))

    if matches.isEmpty {
        return [AlertNarrativeSection(label: nil, body: normalized)]
    }

    var out: [AlertNarrativeSection] = []

    for m in matches {
        let rawLabel = ns.substring(with: m.range(at: 1))
        let rawBody = ns.substring(with: m.range(at: 2))

        let label = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized

        let body = rawBody
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !body.isEmpty {
            out.append(AlertNarrativeSection(label: "\(label)…", body: body))
        }
    }

    return out.isEmpty ? [AlertNarrativeSection(label: nil, body: normalized)] : out
}



private struct InlineAlertRow: View {
    let alert: NWSAlertsResponse.Feature

    var body: some View {
        HStack(spacing: 10) {
            let sevColor = colorForSeverity(alert.properties.severity)

            Image(systemName: symbolForSeverity(alert.properties.severity))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, sevColor)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 26, height: 26, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.properties.event)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YAWATheme.textPrimary)
                    .lineLimit(1)

                if let headline = alert.properties.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.caption)
                        .foregroundStyle(YAWATheme.textSecondary)
                        .lineLimit(2)
                } else if let area = alert.properties.areaDesc, !area.isEmpty {
                    Text(area)
                        .font(.caption)
                        .foregroundStyle(YAWATheme.textSecondary)
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

    private func colorForSeverity(_ severity: String?) -> Color {
        switch severity?.lowercased() {
        case "extreme", "severe":
            return Color.red.opacity(0.95)
        case "moderate":
            return Color.orange.opacity(0.9)
        default:
            return Color.secondary.opacity(0.8)
        }
    }
}

private struct LocationsSheet: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore

    @Binding var showingLocations: Bool
    @Binding var sourceRaw: String
    @Binding var previousSourceRaw: String?

    @StateObject private var searchVM = CitySearchViewModel()
    @FocusState private var searchFocused: Bool
    @State private var justAddedResultID: CitySearchViewModel.Result.ID? = nil

    var body: some View {
        NavigationStack {
            List {

                // MARK: - Search
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(YAWATheme.textSecondary)

                        TextField("Search city, state", text: $searchVM.query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($searchFocused)
                            .foregroundStyle(YAWATheme.textPrimary)
                            .onSubmit { Task { await searchVM.search() } }

                        if searchVM.isSearching {
                            ProgressView().controlSize(.small)
                        }

                        if !searchVM.query.isEmpty {
                            Button {
                                searchVM.query = ""
                                searchVM.results = []
                                searchFocused = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(YAWATheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowBackground(YAWATheme.card2)
                .listRowSeparator(.hidden)

                // MARK: - Search Results
                if !searchVM.results.isEmpty {
                    Section {
                        ForEach(Array(searchVM.results.prefix(8))) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title)
                                        .foregroundStyle(YAWATheme.textPrimary)

                                    if !r.subtitle.isEmpty {
                                        Text(r.subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(YAWATheme.textSecondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: (justAddedResultID == r.id) ? "star.fill" : "star")
                                    .foregroundStyle((justAddedResultID == r.id) ? Color.yellow : YAWATheme.textSecondary)
                                    .animation(.easeInOut(duration: 0.15), value: justAddedResultID)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Visual feedback: briefly fill the star so the user sees the add
                                justAddedResultID = r.id
                                lightHaptic()

                                if previousSourceRaw == nil { previousSourceRaw = sourceRaw }
                                sourceRaw = CurrentConditionsSource.noaa.rawValue

                                let f = FavoriteLocation(
                                    title: r.title,
                                    subtitle: r.subtitle,
                                    latitude: r.coordinate.latitude,
                                    longitude: r.coordinate.longitude
                                )

                                favorites.add(f)
                                selection.selectedFavorite = f

                                // Give the star-fill a brief moment to render, then dismiss
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                                    justAddedResultID = nil
                                    searchVM.query = ""
                                    searchVM.results = []
                                    searchFocused = false
                                    showingLocations = false
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(YAWATheme.card2)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Results")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(YAWATheme.textPrimary)
                    }
                    .textCase(nil)
                }

                // MARK: - Current Location
                Section {
                    HStack {
                        Text("Current Location")
                            .foregroundStyle(YAWATheme.textPrimary)

                        Spacer()

                        if selection.selectedFavorite == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(YAWATheme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection.selectedFavorite = nil

                        if let prev = previousSourceRaw {
                            sourceRaw = prev
                            previousSourceRaw = nil
                        }

                        searchVM.query = ""
                        searchVM.results = []
                        searchFocused = false
                        showingLocations = false
                    }
                }
                .listRowBackground(YAWATheme.card2)
                .listRowSeparator(.hidden)

                // MARK: - Favorites
                Section {
                    if favorites.favorites.isEmpty {
                        Text("No favorites yet.")
                            .foregroundStyle(YAWATheme.textSecondary)
                            .listRowBackground(YAWATheme.card2)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(favorites.favorites) { f in
                            HStack {
                                Text(f.displayName)
                                    .foregroundStyle(YAWATheme.textPrimary)

                                Spacer()

                                if selection.selectedFavorite?.id == f.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(YAWATheme.textSecondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if previousSourceRaw == nil { previousSourceRaw = sourceRaw }
                                sourceRaw = CurrentConditionsSource.noaa.rawValue
                                selection.selectedFavorite = f
                                showingLocations = false
                            }
                            // ✅ Swipe works reliably on non-Button row content
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    lightHaptic()
                                    favorites.remove(f)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .tint(Color.red.opacity(0.35))
                            }
                            .listRowBackground(YAWATheme.card2)
                            .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    Text("Favorites")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YAWATheme.textPrimary)
                }
                .textCase(nil)
            }
            .scrollContentBackground(.hidden)
                .background(YAWATheme.sky)
                .listStyle(.insetGrouped)
                .navigationTitle("Favorites")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            searchVM.query = ""
                            searchVM.results = []
                            searchFocused = false
                            showingLocations = false
                        }
                    }
                }
            // Nav bar glass + readable title (Daily Forecast style)
//            .toolbarBackground(.visible, for: .navigationBar)
//            .toolbarBackground(YAWATheme.card2, for: .navigationBar)   // ✅ tint like Daily Forecast
//            .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .preferredColorScheme(.dark)
            .preferredColorScheme(.dark)
        }
    }
}



private func successHaptic() {
    let gen = UINotificationFeedbackGenerator()
    gen.prepare()
    gen.notificationOccurred(.success)
}

func lightHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred()
}

private func iconYOffset(symbol: String, hasPop: Bool) -> CGFloat {
    guard !hasPop else { return 0 }

    switch symbol {
    case "sun.max.fill", "sun.max":
        return 8
    case "cloud.sun.fill", "cloud.sun":
        return 6
    default:
        return 3
    }
}



#Preview {
    NavigationStack { ContentView() }
        .environmentObject(FavoritesStore())
        .environmentObject(LocationSelectionStore())
}
