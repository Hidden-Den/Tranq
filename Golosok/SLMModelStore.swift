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

    /// Проверка наличия хотя бы одной установленной оффлайн-модели
    public var hasInstalledModels: Bool {
        Self.catalog.contains { isModelDownloaded($0) }
    }

    /// Поиск активной установленной модели с учетом предпочтения пользователя
    public func activeDownloadedModel(preferredId: String? = nil) -> SLMModel? {
        if let preferredId = preferredId,
           let preferred = Self.catalog.first(where: { $0.id == preferredId || $0.fileName == preferredId }),
           isModelDownloaded(preferred) {
            return preferred
        }
        return Self.catalog.first(where: { isModelDownloaded($0) })
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

    /// Запуск загрузки весов модели из официального репозитория
    public func startDownload(model: SLMModel) {
        guard let url = model.downloadURL else { return }
        cancelDownload()

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.downloadSession = session

        let task = session.downloadTask(with: url)
        self.downloadTask = task
        self.downloadingID = model.id
        self.downloadProgress = 0.0
        self.downloadStatus = "Подключение..."
        self.objectWillChange.send()

        task.resume()
        AppLogger.shared.info("SLMModelStore", "Начата загрузка модели: \(model.name)")
    }

    /// Поиск модели в каталоге по ID или имени файла
    public func model(named id: String) -> SLMModel? {
        Self.catalog.first(where: { $0.id == id || $0.fileName == id })
    }

    /// Отмена текущей загрузки модели
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        DispatchQueue.main.async {
            self.downloadingID = nil
            self.downloadProgress = 0.0
            self.downloadStatus = ""
            self.objectWillChange.send()
        }
    }

    /// Удаление модели для освобождения места на накопителе
    public func delete(model: SLMModel) {
        let url = localFileURL(for: model)
        try? FileManager.default.removeItem(at: url)
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        AppLogger.shared.info("SLMModelStore", "Модель удалена: \(model.name)")
    }
}

// MARK: - URLSessionDownloadDelegate

extension SLMModelStore: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let modelID = self.downloadingID,
              let model = Self.catalog.first(where: { $0.id == modelID }) else {
            return
        }

        let destination = localFileURL(for: model)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadProgress = 1.0
                self.downloadStatus = "Установлена"
                self.objectWillChange.send()
                AppLogger.shared.info("SLMModelStore", "Модель успешно установлена: \(model.name)")
            }
        } catch {
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadProgress = 0.0
                self.downloadStatus = "Ошибка сохранения"
                self.objectWillChange.send()
                AppLogger.shared.error("SLMModelStore", "Ошибка перемещения модели: \(error.localizedDescription)")
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.downloadProgress = progress
            self.downloadStatus = String(format: "%.0f%%", progress * 100.0)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadProgress = 0.0
                self.downloadStatus = ""
                self.objectWillChange.send()
            }
            return
        }

        if let error = error {
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadProgress = 0.0
                self.downloadStatus = "Сбой загрузки"
                self.objectWillChange.send()
                AppLogger.shared.error("SLMModelStore", "Ошибка сетевой загрузки модели: \(error.localizedDescription)")
            }
        }
    }
}
