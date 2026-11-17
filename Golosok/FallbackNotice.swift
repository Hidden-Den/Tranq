import Foundation

/// Короткая пометка на экране записи, когда вместо ответа модели вставлен текст без ИИ.
enum FallbackNotice {
    static func message(for reason: FallbackReason?, providerID: String, engine: VoiceEngine) -> String? {
        switch reason {
        case .providerUnavailable:
            if engine == .external, providerID == "corporate" { return String(localized: "Шлюз недоступен") }
            return String(localized: "ИИ недоступен")
        case .providerError:
            if engine == .external, providerID == "corporate" { return String(localized: "Ошибка шлюза") }
            return String(localized: "Ошибка ИИ")
        case .timeout:
            return String(localized: "ИИ не ответил")
        case .notConfigured:
            return String(localized: "ИИ не настроен")
        case .shortPhrase, .hardware, .emptyResponse, .rejected, nil:
            return nil
        }
    }
}
