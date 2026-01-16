//
//  RainViewerTileOverlay.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


import Foundation
import MapKit

/// MKTileOverlay that builds RainViewer tile URLs from host + frame path.
///
/// RainViewer tile format:
/// {host}{path}/{size}/{z}/{x}/{y}/{color}/{smooth}_{snow}.png  [oai_citation:4‡Rain Viewer](https://www.rainviewer.com/api/weather-maps-api.html)
///
/// Note: RainViewer limits max zoom for free users (currently zoom 10).  [oai_citation:5‡Rain Viewer](https://www.rainviewer.com/api/weather-maps-api.html)
final class RainViewerTileOverlay: MKTileOverlay {
    enum TileSize: Int { case s256 = 256, s512 = 512 }

    private let host: String
    private let framePath: String
    private let colorScheme: Int
    private let smooth: Int
    private let snow: Int
    private let size: TileSize
    private let maxZoom: Int

    init(host: String,
         framePath: String,
         colorScheme: Int = 2,
         smooth: Bool = true,
         snow: Bool = false,
         size: TileSize = .s512,
         maxZoom: Int = 10) {

        self.host = host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.smooth = smooth ? 1 : 0
        self.snow = snow ? 1 : 0
        self.size = size
        self.maxZoom = maxZoom

        // urlTemplate exists, but we override url(forTilePath:) for full control.
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: size.rawValue, height: size.rawValue)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let z = min(path.z, maxZoom)

        // RainViewer expects normal XYZ: z/x/y
        let urlString =
        "\(host)\(framePath)/\(size.rawValue)/\(z)/\(path.x)/\(path.y)/\(colorScheme)/\(smooth)_\(snow).png"

        return URL(string: urlString)!
    }
}