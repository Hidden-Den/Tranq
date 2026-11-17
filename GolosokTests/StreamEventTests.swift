import Testing
import Foundation
@testable import Golosok

/// Разбор строк потока ответа провайдера: текст, конец и ошибка посреди потока.
struct StreamEventTests {
    @Test func openAIChunkGivesText() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[{"delta":{"content":"при"}}]}"#) == .text("при"))
    }

    @Test func anthropicDeltaGivesText() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"вет"}}"#) == .text("вет"))
    }

    @Test func endMarkers() {
        #expect(ExternalBackend.parseStreamLine("data: [DONE]") == .done)
        #expect(ExternalBackend.parseStreamLine(#"data: {"type":"message_stop"}"#) == .done)
    }

    @Test func errorsInsideTheStreamAreFailures() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"type":"error","error":{"type":"overloaded_error"}}"#) == .failure)
        #expect(ExternalBackend.parseStreamLine(#"data: {"error":{"message":"rate limit"}}"#) == .failure)
    }

    @Test func serviceLinesAreSkipped() {
        #expect(ExternalBackend.parseStreamLine(": keep-alive") == .skip)
        #expect(ExternalBackend.parseStreamLine("event: ping") == .skip)
        #expect(ExternalBackend.parseStreamLine("data: не json") == .skip)
        #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[{"delta":{}}]}"#) == .skip)
    }
}
