import Foundation
import AppKit
import ServiceManagement

/// Общие настройки поведения приложения.
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var soundEnabled: Bool = AppEnvironment.defaults.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { AppEnvironment.defaults.set(soundEnabled, forKey: "soundEnabled") }
    }

    @Published var autoPasteEnabled: Bool = AppEnvironment.defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true {
        didSet { AppEnvironment.defaults.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }

    @Published var windowHighlightEnabled: Bool = AppPreferences.windowHighlightEnabled(in: AppEnvironment.defaults) {
        didSet { AppEnvironment.defaults.set(windowHighlightEnabled, forKey: "windowHighlightEnabled") }
    }

    /// Значения нет — подсветка включена.
    static func windowHighlightEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "windowHighlightEnabled") as? Bool ?? true
    }

    /// Замок истории. Флаг меняет только миграция после успешного включения или выключения.
    @Published var historyLockEnabled: Bool = AppPreferences.historyLockEnabled(in: AppEnvironment.defaults) {
        didSet { AppPreferences.setHistoryLockEnabled(historyLockEnabled, in: AppEnvironment.defaults) }
    }

    /// Значения нет — замок выключен.
    static func historyLockEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "historyLockEnabled") as? Bool ?? false
    }

    static func setHistoryLockEnabled(_ value: Bool, in defaults: UserDefaults) {
        defaults.set(value, forKey: "historyLockEnabled")
    }

    @Published var autoOpenNoteEnabled: Bool = AppEnvironment.defaults.object(forKey: "autoOpenNoteEnabled") as? Bool ?? true {
        didSet { AppEnvironment.defaults.set(autoOpenNoteEnabled, forKey: "autoOpenNoteEnabled") }
    }

    @Published var launchAtLoginEnabled: Bool = AppEnvironment.defaults.bool(forKey: "launchAtLoginEnabled") {
        didSet {
            AppEnvironment.defaults.set(launchAtLoginEnabled, forKey: "launchAtLoginEnabled")
            setLaunchAtLogin(enabled: launchAtLoginEnabled)
        }
    }

    @Published var hideInDock: Bool = AppEnvironment.defaults.bool(forKey: "hideInDock") {
        didSet {
            AppEnvironment.defaults.set(hideInDock, forKey: "hideInDock")
            applyActivationPolicy()
        }
    }

    private init() {}

    func applyActivationPolicy() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        DispatchQueue.main.async {
            if self.hideInDock {
                NSApp.setActivationPolicy(.accessory)
            } else {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            AppLogger.shared.warn("Settings", "Не удалось изменить автозапуск", details: error.localizedDescription)
        }
    }
}
