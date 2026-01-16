//
//  RadarMapView.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


import SwiftUI
import MapKit

struct RadarMapView: UIViewRepresentable {
    struct OverlayConfig: Equatable {
        let host: String
        let framePath: String
        let opacity: Double
    }

    let center: CLLocationCoordinate2D
    let initialRadiusMeters: CLLocationDistance
    let overlay: OverlayConfig

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator

        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.showsScale = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false

        // Set initial region
        let region = MKCoordinateRegion(center: center,
                                        latitudinalMeters: initialRadiusMeters,
                                        longitudinalMeters: initialRadiusMeters)
        map.setRegion(region, animated: false)

        // Add overlay
        context.coordinator.installOverlay(on: map, overlay: overlay)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // If overlay changed (frame switch), replace it.
        if context.coordinator.currentOverlayConfig != overlay {
            context.coordinator.installOverlay(on: map, overlay: overlay)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var currentOverlayConfig: OverlayConfig?

        private var overlayObj: RainViewerTileOverlay?

        func installOverlay(on map: MKMapView, overlay: OverlayConfig) {
            // Remove old overlay
            if let overlayObj {
                map.removeOverlay(overlayObj)
            }

            let tileOverlay = RainViewerTileOverlay(
                host: overlay.host,
                framePath: overlay.framePath,
                colorScheme: 2,
                smooth: true,
                snow: false,
                size: .s512,
                maxZoom: 10
            )

            overlayObj = tileOverlay
            currentOverlayConfig = overlay

            map.addOverlay(tileOverlay, level: .aboveLabels)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = CGFloat(currentOverlayConfig?.opacity ?? 0.65)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}