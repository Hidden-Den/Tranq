import Testing
import Foundation
@testable import Tranq

/// Запросы к провайдерам: корпоративный шлюз не получает лишнего, формат определяется пресетом.
struct ProviderRequestTests {
    private let gateway = AIProviderConfig(baseURL: "https://llm.corp.local/v1", apiKey: "k", model: "m", providerID: "corporate")

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func corporateRequestIsPlainOpenAI() throws {
        let request = try ChatRequestBuilder.streamRequest(config: gateway, system: "s", user: "u")
        #expect(request.url?.absoluteString == "https://llm.corp.local/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
        let json = try body(request)
        #expect(json["stream"] as? Bool == true)
        #expect(json["reasoning"] == nil)
        #expect(json["provider"] == nil)
    }

    @Test func openRouterKeepsAttributionHeaders() throws {
        let config = AIProviderConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "k", model: "m", providerID: "openrouter")
        let request = try ChatRequestBuilder.streamRequest(config: config, system: "s", user: "u")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") != nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Tranq")
        #expect(try body(request)["reasoning"] != nil)
    }

    @Test func anthropicRequestUsesMessagesFormat() throws {
        let config = AIProviderConfig(baseURL: "https://api.anthropic.com/v1", apiKey: "k", model: "m", providerID: "anthropic")
        let request = try ChatRequestBuilder.streamRequest(config: config, system: "sys", user: "u")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let json = try body(request)
        #expect(json["system"] as? String == "sys")
    }

    @Test func rootBaseURLsGetVersionPrefix() throws {
        let openAI = AIProviderConfig(baseURL: "https://api.openai.com", apiKey: "k", model: "m", providerID: "openai")
        #expect(try ChatRequestBuilder.streamRequest(config: openAI, system: "s", user: "u").url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        let anthropic = AIProviderConfig(baseURL: "https://api.anthropic.com/", apiKey: "k", model: "m", providerID: "anthropic")
        #expect(try ChatRequestBuilder.streamRequest(config: anthropic, system: "s", user: "u").url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func anthropicFormatOnlyByPreset() {
        let proxy = AIProviderConfig(baseURL: "https://anthropic.com.proxy.corp/v1", apiKey: "k", model: "m", providerID: "corporate")
        #expect(proxy.isAnthropic == false)
    }

    @Test func openAIReasoningModelsRunWithoutReasoning() throws {
        let luna = AIProviderConfig(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-6-luna", providerID: "openai")
        #expect(try body(ChatRequestBuilder.streamRequest(config: luna, system: "s", user: "u"))["reasoning_effort"] as? String == "none")
        let classic = AIProviderConfig(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-4o-mini", providerID: "openai")
        #expect(try body(ChatRequestBuilder.streamRequest(config: classic, system: "s", user: "u"))["reasoning_effort"] == nil)
    }

    @Test func gatewayProxyingOpenAIReasoningModelsRunsWithoutReasoning() throws {
        for model in ["gpt-6-luna", "gpt-6.1-terra", "gpt-6-sol-2026-09-15", "GPT-6-Luna"] {
            let config = AIProviderConfig(baseURL: "https://llm.corp.local/v1", apiKey: "k", model: model, providerID: "corporate")
            #expect(try body(ChatRequestBuilder.streamRequest(config: config, system: "s", user: "u"))["reasoning_effort"] as? String == "none", "\(model)")
        }
        for model in ["gpt-6.1-sol", "gpt-6-astra", "gpt-4o-mini", "llama-3.3-70b"] {
            let config = AIProviderConfig(baseURL: "https://llm.corp.local/v1", apiKey: "k", model: model, providerID: "corporate")
            #expect(try body(ChatRequestBuilder.streamRequest(config: config, system: "s", user: "u"))["reasoning_effort"] == nil, "\(model)")
        }
    }

    @Test func anthropicAndOpenRouterNeverGetReasoningEffort() throws {
        let anthropic = AIProviderConfig(baseURL: "https://api.anthropic.com/v1", apiKey: "k", model: "gpt-6-luna", providerID: "anthropic")
        #expect(try body(ChatRequestBuilder.streamRequest(config: anthropic, system: "s", user: "u"))["reasoning_effort"] == nil)
        let router = AIProviderConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "k", model: "openai/gpt-6-luna", providerID: "openrouter")
        #expect(try body(ChatRequestBuilder.streamRequest(config: router, system: "s", user: "u"))["reasoning_effort"] == nil)
    }

    @Test func corporatePresetStartsUnconfigured() {
        let store = AIProviderStore.shared
        let saved = (store.providerID, store.baseURL, store.model)
        defer { (store.providerID, store.baseURL, store.model) = saved }
        let preset = AIProviderPresets.preset(id: "corporate")
        #expect(preset != nil)
        store.apply(preset!)
        #expect(store.isConfigured == false)
    }

    @Test func defaultModelsAreCurrent() {
        #expect(AIProviderPresets.preset(id: "anthropic")?.defaultModel == "claude-haiku-5-5")
        #expect(AIProviderPresets.preset(id: "openai")?.defaultModel == "gpt-6-luna")
    }

    @Test func legacyTimeoutMigratesToSix() {
        let name = "tranq.tests.timeout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(3.0, forKey: "voice.timeout")
        VoiceIntelligenceSettings.migrateLegacyTimeout(defaults)
        #expect(defaults.double(forKey: "voice.timeout") == 6.0)
        defaults.set(4.5, forKey: "voice.timeout")
        VoiceIntelligenceSettings.migrateLegacyTimeout(defaults)
        #expect(defaults.double(forKey: "voice.timeout") == 4.5)
        #expect(VoiceIntelligenceSettings.defaultTimeoutSeconds == 6.0)
    }
}
