import Foundation

/// Локальный синтез мысли на моделях GGUF: Вихрь, Qwen, Llama.
///
/// Основной путь — постоянный `LocalLLMServer`: модель уже в памяти, ответ за доли
/// секунды. Если сервер ещё загружается или недоступен, запрос выполняется через
/// `llama-cli`, как раньше, а сервер тем временем догружается для следующих диктовок.
public final class LocalSynthServiceClient: ObservableObject {
    public static let shared = LocalSynthServiceClient()

    /// Подмена исполнителя в тестах.
    public var mockService: GolosokSynthProtocol?

    /// Разрешён ли запуск llama-cli как резервного пути.
    public var isCLIEnabled: Bool = true

    /// Путь к доступному исполняемому файлу llama-cli.
    public static var llamaCLIPath: String? {
        if let bundlePath = Bundle.main.path(forResource: "llama-cli", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        let searchPaths = ["/opt/homebrew/bin/llama-cli", "/usr/local/bin/llama-cli", "/usr/bin/llama-cli"]
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Подключён ли внешний исполнитель вместо встроенных llama-server и llama-cli.
    public var isServiceAvailable: Bool { mockService != nil }

    /// Есть ли хоть один способ выполнить локальный инференс.
    public var isEngineAvailable: Bool {
        mockService != nil || LocalLLMServer.isAvailable || (isCLIEnabled && Self.llamaCLIPath != nil)
    }

    private init() {}

    public func synthesize(
        transcript: String,
        stylePrompt: String,
        modelPath: String? = nil,
        timeout: TimeInterval = 4.0
    ) async -> String? {
        guard HardwareWatchdog.evaluateInferenceSafety() == .allowed else { return nil }

        if let mock = mockService {
            return await executeMockService(mock, transcript: transcript, stylePrompt: stylePrompt, timeout: timeout)
        }

        guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else {
            AppLogger.shared.info("LocalSynthClient", "Локальная модель не передана — мгновенный откат на этап 1")
            return nil
        }
        let prompt = "<transcript>\n\(transcript)\n</transcript>"
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent

        if LocalLLMServer.isAvailable {
            if LocalLLMServer.shared.isReady(for: modelPath) {
                AppLogger.shared.info("LocalSynthClient", "Инференс через llama-server", details: "Модель: \(modelName)")
                if let raw = await LocalLLMServer.shared.complete(system: stylePrompt, user: prompt, modelPath: modelPath, timeout: timeout) {
                    return Self.cleanModelOutput(raw)
                }
            } else {
                // Сервер догружается в фоне; эту диктовку обслужит llama-cli
                LocalLLMServer.shared.prewarm(modelPath: modelPath)
                AppLogger.shared.info("LocalSynthClient", "llama-server ещё загружается — запрос через llama-cli")
            }
        }

        guard allowsCLIFallback(modelPath: modelPath) else {
            AppLogger.shared.info("LocalSynthClient", "Модель работает только через llama-server — откат на этап 1", details: "Модель: \(modelName)")
            return nil
        }
        guard isCLIEnabled, let cliPath = Self.llamaCLIPath else {
            AppLogger.shared.info("LocalSynthClient", "Локальный исполнитель недоступен — откат на этап 1")
            return nil
        }
        AppLogger.shared.info("LocalSynthClient", "Инференс через llama-cli", details: "Модель: \(modelName)")
        return await Task.detached(priority: .userInitiated) {
            Self.runCLISynthesis(cliPath: cliPath, modelPath: modelPath, prompt: prompt, stylePrompt: stylePrompt, timeout: timeout)
        }.value
    }

    /// Запасной путь через llama-cli закрыт для моделей, которые работают только через llama-server:
    /// встроенный llama-cli может не знать их архитектуру и шаблон чата.
    func allowsCLIFallback(modelPath: String) -> Bool {
        SLMModelStore.model(forPath: modelPath)?.requiresServer != true
    }

    /// Поднимает модель заранее, пока человек ещё говорит.
    public func prewarm(modelPath: String) {
        guard HardwareWatchdog.evaluateInferenceSafety() == .allowed,
              LocalLLMServer.isAvailable,
              FileManager.default.fileExists(atPath: modelPath) else { return }
        LocalLLMServer.shared.prewarm(modelPath: modelPath)
    }

    /// Выгружает модель из памяти.
    public func unload() {
        LocalLLMServer.shared.stop()
        AppLogger.shared.info("LocalSynthClient", "Модель выгружена, память освобождена")
    }

    // MARK: - Исполнители

    private func executeMockService(
        _ service: GolosokSynthProtocol,
        transcript: String,
        stylePrompt: String,
        timeout: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            var isResumed = false
            let resumeLock = NSLock()
            let safeResume: (String?) -> Void = { result in
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !isResumed else { return }
                isResumed = true
                continuation.resume(returning: result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { safeResume(nil) }
            service.synthesize(prompt: transcript, systemPrompt: stylePrompt, options: [:]) { result, error in
                if let error {
                    AppLogger.shared.warn("LocalSynthClient", "Ошибка mock синтеза: \(error.localizedDescription)")
                    safeResume(nil)
                } else {
                    safeResume(result)
                }
            }
        }
    }

    private static func runCLISynthesis(cliPath: String, modelPath: String, prompt: String, stylePrompt: String, timeout: TimeInterval) -> String? {
        let arguments = [
            "-m", modelPath,
            "-sys", stylePrompt,
            "-p", prompt,
            "-n", "256",
            "--temp", "0.0",
            "-ngl", "99",
            "-st",
            "--no-display-prompt",
            "--simple-io"
        ]
        guard let result = ProcessRunner.run(cliPath, arguments: arguments, timeout: timeout) else {
            AppLogger.shared.error("LocalSynthClient", "Ошибка запуска llama-cli")
            return nil
        }
        guard !result.timedOut, !result.stdout.isEmpty else {
            if result.timedOut { AppLogger.shared.warn("LocalSynthClient", "llama-cli не уложился в \(Int(timeout)) с") }
            return nil
        }

        let lines = result.stdout.components(separatedBy: .newlines)
        var resultLines: [String] = []
        if lines.contains(where: { $0.hasPrefix("> ") }) {
            var recording = false
            for line in lines {
                if line.hasPrefix("> ") { recording = true; continue }
                if recording {
                    if line.hasPrefix("[ Prompt:") || line.hasPrefix("Exiting...") { break }
                    resultLines.append(line)
                }
            }
        } else {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[ Prompt:") || trimmed.hasPrefix("Exiting...")
                    || trimmed.hasPrefix("system_info:") || trimmed.hasPrefix("llama_") { continue }
                resultLines.append(line)
            }
        }
        return cleanModelOutput(resultLines.joined(separator: "\n"))
    }

    /// Убирает повтор исходника, служебные заголовки и обрамляющие кавычки из ответа модели.
    static func cleanModelOutput(_ raw: String) -> String? {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("</transcript>") {
            clean = clean.components(separatedBy: "</transcript>").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? clean
        }
        let sectionPatterns = [
            #"(?is).*(?:очищенный|исправленный|отредактированный)\s+текст\s*:\s*"#,
            #"(?is).*результат\s*:\s*"#
        ]
        for pattern in sectionPatterns {
            if let match = clean.range(of: pattern, options: .regularExpression) {
                let extracted = String(clean[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    clean = extracted
                    break
                }
            }
        }
        if clean.count >= 2,
           (clean.hasPrefix("\"") && clean.hasSuffix("\"")) || (clean.hasPrefix("«") && clean.hasSuffix("»")) {
            clean = String(clean.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean.isEmpty ? nil : clean
    }
}
