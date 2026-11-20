import Testing
import Foundation
@testable import Tranq

/// Модель по сценарию: ответ считается из текста куска, вызовы запоминаются по порядку.
final class ScriptedBackend: CleanupBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [String] = []
    private let script: @Sendable (String) throws -> String

    init(_ script: @escaping @Sendable (String) throws -> String) {
        self.script = script
    }

    /// Тексты, которые пришли модели, по порядку.
    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func complete(system: String, user: String, deadlines: CleanupDeadlines) async throws -> String {
        lock.lock(); received.append(user); lock.unlock()
        return try script(user)
    }
}

/// Очистка длинной речи по кускам. Каждый кусок проверяется валидатором отдельно,
/// и отказ по куску стоит одного абзаца: он вставляется как сказан, остальные чистые.
@MainActor
struct ChunkedCleanupTests {
    /// Длинная речь с паразитом «Ну,» в каждом предложении и своим номером раздела.
    private let long = (1...24).map {
        "Ну, в разделе \($0) надо поправить кнопку и проверить отступы на экране настроек."
    }.joined(separator: " ")

    /// Модель, которая просто убирает паразит.
    nonisolated private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "Ну, в", with: "В")
    }

    private func clean(_ text: String, backend: CleanupBackend, store: CleanupTelemetry? = nil) async -> CleanupResult {
        await ThoughtSynthesizer.shared.clean(
            text, level: .clean, targetBundleId: nil, firedSpellings: [], language: .ru,
            backend: backend, telemetry: store
        )
    }

    private func makeStore() -> CleanupTelemetry {
        CleanupTelemetry(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json"))
    }

    /// Длинная речь уходит кусками, каждый кусок становится абзацем.
    @Test func longDictationIsCleanedPieceByPiece() async {
        let stageOne = ThoughtSynthesizer.stageOne(long)
        let pieces = TranscriptChunker.chunks(stageOne)
        #expect(pieces.count > 1)

        let backend = ScriptedBackend { Self.tidy($0) }
        let result = await clean(long, backend: backend)
        #expect(backend.calls == pieces)
        #expect(result.text == pieces.map(Self.tidy).joined(separator: "\n\n"))
        #expect(result.fallback == nil)
    }

    /// Модель потеряла число в одном куске: валидатор отклоняет только его,
    /// и он вставляется как сказан, а соседи остаются чистыми.
    @Test func rejectedPieceFallsBackAlone() async {
        let stageOne = ThoughtSynthesizer.stageOne(long)
        let pieces = TranscriptChunker.chunks(stageOne)
        let broken = pieces.firstIndex { $0.contains("разделе 7 ") }!

        let backend = ScriptedBackend { piece in
            piece.contains("разделе 7 ") ? Self.tidy(piece).replacingOccurrences(of: "разделе 7 ", with: "разделе ") : Self.tidy(piece)
        }
        let result = await clean(long, backend: backend)
        var expected = pieces.map(Self.tidy)
        expected[broken] = pieces[broken]
        #expect(result.text == expected.joined(separator: "\n\n"))
        #expect(result.fallback == nil)
    }

    /// Запрос по одному куску не прошёл: этот кусок как сказан, остальные чистые.
    @Test func failedRequestFallsBackAlone() async {
        let stageOne = ThoughtSynthesizer.stageOne(long)
        let pieces = TranscriptChunker.chunks(stageOne)

        let backend = ScriptedBackend { piece in
            if piece == pieces[0] { throw CleanupBackendError.timeout }
            return Self.tidy(piece)
        }
        let result = await clean(long, backend: backend)
        var expected = pieces.map(Self.tidy)
        expected[0] = pieces[0]
        #expect(result.text == expected.joined(separator: "\n\n"))
        #expect(result.fallback == nil)
    }

    /// Не прошёл ни один кусок: всё как раньше, текст этапа 1 и причина первого отказа.
    @Test func everyPieceFailingKeepsTheReason() async {
        let result = await clean(long, backend: ScriptedBackend { _ in throw CleanupBackendError.timeout })
        #expect(result == CleanupResult(text: ThoughtSynthesizer.stageOne(long), fallback: .timeout))
    }

    /// Короткая диктовка идёт одним запросом, как и раньше.
    @Test func shortDictationIsOneRequest() async {
        let short = "Ну, в разделе 3 надо поправить кнопку и проверить отступы на экране настроек."
        let backend = ScriptedBackend { Self.tidy($0) }
        let result = await clean(short, backend: backend)
        #expect(backend.calls == [ThoughtSynthesizer.stageOne(short)])
        #expect(result.fallback == nil)
    }

    /// Каждый кусок это отдельный запрос и отдельный замер.
    @Test func everyPieceIsMeasured() async {
        let pieces = TranscriptChunker.chunks(ThoughtSynthesizer.stageOne(long))
        let store = makeStore()
        _ = await clean(long, backend: ScriptedBackend { Self.tidy($0) }, store: store)
        #expect(store.records.count == pieces.count)
        #expect(store.records.allSatisfy { $0.outcome == .success })
    }
}
