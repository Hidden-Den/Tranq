import Testing
import Foundation
@testable import Tranq

/// Подмена сети: отдаёт заранее заготовленный поток событий для адреса stub.test.
final class SSEStubProtocol: URLProtocol {
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Поток внешнего провайдера целиком: первый токен и расход попадают в телеметрию.
@Suite(.serialized)
@MainActor
struct ExternalBackendTelemetryTests {
    private func makeStore() -> CleanupTelemetry {
        CleanupTelemetry(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json"))
    }

    /// Прогоняет один ответ через настоящий разбор потока и возвращает закрытую запись.
    private func run(providerID: String, baseURL: String, stream: String) async throws -> (reply: String, record: TelemetryRecord) {
        URLProtocol.registerClass(SSEStubProtocol.self)
        defer { URLProtocol.unregisterClass(SSEStubProtocol.self) }
        SSEStubProtocol.body = stream
        let store = makeStore()
        let config = AIProviderConfig(baseURL: baseURL, apiKey: "k", model: "m", providerID: providerID)
        store.begin(model: "m")
        let reply = try await ExternalBackend(config: config, telemetry: store).complete(system: "системный промпт", user: "привет мир", timeout: 5)
        store.finish(outcome: .success, totalSeconds: 1)
        return (reply, try #require(store.records.first))
    }

    @Test func openAIStreamRecordsProviderUsage() async throws {
        let stream = """
        data: {"choices":[{"delta":{"content":"При"}}]}
        data: {"choices":[{"delta":{"content":"вет"}}]}
        data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":48}}
        data: [DONE]

        """
        let result = try await run(providerID: "openai", baseURL: "https://stub.test/v1", stream: stream)
        #expect(result.reply == "Привет")
        #expect(result.record.inputTokens == 120)
        #expect(result.record.outputTokens == 48)
        #expect(result.record.estimated == false)
        #expect(result.record.firstTokenSeconds != nil)
    }

    @Test func anthropicUsageIsNotCountedTwice() async throws {
        let stream = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":120,"output_tokens":1}}}
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Привет"}}
        data: {"type":"message_delta","usage":{"output_tokens":48}}
        data: {"type":"message_stop"}

        """
        let result = try await run(providerID: "anthropic", baseURL: "https://stub.test", stream: stream)
        #expect(result.reply == "Привет")
        #expect(result.record.inputTokens == 120)
        #expect(result.record.outputTokens == 48)
        #expect(result.record.estimated == false)
    }

    @Test func missingUsageFallsBackToMarkedEstimate() async throws {
        let stream = """
        data: {"choices":[{"delta":{"content":"Привет, мир"}}]}
        data: [DONE]

        """
        let result = try await run(providerID: "openai", baseURL: "https://stub.test/v1", stream: stream)
        #expect(result.record.estimated == true)
        #expect(result.record.inputTokens == CleanupTelemetry.estimateTokens("системный промпт" + "привет мир"))
        #expect(result.record.outputTokens == CleanupTelemetry.estimateTokens("Привет, мир"))
    }
}
