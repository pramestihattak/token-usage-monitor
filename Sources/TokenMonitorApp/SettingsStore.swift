import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let claudePath = "claudeExecutablePath"
        static let codexPath = "codexExecutablePath"
        static let refreshInterval = "quotaRefreshInterval"
        static let notifications = "notificationsEnabled"
    }

    private let defaults: UserDefaults

    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: Key.claudePath) } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: Key.codexPath) } }
    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) } }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudePath = defaults.string(forKey: Key.claudePath) ?? ""
        codexPath = defaults.string(forKey: Key.codexPath) ?? ""
        let savedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = savedInterval >= 60 ? savedInterval : 300
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "Launch at login requires running the packaged app from Applications. \(error.localizedDescription)"
        }
    }
}
