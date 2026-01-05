//
//  SettingsView.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/4/26.
//


import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var stationID: String = "—"
    @State private var apiKey: String = "—"
    @State private var showKey = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Current Conditions Source") {
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

                Section("Attribution") {
                    Text("Current conditions use Weather.com PWS (Personal Weather Station) API.")
                        .foregroundStyle(.secondary)
                    Text("Forecasts use NOAA weather.gov.")
                        .foregroundStyle(.secondary)
                }
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