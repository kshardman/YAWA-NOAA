//  iOSWeather.swift
//
//
//  Created by Keith Sharman on 12/14/25.
//

import SwiftUI
import UIKit

@main
struct iOSWeather: App {
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var selection = LocationSelectionStore()

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemMaterial)
        appearance.backgroundColor = .clear

        // Optional: remove the bottom hairline/shadow for a cleaner “glass” look
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
