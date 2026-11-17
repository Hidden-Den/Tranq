import Foundation

extension AIProviderConfig {
    /// Адрес OpenRouter: только ему отправляются заголовки с названием приложения.
    var isOpenRouter: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    /// Модели OpenAI, которым нужно явно отключить рассуждение: по умолчанию оно среднее, тормозит ответ
    /// и запрещает температуру. Имя проверяется у любого адреса формата OpenAI, шлюз тоже отдаёт такие модели.
    /// Astra и 6.1 Sol режим none не поддерживают.
    var needsReasoningOff: Bool {
        guard !isAnthropic, !isOpenRouter else { return false }
        let name = model.lowercased()
        guard name.hasPrefix("gpt-6") else { return false }
        return name.contains("luna") || name.contains("terra") || name.hasPrefix("gpt-6-sol")
    }
}

/// Сборка запросов к внешним провайдерам: формат OpenAI или Anthropic.
enum ChatRequestBuilder {
    /// Потоковый запрос очистки. `user` уходит как есть.
    static func streamRequest(config: AIProviderConfig, system: String, user: String) throws -> URLRequest {
        var cleanBase = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // Адрес без версии вводят часто: у этих двух сервисов она обязательна
        if cleanBase == "https://api.anthropic.com" || cleanBase == "https://api.openai.com" { cleanBase += "/v1" }
        let target: String
        if config.isAnthropic {
            target = cleanBase.hasSuffix("/messages") ? cleanBase : cleanBase + "/messages"
        } else {
            target = cleanBase.hasSuffix("/chat/completions") ? cleanBase : cleanBase + "/chat/completions"
        }
        guard let url = URL(string: target) else { throw CleanupBackendError.unavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, config: config)
        if config.isOpenRouter {
            request.setValue("https://github.com/Nuteres/Golosok", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Golosok", forHTTPHeaderField: "X-Title")
        }

        var body: [String: Any] = ["model": config.model, "stream": true]
        if config.isAnthropic {
            body["max_tokens"] = 1024
            body["temperature"] = 0.1
            body["messages"] = [["role": "user", "content": user]]
            if !system.isEmpty { body["system"] = system }
        } else {
            body["messages"] = [["role": "system", "content": system], ["role": "user", "content": user]]
            if config.isOpenRouter {
                body["reasoning"] = ["effort": "none", "exclude": true]
                body["provider"] = ["sort": "latency"]
            } else {
                body["temperature"] = 0.1
                if config.needsReasoningOff { body["reasoning_effort"] = "none" }
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Заголовки авторизации: ключ в `x-api-key` для Anthropic, иначе `Authorization: Bearer`.
    static func applyAuth(_ request: inout URLRequest, config: AIProviderConfig) {
        if config.isAnthropic {
            if !config.apiKey.isEmpty { request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
    }
}
