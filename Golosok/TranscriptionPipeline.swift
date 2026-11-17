import Foundation

/// Полный путь от звука до текста: распознавание фрагментами, затем по
/// желанию языковая модель, валидация и словарь пользователя.
///
/// Задания выполняются строго по одному на последовательной очереди, поэтому
/// быстрые диктовки подряд не мешают друг другу и не делят временные файлы.
final class TranscriptionPipeline {
    static let shared = TranscriptionPipeline()

    enum Source {
        /// Запись микрофона: WAV 16 кГц моно, удаляется вызывающим.
        case recording(URL, duration: TimeInterval)
        /// Импортированный файл любого поддерживаемого формата.
        case mediaFile(URL)

        var isFileImport: Bool {
            if case .mediaFile = self { return true }
            return false
        }
    }

    struct Job {
        let source: Source
        let focusTarget: FocusSnapshot?
        /// Уровень очистки; `nil` для импорта файлов: текст остаётся как распознан.
        let level: CleanupLevel?
    }

    struct Output {
        let noteId: UUID
        let rawText: String
        let stageOneText: String
        let finalText: String
        let isTransformedByAI: Bool
        /// Почему вместо ответа модели вставлен текст без ИИ; пусто, если откатов не было.
        let fallback: FallbackReason?
        let words: [TimedWord]
        let audioSeconds: Double
        let speedup: Double
        /// WAV для прослушивания заметки; вызывающий решает, сохранить ли его.
        let audioURL: URL
        let ownsAudioFile: Bool
    }

    enum Failure: Error {
        case noRecognizer
        case audioUnreadable
        case nothingRecognized(audioSeconds: Double)
    }

    /// Насколько назад от границы фрагмента искать паузу, в секундах.
    private let silenceSearchWindow: Double = 4.0
    private let queue = DispatchQueue(label: "golosok.pipeline", qos: .userInitiated)

    private init() {}

