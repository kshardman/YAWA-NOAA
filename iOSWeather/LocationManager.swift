//
//  LocationManager.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/28/25.
//


import SwiftUI
import CoreLocation
import Combine
import MapKit

//city search

@MainActor
final class CitySearchViewModel: ObservableObject {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    @Published var query: String = ""
    @Published var results: [Result] = []
    @Published var isSearching = false

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = []; return }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.resultTypes = [.address]   // city/state hits well

        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.compactMap { item in
                guard let name = item.placemark.locality ?? item.name else { return nil }
                let state = item.placemark.administrativeArea ?? ""
                return Result(title: name, subtitle: state, coordinate: item.placemark.coordinate)
            }
        } catch {
            results = []
        }
    }
}


// MARK: - Location

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    // City, ST for display
    @Published var locationName: String?

    private let manager = CLLocationManager()
    private var lastGeocodedCoord: CLLocationCoordinate2D?
    private let geocoder = CLGeocoder()

    
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        errorMessage = nil
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func refresh() {
        errorMessage = nil
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            errorMessage = "Location access is disabled."
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        coordinate = loc.coordinate
        Task { await reverseGeocodeIfNeeded(for: loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = "Could not get location."
        print("Location error:", error)
    }

    // MARK: - Reverse geocode (City, ST)

    private func reverseGeocodeIfNeeded(for location: CLLocation) async {
        if let last = lastGeocodedCoord {
            let dLat = abs(last.latitude - location.coordinate.latitude)
            let dLon = abs(last.longitude - location.coordinate.longitude)
            if dLat < 0.01 && dLon < 0.01 { return }
        }
        lastGeocodedCoord = location.coordinate

        geocoder.cancelGeocode()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let place = placemarks.first else { return }

            let city = place.locality
            let state = place.administrativeArea

            await MainActor.run {
                if let city, let state { self.locationName = "\(city), \(state)" }
                else if let city { self.locationName = city }
                else if let state { self.locationName = state }
                else { self.locationName = nil }
            }
        } catch {
            // silent fail is fine
        }
    }
}


// MARK: - NOAA/NWS API models

struct NWSAlertsResponse: Decodable {
    struct Feature: Decodable, Identifiable {
        struct Properties: Decodable {
            let event: String
            let headline: String?
            let severity: String?
            let urgency: String?
            let areaDesc: String?
        }

        let id: String
        let properties: Properties
    }

    let features: [Feature]
}

struct NWSPointsResponse: Decodable {
    struct Properties: Decodable {
        let forecast: String
        let observationStations: String
    }
    let properties: Properties
}

struct NWSForecastResponse: Decodable {

    struct Properties: Decodable {
        let periods: [Period]
    }

    let properties: Properties

    struct Period: Decodable, Identifiable {
        let number: Int
        var id: Int { number }

        let name: String
        let startTime: Date            // ✅ ADD
        let isDaytime: Bool
        let temperature: Int
        let temperatureUnit: String
        let windSpeed: String
        let windDirection: String
        let shortForecast: String
        let detailedForecast: String?
        let probabilityOfPrecipitation: ProbabilityOfPrecipitation?
    }

    struct ProbabilityOfPrecipitation: Decodable {
        let value: Double?
    }
}

enum NOAAServiceError: Error {
    case invalidURL
    case badStatus(Int)
}

// MARK: - NOAA Service

