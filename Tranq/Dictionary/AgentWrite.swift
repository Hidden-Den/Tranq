import Foundation

/// Слово, которое агент просит записать в словарь через MCP.
struct AgentWord: Equatable {
    var spelling: String
    var variants: [DictionaryLanguage: [String]]
    var forceCase: Bool
}

/// Итог пачки от агента: что записано или снято, и что отброшено с причиной для человека.
struct AgentWriteResult: Equatable {
    var added: [String]
    /// Написание в том виде, в каком его прислал агент, → причина отказа.
    var skipped: [String: String]
}

/// Итог отката: сколько записей агента удалено и сколько вариантов агента снято с записей, не принадлежащих агенту.
/// В число входят и варианты, снятые с выученной записи, которую тот же откат затем удалил как пустую.
struct AgentRevertResult: Equatable {
    var removedWords: Int
    var removedVariants: Int
    /// Сколько наборов агента удалено.
    var removedPacks = 0
}

/// Итог создания набора агента. `created == false`, если набор с таким названием уже был.
struct AgentPackCreateResult: Equatable {
    var id: String
    var title: String
    var created: Bool
}

struct AgentPackDeleteResult: Equatable {
    var id: String
    var title: String
    var removedWords: Int
}

/// Отказ в работе с набором агента. Текст для человека пишет дверь.
enum AgentPackError: Error, Equatable {
    case emptyTitle
    case titleTooLong(limit: Int)
    case titleTakenByBuiltIn
    case tooManyPacks(limit: Int)
    case builtInPack(id: String)
    case noSuchPack(id: String)
    case tooManyWords(limit: Int, free: Int)
}
