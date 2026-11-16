import Foundation
import Combine

enum WordProbeOutcome: Equatable {
    case tooQuiet, tooManyWords, noise, alreadyCorrect, variant(String)
}

/// Одна запись слова голосом: что услышал распознаватель, то и становится вариантом.
final class WordProbe: ObservableObject {
    static let maxSeconds: TimeInterval = 3
    static let silenceSeconds: TimeInterval = 0.6
    static let speechDb: Float = -45
    static let quietDb: Float = -40

    @Published var level: Float = -60

    private let recorder = AudioRecorder()
    private var token = UUID()
    private var peakDb: Float = -160
    private var lastLoudAt: TimeInterval?
    private var active = false
    private var deadline: DispatchWorkItem?

    deinit {
        deadline?.cancel()
        recorder.cancel()
    }

    /// Пора останавливать: истёк лимит или после начала речи прошла тишина.
    static func shouldStop(elapsed: TimeInterval, peakDb: Float, lastLoudAt: TimeInterval?, now: TimeInterval) -> Bool {
        if elapsed >= maxSeconds { return true }
        guard peakDb >= speechDb, let lastLoudAt else { return false }
        return now - lastLoudAt >= silenceSeconds
    }

    static func evaluate(recognized: String, spelling: String, peakDb: Float, language: DictionaryLanguage) -> WordProbeOutcome {
        if peakDb < quietDb { return .tooQuiet }
        let cleaned = clean(DisfluencyPrefilter.filter(recognized))
        if cleaned.isEmpty { return .noise }
        if cleaned.split(separator: " ").count > 3 { return .tooManyWords }
        if cleaned == spelling.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) { return .alreadyCorrect }
        return .variant(cleaned)
    }

    /// Нижний регистр, без пунктуации кроме - . / внутри слов.
    private static func clean(_ text: String) -> String {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).compactMap { raw -> String? in
            let word = raw.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
            let kept = word.filter { $0.isLetter || $0.isNumber || "-./".contains($0) }
            return kept.contains(where: { $0.isLetter || $0.isNumber }) ? kept : nil
        }
        return words.joined(separator: " ")
    }

    /// Запись и распознавание. `completion` вызывается на главном потоке ровно один раз, кроме случая `cancel`.
    func start(spelling: String, completion: @escaping (WordProbeOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        let session = UUID()
        token = session
        peakDb = -160
        lastLoudAt = nil
        level = -60

        let started = recorder.start { [weak self] power, elapsed in
            guard let self, self.token == session, self.active else { return }
            self.level = power
            self.peakDb = max(self.peakDb, power)
            if power >= Self.speechDb { self.lastLoudAt = elapsed }
            if Self.shouldStop(elapsed: elapsed, peakDb: self.peakDb, lastLoudAt: self.lastLoudAt, now: elapsed) {
                self.finish(spelling: spelling, session: session, completion: completion)
            }
        }
        if started {
            active = true
            // Независимый предел: не зависит от колбэков измерителя.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.token == session, self.active else { return }
                self.finish(spelling: spelling, session: session, completion: completion)
            }
            deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSeconds, execute: work)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == session else { return }
                completion(.noise)
            }
        }
    }

    /// Безопасно в любом состоянии: останавливает запись и удаляет файл, результат не доставляется.
    func cancel() {
        token = UUID()
        active = false
        deadline?.cancel()
        deadline = nil
        recorder.cancel()
        level = -60
    }

    private func finish(spelling: String, session: UUID, completion: @escaping (WordProbeOutcome) -> Void) {
        active = false
        deadline?.cancel()
        deadline = nil
        let peak = peakDb
        guard let recording = recorder.stop() else {
            completion(.noise)
            return
        }
        level = -60
        let language = DictionaryLanguage.current
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { TempFiles.remove(recording.url) }
            var text = ""
            if let recognizer = SpeechRecognizerFactory.current(),
               let reader = AudioChunkReader(url: recording.url),
               let samples = reader.samples(fromSecond: 0, length: min(reader.durationSeconds, Self.maxSeconds + 1)) {
                text = recognizer.recognize(samples: samples).text
            }
            let outcome = Self.evaluate(recognized: text, spelling: spelling, peakDb: peak, language: language)
            DispatchQueue.main.async {
                guard let self, self.token == session else { return }
                completion(outcome)
            }
        }
    }
}
