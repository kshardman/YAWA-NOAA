//
//  ForecastUIHelpers.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/5/26.
//
import Foundation
import SwiftUI

// MARK: - Forecast icon + color


func forecastSymbolAndColor(
    for shortForecast: String,
    detailedForecast: String? = nil,
    isDaytime: Bool
) -> (symbol: String, color: Color) {

    // Combine both — NOAA sometimes only says “snow” in detailedForecast
    let s = (shortForecast + " " + (detailedForecast ?? "")).lowercased()

    // Thunder / severe
    if s.contains("thunder") || s.contains("t-storm") || s.contains("tstorm") || s.contains("storm") {
        return ("cloud.bolt.rain.fill", .purple)
    }

    // Wintry / snow (do this BEFORE rain)
    let hasSnowyWords =
        s.contains("snow") ||
        s.contains("flurr") ||          // flurries
        s.contains("sleet") ||
        s.contains("wintry") ||
        s.contains("ice") ||
        s.contains("freezing") ||       // freezing rain / freezing drizzle
        s.contains("blizzard") ||
        s.contains("blowing snow")

    
//    if hasSnowyWords {
//        if s.contains("rain") && s.contains("snow") {
//            return ("cloud.sleet.fill", .cyan)
//        }
//        return ("snowflake", .cyan)
//    }
    
    if hasSnowyWords {
        // Mixed precip: rain + snow present
        if s.contains("rain") && s.contains("snow") {
            return ("cloud.sleet.fill", .cyan)
        }
        // Freezing rain is more “ice” than rain in user expectation
        if s.contains("freezing rain") || s.contains("freezing drizzle") {
            return ("cloud.hail.fill", .cyan) // or keep cloud.snow.fill if you prefer
        }
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
        return isDaytime ? ("cloud.sun.fill", .orange) : ("cloud.moon.fill", .gray)
    }

    if s.contains("cloudy") || s.contains("overcast") {
        return ("cloud.fill", .gray)
    }

    // Clear / Sunny
    if s.contains("clear") || s.contains("sunny") {
        return (isDaytime ? "sun.max.fill" : "moon.stars.fill", isDaytime ? .yellow : .indigo)
    }

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
    guard let v = p.probabilityOfPrecipitation?.value else { return nil }

    let rounded10 = ((v + 5) / 10) * 10

    if rounded10 <= 0 { return nil }

    return "\(rounded10)%"
}
