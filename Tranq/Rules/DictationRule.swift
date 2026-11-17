import Foundation

/// К чему относится правило: к приложению или к сайту в браузере.
enum RuleTarget: Codable, Equatable {
    case app(bundleId: String)
    case site(domain: String)
}

/// Тон текста, который пользователь выбрал для правила.
enum RuleTone: Codable, Equatable {
    case business
    case casual
    case custom(String)

    /// Описание тона, которое подставляется в промпт уровня C.
    var instruction: String {
        switch self {
        case .business: return "деловой: вежливо и по делу, полными предложениями, без разговорных слов"
        case .casual: return "живой: коротко и просто, как в переписке с коллегой"
        case .custom(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct DictationRule: Codable, Identifiable, Equatable {
    let id: UUID
    var target: RuleTarget
    var displayName: String
    var tone: RuleTone
    var isEnabled: Bool
}
