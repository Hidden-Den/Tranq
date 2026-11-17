import Foundation

public final class ThoughtSynthesizer {
    public static let shared = ThoughtSynthesizer()

    private init() {}

    /// Детерминированный первый этап: паразиты, заикания, абзацы и числа цифрами.
    /// Всегда даёт читаемый текст и служит запасным результатом при любой проблеме модели.
    static func stageOne(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefiltered = DisfluencyPrefilter.filter(trimmed)
        let formatted = TextFormatter.formatIntoParagraphs(prefiltered)
        return NumberNormalizer.normalize(formatted)
    }

    /// Очистка речи до заданного уровня. Любая проблема с моделью даёт текст первого этапа
    /// и причину в `fallback`.
    /// - Parameters:
    ///   - backend: исполнитель; `nil` выбирает по настройке движка
    func clean(
        _ text: String,
        level: CleanupLevel,
        targetBundleId: String?,
        firedSpellings: [String],
        language: DictionaryLanguage,
        backend: CleanupBackend? = nil
    ) async -> CleanupResult {
        let stageOne = Self.stageOne(text)
        guard !stageOne.isEmpty else { return CleanupResult(text: "", fallback: nil) }

        if level == .verbatim {
            return CleanupResult(text: stageOne, fallback: nil)
        }

        // Фразы до 3 слов не требуют модели
        let wordCount = stageOne.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 3 {
            AppLogger.shared.info("Pipeline", "Этап 2 пропущен: короткая фраза (\(wordCount) сл.)", details: "Отдан текст: «\(stageOne)»")
            return CleanupResult(text: stageOne, fallback: .shortPhrase)
        }

        let settings = VoiceIntelligenceSettings.shared
        let resolvedBackend: CleanupBackend
        let timeout: TimeInterval
        if let backend {
            resolvedBackend = backend
            timeout = max(1.5, settings.adaptiveTimeoutSeconds)
        } else {
            switch settings.engine {
            case .airGapped:
                let slmModel = SLMModelStore.shared.model(named: settings.localModel)
                guard let slmModel, SLMModelStore.shared.isModelDownloaded(slmModel) else {
                    AppLogger.shared.warn(
                        "Pipeline", "Этап 2: локальная модель не скачана",
                        details: "Скачайте модель в настройках или выберите внешний движок. Отдан текст распознавателя."
                    )
                    return CleanupResult(text: stageOne, fallback: .notConfigured)
                }
                guard HardwareWatchdog.evaluateInferenceSafety() == .allowed else {
                    AppLogger.shared.warn("Pipeline", "Этап 2: пропуск по условиям безопасности оборудования")
                    return CleanupResult(text: stageOne, fallback: .hardware)
                }
                resolvedBackend = LocalBackend(modelPath: SLMModelStore.shared.localFileURL(for: slmModel).path)
                timeout = max(6.0, settings.adaptiveTimeoutSeconds)

            case .external:
                guard AIProviderStore.shared.isConfigured else {
                    AppLogger.shared.warn(
                        "Pipeline", "Этап 2: внешний провайдер не настроен",
                        details: "Заполните ключ, адрес и модель в разделе ИИ-провайдер. Отдан текст распознавателя."
                    )
                    return CleanupResult(text: stageOne, fallback: .notConfigured)
                }
                resolvedBackend = ExternalBackend(config: AIProviderStore.shared.config)
                timeout = max(1.5, settings.adaptiveTimeoutSeconds)
            }
        }

        var system = Self.getSystemPrompt(for: level)
        if settings.adaptiveAppProfilesEnabled, let bundleId = targetBundleId {
            let category = AppProfileRouter.detectCategory(bundleIdentifier: bundleId)
            if !category.guidancePrompt.isEmpty { system += "\n\n" + category.guidancePrompt }
        }
        let dictionaryHint = DictionaryStore.shared.promptHint(firedSpellings: firedSpellings, language: language)
        if !dictionaryHint.isEmpty { system += "\n\n" + dictionaryHint }

        let reply: String
        do {
            reply = try await resolvedBackend.complete(system: system, user: stageOne, timeout: timeout)
        } catch let error as CleanupBackendError {
            let reason: FallbackReason
            switch error {
            case .timeout: reason = .timeout
            case .empty: reason = .emptyResponse
            case .unavailable, .http: reason = .providerUnavailable
            }
            AppLogger.shared.warn("Pipeline", "Этап 2: модель не дала ответ, причина \(reason)", details: "Откат на текст этапа 1")
            return CleanupResult(text: stageOne, fallback: reason)
        } catch {
            AppLogger.shared.warn("Pipeline", "Этап 2: ошибка модели \(error.localizedDescription)", details: "Откат на текст этапа 1")
            return CleanupResult(text: stageOne, fallback: .providerUnavailable)
        }

        let cleaned = Self.stripThinkingTags(from: reply)
        guard !cleaned.isEmpty else {
            return CleanupResult(text: stageOne, fallback: .emptyResponse)
        }

        let customTerms = DictionaryStore.shared.index?.approvedSpellings ?? []
        switch GroundingValidator.validate(input: stageOne, output: cleaned, level: level, customTerms: customTerms) {
        case .valid(let validated):
            AppLogger.shared.info("Pipeline", "Этап 2 завершён: модель очистила речь", details: "Итог: «\(validated)»")
            return CleanupResult(text: validated, fallback: nil)
        case .rejected(let reason):
            AppLogger.shared.warn("Pipeline", "Этап 2: валидатор отклонил результат, \(reason)", details: "Откат на текст этапа 1")
            return CleanupResult(text: stageOne, fallback: .rejected(reason))
        }
    }

