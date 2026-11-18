import Testing
import Foundation
@testable import Tranq

/// Запрос просит у провайдера расход токенов: поток без этого их не присылает.
struct ChatRequestBuilderUsageTests {
    private func body(_ config: AIProviderConfig) throws -> [String: Any] {
        let request = try ChatRequestBuilder.streamRequest(config: config, system: "s", user: "u")
        return try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any] ?? [:]
    }

    @Test func openAIFormatAsksForUsage() throws {
        let config = AIProviderConfig(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-6-luna", providerID: "openai")
        let options = try body(config)["stream_options"] as? [String: Any]
        #expect(options?["include_usage"] as? Bool == true)
    }

    @Test func openRouterAsksForUsage() throws {
        let config = AIProviderConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "k", model: "deepseek/deepseek-v4", providerID: "openrouter")
        let usage = try body(config)["usage"] as? [String: Any]
        #expect(usage?["include"] as? Bool == true)
    }

    @Test func anthropicSendsNoUsageField() throws {
        let config = AIProviderConfig(baseURL: "https://api.anthropic.com", apiKey: "k", model: "claude-opus-5", providerID: "anthropic")
        let dict = try body(config)
        #expect(dict["stream_options"] == nil)
        #expect(dict["usage"] == nil)
    }
}
