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
    ///   - telemetry: хранилище замеров; `nil` берёт общее, подмена нужна тестам
    ///   - noteId: заметка, для которой идёт очистка; при замке попадает в лог вместо текста
    func clean(
        _ text: String,
        level: CleanupLevel,
        targetBundleId: String?,
        firedSpellings: [String],
        language: DictionaryLanguage,
        backend: CleanupBackend? = nil,
        telemetry: CleanupTelemetry? = nil,
        noteId: UUID? = nil
    ) async -> CleanupResult {
        let stageOne = Self.stageOne(text)
        // Речь из одних звуков: модель не нужна, а текст не от неё
        guard !stageOne.isEmpty else { return CleanupResult(text: "", fallback: .shortPhrase) }

        if level == .verbatim {
            return CleanupResult(text: stageOne, fallback: nil)
        }

        // Фразы до 3 слов не требуют модели
        let wordCount = stageOne.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 3 {
            AppLogger.shared.info("Pipeline", "Этап 2 пропущен: короткая фраза (\(wordCount) сл.)", details: "Отдан текст: \(AppLogger.shared.transcript(stageOne, id: noteId))")
            return CleanupResult(text: stageOne, fallback: .shortPhrase)
        }

        let settings = VoiceIntelligenceSettings.shared
        let resolvedBackend: CleanupBackend
        let deadlines: CleanupDeadlines
        let modelName: String
        if let backend {
            resolvedBackend = backend
            modelName = String(describing: type(of: backend))
            deadlines = CleanupDeadlines.external(characters: stageOne.count, setting: settings.adaptiveTimeoutSeconds)
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
                modelName = settings.localModel
                deadlines = CleanupDeadlines.local(setting: settings.adaptiveTimeoutSeconds)

            case .external:
                guard AIProviderStore.shared.isConfigured else {
                    AppLogger.shared.warn(
                        "Pipeline", "Этап 2: внешний провайдер не настроен",
                        details: "Заполните ключ, адрес и модель в разделе ИИ-провайдер. Отдан текст распознавателя."
                    )
                    return CleanupResult(text: stageOne, fallback: .notConfigured)
                }
                resolvedBackend = ExternalBackend(config: AIProviderStore.shared.config, telemetry: telemetry)
                modelName = AIProviderStore.shared.config.model
                deadlines = CleanupDeadlines.external(characters: stageOne.count, setting: settings.adaptiveTimeoutSeconds)
            }
        }

        var system = Self.getSystemPrompt(for: level)
        let dictionaryHint = DictionaryStore.shared.promptHint(firedSpellings: firedSpellings, language: language)
        if !dictionaryHint.isEmpty { system += "\n\n" + dictionaryHint }
        let suspects = DictionaryStore.shared.index?.termSuspects(in: stageOne, language: language) ?? []
        let termHint = DictionaryStore.shared.termHint(suspects)
        if !termHint.isEmpty {
            system += "\n\n" + termHint
            // Подсказка собрана из слов диктовки: при замке пишется только число слов
            AppLogger.shared.info("Pipeline", "Этап 2: подсказка терминов",
                                  details: AppLogger.shared.redactTranscripts ? "слов: \(suspects.count)" : termHint)
        }

        let store: CleanupTelemetry
        if let telemetry { store = telemetry } else { store = await CleanupTelemetry.shared }
        let attemptStarted = CFAbsoluteTimeGetCurrent()
        await store.begin(model: modelName)

        let reply: String
        do {
            reply = try await resolvedBackend.complete(system: system, user: stageOne, deadlines: deadlines)
            await store.finish(outcome: .success, totalSeconds: CFAbsoluteTimeGetCurrent() - attemptStarted)
        } catch let error as CleanupBackendError {
            await store.finish(outcome: error == .timeout ? .timeout : .error, totalSeconds: CFAbsoluteTimeGetCurrent() - attemptStarted)
            let reason: FallbackReason
            switch error {
            case .timeout: reason = .timeout
            case .empty: reason = .emptyResponse
            case .http(let code): reason = .providerError(code)
            case .unavailable, .connectionLost: reason = .providerUnavailable
            }
            AppLogger.shared.warn("Pipeline", "Этап 2: модель не дала ответ, \(error.logDescription)", details: "Откат на текст этапа 1")
            return CleanupResult(text: stageOne, fallback: reason)
        } catch {
            await store.finish(outcome: .error, totalSeconds: CFAbsoluteTimeGetCurrent() - attemptStarted)
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
            AppLogger.shared.info("Pipeline", "Этап 2 завершён: модель очистила речь", details: "Итог: \(AppLogger.shared.transcript(validated, id: noteId))")
            return CleanupResult(text: validated, fallback: nil)
        case .rejected(let reason):
            // Причина может назвать слово или число из диктовки, при замке она скрыта
            let shown = AppLogger.shared.redactTranscripts ? "причина скрыта" : reason
            AppLogger.shared.warn("Pipeline", "Этап 2: валидатор отклонил результат, \(shown)", details: "Откат на текст этапа 1")
            return CleanupResult(text: stageOne, fallback: .rejected(reason))
        }
    }

    /// Что греть перед диктовкой.
    public enum PrewarmPlan: Equatable {
        case nothing
        case localModel(path: String)
    }

    /// Решение о прогреве. Внешний провайдер не греется: на стороне API греть нечего,
    /// а сокет, открытый на старте записи, шлюз закрывает, пока человек говорит, и запрос
    /// получает мёртвое соединение из пула. Рукопожатие TLS стоит 0,15 с, потеря очистки дороже.
    static func prewarmPlan(engine: VoiceEngine, downloadedModelPath: String?) -> PrewarmPlan {
        switch engine {
        case .external:
            return .nothing
        case .airGapped:
            // Греется только выбранная и скачанная модель, как в `clean`: чужая заняла бы гигабайты памяти зря
            guard let path = downloadedModelPath else { return .nothing }
            return .localModel(path: path)
        }
    }

    /// Предварительный прогрев локальной модели во время диктовки
    public func prewarmConnection(for engine: VoiceEngine) {
        var downloaded: String?
        if let model = SLMModelStore.shared.model(named: VoiceIntelligenceSettings.shared.localModel),
           SLMModelStore.shared.isModelDownloaded(model) {
            downloaded = SLMModelStore.shared.localFileURL(for: model).path
        }
        switch Self.prewarmPlan(engine: engine, downloadedModelPath: downloaded) {
        case .nothing:
            return
        case .localModel(let path):
            LocalSynthServiceClient.shared.prewarm(modelPath: path)
        }
    }

    // MARK: - Промпты по уровням

    /// Как писать термины, общее для всех уровней с моделью.
    static let termsRule = "Латинские термины и аббревиатуры пиши латиницей: CRM, B2B, staging, pull request. Русские аббревиатуры пиши кириллицей: БТИ, НДС. Слова с русскими окончаниями оставляй кириллицей: задеплоить, митинг, фича."

    /// Речь говорящего передаётся как есть, мат в том числе. Тон правила может это переопределить.
    static let profanityRule = "Мат и грубые слова говорящего оставь как сказано: не смягчай, не маскируй звёздочками и не заменяй."

    public static func getSystemPrompt(for level: CleanupLevel) -> String {
        let base: String
        // Тон правила может сам решить судьбу мата: тогда общее правило не добавляется.
        var keepsProfanity = true
        switch level {
        case .verbatim, .clean:
            let custom = VoiceIntelligenceSettings.shared.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            base = custom.isEmpty ? VoiceIntelligenceSettings.defaultCustomPrompt : custom

        case .rewrite(let tone):
            base = VoiceIntelligenceSettings.defaultCustomPrompt.replacingOccurrences(
                of: VoiceIntelligenceSettings.keepWordsRule,
                with: "4. Перепиши в тоне: \(tone). Структурируй по абзацам, если текст длинный."
            )
            keepsProfanity = !tone.contains(RuleTone.dropProfanity) && !tone.contains(RuleTone.keepProfanity)
        }
        let tail = keepsProfanity ? termsRule + "\n" + profanityRule : termsRule
        return base + "\n\n" + tail
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