    /// Запускает задание. `progress` и `completion` вызываются на главном потоке.
    func run(
        _ job: Job,
        onStageTwoStarted: @escaping () -> Void = {},
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Output, Failure>) -> Void
    ) {
        queue.async { [self] in
            let stageOne = recognize(job.source, progress: progress)
            switch stageOne {
            case .failure(let failure):
                DispatchQueue.main.async { completion(.failure(failure)) }
            case .success(let recognized):
                finish(job: job, recognized: recognized, onStageTwoStarted: onStageTwoStarted, completion: completion)
            }
        }
    }

    // MARK: - Этап 1: распознавание

    private struct Recognized {
        let rawText: String
        let words: [TimedWord]
        let audioSeconds: Double
        let processingSeconds: Double
        let audioURL: URL
        let ownsAudioFile: Bool
    }

    private func recognize(_ source: Source, progress: @escaping (Double) -> Void) -> Result<Recognized, Failure> {
        let started = Date()
        guard let recognizer = SpeechRecognizerFactory.current() else { return .failure(.noRecognizer) }

        let audioURL: URL
        let ownsAudioFile: Bool
        switch source {
        case .recording(let url, _):
            audioURL = url
            ownsAudioFile = false
        case .mediaFile(let url):
            let converted = TempFiles.makeURL(prefix: "import", ext: "wav")
            guard AudioPCM.convertMediaToWav(url, output: converted) else {
                TempFiles.remove(converted)
                return .failure(.audioUnreadable)
            }
            audioURL = converted
            ownsAudioFile = true
        }

        guard let reader = AudioChunkReader(url: audioURL) else {
            if ownsAudioFile { TempFiles.remove(audioURL) }
            return .failure(.audioUnreadable)
        }

        let audioSeconds: Double
        if case .recording(_, let duration) = source, duration > 0 {
            audioSeconds = duration
        } else {
            audioSeconds = reader.durationSeconds
        }

        AppLogger.shared.info("Pipeline", "Этап 1: Распознавание через \(recognizer.displayName)", details: String(format: "аудио %.1f с", reader.durationSeconds))

        var texts: [String] = []
        var words: [TimedWord] = []
        var cursor = 0.0
        let total = reader.durationSeconds
        while cursor < total - 0.05 {
            let chunkLength = recognizer.maxChunkSeconds
            guard let window = reader.samples(fromSecond: cursor, length: chunkLength), !window.isEmpty else { break }

            var cutSamples = window.count
            let reachesEnd = cursor + chunkLength >= total
            if !reachesEnd {
                cutSamples = Self.quietestCut(in: window, searchSeconds: silenceSearchWindow)
            }
            let chunk = cutSamples == window.count ? window : Array(window[0..<cutSamples])

            let result = autoreleasepool { recognizer.recognize(samples: chunk) }
            if !result.text.isEmpty { texts.append(result.text) }
            words.append(contentsOf: WordTimings.shifted(result.words, by: cursor))

            cursor += Double(cutSamples) / AudioPCM.sampleRate
            let fraction = min(1.0, cursor / max(total, 0.001))
            DispatchQueue.main.async { progress(fraction) }
        }

        let rawText = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.info("Pipeline", "Этап 1 завершён: \(recognizer.displayName)", details: "Распознано: «\(rawText)», слов: \(words.count)")
        guard !rawText.isEmpty else {
            if ownsAudioFile { TempFiles.remove(audioURL) }
            return .failure(.nothingRecognized(audioSeconds: audioSeconds))
        }
        return .success(Recognized(
            rawText: rawText,
            words: words,
            audioSeconds: audioSeconds,
            processingSeconds: Date().timeIntervalSince(started),
            audioURL: audioURL,
            ownsAudioFile: ownsAudioFile
        ))
    }

    /// Ищет самую тихую точку в последних `searchSeconds` окна, чтобы не резать слово пополам.
    /// Возвращает число сэмплов, которые войдут в текущий фрагмент.
    static func quietestCut(in samples: [Float], searchSeconds: Double) -> Int {
        let frame = Int(AudioPCM.sampleRate * 0.02)
        let searchSamples = min(samples.count / 2, Int(AudioPCM.sampleRate * searchSeconds))
        guard frame > 0, searchSamples > frame else { return samples.count }
        var bestEnd = samples.count
        var bestEnergy = Float.greatestFiniteMagnitude
        var end = samples.count
        let lowerBound = samples.count - searchSamples
        while end - frame >= lowerBound {
            var energy: Float = 0
            for i in (end - frame)..<end { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestEnd = end - frame / 2
            }
            end -= frame
        }
        return bestEnd
    }

    // MARK: - Этап 2: языковая модель

    private func finish(
        job: Job,
        recognized: Recognized,
        onStageTwoStarted: @escaping () -> Void,
        completion: @escaping (Result<Output, Failure>) -> Void
    ) {
        let stageOneText = TextFormatter.formatIntoParagraphs(recognized.rawText)
        let speedup = max(1.0, recognized.audioSeconds / max(0.1, recognized.processingSeconds))
        let noteId = UUID()
        let target = job.focusTarget
        let language = DictionaryLanguage.current
        // Словарь применяется до модели: модель получает текст уже с заменами
        let dictionary = DictionaryStage.apply(stageOneText, noteId: noteId, language: language)

        DispatchQueue.main.async {
            // Фиксируем исходный сырой транскрипт до любых ИИ-манипуляций
            TranscriptJournal.shared.recordInitial(
                id: noteId,
                rawText: recognized.rawText,
                durationSec: recognized.audioSeconds,
                targetAppName: target?.appName,
                targetPid: target?.pid,
                targetBundleId: target?.bundleIdentifier
            )

            func deliver(finalText: String, transformed: Bool, fallback: FallbackReason?) {
                TranscriptJournal.shared.updateFinal(
                    id: noteId,
                    stageOneText: stageOneText,
                    finalText: finalText,
                    isFallback: fallback != nil
                )
                completion(.success(Output(
                    noteId: noteId,
                    rawText: recognized.rawText,
                    stageOneText: stageOneText,
                    finalText: finalText,
                    isTransformedByAI: transformed,
                    fallback: fallback,
                    words: recognized.words,
                    audioSeconds: recognized.audioSeconds,
                    speedup: speedup,
                    audioURL: recognized.audioURL,
                    ownsAudioFile: recognized.ownsAudioFile
                )))
                DictionaryStage.shadowFuzzy(finalText, language: language)
            }

            guard let level = job.level else {
                let direct = dictionary.text
                AppLogger.shared.info("Pipeline", "Этап 2 пропущен: импорт файла", details: "Итог: «\(direct)»")
                deliver(finalText: direct, transformed: false, fallback: nil)
                return
            }

            let settings = VoiceIntelligenceSettings.shared
            AppLogger.shared.info("Pipeline", "Этап 2: очистка речи, движок \(settings.engine.title)", details: "уровень: \(level)")
            if level != .verbatim { onStageTwoStarted() }
            Task {
                let cleaned = await ThoughtSynthesizer.shared.clean(
                    dictionary.text,
                    level: level,
                    targetBundleId: target?.bundleIdentifier,
                    firedSpellings: dictionary.fired,
                    language: language
                )
                DispatchQueue.main.async {
                    // Повторный проход страхует от вариантов, которые вернула модель
                    var resolved = DictionaryStage.apply(
                        cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines), noteId: noteId, language: language,
                        warnIfNotReady: false
                    ).text
                    if resolved.isEmpty {
                        resolved = dictionary.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard !resolved.isEmpty else {
                        AppLogger.shared.warn("Recognition", "Текст пуст после очистки от слов-паразитов")
                        if recognized.ownsAudioFile { TempFiles.remove(recognized.audioURL) }
                        completion(.failure(.nothingRecognized(audioSeconds: recognized.audioSeconds)))
                        return
                    }
                    let isFallback = cleaned.fallback != nil
                    AppLogger.shared.info("Pipeline", "✔ Пайплайн завершён: \(isFallback ? "откат на распознанный текст" : "очистка выполнена")", details: "Финальный текст: «\(resolved)»")
                    deliver(finalText: resolved, transformed: level != .verbatim && !isFallback, fallback: cleaned.fallback)
                }
            }
        }
    }
}
