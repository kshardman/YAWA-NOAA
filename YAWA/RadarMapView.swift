import SwiftUI
import MapKit
import CoreLocation

/// Simple value object describing the RainViewer overlay we want to show.
struct OverlayConfig: Equatable {
    let host: String
    let framePath: String
    let opacity: Double

    var frameKey: String { "\(host)|\(framePath)" }
}

/// A MapKit-backed radar map that renders RainViewer tiles.
struct RadarMapView: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let radiusMeters: CLLocationDistance
    let overlay: OverlayConfig

    /// Clamp user zoom so MapKit can’t zoom beyond RainViewer’s max tile zoom (default 11).
    /// (If you change RainViewerCachingTileOverlay(maxZoom:), keep this in sync.)
    let maxAllowedZoom: Int

    /// Show a small crosshair at the center.
    var showCrosshair: Bool = true

    init(
        center: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        overlay: OverlayConfig,
        maxAllowedZoom: Int = 10,
        showCrosshair: Bool = true
    ) {
        self.center = center
        self.radiusMeters = radiusMeters
        self.overlay = overlay
        self.maxAllowedZoom = maxAllowedZoom
        self.showCrosshair = showCrosshair
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(maxAllowedZoom: maxAllowedZoom)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator

        map.mapType = .standard
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.isPitchEnabled = false

        context.coordinator.recenterIfNeeded(map, center: center, radius: radiusMeters)
        context.coordinator.installInitialOverlay(on: map, overlay: overlay)

        if showCrosshair {
            context.coordinator.ensureCrosshair(on: map, at: center)
        }

        // ✅ Scale bar
        let scaleView = MKScaleView(mapView: map)
        scaleView.scaleVisibility = .visible
        scaleView.legendAlignment = .trailing
        scaleView.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(scaleView)

        NSLayoutConstraint.activate([
            scaleView.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            scaleView.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if showCrosshair {
            context.coordinator.ensureCrosshair(on: map, at: center)
        } else {
            context.coordinator.removeCrosshair(from: map)
        }

        context.coordinator.recenterIfNeeded(map, center: center, radius: radiusMeters)
        context.coordinator.replaceOverlay(on: map, overlay: overlay)

        // If the map size changed (rotation / split view), allow the camera zoom range to be recomputed.
        context.coordinator.didSetCameraZoomRange = false
        context.coordinator.clampZoomIfNeeded(map)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let maxAllowedZoom: Int

        var currentFrameKey: String?
        var currentOverlayConfig: OverlayConfig?

        private var activeOverlay: MKTileOverlay?

        private var overlayAlpha: [ObjectIdentifier: CGFloat] = [:]
        private var overlayRenderer: [ObjectIdentifier: MKTileOverlayRenderer] = [:]

        private var lastCentered: CLLocationCoordinate2D?

        private let crosshairID = "crosshair"
        private var isClampingZoom = false
        private var lastLoggedZoom: Int?
        private var lastLoggedSpan: CLLocationDegrees?
        var didSetCameraZoomRange = false

        init(maxAllowedZoom: Int) {
            self.maxAllowedZoom = maxAllowedZoom
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                let key = ObjectIdentifier(tile)
                renderer.alpha = overlayAlpha[key] ?? 1.0
                overlayRenderer[key] = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: crosshairID)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: crosshairID)

            view.annotation = annotation
            view.canShowCallout = false
            view.image = UIImage(systemName: "scope")
            view.tintColor = .systemRed
            return view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            clampZoomIfNeeded(mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            clampZoomIfNeeded(mapView)
        }

        // MARK: - Camera

        func recenterIfNeeded(_ map: MKMapView, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
            if let last = lastCentered,
               abs(last.latitude - center.latitude) < 0.0005,
               abs(last.longitude - center.longitude) < 0.0005 {
                return
            }
            lastCentered = center

            let region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: radius,
                longitudinalMeters: radius
            )
            map.setRegion(region, animated: false)
        }

        // MARK: - Zoom clamp

        func clampZoomIfNeeded(_ map: MKMapView) {
            // If the map hasn't been laid out yet, don't try to clamp.
            guard map.bounds.size.width > 0, map.bounds.size.height > 0 else { return }
            guard !isClampingZoom else { return }

            // Compute the minimum span that corresponds to the maximum allowed zoom.
            // If the map becomes MORE zoomed-in than this (smaller lonDelta), clamp it.
            let targetLonDelta = lonDelta(forZoom: maxAllowedZoom, mapWidthPoints: map.bounds.size.width)

            // One-time: also clamp gestures via cameraZoomRange so users can't zoom past tiles.
            if !didSetCameraZoomRange {
                let lat = map.region.center.latitude
                let metersPerDegreeLon = cos(lat * .pi / 180) * 111_320.0
                let visibleLonMeters = targetLonDelta * metersPerDegreeLon
                let minCenterDistance = max(250, visibleLonMeters / 2.0)

                let range = MKMapView.CameraZoomRange(
                    minCenterCoordinateDistance: minCenterDistance,
                    maxCenterCoordinateDistance: 10_000_000
                )
                map.setCameraZoomRange(range, animated: false)
                didSetCameraZoomRange = true
            }

            // Debug: log zoom changes so we can see when tiles vanish.
            let zoom = currentZoomLevel(for: map)
            let span = map.region.span.longitudeDelta
            if lastLoggedZoom != zoom || lastLoggedSpan == nil || abs((lastLoggedSpan ?? span) - span) > 0.000001 {
                lastLoggedZoom = zoom
                lastLoggedSpan = span
            }

            // Only clamp when the map is more zoomed-in than the allowed span.
            guard map.region.span.longitudeDelta < targetLonDelta else { return }

            isClampingZoom = true
            defer { isClampingZoom = false }

            var region = map.region
            region.span.longitudeDelta = targetLonDelta

            // Keep aspect ratio consistent with the view so the clamp feels natural.
            let aspect = max(map.bounds.size.height, 1) / max(map.bounds.size.width, 1)
            region.span.latitudeDelta = targetLonDelta * aspect

            map.setRegion(region, animated: false)
        }

        private func currentZoomLevel(for map: MKMapView) -> Int {
            let lonDelta = max(map.region.span.longitudeDelta, 0.0000001)
            let width = max(map.bounds.size.width, 1)

            let zoom = log2(360.0 * Double(width) / 256.0 / lonDelta)
            return Int(floor(zoom))
        }

        private func lonDelta(forZoom zoom: Int, mapWidthPoints: CGFloat) -> CLLocationDegrees {
            let width = max(Double(mapWidthPoints), 1)
            return 360.0 * (width / 256.0) / pow(2.0, Double(zoom))
        }

        // MARK: - Crosshair

        func ensureCrosshair(on map: MKMapView, at coordinate: CLLocationCoordinate2D) {
            if let existing = map.annotations
                .first(where: { ($0 as? MKPointAnnotation)?.title == crosshairID }) as? MKPointAnnotation {
                existing.coordinate = coordinate
                return
            }

            let ann = MKPointAnnotation()
            ann.title = crosshairID
            ann.coordinate = coordinate
            map.addAnnotation(ann)
        }

        func removeCrosshair(from map: MKMapView) {
            let toRemove = map.annotations.filter { ($0 as? MKPointAnnotation)?.title == crosshairID }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
        }

        // MARK: - Opacity

        func updateOpacity(on map: MKMapView, opacity: Double) {
            currentOverlayConfig = OverlayConfig(
                host: currentOverlayConfig?.host ?? "",
                framePath: currentOverlayConfig?.framePath ?? "",
                opacity: opacity
            )

            guard let activeOverlay,
                  let renderer = overlayRenderer[ObjectIdentifier(activeOverlay)]
            else { return }

            let a = CGFloat(opacity)
            overlayAlpha[ObjectIdentifier(activeOverlay)] = a
            renderer.alpha = a
            renderer.setNeedsDisplay()
        }

        // MARK: - Overlay lifecycle

        func installInitialOverlay(on map: MKMapView, overlay: OverlayConfig) {
            if currentFrameKey == overlay.frameKey {
                updateOpacity(on: map, opacity: overlay.opacity)
                return
            }

            let tile = makeTileOverlay(from: overlay)
            activeOverlay = tile
            currentOverlayConfig = overlay
            currentFrameKey = overlay.frameKey

            overlayAlpha[ObjectIdentifier(tile)] = CGFloat(overlay.opacity)

            UIView.performWithoutAnimation {
                map.addOverlay(tile, level: .aboveLabels)
            }
        }

        func replaceOverlay(on map: MKMapView, overlay: OverlayConfig) {
            if currentFrameKey == overlay.frameKey {
                updateOpacity(on: map, opacity: overlay.opacity)
                return
            }

            if let activeOverlay {
                UIView.performWithoutAnimation { map.removeOverlay(activeOverlay) }
            }

            overlayAlpha.removeAll()
            overlayRenderer.removeAll()
            activeOverlay = nil

            installInitialOverlay(on: map, overlay: overlay)
        }

        // MARK: - Overlay factory

        private func makeTileOverlay(from overlay: OverlayConfig) -> MKTileOverlay {
            RainViewerCachingTileOverlay(
                host: overlay.host,
                framePath: overlay.framePath,
                colorScheme: 2,
                smooth: true,
                snow: false,
                maxZoom: maxAllowedZoom
            )
        }
    }
}
