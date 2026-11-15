import Foundation

public struct OpenRouterModelInfo: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let contextLength: Int?

    public init(id: String, name: String, description: String? = nil, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.contextLength = contextLength
    }
}

public final class OpenRouterCatalogService: ObservableObject {
    public static let shared = OpenRouterCatalogService()

    @Published public private(set) var models: [OpenRouterModelInfo] = []
    @Published public private(set) var isLoading: Bool = false

    /// Проверенные модели с ультранизкой задержкой для голосового ввода
    public static let defaultModels: [OpenRouterModelInfo] = [
        OpenRouterModelInfo(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5", description: "Сверхбыстрый синтез мыслей"),
        OpenRouterModelInfo(id: "google/gemini-2.0-flash-001", name: "Gemini 2.0 Flash", description: "Минимальное время отклика TTFT"),
        OpenRouterModelInfo(id: "meta-llama/llama-3.3-70b-instruct", name: "Llama 3.3 70B", description: "Глубокая семантическая структура"),
        OpenRouterModelInfo(id: "deepseek/deepseek-chat", name: "DeepSeek V3", description: "Экономичный баланс скорости и качества"),
        OpenRouterModelInfo(id: "qwen/qwen-2.5-72b-instruct", name: "Qwen 2.5 72B", description: "Точная русская грамматика")
    ]

    private let cacheURL: URL?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.cacheURL = caches?.appendingPathComponent("openrouter_catalog.json")
        self.models = loadFromCache() ?? Self.defaultModels
    }

    /// Фоновое обновление каталога с OpenRouter API
    public func refreshCatalog(apiKey: String) {
        guard !apiKey.isEmpty else { return }
        guard !isLoading else { return }

        isLoading = true
        Task.detached(priority: .utility) { [weak self] in
            guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
                await self?.finishLoading(models: nil)
                return
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10.0

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    await self?.finishLoading(models: nil)
                    return
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataList = json["data"] as? [[String: Any]] {
                    var parsed: [OpenRouterModelInfo] = []
                    for item in dataList {
                        guard let id = item["id"] as? String,
                              let name = item["name"] as? String else { continue }
                        let desc = item["description"] as? String
                        let ctx = item["context_length"] as? Int
                        parsed.append(OpenRouterModelInfo(id: id, name: name, description: desc, contextLength: ctx))
                    }
                    await self?.finishLoading(models: parsed)
                } else {
                    await self?.finishLoading(models: nil)
                }
            } catch {
                AppLogger.shared.info("OpenRouterCatalog", "Не удалось загрузить каталог моделей: \(error.localizedDescription)")
                await self?.finishLoading(models: nil)
            }
        }
    }

    @MainActor
    private func finishLoading(models: [OpenRouterModelInfo]?) {
        self.isLoading = false
        if let models = models, !models.isEmpty {
            self.models = models
            saveToCache(models)
        }
    }

    private func loadFromCache() -> [OpenRouterModelInfo]? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([OpenRouterModelInfo].self, from: data)
    }

    private func saveToCache(_ models: [OpenRouterModelInfo]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(models) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
