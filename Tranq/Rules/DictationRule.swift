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

    /// Мат говорящего остаётся во всех тонах, кроме делового.
    static let keepProfanity = "мат и грубые слова говорящего оставь как сказано, не смягчай и не маскируй"

    /// Деловой тон по умолчанию убирает мат.
    static let dropProfanity = "мат и грубые слова убери, их смысл и силу передай деловыми словами"

    /// Описание тона, которое подставляется в промпт уровня C.
    var instruction: String {
        switch self {
        case .business:
            return "деловой: вежливо и по делу, полными предложениями, без разговорных слов; резкость и недовольство передай твёрдыми деловыми словами, а не убирай; иронию передай по смыслу, а не дословно; не добавляй просьб и пожеланий, которых не было; \(Self.dropProfanity)"
        case .casual:
            return "живой: коротко и просто, как в переписке с коллегой; \(Self.keepProfanity)"
        case .custom(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? trimmed : "\(trimmed); \(Self.keepProfanity)"
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
