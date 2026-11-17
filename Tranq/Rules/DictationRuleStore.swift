import Foundation

/// Правила приложений и сайтов. Хранятся в `UserDefaults` как JSON.
final class DictationRuleStore: ObservableObject {
    static let shared = DictationRuleStore(defaults: AppEnvironment.defaults)

    private static let key = "dictation.rules"
    private static let backupKey = "dictation.rules.backup"

    @Published private(set) var rules: [DictationRule]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.rules = Self.load(from: defaults)
    }

    func add(_ rule: DictationRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: DictationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Читает правила по одному: нечитаемая запись пропускается, остальные остаются.
    /// Если что-то не прочиталось, исходные данные откладываются в резервный ключ раньше любой записи.
    private static func load(from defaults: UserDefaults) -> [DictationRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            let items = try JSONDecoder().decode([Lossy<DictationRule>].self, from: data)
            let rules = items.compactMap(\.value)
            if rules.count != items.count {
                defaults.set(data, forKey: backupKey)
                AppLogger.shared.warn("Rules", "Часть правил приложений не прочиталась и пропущена", details: "прочитано \(rules.count) из \(items.count), копия в \(backupKey)")
            }
            return rules
        } catch {
            defaults.set(data, forKey: backupKey)
            AppLogger.shared.warn("Rules", "Не удалось прочитать правила приложений", details: error.localizedDescription)
            return []
        }
    }
}

/// Элемент массива, который не обрушивает чтение остальных.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