final class NOAAService {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    func fetchActiveAlerts(lat: Double, lon: Double) async throws -> [NWSAlertsResponse.Feature] {
        guard let url = URL(string: "https://api.weather.gov/alerts/active?point=\(lat),\(lon)") else {
            throw NOAAServiceError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("iOSWeather (personal app)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAAServiceError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(NWSAlertsResponse.self, from: data)
        return decoded.features
    }
    
    func fetch7DayPeriods(lat: Double, lon: Double) async throws -> [NWSForecastResponse.Period] {
        // 1) points endpoint
        guard let pointsURL = URL(string: "https://api.weather.gov/points/\(lat),\(lon)") else {
            throw NOAAServiceError.invalidURL
        }

        var pointsReq = URLRequest(url: pointsURL)
        pointsReq.setValue("iOSWeather (personal app)", forHTTPHeaderField: "User-Agent")
        pointsReq.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (pointsData, pointsResp) = try await session.data(for: pointsReq)
        if let http = pointsResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAAServiceError.badStatus(http.statusCode)
        }

        let points = try JSONDecoder().decode(NWSPointsResponse.self, from: pointsData)

        // 2) forecast url from points
        guard let forecastURL = URL(string: points.properties.forecast) else {
            throw NOAAServiceError.invalidURL
        }

        var forecastReq = URLRequest(url: forecastURL)
        forecastReq.setValue("iOSWeather (personal app)", forHTTPHeaderField: "User-Agent")
        forecastReq.setValue("application/geo+json", forHTTPHeaderField: "Accept")

        let (forecastData, forecastResp) = try await session.data(for: forecastReq)
        if let http = forecastResp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NOAAServiceError.badStatus(http.statusCode)
        }

 //       let decoded = try JSONDecoder().decode(NWSForecastResponse.self, from: forecastData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NWSForecastResponse.self, from: forecastData)
        return decoded.properties.periods
    }
}

// MARK: - Forecast VM


@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var periods: [NWSForecastResponse.Period] = []
    @Published var alerts: [NWSAlertsResponse.Feature] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = NOAAService()
    private var lastCoord: CLLocationCoordinate2D?
    

    func loadIfNeeded(for coord: CLLocationCoordinate2D) async {
        // Prevent refetch spam from minor GPS jitter
        if let last = lastCoord,
           abs(last.latitude - coord.latitude) < 0.01,
           abs(last.longitude - coord.longitude) < 0.01,
           !periods.isEmpty {
            return
        }
        lastCoord = coord
        await refresh(for: coord)
    }

    func refresh(for coord: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let periodsTask = service.fetch7DayPeriods(lat: coord.latitude, lon: coord.longitude)
            async let alertsTask  = service.fetchActiveAlerts(lat: coord.latitude, lon: coord.longitude)

            periods = try await periodsTask
            alerts  = try await alertsTask

            errorMessage = nil
        } catch {
            errorMessage = "Forecast unavailable."
        }
    }
    
    
}

// MARK: - View

func conditionsSymbolAndColor(
    for text: String,
    isNight: Bool
) -> (symbol: String, color: Color) {

    let t = text.lowercased()

    if t.contains("thunder") {
        return ("cloud.bolt.rain.fill", .purple)
    }

    if t.contains("snow") || t.contains("sleet") || t.contains("ice") {
        return ("cloud.snow.fill", .cyan)
    }

    if t.contains("rain") || t.contains("shower") || t.contains("drizzle") {
        return ("cloud.rain.fill", .blue)
    }

    if t.contains("fog") || t.contains("mist") || t.contains("haze") {
        return ("cloud.fog.fill", .gray)
    }

    if t.contains("overcast") || t.contains("cloudy") {
        return ("cloud.fill", .gray)
    }

    if t.contains("partly") || t.contains("mostly") {
        return isNight
            ? ("cloud.moon.fill", .gray)
            : ("cloud.sun.fill", .yellow)
    }

    if t.contains("clear") || t.contains("sunny") {
        return isNight
            ? ("moon.stars.fill", .gray)
            : ("sun.max.fill", .yellow)
    }

    return ("cloud.fill", .secondary)
}

private func forecastSymbolAndColor(
    for text: String,
    isDaytime: Bool
) -> (symbol: String, color: Color) {

    let t = text.lowercased()

    if t.contains("thunder") {
        return ("cloud.bolt.rain.fill", .purple)
    }

    if t.contains("snow") {
        return ("snowflake", .cyan)
    }

    if t.contains("sleet") || t.contains("ice") {
        return ("cloud.sleet.fill", .cyan)
    }

    if t.contains("rain") || t.contains("showers") {
        return ("cloud.rain.fill", .blue)
    }

    if t.contains("fog") || t.contains("haze") {
        return ("cloud.fog.fill", .gray)
    }

    // ✅ PARTLY / MOSTLY / CLOUDY — must come BEFORE sunny
    if t.contains("partly")
        || t.contains("mostly")
        || t.contains("scattered")
        || t.contains("cloud") {
        return (
            isDaytime ? "cloud.sun.fill" : "cloud.moon.fill",
            .gray
        )
    }

    // ✅ TRUE clear only
    if t.contains("sunny") || t.contains("clear") {
        return (
            isDaytime ? "sun.max.fill" : "moon.stars.fill",
            isDaytime ? .yellow : .secondary
        )
    }

    return ("cloud.fill", .gray)
}

