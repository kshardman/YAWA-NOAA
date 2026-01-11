//
//  InlineForecastCard.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/5/26.
//


import SwiftUI
import CoreLocation
import Combine

struct InlineForecastCard: View {
    let coord: CLLocationCoordinate2D?
    let locationTitle: String
    let initialSelection: FavoriteLocation?   // (kept for compatibility, not used here)

    @StateObject private var vm = ForecastViewModel()

    // MARK: - Inline alert row
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forecast")
                        .font(.headline)

                    Text(locationTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if vm.isLoading && vm.periods.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }

            // MARK: Alerts & Advisories (restored)
            Text("DEBUG alerts=\(vm.alerts.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let top = vm.alerts.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alerts & Advisories")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    InlineAlertRow(alert: top)

                    if vm.alerts.count > 1 {
                        Text("\(vm.alerts.count - 1) more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(YAWATheme.card2)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            // Error message (kept below alerts so advisories still show even if forecast fails)
            if let msg = vm.errorMessage {
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Forecast rows
            if !vm.periods.isEmpty {
                let days = Array(combineDayNight(Array(vm.periods.prefix(14))).prefix(7))

                ForEach(days) { d in
                    let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)

                    HStack(spacing: 10) {
                        Text(abbreviatedDayName(d.name))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 42, alignment: .leading)

                        Image(systemName: sym.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(sym.color)
                            .font(.title3)
                            .frame(width: 26, alignment: .center)

                        Spacer()

                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }

                    if d.id != days.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            } else if !vm.isLoading && vm.errorMessage == nil {
                Text("No forecast yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
//        .background(tileBackground)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task {
            guard let coord else { return }
            await vm.refresh(for: coord)     // ✅ refresh pulls periods + alerts
        }
        .onChange(of: coordKey(coord)) {
            guard let coord else { return }
            Task { await vm.refresh(for: coord) }  // ✅
        }
    }

    private func coordKey(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "nil" }
        return "\(c.latitude.rounded(toPlaces: 3))_\(c.longitude.rounded(toPlaces: 3))"
    }
}
