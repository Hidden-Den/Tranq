import Foundation

/// Локальная модель: llama-server с резервом на llama-cli.
struct LocalBackend: CleanupBackend {
    let modelPath: String

    func complete(system: String, user: String, deadlines: CleanupDeadlines) async throws -> String {
        guard let result = await LocalSynthServiceClient.shared.synthesize(
            transcript: user, stylePrompt: system, modelPath: modelPath, timeout: deadlines.total
        ) else { throw CleanupBackendError.unavailable }
        return result
    }
}

/// Отметка последнего куска потока: пишет чтение ответа, читает наблюдатель за сроками.
final class StreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CFAbsoluteTime?

    /// Когда пришёл последний кусок текста; `nil`, пока не пришёл ни один.
    var lastChunk: CFAbsoluteTime? {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    func noteChunk() {
        lock.lock(); last = CFAbsoluteTimeGetCurrent(); lock.unlock()
    }
}

/// Внешний API: формат OpenAI или Anthropic, ответ принимается потоком.
struct ExternalBackend: CleanupBackend {
    let config: AIProviderConfig
    /// Куда писать замеры потока; `nil` берёт общее хранилище, подмена нужна тестам.
    var telemetry: CleanupTelemetry?
    /// Сессия запроса. Подмена нужна тестам: они отдают поток без сети, своей сессией,
    /// не трогая общую регистрацию URLProtocol, глобальную на весь процесс.
    var session: URLSession = .shared

    func complete(system: String, user: String, deadlines: CleanupDeadlines) async throws -> String {
        do {
            return try await attempt(system: system, user: user, deadlines: deadlines)
        } catch CleanupBackendError.connectionLost {
            // Мёртвое соединение из пула: вторая попытка берёт живое. Сроки у неё свои,
            // первая потратила часть ожидания на то, чтобы обрыв вообще всплыл.
            AppLogger.shared.warn("Synthesizer", "Соединение потеряно, вторая попытка")
            return try await attempt(system: system, user: user, deadlines: deadlines)
        }
    }

    /// Одно обращение к провайдеру: поток под присмотром сроков.
    private func attempt(system: String, user: String, deadlines: CleanupDeadlines) async throws -> String {
        let progress = StreamProgress()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await stream(system: system, user: user, progress: progress) }
            group.addTask { try await Self.watch(progress, deadlines: deadlines) }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CleanupBackendError.empty }
            return first
        }
    }

    /// Почему поток оборван. Текст для журнала собирается здесь же, чтобы причина
    /// в логе всегда называла срок, а не общий «таймаут».
    enum StreamCut: Equatable {
        /// Ответ не начался за отведённое время.
        case noStart
        /// Поток начался и замолчал.
        case stalled
        /// Ответ не кончается, вышел общий потолок.
        case ceiling
    }

    enum StreamVerdict: Equatable {
        case wait
        case cut(StreamCut)
    }

    /// Решение по срокам: ждать или обрывать. Чистая функция от времени, поэтому
    /// её таблица проверяется тестами без таймеров и без сети.
    /// `sinceLastChunk` это `nil`, пока не пришёл ни один кусок текста.
    /// До первого куска срок простоя не применяется, после первого не применяется ожидание начала.
    static func verdict(elapsed: TimeInterval, sinceLastChunk: TimeInterval?, deadlines: CleanupDeadlines) -> StreamVerdict {
        if elapsed > deadlines.total { return .cut(.ceiling) }
        guard let sinceLastChunk else {
            return elapsed > deadlines.firstToken ? .cut(.noStart) : .wait
        }
        return sinceLastChunk > deadlines.idle ? .cut(.stalled) : .wait
    }

    /// Наблюдатель за сроками. Возврата у него нет: он либо бросает таймаут,
    /// либо отменяется вместе с победившим потоком.
    private static func watch(_ progress: StreamProgress, deadlines: CleanupDeadlines) async throws -> String {
        let started = CFAbsoluteTimeGetCurrent()
        while true {
            // Отмена приходит сюда ошибкой сна: поток ответил первым, следить больше не за чем
            try await Task.sleep(nanoseconds: 50_000_000)
            let now = CFAbsoluteTimeGetCurrent()
            let last = progress.lastChunk
            switch verdict(elapsed: now - started, sinceLastChunk: last.map { now - $0 }, deadlines: deadlines) {
            case .wait:
                continue
            case .cut(let cut):
                AppLogger.shared.warn("Synthesizer", cut.logMessage(elapsed: now - started, sinceLastChunk: last.map { now - $0 }))
                throw CleanupBackendError.timeout
            }
        }
    }

    private func stream(system: String, user: String, progress: StreamProgress) async throws -> String {
        let request = try ChatRequestBuilder.streamRequest(config: config, system: system, user: "<transcript>\(user)</transcript>")

        let store: CleanupTelemetry
        if let telemetry { store = telemetry } else { store = await CleanupTelemetry.shared }
        let started = CFAbsoluteTimeGetCurrent()
        var accumulated = ""
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CleanupBackendError.unavailable }
            guard http.statusCode == 200 else { throw CleanupBackendError.http(http.statusCode) }

            var stripper = StreamingThinkTagStripper()
            var usage = UsageAccumulator()
            var gotFirstToken = false
            for try await line in bytes.lines {
                switch Self.parseStreamLine(line) {
                case .skip: continue
                case .done: break
                case .failure: throw CleanupBackendError.unavailable
                case .usage(let input, let output):
                    usage.apply(input: input, output: output)
                    continue
                case .text(let piece):
                    progress.noteChunk()
                    if !gotFirstToken {
                        gotFirstToken = true
                        let elapsed = CFAbsoluteTimeGetCurrent() - started
                        AppLogger.shared.info("Synthesizer", String(format: "Первый токен получен за %.2f с", elapsed))
                        await store.noteFirstToken(seconds: elapsed)
                    }
                    // Часть шлюзов шлёт usage вместе с текстом: расход берём независимо от куска
                    if let pair = Self.usagePair(in: line) { usage.apply(input: pair.input, output: pair.output) }
                    if let clean = stripper.feed(piece) { accumulated.append(clean) }
                    continue
                }
                break
            }
            if let rest = stripper.finish() { accumulated.append(rest) }
            // Провайдер мог не прислать расход: тогда оценка по символам с пометкой
            await store.noteUsage(
                input: usage.input ?? CleanupTelemetry.estimateTokens(system + user),
                output: usage.output ?? CleanupTelemetry.estimateTokens(accumulated),
                estimated: usage.input == nil || usage.output == nil
            )
        } catch let error as CleanupBackendError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw CleanupBackendError.timeout
        } catch let error as URLError where error.code == .networkConnectionLost {
            throw CleanupBackendError.connectionLost
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // Поток оборвала задача с таймером, настоящей ошибки соединения нет
            throw CancellationError()
        } catch {
            let code = (error as? URLError)?.code.rawValue
            AppLogger.shared.warn("Synthesizer", "Ошибка соединения с провайдером", details: "\(config.baseURL), код \(code.map(String.init) ?? "?"), \(error.localizedDescription)")
            throw CleanupBackendError.unavailable
        }

        let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CleanupBackendError.empty }
        return text
    }
}

