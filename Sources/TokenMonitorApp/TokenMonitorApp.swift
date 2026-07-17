import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct TokenMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var coordinator: MonitorCoordinator

    init() {
        let settings = SettingsStore()
        let coordinator = MonitorCoordinator(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
        Task { @MainActor in await coordinator.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(coordinator: coordinator)
        } label: {
            StatusLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(settings: settings, coordinator: coordinator)
        }
    }
}
