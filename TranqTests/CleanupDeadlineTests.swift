import Testing
import Foundation
@testable import Tranq

/// Подмена сети без сна в потоке: отдаёт куски отложенными задачами.
/// Спящий поток занимает место в общем пуле, и соседние наборы с сетью начинают голодать.
final class SlowSSEStubProtocol: URLProtocol, @unchecked Sendable {
    struct Chunk {
        let delay: TimeInterval
        let line: String
    }

    nonisolated(unsafe) static var chunks: [Chunk] = []

    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "slow.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let queue = DispatchQueue(label: "slow-sse-stub")
        var at: TimeInterval = 0
        for chunk in Self.chunks {
            at += chunk.delay
            queue.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: Data((chunk.line + "\n\n").utf8))
            }
        }
        queue.asyncAfter(deadline: .now() + at + 0.01) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

/// Сроки обращения к модели: расчёт, таблица решений наблюдателя и один живой поток.
/// Решения проверяются чистой функцией, без таймеров: сюита идёт вместе с остальными,
/// и проверки на секундомер падали бы от чужой нагрузки, а не от ошибки в коде.
struct CleanupDeadlineTests {

    // MARK: - Решения наблюдателя

    private let deadlines = CleanupDeadlines(firstToken: 10, idle: 4, total: 30)

    /// Ответ ещё не начался, ожидание начала не вышло: ждём.
    @Test func quietStartWithinItsBudgetWaits() {
        #expect(ExternalBackend.verdict(elapsed: 6, sinceLastChunk: nil, deadlines: deadlines) == .wait)
    }

    /// Самое главное: до первого куска срок простоя не применяется. Прежний плоский таймаут
    /// обрывал на этом месте шлюз, который разогревался дольше него, вместе с готовым ответом.
    @Test func idleBudgetDoesNotApplyBeforeTheAnswerStarts() {
        #expect(ExternalBackend.verdict(elapsed: 9, sinceLastChunk: nil, deadlines: deadlines) == .wait)
    }

    /// Шлюз молчит дольше отведённого на начало: обрыв.
    @Test func silentStartIsCut() {
        #expect(ExternalBackend.verdict(elapsed: 11, sinceLastChunk: nil, deadlines: deadlines) == .cut(.noStart))
    }

    /// Поток идёт, пауза между куском и куском в пределах срока: ждём.
    @Test func steadyStreamWaits() {
        #expect(ExternalBackend.verdict(elapsed: 12, sinceLastChunk: 0.8, deadlines: deadlines) == .wait)
    }

    /// Ожидание начала после начала не применяется: длинный ответ идёт сколько нужно.
    @Test func firstTokenBudgetDoesNotApplyAfterTheAnswerStarted() {
        #expect(ExternalBackend.verdict(elapsed: 25, sinceLastChunk: 1.0, deadlines: deadlines) == .wait)
    }

    /// Поток застыл на середине: обрыв по простою, не дожидаясь потолка.
    @Test func stalledStreamIsCut() {
        #expect(ExternalBackend.verdict(elapsed: 12, sinceLastChunk: 5, deadlines: deadlines) == .cut(.stalled))
    }

    /// Ответ не кончается: потолок обрывает его даже при живом потоке.
    @Test func endlessStreamIsCutByTheCeiling() {
        #expect(ExternalBackend.verdict(elapsed: 31, sinceLastChunk: 0.1, deadlines: deadlines) == .cut(.ceiling))
    }

    // MARK: - Живой поток

    /// Проводка целиком: сроки доходят до чтения потока, и ответ возвращается.
    @Test func streamWithinItsDeadlinesIsReturned() async throws {
        SlowSSEStubProtocol.chunks = [
            .init(delay: 0.1, line: #"data: {"choices":[{"delta":{"content":"Привет"}}]}"#),
            .init(delay: 0.01, line: "data: [DONE]"),
        ]
        // Своя сессия вместо общей регистрации URLProtocol: та глобальна на процесс
        // и ломает соседние наборы, которые тоже подменяют сеть.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [SlowSSEStubProtocol.self]
        let config = AIProviderConfig(baseURL: "https://slow.test/v1", apiKey: "k", model: "m", providerID: "openrouter")
        let text = try await ExternalBackend(config: config, session: URLSession(configuration: sessionConfig))
            .complete(system: "промпт", user: "привет мир", deadlines: CleanupDeadlines(firstToken: 60, idle: 60, total: 60))
        #expect(text == "Привет")
    }

    // MARK: - Расчёт сроков

    /// Замер OpenRouter 20.11.2026, haiku 5.5, одиннадцать прогонов: первый токен 0,84–5,46 с,
    /// простой между куском и куском до 0,75 с. Сроки обязаны покрывать этот разброс,
    /// иначе каждая десятая диктовка теряет очистку.
    @Test func externalDeadlinesCoverTheMeasuredSpread() {
        let deadlines = CleanupDeadlines.external(characters: 1163, setting: 6)
        #expect(deadlines.firstToken >= 8)
        #expect(deadlines.idle >= 3)
        #expect(deadlines.total >= deadlines.firstToken + 4)
    }

    /// Потолок растёт от объёма речи: длинной диктовке нужно больше генерации, чем короткой фразе.
    @Test func externalTotalGrowsWithTheTranscript() {
        let short = CleanupDeadlines.external(characters: 40, setting: 6)
        let long = CleanupDeadlines.external(characters: 1163, setting: 6)
        #expect(long.total > short.total + 5)
    }

    /// Настройка остаётся нижней границей: поднял её человек, поднялись все сроки.
    @Test func settingRaisesEveryDeadline() {
        let deadlines = CleanupDeadlines.external(characters: 40, setting: 30)
        #expect(deadlines.firstToken >= 30)
        #expect(deadlines.total >= 30)
    }

    /// Локальная модель живёт по прежнему одному сроку: без замеров её поведение не меняется.
    @Test func localKeepsTheSingleBudget() {
        #expect(CleanupDeadlines.local(setting: 6).total == 6)
        #expect(CleanupDeadlines.local(setting: 2).total == 6)
        #expect(CleanupDeadlines.local(setting: 25).total == 25)
    }
}