extension ExternalBackend {
    enum StreamEvent: Equatable {
        case text(String)
        case done
        /// Провайдер прислал ошибку посреди потока.
        case failure
        /// Расход токенов, который провайдер прислал отдельной строкой. Любое из чисел может отсутствовать.
        case usage(input: Int?, output: Int?)
        case skip
    }

    /// Одна строка потока ответа: формат OpenAI или Anthropic.
    static func parseStreamLine(_ line: String) -> StreamEvent {
        guard line.hasPrefix("data: ") else { return .skip }
        let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .skip }
        let type = json["type"] as? String
        if type == "message_stop" { return .done }
        if type == "error" || json["error"] != nil { return .failure }
        // Текст важнее расхода: часть шлюзов шлёт usage в каждом куске, и ответ терять нельзя
        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            if let piece = delta["content"] as? String, !piece.isEmpty { return .text(piece) }
            return usageEvent(in: json) ?? .skip
        }
        if let delta = json["delta"] as? [String: Any], let piece = delta["text"] as? String, !piece.isEmpty {
            return .text(piece)
        }
        // У последнего куска OpenAI массив choices пуст, у Anthropic usage лежит в message_start и message_delta
        return usageEvent(in: json) ?? .skip
    }

    /// Расход из строки потока независимо от того, есть ли в ней текст.
    static func usagePair(in line: String) -> (input: Int?, output: Int?)? {
        guard line.hasPrefix("data: "), line.contains("\"usage\""),
              let data = String(line.dropFirst(6)).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              case .usage(let input, let output)? = usageEvent(in: json) else { return nil }
        return (input, output)
    }

    private static func usageEvent(in json: [String: Any]) -> StreamEvent? {
        let usage = (json["usage"] as? [String: Any])
            ?? ((json["message"] as? [String: Any])?["usage"] as? [String: Any])
        guard let usage else { return nil }
        let input = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int)
        let output = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int)
        guard input != nil || output != nil else { return nil }
        return .usage(input: input, output: output)
    }
}

extension ExternalBackend.StreamCut {
    /// Строка для журнала: называет срок и то время, на котором он вышел.
    func logMessage(elapsed: TimeInterval, sinceLastChunk: TimeInterval?) -> String {
        switch self {
        case .noStart: return String(format: "Ответ не начался за %.1f с", elapsed)
        case .stalled: return String(format: "Поток замолчал на %.1f с", sinceLastChunk ?? elapsed)
        case .ceiling: return String(format: "Срок потока вышел: %.1f с", elapsed)
        }
    }
}

/// Складывает расход из потока. Anthropic присылает usage дважды, в `message_start` и в `message_delta`:
/// входные токены берутся первым значением, выходные последним, поэтому они не складываются вдвое.
struct UsageAccumulator {
    private(set) var input: Int?
    private(set) var output: Int?

    mutating func apply(input newInput: Int?, output newOutput: Int?) {
        if input == nil { input = newInput }
        if let newOutput { output = newOutput }
    }
}
