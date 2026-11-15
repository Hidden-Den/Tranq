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

    /// Проверенные современные модели с ультранизкой задержкой для голосового ввода
    public static let defaultModels: [OpenRouterModelInfo] = [
        OpenRouterModelInfo(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5", description: "Сверхбыстрый синтез мыслей"),
        OpenRouterModelInfo(id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite", description: "Минимальное время отклика TTFT"),
        OpenRouterModelInfo(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", description: "Высокая скорость генерации и точность"),
        OpenRouterModelInfo(id: "qwen/qwen3.8-omni-flash", name: "Qwen 3.8 Omni Flash", description: "Современная русская грамматика"),
        OpenRouterModelInfo(id: "openai/gpt-6-luna", name: "GPT 6 Luna", description: "Быстрое редактирование текста"),
        OpenRouterModelInfo(id: "meta-llama/llama-4-scout", name: "Llama 4 Scout", description: "Глубокая смысловая структура")
    ]

    private static let catalogVersionKey = "openrouter_catalog_version"
    private static let currentCatalogVersion = 2
    private let cacheURL: URL?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.cacheURL = caches?.appendingPathComponent("openrouter_catalog_v2.json")
        let storedVersion = UserDefaults.standard.integer(forKey: Self.catalogVersionKey)

        if storedVersion < Self.currentCatalogVersion {
            // При обновлении приложения сбрасываем устаревший кэш для получения новейшего списка моделей
            self.models = Self.defaultModels
            saveToCache(Self.defaultModels)
            UserDefaults.standard.set(Self.currentCatalogVersion, forKey: Self.catalogVersionKey)
        } else {
            self.models = loadFromCache() ?? Self.defaultModels
        }
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
