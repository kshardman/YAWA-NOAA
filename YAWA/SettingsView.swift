//
//  SettingsView.swift
//  iOSWeather
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
            List {
                Section {
                    Toggle("Weather alert notifications", isOn: $notifications.alertsNotificationsEnabled)

                    HStack {
                        Text("System permission")
                        Spacer()
                        Text(permissionLabel(notifications.authorizationStatus))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    if notifications.authorizationStatus == .denied {
                        Button("Open iOS Notification Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } footer: {
                    Text("Get notified when NOAA issues a new alert for the location you’re viewing. Alerts are sent once per unique alert ID.")
                }
                
                Section("Current Conditions Source") {
                    Picker("Source", selection: $sourceRaw) {
                        ForEach(CurrentConditionsSource.allCases) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                Text(s.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.inline)

                    // ✅ Only show PWS details when PWS is selected
                    if source == .pws {

                        LabeledContent("Station") {
                            Text(stationID)
                                .font(.body.weight(.semibold))
                                .monospaced()
                        }

                        LabeledContent("API Key") {
                            Text(showKey ? apiKey : masked(apiKey))
                                .font(.body.weight(.semibold))
                                .monospaced()
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
                            .disabled(apiKey == "—" || apiKey.isEmpty)
                        }
                    }
                }

                Section("Attribution") {
                    Text("Automatic current conditions use NOAA weather.gov nearby observations.")
                        .foregroundStyle(.secondary)
                    Text("Personal Weather Station mode uses Weather.com PWS API.")
                        .foregroundStyle(.secondary)
                    Text("Forecasts use NOAA weather.gov.")
                        .foregroundStyle(.secondary)
                }

#if DEBUG
Section("Debug") {
    Button("Clear alert notification history") {
        NotificationsManager.shared.clearAlertNotificationHistory()
    }
    .foregroundStyle(.red)
}
#endif
                
                
            }
            .task {
                await notifications.refreshAuthorizationStatus()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Load from config.plist in app bundle
                stationID = (try? configValue("stationID")) ?? "—"
                apiKey = (try? configValue("WU_API_KEY")) ?? "—"
            }
        }
    }

    private func permissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "On"
        case .provisional: return "Provisional"
        case .denied: return "Off"
        case .notDetermined: return "Not set"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
    
    
    // MARK: - Helpers

    private func masked(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "••••••••" }

        let suffix = String(trimmed.suffix(6))
        return "••••••••••\(suffix)"
    }

    private func configValue(_ key: String) throws -> String {
        // Matches the approach you already use in your service: config.plist in main bundle
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
