//
//  NWSStationsResponse.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/4/26.
//


import Foundation

struct NWSStationsResponse: Decodable {
    struct Feature: Decodable {
        struct Properties: Decodable {
            let stationIdentifier: String
            let name: String?
        }
        let properties: Properties
    }
    let features: [Feature]
}

struct NWSLatestObservationResponse: Decodable {
    struct Properties: Decodable {

        struct Measurement: Decodable {
            let value: Double?
            let unitCode: String?
        }

        let timestamp: String?

        let temperature: Measurement?
        let relativeHumidity: Measurement?
        let windSpeed: Measurement?
        let windGust: Measurement?
        let windDirection: Measurement?
        let barometricPressure: Measurement?

        let textDescription: String?
    }

    let properties: Properties
}