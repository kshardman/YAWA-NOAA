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
    
    @State private var lastCurrentRefreshAt: Date? = nil
    @State private var lastForecastRefreshAt: Date? = nil
    @State private var lastRefreshCoord: CLLocationCoordinate2D? = nil
    
    @State private var pendingForegroundRefresh = false

    private let refreshMaxAge: TimeInterval = 15 * 60   // 15 minutes
    private let refreshDistanceMeters: CLLocationDistance = 1500 // ~1.5 km
    

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore
    
    @State private var selectedDetail: DetailPayload?

    private enum DetailBody {
        case text(String)
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

        init(title: String, description: String?, instructions: [String], severity: String?) {
            self.title = title
            self.body = .alert(description: description, instructions: instructions, severity: severity)
        }
    }
    
    struct AlertSection: Identifiable {
        let id = UUID()
        let title: String
        let paragraphs: [String]
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

    private func movedEnough(from old: CLLocationCoordinate2D?, to new: CLLocationCoordinate2D) -> Bool {
        guard let old else { return true }
        let dLat = abs(old.latitude - new.latitude)
        let dLon = abs(old.longitude - new.longitude)
        return dLat > 0.02 || dLon > 0.02   // ~1–2 miles-ish; adjust as you like
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
        Color(.secondarySystemBackground)
    }

    private var headerLocationText: String {
        if source == .pws { return "" } // don’t show stale NOAA location in PWS mode
        return selection.selectedFavorite?.displayName ?? (location.locationName ?? "Current Location")
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
        location.request()

        let shouldByAge = isStale(lastCurrentRefreshAt, maxAge: refreshMaxAge)
        let shouldByMove = movedEnough(from: lastRefreshCoord, to: location.coordinate)

        guard shouldByAge || shouldByMove else { return }

        viewModel.setLoadingPlaceholders()
        if source == .noaa { forecastVM.setLoadingPlaceholders() }
        await Task.yield()

        await refreshNow()
        if source == .noaa { await refreshForecastNow() }

        lastCurrentRefreshAt = Date()
        lastForecastRefreshAt = Date()
        lastRefreshCoord = location.coordinate
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

            // ✅ Easter egg overlay (inside ZStack, after main VStack)
            if showEasterEgg {
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
                .zIndex(10) // keep it above everything
            }

        }

        // ============================
        // 🔽 CODE SNIPPET 1 STARTS HERE
        // ============================

        .task {
            // 🔔 Ask for notification permission once on launch
            await NotificationService.shared.requestAuthorizationIfNeeded()
            location.request()

            // immediate refresh on launch
            viewModel.setLoadingPlaceholders()
            if source == .noaa { forecastVM.setLoadingPlaceholders() }
            await Task.yield()

            await refreshNow()
            if source == .noaa { await refreshForecastNow() }

            recordRefresh(coord: location.coordinate)
        }
        
        .onReceive(location.$coordinate) { coord in
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
        
 //       .onReceive(location.$locationName) { name in
 //           guard selection.selectedFavorite == nil else { return }
//            guard let name, !name.isEmpty else { return }
  //          viewModel.currentLocationLabel = name
//        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guard selection.selectedFavorite == nil else { return } // favorites handled elsewhere

            pendingForegroundRefresh = true
            location.refresh()   // one-shot location request
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Yawa")
                    .font(.headline)
                    .onLongPressGesture(minimumDuration: 1.0) {
                        triggerEasterEgg()
                    }
                    .accessibilityLabel("YAWA")
            }

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
                    VStack(alignment: .leading, spacing: 16) {

                        switch detail.body {

                        case .text(let text):
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineSpacing(6)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                        case .alert(let description, let instructions, let severity):

                            // MAIN NARRATIVE (WHAT / WHEN / IMPACTS / ADDITIONAL DETAILS)
                            if let description, !description.isEmpty {
                                let sections = parseAlertNarrativeSections(from: description)

                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(sections) { s in
                                        VStack(alignment: .leading, spacing: 6) {
                                            if let label = s.label {
                                                Text(label)
                                                    .font(.headline)
                                            }

                                            Text(s.body)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                                .lineSpacing(6)
                                                .multilineTextAlignment(.leading)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }

                            // WHAT TO DO — proper bullets
                            if !instructions.isEmpty {
                                Text("What to do")
                                    .font(.headline)
                                    .padding(.top, description == nil ? 0 : 4)

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(instructions, id: \.self) { item in
                                        let cleaned = stripLeadingBullet(item)

                                        HStack(alignment: .top, spacing: 10) {
                                            Text("•")
                                                .font(.callout.weight(.semibold))
                                                .padding(.top, 1)

                                            Text(cleaned)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                                .lineSpacing(4)
                                                .multilineTextAlignment(.leading)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }

                            // SEVERITY FOOTER
                            if let severity, !severity.isEmpty {
                                Divider().padding(.top, 6)

                                Text("Severity: \(severity)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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

            // Alerts & Advisories (tap to expand)
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
                .contentShape(Rectangle())
                .onTapGesture {
                    let p = top.properties

                    let description: String? = {
                        guard let desc = p.descriptionText, !desc.isEmpty else { return nil }
                        let formatted = normalizeParagraphNewlines(formatNOAAAlertBody(desc))
                        return formatted.isEmpty ? nil : formatted
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
            }

            // Forecast rows
            if !forecastVM.periods.isEmpty {

                let sideCol: CGFloat = 120 // tweak 110–140 to taste
                let forecastDays: [DailyForecast] =
                    Array(combineDayNight(Array(forecastVM.periods.prefix(14))).prefix(7))

                ForEach(forecastDays, id: \.id) { d in
                    let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)

                    HStack(spacing: 10) {

                        // Left column (fixed)
                        HStack(spacing: 6) {
                            Text(weekdayLabel(d.startDate))
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let dayText = (d.day.detailedForecast ?? d.day.shortForecast)
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        let nightText = (d.night?.detailedForecast ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        var parts: [String] = []

                        if !dayText.isEmpty {
                            parts.append("Day...\n\(dayText)")
                        }

                        if !nightText.isEmpty, nightText != dayText {
                            parts.append("Night...\n\(nightText)")
                        }

                        let description = parts.joined(separator: "\n\n")

                        selectedDetail = DetailPayload(
                            title: "\(abbreviatedDayName(d.name)) \(d.dateText)",
                            description: description.isEmpty ? nil : description,
                            instructions: [],
                            severity: nil
                        )
                    }

                    // If you want dividers between rows, add them here:
                    // if d.id != forecastDays.last?.id { Divider().opacity(0.35) }
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
        ZStack(alignment: .top) {

            // Temperature centered vertically
            VStack {
                Spacer(minLength: 0)

                Text(viewModel.temp)
                    .font(Font.system(size: tempFontSize, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            // Thermometer icon “floats” near the top
            Image(systemName: "thermometer")
                .foregroundStyle(.red)
                .font(tempIconFont)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: bigMinHeight * 1.15)          // ✅ lock height (not minHeight)
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

                                    Image(systemName: "star")
                                        .foregroundStyle(.secondary)
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

    private func refreshNow() async {
        if let f = selection.selectedFavorite {
            // Favorites always imply NOAA
            await viewModel.fetchCurrentFromNOAA(
                lat: f.coordinate.latitude,
                lon: f.coordinate.longitude,
                locationName: f.displayName
            )
        } else {
            // ✅ Clean architecture:
            // In current-location (GPS) mode, do NOT pass a locationName into the fetch.
            // LocationManager's reverse geocode owns the header label, preventing stale “snap back”.
            await viewModel.refreshCurrentConditions(
                source: source,
                coord: location.coordinate,
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

        guard let coord = location.coordinate else { return }

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

    
    func parseAlertSections(from text: String) -> [AlertSection] {
        let cleaned = text
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = [
            ("WHAT", "WHAT"),
            ("WHEN", "WHEN"),
            ("IMPACTS", "IMPACTS")
        ]

        var sections: [AlertSection] = []

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
                        AlertSection(title: title.capitalized, paragraphs: body)
                    )
                }
            }
        }

        return sections
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
        // Normalize line endings
        let s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Split + trim + strip leading "*" / "•"
        let lines = s
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line -> String in
                var l = line
                while l.hasPrefix("*") || l.hasPrefix("•") {
                    l.removeFirst()
                    l = l.trimmingCharacters(in: .whitespaces)
                }
                return l
            }

        // Section detection (NOAA uses WHAT... WHERE... WHEN... IMPACTS... etc)
        func sectionHeader(_ line: String) -> String? {
            let upper = line.uppercased()

            // Typical NOAA pattern: "WHAT..." / "WHERE..." / "WHEN..." / "IMPACTS..."
            let known = ["WHAT...", "WHERE...", "WHEN...", "IMPACTS...", "HAZARD...", "SOURCE...", "INFO..."]
            for k in known where upper.hasPrefix(k) { return k }

            // Also handle "What:" style
            if upper.hasPrefix("WHAT:") { return "WHAT..." }
            if upper.hasPrefix("WHERE:") { return "WHERE..." }
            if upper.hasPrefix("WHEN:") { return "WHEN..." }
            if upper.hasPrefix("IMPACTS:") { return "IMPACTS..." }

            return nil
        }

        var outBlocks: [String] = []
        var currentLines: [String] = []
        var skippingWhere = false

        func flush() {
            let joined = currentLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { outBlocks.append(joined) }
            currentLines.removeAll()
        }

        for line in lines {
            if line.isEmpty {
                // treat blank lines as paragraph separators
                flush()
                continue
            }

            if let header = sectionHeader(line) {
                // whenever we hit a header, end prior block
                flush()

                // Start/stop WHERE skipping
                if header == "WHERE..." {
                    skippingWhere = true
                    continue
                } else {
                    // leaving WHERE section when we hit the next known header
                    skippingWhere = false
                }

                // Keep WHAT/WHEN/IMPACTS headers in-line (but without bullets)
                // Example: "WHAT...Cold..." stays as one paragraph.
                currentLines.append(line)
                continue
            }

            // If we are inside WHERE, drop ALL lines until next header
            if skippingWhere {
                continue
            }

            currentLines.append(line)
        }

        flush()

        // Final cleanup: collapse repeated spaces
        let cleaned = outBlocks
            .map { $0.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return cleaned.joined(separator: "\n\n")
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

            if label == "WHERE" { return nil }   // ✅ drop WHERE

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

private struct AlertSection: Identifiable {
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
private func parseAlertNarrativeSections(from text: String) -> [AlertSection] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // labels you care about (add more if you want)
    let labels = ["WHAT", "WHEN", "IMPACTS", "ADDITIONAL DETAILS", "PRECAUTIONARY/PREPAREDNESS ACTIONS"]
    let labelPattern = labels.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

    // Match: LABEL... body (until next LABEL... or end)
    let pattern = #"(?s)(?:^|\n)\s*(\#(labelPattern))\s*\.{3}\s*(.*?)(?=(?:\n\s*(?:\#(labelPattern))\s*\.{3})|\z)"#

    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
        return [AlertSection(label: nil, body: normalized)]
    }

    let ns = normalized as NSString
    let matches = re.matches(in: normalized, options: [], range: NSRange(location: 0, length: ns.length))

    if matches.isEmpty {
        return [AlertSection(label: nil, body: normalized)]
    }

    var out: [AlertSection] = []

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
            out.append(AlertSection(label: "\(label)…", body: body))
        }
    }

    return out.isEmpty ? [AlertSection(label: nil, body: normalized)] : out
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

// private struct UpdatedStatusRow: View {
//    let text: String
//    let isRefreshing: Bool
//    let color: Color

//    var body: some View {
//        HStack(spacing: 8) {
//            if isRefreshing {
//                ProgressView()
//                    .controlSize(.mini)
//                    .tint(color)
//                    .transition(.opacity.combined(with: .scale))
//            }

//            Text(text)
//                .font(.subheadline)
//                .foregroundStyle(color)
//                .contentTransition(.opacity)
//        }
//        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
//    }
// }




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