private struct DailyForecast: Identifiable {
    let id: Int
    let name: String
    let startDate: Date        // ✅ stored date for the day

    let day: NWSForecastResponse.Period
    let night: NWSForecastResponse.Period?

    var highText: String {
//        "\(day.temperature)°\(day.temperatureUnit)"
        "\(day.temperature)°"
    }

    var lowText: String {
        if let night {
//            return "\(night.temperature)°\(night.temperatureUnit)"
            return "\(night.temperature)°"
        } else {
//            return "\(day.temperature)°\(day.temperatureUnit)"
            return "\(day.temperature)°"
        }
    }

    // ✅ THIS is where your dateText goes
    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: startDate)
    }
}

private func popText(_ p: NWSForecastResponse.Period) -> String? {
    guard let v = p.probabilityOfPrecipitation?.value else { return nil }
    let roundedTo10 = Int((v / 10.0).rounded() * 10.0)
    guard roundedTo10 > 0 else { return nil }   // hide 0%
    return "\(roundedTo10)%"
}

private func abbreviatedDayName(_ name: String) -> String {
    switch name {
    case "Monday":    return "Mon"
    case "Tuesday":   return "Tue"
    case "Wednesday": return "Wed"
    case "Thursday":  return "Thu"
    case "Friday":    return "Fri"
    case "Saturday":  return "Sat"
    case "Sunday":    return "Sun"
    default:
        return name
    }
}

private func combineDayNight(_ periods: [NWSForecastResponse.Period]) -> [DailyForecast] {
    var out: [DailyForecast] = []
    var i = 0

    while i < periods.count {
        let p = periods[i]

        if p.isDaytime {
            let next = (i + 1 < periods.count) ? periods[i + 1] : nil
            let night = (next?.isDaytime == false) ? next : nil

            let isoFormatter = ISO8601DateFormatter()
//            let startDate = isoFormatter.date(from: p.startTime) ?? Date()
            let startDate = p.startTime
            out.append(DailyForecast(
                id: p.number,
                name: p.name,
                startDate: startDate,
                day: p,
                night: night
            ))
            i += (night == nil ? 1 : 2)
        } else {
            // If we start on a night period for some reason, skip it
            i += 1
        }
    }

    return out
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}

struct ForecastView: View {

    // MARK: - State
    @StateObject private var location = LocationManager()
    @StateObject private var vm = ForecastViewModel()
    @StateObject private var searchVM = CitySearchViewModel()
    @StateObject private var favorites = FavoritesStore()

    @State private var selected: FavoriteLocation? = nil
    @State private var showingFavorites = false
    @State private var selectedDetail: DetailPayload?

    private let sideColumnWidth: CGFloat = 130
    
    // MARK: - Detail payload
    private struct DetailPayload: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    // MARK: - Coordinate key (Equatable)
    private var coordKey: String? {
        guard let c = location.coordinate else { return nil }
        return "\(c.latitude.rounded(toPlaces: 3))_\(c.longitude.rounded(toPlaces: 3))"
    }

    // MARK: - Toolbar subtitle
    private var subtitleLocationText: String {
        if let selected {
            return selected.displayName
        }
        return location.locationName ?? "Current Location"
    }

