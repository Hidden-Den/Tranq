import Foundation
import CTranscribe

/// Распознавание через библиотеку transcribe.cpp прямо в процессе приложения.
///
/// По экземпляру на модель: GigaAM v3 из бандла и русский Whisper turbo.
/// Модель загружается один раз и остаётся в памяти; после `idleUnloadSeconds`
/// простоя выгружается. Это убирает повторную загрузку модели и запуск
/// отдельного процесса на каждую диктовку: Whisper через whisper-cli после паузы
/// грузился до 9 секунд.
final class TranscribeEngine: SpeechRecognizer {
    static let gigaAM = TranscribeEngine(model: .russianGigaAM, logSource: "GigaAM")
    static let russianTurbo = TranscribeEngine(model: .russianTurbo, logSource: "Whisper")

    /// Все экземпляры: выход из приложения освобождает каждый.
    static let all = [gigaAM, russianTurbo]

    /// Движок для модели, если она работает в процессе; иначе нужен `WhisperCLIEngine`.
    static func engine(for model: RecognitionModel) -> TranscribeEngine? {
        all.first { $0.model.id == model.id }
    }

    let model: RecognitionModel
    var displayName: String { model.systemName }
    private(set) var maxChunkSeconds: Double = 25.0

    private let logSource: String
    private let idleUnloadSeconds: TimeInterval = 300
    private let queue: DispatchQueue
    private var transcribeModel: OpaquePointer?
    private var session: OpaquePointer?
    private var loadedPath: String?
    private var idleUnload: DispatchWorkItem?
    private static let backendsReady: Bool = {
        transcribe_log_set({ level, msg, _ in
            guard let msg, level == TRANSCRIBE_LOG_LEVEL_ERROR else { return }
            let text = String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines)
            // ggml пробует собрать тензорный API из исходника и штатно откатывается — это не ошибка.
            guard !text.isEmpty, !text.contains("init_from_source") else { return }
            AppLogger.shared.warn("Recognition", "transcribe.cpp: \(text)")
        }, nil)
        return transcribe_init_backends_default() == TRANSCRIBE_OK
    }()

    private init(model: RecognitionModel, logSource: String) {
        self.model = model
        self.logSource = logSource
        self.queue = DispatchQueue(label: "tranq.transcribe.\(model.id)", qos: .userInitiated)
    }

    /// ggml роняет процесс при выходе, если Metal-устройство освобождается, пока модель жива:
    /// в наборах резидентности остаются буферы. Обработчик `atexit` регистрируется после первой
    /// загрузки, то есть после создания устройства, поэтому на выходе срабатывает раньше его
    /// деструктора. Он покрывает и выход из приложения, и завершение хоста юнит-тестов.
    private static let exitHook: Void = {
        atexit { TranscribeEngine.all.forEach { $0.shutdown() } }
    }()

    /// Whisper получает язык и подсказку словаря, GigaAM знает только русский и подсказок не берёт.
    private var isWhisper: Bool { model.fileName.hasSuffix(".bin") }

    /// Модель сейчас в памяти.
    var isModelLoaded: Bool {
        queue.sync { session != nil }
    }

    /// Освобождает модель и сессию и отменяет отложенную выгрузку. Вызывается при выходе из приложения.
    func shutdown() {
        queue.sync {
            idleUnload?.cancel()
            idleUnload = nil
            unloadLocked()
        }
    }

    func prewarm() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.ensureLoaded()
            self.scheduleIdleUnload()
        }
    }

    func recognize(samples: [Float]) -> RecognitionResult {
        guard !samples.isEmpty else { return .empty }
        // Подсказка читается до очереди движка: словарь живёт своей жизнью
        let vocabulary = isWhisper ? DictionaryStore.shared.recognizerPrompt() : ""
        return queue.sync {
            defer { scheduleIdleUnload() }
            guard ensureLoaded() else { return .empty }

            var status = run(samples, vocabulary: vocabulary)
            if status == TRANSCRIBE_ERR_BACKEND {
                AppLogger.shared.warn(logSource, "Сбой Metal, перезагрузка модели на CPU")
                unloadLocked()
                guard ensureLoaded(backend: TRANSCRIBE_BACKEND_CPU) else { return .empty }
                status = run(samples, vocabulary: vocabulary)
            }
            guard status == TRANSCRIBE_OK, let session else {
                AppLogger.shared.error(logSource, "Ошибка распознавания", details: Self.describe(status))
                return .empty
            }

            if isWhisper {
                let segments = Self.readSegments(session)
                let kept = segments.filter { !Self.isHallucination($0.text) }
                if kept.count < segments.count {
                    AppLogger.shared.info(logSource, "Отброшена фраза из титров, Whisper выдумывает её на тишине")
                }
                let text = kept.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let words = kept.flatMap { Self.segmentWords($0.text, from: $0.start, to: $0.end) }
                return RecognitionResult(text: text, words: WordTimings.finalize(words))
            }
            let text = transcribe_full_text(session).map { String(cString: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return RecognitionResult(text: text, words: WordTimings.finalize(Self.readWords(session)))
        }
    }

    private func run(_ samples: [Float], vocabulary: String) -> transcribe_status {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session, let transcribeModel else { return TRANSCRIBE_ERR_INVALID_ARG }
        var params = transcribe_run_params()
        params.struct_size = UInt64(MemoryLayout<transcribe_run_params>.size)
        transcribe_run_params_init(&params)

        guard isWhisper else {
            params.timestamps = TRANSCRIBE_TIMESTAMPS_TOKEN
            return samples.withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
            }
        }

        // Whisper отдаёт только метки фраз; слова раскладываются по ним в segmentWords
        params.timestamps = TRANSCRIBE_TIMESTAMPS_SEGMENT
        var ext = transcribe_whisper_run_ext()
        transcribe_whisper_run_ext_init(&ext)
        let acceptsExt = transcribe_model_accepts_ext_kind(
            transcribeModel, TRANSCRIBE_EXT_SLOT_RUN, TRANSCRIBE_EXT_KIND_WHISPER_RUN)
        return model.languageCode.withCString { language in
            params.language = language
            // Слова из словаря как начальный контекст: Whisper охотнее пишет их как надо
            return vocabulary.withCString { prompt in
                if acceptsExt, !vocabulary.isEmpty { ext.initial_prompt = prompt }
                return withUnsafePointer(to: &ext) { extPointer in
                    if acceptsExt {
                        params.family = UnsafeRawPointer(extPointer).assumingMemoryBound(to: transcribe_ext.self)
                    }
                    return samples.withUnsafeBufferPointer {
                        transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
                    }
                }
            }
        }
    }

    // MARK: - Загрузка и выгрузка

    private func ensureLoaded(backend: transcribe_backend_request = TRANSCRIBE_BACKEND_AUTO) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let path = ModelStore.shared.localModelPath(for: model.id) else {
            AppLogger.shared.error(logSource, "Модель \(model.fileName) не найдена")
            return false
        }
        if session != nil, loadedPath == path { return true }
        unloadLocked()

        guard Self.backendsReady else {
            AppLogger.shared.error(logSource, "Не удалось инициализировать вычислительные бэкенды")
            return false
        }

        let started = CFAbsoluteTimeGetCurrent()
        var loadParams = transcribe_model_load_params()
        loadParams.struct_size = UInt64(MemoryLayout<transcribe_model_load_params>.size)
        transcribe_model_load_params_init(&loadParams)
        loadParams.backend = backend

        var newModel: OpaquePointer?
        var status = transcribe_model_load_file(path, &loadParams, &newModel)
        guard status == TRANSCRIBE_OK, let newModel else {
            AppLogger.shared.error(logSource, "Не удалось загрузить модель", details: Self.describe(status))
            return false
        }
        var newSession: OpaquePointer?
        status = transcribe_session_init(newModel, nil, &newSession)
        guard status == TRANSCRIBE_OK, let newSession else {
            transcribe_model_free(newModel)
            AppLogger.shared.error(logSource, "Не удалось создать сессию", details: Self.describe(status))
            return false
        }

        var limits = transcribe_session_limits()
        limits.struct_size = UInt64(MemoryLayout<transcribe_session_limits>.size)
        transcribe_session_limits_init(&limits)
        if transcribe_session_get_limits(newSession, &limits) == TRANSCRIBE_OK, limits.effective_max_audio_ms > 0 {
            // Запас в полсекунды, чтобы фрагмент гарантированно влез в лимит модели
            maxChunkSeconds = max(5, Double(limits.effective_max_audio_ms) / 1000.0 - 0.5)
        }

        transcribeModel = newModel
        session = newSession
        loadedPath = path
        _ = Self.exitHook
        let backendName = transcribe_model_backend(newModel).map { String(cString: $0) } ?? "?"
        AppLogger.shared.info(
            logSource,
            "Модель загружена в память",
            details: String(format: "%.2f с, бэкенд %@, фрагмент до %.0f с", CFAbsoluteTimeGetCurrent() - started, backendName, maxChunkSeconds)
        )
        return true
    }

    private func scheduleIdleUnload() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleUnload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil else { return }
            self.unloadLocked()
            AppLogger.shared.info(self.logSource, "Модель выгружена после простоя")
        }
        idleUnload = work
        queue.asyncAfter(deadline: .now() + idleUnloadSeconds, execute: work)
    }

    private func unloadLocked() {
        if let session { transcribe_session_free(session) }
        if let transcribeModel { transcribe_model_free(transcribeModel) }
        session = nil
        transcribeModel = nil
        loadedPath = nil
    }

    // MARK: - Результаты

    private static func readWords(_ session: OpaquePointer) -> [TimedWord] {
        let count = transcribe_n_tokens(session)
        guard count > 0 else { return [] }
        var tokens: [(text: String, start: Double, end: Double)] = []
        tokens.reserveCapacity(Int(count))
        var token = transcribe_token()
        token.struct_size = UInt64(MemoryLayout<transcribe_token>.size)
        transcribe_token_init(&token)
        for i in 0..<count {
            guard transcribe_get_token(session, i, &token) == TRANSCRIBE_OK, let text = token.text else { continue }
            tokens.append((String(cString: text), Double(token.t0_ms) / 1000, Double(token.t1_ms) / 1000))
        }
        return WordTimings.assemble(tokens: tokens)
    }

    /// Фразы Whisper с метками времени в секундах.
    private static func readSegments(_ session: OpaquePointer) -> [(text: String, start: Double, end: Double)] {
        let count = transcribe_n_segments(session)
        guard count > 0 else { return [] }
        var segment = transcribe_segment()
        segment.struct_size = UInt64(MemoryLayout<transcribe_segment>.size)
        transcribe_segment_init(&segment)
        var segments: [(text: String, start: Double, end: Double)] = []
        for i in 0..<count {
            guard transcribe_get_segment(session, i, &segment) == TRANSCRIBE_OK, let text = segment.text else { continue }
            segments.append((String(cString: text), Double(segment.t0_ms) / 1000, Double(segment.t1_ms) / 1000))
        }
        return segments
    }

    /// Подписи из титров видео, которые Whisper выдаёт на фрагменте без речи. Собственная
    /// проверка тишины Whisper их не ловит: у turbo вероятность тишины на них нулевая,
    /// а уверенность высокая. Отбрасывается только фраза, целиком совпадающая с подписью.
    private static let hallucinatedPhrases: Set<String> = [
        "продолжение следует",
        "спасибо за просмотр",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "редактор субтитров а синецкая корректор а егорова",
    ]

    static func isHallucination(_ segment: String) -> Bool {
        let normalized = segment.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        return hallucinatedPhrases.contains(normalized)
    }

    /// Слова фразы Whisper: время фразы делится между её словами пропорционально длине.
    static func segmentWords(_ text: String, from start: Double, to end: Double) -> [TimedWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        let placeholders = parts.map { TimedWord(text: $0, start: start, end: end) }
        return WordTimings.interpolate(placeholders, from: start, to: end)
    }

    private static func describe(_ status: transcribe_status) -> String {
        transcribe_status_string(Int32(status.rawValue)).map { String(cString: $0) } ?? "код \(status.rawValue)"
    }
}
