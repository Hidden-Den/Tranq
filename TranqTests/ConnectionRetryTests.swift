import Testing
import Foundation
@testable import Tranq

/// Подмена сети с разным ответом на каждый запрос: нужна повторной попытке.
/// Считает запросы, чтобы было видно, что повтор один, а не цикл.
final class FlakySSEStubProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        /// Соединение потеряно: так ведёт себя мёртвое соединение из пула, код -1005.
        case lostConnection
        case status(Int)
        case stream(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcomes: [Outcome] = []
    nonisolated(unsafe) private static var served = 0

    /// Задаёт ответы по порядку. Последний повторяется, если запросов будет больше.
    static func serve(_ outcomes: [Outcome]) {
        lock.lock(); Self.outcomes = outcomes; served = 0; lock.unlock()
    }

    static var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    private static func next() -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let outcome = outcomes[min(served, outcomes.count - 1)]
        served += 1
        return outcome
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "flaky.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.next() {
        case .lostConnection:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .status(let code):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .stream(let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Потеря соединения: соединение из пула умирает, пока человек говорит.
/// Замер 20.11.2026: прогрев открывал соединение на старте записи, запрос уходил через
/// 108 с простоя и получал -1005. Прогрев убран, но шлюз может закрыть соединение и сам,
/// поэтому одна повторная попытка остаётся: она берёт живое соединение.
@Suite(.serialized)
struct ConnectionRetryTests {
    private let answer = """
    data: {"choices":[{"delta":{"content":"Привет"}}]}
    data: [DONE]

    """

    private func backend() -> ExternalBackend {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [FlakySSEStubProtocol.self]
        let config = AIProviderConfig(baseURL: "https://flaky.test/v1", apiKey: "k", model: "m", providerID: "openrouter")
        return ExternalBackend(config: config, session: URLSession(configuration: sessionConfig))
    }

    private func complete() async throws -> String {
        try await backend().complete(
            system: "промпт", user: "привет мир",
            deadlines: CleanupDeadlines(firstToken: 60, idle: 60, total: 60)
        )
    }

    /// Мёртвое соединение отдаёт ответ со второй попытки, человек этого не замечает.
    @Test func lostConnectionIsRetried() async throws {
        FlakySSEStubProtocol.serve([.lostConnection, .stream(answer)])
        let text = try await complete()
        #expect(text == "Привет")
        #expect(FlakySSEStubProtocol.requests == 2)
    }

    /// Повтор один: сеть действительно лежит, и очистка отступает, а не долбит шлюз.
    @Test func lostConnectionTwiceGivesUp() async throws {
        FlakySSEStubProtocol.serve([.lostConnection])
        await #expect(throws: CleanupBackendError.connectionLost) { try await complete() }
        #expect(FlakySSEStubProtocol.requests == 2)
    }

    /// Отказ шлюза это не потеря соединения: повторять его бессмысленно.
    @Test func gatewayRefusalIsNotRetried() async throws {
        FlakySSEStubProtocol.serve([.status(500)])
        await #expect(throws: CleanupBackendError.http(500)) { try await complete() }
        #expect(FlakySSEStubProtocol.requests == 1)
    }

    /// Для человека это та же недоступность провайдера: отдельной причины отката не появилось.
    @Test func lostConnectionReadsAsProviderUnavailable() async {
        let result = await ThoughtSynthesizer.shared.clean(
            "ну короче давай перенесём встречу на четверг", level: .clean,
            targetBundleId: nil, firedSpellings: [], language: .ru,
            backend: StubBackend(error: .connectionLost)
        )
        #expect(result.fallback == .providerUnavailable)
    }

    /// Журнал называет потерю соединения своими словами, а не общим «нет соединения».
    @Test func lostConnectionDescribesItselfForTheLog() {
        #expect(CleanupBackendError.connectionLost.logDescription == "соединение потеряно")
    }
}
