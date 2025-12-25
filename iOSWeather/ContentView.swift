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

    // Manual refresh UI state (spinner + “Refreshing…”)
    @State private var isManualRefreshing = false

    // Time-of-day updates
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // MARK: - Condition theme logic
    private var conditionTheme: ConditionTheme {
        if !networkMonitor.isOnline { return .offline }
        if viewModel.errorMessage != nil { return .storm }
        if viewModel.isStale { return .hazy }

        let precipAmount = extractNumber(from: viewModel.precipitation)
        if precipAmount >= 0.01 {
            let tempValue = extractNumber(from: viewModel.temp)
            if tempValue > 0 && tempValue <= 32 { return .snow }
            return .rain
        }

        let tempValue = extractNumber(from: viewModel.temp)
        if tempValue > 0 {
            if tempValue >= 85 { return .hot }
            if tempValue <= 35 { return .cold }
        }

        return .clear
    }

    // MARK: - Time-of-day theme logic
    private var timeOfDay: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 5 && hour < 8 { return .dawn }
        if hour >= 8 && hour < 17 { return .day }
        if hour >= 17 && hour < 20 { return .sunset }
        return .night
    }

    // Header colors must adapt for night
    private var headerPrimary: Color {
        timeOfDay == .night ? Color.white : Color.black
    }
    private var headerSecondary: Color {
        (timeOfDay == .night ? Color.white : Color.black).opacity(0.7)
    }
    private var pillText: Color {
        (timeOfDay == .night ? Color.white : Color.black).opacity(0.8)
    }
    private var pillIcon: Color {
        (timeOfDay == .night ? Color.white : Color.black).opacity(0.75)
    }
    private var pillBackgroundOpacity: Double {
        timeOfDay == .night ? 0.18 : 0.75
    }

//    private var windDisplay: String {
//        let base = viewModel.wind
//        let gust = (viewModel.windGust == "--" || viewModel.windGust.isEmpty) ? "" : "G\(viewModel.windGust)"
//        let dir  = viewModel.windDirection.isEmpty ? "" : "\(viewModel.windDirection) "
//        return dir + base + gust
//    }

    var body: some View {
        ZStack {
            ThemedSkyBackground(timeOfDay: timeOfDay, condition: conditionTheme)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {

                    // MARK: Header (no background)
                    VStack(spacing: 10) {
                        Text("Current Conditions")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(headerPrimary)

                        // Spinner + animated text change
                        UpdatedStatusRow(
                            text: isManualRefreshing ? "Refreshing…" : viewModel.lastUpdatedText,
                            isRefreshing: isManualRefreshing,
                            color: headerSecondary
                        )

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
                        HStack(spacing: 14) {
                            tile("thermometer", .red, viewModel.temp, "Temp")
                            tile("wind", .teal, viewModel.windDisplay, "Wind")
                            tile("gauge", .orange, viewModel.pressure, "Pressure")
                        }

                        HStack(spacing: 14) {
                            wideTile("drop", .blue, viewModel.humidity, "Humidity")
                            wideTile("cloud.rain", .blue, viewModel.precipitation, "Rain today")
                        }
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            // ✅ IMPORTANT: refreshable MUST be on ScrollView
            .refreshable {
  //                  print("PULL REFRESH fired", Date())
                isManualRefreshing = true
                defer { isManualRefreshing = false }

                if await viewModel.fetchWeather(force: true) {
                    successHaptic()
                }
            }
            // ✅ Also fine to keep .task on ScrollView
            .task {
                viewModel.loadCached()
                await viewModel.fetchWeather()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.fetchWeather() }
            }
        }
        .onReceive(clock) { date in
            now = date
        }
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.8), value: timeOfDay)
        .animation(.easeInOut(duration: 0.6), value: conditionTheme)
    }

    // MARK: - UI components

    private func pill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(pillIcon)

            Text(text)
                .foregroundStyle(pillText)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(pillBackgroundOpacity))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
    }

    private func tile(_ icon: String, _ color: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(color, Color.black)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.black)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(label)
                .font(.caption)
                .foregroundStyle(Color.black.opacity(0.6))
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 124)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
    }

    private func wideTile(_ icon: String, _ color: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(color, Color.black)

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.black.opacity(0.6))
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
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

