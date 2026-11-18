import Testing
import Foundation
@testable import Tranq

/// Замеры на боевом пути очистки: каждый вызов бэкенда даёт запись, короткие фразы и уровень A не дают.
@MainActor
struct CleanupTelemetryPipelineTests {
    private let phrase = "ну короче давай перенесём встречу на четверг"

    private func makeStore() -> CleanupTelemetry {
        CleanupTelemetry(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json"))
    }

    private func clean(_ text: String, level: CleanupLevel = .clean, backend: CleanupBackend, store: CleanupTelemetry) async {
        _ = await ThoughtSynthesizer.shared.clean(
            text, level: level, targetBundleId: nil, firedSpellings: [], language: .ru,
            backend: backend, telemetry: store
        )
    }

    @Test func successfulCleanupIsRecorded() async {
        let store = makeStore()
        await clean(phrase, backend: StubBackend(reply: "Давай перенесём встречу на четверг"), store: store)
        #expect(store.records.count == 1)
        #expect(store.records.first?.outcome == .success)
        #expect(store.records.first?.model == "StubBackend")
    }

    @Test func timeoutIsRecordedAsFailure() async {
        let store = makeStore()
        await clean(phrase, backend: StubBackend(error: .timeout), store: store)
        #expect(store.records.first?.outcome == .timeout)
        #expect(store.totals["StubBackend"]?.failures == 1)
    }

    @Test func otherBackendErrorsAreRecordedAsError() async {
        let store = makeStore()
        await clean(phrase, backend: StubBackend(error: .http(500)), store: store)
        #expect(store.records.first?.outcome == .error)
    }

    @Test func backendWithoutTokensRecordsZeroAndNotEstimated() async {
        let store = makeStore()
        await clean(phrase, backend: StubBackend(reply: "Давай перенесём встречу на четверг"), store: store)
        let totals = store.totals["StubBackend"]
        #expect(totals?.inputTokens == 0)
        #expect(totals?.outputTokens == 0)
        #expect(store.records.first?.estimated == false)
    }

    @Test func shortPhraseAndVerbatimMakeNoRecord() async {
        let store = makeStore()
        await clean("эээ", backend: StubBackend(reply: "x"), store: store)
        await clean(phrase, level: .verbatim, backend: StubBackend(reply: "x"), store: store)
        #expect(store.records.isEmpty)
    }
}
