import Foundation

public final class LocalSynthServiceClient: ObservableObject {
    public static let shared = LocalSynthServiceClient()

    /// Мок-сервис для тестирования или встраиваемого инференса
    public var mockService: GolosokSynthProtocol?

    /// Проверка физического присутствия скомпилированного XPC-демона в бандле приложения
    public var isServiceAvailable: Bool {
        if mockService != nil {
            return true
        }
        if let xpcURL = Bundle.main.url(forResource: "com.nuter.Golosok.SynthService", withExtension: "xpc", subdirectory: "XPCServices") {
            return FileManager.default.fileExists(atPath: xpcURL.path)
        }
        let altURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/com.nuter.Golosok.SynthService.xpc")
        return FileManager.default.fileExists(atPath: altURL.path)
    }

    private var connection: NSXPCConnection?
    private let connectionLock = NSLock()
    private var idleTimer: Timer?
    private let idleTimeoutSeconds: TimeInterval = 300 // 5 минут простоя -> выгрузка

    private init() {}

    /// Выполнение синтеза мысли через локальный изолированный XPC-сервис
    public func synthesize(
        transcript: String,
        stylePrompt: String,
        timeout: TimeInterval = 4.0
    ) async -> String? {
        // Проверка аппаратной безопасности перед инференсом
        let safety = HardwareWatchdog.evaluateInferenceSafety()
        guard safety == .allowed else {
            return nil
        }

        guard isServiceAvailable, let service = getService() else {
            AppLogger.shared.info("LocalSynthClient", "XPC сервис локального синтеза не подключен — мгновенный откат на этап 1")
            return nil
        }

        resetIdleTimer()

        return await withCheckedContinuation { continuation in
            var isResumed = false
            let resumeLock = NSLock()

            let safeResume: (String?) -> Void = { result in
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !isResumed else { return }
                isResumed = true
                continuation.resume(returning: result)
            }

            // Таймаут сторож
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                safeResume(nil)
            }

            service.synthesize(
                prompt: transcript,
                systemPrompt: stylePrompt,
                options: [:]
            ) { result, error in
                if let error = error {
                    AppLogger.shared.warn("LocalSynthClient", "Ошибка XPC синтеза: \(error.localizedDescription)")
                    safeResume(nil)
                } else {
                    safeResume(result)
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
