import Foundation

/// Правила приложений и сайтов. Хранятся в `UserDefaults` как JSON.
final class DictationRuleStore: ObservableObject {
    static let shared = DictationRuleStore(defaults: AppEnvironment.defaults)

    private static let key = "dictation.rules"

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

    private static func load(from defaults: UserDefaults) -> [DictationRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([DictationRule].self, from: data)
        } catch {
            AppLogger.shared.warn("Rules", "Не удалось прочитать правила приложений", details: error.localizedDescription)
            return []
        }
    }
}
