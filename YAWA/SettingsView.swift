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

private enum LaunchLocationMode: String, CaseIterable, Identifiable {
    case currentLocation
    case selectedFavorite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentLocation: return "Current Location"
        case .selectedFavorite: return "Selected Favorite"
        }
    }
}

struct SettingsView: View {
  

    

    @AppStorage("homeEnabled") private var homeEnabled: Bool = false
    @AppStorage("homeLat") private var homeLat: Double = 0
    @AppStorage("homeLon") private var homeLon: Double = 0

    @AppStorage("launchLocationMode") private var launchLocationModeRaw: String = LaunchLocationMode.currentLocation.rawValue

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
                    launchSection
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
            }
        }
    }
}


// MARK: - Sections

private extension SettingsView {
    var launchSection: some View {
        Section {
            Picker("On Launch", selection: $launchLocationModeRaw) {
                ForEach(LaunchLocationMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Text("Choose whether YAWA opens to your current GPS location or the currently selected favorite.")
                .font(.caption)
                .foregroundStyle(YAWATheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        } header: {
            Text("On Launch")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
        }
        .textCase(nil)
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }


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
                Text("YAWA uses your location to show nearby conditions, forecasts, and radar. Your API keys and station ID are stored on-device. Data is fetched from NOAA/weather.gov")
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