    // MARK: - Alert banner
    private struct AlertBanner: View {
        let alert: NWSAlertsResponse.Feature

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: symbolForSeverity(alert.properties.severity))
                        .foregroundStyle(.orange)
                    Text(alert.properties.event)
                        .font(.headline)
                    Spacer()
                }

                if let headline = alert.properties.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let area = alert.properties.areaDesc, !area.isEmpty {
                    Text(area)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }

        private func symbolForSeverity(_ severity: String?) -> String {
            switch severity?.lowercased() {
            case "extreme", "severe": return "exclamationmark.octagon.fill"
            case "moderate": return "exclamationmark.triangle.fill"
            default: return "info.circle.fill"
            }
        }
    }

    // MARK: - Body
    var body: some View {
        List {

            if let top = vm.alerts.first {
                Section {
                    AlertBanner(alert: top)
                }
            }

            if let msg = location.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }

            if let msg = vm.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }

            ForEach(combineDayNight(Array(vm.periods.prefix(14)))) { d in
                let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)

                VStack(alignment: .leading, spacing: 6) {

                    // Top row
                    HStack(spacing: 10) {

                        // Left column (fixed)
                        HStack(spacing: 6) {
                            Text(abbreviatedDayName(d.name))
                                .font(.headline)
                            Text(d.dateText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: sideColumnWidth, alignment: .leading)

                        // Middle column (exact center)
                        VStack(spacing: 3) {
                            Image(systemName: sym.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(sym.color)
                                .font(.title2)

                            if let pop = popText(d.day) {
                                Text(pop)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        // Right column (fixed, matches left)
                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(width: sideColumnWidth, alignment: .trailing)
                    }                }
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
                .padding(.vertical, 6)
            }
        }

        // MARK: - Search bar (bottom)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search city, state", text: $searchVM.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await searchVM.search() } }

                    if searchVM.isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)

                if !searchVM.results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(searchVM.results.prefix(6)) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.headline)
                                    if !r.subtitle.isEmpty {
                                        Text(r.subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Button {
                                    let f = FavoriteLocation(
                                        title: r.title,
                                        subtitle: r.subtitle,
                                        latitude: r.coordinate.latitude,
                                        longitude: r.coordinate.longitude
                                    )

                                    favorites.add(f)
                                    selected = f
                                    Task { await vm.refresh(for: f.coordinate) }

                                    searchVM.query = ""
                                    searchVM.results = []
                                    dismissKeyboard()
                                } label: {
                                    Image(systemName: "star.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                            Divider()
                        }
                    }
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
        }

        // MARK: - Loading overlay
        .overlay {
            if vm.isLoading && vm.periods.isEmpty {
                ProgressView("Loading forecast…")
            }
        }

        // MARK: - Toolbar
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Forecast")
                        .font(.headline)
                    Text(subtitleLocationText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFavorites = true
                } label: {
                    Image(systemName: "star.circle")
                }
            }
        }

        // MARK: - Favorites sheet
        .sheet(isPresented: $showingFavorites) {
            NavigationStack {
                List {
                    Section {
                        Button {
                            selected = nil
                            searchVM.query = ""
                            searchVM.results = []
                            dismissKeyboard()

                            if let coord = location.coordinate {
                                Task { await vm.refresh(for: coord) }
                            } else {
                                location.request()
                            }

                            showingFavorites = false
                        } label: {
                            HStack {
                                Text("Current Location")
                                Spacer()
                                if selected == nil {
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
                                    selected = f
                                    Task { await vm.refresh(for: f.coordinate) }
                                    showingFavorites = false
                                } label: {
                                    HStack {
                                        Text(f.displayName)
                                        Spacer()
                                        if selected?.id == f.id {
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
                        Button("Done") { showingFavorites = false }
                    }
                }
            }
        }

        // MARK: - Detail forecast sheet
        .sheet(item: $selectedDetail) { detail in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {

                        // Optional: a small header line that reads nicely
                        Text(detail.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(detail.body)
                            .font(.callout)                 // 👈 slightly more character than .body
                            .foregroundStyle(.primary)
                            .lineSpacing(6)                 // 👈 this is the big readability win
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

        // MARK: - Lifecycle
        .task {
            location.request()
        }
        .onChange(of: coordKey) { _ in
            guard selected == nil, let coord = location.coordinate else { return }
            Task { await vm.loadIfNeeded(for: coord) }
        }
        .refreshable {
            guard let coord = location.coordinate else { return }
            await vm.refresh(for: coord)
        }
    }
}
