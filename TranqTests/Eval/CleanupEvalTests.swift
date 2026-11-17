import Testing
import Foundation
@testable import Tranq

/// Замер качества очистки. Метрики считаются всегда; прогон по реальным моделям включается окружением.
struct CleanupEvalTests {
    private func makeCase(_ raw: String) -> EvalCase {
        EvalCase(id: raw, category: "x", raw: raw, expected: "")
    }

    @Test func summarizeComputesMetrics() {
        let runs = [
            EvalRun(evalCase: makeCase("встреча в 15 в CRM ну как бы"),
                    result: CleanupResult(text: "встреча в 15 в CRM", fallback: nil), seconds: 1),
            EvalRun(evalCase: makeCase("встреча в 16 ну как бы потом"),
                    result: CleanupResult(text: "встреча", fallback: .rejected("r")), seconds: 3),
        ]
        let summary = CleanupEval.summarize(runs)
        #expect(summary.total == 2)
        #expect(summary.acceptedShare == 0.5)
        #expect(summary.numbersKeptShare == 0.5)
        #expect(summary.latinKeptShare == 1.0)
        #expect(abs(summary.medianCompression - (5.0 / 8.0 + 1.0 / 7.0) / 2.0) < 0.001)
        #expect(summary.p50 == 1)
        #expect(summary.p95 == 3)
    }

    @Test func numbersAreComparedAfterNormalizingSpelledOutNumbers() {
        let kept = EvalRun(evalCase: makeCase("встреча в пятнадцать часов"),
                           result: CleanupResult(text: "встреча в 15 часов", fallback: nil), seconds: 1)
        let lost = EvalRun(evalCase: makeCase("встреча в пятнадцать часов"),
                           result: CleanupResult(text: "встреча в часов", fallback: nil), seconds: 1)
        #expect(CleanupEval.summarize([kept]).numbersKeptShare == 1.0)
        #expect(CleanupEval.summarize([lost]).numbersKeptShare == 0.0)
    }

    @Test func shortPhrasesAreNotCountedAgainstAcceptance() {
        let runs = [
            EvalRun(evalCase: makeCase("ну привет"), result: CleanupResult(text: "ну привет", fallback: .shortPhrase), seconds: 0.1),
            EvalRun(evalCase: makeCase("давай перенесём встречу на четверг"),
                    result: CleanupResult(text: "Давай перенесём встречу на четверг", fallback: nil), seconds: 1),
        ]
        let summary = CleanupEval.summarize(runs)
        #expect(summary.total == 2)
        #expect(summary.acceptedShare == 1.0)
    }

    @Test func summarizeOfNothingIsZero() {
        let summary = CleanupEval.summarize([])
        #expect(summary == EvalSummary(total: 0, acceptedShare: 0, numbersKeptShare: 0, latinKeptShare: 0,
                                       medianCompression: 0, p50: 0, p95: 0))
    }

    @Test func reportEscapesTableCells() {
        let runs = [EvalRun(evalCase: EvalCase(id: "a|b", category: "c", raw: "строка\nдве", expected: "э"),
                            result: CleanupResult(text: "итог", fallback: .timeout), seconds: 0.5)]
        let report = CleanupEval.report(runs, summary: CleanupEval.summarize(runs), label: "модель")
        #expect(report.contains("# Замер очистки: модель"))
        #expect(report.contains("a\\|b"))
        #expect(!report.contains("строка\nдве"))
        #expect(report.contains("timeout"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANQ_EVAL_DIR"] != nil))
    func liveEval() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: (env["TRANQ_EVAL_DIR"]! as NSString).expandingTildeInPath, isDirectory: true)
        let cases = try CleanupEval.loadCases(from: dir.appendingPathComponent("cases.jsonl"))
        let (backend, label) = try CleanupEval.backendFromEnvironment(env)
        try await CleanupEval.waitForLocalServer(env)

        // Словарь срабатывает до модели и после неё, как в TranscriptionPipeline. Чистый `apply`
        // не трогает счётчики срабатываний в словаре пользователя.
        DictionaryStore.shared.waitForIndex()
        let index = DictionaryStore.shared.index

        var runs: [EvalRun] = []
        for evalCase in cases {
            let started = Date()
            let dictionary = index?.apply(to: evalCase.raw, language: .ru)
            var fired: [String] = []
            for replacement in dictionary?.replacements ?? [] where !fired.contains(replacement.replacement) {
                fired.append(replacement.replacement)
            }
            let cleaned = await ThoughtSynthesizer.shared.clean(
                dictionary?.text ?? evalCase.raw, level: .clean, targetBundleId: nil,
                firedSpellings: fired, language: .ru, backend: backend
            )
            let text = index?.apply(
                to: cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines), language: .ru
            ).text ?? cleaned.text
            let result = CleanupResult(text: text, fallback: cleaned.fallback)
            runs.append(EvalRun(evalCase: evalCase, result: result, seconds: Date().timeIntervalSince(started)))
        }
        let summary = CleanupEval.summarize(runs)
        let report = CleanupEval.report(runs, summary: summary, label: label)
        let name = CleanupEval.reportFileName(label: label, date: Date())
        try report.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        #expect(summary.total == cases.count)
    }
}
