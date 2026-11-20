import Foundation

/// Насколько сильно очистка меняет речь.
public enum CleanupLevel: Equatable {
    /// Уровень A: звуковые паразиты и заикания, без модели.
    /// Сейчас недостижим: уровни остались каркасом спеки от 2026-11-17, а тон «Дословно» для правил вне рамок, см. §11 спеки перестройки меню.
    case verbatim
    /// Уровень B: A плюс слова-паразиты, самоисправления и повторы мыслей, слова говорящего.
    case clean
    /// Уровень C: B плюс тон по правилу пользователя.
    case rewrite(tone: String)
}

/// Почему вместо ответа модели вставлен текст уровня A.
public enum FallbackReason: Equatable {
    case shortPhrase
    case notConfigured
    case providerUnavailable
    /// Провайдер ответил ошибкой HTTP: сеть работает, но запрос отклонён.
    case providerError(Int)
    case timeout
    case hardware
    case emptyResponse
    case rejected(String)
}

public struct CleanupResult: Equatable {
    public let text: String
    /// Пусто, если текст вернула модель или уровень не требует модели. Иначе причина, по которой это текст этапа 1.
    public let fallback: FallbackReason?

    public init(text: String, fallback: FallbackReason?) {
        self.text = text
        self.fallback = fallback
    }
}

public enum CleanupBackendError: Error, Equatable {
    case unavailable
    /// Соединение оборвалось на полпути. Так ведёт себя мёртвое соединение из пула:
    /// шлюз закрыл его, пока человек говорил. Прогрев, который открывал такое соединение
    /// на старте записи, убран, но оборваться соединение может и само.
    case connectionLost
    case timeout
    case http(Int)
    case empty

    /// Короткое описание для журнала.
    var logDescription: String {
        switch self {
        case .unavailable: return "нет соединения"
        case .connectionLost: return "соединение потеряно"
        case .timeout: return "таймаут"
        case .http(let code): return "HTTP \(code)"
        case .empty: return "пустой ответ"
        }
    }
}

/// Сроки одного обращения к модели. Плоский таймаут на весь поток их не различал: шлюз,
/// который разогревался дольше него, забирал с собой и уже готовый ответ.
public struct CleanupDeadlines: Equatable {
    /// Сколько ждать начала ответа. Это про сеть и очередь провайдера, не про длину речи.
    public let firstToken: TimeInterval
    /// Сколько ждать следующий кусок, когда ответ уже пошёл.
    public let idle: TimeInterval
    /// Потолок на весь поток, последняя защита от бесконечного ответа.
    public let total: TimeInterval

    public init(firstToken: TimeInterval, idle: TimeInterval, total: TimeInterval) {
        self.firstToken = firstToken
        self.idle = idle
        self.total = total
    }
}

public extension CleanupDeadlines {
    /// Замер OpenRouter 20.11.2026, haiku 5.5 на диктовке в 1163 знака, одиннадцать прогонов:
    /// первый токен 0,84–5,46 с, простой между куском и куском до 0,75 с, генерация около 2 с.
    /// Разброс даёт `provider: sort latency`: шлюз каждый раз выбирает другой сервер, и холодный
    /// отвечает впятеро медленнее. Сроки берут этот разброс с запасом.
    static let externalFirstToken: TimeInterval = 10
    static let externalIdle: TimeInterval = 4
    /// Знаков речи на секунду потолка: генерация на этой модели идёт быстрее, запас двойной.
    static let charactersPerSecond: Double = 100

    /// Сроки внешнего провайдера. `setting` это настройка ожидания, она служит нижней границей.
    static func external(characters: Int, setting: TimeInterval) -> CleanupDeadlines {
        let firstToken = max(externalFirstToken, setting)
        let generation = Double(characters) / charactersPerSecond
        return CleanupDeadlines(
            firstToken: firstToken,
            idle: externalIdle,
            total: max(firstToken + externalIdle + generation, setting)
        )
    }

    /// Локальная модель живёт по одному сроку, как и до разделения: замеров её разброса нет,
    /// а менять её поведение наугад значит ломать работающее.
    static func local(setting: TimeInterval) -> CleanupDeadlines {
        let total = max(6.0, setting)
        return CleanupDeadlines(firstToken: total, idle: total, total: total)
    }
}

/// Исполнитель очистки: внешний API или локальная модель.
/// `user` это сырой текст речи, исполнитель сам оборачивает его в `<transcript>`.
public protocol CleanupBackend {
    func complete(system: String, user: String, deadlines: CleanupDeadlines) async throws -> String
}
