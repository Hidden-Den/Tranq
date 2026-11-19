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

/// Обёртка над `FallbackNotice` для одного запуска приложения.
/// «ИИ не настроен» сообщает об отсутствии настройки, а не о сбое, поэтому показывается один раз за запуск:
/// иначе человек без ИИ видел бы его после каждой диктовки. Настоящие сбои сообщаются каждый раз.
struct FallbackNoticeThrottle {
    private var notConfiguredShown = false

    mutating func message(for reason: FallbackReason?, providerID: String, engine: VoiceEngine) -> String? {
        let text = FallbackNotice.message(for: reason, providerID: providerID, engine: engine)
        guard reason == .notConfigured, text != nil else { return text }
        if notConfiguredShown { return nil }
        notConfiguredShown = true
        return text
    }
}

