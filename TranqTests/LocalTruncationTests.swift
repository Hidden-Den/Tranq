import Testing
import Foundation
@testable import Tranq

/// Обрыв ответа локальной модели по лимиту длины.
///
/// Замер 20.11.2026, gemma 4 E4B: на диктовке в 1163 знака ответ упёрся в `max_tokens: 256`
/// и оборвался на «...формировать две аут-сущ». Причину обрыва никто не читал, валидатор
/// сокращение разрешает, и обрубок прошёл: последняя фраза пропала без следа.
struct LocalTruncationTests {
    private func response(content: String?, finish: String?) -> Data {
        var choice: [String: Any] = [:]
        if let content { choice["message"] = ["role": "assistant", "content": content] }
        if let finish { choice["finish_reason"] = finish }
        return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }

    @Test func finishedAnswerIsText() {
        #expect(LocalLLMServer.parseCompletion(response(content: "Привет.", finish: "stop")) == .text("Привет."))
    }

    /// Обрыв по лимиту не результат, даже если текст пришёл.
    @Test func lengthLimitIsTruncation() {
        #expect(LocalLLMServer.parseCompletion(response(content: "формировать две аут-сущ", finish: "length")) == .truncated)
    }

    /// Сервер без причины окончания: текст принимается, как и раньше.
    @Test func missingFinishReasonKeepsText() {
        #expect(LocalLLMServer.parseCompletion(response(content: "Привет.", finish: nil)) == .text("Привет."))
    }

    @Test func malformedAnswerFails() {
        #expect(LocalLLMServer.parseCompletion(Data("{}".utf8)) == .failed)
        #expect(LocalLLMServer.parseCompletion(response(content: nil, finish: "stop")) == .failed)
    }

    /// Лимит покрывает самый длинный кусок с запасом: речь до 1200 знаков идёт одним
    /// запросом, а ответ в 1026 знаков gemma уложила ровно в 256 токенов.
    @Test func limitCoversTheLongestPiece() {
        #expect(LocalLLMServer.maxTokens >= 4 * 256)
    }

    /// Обрезанный кусок откатывается на свой текст с причиной, а не проходит молча.
    @Test func truncatedPieceFallsBackWithReason() async {
        let input = "ну короче давай перенесём встречу на четверг"
        let result = await ThoughtSynthesizer.shared.clean(
            input, level: .clean, targetBundleId: nil, firedSpellings: [], language: .ru,
            backend: StubBackend(error: .truncated)
        )
        #expect(result.text == ThoughtSynthesizer.stageOne(input))
        guard case .rejected(let reason) = result.fallback else {
            Issue.record("обрыв не стал отказом: \(String(describing: result.fallback))"); return
        }
        #expect(reason.contains("обрезан"))
    }

    @Test func truncationDescribesItselfForTheLog() {
        #expect(CleanupBackendError.truncated.logDescription == "ответ обрезан по лимиту длины")
    }
}
