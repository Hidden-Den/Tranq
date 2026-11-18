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

/// Итог отката: сколько записей агента удалено и сколько его вариантов снято с оставшихся записей.
struct AgentRevertResult: Equatable {
    var removedWords: Int
    var removedVariants: Int
}
