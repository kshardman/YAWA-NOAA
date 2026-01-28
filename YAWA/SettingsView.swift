//
//  SettingsView.swift
//  YAWA
//
//  Created by Keith Sharman on 1/4/26.
//

import SwiftUI
import UIKit
import UserNotifications
import CoreLocation

struct SettingsView: View {
    @AppStorage("pwsStationID") private var stationID: String = ""
    @AppStorage("pwsApiKey") private var apiKey: String = ""

    @AppStorage("weatherApiKey") private var weatherApiKey: String = ""

    @AppStorage("homeEnabled") private var homeEnabled: Bool = false
    @AppStorage("homeLat") private var homeLat: Double = 0
    @AppStorage("homeLon") private var homeLon: Double = 0

    // One-time defaults from bundled config.plist (optional)
    @State private var loadedDefaults = false
    @State private var showKey = false
    @State private var copied = false
    @State private var showWeatherApiKey = false
    @State private var copiedWeatherApiKey = false

    @State private var showingApiKeys = false

    // Draft editing (so the API Keys sheet can Cancel/Back without saving)
    @State private var draftStationID: String = ""
    @State private var draftApiKey: String = ""
    @State private var draftWeatherApiKey: String = ""

    @State private var draftShowPwsKey = false
    @State private var draftCopiedPwsKey = false

    @State private var draftShowWeatherApiKey = false
    @State private var draftCopiedWeatherApiKey = false

    @Environment(\.dismiss) private var dismiss

    @AppStorage("currentConditionsSource")
    private var sourceRaw: String = CurrentConditionsSource.noaa.rawValue

    private var source: CurrentConditionsSource {
        get { CurrentConditionsSource(rawValue: sourceRaw) ?? .noaa }
        set { sourceRaw = newValue.rawValue }
    }

    @ObservedObject private var notifications = NotificationsManager.shared
    @EnvironmentObject private var locationManager: LocationManager

