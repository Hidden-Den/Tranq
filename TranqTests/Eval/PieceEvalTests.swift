import Testing
import Foundation
@testable import Tranq

/// Замер очистки по кускам на настоящих диктовках: внешний провайдер или локальная модель.
///
/// Каждый кусок проходит тот же путь, что в приложении: этап 1, нарезка, подсказка
/// терминов из встроенных наборов, потоковый запрос и валидатор. В отчёт идёт решение
/// валидатора с причиной, чтобы видеть, что именно отклоняется и почему.
///
/// Пропускается, пока не задано окружение. Диктовки и ключ в репозиторий не попадают:
///   TRANQ_PIECE_EVAL_CASES  путь к JSON-массиву сырых расшифровок
///   TRANQ_PIECE_EVAL_OUT    путь к отчёту JSON
///   TRANQ_PIECE_EVAL_BASE, TRANQ_PIECE_EVAL_MODEL, TRANQ_PIECE_EVAL_KEY  провайдер
///   TRANQ_PIECE_EVAL_LOCAL_MODEL вместо провайдера: путь к .gguf, свой llama-server
///   TRANQ_PIECE_EVAL_TIMEOUT    срок локальной модели на кусок, по умолчанию боевые 6 с
///   TRANQ_PIECE_EVAL_MAX_TOKENS лимит ответа локальной модели вместо боевого: проверка обрыва
///   TRANQ_PIECE_EVAL_PROMPT необязательно: файл с системным промптом вместо боевого
///   TRANQ_PIECE_EVAL_REPLAY необязательно: прежний отчёт; модель не зовётся, его ответы
///                           заново проходят валидатор. Так правка валидатора сравнивается
///                           на тех же самых текстах
/// Запуск: scripts/eval-external.sh
struct PieceEvalTests {
    struct Row: Codable {
        let caseIndex: Int
        let pieceIndex: Int
        let input: String
        let output: String?
        let verdict: String
        let reason: String?
        /// Время ответа модели на кусок; нет в отчётах до 20.11.2026 и при повторе.
        var seconds: Double? = nil
    }

