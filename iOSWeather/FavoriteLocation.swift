import Foundation
import Combine
import CoreLocation

struct FavoriteLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String      // City
    var subtitle: String   // State
    var latitude: Double
    var longitude: Double

    init(title: String, subtitle: String, latitude: Double, longitude: Double) {
        self.id = UUID()
        self.title = title
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    var displayName: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [FavoriteLocation] = []

    private let key = "favorites.locations.v1"

    init() { load() }

    func add(_ loc: FavoriteLocation) {
        if favorites.contains(where: { $0.title == loc.title && $0.subtitle == loc.subtitle }) { return }
        favorites.insert(loc, at: 0)
        save()
    }

    func remove(_ loc: FavoriteLocation) {
        favorites.removeAll { $0.id == loc.id }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(favorites)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // ignore
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            favorites = try JSONDecoder().decode([FavoriteLocation].self, from: data)
        } catch {
            favorites = []
        }
    }
}