    var body: some View {
        NavigationStack {
            ZStack {
                // ✅ Full-screen theme background
                YAWATheme.sky.ignoresSafeArea()

                List {
                    notificationsSection
                    sourceSection
                    homeSection
                    privacySection
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
                // Keep drafts in sync with persisted values (used by API Keys sheet)
                draftStationID = stationID
                draftApiKey = apiKey
                draftWeatherApiKey = weatherApiKey
            }
            .sheet(isPresented: $showingApiKeys) {
                apiKeysSheet
            }
        }
    }
}


// MARK: - Sections

private extension SettingsView {
    var homeSection: some View {
        let radiusMeters: Double = 100
        let hasFix = locationManager.coordinate != nil
        let isSet = homeEnabled && !(homeLat == 0 && homeLon == 0)

        return Section {
            Button {
                guard let c = locationManager.coordinate else { return }
                homeLat = c.latitude
                homeLon = c.longitude
                homeEnabled = true
                UserDefaults.standard.synchronize()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .yawaHomeSettingsDidChange, object: nil)
                }
            } label: {
                HStack {
                    Label("Set Home to Current Location", systemImage: "house.fill")
                        .foregroundStyle(YAWATheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YAWATheme.textSecondary.opacity(0.9))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasFix)
            .opacity(hasFix ? 1.0 : 0.55)

            if isSet {
                HStack {
                    Text("Home is set")
                        .foregroundStyle(YAWATheme.textPrimary)
                    Spacer()
                    Text("\(Int(radiusMeters)) m")
                        .foregroundStyle(YAWATheme.textSecondary)
                        .monospacedDigit()
                }
                .font(.subheadline)

                Button(role: .destructive) {
                    homeEnabled = false
                    homeLat = 0
                    homeLon = 0
                    UserDefaults.standard.synchronize()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .yawaHomeSettingsDidChange, object: nil)
                    }
                } label: {
                    Label("Clear Home", systemImage: "trash")
                }
            } else {
                HStack {
                    Text("Home is not set")
                        .foregroundStyle(YAWATheme.textSecondary)
                    Spacer()
                    Text(hasFix ? "Ready" : "Waiting for GPS")
                        .foregroundStyle(YAWATheme.textSecondary)
                }
                .font(.subheadline)
            }
        } header: {
            Text("Home")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
        } footer: {
            Text("When you’re within 100 meters of Home, YAWA can treat your current GPS location as \"Home\".")
                .foregroundStyle(YAWATheme.textSecondary)
        }
        .textCase(nil)
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }
    var privacySection: some View {
        Section(header: Text("Privacy").font(.subheadline.weight(.semibold)).foregroundStyle(YAWATheme.textPrimary)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("YAWA uses your location to show nearby conditions, forecasts, and radar. Your API keys and station ID are stored on-device. Data is fetched from NOAA/weather.gov and, when enabled, Weather.com PWS and WeatherAPI.com.")
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "https://kshardman.github.io/YAWA-NOAA")!) {
                    HStack {
                        Text("Privacy Policy")
                            .foregroundStyle(YAWATheme.textPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(YAWATheme.textSecondary.opacity(0.9))
                    }
                    .contentShape(Rectangle())
                }
            }
            .padding(.vertical, 2)
        }
        .textCase(nil)
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    var attributionSection: some View {
        Section(header: Text("Attribution").font(.subheadline.weight(.semibold)).foregroundStyle(YAWATheme.textPrimary)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Radar images and tiles are from rainviewer.com. NOAA forecasts are from weather.gov.  International locations use forecast data from weatherAPI.com")
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .textCase(nil)
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

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
            // ✅ Simple mode picker (NOAA vs PWS)
            Picker("Current Conditions Source", selection: $sourceRaw) {
                Text("NOAA+").tag(CurrentConditionsSource.noaa.rawValue)
                Text("PWS").tag(CurrentConditionsSource.pws.rawValue)
            }
            .pickerStyle(.segmented)

            // Helpful subtitle / explanation
            VStack(alignment: .leading, spacing: 6) {
                Text(source == .noaa
                     ? "NOAA+ uses NOAA (weather.gov) for U.S. conditions and forecasts.  For international conditions and forecasts, weatherapi.com is used."
                     : "PWS mode uses your weather.com stationID and API key to obtain current conditions.  For forecasts at your stationID, weatherAPI.com API key is used.")
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textSecondary)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

            // ✅ Tappable row to edit keys in a dedicated sheet
            Button {
                // Seed drafts each time we open
                draftStationID = stationID
                draftApiKey = apiKey
                draftWeatherApiKey = weatherApiKey

                draftShowPwsKey = false
                draftCopiedPwsKey = false
                draftShowWeatherApiKey = false
                draftCopiedWeatherApiKey = false

                showingApiKeys = true
            } label: {
                HStack {
                    Text("API Keys")
                        .foregroundStyle(YAWATheme.textPrimary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YAWATheme.textSecondary.opacity(0.9))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Current Conditions Source")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
        }
        .textCase(nil)
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

    var apiKeysSheet: some View {
        NavigationStack {
            ZStack {
                YAWATheme.sky.ignoresSafeArea()

                List {
                    Section {
                        LabeledContent("Station") {
                            TextField("Enter station ID", text: $draftStationID)
                                .font(.body.weight(.semibold))
                                .monospaced()
                                .foregroundStyle(YAWATheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.asciiCapable)
                                .textContentType(.none)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("PWS API Key") {
                            Group {
                                if draftShowPwsKey {
                                    TextField("Enter PWS API key", text: $draftApiKey)
                                } else {
                                    SecureField("Enter PWS API key", text: $draftApiKey)
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
                            Button(draftShowPwsKey ? "Hide" : "Reveal") {
                                draftShowPwsKey.toggle()
                            }

                            Button(draftCopiedPwsKey ? "Copied" : "Copy") {
                                UIPasteboard.general.string = draftApiKey
                                draftCopiedPwsKey = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    draftCopiedPwsKey = false
                                }
                            }
                            .disabled(draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .buttonStyle(.bordered)
                        .tint(YAWATheme.accent)

                        LabeledContent("WeatherAPI Key") {
                            Group {
                                if draftShowWeatherApiKey {
                                    TextField("Enter WeatherAPI key", text: $draftWeatherApiKey)
                                } else {
                                    SecureField("Enter WeatherAPI key", text: $draftWeatherApiKey)
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
                            Button(draftShowWeatherApiKey ? "Hide" : "Reveal") {
                                draftShowWeatherApiKey.toggle()
                            }

                            Button(draftCopiedWeatherApiKey ? "Copied" : "Copy") {
                                UIPasteboard.general.string = draftWeatherApiKey
                                draftCopiedWeatherApiKey = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    draftCopiedWeatherApiKey = false
                                }
                            }
                            .disabled(draftWeatherApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .buttonStyle(.bordered)
                        .tint(YAWATheme.accent)
                    } header: {
                        Text("API Keys")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(YAWATheme.textPrimary)
                    } footer: {
                        Text("These keys are stored on-device using AppStorage. You can set them anytime, even while using NOAA mode.")
                            .foregroundStyle(YAWATheme.textSecondary)
                    }
                    .listRowBackground(YAWATheme.card2)
                    .listRowSeparator(.hidden)
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listStyle(.insetGrouped)
            }
            .navigationTitle("API Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingApiKeys = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        stationID = draftStationID.trimmingCharacters(in: .whitespacesAndNewlines)
                        apiKey = draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        weatherApiKey = draftWeatherApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        showingApiKeys = false
                    }
                    .buttonStyle(.plain)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .disabled(!apiKeysDirty)
                    .opacity(apiKeysDirty ? 1.0 : 0.55)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var apiKeysDirty: Bool {
        draftStationID.trimmingCharacters(in: .whitespacesAndNewlines) != stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        || draftApiKey.trimmingCharacters(in: .whitespacesAndNewlines) != apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        || draftWeatherApiKey.trimmingCharacters(in: .whitespacesAndNewlines) != weatherApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

