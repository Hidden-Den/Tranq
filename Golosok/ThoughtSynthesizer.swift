import Foundation

public final class ThoughtSynthesizer {
    public static let shared = ThoughtSynthesizer()

    private init() {}

    /// Главный метод синтеза мысли
    /// - Parameters:
    ///   - rawText: сырой распознанный текст
    ///   - style: целевой стиль мысли
    ///   - targetBundleId: идентификатор целевого приложения для контекстной адаптации
    ///   - firedSpellings: написания, которые словарь уже подставил в текст
    ///   - language: язык диктовки для подсказки словаря
    ///   - completion: возвращает итоговый текст и флаг, был ли это fallback
    func synthesize(
        rawText: String,
        style: VoiceStyle,
        targetBundleId: String? = nil,
        firedSpellings: [String] = [],
        language: DictionaryLanguage = .current,
        completion: @escaping (_ finalText: String, _ isFallback: Bool) -> Void
    ) {
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            completion("", false)
            return
        }

        // Этап 1: Детерминированный префильтр и базовая нормализация
        let prefiltered = DisfluencyPrefilter.filter(trimmedRaw)
        let formatted = TextFormatter.formatIntoParagraphs(prefiltered)
        let stageOneText = NumberNormalizer.normalize(formatted)

        // Если фраза очень короткая (1-3 слова), пропускаем тяжелый синтез
        let wordCount = stageOneText.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 3 {
            AppLogger.shared.info("Pipeline", "Этап 2 пропущен: короткая фраза (\(wordCount) сл.)", details: "Фразы до 3 слов не требуют языковой модели. Отдан текст: «\(stageOneText)»")
            completion(stageOneText, true)
            return
        }

        // Чистой мысли нечего чистить: вызов модели только рискует переписать речь
        if style == .clean && !DisfluencyPrefilter.needsCleanup(stageOneText) {
            AppLogger.shared.info("Pipeline", "Этап 2 пропущен: в речи нет паразитов и самоисправлений", details: "Отдан текст распознавателя: «\(stageOneText)»")
            completion(stageOneText, true)
            return
        }

        let settings = VoiceIntelligenceSettings.shared
        let dictionaryHint = DictionaryStore.shared.promptHint(firedSpellings: firedSpellings, language: language)
        let messages = buildMessages(for: stageOneText, style: style, targetBundleId: targetBundleId, dictionaryHint: dictionaryHint)

