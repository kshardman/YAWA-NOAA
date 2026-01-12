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
    @State private var stationID: String = "—"
    @State private var apiKey: String = "—"
    @State private var showKey = false
    @State private var copied = false

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

                    #if DEBUG
                    debugSection
                    #endif
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
            // Nav bar glass + readable title (Daily Forecast style)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(YAWATheme.card2, for: .navigationBar)   // ✅ tint like Daily Forecast
            .toolbarColorScheme(.dark, for: .navigationBar)
            
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    GlassyDoneButton {
                        dismiss()
                    }
                }
            }
            .task {
                await notifications.refreshAuthorizationStatus()

                // Load from config.plist in app bundle
                stationID = (try? configValue("stationID")) ?? "—"
                apiKey = (try? configValue("WU_API_KEY")) ?? "—"
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
                    .foregroundStyle(YAWATheme.textPrimary) // ← white
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
        }
        header: {
            Text("Alerts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)   // ← THIS is the fix
        }
        footer: {
            Text("Get notified when NOAA issues a new alert for the location you’re viewing. Alerts are sent once per unique alert ID.")
                .foregroundStyle(YAWATheme.textSecondary)
        }
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    var sourceSection: some View {
        Section {
            Picker(selection: $sourceRaw) {
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
            } label: {
                Text("Source")
                    .foregroundStyle(YAWATheme.textPrimary)   // ← this is the key
            }
            .pickerStyle(.inline)

            // ✅ Only show PWS details when PWS is selected
            if source == .pws {
                LabeledContent("Station") {
                    Text(stationID)
                        .font(.body.weight(.semibold))
                        .monospaced()
                        .foregroundStyle(YAWATheme.textPrimary)
                }

                LabeledContent("API Key") {
                    Text(showKey ? apiKey : masked(apiKey))
                        .font(.body.weight(.semibold))
                        .monospaced()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(YAWATheme.textPrimary)
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
                    .disabled(apiKey == "—" || apiKey.isEmpty)
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
                .textCase(nil) // prevent automatic ALL CAPS
        }
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }

    #if DEBUG
    var debugSection: some View {
        Section {
            Button("Clear alert notification history") {
                NotificationsManager.shared.clearAlertNotificationHistory()
            }
            .foregroundStyle(.red)
        } header: {
            Text("Debug")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary)
        }
        .textCase(nil)
        .listRowBackground(YAWATheme.card2)
        .listRowSeparator(.hidden)
    }
    #endif
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
        guard trimmed.count > 8 else { return "••••••••" }
        let suffix = String(trimmed.suffix(6))
        return "••••••••••\(suffix)"
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
