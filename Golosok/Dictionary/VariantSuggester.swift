import Foundation

/// Языковая модель для подсказок вариантов. Возвращает nil при любом сбое.
protocol VariantLLM {
    func complete(system: String, user: String) async -> String?
}

/// Автоподбор вариантов произношения по написанию: транслитерация сразу, модель по возможности.
struct VariantSuggester {
    static let llmTimeout: TimeInterval = 6
    static let maxPerLanguage = 5

    static let systemPrompt = """
    You help a speech dictation app. The user gives one word or name as typed. \
    Reply with a strict JSON object and nothing else: {"ru":[...],"en":[...]}. \
    "ru": how Russian speakers pronounce it and how a Russian speech recognizer might write it, in lowercase Cyrillic. \
    "en": how English speakers pronounce it and how an English speech recognizer might write it, in lowercase Latin letters. \
    Up to 3 items per list, each 1 to 3 words, no punctuation, no explanations.
    """

    let checker: CommonWordChecking
    let llm: VariantLLM?

    init(checker: CommonWordChecking, llm: VariantLLM?) {
        self.checker = checker
        self.llm = llm
    }

    func instant(for spelling: String) -> [DictionaryLanguage: [String]] {
        let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isASCII && $0.isLetter }),
              !VariantRules.hasCyrillic(trimmed) else { return [:] }
        let ru = Phonetics.transliterateToCyrillic(trimmed)
        let filtered = filter([ru], spelling: trimmed, language: .ru)
        return filtered.isEmpty ? [:] : [.ru: filtered]
    }

    func suggest(for spelling: String) async -> [DictionaryLanguage: [String]] {
        let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = instant(for: trimmed)
        guard !trimmed.isEmpty, let llm, let reply = await llm.complete(system: Self.systemPrompt, user: trimmed),
              let parsed = Self.parse(reply) else { return result }
        let hasCyrillic = VariantRules.hasCyrillic(trimmed)
        for language in DictionaryLanguage.allCases {
            // Кириллическое написание: латинские варианты не нужны.
            if hasCyrillic, language == .en { result[.en] = nil; continue }
            let merged = filter((result[language] ?? []) + (parsed[language] ?? []), spelling: trimmed, language: language)
            if merged.isEmpty { result[language] = nil } else { result[language] = merged }
        }
        return result
    }

    private func filter(_ raw: [String], spelling: String, language: DictionaryLanguage) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            guard let variant = VariantRules.accepted(item, spelling: spelling, language: language, checker: checker),
                  seen.insert(variant).inserted else { continue }
            out.append(variant)
            if out.count == Self.maxPerLanguage { break }
        }
        return out
    }

    /// Строгий JSON `{"ru":[…],"en":[…]}`; допускается обёртка из кодового блока. Иначе nil.
    static func parse(_ reply: String) -> [DictionaryLanguage: [String]]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [DictionaryLanguage: [String]] = [:]
        for language in DictionaryLanguage.allCases {
            if let list = object[language.rawValue] as? [Any] {
                result[language] = list.compactMap { $0 as? String }
            }
        }
        return result
    }

    /// Модель для подсказок или nil. Ничего не загружает и не прогревает.
    static func currentLLM() -> VariantLLM? {
        let settings = VoiceIntelligenceSettings.shared
        switch settings.engine {
        case .airGapped:
            guard let model = SLMModelStore.shared.model(named: settings.localModel),
                  SLMModelStore.shared.isModelDownloaded(model) else { return nil }
            let path = SLMModelStore.shared.localFileURL(for: model).path
            guard LocalLLMServer.shared.isReady(for: path) else { return nil }
            return LocalVariantLLM(modelPath: path)
        case .external:
            guard AIProviderStore.shared.isConfigured else { return nil }
            return ExternalVariantLLM(config: AIProviderStore.shared.config)
        }
    }
}

private struct LocalVariantLLM: VariantLLM {
    let modelPath: String

    func complete(system: String, user: String) async -> String? {
        await LocalLLMServer.shared.completeIfReady(system: system, user: user, modelPath: modelPath, timeout: VariantSuggester.llmTimeout)
    }
}

private struct ExternalVariantLLM: VariantLLM {
    let config: AIProviderConfig

    func complete(system: String, user: String) async -> String? {
        await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            AIService.shared.chat(
                messages: [AIChatMessage(role: "system", content: system), AIChatMessage(role: "user", content: user)],
                using: config
            ) { result in
                if case .success(let text) = result { once.resume(text) } else { once.resume(nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + VariantSuggester.llmTimeout) { once.resume(nil) }
        }
    }
}

private final class OnceResume {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
