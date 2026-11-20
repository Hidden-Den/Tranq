import Foundation
import Combine

/// Команды, которыми нейронка управляет словарём. Имена совпадают с именами инструментов протокола.
enum MCPCommandName: String, CaseIterable {
    case packs, words, setPack = "set_pack", addWords = "add_words"
    case removeWords = "remove_words", revertAgentWords = "revert_agent_words", dictations
    case createPack = "create_pack", deletePack = "delete_pack", packWords = "pack_words"
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

    /// Выключение доступа снимает и полный доступ, и историю, а не прячет их: при повторном включении
    /// оба права начинают с нуля и включаются заново, с предупреждением на экране настроек.
    /// Сброс стоит здесь, а не в экране, чтобы покрыть любой путь выключения. Через `didSet`
    /// каждый сброс записывается в настройки так же, как любое другое присваивание флага.
    @Published var enabled: Bool = false {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            if !enabled {
                fullAccess = false
                historyAccess = false
            }
        }
    }
    /// Разрешает выключать наборы и удалять чужие слова.
    @Published var fullAccess: Bool = false {
        didSet { defaults.set(fullAccess, forKey: Keys.fullAccess) }
    }
    /// Разрешает читать историю диктовок.
    @Published var historyAccess: Bool = false {
        didSet { defaults.set(historyAccess, forKey: Keys.historyAccess) }
    }

    /// История заперта замком или её ключ не читается. Ставит `bindHistoryLock(to:)`, в настройки не пишется.
    /// Читается и пишется только на главном потоке: дверь сама уходит на него перед проверкой.
    var historyLocked = false

    enum Verdict: Equatable {
        case allow
        case deny(String)
    }

    private let defaults: UserDefaults

    /// Тесты передают свой набор настроек.
    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        // `didSet` срабатывает и при присваивании в init. Если сохранено `enabled == false`, а флаги
        // полного доступа и истории сохранены включёнными, присваивание `enabled` сбрасывает оба флага,
        // и они записываются обратно уже выключенными. Если сохранено `enabled == true`, флаги остаются как были.
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
            // Выключенный доступ отвечает как раньше: нейронке не видно, что у человека стоит замок.
            guard historyAccess else {
                return .deny(String(localized: "Доступ нейронок к истории выключен. Включите его в настройках Tranq."))
            }
            return historyLocked
                ? .deny(String(localized: "История заперта. Разблокируйте её в Tranq."))
                : .allow
        case .setPack:
            return disablingPack && !fullAccess
                ? .deny(String(localized: "Для этого нужен полный доступ нейронок. Включите его в настройках Tranq."))
                : .allow
        case .packs, .words, .addWords, .removeWords, .revertAgentWords, .createPack, .deletePack, .packWords:
            return .allow
        }
    }

    /// Следит за замком истории: запертая и нечитаемая история закрывает `dictations`.
    /// Первое значение применяется сразу, до первого запроса. Паблишер замка работает на главном потоке.
    func bindHistoryLock(to states: AnyPublisher<HistoryLockState, Never>) -> AnyCancellable {
        states.sink { [weak self] state in self?.historyLocked = state.hidesHistory }
    }
}
