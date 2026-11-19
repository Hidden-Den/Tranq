import Foundation

/// Шесть разделов настроек. Список живёт в боковом меню, пока открыта вкладка «Настройки».
enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation, recognition, processing, provider, app, data

    var id: String { rawValue }

    /// Ключ и в `UserDefaults`, и в `@AppStorage` бокового меню.
    static let storageKey = "settings.section"

    var title: String {
        switch self {
        case .dictation: return String(localized: "Диктовка")
        case .recognition: return String(localized: "Распознавание")
        case .processing: return String(localized: "Обработка")
        case .provider: return String(localized: "Провайдер")
        case .app: return String(localized: "Приложение")
        case .data: return String(localized: "Данные")
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "mic.fill"
        case .recognition: return "waveform"
        case .processing: return "wand.and.stars"
        case .provider: return "network"
        case .app: return "macwindow"
        case .data: return "externaldrive.fill"
        }
    }

    /// Неизвестное или пустое значение открывает первый раздел.
    static func restore(from defaults: UserDefaults) -> SettingsSection {
        from(raw: defaults.string(forKey: storageKey))
    }

    /// Единственное место, где сохранённая строка превращается в раздел.
    /// Им пользуются и `restore`, и боковое меню через `@AppStorage`.
    static func from(raw: String?) -> SettingsSection {
        raw.flatMap(SettingsSection.init(rawValue:)) ?? .dictation
    }

    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
