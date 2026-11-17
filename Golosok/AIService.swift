import Foundation
import SwiftUI

struct AIChatMessage: Codable {
    let role: String
    let content: String
}

struct AIProviderPreset: Identifiable {
    let id: String
    let name: String
    let hint: LocalizedStringKey
    let baseURL: String
    let defaultModel: String
    let needsKey: Bool
}

enum AIProviderPresets {
    static let all: [AIProviderPreset] = [
        AIProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            hint: "claude-haiku-5.5, gemini-3.8-flash",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "anthropic/claude-haiku-5.5",
            needsKey: true
        ),
        AIProviderPreset(
            id: "openai",
            name: "OpenAI",
            hint: "ChatGPT, gpt-4o-mini, gpt-4o",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            needsKey: true
        ),
        AIProviderPreset(
            id: "anthropic",
            name: "Anthropic",
            hint: "claude-3-5-haiku, claude-3-7-sonnet",
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-3-5-haiku-20241022",
            needsKey: true
        ),
        AIProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            hint: "deepseek-chat, deepseek-reasoner",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            needsKey: true
        ),
        AIProviderPreset(
            id: "ollama",
            name: "Ollama локально",
            hint: "LM Studio или локальный сервер",
            baseURL: "http://localhost:11434/v1",
            defaultModel: "llama3.2",
            needsKey: false
        )
    ]

    static func preset(id: String) -> AIProviderPreset? {
        all.first { $0.id == id }
    }
}

struct AIProviderConfig {
    let baseURL: String
    let apiKey: String
    let model: String
    var providerID: String = ""

    var isAnthropic: Bool {
        baseURL.contains("anthropic.com") || providerID == "anthropic"
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case invalidURL
    case network(String)
    case http(Int, String)
    case emptyResponse
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "ИИ-провайдер не настроен")
        case .invalidURL:
            return String(localized: "Некорректный baseURL")
        case .network(let message):
            return String(localized: "Сетевая ошибка") + ": \(message)"
        case .http(let code, let message):
            return String(localized: "Ошибка сервера") + " \(code): \(message)"
        case .emptyResponse:
            return String(localized: "Модель вернула пустой ответ")
        case .parse(let message):
            return String(localized: "Не удалось разобрать ответ") + ": \(message)"
        }
    }
}

final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()

    @Published var providerID: String { didSet { Self.defaults.set(providerID, forKey: "ai.providerID") } }
    @Published var baseURL: String { didSet { Self.defaults.set(baseURL, forKey: "ai.baseURL") } }
    @Published var model: String { didSet { Self.defaults.set(model, forKey: "ai.model") } }
    @Published var apiKey: String {
        didSet {
            if apiKey != oldValue {
                KeyStore.set(apiKey, for: "ai.apiKey")
            }
        }
    }

    @Published var isTesting = false
    @Published var testResult: String?
    @Published var testOK = false
    @Published var installedModels: [String] = []
    @Published var isLoadingModels = false

    private static let defaults = AppEnvironment.defaults

    private init() {
        // One-time cleanup for removed account credentials
        KeyStore.delete("account.token")

        let storedID = Self.defaults.string(forKey: "ai.providerID") ?? ""
        let initialID: String
        let initialBaseURL: String
        let initialModel: String

        if let preset = AIProviderPresets.preset(id: storedID) {
            initialID = preset.id
            initialBaseURL = Self.defaults.string(forKey: "ai.baseURL") ?? preset.baseURL
            initialModel = Self.defaults.string(forKey: "ai.model") ?? preset.defaultModel
        } else {
            // Stored provider is unknown, legacy or was the removed proxy; reset to default preset
            let defaultPreset = AIProviderPresets.all[0]
            initialID = defaultPreset.id
            initialBaseURL = defaultPreset.baseURL
            initialModel = defaultPreset.defaultModel
            Self.defaults.set(initialID, forKey: "ai.providerID")
            Self.defaults.set(initialBaseURL, forKey: "ai.baseURL")
            Self.defaults.set(initialModel, forKey: "ai.model")
        }

        self.providerID = initialID
        self.baseURL = initialBaseURL
        self.model = initialModel
        self.apiKey = KeyStore.get("ai.apiKey") ?? ""
    }

    var currentPreset: AIProviderPreset? {
        AIProviderPresets.preset(id: providerID)
    }

    var config: AIProviderConfig {
        AIProviderConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            providerID: providerID
        )
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (apiKey.isEmpty ? !(currentPreset?.needsKey ?? true) : true)
    }

    func apply(_ preset: AIProviderPreset) {
        providerID = preset.id
        baseURL = preset.baseURL
        model = preset.defaultModel
        testResult = nil
        testOK = false
        AppLogger.shared.info("AI", "Выбран провайдер \(preset.name)", details: preset.baseURL)
    }

    func refreshModels() {
        isLoadingModels = true
        installedModels = []
        AIService.shared.listModels(using: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingModels = false
                switch result {
                case .success(let models):
                    self.installedModels = models.sorted()
                case .failure:
                    self.installedModels = []
                }
            }
        }
    }

    func testConnection() {
        guard isConfigured else {
            testOK = false
            testResult = String(localized: "Заполните baseURL и модель")
            return
        }
        isTesting = true
        testResult = nil
        testOK = false
        AIService.shared.test(using: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isTesting = false
                switch result {
                case .success:
                    self.testOK = true
                    self.testResult = String(localized: "Подключено")
                    AppLogger.shared.info("AI", "Проверка подключения успешна", details: "\(self.baseURL) / \(self.model)")
                case .failure(let error):
                    self.testOK = false
                    self.testResult = error.localizedDescription
                    AppLogger.shared.warn("AI", "Проверка подключения не удалась", details: error.localizedDescription)
                }
            }
        }
    }
}

