import Foundation
import MapKit
import UIKit

final class RainViewerCachingTileOverlay: MKTileOverlay {

    /// Pixel size RainViewer serves in the URL path.
    enum PixelSize: Int { case s256 = 256, s512 = 512 }

    private let host: String
    private let framePath: String
    private let colorScheme: Int
    private let smooth: Int
    private let snow: Int

    /// Max zoom RainViewer supports.
    private let providerMaxZoom: Int

    private(set) var lastRequestedZoom: Int = 0

    // IMPORTANT: tell MapKit the overlay covers the world
    override var boundingMapRect: MKMapRect { .world }

    // In-memory tile cache
    private static let memCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 1500
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    // In-flight request dedupe
    private static var inFlight: [String: [((Data?, Error?) -> Void)]] = [:]
    private static let lock = NSLock()

    // Signal when at least one tile has been loaded (for fade timing)
    var didLoadFirstTile: (() -> Void)?
    private var firstTileSent = false

    private let session: URLSession

    init(
        host: String,
        framePath: String,
        colorScheme: Int = 2,
        smooth: Bool = true,
        snow: Bool = false,
        maxZoom: Int = 7
    ) {
        self.host = host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.smooth = smooth ? 1 : 0
        self.snow = snow ? 1 : 0
        self.providerMaxZoom = maxZoom

        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 10
        cfg.urlCache = .shared
        cfg.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: cfg)

        super.init(urlTemplate: nil)

        // Let MapKit request whatever zoom it wants; we’ll overzoom for z > providerMaxZoom.
        self.minimumZ = 0
        self.maximumZ = 19

        self.isGeometryFlipped = false
        self.canReplaceMapContent = false

        // KEY FIX: MKTileOverlay.tileSize is in *points*.
        // Keep it 256pt so MapKit uses a normal tile grid.
        self.tileSize = CGSize(width: 256, height: 256)
    }

    private func fireFirstTileIfNeeded() {
        guard !firstTileSent else { return }
        firstTileSent = true
        DispatchQueue.main.async { self.didLoadFirstTile?() }
    }

    // MARK: - MKTileOverlay

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // Debug: show what MapKit is requesting
        // print("🌧 loadTile z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor)")

        lastRequestedZoom = path.z

        // Decide pixel size to request (256 for 1x, 512 for 2x/3x)
        let pixelSize: PixelSize = (path.contentScaleFactor >= 2.0) ? .s512 : .s256

        // Cache key MUST include the REQUESTED z/x/y because MapKit is placing into that slot.
        let outKey = "\(framePath)|OUT|\(pixelSize.rawValue)|\(path.z)|\(path.x)|\(path.y)|\(colorScheme)|\(smooth)_\(snow)" as NSString

        // 1) Output cache (already cropped/scaled if needed)
        if let cached = Self.memCache.object(forKey: outKey) {
            fireFirstTileIfNeeded()
            result(cached as Data, nil)
            return
        }

        // 2) Dedupe in-flight on the OUTPUT key
        Self.lock.lock()
        if Self.inFlight[outKey as String] != nil {
            Self.inFlight[outKey as String]?.append(result)
            Self.lock.unlock()
            return
        } else {
            Self.inFlight[outKey as String] = [result]
            Self.lock.unlock()
        }

        // If MapKit asks for z <= providerMaxZoom, fetch directly and return.
        if path.z <= providerMaxZoom {
            fetchProviderTile(pixelSize: pixelSize, z: path.z, x: path.x, y: path.y) { data, error in
                if let data = data as NSData? {
                    Self.memCache.setObject(data, forKey: outKey, cost: data.length)
                }
                self.finish(key: outKey as String, data: data, error: error)
            }
            return
        }

        // Overzoom: fetch parent provider tile and crop sub-rect.
        let dz = path.z - providerMaxZoom
        let parts = 1 << dz

        let parentZ = providerMaxZoom
        let parentX = path.x >> dz
        let parentY = path.y >> dz

        let mask = parts - 1
        let subX = path.x & mask
        let subY = path.y & mask

        fetchProviderTile(pixelSize: pixelSize, z: parentZ, x: parentX, y: parentY) { data, error in
            guard let data, error == nil else {
                self.finish(key: outKey as String, data: nil, error: error)
                return
            }

            guard let outData = self.cropAndScaleOverzoom(
                parentTileData: data,
                parts: parts,
                subX: subX,
                subY: subY,
                outputPixels: pixelSize.rawValue
            ) else {
                self.finish(key: outKey as String, data: nil, error: URLError(.cannotDecodeContentData))
                return
            }

            let ns = outData as NSData
            Self.memCache.setObject(ns, forKey: outKey, cost: ns.length)
            self.finish(key: outKey as String, data: outData, error: nil)
        }
    }

    // MARK: - Provider fetch

    private func fetchProviderTile(pixelSize: PixelSize, z: Int, x: Int, y: Int, completion: @escaping (Data?, Error?) -> Void) {
        let key = "\(framePath)|PROV|\(pixelSize.rawValue)|\(z)|\(x)|\(y)|\(colorScheme)|\(smooth)_\(snow)" as NSString

        if let cached = Self.memCache.object(forKey: key) {
            completion(cached as Data, nil)
            return
        }

        Self.lock.lock()
        if Self.inFlight[key as String] != nil {
            Self.inFlight[key as String]?.append(completion)
            Self.lock.unlock()
            return
        } else {
            Self.inFlight[key as String] = [completion]
            Self.lock.unlock()
        }

        let urlString = "\(host)\(framePath)/\(pixelSize.rawValue)/\(z)/\(x)/\(y)/\(colorScheme)/\(smooth)_\(snow).png"
        // Debug: show the exact URL being fetched
//        print("🧱 tile url: \(urlString)")

        guard let url = URL(string: urlString) else {
            finish(key: key as String, data: nil, error: URLError(.badURL))
            return
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad

        let task = session.dataTask(with: req) { data, resp, error in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // print("❌ Tile HTTP \(http.statusCode) url=\(urlString)")
            }

            if let data = data as NSData? {
                Self.memCache.setObject(data, forKey: key, cost: data.length)
            }

            self.finish(key: key as String, data: data, error: error)
        }
        task.resume()
    }

    // MARK: - Overzoom crop+scale

    private func cropAndScaleOverzoom(
        parentTileData: Data,
        parts: Int,
        subX: Int,
        subY: Int,
        outputPixels: Int
    ) -> Data? {
        guard let img = UIImage(data: parentTileData),
              let cg = img.cgImage
        else { return nil }

        let cropSize = outputPixels / parts
        let cropX = subX * cropSize
        let cropY = subY * cropSize

        let rect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputPixels, height: outputPixels))
        let out = renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: outputPixels, height: outputPixels))
        }

        return out.pngData()
    }

    // MARK: - Finish / drain

    private func finish(key: String, data: Data?, error: Error?) {
        if data != nil { fireFirstTileIfNeeded() }

        Self.lock.lock()
        let callbacks = Self.inFlight.removeValue(forKey: key) ?? []
        Self.lock.unlock()

        for cb in callbacks { cb(data, error) }
    }
}