    @Test(.timeLimit(.minutes(30))) func liveExternalPieces() async throws {
        let env = ProcessInfo.processInfo.environment
        if let replayPath = env["TRANQ_PIECE_EVAL_REPLAY"], let outPath = env["TRANQ_PIECE_EVAL_OUT"] {
            try replay(from: replayPath, to: outPath)
            return
        }
        guard let casesPath = env["TRANQ_PIECE_EVAL_CASES"], let outPath = env["TRANQ_PIECE_EVAL_OUT"] else { return }

        let spoken = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
        let system: String
        if let promptPath = env["TRANQ_PIECE_EVAL_PROMPT"] {
            system = try String(contentsOfFile: promptPath, encoding: .utf8)
        } else {
            system = ThoughtSynthesizer.getSystemPrompt(for: .clean)
        }
        let store = DictionaryStore.shared
        // Индекс собирается в фоне: без ожидания замер шёл бы без словаря, строже приложения
        store.waitForIndex()
        #expect(store.index != nil)
        let customTerms = store.index?.approvedSpellings ?? []
        let backend: CleanupBackend
        let deadlinesFor: (Int) -> CleanupDeadlines
        // Локальный сервер отвечает по одному: параллельные куски ждали бы в очереди за счёт своего срока
        let parallel: Int
        if let modelPath = env["TRANQ_PIECE_EVAL_LOCAL_MODEL"], !modelPath.isEmpty {
            try #require(LocalLLMServer.isAvailable, "в бандле нет llama-server")
            LocalLLMServer.shared.prewarm(modelPath: modelPath)
            let ready = Date().addingTimeInterval(180)
            while !LocalLLMServer.shared.isReady(for: modelPath) {
                try #require(Date() < ready, "llama-server не загрузил модель за 180 с")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if let limit = Int(env["TRANQ_PIECE_EVAL_MAX_TOKENS"] ?? "") { LocalLLMServer.maxTokens = limit }
            backend = LocalBackend(modelPath: modelPath)
            let setting = Double(env["TRANQ_PIECE_EVAL_TIMEOUT"] ?? "") ?? 6
            deadlinesFor = { _ in CleanupDeadlines.local(setting: setting) }
            parallel = 1
        } else {
            guard let base = env["TRANQ_PIECE_EVAL_BASE"], let model = env["TRANQ_PIECE_EVAL_MODEL"],
                  let key = env["TRANQ_PIECE_EVAL_KEY"] else { return }
            backend = ExternalBackend(
                config: AIProviderConfig(baseURL: base, apiKey: key, model: model, providerID: "openrouter"),
                telemetry: await CleanupTelemetry(storeURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("piece-eval-\(UUID().uuidString).json"))
            )
            deadlinesFor = { CleanupDeadlines.external(characters: $0, setting: 6) }
            parallel = 4
        }

        // Куски всех диктовок; короткие фразы до трёх слов модель в приложении не видит
        var jobs: [(caseIndex: Int, pieceIndex: Int, piece: String)] = []
        for (caseIndex, raw) in spoken.enumerated() {
            let stageOne = ThoughtSynthesizer.stageOne(raw)
            guard stageOne.split(whereSeparator: \.isWhitespace).count > 3 else { continue }
            for (pieceIndex, piece) in TranscriptChunker.chunks(stageOne).enumerated() {
                jobs.append((caseIndex, pieceIndex, piece))
            }
        }

        let rows = try await withThrowingTaskGroup(of: Row.self) { group in
            var rows: [Row] = []
            var next = 0
            func launch() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    let suspects = store.index?.termSuspects(in: job.piece, language: .ru) ?? []
                    let hint = store.termHint(suspects)
                    let prompt = hint.isEmpty ? system : system + "\n\n" + hint
                    let deadlines = deadlinesFor(job.piece.count)
                    let started = Date()
                    do {
                        let reply = try await backend.complete(system: prompt, user: job.piece, deadlines: deadlines)
                        let seconds = Date().timeIntervalSince(started)
                        let cleaned = ThoughtSynthesizer.stripThinkingTags(from: reply)
                        switch GroundingValidator.validate(input: job.piece, output: cleaned, level: .clean,
                                                           customTerms: customTerms, termSuspects: suspects) {
                        case .valid(let text):
                            return Row(caseIndex: job.caseIndex, pieceIndex: job.pieceIndex, input: job.piece,
                                       output: text, verdict: "valid", reason: nil, seconds: seconds)
                        case .rejected(let reason):
                            return Row(caseIndex: job.caseIndex, pieceIndex: job.pieceIndex, input: job.piece,
                                       output: cleaned, verdict: "rejected", reason: reason, seconds: seconds)
                        }
                    } catch {
                        return Row(caseIndex: job.caseIndex, pieceIndex: job.pieceIndex, input: job.piece,
                                   output: nil, verdict: "failed", reason: "\(error)",
                                   seconds: Date().timeIntervalSince(started))
                    }
                }
            }
            for _ in 0..<parallel { launch() }
            while let row = try await group.next() {
                rows.append(row)
                launch()
            }
            return rows.sorted { ($0.caseIndex, $0.pieceIndex) < ($1.caseIndex, $1.pieceIndex) }
        }

        try write(rows, to: outPath)
    }

    /// Прежние ответы модели заново через валидатор, без запросов.
    private func replay(from replayPath: String, to outPath: String) throws {
        let store = DictionaryStore.shared
        store.waitForIndex()
        let customTerms = store.index?.approvedSpellings ?? []
        let previous = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: replayPath)))
        let rows = previous.map { row -> Row in
            guard let output = row.output, row.verdict != "failed" else { return row }
            let suspects = store.index?.termSuspects(in: row.input, language: .ru) ?? []
            switch GroundingValidator.validate(input: row.input, output: output, level: .clean,
                                               customTerms: customTerms, termSuspects: suspects) {
            case .valid(let text):
                return Row(caseIndex: row.caseIndex, pieceIndex: row.pieceIndex, input: row.input,
                           output: text, verdict: "valid", reason: nil)
            case .rejected(let reason):
                return Row(caseIndex: row.caseIndex, pieceIndex: row.pieceIndex, input: row.input,
                           output: output, verdict: "rejected", reason: reason)
            }
        }
        try write(rows, to: outPath)
    }

    private func write(_ rows: [Row], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
