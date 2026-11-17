import Foundation

public struct SLMModel: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let fileName: String
    public let sizeMB: Int
    public let downloadURLs: [URL]
    public let description: String
    /// Класс памяти Mac, для которого модель рассчитана: 8 или 16 ГБ.
    public let memoryClassGB: Int
    /// Модель работает только через llama-server: встроенный llama-cli может не знать её архитектуру.
    public let requiresServer: Bool

    public var downloadURL: URL? {
        downloadURLs.first
    }

    public init(
        id: String,
        name: String,
        fileName: String,
        sizeMB: Int,
        downloadURLs: [URL],
        description: String,
        memoryClassGB: Int = 8,
        requiresServer: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sizeMB = sizeMB
        self.downloadURLs = downloadURLs
        self.description = description
        self.memoryClassGB = memoryClassGB
        self.requiresServer = requiresServer
    }

    public init(
        id: String,
        name: String,
        fileName: String,
        sizeMB: Int,
        downloadURL: URL?,
        description: String,
        memoryClassGB: Int = 8,
        requiresServer: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sizeMB = sizeMB
        self.downloadURLs = downloadURL.map { [$0] } ?? []
        self.description = description
        self.memoryClassGB = memoryClassGB
        self.requiresServer = requiresServer
    }
}

public final class SLMModelStore: NSObject, ObservableObject {
    public static let shared = SLMModelStore()

    public static let catalog: [SLMModel] = [
        SLMModel(
            id: "gemma_4_e4b_qat",
            name: "Gemma 4 E4B",
            fileName: "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf",
            sizeMB: 4210,
            downloadURLs: [
                URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf")!
            ],
            description: "Точная очистка, быстрая",
            memoryClassGB: 16,
            requiresServer: true
        ),
        SLMModel(
            id: "tlite_2.1",
            name: "T-lite 2.1",
            fileName: "T-lite-it-2.1-Q4_K_M.gguf",
            sizeMB: 5030,
            downloadURLs: [
                URL(string: "https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/resolve/main/T-lite-it-2.1-Q4_K_M.gguf")!
            ],
            description: "Сильна в терминах",
            memoryClassGB: 16,
            requiresServer: true
        ),
        SLMModel(
            id: "gemma_4_e2b",
            name: "Gemma 4 E2B",
            fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
            sizeMB: 3110,
            downloadURLs: [
                URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!
            ],
            description: "Лёгкая и быстрая",
            memoryClassGB: 8,
            requiresServer: true
        )
    ]

