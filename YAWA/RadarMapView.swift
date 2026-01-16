//
//  RadarMapView 2.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


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
    let animateTransition: Bool

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
                minCenterCoordinateDistance: 40_000,
                maxCenterCoordinateDistance: 1_500_000
            ),
            animated: false
        )

        context.coordinator.recenterIfNeeded(map, center: center, radius: initialRadiusMeters)
        context.coordinator.installInitialOverlay(on: map, overlay: overlay)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Only recenter when the selected location changes (prevents “jump” during playback/refresh)
        context.coordinator.recenterIfNeeded(map, center: center, radius: initialRadiusMeters)

        // If only opacity changed, update renderer alpha without rebuilding overlays.
        if context.coordinator.currentFrameKey == overlay.frameKey {
            context.coordinator.updateOpacity(on: map, opacity: overlay.opacity)
            return
        }

        if animateTransition {
            context.coordinator.prefetchThenFadeInOverlay(on: map, overlay: overlay)
        } else {
            context.coordinator.replaceOverlay(on: map, overlay: overlay)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {

        // Track identity of the currently displayed frame (host+path), NOT opacity
        var currentFrameKey: String?

        // Keep last config so we can know current opacity, etc.
        var currentOverlayConfig: OverlayConfig?

        private var activeOverlay: RainViewerCachingTileOverlay?
        private var isTransitioning = false

        // Track alpha/renderer per overlay instance
        private var overlayAlpha: [ObjectIdentifier: CGFloat] = [:]
        private var overlayRenderer: [ObjectIdentifier: MKTileOverlayRenderer] = [:]

        // Recentering protection
        private var lastCentered: CLLocationCoordinate2D?

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

        // MARK: - Opacity (no overlay rebuild)

        func updateOpacity(on map: MKMapView, opacity: Double) {
            let a = CGFloat(opacity)
            currentOverlayConfig = OverlayConfig(
                host: currentOverlayConfig?.host ?? "",
                framePath: currentOverlayConfig?.framePath ?? "",
                opacity: opacity
            )

            guard let activeOverlay,
                  let renderer = overlayRenderer[ObjectIdentifier(activeOverlay)]
            else { return }

            overlayAlpha[ObjectIdentifier(activeOverlay)] = a
            renderer.alpha = a
            renderer.setNeedsDisplay()
        }

        // MARK: - Overlay lifecycle

        func installInitialOverlay(on map: MKMapView, overlay: OverlayConfig) {
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
            // Avoid redundant work
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

        /// Apple-ish: keep old visible, add new at alpha 0, then fade in when first tile arrives.
        func prefetchThenFadeInOverlay(on map: MKMapView, overlay: OverlayConfig) {
            guard !isTransitioning else { return }

            // If only opacity changed, don't transition at all.
            if currentFrameKey == overlay.frameKey {
                updateOpacity(on: map, opacity: overlay.opacity)
                return
            }

            isTransitioning = true

            guard let old = activeOverlay else {
                replaceOverlay(on: map, overlay: overlay)
                isTransitioning = false
                return
            }

            let new = makeTileOverlay(from: overlay)
            currentOverlayConfig = overlay
            currentFrameKey = overlay.frameKey

            // Start new invisible so it can load tiles while old stays visible.
            overlayAlpha[ObjectIdentifier(new)] = 0

            UIView.performWithoutAnimation {
                map.addOverlay(new, level: .aboveLabels)
            }

            let targetAlpha = CGFloat(overlay.opacity)
            var didFade = false

            func fadeNow() {
                guard !didFade else { return }
                didFade = true

                guard let newRenderer = self.overlayRenderer[ObjectIdentifier(new)] else {
                    self.replaceOverlay(on: map, overlay: overlay)
                    self.isTransitioning = false
                    return
                }

                UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseInOut]) {  // ← Increased for smoother feel
                    newRenderer.alpha = targetAlpha
                    newRenderer.setNeedsDisplay()
                } completion: { _ in
                    UIView.performWithoutAnimation {
                        map.removeOverlay(old)
                    }

                    self.overlayAlpha.removeValue(forKey: ObjectIdentifier(old))
                    self.overlayRenderer.removeValue(forKey: ObjectIdentifier(old))

                    self.activeOverlay = new
                    self.isTransitioning = false
                }
            }

            // Fade as soon as ANY tile arrives
            new.didLoadFirstTile = {
                DispatchQueue.main.async { fadeNow() }
            }

            // Safety timeout (increased slightly)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                fadeNow()
            }
        }

        // MARK: - Overlay factory

        private func makeTileOverlay(from overlay: OverlayConfig) -> RainViewerCachingTileOverlay {
            RainViewerCachingTileOverlay(
                host: overlay.host,
                framePath: overlay.framePath,
                colorScheme: 2,
                smooth: true,
                snow: false,
                size: .s512,          // ← Default to 512 for better perf
                maxZoom: 7
            )
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)

                let key = ObjectIdentifier(tile)
                let a = overlayAlpha[key] ?? 0.0
                renderer.alpha = a

                overlayRenderer[key] = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
