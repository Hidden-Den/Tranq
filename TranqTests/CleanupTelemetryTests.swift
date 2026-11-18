import Testing
import Foundation
@testable import Tranq

/// Хранилище телеметрии очистки: записи, итоги по моделям, средние и файл на диске.
@MainActor
struct CleanupTelemetryTests {
    private func makeStore(file: URL? = nil) -> CleanupTelemetry {
        CleanupTelemetry(storeURL: file ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json"))
    }

    @Test func estimateIsThreeCharactersPerToken() {
        #expect(CleanupTelemetry.estimateTokens("") == 0)
        #expect(CleanupTelemetry.estimateTokens("абв") == 1)
        #expect(CleanupTelemetry.estimateTokens("абвг") == 2)
    }

    @Test func finishedAttemptBecomesRecordAndTotals() {
        let t = makeStore()
        t.begin(model: "m")
        t.noteFirstToken(seconds: 0.5)
        t.noteUsage(input: 100, output: 40, estimated: false)
        t.finish(outcome: .success, totalSeconds: 2.0)
        #expect(t.records.count == 1)
        #expect(t.totals["m"] == ModelTotals(requests: 1, failures: 0, inputTokens: 100, outputTokens: 40))
        #expect(t.records.first?.estimated == false)
        #expect(t.records.first?.firstTokenSeconds == 0.5)
    }

    @Test func estimatedAttemptsAreCountedInTotals() {
        let t = makeStore()
        t.begin(model: "m"); t.noteUsage(input: 10, output: 5, estimated: true); t.finish(outcome: .success, totalSeconds: 1.0)
        t.begin(model: "m"); t.noteUsage(input: 10, output: 5, estimated: false); t.finish(outcome: .success, totalSeconds: 1.0)
        #expect(t.totals["m"]?.estimatedRequests == 1)
        #expect(t.totals["m"]?.requests == 2)
    }

    @Test func totalsFileWrittenBeforeEstimateCounterStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString).json")
        let old = #"{"totals":{"m":{"requests":3,"failures":1,"inputTokens":30,"outputTokens":9}},"records":[]}"#
        try Data(old.utf8).write(to: url)
        let t = makeStore(file: url)
        #expect(t.totals["m"] == ModelTotals(requests: 3, failures: 1, inputTokens: 30, outputTokens: 9))
    }

    @Test func failureCountsAsFailure() {
        let t = makeStore()
        t.begin(model: "m")
        t.finish(outcome: .timeout, totalSeconds: 3.0)
        #expect(t.totals["m"]?.failures == 1)
        #expect(t.records.first?.firstTokenSeconds == nil)
    }

    @Test func averageFirstTokenSkipsAttemptsWithoutToken() {
        let t = makeStore()
        t.begin(model: "m"); t.noteFirstToken(seconds: 1.0); t.finish(outcome: .success, totalSeconds: 2.0)
        t.begin(model: "m"); t.finish(outcome: .timeout, totalSeconds: 3.0)
        #expect(t.averageFirstToken(model: "m") == 1.0)
    }

    @Test func averageTotalCountsSuccessfulAttemptsOnly() {
        let t = makeStore()
        t.begin(model: "m"); t.finish(outcome: .success, totalSeconds: 2.0)
        t.begin(model: "m"); t.finish(outcome: .timeout, totalSeconds: 10.0)
        #expect(t.averageTotal(model: "m") == 2.0)
    }

    @Test func averagesIgnoreOtherModels() {
        let t = makeStore()
        t.begin(model: "a"); t.noteFirstToken(seconds: 1.0); t.finish(outcome: .success, totalSeconds: 2.0)
        t.begin(model: "b"); t.noteFirstToken(seconds: 5.0); t.finish(outcome: .success, totalSeconds: 9.0)
        #expect(t.averageFirstToken(model: "a") == 1.0)
        #expect(t.averageTotal(model: "a") == 2.0)
        #expect(t.averageTotal(model: "missing") == nil)
    }

    @Test func windowKeepsLastFifty() {
        let t = makeStore()
        for i in 0..<60 {
            t.begin(model: "m\(i)")
            t.finish(outcome: .success, totalSeconds: 1.0)
        }
        #expect(t.records.count == 50)
        #expect(t.records.first?.model == "m59")
        #expect(t.totals.count == 60)
    }

    @Test func brokenFileLeavesStoreEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString).json")
        try Data("не json".utf8).write(to: url)
        let t = makeStore(file: url)
        #expect(t.records.isEmpty)
        #expect(t.totals.isEmpty)
    }

    @Test func missingFileLeavesStoreEmpty() {
        let t = makeStore()
        #expect(t.records.isEmpty)
        #expect(t.totals.isEmpty)
    }

    @Test func dataSurvivesRestart() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString).json")
        let first = makeStore(file: url)
        first.begin(model: "m")
        first.noteUsage(input: 10, output: 5, estimated: true)
        first.finish(outcome: .success, totalSeconds: 1.5)
        let second = makeStore(file: url)
        #expect(second.records.count == 1)
        #expect(second.records.first?.estimated == true)
        #expect(second.totals["m"]?.inputTokens == 10)
    }

    @Test func finishWithoutBeginChangesNothing() {
        let t = makeStore()
        t.noteFirstToken(seconds: 1.0)
        t.noteUsage(input: 1, output: 1, estimated: false)
        t.finish(outcome: .success, totalSeconds: 1.0)
        #expect(t.records.isEmpty)
        #expect(t.totals.isEmpty)
    }

    @Test func resetClearsEverythingAndFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString).json")
        let t = makeStore(file: url)
        t.begin(model: "m"); t.finish(outcome: .success, totalSeconds: 1.0)
        t.reset()
        #expect(t.records.isEmpty)
        #expect(t.totals.isEmpty)
        #expect(makeStore(file: url).records.isEmpty)
    }
}
