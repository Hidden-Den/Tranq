import Foundation
@testable import Golosok

struct EvalCase: Codable, Equatable {
    let id: String
    let category: String
    let raw: String
    let expected: String
}

struct EvalRun {
    let evalCase: EvalCase
    let result: CleanupResult
    let seconds: Double
}

struct EvalSummary: Equatable {
    let total: Int
    /// Доля ответов модели, принятых проверкой, без коротких фраз.
    let acceptedShare: Double
    /// Доля случаев, где все числа речи есть в результате.
    let numbersKeptShare: Double
    /// Доля случаев, где все латинские слова речи есть в результате.
    let latinKeptShare: Double
    /// Медиана отношения слов результата к словам речи.
    let medianCompression: Double
    let p50: Double
    let p95: Double
}

enum CleanupEvalError: Error {
    case noBackend
    case serverNotReady
}

enum CleanupEval {
    static func summarize(_ runs: [EvalRun]) -> EvalSummary {
        guard !runs.isEmpty else {
            return EvalSummary(total: 0, acceptedShare: 0, numbersKeptShare: 0, latinKeptShare: 0,
                               medianCompression: 0, p50: 0, p95: 0)
        }
        let total = Double(runs.count)
        // Короткие фразы не доходят до модели, их принятие или отказ ничего не измеряет
        let modelRuns = runs.filter { $0.result.fallback != .shortPhrase }
        let accepted = modelRuns.filter { $0.result.fallback == nil }.count
        // Речь распознавателя пишет числа словами, поэтому числа берутся после нормализации
        let numbersKept = runs.filter { kept(numbers(in: ThoughtSynthesizer.stageOne($0.evalCase.raw)), in: $0.result.text) }.count
        let latinKept = runs.filter { kept(latinWords(in: $0.evalCase.raw), in: $0.result.text) }.count
        let compressions = runs.map { run -> Double in
            let rawWords = max(1, wordCount(run.evalCase.raw))
            return Double(wordCount(run.result.text)) / Double(rawWords)
        }
        let seconds = runs.map(\.seconds)
        return EvalSummary(
            total: runs.count,
            acceptedShare: modelRuns.isEmpty ? 0 : Double(accepted) / Double(modelRuns.count),
            numbersKeptShare: Double(numbersKept) / total,
            latinKeptShare: Double(latinKept) / total,
            medianCompression: median(compressions),
            p50: percentile(seconds, 0.5),
            p95: percentile(seconds, 0.95)
        )
    }

    /// Отчёт в Markdown: сводка и таблица с пустой колонкой для ручной оценки.
    static func report(_ runs: [EvalRun], summary: EvalSummary, label: String) -> String {
        func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        var lines = [
            "# Замер очистки: \(label)",
            "",
            "- Случаев: \(summary.total)",
            "- Принято проверкой: \(pct(summary.acceptedShare))",
            "- Числа сохранены: \(pct(summary.numbersKeptShare))",
            "- Латиница сохранена: \(pct(summary.latinKeptShare))",
            String(format: "- Медиана сжатия: %.2f", summary.medianCompression),
            String(format: "- Время ответа: медиана %.2f с, 95-й перцентиль %.2f с", summary.p50, summary.p95),
            "",
            "| id | Категория | Речь | Эталон | Результат | Откат | Секунды | Оценка |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for run in runs {
            let cells = [
                run.evalCase.id, run.evalCase.category, run.evalCase.raw, run.evalCase.expected,
                run.result.text, run.result.fallback.map { "\($0)" } ?? "нет",
                String(format: "%.2f", run.seconds), "",
            ]
            lines.append("| " + cells.map(escape).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func reportFileName(label: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let safe = label.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return "report-\(safe)-\(formatter.string(from: date)).md"
    }

    static func loadCases(from url: URL) throws -> [EvalCase] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(EvalCase.self, from: Data($0.utf8)) }
    }

    /// Исполнитель из переменных окружения: локальная модель или внешний API.
    static func backendFromEnvironment(_ env: [String: String]) throws -> (CleanupBackend, String) {
        if let path = env["GOLOSOK_EVAL_LOCAL_MODEL"], !path.isEmpty {
            return (LocalBackend(modelPath: path), URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }
        guard let base = env["GOLOSOK_EVAL_BASE_URL"], let model = env["GOLOSOK_EVAL_MODEL"] else {
            throw CleanupEvalError.noBackend
        }
        let config = AIProviderConfig(
            baseURL: base, apiKey: env["GOLOSOK_EVAL_KEY"] ?? "", model: model,
            providerID: env["GOLOSOK_EVAL_PROVIDER"] ?? "openai"
        )
        return (ExternalBackend(config: config), model)
    }

    /// Модели каталога работают только через llama-server: до первой фразы сервер должен загрузить модель,
    /// иначе весь прогон откатится на уровень A. Внешнему API ждать нечего.
    static func waitForLocalServer(_ env: [String: String], timeout: TimeInterval = 180) async throws {
        guard let path = env["GOLOSOK_EVAL_LOCAL_MODEL"], !path.isEmpty, LocalLLMServer.isAvailable else { return }
        LocalLLMServer.shared.prewarm(modelPath: path)
        let deadline = Date().addingTimeInterval(timeout)
        while !LocalLLMServer.shared.isReady(for: path) {
            guard Date() < deadline else { throw CleanupEvalError.serverNotReady }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Вспомогательное

    private static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func numbers(in text: String) -> Set<String> {
        matches(of: #"(?<![\d.,])\d+(?:[.,]\d+)?(?![\d.,])"#, in: text)
    }

    private static func latinWords(in text: String) -> Set<String> {
        Set(matches(of: #"\b[A-Za-z][A-Za-z0-9_-]*\b"#, in: text).map { $0.lowercased() })
    }

    private static func kept(_ tokens: Set<String>, in output: String) -> Bool {
        guard !tokens.isEmpty else { return true }
        let outputTokens = numbers(in: output).union(latinWords(in: output))
        return tokens.allSatisfy { outputTokens.contains($0) }
    }

    private static func matches(of pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Ближайший ранг: значение с номером ceil(q * n).
    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}
