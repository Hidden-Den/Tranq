import Testing
import Foundation
@testable import Golosok

/// Асинхронный API очистки: уровни, подмена модели и причины отката.
struct CleanupAPITests {
    private func clean(_ text: String, level: CleanupLevel, backend: CleanupBackend) async -> CleanupResult {
        await ThoughtSynthesizer.shared.clean(
            text, level: level, targetBundleId: nil, firedSpellings: [], language: .ru, backend: backend
        )
    }

    @Test func verbatimNeverCallsBackend() async {
        let stub = StubBackend(reply: "x")
        let input = "ну эээ давай перенесём встречу на четверг"
        let result = await clean(input, level: .verbatim, backend: stub)
        #expect(stub.calls == 0)
        #expect(result.text == ThoughtSynthesizer.stageOne(input))
        #expect(result.fallback == nil)
    }

    @Test func emptyOrThinkOnlyReplyFallsBackToStageOne() async {
        let input = "ну короче давай перенесём встречу на четверг"
        for reply in ["", "   ", "<think>рассуждаю</think>"] {
            let result = await clean(input, level: .clean, backend: StubBackend(reply: reply))
            #expect(result == CleanupResult(text: ThoughtSynthesizer.stageOne(input), fallback: .emptyResponse))
        }
    }

    @Test func backendErrorsMapToReasons() async {
        let input = "ну короче давай перенесём встречу на четверг"
        let cases: [(CleanupBackendError, FallbackReason)] = [
            (.unavailable, .providerUnavailable), (.http(500), .providerError(500)), (.http(401), .providerError(401)), (.timeout, .timeout),
        ]
        for (error, reason) in cases {
            let result = await clean(input, level: .clean, backend: StubBackend(error: error))
            #expect(result.fallback == reason)
            #expect(result.text == ThoughtSynthesizer.stageOne(input))
        }
    }

    @Test func backendErrorsDescribeThemselvesForTheLog() {
        #expect(CleanupBackendError.http(401).logDescription == "HTTP 401")
        #expect(CleanupBackendError.timeout.logDescription == "таймаут")
        #expect(CleanupBackendError.unavailable.logDescription == "нет соединения")
        #expect(CleanupBackendError.empty.logDescription == "пустой ответ")
    }

    @Test func shortPhraseSkipsBackend() async {
        let stub = StubBackend(reply: "x")
        let result = await clean("ну БТИ", level: .clean, backend: stub)
        #expect(stub.calls == 0)
        #expect(result.fallback == .shortPhrase)
    }

    @Test func validReplyIsReturnedWithoutFallback() async {
        let input = "ну короче давай перенесём встречу на четверг"
        let result = await clean(input, level: .clean, backend: StubBackend(reply: "Давай перенесём встречу на четверг"))
        #expect(result == CleanupResult(text: "Давай перенесём встречу на четверг", fallback: nil))
    }
}
