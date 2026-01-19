//
//  CurrentConditionsSource.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/4/26.
//


import Foundation

enum CurrentConditionsSource: String, CaseIterable, Identifiable {
    case noaa
    case pws

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noaa: return "NOAA (Nearby station)"
        case .pws:  return "Personal Weather Station"
        }
    }

    var subtitle: String {
        switch self {
        case .noaa: return "Uses your location + weather.gov observations"
        case .pws:  return "Uses your configured station + weatherAPI.com API key"
        }
    }
}
