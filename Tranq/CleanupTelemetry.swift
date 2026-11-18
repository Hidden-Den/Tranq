import Foundation

/// Чем закончился запрос к модели очистки.
enum TelemetryOutcome: String, Codable {
    case success, timeout, error
}

/// Один запрос к модели очистки.
struct TelemetryRecord: Codable, Equatable {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// Токены посчитаны по символам, а не взяты у провайдера.
    let estimated: Bool
    /// Пусто, если запрос оборвался до первого токена.
    let firstTokenSeconds: Double?
    let totalSeconds: Double
    let outcome: TelemetryOutcome
    let date: Date
}

/// Накопительные итоги по одной модели. Живут дольше окна последних записей.
struct ModelTotals: Codable, Equatable {
    var requests: Int
    var failures: Int
    var inputTokens: Int
    var outputTokens: Int
    /// Сколько запросов посчитано по символам, а не взято у провайдера: итоги с оценками нельзя выдавать за точные.
    var estimatedRequests: Int = 0

    init(requests: Int, failures: Int, inputTokens: Int, outputTokens: Int, estimatedRequests: Int = 0) {
        self.requests = requests
        self.failures = failures
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedRequests = estimatedRequests
    }

    /// Файл, записанный до появления счётчика оценок, читается как есть.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decode(Int.self, forKey: .requests)
        failures = try c.decode(Int.self, forKey: .failures)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        estimatedRequests = try c.decodeIfPresent(Int.self, forKey: .estimatedRequests) ?? 0
    }
}

/// Телеметрия очистки: расход токенов, задержки и исходы. Данные остаются на машине.
///
/// Открытая попытка одна: `begin` открывает её, `noteFirstToken` и `noteUsage` дополняют из потока,
/// `finish` закрывает записью. Две очистки одновременно, например быстрая вторая диктовка при медленном API,
/// смешают записи: пострадают только цифры телеметрии, сама диктовка не затрагивается.
@MainActor
final class CleanupTelemetry: ObservableObject {
    static let shared = CleanupTelemetry()
    static let maxRecords = 50

    @Published private(set) var totals: [String: ModelTotals] = [:]
    /// Последние `maxRecords` запросов, новые в начале.
    @Published private(set) var records: [TelemetryRecord] = []

    private struct Attempt {
        let model: String
        var firstTokenSeconds: Double?
        var inputTokens = 0
        var outputTokens = 0
        var estimated = false
    }

    private struct Snapshot: Codable {
        var totals: [String: ModelTotals]
        var records: [TelemetryRecord]
    }

    private var attempt: Attempt?
    private let storeURL: URL

    init(storeURL: URL = AppEnvironment.dataDirectory.appendingPathComponent("telemetry.json")) {
        self.storeURL = storeURL
        load()
    }

    func begin(model: String) {
        attempt = Attempt(model: model)
    }

    func noteFirstToken(seconds: Double) {
        guard attempt != nil, attempt?.firstTokenSeconds == nil else { return }
        attempt?.firstTokenSeconds = seconds
    }

    func noteUsage(input: Int?, output: Int?, estimated: Bool) {
        guard attempt != nil else { return }
        attempt?.inputTokens = input ?? 0
        attempt?.outputTokens = output ?? 0
        attempt?.estimated = estimated
    }

    func finish(outcome: TelemetryOutcome, totalSeconds: Double) {
        guard let done = attempt else { return }
        attempt = nil
        let record = TelemetryRecord(
            model: done.model,
            inputTokens: done.inputTokens,
            outputTokens: done.outputTokens,
            estimated: done.estimated,
            firstTokenSeconds: done.firstTokenSeconds,
            totalSeconds: totalSeconds,
            outcome: outcome,
            date: Date()
        )
        records.insert(record, at: 0)
        if records.count > Self.maxRecords { records.removeLast(records.count - Self.maxRecords) }

        var entry = totals[done.model] ?? ModelTotals(requests: 0, failures: 0, inputTokens: 0, outputTokens: 0)
        entry.requests += 1
        if outcome != .success { entry.failures += 1 }
        entry.inputTokens += done.inputTokens
        entry.outputTokens += done.outputTokens
        if done.estimated { entry.estimatedRequests += 1 }
        totals[done.model] = entry
        save()
    }

    func reset() {
        totals = [:]
        records = []
        save()
    }

    /// Среднее время до первого токена по записям модели, где токен был.
    func averageFirstToken(model: String) -> Double? {
        mean(records.filter { $0.model == model }.compactMap(\.firstTokenSeconds))
    }

    /// Среднее полное время успешных ответов модели: оборванные запросы считаются отдельно, в отказах.
    func averageTotal(model: String) -> Double? {
        mean(records.filter { $0.model == model && $0.outcome == .success }.map(\.totalSeconds))
    }

    /// Грубая оценка по символам, когда провайдер не прислал расход: русский текст в среднем три символа на токен.
    nonisolated static func estimateTokens(_ text: String) -> Int {
        (text.count + 2) / 3
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        totals = snapshot.totals
        records = Array(snapshot.records.prefix(Self.maxRecords))
    }

    private func save() {
        let snapshot = Snapshot(totals: totals, records: records)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
