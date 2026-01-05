//
//  NOAAUnits.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/4/26.
//


import Foundation

// NOAA uses unitCode strings like "wmoUnit:degC", "wmoUnit:Pa", "wmoUnit:m_s-1", etc.
enum NOAAUnits {

    static func cToF(_ c: Double) -> Double { (c * 9.0/5.0) + 32.0 }

    static func paToInHg(_ pa: Double) -> Double { pa * 0.000295299830714 } // Pa -> inHg

    static func mpsToMph(_ mps: Double) -> Double { mps * 2.2369362920544 }

    static func degreesToCompass(_ deg: Int) -> String {
        // 16-point compass
        let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"]
        let idx = Int((Double(deg) / 22.5).rounded()) % 16
        return dirs[idx]
    }
}