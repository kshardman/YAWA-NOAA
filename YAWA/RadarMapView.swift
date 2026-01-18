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

        /// Only the values that affect tile URL identity.
        var frameKey: String { "\(host)|\(framePath)" }
    }

    let center: CLLocationCoordinate2D
    let initialRadiusMeters: CLLocationDistance
    let overlay: OverlayConfig
    let animateTransition: Bool   // ignored in this “static” build

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator

        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = true

        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: initialRadiusMeters,
            longitudinalMeters: initialRadiusMeters
        )
        map.setRegion(region, animated: false)

        // Metro-ish zoom cap
        map.setCameraZoomRange(
            MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 60_000,  // was 40_000
                maxCenterCoordinateDistance: 7_500_000
            ),
            animated: false
        )

        context.coordinator.recenterIfNeeded(map, center: center, radius: initialRadiusMeters)
        context.coordinator.installInitialOverlay(on: map, overlay: overlay)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.recenterIfNeeded(map, center: center, radius: initialRadiusMeters)

        // Fast path: opacity only
        if context.coordinator.currentFrameKey == overlay.frameKey {
            context.coordinator.updateOpacity(on: map, opacity: overlay.opacity)
            return
        }

        // Static swap
        context.coordinator.replaceOverlay(on: map, overlay: overlay)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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

 //               print("✅ renderer created, alpha =", renderer.alpha)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: - Camera

        func recenterIfNeeded(_ map: MKMapView, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
            if let last = lastCentered,
               abs(last.latitude - center.latitude) < 0.0005,
               abs(last.longitude - center.longitude) < 0.0005 {
                return
            }
            lastCentered = center

            let region = MKCoordinateRegion(center: center,
                                            latitudinalMeters: radius,
                                            longitudinalMeters: radius)
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
            // If already installed with same frame, just update opacity
            if currentFrameKey == overlay.frameKey {
                updateOpacity(on: map, opacity: overlay.opacity)
                return
            }

            let tile = makeTileOverlay(from: overlay)
            activeOverlay = tile
            currentOverlayConfig = overlay
            currentFrameKey = overlay.frameKey

            overlayAlpha[ObjectIdentifier(tile)] = CGFloat(overlay.opacity)

 //           print("✅ tile class:", String(describing: type(of: tile)))
//            print("✅ installInitialOverlay frameKey:", overlay.frameKey, "opacity:", overlay.opacity)

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

        // MARK: - Overlay factory

        private func makeTileOverlay(from overlay: OverlayConfig) -> MKTileOverlay {
            RainViewerCachingTileOverlay(
                host: overlay.host,
                framePath: overlay.framePath,
                colorScheme: 2,
                smooth: true,
                snow: false,
                maxZoom: 7
            )
        }
    }
}
