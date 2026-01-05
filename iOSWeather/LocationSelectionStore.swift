//
//  LocationSelectionStore.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/5/26.
//


import Foundation
import Combine

@MainActor
final class LocationSelectionStore: ObservableObject {
    // nil = Current Location (GPS)
    @Published var selectedFavorite: FavoriteLocation? = nil
}
