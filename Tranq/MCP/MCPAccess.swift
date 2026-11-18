import Foundation
import Combine

/// Команды, которыми нейронка управляет словарём. Имена совпадают с именами инструментов протокола.
enum MCPCommandName: String, CaseIterable {
    case packs, words, setPack = "set_pack", addWords = "add_words"
    case removeWords = "remove_words", revertAgentWords = "revert_agent_words", dictations
}

/// Три выключателя доступа для нейронок, все выключены по умолчанию:
/// доступ вообще, полный доступ и доступ к истории. Каждый хранится в `defaults` под своим ключом.
///
/// Шлюз решает только то, что зависит от выключателей. Разницу между своими и чужими словами
/// при удалении проводит хранилище словаря: `removeWords` здесь разрешён всегда, пока доступ включён.
final class MCPAccess: ObservableObject {
    static let shared = MCPAccess()

    private enum Keys {
        static let enabled = "mcp.enabled"
        static let fullAccess = "mcp.fullAccess"
        static let historyAccess = "mcp.historyAccess"
    }

    @Published var enabled: Bool = false {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    /// Разрешает выключать наборы и удалять чужие слова.
    @Published var fullAccess: Bool = false {
        didSet { defaults.set(fullAccess, forKey: Keys.fullAccess) }
    }
    /// Разрешает читать историю диктовок.
    @Published var historyAccess: Bool = false {
        didSet { defaults.set(historyAccess, forKey: Keys.historyAccess) }
    }

    enum Verdict: Equatable {
        case allow
        case deny(String)
    }

    private let defaults: UserDefaults

    /// Тесты передают свой набор настроек.
    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        // Присваивание в init не вызывает наблюдателей, лишней записи в настройки нет.
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        fullAccess = defaults.object(forKey: Keys.fullAccess) as? Bool ?? false
        historyAccess = defaults.object(forKey: Keys.historyAccess) as? Bool ?? false
    }

    /// Решает, можно ли выполнить команду. `disablingPack` важен только для `setPack`:
    /// включать набор можно всегда, выключать только с полным доступом.
    func verdict(for command: MCPCommandName, disablingPack: Bool) -> Verdict {
        guard enabled else {
            return .deny(String(localized: "Доступ для нейронок выключен. Включите его в настройках Tranq."))
        }
        switch command {
        case .dictations:
            return historyAccess
                ? .allow
                : .deny(String(localized: "Доступ нейронок к истории выключен. Включите его в настройках Tranq."))
        case .setPack:
            return disablingPack && !fullAccess
                ? .deny(String(localized: "Для этого нужен полный доступ нейронок. Включите его в настройках Tranq."))
                : .allow
        case .packs, .words, .addWords, .removeWords, .revertAgentWords:
            return .allow
        }
    }
}
