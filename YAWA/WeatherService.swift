////
////  WeatherService.swift
////  iOSWeather
////
////  Created by Keith Sharman on 12/15/25.
////
//
//
import Foundation

    private func compassDirection(from degrees: Int) -> String {
        let directions = [
            "N", "NNE", "NE", "ENE",
            "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW",
            "W", "WNW", "NW", "NNW"
        ]
        let index = Int((Double(degrees) / 22.5).rounded()) % 16
        return directions[index]
    }
//}
