import Foundation
import AppKit

/// Постоянный процесс llama-server для локальных моделей каталога.
///
/// Модель загружается один раз и держится в памяти, поэтому запрос занимает доли
/// секунды вместо запуска llama-cli с нуля. Сервер слушает только 127.0.0.1,
/// защищён случайным ключом и останавливается после 5 минут простоя.
///
/// Сервер запускается через обёртку `/bin/sh`, которая держит открытым канал от
/// приложения. Если приложение завершится как угодно, в том числе аварийно, ядро
/// закроет канал, и обёртка остановит сервер — висящих процессов не остаётся.
final class LocalLLMServer {
    static let shared = LocalLLMServer()

    enum State: Equatable {
        case stopped
        case starting
        case ready
    }

    private let idleStopSeconds: TimeInterval = 300
    private let startupTimeout: TimeInterval = 60
    private let queue = DispatchQueue(label: "tranq.llm-server")

    private var process: Process?
    private var lifeline: Pipe?
    private var port: UInt16 = 0
    private var apiKey = ""
    private var modelPath: String?
    private var state: State = .stopped
    private var idleStop: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    static var binaryPath: String? {
        guard let path = Bundle.main.path(forResource: "llama-server", ofType: nil, inDirectory: "llama"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static var isAvailable: Bool { binaryPath != nil }

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.sync { self?.stopLocked() }
        }
    }

