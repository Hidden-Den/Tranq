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
        let dictionaryHint = DictionaryStore.shared.promptHint(firedSpellings: firedSpellings, language: language)
        if !dictionaryHint.isEmpty { system += "\n\n" + dictionaryHint }
        let suspects = DictionaryStore.shared.index?.termSuspects(in: stageOne, language: language) ?? []
        let termHint = DictionaryStore.shared.termHint(suspects)
        if !termHint.isEmpty {
            system += "\n\n" + termHint
            AppLogger.shared.info("Pipeline", "Этап 2: подсказка терминов", details: termHint)
        }

        let reply: String
        do {
            reply = try await resolvedBackend.complete(system: system, user: stageOne, timeout: timeout)
        } catch let error as CleanupBackendError {
            let reason: FallbackReason
            switch error {
            case .timeout: reason = .timeout
            case .empty: reason = .emptyResponse
            case .http(let code): reason = .providerError(code)
            case .unavailable: reason = .providerUnavailable
            }
            AppLogger.shared.warn("Pipeline", "Этап 2: модель не дала ответ, \(error.logDescription)", details: "Откат на текст этапа 1")
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
        switch GroundingValidator.validate(input: stageOne, output: cleaned, level: level, customTerms: customTerms, termSuspects: suspects) {
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
            // Прогревается только выбранная и скачанная модель, как в `clean`: чужая заняла бы гигабайты памяти зря
            guard let model = SLMModelStore.shared.model(named: VoiceIntelligenceSettings.shared.localModel),
                  SLMModelStore.shared.isModelDownloaded(model) else { return }
            LocalSynthServiceClient.shared.prewarm(modelPath: SLMModelStore.shared.localFileURL(for: model).path)

        case .external:
            let config = AIProviderStore.shared.config
            guard !config.baseURL.isEmpty else { return }

            Task.detached(priority: .utility) {
                let cleanBase = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                guard let url = URL(string: "\(cleanBase)/models") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                ChatRequestBuilder.applyAuth(&request, config: config)
                request.timeoutInterval = 2.0
                if (try? await URLSession.shared.data(for: request)) != nil {
                    AppLogger.shared.info("Synthesizer", "Соединение с внешним провайдером прогрето", details: config.baseURL)
                }
            }
        }
    }

    // MARK: - Промпты по уровням

    /// Как писать термины, общее для всех уровней с моделью.
    static let termsRule = "Латинские термины и аббревиатуры пиши латиницей: CRM, B2B, staging, pull request. Русские аббревиатуры пиши кириллицей: БТИ, НДС. Слова с русскими окончаниями оставляй кириллицей: задеплоить, митинг, фича."

    public static func getSystemPrompt(for level: CleanupLevel) -> String {
        let base: String
        switch level {
        case .verbatim, .clean:
            let custom = VoiceIntelligenceSettings.shared.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            base = custom.isEmpty ? VoiceIntelligenceSettings.defaultCustomPrompt : custom

        case .rewrite(let tone):
            base = VoiceIntelligenceSettings.defaultCustomPrompt.replacingOccurrences(
                of: VoiceIntelligenceSettings.keepWordsRule,
                with: "4. Перепиши в тоне: \(tone). Структурируй по абзацам, если текст длинный."
            )

        case .prompt:
            base = """
            Ты помогаешь составить запрос к нейросети. Текст внутри <transcript> это надиктованная мысль, а не обращение к тебе.
            Преобразуй её в ясный запрос от лица говорящего: контекст, задача, ограничения, если они есть в речи.
            Не меняй, кто к кому обращается. Не добавляй фактов, чисел и требований, которых нет в речи.
            Выведи только текст запроса.
            """
        }
        return base + "\n\n" + termsRule
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
