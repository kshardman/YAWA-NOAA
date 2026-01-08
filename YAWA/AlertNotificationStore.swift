//
//  AlertNotificationStore 2.swift
//  YAWA
//
//  Created by Keith Sharman on 1/8/26.
//

import Foundation

final class AlertNotificationStore {
    private let key = "notifiedAlertIDs"
    private let maxKeep = 200

    func hasNotified(id: String) -> Bool {
        load().contains(id)
    }

    func markNotified(id: String) {
        var set = load()
        set.insert(id)

        // keep bounded (best-effort; order isn't meaningful in a Set)
        if set.count > maxKeep {
            set = Set(Array(set).prefix(maxKeep))
        }

        save(set)
    }

    // MARK: - Persistence (UserDefaults stores as [String], we expose Set<String>)

    private func load() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
    }

    private func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
    
    func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
