//
//  Config.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/4/26.
//


import Foundation

func configValue(_ key: String) throws -> String {
    guard
        let url = Bundle.main.url(forResource: "config", withExtension: "plist"),
        let data = try? Data(contentsOf: url),
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
        let value = dict[key] as? String
    else {
        throw NSError(domain: "Config", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(key)"])
    }

    return value
}