// MARK: - Theme types

private enum ConditionTheme: Equatable { case clear, hot, cold, rain, storm, hazy, offline, snow }
private enum TimeOfDay: Equatable { case dawn, day, sunset, night }

// MARK: - Background

private struct ThemedSkyBackground: View {
    let timeOfDay: TimeOfDay
    let condition: ConditionTheme

    var body: some View {
        ZStack {
            LinearGradient(colors: baseSkyColors, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if condition != .storm && condition != .offline {
                if timeOfDay == .dawn || timeOfDay == .day || timeOfDay == .sunset {
                    sunGlow.opacity(timeOfDay == .day ? 0.75 : 0.55)
                }
            }

            switch condition {
            case .rain:
                rainHaze.opacity(0.55)
            case .storm:
                stormVignette.opacity(0.75)
            case .hazy, .offline:
                fogLayer.opacity(condition == .offline ? 0.25 : 0.18)
            case .snow:
                frostGlow.opacity(0.55)
            case .cold:
                frostGlow.opacity(0.35)
            case .hot:
                warmTint.opacity(0.25)
            case .clear:
                EmptyView()
            }
        }
    }

    private var baseSkyColors: [Color] {
        switch timeOfDay {
        case .dawn:
            return [Color(red: 0.55, green: 0.78, blue: 0.98),
                    Color(red: 0.98, green: 0.82, blue: 0.70),
                    Color(red: 0.96, green: 0.94, blue: 1.00)]
        case .day:
            return [Color(red: 0.52, green: 0.80, blue: 0.98),
                    Color(red: 0.76, green: 0.90, blue: 1.00),
                    Color.white]
        case .sunset:
            return [Color(red: 0.36, green: 0.70, blue: 0.98),
                    Color(red: 0.98, green: 0.72, blue: 0.55),
                    Color(red: 0.98, green: 0.90, blue: 0.80)]
        case .night:
            return [Color(red: 0.06, green: 0.12, blue: 0.24),
                    Color(red: 0.12, green: 0.22, blue: 0.38),
                    Color(red: 0.20, green: 0.30, blue: 0.45)]
        }
    }

    private var sunGlow: some View {
        RadialGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.20), Color.clear],
                       center: UnitPoint(x: 0.55, y: 0.12),
                       startRadius: 20,
                       endRadius: 360)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var rainHaze: some View {
        LinearGradient(colors: [Color.black.opacity(0.10), Color.clear, Color.black.opacity(0.06)],
                       startPoint: .top,
                       endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var stormVignette: some View {
        RadialGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.10), Color.clear],
                       center: .center,
                       startRadius: 80,
                       endRadius: 520)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var fogLayer: some View {
        Rectangle().fill(Color.white).ignoresSafeArea().allowsHitTesting(false)
    }

    private var frostGlow: some View {
        RadialGradient(colors: [Color.white.opacity(0.55), Color.clear],
                       center: UnitPoint(x: 0.35, y: 0.18),
                       startRadius: 20,
                       endRadius: 320)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var warmTint: some View {
        LinearGradient(colors: [Color(red: 1.00, green: 0.78, blue: 0.55).opacity(0.40), Color.clear],
                       startPoint: .top,
                       endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - Helpers

private func extractNumber(from text: String) -> Double {
    let cleaned = text.replacingOccurrences(of: ",", with: ".")
    let regex = try? NSRegularExpression(pattern: #"[-+]?\d*\.?\d+"#)
    let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
    if let match = regex?.firstMatch(in: cleaned, range: range),
       let r = Range(match.range, in: cleaned) {
        return Double(cleaned[r]) ?? 0
    }
    return 0
}

private func successHaptic() {
    let gen = UINotificationFeedbackGenerator()
    gen.prepare()
    gen.notificationOccurred(.success)
}



#Preview { NavigationStack { ContentView() } }
