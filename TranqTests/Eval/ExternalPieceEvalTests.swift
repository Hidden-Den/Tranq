import Testing
import Foundation
@testable import Tranq

/// Замер очистки внешним провайдером по кускам, на настоящих диктовках.
///
/// Каждый кусок проходит тот же путь, что в приложении: этап 1, нарезка, подсказка
/// терминов из встроенных наборов, потоковый запрос и валидатор. В отчёт идёт решение
/// валидатора с причиной, чтобы видеть, что именно отклоняется и почему.
///
/// Пропускается, пока не задано окружение. Диктовки и ключ в репозиторий не попадают:
///   TRANQ_PIECE_EVAL_CASES  путь к JSON-массиву сырых расшифровок
///   TRANQ_PIECE_EVAL_OUT    путь к отчёту JSON
///   TRANQ_PIECE_EVAL_BASE, TRANQ_PIECE_EVAL_MODEL, TRANQ_PIECE_EVAL_KEY  провайдер
///   TRANQ_PIECE_EVAL_PROMPT необязательно: файл с системным промптом вместо боевого
///   TRANQ_PIECE_EVAL_REPLAY необязательно: прежний отчёт; модель не зовётся, его ответы
///                           заново проходят валидатор. Так правка валидатора сравнивается
///                           на тех же самых текстах
/// Запуск: scripts/eval-external.sh
struct ExternalPieceEvalTests {
    struct Row: Codable {
        let caseIndex: Int
        let pieceIndex: Int
        let input: String
        let output: String?
        let verdict: String
        let reason: String?
    }

    @Test(.timeLimit(.minutes(30))) func liveExternalPieces() async throws {
        let env = ProcessInfo.processInfo.environment
        if let replayPath = env["TRANQ_PIECE_EVAL_REPLAY"], let outPath = env["TRANQ_PIECE_EVAL_OUT"] {
            try replay(from: replayPath, to: outPath)
            return
        }
        guard let casesPath = env["TRANQ_PIECE_EVAL_CASES"], let outPath = env["TRANQ_PIECE_EVAL_OUT"],
              let base = env["TRANQ_PIECE_EVAL_BASE"], let model = env["TRANQ_PIECE_EVAL_MODEL"],
              let key = env["TRANQ_PIECE_EVAL_KEY"] else { return }

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
        let backend = ExternalBackend(
            config: AIProviderConfig(baseURL: base, apiKey: key, model: model, providerID: "openrouter"),
            telemetry: await CleanupTelemetry(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("piece-eval-\(UUID().uuidString).json"))
        )

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
                    let deadlines = CleanupDeadlines.external(characters: job.piece.count, setting: 6)
                    do {
                        let reply = try await backend.complete(system: prompt, user: job.piece, deadlines: deadlines)
                        let cleaned = ThoughtSynthesizer.stripThinkingTags(from: reply)
                        switch GroundingValidator.validate(input: job.piece, output: cleaned, level: .clean,
                                                           customTerms: customTerms, termSuspects: suspects) {
                        case .valid(let text):
                            return Row(caseIndex: job.caseIndex, pieceIndex: job.pieceIndex, input: job.piece,
                                       output: text, verdict: "valid", reason: nil)
                        case .rejected(let reason):
                            return Row(caseIndex: job.caseIndex, pieceIndex: job.pieceIndex, input: job.piece,
                                       output: cleaned, verdict: "rejected", reason: reason)
                        }
                    } catch {
                        return Row(caseIndex: job.caseIndex, pieceIndex: job.pieceIndex, input: job.piece,
                                   output: nil, verdict: "failed", reason: "\(error)")
                    }
                }
            }
            for _ in 0..<4 { launch() }
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
