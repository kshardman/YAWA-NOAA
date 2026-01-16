//
//  RainViewerCachingTileOverlay 2.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


//
//  RainViewerCachingTileOverlay.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//

import Foundation
import MapKit

final class RainViewerCachingTileOverlay: MKTileOverlay {
    enum TileSize: Int { case s256 = 256, s512 = 512 }

    private let host: String
    private let framePath: String
    private let colorScheme: Int
    private let smooth: Int
    private let snow: Int
    private let size: TileSize
    private let maxZoom: Int

    // Track last requested zoom (useful for diagnostics)
    private(set) var lastRequestedZoom: Int = 0

    // In-memory tile cache – bumped limits for better hit rate during animation loops
    private static let memCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 1500                // ↑ Slightly higher
        c.totalCostLimit = 100 * 1024 * 1024 // ~100MB, safe on modern devices
        return c
    }()

    // In-flight request dedupe
    private static var inFlight: [String: [((Data?, Error?) -> Void)]] = [:]
    private static let lock = NSLock()

    // Signal when at least one tile has been loaded (for fade timing)
    var didLoadFirstTile: (() -> Void)?
    private var firstTileSent = false

    private let session: URLSession

    init(host: String,
         framePath: String,
         colorScheme: Int = 2,
         smooth: Bool = true,
         snow: Bool = false,
         size: TileSize = .s512,          // ← Default changed to 512
         maxZoom: Int = 7) {

        self.host = host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.smooth = smooth ? 1 : 0
        self.snow = snow ? 1 : 0
        self.size = size
        self.maxZoom = maxZoom

        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 10
        cfg.urlCache = .shared
        // Optional: allow more parallel connections for tile bursts
        cfg.httpMaximumConnectionsPerHost = 6

        self.session = URLSession(configuration: cfg)

        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: size.rawValue, height: size.rawValue)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        lastRequestedZoom = path.z

        // Clamp zoom and scale x/y
        var z = path.z
        var x = path.x
        var y = path.y

        if z > maxZoom {
            let dz = z - maxZoom
            z = maxZoom
            x = x >> dz
            y = y >> dz
        }

        let key = "\(framePath)|\(size.rawValue)|\(z)|\(x)|\(y)|\(colorScheme)|\(smooth)_\(snow)" as NSString

        // 1) Memory cache
        if let cached = Self.memCache.object(forKey: key) {
            if !firstTileSent {
                firstTileSent = true
                didLoadFirstTile?()
            }
            result(cached as Data, nil)
            return
        }

        // 2) Dedupe in-flight
        Self.lock.lock()
        if Self.inFlight[key as String] != nil {
            Self.inFlight[key as String]?.append(result)
            Self.lock.unlock()
            return
        } else {
            Self.inFlight[key as String] = [result]
            Self.lock.unlock()
        }

        // 3) Fetch
        let urlString = "\(host)\(framePath)/\(size.rawValue)/\(z)/\(x)/\(y)/\(colorScheme)/\(smooth)_\(snow).png"
        guard let url = URL(string: urlString) else {
            finish(key: key as String, data: nil, error: URLError(.badURL))
            return
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad

        let task = session.dataTask(with: req) { data, _, error in
            if let data = data as NSData? {
                // Cost = bytes
                Self.memCache.setObject(data, forKey: key, cost: data.length)
            }
            self.finish(key: key as String, data: data, error: error)
        }
        task.resume()
    }

    private func finish(key: String, data: Data?, error: Error?) {
        // Notify “first tile” once
        if data != nil, !firstTileSent {
            firstTileSent = true
            DispatchQueue.main.async { self.didLoadFirstTile?() }
        }
        if let error = error {
            print("Tile fetch failed for \(key): \(error.localizedDescription)")
        }
        // Drain callbacks
        Self.lock.lock()
        let callbacks = Self.inFlight.removeValue(forKey: key) ?? []
        Self.lock.unlock()

        for cb in callbacks {
            cb(data, error)
        }
    }
}
