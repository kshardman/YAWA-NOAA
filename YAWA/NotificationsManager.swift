//
//  NotificationsManager.swift
//  YAWA
//
//  Created by Keith Sharman on 1/8/26.
//


import Foundation
import UserNotifications
import Combine
import SwiftUI


@MainActor
final class NotificationsManager: ObservableObject {
    static let shared = NotificationsManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("alertsNotificationsEnabled") var alertsNotificationsEnabled: Bool = true

    private let store = AlertNotificationStore()

    func clearAlertNotificationHistory() {
        store.clearAll()
    }

    private init() {
        Task { await refreshAuthorizationStatus() }
    }
 
    func hasNotifiedAlert(id: String) -> Bool {
        store.hasNotified(id: id)
    }

    func markAlertNotified(id: String) {
        store.markNotified(id: id)
    }

    #if DEBUG
    func clearAlertHistory() {
        store.clearAll()
    }
    #endif
    
    
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let ok = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                await refreshAuthorizationStatus()
                return ok
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    func postNewAlertNotification(title: String, body: String, id: String) async -> Bool {
        guard alertsNotificationsEnabled else { return false }

        let ok = await requestPermissionIfNeeded()
        guard ok else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: "nws.alert.\(id)", content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(req)
            return true
        } catch {
            return false
        }
    }
    
    
    
}
