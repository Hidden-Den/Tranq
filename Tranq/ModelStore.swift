import Foundation

struct RecognitionModel: Identifiable {
    let id: String
    let name: String
    let systemName: String
    let languageCode: String
    let fileName: String
    let isBundled: Bool
    let sizeMB: Int
    let downloadURL: URL?
}

extension RecognitionModel {
    static let russianGigaAM = RecognitionModel(
        id: "ru_giga",
        name: "RecognitionModel.Russian",
        systemName: "GigaAM",
        languageCode: "ru",
        fileName: "gigaam",
        isBundled: true,
        sizeMB: 273,
        downloadURL: nil
    )
    /// Whisper для русской речи: англицизмы пишет латиницей вдвое чаще GigaAM,
    /// замер scripts/eval-asr.py 25.11.2026. q5 мерили, она легче q8.
    static let russianTurbo = RecognitionModel(
        id: "ru_turbo",
        name: "RecognitionModel.RussianTurbo",
        systemName: "Whisper Large-v3 Turbo",
        languageCode: "ru",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        isBundled: false,
        sizeMB: 547,
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
    )
    static let englishTurbo = RecognitionModel(
        id: "en_turbo",
        name: "RecognitionModel.EnglishTurbo",
        systemName: "Whisper Large-v3 Turbo",
        languageCode: "en",
        fileName: "ggml-large-v3-turbo-q8_0.bin",
        isBundled: false,
        sizeMB: 820,
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")
    )
    static let englishMedium = RecognitionModel(
        id: "en_medium",
        name: "RecognitionModel.EnglishMedium",
        systemName: "Whisper Medium (Q5)",
        languageCode: "en",
        fileName: "ggml-medium-q5_0.bin",
        isBundled: false,
        sizeMB: 510,
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")
    )
}

final class ModelStore: NSObject, ObservableObject {
    static let shared = ModelStore()

    static let catalog: [RecognitionModel] = [.russianGigaAM, .russianTurbo, .englishTurbo, .englishMedium]

    @Published var downloadingID: String?
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus = ""
    @Published var downloadFailed = false

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var lastSpeedCheckTime: CFAbsoluteTime = 0
    private var bytesSinceLastCheck: Int64 = 0
    private var currentSpeedMBs: Double = 0.0

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    var activeModelID: String {
        get { UserDefaults.standard.string(forKey: "recognized.activeModel") ?? RecognitionModel.russianGigaAM.id }
        set {
            UserDefaults.standard.set(newValue, forKey: "recognized.activeModel")
            objectWillChange.send()
        }
    }

    func model(named id: String) -> RecognitionModel? {
        Self.catalog.first { $0.id == id } ?? Self.catalog.first { $0.name == id }
    }

    private var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataFolderName, isDirectory: true).appendingPathComponent("Models", isDirectory: true)
    }

    func localModelPath(for id: String) -> String? {
        guard let model = model(named: id) else { return nil }
        if model.isBundled {
            if let bundledPath = Bundle.main.path(forResource: model.fileName, ofType: model.id == "ru_giga" ? "gguf" : nil) {
                return bundledPath
            }
        }
        let fullName = model.id == "ru_giga" && !model.fileName.hasSuffix(".gguf") ? "\(model.fileName).gguf" : model.fileName
        let path = modelsDir.appendingPathComponent(fullName).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func isDownloaded(_ id: String) -> Bool {
        guard let model = model(named: id) else { return false }
        if model.isBundled {
            return localModelPath(for: id) != nil
        }
        return FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(model.fileName).path)
    }

    func download(_ id: String) {
        guard let model = model(named: id), let url = model.downloadURL, !isDownloaded(id) else { return }
        downloadFailed = false
        downloadStatus = "DownloadStatus.Connecting"
        downloadingID = id
        downloadProgress = 0
        lastSpeedCheckTime = CFAbsoluteTimeGetCurrent()
        bytesSinceLastCheck = 0
        currentSpeedMBs = 0.0
        AppLogger.shared.info("Models", "Начало скачивания модели", details: "\(id) — \(sizeMB(for: model))")
        task = session?.downloadTask(with: url)
        task?.resume()
    }

    private func sizeMB(for model: RecognitionModel) -> Int { model.sizeMB }

    func cancel() {
        task?.cancel()
        task = nil
        downloadingID = nil
        downloadStatus = ""
        lastSpeedCheckTime = 0
        bytesSinceLastCheck = 0
        currentSpeedMBs = 0.0
    }

    func remove(_ id: String) {
        guard let model = model(named: id), !model.isBundled else { return }
        let path = modelsDir.appendingPathComponent(model.fileName).path
        if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
        if activeModelID == id { activeModelID = RecognitionModel.russianGigaAM.id }
        objectWillChange.send()
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadingID
        guard let id, let model = self.model(named: id), !model.isBundled else {
            DispatchQueue.main.async { self.downloadingID = nil; self.downloadStatus = "" }
            return
        }
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            let dest = modelsDir.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            AppLogger.shared.info("Models", "Модель скачана", details: id)
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadStatus = "DownloadStatus.Ready"
            }
        } catch {
            AppLogger.shared.error("Models", "Ошибка сохранения модели", details: "\(id): \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadStatus = "DownloadStatus.Failed"
                self.downloadFailed = true
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error != nil else { return }
        let id = downloadingID
        AppLogger.shared.error("Models", "Скачивание модели прервано", details: "\(id ?? "?") — \(error?.localizedDescription ?? "ошибка")")
        DispatchQueue.main.async {
            self.downloadingID = nil
            self.downloadStatus = "DownloadStatus.Failed"
            self.downloadFailed = true
        }
    }
}