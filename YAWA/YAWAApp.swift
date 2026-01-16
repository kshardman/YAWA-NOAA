import SwiftUI
import UIKit

@main
struct YAWAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var favorites = FavoritesStore()
    @StateObject private var selection = LocationSelectionStore()

    init() {
        URLCache.shared = URLCache(
                    memoryCapacity: 64 * 1024 * 1024,
                    diskCapacity: 256 * 1024 * 1024,
                    diskPath: "radarTileCache"
                )
        
        // ✅ Don’t globally force blur/material. Let SwiftUI per-screen
        // `.toolbarBackground(... for: .navigationBar)` control the “liquid glass” look.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear

        // Optional: keep nav titles readable if any UIKit-driven bar shows up.
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance

        // ❌ IMPORTANT: remove this (it fights SwiftUI toolbarColorScheme)
        // UINavigationBar.appearance().overrideUserInterfaceStyle = .dark
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .preferredColorScheme(.dark)   // ← THIS fixes the status bar
            .environmentObject(favorites)
            .environmentObject(selection)
        }
    }
}
