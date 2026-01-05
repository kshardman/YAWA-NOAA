//
//  NOAAUnits.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/4/26.
//


import Foundation

// NOAA uses unitCode strings like "wmoUnit:degC", "wmoUnit:Pa", "wmoUnit:m_s-1", etc.
enum NOAAUnits {
    static func cToF(_ c: Double) -> Double { (c * 9/5) + 32 }

    static func paToInHg(_ pa: Double) -> Double { pa * 0.0002952998751 }

    static func mpsToMph(_ mps: Double) -> Double { mps * 2.2369362921 }
    static func kphToMph(_ kph: Double) -> Double { kph * 0.6213711922 }
    static func knotsToMph(_ kn: Double) -> Double { kn * 1.150779448 }

    static func speedToMph(value: Double, unitCode: String?) -> Double {
        let u = (unitCode ?? "").lowercased()

        // Common NOAA/WMO unit codes:
        // wmoUnit:m_s-1, wmoUnit:km_h-1, wmoUnit:kn, wmoUnit:mi_h-1
        if u.contains("km_h-1") { return kphToMph(value) }
        if u.contains("m_s-1")  { return mpsToMph(value) }
        if u.contains("kn")     { return knotsToMph(value) }
        if u.contains("mi_h-1") { return value } // already mph

        // Fallback: assume m/s (safe-ish default)
        return mpsToMph(value)
    }

    static func degreesToCompass(_ deg: Int) -> String {
        let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"]
        let i = Int((Double(deg) / 22.5).rounded()) % 16
        return dirs[i]
    }
}
