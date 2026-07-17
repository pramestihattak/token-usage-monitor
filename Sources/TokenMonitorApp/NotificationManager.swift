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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                continuation.resume()
            }
        }
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
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                center.add(request) { _ in
                    continuation.resume()
                }
            }
        }
        if let data = try? JSONEncoder().encode(deduplicator) {
            defaults.set(data, forKey: "notificationDeduplicator")
        }
    }
}
