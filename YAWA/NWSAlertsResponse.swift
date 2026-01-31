

//
//  NWSAlertsResponse.swift
//  YAWA
//
//  Created by Keith Sharman on 1/30/26.
//


struct NWSAlertsResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable, Identifiable {
        // NOAA uses a string id like the full URL
        let id: String

        // ✅ IMPORTANT: NOAA frequently returns geometry: null
        let geometry: Geometry?

        let properties: Properties
    }

    struct Geometry: Decodable {
        let type: String
        let coordinates: [[[Double]]]? // keep loose; often polygon/multipolygon
    }

    struct Properties: Decodable {
        let event: String
        let severity: String?
        let headline: String?
        let areaDesc: String?
        let descriptionText: String?
        let instructionText: String?

        // ✅ NWS timestamps (RFC3339 / ISO8601)
        let effective: String?
        let sent: String?

        enum CodingKeys: String, CodingKey {
            case event
            case severity
            case headline
            case areaDesc
            case descriptionText = "description"
            case instructionText = "instruction"
            case effective
            case sent
        }
    }
}
