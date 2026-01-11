//
//  ForecastView.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/5/26.
//


import SwiftUI
import CoreLocation

struct ForecastView: View {

    // MARK: - State
    @StateObject private var location = LocationManager()
    @StateObject private var vm = ForecastViewModel()
    @StateObject private var searchVM = CitySearchViewModel()

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var selection: LocationSelectionStore

    @State private var showingFavorites = false
    @State private var selectedDetail: DetailPayload?

    private let sideColumnWidth: CGFloat = 130

    private struct DetailPayload: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    private var coordKey: String? {
        guard let c = location.coordinate else { return nil }
        return "\(c.latitude.rounded(toPlaces: 3))_\(c.longitude.rounded(toPlaces: 3))"
    }

    private var subtitleLocationText: String {
        if let selected = selection.selectedFavorite {
            return selected.displayName
        }

        if let name = location.locationName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        return "Current Location"
    }

    private var isShowingCurrentGPS: Bool {
        selection.selectedFavorite == nil
    }

    private struct AlertBanner: View {
        let alert: NWSAlertsResponse.Feature

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: symbolForSeverity(alert.properties.severity))
                        .foregroundStyle(YAWATheme.alert)
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

    var body: some View {
        List {

            if let top = vm.alerts.first {
                Section { AlertBanner(alert: top) }
            }

            if let msg = location.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }

            if let msg = vm.errorMessage {
                Text(msg).foregroundStyle(.secondary)
            }

            // ✅ Uses the shared helper from ForecastHelpers.swift
            ForEach(combineDayNight(Array(vm.periods.prefix(14)))) { d in
                let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text(abbreviatedDayName(d.name))
                                .font(.headline)
                            Text(d.dateText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: sideColumnWidth, alignment: .leading)

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

                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(width: sideColumnWidth, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let dayText = d.day.detailedForecast ?? d.day.shortForecast
                    let nightText = d.night?.detailedForecast

                    let body: String
                    if let nightText, !nightText.isEmpty, nightText != dayText {
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
            }
        }

        // ... keep the rest of your safeAreaInset, toolbar, sheets, lifecycle exactly as you have it ...
        // (No changes needed for the scope issue.)
        .navigationBarTitleDisplayMode(.inline)
    }
}