        switch settings.engine {
        case .airGapped:
            let selectedId = settings.localModel
            let slmModel = SLMModelStore.shared.model(named: selectedId)
            let isDownloaded = slmModel != nil && SLMModelStore.shared.isModelDownloaded(slmModel!)
            let modelName = slmModel?.name ?? selectedId

            if !isDownloaded {
                AppLogger.shared.warn(
                    "Pipeline",
                    "Этап 2: Локальная модель «\(modelName)» не скачана на устройство",
                    details: "Скачайте модель в Настройках («Голосовой ввод и синтез») или переключите Движок на Внешний. Выполнен откат на распознанный текст GigaAM."
                )
                completion(stageOneText, true)
                return
            }

            // Проверка аппаратных сторожей безопасности (температура, заряд, память)
            let safety = HardwareWatchdog.evaluateInferenceSafety()
            guard safety == .allowed else {
                AppLogger.shared.warn("Pipeline", "Этап 2: Air-Gapped пропуск синтеза по условиям безопасности оборудования", details: "Откат на текст GigaAM")
                completion(stageOneText, true)
                return
            }

            Task {
                var systemPrompt = Self.getSystemPrompt(for: style)
                if settings.adaptiveAppProfilesEnabled, let bundleId = targetBundleId {
                    let category = AppProfileRouter.detectCategory(bundleIdentifier: bundleId)
                    if !category.guidancePrompt.isEmpty {
                        systemPrompt += "\n\n" + category.guidancePrompt
                    }
                }
                if !dictionaryHint.isEmpty {
                    systemPrompt += "\n\n" + dictionaryHint
                }

                AppLogger.shared.info(
                    "Pipeline",
                    "Этап 2: Локальная модель готова: \(modelName)",
                    details: "Размер: \(slmModel?.sizeMB ?? 0) МБ, стиль: \(style.title)"
                )

                let targetModelPath = slmModel.map { SLMModelStore.shared.localFileURL(for: $0).path }
                let localTimeout = max(6.0, settings.adaptiveTimeoutSeconds)
                if let synthResult = await LocalSynthServiceClient.shared.synthesize(
                    transcript: stageOneText,
                    stylePrompt: systemPrompt,
                    modelPath: targetModelPath,
                    timeout: localTimeout
                ) {
                    let cleaned = Self.stripThinkingTags(from: synthResult)
                    let customTerms = DictionaryStore.shared.index?.approvedSpellings ?? []
                    let validation = GroundingValidator.validate(
                        input: stageOneText,
                        output: cleaned,
                        style: style,
                        customTerms: customTerms
                    )
                    switch validation {
                    case .valid(let text):
                        AppLogger.shared.info(
                            "Pipeline",
                            "Этап 2 завершен: Локальная модель успешно выполнила синтез мысли",
                            details: "Итог: «\(text)»"
                        )
                        DispatchQueue.main.async {
                            completion(text, false)
                        }
                        return
                    case .rejected(let reason):
                        AppLogger.shared.warn(
                            "Pipeline",
                            "Этап 2: Валидатор отклонил результат (\(reason)) — откат на текст GigaAM"
                        )
                    }
                } else {
                    AppLogger.shared.warn(
                        "Pipeline",
                        "Этап 2: Локальный инференс не вернул результат",
                        details: "Модель «\(modelName)» загружена на диск, но локальный исполнитель не вернул ответ. Безопасный откат на нормализованный текст GigaAM."
                    )
                }
                DispatchQueue.main.async {
                    completion(stageOneText, true)
                }
            }

        case .external:
            let config = AIProviderStore.shared.config
            guard AIProviderStore.shared.isConfigured else {
                AppLogger.shared.warn(
                    "Pipeline",
                    "Этап 2: Внешний ИИ-провайдер не настроен",
                    details: "Заполните ключ, Base URL и модель в секции «ИИ-провайдер». Откат на текст GigaAM."
                )
                completion(stageOneText, true)
                return
            }
            AppLogger.shared.info(
                "Pipeline",
                "Этап 2: Запрос к внешней модели (\(config.model))",
                details: "Провайдер: \(config.baseURL), стиль: \(style.title)"
            )
            runAISynthesis(messages: messages, config: config, stageOneText: stageOneText, style: style, timeout: settings.adaptiveTimeoutSeconds, completion: completion)
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

    private func runAISynthesis(
        messages: [AIChatMessage],
        config: AIProviderConfig,
        stageOneText: String,
        style: VoiceStyle,
        timeout: Double,
        completion: @escaping (_ finalText: String, _ isFallback: Bool) -> Void
    ) {
        AppLogger.shared.info("Synthesizer", "Старт стриминга мысли [\(style.title)] через \(config.baseURL) / \(config.model)")

        let startAbsoluteTime = CFAbsoluteTimeGetCurrent()
        let lock = NSLock()
        var isCompleted = false

        let safeCompletion: (String, Bool) -> Void = { text, isFallback in
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else { return }
            isCompleted = true
            DispatchQueue.main.async {
                completion(text, isFallback)
            }
        }

        // Адаптивный сторож по времени
        let timeoutSec = max(1.5, timeout)
        let watchdogTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
            if !Task.isCancelled {
                AppLogger.shared.warn("Synthesizer", String(format: "Таймаут синтеза (%.1f с) — откат на этап 1", timeoutSec))
                safeCompletion(stageOneText, true)
            }
        }

        Task.detached(priority: .userInitiated) {
            do {
                let cleanBase = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                let targetURLString: String
                if config.isAnthropic {
                    targetURLString = cleanBase.hasSuffix("/messages") ? cleanBase : cleanBase + "/messages"
                } else {
                    targetURLString = cleanBase.hasSuffix("/chat/completions") ? cleanBase : cleanBase + "/chat/completions"
                }

                guard let url = URL(string: targetURLString) else {
                    safeCompletion(stageOneText, true)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                if config.isAnthropic {
                    if !config.apiKey.isEmpty {
                        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
                    }
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                } else {
                    if !config.apiKey.isEmpty {
                        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                }
                request.setValue("https://github.com/Nuteres/Golosok", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Golosok macOS", forHTTPHeaderField: "X-Title")

                var body: [String: Any] = [
                    "model": config.model,
                    "stream": true
                ]

                if config.isAnthropic {
                    body["max_tokens"] = 1024
                    body["temperature"] = 0.1

                    var systemPrompt: String? = nil
                    var anthropicMessages: [[String: String]] = []
                    for msg in messages {
                        if msg.role == "system" {
                            if let existing = systemPrompt {
                                systemPrompt = existing + "\n\n" + msg.content
                            } else {
                                systemPrompt = msg.content
                            }
                        } else {
                            anthropicMessages.append(["role": msg.role, "content": msg.content])
                        }
                    }
                    if anthropicMessages.isEmpty, let sp = systemPrompt {
                        anthropicMessages.append(["role": "user", "content": sp])
                        systemPrompt = nil
                    }
                    body["messages"] = anthropicMessages
                    if let systemPrompt, !systemPrompt.isEmpty {
                        body["system"] = systemPrompt
                    }
                } else {
                    body["messages"] = messages.map { ["role": $0.role, "content": $0.content] }
                    let isOpenRouter = config.baseURL.contains("openrouter.ai")
                    if isOpenRouter {
                        body["reasoning"] = ["effort": "none", "exclude": true]
                        body["provider"] = ["sort": "latency"]
                    } else {
                        body["temperature"] = 0.1
                    }
                }

                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    AppLogger.shared.warn("Synthesizer", "HTTP ошибка при стриминге: \(code) — откат на этап 1")
                    safeCompletion(stageOneText, true)
                    return
                }

                var firstTokenTime: CFAbsoluteTime?
                var stripper = StreamingThinkTagStripper()
                var accumulated = ""

                for try await line in bytes.lines {
                    if line.hasPrefix("data: ") {
                        let dataStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if dataStr == "[DONE]" { break }
                        guard let jsonData = dataStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

                        if let type = json["type"] as? String, type == "message_stop" {
                            break
                        }

                        let chunk: String?
                        if let choices = json["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let delta = firstChoice["delta"] as? [String: Any] {
                            chunk = delta["content"] as? String
                        } else if let delta = json["delta"] as? [String: Any] {
                            chunk = delta["text"] as? String
                        } else {
                            chunk = nil
                        }

                        guard let validChunk = chunk, !validChunk.isEmpty else { continue }

                        if firstTokenTime == nil {
                            firstTokenTime = CFAbsoluteTimeGetCurrent()
                            let ttft = firstTokenTime! - startAbsoluteTime
                            AppLogger.shared.info("Synthesizer", String(format: "Первый токен получен (TTFT: %.3f с)", ttft))
                            if ttft > 1.2 {
                                AppLogger.shared.warn("Synthesizer", String(format: "Медленный старт генерации модели (TTFT: %.2f с)", ttft))
                            }
                        }

                        if let cleanChunk = stripper.feed(validChunk) {
                            accumulated.append(cleanChunk)
                        }
                    }
                }

                if let rest = stripper.finish() {
                    accumulated.append(rest)
                }

                watchdogTask.cancel()

                let totalDuration = CFAbsoluteTimeGetCurrent() - startAbsoluteTime
                AppLogger.shared.info("Synthesizer", String(format: "Стриминг завершен за %.2f с (символов: %d)", totalDuration, accumulated.count))

                let cleanContent = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanContent.isEmpty else {
                    AppLogger.shared.warn("Synthesizer", "Пустой ответ стриминга — откат на этап 1")
                    safeCompletion(stageOneText, true)
                    return
                }

                // Детерминированный Grounding Validator с учетом стиля, словаря и персонализации
                let customTerms = DictionaryStore.shared.index?.approvedSpellings ?? []
                let validation = GroundingValidator.validate(
                    input: stageOneText,
                    output: cleanContent,
                    style: style,
                    customTerms: customTerms
                )
                switch validation {
                case .valid(let validatedText):
                    AppLogger.shared.info("Synthesizer", "Валидация успешна: мысль готова к вставке")
                    AppLogger.shared.info("Pipeline", "Этап 2 завершен: Внешняя модель успешно выполнила синтез", details: "Итог: «\(validatedText)»")
                    safeCompletion(validatedText, false)

                case .rejected(let reason):
                    AppLogger.shared.warn("Synthesizer", "Валидатор отклонил результат (\(reason)) — откат на этап 1")
                    AppLogger.shared.warn("Pipeline", "Этап 2 отклонен валидатором: \(reason)", details: "Откат на базовый текст GigaAM")
                    safeCompletion(stageOneText, true)
                }

            } catch {
                watchdogTask.cancel()
                AppLogger.shared.warn("Synthesizer", "Ошибка стриминга: \(error.localizedDescription) — откат на этап 1")
                AppLogger.shared.warn("Pipeline", "Этап 2: Ошибка обращения к внешней модели: \(error.localizedDescription)", details: "Откат на базовый текст GigaAM")
                safeCompletion(stageOneText, true)
            }
        }
    }

    // MARK: - Промпты по стилям

    public static func getSystemPrompt(for style: VoiceStyle) -> String {
        let settings = VoiceIntelligenceSettings.shared
        if style == .clean {
            let custom = settings.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                return custom
            }
        }

        switch style {
        case .clean:
            return VoiceIntelligenceSettings.defaultCustomPrompt

        case .bullets:
            return """
            Ты редактор. Текст внутри <transcript> — сырая голосовая заметка.
            Выдели из неё ключевые тезисы и факты в виде лаконичного маркированного списка (каждый пункт с дефиса).
            Не придумывай фактов, которых нет в речи. Не пиши вводных фраз.
            """

        case .formal:
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

    private func buildMessages(for text: String, style: VoiceStyle, targetBundleId: String?, dictionaryHint: String) -> [AIChatMessage] {
        var systemPrompt = Self.getSystemPrompt(for: style)
        let settings = VoiceIntelligenceSettings.shared

        if settings.adaptiveAppProfilesEnabled, let bundleId = targetBundleId {
            let category = AppProfileRouter.detectCategory(bundleIdentifier: bundleId)
            if !category.guidancePrompt.isEmpty {
                systemPrompt += "\n\n" + category.guidancePrompt
            }
        }

        if !dictionaryHint.isEmpty {
            systemPrompt += "\n\n" + dictionaryHint
        }

        let userPrompt = "<transcript>\(text)</transcript>"

        return [
            AIChatMessage(role: "system", content: systemPrompt),
            AIChatMessage(role: "user", content: userPrompt)
        ]
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
