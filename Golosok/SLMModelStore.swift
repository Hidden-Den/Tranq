import Foundation

public struct SLMModel: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let fileName: String
    public let sizeMB: Int
    public let downloadURL: URL?
    public let description: String

    public init(
        id: String,
        name: String,
        fileName: String,
        sizeMB: Int,
        downloadURL: URL?,
        description: String
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sizeMB = sizeMB
        self.downloadURL = downloadURL
        self.description = description
    }
}

public final class SLMModelStore: NSObject, ObservableObject {
    public static let shared = SLMModelStore()

    public static let catalog: [SLMModel] = [
        SLMModel(
            id: "vikhr_1.5b",
            name: "Vikhr 1.5B Q4",
            fileName: "vikhr-qwen-2.5-1.5b-instruct-q4_k_m.gguf",
            sizeMB: 1100,
            downloadURL: URL(string: "https://huggingface.co/Vikhrmodels/Vikhr-Qwen-2.5-1.5B-Instruct-GGUF/resolve/main/vikhr-qwen-2.5-1.5b-instruct-q4_k_m.gguf"),
            description: "Оптимизирована для русской речи и очистки от мусора"
        ),
        SLMModel(
            id: "vikhr_0.5b",
            name: "Vikhr 0.5B Q4",
            fileName: "vikhr-qwen-2.5-0.5b-instruct-q4_k_m.gguf",
            sizeMB: 350,
            downloadURL: URL(string: "https://huggingface.co/tinyopsec/Vikhr-Qwen-2.5-0.5b-Instruct-GGUF/resolve/main/vikhr-qwen-2.5-0.5b-instruct-q4_k_m.gguf"),
            description: "Русскоязычный тюнинг в ультракомпактном размере"
        ),
        SLMModel(
            id: "qwen_0.5b",
            name: "Qwen 2.5 0.5B Q4",
            fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            sizeMB: 390,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"),
            description: "Ультралегкая модель для базовых Mac с 8 ГБ памяти"
        ),
        SLMModel(
            id: "llama_3.2_1b",
            name: "Llama 3.2 1B Q4",
            fileName: "llama-3.2-1b-instruct-q4_k_m.gguf",
            sizeMB: 750,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
            description: "Компактная быстрая мультиязычная модель"
        ),
        SLMModel(
            id: "qwen_3.5_1.5b",
            name: "Qwen 3.5 1.5B Q4",
            fileName: "qwen3.5-1.5b-instruct-q4_k_m.gguf",
            sizeMB: 1100,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-1.5B-Instruct-GGUF/resolve/main/qwen3.5-1.5b-instruct-q4_k_m.gguf"),
            description: "Новейшая архитектура с улучшенным контекстом"
        )
    ]

    @Published public var downloadingID: String?
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadStatus: String = ""

    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Golosok", isDirectory: true).appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        super.init()
    }

    /// Путь к файлу модели на диске
    public func localFileURL(for model: SLMModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// Проверка, загружен ли файл модели
    public func isModelDownloaded(_ model: SLMModel) -> Bool {
        let url = localFileURL(for: model)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Удаление модели для освобождения места на накопителе
    public func delete(model: SLMModel) {
        let url = localFileURL(for: model)
        try? FileManager.default.removeItem(at: url)
        objectWillChange.send()
        AppLogger.shared.info("SLMModelStore", "Модель удалена: \(model.name)")
    }
}
