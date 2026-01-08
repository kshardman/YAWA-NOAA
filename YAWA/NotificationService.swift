//
//  NotificationService.swift
//  YAWA
//
//  Created by Keith Sharman on 1/8/26.
//


import Foundation
import UserNotifications

final class NotificationService {

    static let shared = NotificationService()
    private init() {}

    // Call once (e.g. on app launch or Settings screen)
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard settings.authorizationStatus == .notDetermined else { return }

        do {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Silent failure is fine; user can enable later in Settings
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}