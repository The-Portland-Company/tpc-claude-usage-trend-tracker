import Foundation
import UserNotifications

/// Thin seam over UNUserNotificationCenter so the model can be tested with a fake.
protocol Notifying: AnyObject {
    func requestPermission()
    func post(id: String, title: String, body: String)
}

final class Notifier: Notifying {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
