//
//  ForecastHelpers.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/5/26.
//
import Foundation

// Shared model used by ForecastView AND ContentView (inline forecast)
struct DailyForecast: Identifiable {
    let id: Int
    let name: String
    let startDate: Date
    let day: NWSForecastResponse.Period
    let night: NWSForecastResponse.Period?

    // mm/dd
    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: startDate)
    }

    // These assume your combine logic is "day + optional night"
    var highText: String { "\(day.temperature)°" }

    var lowText: String {
        if let night {
            return "\(night.temperature)°"
        }
        // If NOAA didn't give the night period, fall back to day temp
        return "\(day.temperature)°\(day.temperatureUnit)"
    }
}

/// IMPORTANT: Top-level + NOT private so ContentView can call it.
func combineDayNight(_ periods: [NWSForecastResponse.Period]) -> [DailyForecast] {
    var out: [DailyForecast] = []
    var i = 0

    while i < periods.count {
        let p = periods[i]

        if p.isDaytime {
            let next = (i + 1 < periods.count) ? periods[i + 1] : nil
            let night = (next?.isDaytime == false) ? next : nil

            // You already have startTime as a Date in your model
            let startDate = p.startTime

            out.append(
                DailyForecast(
                    id: p.number,
                    name: p.name,
                    startDate: startDate,
                    day: p,
                    night: night
                )
            )

            i += (night == nil ? 1 : 2)
        } else {
            // If we start on a night period, skip it
            i += 1
        }
    }

    return out
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}



