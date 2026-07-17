import Foundation
import TokenMonitorCore
import UserNotifications

@MainActor
final class NotificationManager {
    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private var deduplicator: NotificationDeduplicator

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "notificationDeduplicator"),
           let decoded = try? JSONDecoder().decode(NotificationDeduplicator.self, from: data) {
            deduplicator = decoded
        } else {
            deduplicator = NotificationDeduplicator()
        }
    }

    func requestAuthorizationIfNeeded(enabled: Bool) async {
        guard enabled else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func evaluate(_ snapshots: [UsageSnapshot], enabled: Bool) async {
        guard enabled else { return }
        let events = deduplicator.newEvents(for: snapshots)
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = "\(event.provider.displayName) usage at \(event.threshold)%"
            content.body = "\(event.window.label) quota is \(Int(event.window.usedPercent.rounded()))% used."
            content.sound = .default
            let reset = event.window.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
            let identifier = "token-monitor.\(event.provider.rawValue).\(event.window.kind.rawValue).\(event.threshold).\(reset)"
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
        if let data = try? JSONEncoder().encode(deduplicator) {
            defaults.set(data, forKey: "notificationDeduplicator")
        }
    }
}