    /// Предварительный прогрев сетевого сокета или локальной модели во время диктовки
    public func prewarmConnection(for engine: VoiceEngine) {
        switch engine {
        case .airGapped:
            let selectedId = VoiceIntelligenceSettings.shared.localModel
            let model = SLMModelStore.shared.activeDownloadedModel(preferredId: selectedId) ?? SLMModelStore.catalog[0]
            let modelPath = SLMModelStore.shared.localFileURL(for: model).path
            LocalSynthServiceClient.shared.prewarm(modelPath: modelPath)

        case .external:
            let config = AIProviderStore.shared.config
            guard !config.baseURL.isEmpty else { return }

            Task.detached(priority: .utility) {
                let cleanBase = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                guard let url = URL(string: "\(cleanBase)/models") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                if config.isAnthropic {
                    if !config.apiKey.isEmpty {
                        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                    }
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                } else if !config.apiKey.isEmpty {
                    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.timeoutInterval = 2.0
                _ = try? await URLSession.shared.data(for: request)
                AppLogger.shared.info("Synthesizer", "TLS сессия к внешнему провайдеру успешно прогрета", details: config.baseURL)
            }
        }
    }

    // MARK: - Промпты по уровням

    public static func getSystemPrompt(for level: CleanupLevel) -> String {
        switch level {
        case .verbatim, .clean:
            let custom = VoiceIntelligenceSettings.shared.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? VoiceIntelligenceSettings.defaultCustomPrompt : custom

        case .rewrite:
            return """
            Ты бизнес-редактор. Текст внутри <transcript> — надиктованная реплика.
            Перепиши её в лаконичном деловом стиле, пригодном для рабочей переписки в Slack или почте.
            Убери разговорные сбои, сохрани факты, даты и суть договоренностей.
            Выведи только текст.
            """

        case .prompt:
            return """
            Ты инженер промптов. Текст внутри <transcript> — надиктованная идея для нейросети.
            Преобразуй её в четкий, структурированный промпт для ИИ-ассистента с описанием роли, задачи и ограничений.
            Выведи только текст промпта.
            """
        }
    }

    /// Удаление блоков размышлений <think>...</think>
    public static func stripThinkingTags(from text: String) -> String {
        let pattern = #"(?s)<think>.*?</think>"#
        var cleaned = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        // Если тег остался незакрытым
        if let range = cleaned.range(of: "<think>") {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