    /// Файлы моделей, выведенных из каталога по замеру. Удаляются при запуске.
    static let retiredFileNames: [String] = [
        "QVikhr-2.5-1.5B-Instruct-SMPO-Q4_K_M.gguf",
        "QVikhr-3-4B-Instruction-Q4_K_M.gguf",
        "Vikhr-Qwen-2.5-0.5B-instruct-Q4_K_M.gguf",
        "Qwen3.5-0.8B-Q4_K_M.gguf",
        "Qwen3.5-2B-Q4_K_M.gguf",
        "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    ]

    /// ID выведенных моделей и старые ключи настроек: выбор переходит на лёгкую рекомендуемую модель.
    static let retiredIDs: Set<String> = [
        "vikhr_1.5b", "qvikhr_3_4b", "vikhr_0.5b", "qwen_3.5_0.8b", "qwen_3.5_2b", "llama_3.2_1b",
        "qwen_0.5b", "qwen_1.5b", "qwen_3.5_1.5b"
    ]

    static func retiredFiles(in directory: URL, retired: [String] = retiredFileNames) -> [URL] {
        let names = Set(retired)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Прежние модели остаются, пока не скачана ни одна из каталога: без неё офлайн-режим пропал бы совсем
        let current = Set(catalog.map(\.fileName))
        guard files.contains(where: { current.contains($0.lastPathComponent) }) else { return [] }
        return files.filter { names.contains($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Удаляет файлы выведенных моделей из каталога моделей приложения.
    func removeRetiredModels() {
        for file in Self.retiredFiles(in: modelsDirectory) {
            do {
                try FileManager.default.removeItem(at: file)
                AppLogger.shared.info("SLMModelStore", "Удалена выведенная модель", details: file.lastPathComponent)
            } catch {
                AppLogger.shared.warn("SLMModelStore", "Не удалось удалить выведенную модель \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    @Published public var downloadingID: String?
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadStatus: String = ""

    private var activeModel: SLMModel?
    private var currentSourceIndex: Int = 0
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var lastSpeedCheckTime: CFAbsoluteTime = 0
    private var bytesSinceLastCheck: Int64 = 0
    private var currentSpeedMBs: Double = 0.0

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
           let preferred = model(named: preferredId),
           isModelDownloaded(preferred) {
            return preferred
        }
        return Self.catalog.first(where: { isModelDownloaded($0) })
    }

    /// Путь к файлу модели на диске
    public func localFileURL(for model: SLMModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// Проверка, загружен ли файл модели и валиден ли его размер
    public func isModelDownloaded(_ model: SLMModel) -> Bool {
        let url = localFileURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return size > 10 * 1024 * 1024
    }

    /// Запуск загрузки весов модели с автоматическим fail-safe перебором зеркал
    public func startDownload(model: SLMModel, sourceIndex: Int = 0) {
        guard !model.downloadURLs.isEmpty, sourceIndex < model.downloadURLs.count else { return }

        if sourceIndex == 0 {
            cancelDownload()
        } else {
            downloadTask?.cancel()
            downloadTask = nil
        }

        let targetURL = model.downloadURLs[sourceIndex]
        self.activeModel = model
        self.currentSourceIndex = sourceIndex
        self.lastSpeedCheckTime = CFAbsoluteTimeGetCurrent()
        self.bytesSinceLastCheck = 0
        self.currentSpeedMBs = 0.0

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 3600.0

        if self.downloadSession == nil {
            self.downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }

        let task = self.downloadSession?.downloadTask(with: targetURL)
        self.downloadTask = task

        DispatchQueue.main.async {
            self.downloadingID = model.id
            self.downloadProgress = 0.0
            if sourceIndex == 0 {
                self.downloadStatus = "Подключение..."
            } else {
                self.downloadStatus = "Зеркало \(sourceIndex + 1)..."
            }
            self.objectWillChange.send()
        }

        task?.resume()
        AppLogger.shared.info("SLMModelStore", "Загрузка \(model.name) из источника \(sourceIndex + 1)/\(model.downloadURLs.count): \(targetURL.absoluteString)")
    }

    /// Модель каталога по пути к её файлу.
    static func model(forPath path: String) -> SLMModel? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return catalog.first { $0.fileName == name }
    }

    /// Поиск модели в каталоге по ID или имени файла с поддержкой legacy ключей
    public func model(named id: String) -> SLMModel? {
        if Self.retiredIDs.contains(id) {
            return Self.catalog.first(where: { $0.id == SLMRecommendation.smallID })
        }
        return Self.catalog.first(where: { $0.id == id || $0.fileName == id })
    }

    /// Отмена текущей загрузки модели
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        activeModel = nil
        currentSourceIndex = 0
        lastSpeedCheckTime = 0
        bytesSinceLastCheck = 0
        currentSpeedMBs = 0.0
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

    /// Переход на следующее зеркало при ошибке или завершение со статусом сбоя
    private func tryNextSourceOrComplete(for model: SLMModel, reason: String) {
        let nextIndex = currentSourceIndex + 1
        if nextIndex < model.downloadURLs.count {
            AppLogger.shared.info("SLMModelStore", "Переход на зеркало \(nextIndex + 1)/\(model.downloadURLs.count) для \(model.name) из-за: \(reason)")
            DispatchQueue.main.async {
                self.downloadProgress = 0.0
                self.downloadStatus = "Смена источника..."
                self.objectWillChange.send()
                self.startDownload(model: model, sourceIndex: nextIndex)
            }
        } else {
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.activeModel = nil
                self.downloadProgress = 0.0
                self.downloadStatus = "Сбой загрузки"
                self.objectWillChange.send()
                AppLogger.shared.error("SLMModelStore", "Все источники для \(model.name) исчерпаны: \(reason)")
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension SLMModelStore: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = self.activeModel else {
            return
        }

        // Проверяем HTTP статус-код
        if let httpResponse = downloadTask.response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            AppLogger.shared.warn("SLMModelStore", "HTTP \(httpResponse.statusCode) для \(model.name) из источника \(currentSourceIndex + 1)")
            tryNextSourceOrComplete(for: model, reason: "HTTP \(httpResponse.statusCode)")
            return
        }

        // Защита от коротких страниц ошибок под видом файла весов
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        guard fileSize > 10 * 1024 * 1024 else {
            AppLogger.shared.warn("SLMModelStore", "Файл слишком мал (\(fileSize) байт) для \(model.name) из источника \(currentSourceIndex + 1)")
            tryNextSourceOrComplete(for: model, reason: "Поврежденный файл")
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
                self.activeModel = nil
                self.downloadProgress = 1.0
                self.downloadStatus = "Установлена"
                self.objectWillChange.send()
                AppLogger.shared.info("SLMModelStore", "Модель успешно установлена: \(model.name)")
            }
        } catch {
            AppLogger.shared.error("SLMModelStore", "Ошибка перемещения модели: \(error.localizedDescription)")
            tryNextSourceOrComplete(for: model, reason: "Ошибка сохранения")
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

        bytesSinceLastCheck += bytesWritten
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastSpeedCheckTime

        if elapsed >= 0.5 {
            let bytesPerSec = Double(bytesSinceLastCheck) / elapsed
            let instantMBs = bytesPerSec / (1024.0 * 1024.0)
            currentSpeedMBs = currentSpeedMBs == 0 ? instantMBs : (currentSpeedMBs * 0.7 + instantMBs * 0.3)
            lastSpeedCheckTime = now
            bytesSinceLastCheck = 0
        }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mbW = Double(totalBytesWritten) / (1024.0 * 1024.0)
        let mbT = Double(totalBytesExpectedToWrite) / (1024.0 * 1024.0)
        let pct = Int(progress * 100.0)

        let speedStr: String
        if currentSpeedMBs >= 0.1 {
            speedStr = String(format: " — %.1f МБ/с", currentSpeedMBs)
        } else {
            speedStr = ""
        }

        let statusText = String(format: "%.0f / %.0f МБ — %d%%%@", mbW, mbT, pct, speedStr)

        DispatchQueue.main.async {
            self.downloadProgress = progress
            self.downloadStatus = statusText
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            return
        }

        if let error = error {
            guard let model = self.activeModel else { return }
            AppLogger.shared.warn("SLMModelStore", "Сетевой сбой загрузки \(model.name) из источника \(currentSourceIndex + 1): \(error.localizedDescription)")
            tryNextSourceOrComplete(for: model, reason: error.localizedDescription)
        }
    }
}
