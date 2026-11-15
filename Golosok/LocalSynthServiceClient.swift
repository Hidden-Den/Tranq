import Foundation

public final class LocalSynthServiceClient: ObservableObject {
    public static let shared = LocalSynthServiceClient()

    /// Мок-сервис для тестирования или встраиваемого инференса
    public var mockService: GolosokSynthProtocol?

    /// Путь к доступному исполняемому файлу llama-cli
    public static var llamaCLIPath: String? {
        if let bundlePath = Bundle.main.path(forResource: "llama-cli", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        let searchPaths = [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
            "/usr/bin/llama-cli"
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Флаг разрешения прямого CLI инференса
    public var isCLIEnabled: Bool = true

    /// Проверка доступности локального XPC-демона
    public var isXPCAvailable: Bool {
        if let xpcURL = Bundle.main.url(forResource: "com.nuter.Golosok.SynthService", withExtension: "xpc", subdirectory: "XPCServices") {
            return FileManager.default.fileExists(atPath: xpcURL.path)
        }
        let altURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/com.nuter.Golosok.SynthService.xpc")
        return FileManager.default.fileExists(atPath: altURL.path)
    }

    /// Проверка физического присутствия скомпилированного XPC-демона в бандле приложения
    public var isServiceAvailable: Bool {
        if mockService != nil {
            return true
        }
        return isXPCAvailable
    }

    /// Проверка наличия любого доступного исполнителя (CLI или XPC)
    public var isEngineAvailable: Bool {
        mockService != nil || (isCLIEnabled && Self.llamaCLIPath != nil) || isXPCAvailable
    }

    private var connection: NSXPCConnection?
    private let connectionLock = NSLock()
    private var idleTimer: Timer?
    private let idleTimeoutSeconds: TimeInterval = 300 // 5 минут простоя -> выгрузка

    private init() {}

    /// Выполнение синтеза мысли через локальный исполнитель (llama-cli на Metal или XPC)
    public func synthesize(
        transcript: String,
        stylePrompt: String,
        modelPath: String? = nil,
        timeout: TimeInterval = 4.0
    ) async -> String? {
        // Проверка аппаратной безопасности перед инференсом
        let safety = HardwareWatchdog.evaluateInferenceSafety()
        guard safety == .allowed else {
            return nil
        }

        if let mock = mockService {
            return await executeMockService(mock, transcript: transcript, stylePrompt: stylePrompt, timeout: timeout)
        }

        // Если доступен бинарник llama-cli и передан существующий файл модели — нативный локальный инференс на Metal
        if isCLIEnabled, let cliPath = Self.llamaCLIPath, let targetPath = modelPath, FileManager.default.fileExists(atPath: targetPath) {
            AppLogger.shared.info(
                "LocalSynthClient",
                "Запуск локального инференса через llama-cli Metal",
                details: "Модель: \(URL(fileURLWithPath: targetPath).lastPathComponent)"
            )
            return await runCLISynthesis(
                cliPath: cliPath,
                modelPath: targetPath,
                transcript: transcript,
                stylePrompt: stylePrompt,
                timeout: timeout
            )
        }

        // Если скомпилирован XPC-демон
        if isXPCAvailable, let service = getService() {
            resetIdleTimer()
            return await executeXPCService(service, transcript: transcript, stylePrompt: stylePrompt, timeout: timeout)
        }

        AppLogger.shared.info("LocalSynthClient", "Локальный исполнитель инференса не подключен — мгновенный откат на этап 1")
        return nil
    }

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

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                safeResume(nil)
            }

            service.synthesize(prompt: transcript, systemPrompt: stylePrompt, options: [:]) { result, error in
                if let error = error {
                    AppLogger.shared.warn("LocalSynthClient", "Ошибка mock синтеза: \(error.localizedDescription)")
                    safeResume(nil)
                } else {
                    safeResume(result)
                }
            }
        }
    }

    private func executeXPCService(
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

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                safeResume(nil)
            }

