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

        // Add a single "target" pin to mark the center coordinate
        context.coordinator.installTargetPinIfNeeded(on: map)
        context.coordinator.updateTargetPin(center)

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
        context.coordinator.installTargetPinIfNeeded(on: map)
        context.coordinator.updateTargetPin(center)
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

        // MARK: - Target pin (marks the map center)
        private let targetPin = MKPointAnnotation()
        private var isTargetPinInstalled = false

        // MARK: - Target pin helpers

        func installTargetPinIfNeeded(on map: MKMapView) {
            guard !isTargetPinInstalled else { return }
            isTargetPinInstalled = true
            targetPin.title = nil
            map.addAnnotation(targetPin)
        }

        func updateTargetPin(_ center: CLLocationCoordinate2D) {
            targetPin.coordinate = center
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            let id = "targetCrosshair"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
            
            v.annotation = annotation
            v.canShowCallout = false

            // Crosshair/dot style (subtle, non-marker)
            let img = UIImage(systemName: "scope")
                ?? UIImage(systemName: "dot.circle")

            v.image = img
            v.tintColor = UIColor.secondaryLabel

            // Keep it centered exactly on the coordinate
            v.centerOffset = .zero

            return v
        }

        // MARK: - Camera

        func recenterIfNeeded(_ map: MKMapView, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
            if let last = lastCentered,
               abs(last.latitude - center.latitude) < 0.0005,
               abs(last.longitude - center.longitude) < 0.0005 {
                return
            }
            lastCentered = center

            updateTargetPin(center)

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
