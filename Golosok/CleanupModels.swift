import Foundation

/// Насколько сильно очистка меняет речь.
public enum CleanupLevel: Equatable {
    /// Уровень A: звуковые паразиты и заикания, без модели.
    case verbatim
    /// Уровень B: A плюс слова-паразиты, самоисправления и повторы мыслей, слова говорящего.
    case clean
    /// Уровень C: B плюс тон по правилу пользователя.
    case rewrite(tone: String)
    /// Мысль, переписанная в запрос к нейросети.
    case prompt
}

/// Почему вместо ответа модели вставлен текст уровня A.
public enum FallbackReason: Equatable {
    case shortPhrase
    case notConfigured
    case providerUnavailable
    case timeout
    case hardware
    case emptyResponse
    case rejected(String)
}

public struct CleanupResult: Equatable {
    public let text: String
    /// Пусто, если текст вернула модель или модель не нужна.
    public let fallback: FallbackReason?

    public init(text: String, fallback: FallbackReason?) {
        self.text = text
        self.fallback = fallback
    }
}

public enum CleanupBackendError: Error, Equatable {
    case unavailable
    case timeout
    case http(Int)
    case empty
}

/// Исполнитель очистки: внешний API или локальная модель.
/// `user` это сырой текст речи, исполнитель сам оборачивает его в `<transcript>`.
public protocol CleanupBackend {
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String
}