    /// Запускает сервер для модели, если он ещё не запущен. Не ждёт готовности.
    func prewarm(modelPath: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.startIfNeededLocked(modelPath: modelPath)
            self.scheduleIdleStopLocked()
        }
    }

    /// Готов ли сервер ответить прямо сейчас для этой модели.
    func isReady(for modelPath: String) -> Bool {
        queue.sync { state == .ready && self.modelPath == modelPath && process?.isRunning == true }
    }

    /// Лимит ответа в токенах. Речь до 1200 знаков идёт одним запросом, и при прежних 256
    /// gemma 4 E4B оборвала ответ в 1026 знаков на полуслове. Запас вчетверо: долгий ответ
    /// всё равно ограничен сроком на кусок. Стенд замера ставит его ниже, чтобы проверить обрыв.
    static var maxTokens = 1024

    /// Разбор ответа llama-server. Обрыв по лимиту длины не результат, даже если текст пришёл:
    /// валидатор разрешает сокращение и пропустил бы обрубок без последних фраз.
    static func parseCompletion(_ data: Data) -> LocalCompletion {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let content = (choice["message"] as? [String: Any])?["content"] as? String else { return .failed }
        if choice["finish_reason"] as? String == "length" { return .truncated }
        return .text(content)
    }

    /// Чат-запрос к загруженной модели. `.failed`, если сервер не готов или не ответил вовремя.
    func complete(system: String, user: String, modelPath: String, timeout: TimeInterval) async -> LocalCompletion {
        let endpoint: (port: UInt16, key: String)? = queue.sync {
            startIfNeededLocked(modelPath: modelPath)
            scheduleIdleStopLocked()
            guard state == .ready else { return nil }
            return (port, apiKey)
        }
        return await send(endpoint: endpoint, system: system, user: user, timeout: timeout)
    }

    /// Как `complete`, но ничего не запускает и не переключает: только готовый сервер с этой же моделью.
    func completeIfReady(system: String, user: String, modelPath: String, timeout: TimeInterval) async -> String? {
        let endpoint: (port: UInt16, key: String)? = queue.sync {
            guard state == .ready, self.modelPath == modelPath, process?.isRunning == true else { return nil }
            scheduleIdleStopLocked()
            return (port, apiKey)
        }
        if case .text(let text) = await send(endpoint: endpoint, system: system, user: user, timeout: timeout) { return text }
        return nil
    }

    private func send(endpoint: (port: UInt16, key: String)?, system: String, user: String, timeout: TimeInterval) async -> LocalCompletion {
        guard let endpoint, let url = URL(string: "http://127.0.0.1:\(endpoint.port)/v1/chat/completions") else { return .failed }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0,
            "max_tokens": Self.maxTokens,
            "stream": false,
            // Qwen 3 и производные иначе тратят токены на рассуждения
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                AppLogger.shared.warn("LocalLLM", "llama-server вернул неожиданный ответ")
                return .failed
            }
            let completion = Self.parseCompletion(data)
            switch completion {
            case .text: break
            case .truncated:
                AppLogger.shared.warn("LocalLLM", "Ответ обрезан по лимиту длины", details: "max_tokens \(Self.maxTokens)")
            case .failed:
                AppLogger.shared.warn("LocalLLM", "llama-server вернул неожиданный ответ")
            }
            return completion
        } catch {
            AppLogger.shared.warn("LocalLLM", "Запрос к llama-server не выполнен", details: error.localizedDescription)
            return .failed
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    // MARK: - Жизненный цикл процесса

    private func startIfNeededLocked(modelPath: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let process, process.isRunning, self.modelPath == modelPath { return }
        stopLocked()

        guard let binary = Self.binaryPath, FileManager.default.fileExists(atPath: modelPath) else { return }
        guard let freePort = Self.findFreePort() else {
            AppLogger.shared.warn("LocalLLM", "Не найден свободный порт для llama-server")
            return
        }

        let key = UUID().uuidString
        let proc = Process()
        let pipe = Pipe()
        // $0 — путь к llama-server, остальное — его аргументы. read ждёт закрытия канала.
        let wrapper = #"trap 'kill $pid 2>/dev/null' TERM; "$0" "$@" </dev/null & pid=$!; read -r _; kill $pid 2>/dev/null; wait $pid"#
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", wrapper, binary,
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(freePort),
            "-ngl", "99",
            "-c", "4096",
            "--parallel", "1",
            "--jinja",
            "--no-webui"
        ]
        // Ключ передаётся через окружение, чтобы его не было видно в списке процессов
        var environment = ProcessInfo.processInfo.environment
        environment["LLAMA_API_KEY"] = key
        proc.environment = environment
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.queue.async {
                guard self.process === finished else { return }
                if self.state != .stopped {
                    AppLogger.shared.warn("LocalLLM", "llama-server завершился", details: "код \(finished.terminationStatus)")
                }
                self.process = nil
                self.lifeline = nil
                self.state = .stopped
            }
        }

        do {
            try proc.run()
        } catch {
            AppLogger.shared.error("LocalLLM", "Не удалось запустить llama-server", details: error.localizedDescription)
            return
        }

        process = proc
        lifeline = pipe
        port = freePort
        apiKey = key
        self.modelPath = modelPath
        state = .starting
        AppLogger.shared.info("LocalLLM", "Запуск llama-server", details: URL(fileURLWithPath: modelPath).lastPathComponent)
        waitForHealthLocked(process: proc, started: Date())
    }

    /// Опрос /health в фоне; состояние становится `.ready`, когда модель загружена.
    private func waitForHealthLocked(process proc: Process, started: Date) {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let poll = { [weak self] in
            var request = URLRequest(url: healthURL, timeoutInterval: 1)
            request.httpMethod = "GET"
            URLSession.shared.dataTask(with: request) { _, response, _ in
                guard let self else { return }
                self.queue.async {
                    guard self.process === proc, self.state == .starting else { return }
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        self.state = .ready
                        AppLogger.shared.info("LocalLLM", "llama-server готов", details: String(format: "%.2f с", Date().timeIntervalSince(started)))
                    } else if Date().timeIntervalSince(started) > self.startupTimeout {
                        AppLogger.shared.warn("LocalLLM", "llama-server не поднялся за \(Int(self.startupTimeout)) с")
                        self.stopLocked()
                    } else {
                        self.queue.asyncAfter(deadline: .now() + 0.1) { self.waitForHealthLocked(process: proc, started: started) }
                    }
                }
            }.resume()
        }
        poll()
    }

    private func scheduleIdleStopLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.process != nil else { return }
            self.stopLocked()
            AppLogger.shared.info("LocalLLM", "llama-server остановлен после простоя, память освобождена")
        }
        idleStop = work
        queue.asyncAfter(deadline: .now() + idleStopSeconds, execute: work)
    }

    private func stopLocked() {
        state = .stopped
        // Закрытие канала заставляет обёртку остановить сервер; SIGTERM — на случай, если она не в read
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        modelPath = nil
    }

    private static func findFreePort() -> UInt16? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }
}

/// Исход запроса к локальной модели.
public enum LocalCompletion: Equatable {
    case text(String)
    /// Ответ оборван по лимиту длины: текст неполный, принимать его нельзя.
    case truncated
    case failed
}
