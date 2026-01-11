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

        // Optional: if you ever show a title in the nav bar, make it readable
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance

        // ✅ This is the missing piece: makes the status bar (time/Wi-Fi/battery) white
        UINavigationBar.appearance().overrideUserInterfaceStyle = .dark
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
