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
    
    private(set) var lastRequestedZoom: Int = 0
    

    init(host: String,
         framePath: String,
         colorScheme: Int = 2,
         smooth: Bool = true,
         snow: Bool = false,
         size: TileSize = .s256,
         maxZoom: Int = 7) {

        self.host = host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.smooth = smooth ? 1 : 0
        self.snow = snow ? 1 : 0

        let clampedMaxZoom = min(maxZoom, 7)
        self.size = size
        self.maxZoom = clampedMaxZoom

        super.init(urlTemplate: nil)

        self.minimumZ = 0
        self.maximumZ = clampedMaxZoom
        self.isGeometryFlipped = false

        canReplaceMapContent = false
        tileSize = CGSize(width: size.rawValue, height: size.rawValue)
    }
    
    
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // If MapKit asks for tiles beyond provider max zoom, map to max zoom tiles correctly.
        // IMPORTANT: You must also scale x/y down when reducing z.
        
        lastRequestedZoom = path.z
        
        var z = path.z
        var x = path.x
        var y = path.y

        if z > maxZoom {
            let dz = z - maxZoom
            z = maxZoom
            x = x >> dz
            y = y >> dz
        }

        let urlString =
        "\(host)\(framePath)/\(size.rawValue)/\(z)/\(x)/\(y)/\(colorScheme)/\(smooth)_\(snow).png"

 // MARK: debug
        if path.z > maxZoom {
            print("Radar over-zoom: requested z=\(path.z) clamped to \(maxZoom)")
        }
        
        return URL(string: urlString)!
    }
}
