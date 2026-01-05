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
    let initialSelection: FavoriteLocation?

    @StateObject private var vm = ForecastViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

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

            if let msg = vm.errorMessage {
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !vm.periods.isEmpty {
                // show 7 days: your NOAA periods are day/night, so 14 periods ~ 7 days.
                ForEach(combineDayNight(Array(vm.periods.prefix(14))).prefix(7)) { d in
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

                    if d.id != combineDayNight(Array(vm.periods.prefix(14))).prefix(7).last?.id {
                        Divider().opacity(0.35)
                    }
                }
            } else if !vm.isLoading {
                Text("No forecast yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task {
            guard let coord else { return }
            await vm.loadIfNeeded(for: coord)
        }
        .onChange(of: coordKey(coord)) {
            guard let coord else { return }
            Task { await vm.loadIfNeeded(for: coord) }
        }
    }

    private func coordKey(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "nil" }
        return "\(c.latitude.rounded(toPlaces: 3))_\(c.longitude.rounded(toPlaces: 3))"
    }
}
