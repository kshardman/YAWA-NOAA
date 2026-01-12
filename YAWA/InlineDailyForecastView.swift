import SwiftUI

/// Inline 7-day list for the main screen.
/// Self-contained (nests helper types/functions to avoid name collisions with your ForecastView helpers).
struct InlineDailyForecastView: View {
    let periods: [NWSForecastResponse.Period]

    // Layout tuning (match your ForecastView look)
    var sideColumnWidth: CGFloat = 130

    // MARK: - Nested model
//    private struct DailyForecast: Identifiable {
//        let id: Int
//        let name: String
//        let startDate: Date
//        let day: NWSForecastResponse.Period
//        let night: NWSForecastResponse.Period?
//        var dateText: String {
//            let formatter = DateFormatter()
//            formatter.dateFormat = "M/d"
//            return formatter.string(from: startDate)
//        }
//        var highText: String { "\(day.temperature)°" }
//        var lowText: String {
//            if let night { return "\(night.temperature)°" }
//            return "—"
//        }
//    }

    // MARK: - Detail payload (optional sheet)
    private struct DetailPayload: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    @State private var selectedDetail: DetailPayload?

    private struct AlertRow: View {
        let alert: NWSAlertsResponse.Feature

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: symbolForSeverity(alert.properties.severity))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.alert)

                    Text(alert.properties.event)
                        .font(.headline)

                    Spacer()
                }

                if let headline = alert.properties.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let area = alert.properties.areaDesc, !area.isEmpty {
                    Text(area)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
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
        VStack(spacing: 0) {
            
            ForEach(combineDayNight(Array(periods.prefix(14)))) { d in
                let sym = forecastSymbolAndColor(for: d.day.shortForecast, isDaytime: true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {

                        // Left
                        HStack(spacing: 6) {
                            Text(abbreviatedDayName(d.name))
                                .font(.headline)
                            Text(d.dateText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: sideColumnWidth, alignment: .leading)

                        // Center (icon + PoP)
                        // Middle column (true center)
                        let pop = popText(d.day)

                        VStack(spacing: 2) {
                            Image(systemName: sym.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(sym.color)
                                .font(.title2)
                                .offset(y: iconYOffset(symbol: sym.symbol, hasPop: pop != nil))

                            // Always reserve PoP space
                            Text(pop ?? "00%")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(YAWATheme.textSecondary)
                                .opacity(pop == nil ? 0 : 1)
                                .frame(height: 14)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        // Right
                        Text("H \(d.highText)  L \(d.lowText)")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(width: sideColumnWidth, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let dayText = d.day.detailedForecast ?? d.day.shortForecast
                    let nightText = d.night?.detailedForecast

                    let body: String
                    if let nightText,
                       !nightText.isEmpty,
                       nightText != dayText {
                        body = "Day: \(dayText)\n\nNight: \(nightText)"
                    } else {
                        body = dayText
                    }

                    selectedDetail = DetailPayload(
                        title: "\(abbreviatedDayName(d.name)) \(d.dateText)",
                        body: body
                    )
                }
                .padding(.vertical, 4)

                Divider()
                    .opacity(0.35)
            }
        }
        .sheet(item: $selectedDetail) { detail in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(detail.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(detail.body)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineSpacing(6)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
                .navigationTitle(detail.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done for now") { selectedDetail = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Helpers (nested)

    private func combineDayNight(_ periods: [NWSForecastResponse.Period]) -> [DailyForecast] {
        var out: [DailyForecast] = []
        var i = 0

        while i < periods.count {
            let p = periods[i]
            if p.isDaytime {
                let next = (i + 1 < periods.count) ? periods[i + 1] : nil
                let night = (next?.isDaytime == false) ? next : nil

                let startDate = p.startTime
                out.append(.init(
                    id: p.number,
                    name: p.name,
                    startDate: startDate,
                    day: p,
                    night: night
                ))
                i += (night == nil ? 1 : 2)
            } else {
                i += 1
            }
        }
        return out
    }

    private func abbreviatedDayName(_ name: String) -> String {
        // If it ends with "day", abbreviate to 3 letters (Mon, Tue, Wed, etc)
        if name.lowercased().hasSuffix("day"), name.count >= 3 {
            return String(name.prefix(3))
        }
        return name
    }

    private func iconYOffset(symbol: String, hasPop: Bool) -> CGFloat {
        guard !hasPop else { return 0 }

        switch symbol {
        case "sun.max.fill", "sun.max":
            return 8
        case "cloud.sun.fill", "cloud.sun":
            return 6
        default:
            return 3
        }
    }

    
    private func popText(_ p: NWSForecastResponse.Period) -> String? {
        guard let pop = p.probabilityOfPrecipitation?.value else { return nil }

        let rounded = ((pop + 5) / 10) * 10
        return "\(rounded)%"
    }

    private func forecastSymbolAndColor(for short: String, isDaytime: Bool) -> (symbol: String, color: Color) {
        let s = short.lowercased()

        // Night-aware clears
        if s.contains("clear") {
            return (isDaytime ? "sun.max.fill" : "moon.stars.fill", isDaytime ? .yellow : .indigo)
        }

        if s.contains("partly") && s.contains("sunny") {
            return ("cloud.sun.fill", .yellow)
        }
        if s.contains("mostly") && s.contains("sunny") {
            return ("sun.max.fill", .yellow)
        }
        if s.contains("sunny") {
            return ("sun.max.fill", .yellow)
        }

        if s.contains("cloud") || s.contains("overcast") {
            return ("cloud.fill", .gray)
        }
        if s.contains("rain") || s.contains("showers") {
            return ("cloud.rain.fill", .blue)
        }
        if s.contains("storm") || s.contains("thunder") {
            return ("cloud.bolt.rain.fill", .purple)
        }
        if s.contains("snow") {
            return ("cloud.snow.fill", .cyan)
        }
        if s.contains("fog") || s.contains("haze") || s.contains("mist") {
            return ("cloud.fog.fill", .gray)
        }

        // fallback
        return ("cloud.sun.fill", .yellow)
    }
}
