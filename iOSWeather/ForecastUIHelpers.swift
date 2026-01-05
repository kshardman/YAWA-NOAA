//
//  ForecastUIHelpers.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/5/26.
//
import Foundation
import SwiftUI

// MARK: - Forecast icon + color

func forecastSymbolAndColor(for shortForecast: String, isDaytime: Bool) -> (symbol: String, color: Color) {
    let s = shortForecast.lowercased()

    // Thunder / severe
    if s.contains("thunder") || s.contains("t-storm") || s.contains("storm") {
        return ("cloud.bolt.rain.fill", .purple)
    }

    // Snow / sleet / wintry
    if s.contains("snow") || s.contains("sleet") || s.contains("flurr") || s.contains("wintry") || s.contains("ice") {
        return ("cloud.snow.fill", .cyan)
    }

    // Fog / haze / smoke
    if s.contains("fog") || s.contains("haze") || s.contains("smoke") || s.contains("mist") {
        return ("cloud.fog.fill", .gray)
    }

    // Rain / showers / drizzle
    if s.contains("shower") || s.contains("rain") || s.contains("drizzle") {
        return ("cloud.rain.fill", .blue)
    }

    // Cloudy variants
    if s.contains("mostly cloudy") || s.contains("partly cloudy") || s.contains("partly sunny") || s.contains("mostly sunny") {
        if isDaytime {
            // show sun+cloud during day
            return ("cloud.sun.fill", .orange)
        } else {
            // moon+cloud at night
            return ("cloud.moon.fill", .gray)
        }
    }

    if s.contains("cloudy") || s.contains("overcast") {
        return ("cloud.fill", .gray)
    }

    // Clear / Sunny
    if s.contains("clear") || s.contains("sunny") {
        return (isDaytime ? "sun.max.fill" : "moon.stars.fill", isDaytime ? .yellow : .indigo)
    }

    // Fallback
    return ("questionmark.circle", .secondary)
}

// MARK: - Day name abbreviations

func abbreviatedDayName(_ name: String) -> String {
    // If NOAA gives "Monday", "Tuesday", etc, abbreviate when it ends in "day"
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

    // A simple explicit mapping is safest (handles capitalization)
    switch trimmed.lowercased() {
    case "monday": return "Mon"
    case "tuesday": return "Tue"
    case "wednesday": return "Wed"
    case "thursday": return "Thu"
    case "friday": return "Fri"
    case "saturday": return "Sat"
    case "sunday": return "Sun"
    default:
        // If it’s something like "Tonight", "New Year's Day", etc, leave it as-is
        return trimmed
    }
}

// MARK: - Probability of precipitation text (rounded to nearest 10%)

func popText(_ p: NWSForecastResponse.Period) -> String? {
    // You previously used p.probabilityOfPrecipitation?.value
    guard let v = p.probabilityOfPrecipitation?.value else { return nil }

    // Round to nearest 10
    let rounded10 = (v / 10.0).rounded() * 10.0
    let i = Int(rounded10)

    // Optionally suppress tiny PoP like 0%
    if i <= 0 { return nil }

    return "\(i)%"
}