final class AIService {
    static let shared = AIService()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    private struct ReasoningConfig: Codable {
        let effort: String?
        let exclude: Bool?
    }

    private struct ProviderConfig: Codable {
        let sort: String?
    }

    private struct ChatRequest: Codable {
        let model: String?
        let messages: [AIChatMessage]
        let temperature: Double?
        let reasoning: ReasoningConfig?
        let provider: ProviderConfig?
    }

    func chat(messages: [AIChatMessage], using config: AIProviderConfig, completion: @escaping (Result<String, AIError>) -> Void) {
        if config.isAnthropic {
            guard let url = url(config.baseURL, path: "messages") else {
                completion(.failure(.invalidURL))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            var systemPrompt: String? = nil
            var anthropicMessages: [[String: String]] = []
            for msg in messages {
                if msg.role == "system" {
                    if let existing = systemPrompt {
                        systemPrompt = existing + "\n\n" + msg.content
                    } else {
                        systemPrompt = msg.content
                    }
                } else {
                    anthropicMessages.append(["role": msg.role, "content": msg.content])
                }
            }
            if anthropicMessages.isEmpty, let sp = systemPrompt {
                anthropicMessages.append(["role": "user", "content": sp])
                systemPrompt = nil
            }

            var bodyDict: [String: Any] = [
                "model": config.model,
                "max_tokens": 1024,
                "messages": anthropicMessages,
                "temperature": 0.1
            ]
            if let systemPrompt, !systemPrompt.isEmpty {
                bodyDict["system"] = systemPrompt
            }

            guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else {
                completion(.failure(.parse("кодирование запроса")))
                return
            }
            request.httpBody = data

            AppLogger.shared.info("AI", "Запрос к Anthropic", details: "\(config.baseURL) / \(config.model)")

            session.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(.network(error.localizedDescription)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(.network("нет HTTP-ответа")))
                    return
                }
                guard let data else {
                    completion(.failure(.emptyResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(.http(http.statusCode, Self.extractError(from: data) ?? "HTTP \(http.statusCode)")))
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(.parse("не JSON")))
                    return
                }
                if let contentArray = json["content"] as? [[String: Any]] {
                    let textParts = contentArray.compactMap { item -> String? in
                        if (item["type"] as? String) == "text" || item["text"] != nil {
                            return item["text"] as? String
                        }
                        return nil
                    }
                    let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        completion(.success(text))
                        return
                    }
                }
                completion(.failure(.emptyResponse))
            }.resume()
            return
        }

        guard let url = url(config.baseURL, path: "chat/completions") else {
            completion(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if config.baseURL.contains("openrouter.ai") {
            request.setValue("https://github.com/Nuteres/Golosok", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Golosok", forHTTPHeaderField: "X-Title")
        }

        let isOpenRouter = config.baseURL.contains("openrouter.ai")
        let reasoning = isOpenRouter ? ReasoningConfig(effort: "none", exclude: true) : nil
        let provider = isOpenRouter ? ProviderConfig(sort: "latency") : nil
        // Для OpenRouter опускаем поле temperature (nil), чтобы исключить HTTP 400 на моделях с фиксированной температурой
        let temp: Double? = isOpenRouter ? nil : 0.1

        let body = ChatRequest(
            model: config.model,
            messages: messages,
            temperature: temp,
            reasoning: reasoning,
            provider: provider
        )
        guard let data = try? JSONEncoder().encode(body) else {
            completion(.failure(.parse("кодирование запроса")))
            return
        }
        request.httpBody = data

        AppLogger.shared.info("AI", "Запрос к модели", details: "\(config.baseURL) / \(config.model), токенов в промпте ~\(messages.reduce(0) { $0 + $1.content.count } / 4)")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("нет HTTP-ответа")))
                return
            }
            guard let data else {
                completion(.failure(.emptyResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(.http(http.statusCode, Self.extractError(from: data) ?? "HTTP \(http.statusCode)")))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.parse("не JSON")))
                return
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty else {
                completion(.failure(.emptyResponse))
                return
            }
            completion(.success(content))
        }.resume()
    }

    func test(using config: AIProviderConfig, completion: @escaping (Result<Void, AIError>) -> Void) {
        guard let url = url(config.baseURL, path: "models") else {
            completion(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if config.isAnthropic {
            if !config.apiKey.isEmpty {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("нет HTTP-ответа")))
                return
            }
            if (200..<300).contains(http.statusCode) {
                completion(.success(()))
            } else {
                let message = (data.flatMap { Self.extractError(from: $0) }) ?? "HTTP \(http.statusCode)"
                completion(.failure(.http(http.statusCode, message)))
            }
        }.resume()
    }

    func listModels(using config: AIProviderConfig, completion: @escaping (Result<[String], AIError>) -> Void) {
        guard let url = url(config.baseURL, path: "models") else {
            completion(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if config.isAnthropic {
            if !config.apiKey.isEmpty {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                completion(.failure(.emptyResponse))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.parse("не JSON")))
                return
            }
            var names: [String] = []
            if let dataArr = json["data"] as? [[String: Any]] {
                names = dataArr.compactMap { $0["id"] as? String }
            }
            if names.isEmpty, let models = json["models"] as? [[String: Any]] {
                names = models.compactMap { $0["name"] as? String }
            }
            completion(.success(names))
        }.resume()
    }

    private func url(_ base: String, path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed == "https://api.anthropic.com" || trimmed == "https://api.openai.com" {
            trimmed += "/v1"
        }
        return URL(string: "\(trimmed)/\(path)")
    }

    private static func extractError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String {
            return error
        }
        return nil
    }
}
