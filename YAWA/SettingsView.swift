//
//  SettingsView.swift
//  YAWA
//
//  Created by Keith Sharman on 1/4/26.
//

import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @AppStorage("pwsStationID") private var stationID: String = ""
    @AppStorage("pwsApiKey") private var apiKey: String = ""

    @AppStorage("weatherApiKey") private var weatherApiKey: String = ""

    // One-time defaults from bundled config.plist (optional)
    @State private var loadedDefaults = false
    @State private var showKey = false
    @State private var copied = false
    @State private var showWeatherApiKey = false
    @State private var copiedWeatherApiKey = false

    @Environment(\.dismiss) private var dismiss

    @AppStorage("currentConditionsSource")
    private var sourceRaw: String = CurrentConditionsSource.noaa.rawValue

    private var source: CurrentConditionsSource {
        get { CurrentConditionsSource(rawValue: sourceRaw) ?? .noaa }
        set { sourceRaw = newValue.rawValue }
    }

    @ObservedObject private var notifications = NotificationsManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                // ✅ Full-screen theme background
                YAWATheme.sky.ignoresSafeArea()

                List {
                    notificationsSection
                    sourceSection
                    attributionSection
                    aboutSection
                }
                // ✅ Let the sky show through
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listStyle(.insetGrouped)

                // ✅ Keep list looking “cardy” on dark backgrounds
                .environment(\.defaultMinListRowHeight, 48)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Nav bar glass + readable title (Radar style)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.headline.weight(.semibold))   // ⬆️ match Favorites/Radar size
                    .foregroundStyle(Color.white)        // ⬆️ match Favorites/Radar whiteness
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                }
            }
            .task {
                await notifications.refreshAuthorizationStatus()

                // Seed defaults from config.plist only if user hasn't entered anything yet
                if !loadedDefaults {
                    loadedDefaults = true

                    if stationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let v = try? configValue("stationID") {
                            stationID = v
                        }
                    }

                    if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let v = try? configValue("WU_API_KEY") {
                            apiKey = v
                        }
                    }

                    if weatherApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let v = try? configValue("WEATHERAPI_KEY") {
                            weatherApiKey = v
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Sections

private extension SettingsView {

    var notificationsSection: some View {
        Section {
            Toggle(isOn: $notifications.alertsNotificationsEnabled) {
                Text("Weather alert notifications")
                    .foregroundStyle(YAWATheme.textPrimary)
            }
            .tint(.green)

            HStack {
                Text("System permission")
                    .foregroundStyle(YAWATheme.textPrimary)

                Spacer()

                Text(permissionLabel(notifications.authorizationStatus))
                    .foregroundStyle(YAWATheme.textSecondary)
            }
            .font(.subheadline)

            if notifications.authorizationStatus == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open iOS Notification Settings", systemImage: "gearshape")
                }
                .foregroundStyle(YAWATheme.textPrimary)
            }
        } header: {
            Text("Alerts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
        } footer: {
            Text("Get notified when NOAA issues a new alert for the location you’re viewing. Alerts are sent once per unique alert ID.")
                .foregroundStyle(YAWATheme.textSecondary)
        }
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    var sourceSection: some View {
        Section {
            Picker("", selection: $sourceRaw) {
                ForEach(CurrentConditionsSource.allCases) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                            .foregroundStyle(YAWATheme.textPrimary)

                        Text(s.subtitle)
                            .font(.caption)
                            .foregroundStyle(YAWATheme.textSecondary)
                    }
                    .tag(s.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)

            // ✅ Only show PWS details when PWS is selected
            if source == .pws {
                LabeledContent("Station") {
                    TextField("Enter station ID", text: $stationID)
                        .font(.body.weight(.semibold))
                        .monospaced()
                        .foregroundStyle(YAWATheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.asciiCapable)
                        .textContentType(.none)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("API Key") {
                    Group {
                        if showKey {
                            TextField("Enter API key", text: $apiKey)
                        } else {
                            SecureField("Enter API key", text: $apiKey)
                        }
                    }
                    .font(.body.weight(.semibold))
                    .monospaced()
                    .foregroundStyle(YAWATheme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .textContentType(.none)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }

                HStack(spacing: 12) {
                    Button(showKey ? "Hide Key" : "Reveal Key") {
                        showKey.toggle()
                    }

                    Button(copied ? "Copied" : "Copy Key") {
                        UIPasteboard.general.string = apiKey
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copied = false
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .buttonStyle(.bordered)
                .tint(YAWATheme.accent)

                LabeledContent("WeatherAPI Key") {
                    Group {
                        if showWeatherApiKey {
                            TextField("Enter WeatherAPI key", text: $weatherApiKey)
                        } else {
                            SecureField("Enter WeatherAPI key", text: $weatherApiKey)
                        }
                    }
                    .font(.body.weight(.semibold))
                    .monospaced()
                    .foregroundStyle(YAWATheme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .textContentType(.none)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }

                HStack(spacing: 12) {
                    Button(showWeatherApiKey ? "Hide Key" : "Reveal Key") {
                        showWeatherApiKey.toggle()
                    }

                    Button(copiedWeatherApiKey ? "Copied" : "Copy Key") {
                        UIPasteboard.general.string = weatherApiKey
                        copiedWeatherApiKey = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copiedWeatherApiKey = false
                        }
                    }
                    .disabled(weatherApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .buttonStyle(.bordered)
                .tint(YAWATheme.accent)
            }
        } header: {
            Text("Current Conditions Source")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
        }
        .textCase(nil)
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    var attributionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Automatic current conditions use NOAA weather.gov nearby observations.")
                Text("Personal Weather Station mode uses Weather.com PWS API.")
                Text("Forecasts use NOAA weather.gov.")
            }
            .font(.subheadline)
            .foregroundStyle(YAWATheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Attribution")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
                .textCase(nil)
        }
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version (Build)")
                    .foregroundStyle(YAWATheme.textPrimary)

                Spacer()

                Text("\(appVersion) (\(buildNumber))")
                    .foregroundStyle(YAWATheme.textSecondary)
                    .monospacedDigit()
            }
        }
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - Helpers

private extension SettingsView {

    func permissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "On"
        case .provisional: return "Provisional"
        case .denied: return "Off"
        case .notDetermined: return "Not set"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }

    func masked(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : "••••••••••••"
    }

    func configValue(_ key: String) throws -> String {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "plist") else {
            throw ConfigError.missingConfigFile
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let dict = plist as? [String: Any] else {
            throw ConfigError.missingConfigFile
        }
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw ConfigError.missingKey(key)
        }
        return value
    }

    enum ConfigError: Error {
        case missingConfigFile
        case missingKey(String)
    }
}
