import Testing
import Foundation
@testable import Tranq

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

    @Test func openAIFinalChunkGivesUsage() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":48}}"#) == .usage(input: 120, output: 48))
    }

    @Test func anthropicStartGivesInputTokens() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"type":"message_start","message":{"usage":{"input_tokens":120,"output_tokens":1}}}"#) == .usage(input: 120, output: 1))
    }

    @Test func anthropicDeltaGivesOutputTokensOnly() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"type":"message_delta","usage":{"output_tokens":48}}"#) == .usage(input: nil, output: 48))
    }

    @Test func textChunkWithoutUsageStaysText() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[{"delta":{"content":"при"}}]}"#) == .text("при"))
    }

    @Test func chunkWithTextAndUsageKeepsTheText() {
        // Часть шлюзов шлёт usage в каждом куске: текст терять нельзя
        #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[{"delta":{"content":"при"}}],"usage":{"prompt_tokens":120,"completion_tokens":3}}"#) == .text("при"))
    }

    @Test func nullUsageIsSkipped() {
        #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[{"delta":{}}],"usage":null}"#) == .skip)
    }

    @Test func accumulatorKeepsFirstInputAndLastOutput() {
        var acc = UsageAccumulator()
        acc.apply(input: 120, output: 1)
        acc.apply(input: nil, output: 48)
        #expect(acc.input == 120)
        #expect(acc.output == 48)
    }

    @Test func accumulatorStaysEmptyWithoutUsage() {
        let acc = UsageAccumulator()
        #expect(acc.input == nil)
        #expect(acc.output == nil)
    }
}
