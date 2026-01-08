import SwiftUI
import UIKit

@main
struct YAWAApp: App {
    // ✅ This wires in AppDelegate (BGTasks + notifications delegate)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var favorites = FavoritesStore()
    @StateObject private var selection = LocationSelectionStore()

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemMaterial)
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environmentObject(favorites)
            .environmentObject(selection)
        }
    }
}
