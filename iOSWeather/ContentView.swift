//
//  ContentView.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/28/25.
//


//
//  ContentView.swift
//  iOSWeather
//
//  Created by Keith Sharman on 12/17/25.
//

import SwiftUI
import UIKit
import Combine

struct ContentView: View {
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var viewModel = WeatherViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    // Manual refresh UI state (spinner + “Refreshing…”)
    @State private var isManualRefreshing = false
    private var tileBackground: some ShapeStyle {
        Color(.secondarySystemBackground)
    }
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {

                    // MARK: Header (no background)
                    VStack(spacing: 10) {
                        Text("Current Conditions at home")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)

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

                    // MARK: Tiles (white, black text)
                    VStack(spacing: 14) {

                        // Row 1: Temperature (bigger / attention-grabbing)
                        tile(
                            "thermometer",
                            .red,
                            viewModel.temp,
                            "Temp",
                            valueFont: .system(size: 44, weight: .semibold)
                        )
                        // Row 2: Wind + Pressure
                        HStack(spacing: 14) {
                            tile("wind", .teal, viewModel.windDisplay, "Wind")
                            tile("gauge", .orange, viewModel.pressure, "Pressure")
                        }


                        // Row 3: Humidity + Rain
                        HStack(spacing: 14) {
                            wideTile("drop", .blue, viewModel.humidity, "Humidity")
                            wideTile("cloud.rain", .blue, viewModel.precipitation, "Rain today")
                        }
                    }

                    // MARK: 7-Day Forecast Card (NEW)
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
                                    Text("7-Day Forecasts")
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

                if await viewModel.fetchWeather(force: true) {
                    successHaptic()
                }
            }
        }
        .task {
            viewModel.loadCached()
            await viewModel.fetchWeather()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.fetchWeather() }
            }
        }
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
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
                .monospacedDigit()
                .multilineTextAlignment(.center)

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
                .font(.title2)
                .monospacedDigit()

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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

#Preview { NavigationStack { ContentView() } }
