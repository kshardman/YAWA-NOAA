import SwiftUI

struct OverlayConfig {
    let host: String
    let framePath: String
    let opacity: Double

    var frameKey: String {
        "\(host)|\(framePath)"
    }
}

import MapKit

struct RadarMapView: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let radiusMeters: CLLocationDistance
    let overlay: OverlayConfig

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false

        context.coordinator.installInitialOverlay(on: map, overlay: overlay)
        context.coordinator.recenterIfNeeded(map, center: center, radius: radiusMeters)

        // Add crosshair
        let pin = MKPointAnnotation()
        pin.coordinate = center
        map.addAnnotation(pin)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.recenterIfNeeded(map, center: center, radius: radiusMeters)
        context.coordinator.replaceOverlay(on: map, overlay: overlay)

        // Update pin
        map.removeAnnotations(map.annotations)
        let pin = MKPointAnnotation()
        pin.coordinate = center
        map.addAnnotation(pin)
    }
}


final class Coordinator: NSObject, MKMapViewDelegate {

    var currentFrameKey: String?
    var currentOverlayConfig: OverlayConfig?

    private var activeOverlay: MKTileOverlay?

    private var overlayAlpha: [ObjectIdentifier: CGFloat] = [:]
    private var overlayRenderer: [ObjectIdentifier: MKTileOverlayRenderer] = [:]

    private var lastCentered: CLLocationCoordinate2D?

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
        let id = "crosshair"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.image = UIImage(systemName: "scope")
        view.tintColor = .systemRed
        return view
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
            UIView.performWithoutAnimation {
                map.removeOverlay(activeOverlay)
            }
        }

        overlayAlpha.removeAll()
        overlayRenderer.removeAll()
        activeOverlay = nil

        installInitialOverlay(on: map, overlay: overlay)
    }

    private func makeTileOverlay(from overlay: OverlayConfig) -> MKTileOverlay {
        RainViewerCachingTileOverlay(
            host: overlay.host,
            framePath: overlay.framePath,
            colorScheme: 2,
            smooth: true,
            snow: false,
            maxZoom: 12
        )
    }
}



