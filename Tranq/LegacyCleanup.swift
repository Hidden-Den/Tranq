import Foundation

/// Убирает данные удалённых функций: менеджера промптов, кэша ИИ-действий, старой персонализации
/// и неиспользуемые ключи настроек. Безопасно запускать при каждом старте.
enum LegacyCleanup {
    static let obsoleteFiles = ["prompts.json", "ai_cache.json", "personalization.v1.json"]
    static let obsoleteKeys = ["voice.style", "voice.openRouterModel", "voice.adaptiveAppProfiles"]

    static func run(directory: URL = AppEnvironment.dataDirectory, defaults: UserDefaults = AppEnvironment.defaults) {
        for name in obsoleteFiles {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