            service.synthesize(prompt: transcript, systemPrompt: stylePrompt, options: [:]) { result, error in
                if let error = error {
                    AppLogger.shared.warn("LocalSynthClient", "Ошибка XPC синтеза: \(error.localizedDescription)")
                    safeResume(nil)
                } else {
                    safeResume(result)
                }
            }
        }
    }

    private func runCLISynthesis(
        cliPath: String,
        modelPath: String,
        transcript: String,
        stylePrompt: String,
        timeout: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: cliPath)
                let prompt = "<transcript>\n\(transcript)\n</transcript>"
                task.arguments = [
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
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()

                var isCompleted = false
                let lock = NSLock()
                let finish: (String?) -> Void = { res in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !isCompleted else { return }
                    isCompleted = true
                    continuation.resume(returning: res)
                }

                let watchdog = DispatchWorkItem {
                    if task.isRunning {
                        task.terminate()
                    }
                    finish(nil)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                do {
                    try task.run()
                    task.waitUntilExit()
                    watchdog.cancel()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                        finish(nil)
                        return
                    }

                    let lines = output.components(separatedBy: .newlines)
                    let hasInteractivePrompt = lines.contains { $0.hasPrefix("> ") }
                    var resultLines: [String] = []

                    if hasInteractivePrompt {
                        var recording = false
                        for line in lines {
                            if line.hasPrefix("> ") {
                                recording = true
                                continue
                            }
                            if recording {
                                if line.hasPrefix("[ Prompt:") || line.hasPrefix("Exiting...") {
                                    break
                                }
                                resultLines.append(line)
                            }
                        }
                    } else {
                        for line in lines {
                            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                            if trimmedLine.hasPrefix("[ Prompt:") ||
                               trimmedLine.hasPrefix("Exiting...") ||
                               trimmedLine.hasPrefix("system_info:") ||
                               trimmedLine.hasPrefix("llama_") {
                                continue
                            }
                            resultLines.append(line)
                        }
                    }

                    var cleanResult = resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanResult.contains("</transcript>") {
                        let parts = cleanResult.components(separatedBy: "</transcript>")
                        cleanResult = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? cleanResult
                    }
                    if (cleanResult.hasPrefix("\"") && cleanResult.hasSuffix("\"")) ||
                       (cleanResult.hasPrefix("«") && cleanResult.hasSuffix("»")) {
                        if cleanResult.count >= 2 {
                            cleanResult = String(cleanResult.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }

                    if cleanResult.isEmpty {
                        finish(nil)
                    } else {
                        finish(cleanResult)
                    }
                } catch {
                    AppLogger.shared.error("LocalSynthClient", "Ошибка запуска llama-cli: \(error.localizedDescription)")
                    finish(nil)
                }
            }
        }
    }

    /// Прогрев локальной модели при старте записи
    public func prewarm(modelPath: String) {
        guard HardwareWatchdog.evaluateInferenceSafety() == .allowed else { return }
        guard let service = getService() else { return }
        service.prewarmModel(modelPath: modelPath) { _ in }
        resetIdleTimer()
    }

    /// Принудительная выгрузка модели из памяти
    public func unload() {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        if let service = connection?.remoteObjectProxy as? GolosokSynthProtocol {
            service.unloadModel {}
        }
        connection?.invalidate()
        connection = nil
        idleTimer?.invalidate()
        idleTimer = nil
        AppLogger.shared.info("LocalSynthClient", "Модель выгружена, память освобождена (0 МБ)")
    }

    // MARK: - Вспомогательное подключение

    private func getService() -> GolosokSynthProtocol? {
        if let mock = mockService {
            return mock
        }
        guard isServiceAvailable else {
            return nil
        }

        connectionLock.lock()
        defer { connectionLock.unlock() }

        if let conn = connection {
            return conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                AppLogger.shared.warn("LocalSynthClient", "XPC соединение прервано: \(error.localizedDescription)")
                self?.connectionLock.lock()
                self?.connection = nil
                self?.connectionLock.unlock()
            } as? GolosokSynthProtocol
        }

        // Проверяем наличие запущенного или зарегистрированного сервиса
        let newConn = NSXPCConnection(serviceName: "com.nuter.Golosok.SynthService")
        newConn.remoteObjectInterface = NSXPCInterface(with: GolosokSynthProtocol.self)

        newConn.interruptionHandler = { [weak self] in
            AppLogger.shared.info("LocalSynthClient", "XPC прерван")
            self?.connectionLock.lock()
            self?.connection = nil
            self?.connectionLock.unlock()
        }

        newConn.invalidationHandler = { [weak self] in
            AppLogger.shared.info("LocalSynthClient", "XPC инвалидирован")
            self?.connectionLock.lock()
            self?.connection = nil
            self?.connectionLock.unlock()
        }

        newConn.resume()
        self.connection = newConn

        return newConn.remoteObjectProxyWithErrorHandler { [weak self] error in
            AppLogger.shared.info("LocalSynthClient", "XPC сервис недоступен: \(error.localizedDescription)")
            self?.connectionLock.lock()
            self?.connection = nil
            self?.connectionLock.unlock()
        } as? GolosokSynthProtocol
    }

    private func resetIdleTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: self.idleTimeoutSeconds, repeats: false) { [weak self] _ in
                self?.unload()
            }
        }
    }
}
