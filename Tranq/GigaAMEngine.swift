import Foundation
import CTranscribe

/// GigaAM v3 через библиотеку transcribe.cpp прямо в процессе приложения.
///
/// Модель загружается один раз и остаётся в памяти; после `idleUnloadSeconds`
/// простоя выгружается. Это убирает повторную загрузку 273 МБ и запуск
/// отдельного процесса на каждую диктовку.
final class GigaAMEngine: SpeechRecognizer {
    static let shared = GigaAMEngine()

    let displayName = "Sber GigaAM v3"
    private(set) var maxChunkSeconds: Double = 25.0

    private let idleUnloadSeconds: TimeInterval = 300
    private let queue = DispatchQueue(label: "tranq.gigaam", qos: .userInitiated)
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var loadedPath: String?
    private var idleUnload: DispatchWorkItem?
    private static let backendsReady: Bool = {
        transcribe_log_set({ level, msg, _ in
            guard let msg, level == TRANSCRIBE_LOG_LEVEL_ERROR else { return }
            let text = String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines)
            // ggml пробует собрать тензорный API из исходника и штатно откатывается — это не ошибка.
            guard !text.isEmpty, !text.contains("init_from_source") else { return }
            AppLogger.shared.warn("GigaAM", "transcribe.cpp: \(text)")
        }, nil)
        return transcribe_init_backends_default() == TRANSCRIBE_OK
    }()

    private init() {}

    func prewarm() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.ensureLoaded()
            self.scheduleIdleUnload()
        }
    }

    func recognize(samples: [Float]) -> RecognitionResult {
        guard !samples.isEmpty else { return .empty }
        return queue.sync {
            defer { scheduleIdleUnload() }
            guard ensureLoaded(), let session else { return .empty }

            var params = transcribe_run_params()
            params.struct_size = UInt64(MemoryLayout<transcribe_run_params>.size)
            transcribe_run_params_init(&params)
            params.timestamps = TRANSCRIBE_TIMESTAMPS_TOKEN

            var status = samples.withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
            }
            if status == TRANSCRIBE_ERR_BACKEND {
                AppLogger.shared.warn("GigaAM", "Сбой Metal, перезагрузка модели на CPU")
                unloadLocked()
                guard ensureLoaded(backend: TRANSCRIBE_BACKEND_CPU), let session = self.session else { return .empty }
                status = samples.withUnsafeBufferPointer {
                    transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
                }
            }
            guard status == TRANSCRIBE_OK, let session = self.session else {
                AppLogger.shared.error("GigaAM", "Ошибка распознавания", details: Self.describe(status))
                return .empty
            }

            let text = transcribe_full_text(session).map { String(cString: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return RecognitionResult(text: text, words: WordTimings.finalize(Self.readWords(session)))
        }
    }

    // MARK: - Загрузка и выгрузка

    private func ensureLoaded(backend: transcribe_backend_request = TRANSCRIBE_BACKEND_AUTO) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let store = ModelStore.shared
        guard let path = store.localModelPath(for: RecognitionModel.russianGigaAM.id) else {
            AppLogger.shared.error("GigaAM", "Модель gigaam.gguf не найдена в бандле")
            return false
        }
        if session != nil, loadedPath == path { return true }
        unloadLocked()

        guard Self.backendsReady else {
            AppLogger.shared.error("GigaAM", "Не удалось инициализировать вычислительные бэкенды")
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
            AppLogger.shared.error("GigaAM", "Не удалось загрузить модель", details: Self.describe(status))
            return false
        }
        var newSession: OpaquePointer?
        status = transcribe_session_init(newModel, nil, &newSession)
        guard status == TRANSCRIBE_OK, let newSession else {
            transcribe_model_free(newModel)
            AppLogger.shared.error("GigaAM", "Не удалось создать сессию", details: Self.describe(status))
            return false
        }

        var limits = transcribe_session_limits()
        limits.struct_size = UInt64(MemoryLayout<transcribe_session_limits>.size)
        transcribe_session_limits_init(&limits)
        if transcribe_session_get_limits(newSession, &limits) == TRANSCRIBE_OK, limits.effective_max_audio_ms > 0 {
            // Запас в полсекунды, чтобы фрагмент гарантированно влез в лимит модели
            maxChunkSeconds = max(5, Double(limits.effective_max_audio_ms) / 1000.0 - 0.5)
        }

        model = newModel
        session = newSession
        loadedPath = path
        let backendName = transcribe_model_backend(newModel).map { String(cString: $0) } ?? "?"
        AppLogger.shared.info(
            "GigaAM",
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
            AppLogger.shared.info("GigaAM", "Модель выгружена после простоя")
        }
        idleUnload = work
        queue.asyncAfter(deadline: .now() + idleUnloadSeconds, execute: work)
    }

    private func unloadLocked() {
        if let session { transcribe_session_free(session) }
        if let model { transcribe_model_free(model) }
        session = nil
        model = nil
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

    private static func describe(_ status: transcribe_status) -> String {
        transcribe_status_string(Int32(status.rawValue)).map { String(cString: $0) } ?? "код \(status.rawValue)"
    }
}
