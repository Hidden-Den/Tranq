import Foundation
import AVFoundation

/// Whisper через whisper-cli. Модель грузится на каждый фрагмент, поэтому
/// это запасной путь для английских моделей; основной русский движок — `GigaAMEngine`.
final class WhisperCLIEngine: SpeechRecognizer {
    let model: RecognitionModel
    let maxChunkSeconds: Double = 25.0
    var displayName: String { "Whisper \(model.name)" }

    /// На случай зависания CLI: щедрый запас относительно реального времени фрагмента.
    private let processTimeout: TimeInterval = 120

    init(model: RecognitionModel) {
        self.model = model
    }

    func prewarm() {}

    func recognize(samples: [Float]) -> RecognitionResult {
        guard let cliPath = Bundle.main.path(forResource: "whisper-cli", ofType: nil),
              let modelPath = ModelStore.shared.localModelPath(for: model.id) else {
            AppLogger.shared.error("Recognition", "whisper-cli или модель \(model.id) не найдены", details: model.id)
            return .empty
        }
        let wavURL = TempFiles.makeURL(prefix: "whisper", ext: "wav")
        let jsonURL = wavURL.appendingPathExtension("json")
        defer {
            TempFiles.remove(wavURL)
            TempFiles.remove(jsonURL)
        }
        // json пишет whisper-cli: заводим файл заранее закрытым, он дописывает в него
        TempFiles.createPrivateFile(at: jsonURL)
        guard AudioPCM.writeWav(samples: samples, to: wavURL) else { return .empty }

        var arguments = ["-m", modelPath, "-f", wavURL.path, "-l", model.languageCode, "-nt", "-ojf"]
        // Слова из словаря как начальный контекст: Whisper охотнее пишет их как надо
        let vocabulary = DictionaryStore.shared.recognizerPrompt()
        if !vocabulary.isEmpty {
            arguments += ["--prompt", vocabulary]
        }

        guard let result = ProcessRunner.run(
            cliPath,
            arguments: arguments,
            timeout: processTimeout
        ) else { return .empty }
        TempFiles.restrict(jsonURL)
        if !result.succeeded {
            AppLogger.shared.warn(
                "Recognition",
                result.timedOut ? "whisper-cli не уложился в таймаут" : "whisper-cli завершился с ошибкой",
                details: "код \(result.status). \(result.stderr.suffix(400))"
            )
        }

        let text = result.stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.lowercased().hasPrefix("whisper") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(samples.count) / AudioPCM.sampleRate
        let words = Self.readWords(jsonURL: jsonURL, audioDuration: duration)
        return RecognitionResult(text: text, words: words)
    }

    private static func readWords(jsonURL: URL, audioDuration: Double) -> [TimedWord] {
        guard let data = try? Data(contentsOf: jsonURL) else {
            AppLogger.shared.warn("Recognition", "whisper JSON не найден", details: jsonURL.lastPathComponent)
            return []
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transcription = json["transcription"] as? [[String: Any]] else { return [] }

        var words: [TimedWord] = []
        for entry in transcription {
            guard let tokens = entry["tokens"] as? [[String: Any]] else { continue }

            var segmentWords: [TimedWord] = []
            var currentText = ""
            var wordStart = -1.0
            var wordEnd = -1.0
            var reliable = true
            var lastEnd = -1.0

            func appendSegmentWord(_ text: String, _ start: Double, _ end: Double) {
                segmentWords.append(TimedWord(text: text, start: max(start, 0), end: max(end, 0)))
                if start < 0 || end < 0 || end <= start || start < lastEnd { reliable = false }
                lastEnd = max(lastEnd, end)
            }

            for token in tokens {
                guard let raw = token["text"] as? String,
                      let offsets = token["offsets"] as? [String: Any],
                      let fromMs = offsets["from"] as? Double,
                      let toMs = offsets["to"] as? Double else { continue }
                let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || (body.hasPrefix("[_") && body.hasSuffix("_]")) { continue }
                if currentText.isEmpty || raw.hasPrefix(" ") {
                    if !currentText.isEmpty { appendSegmentWord(currentText, wordStart, wordEnd) }
                    currentText = body
                    wordStart = fromMs / 1000
                    wordEnd = toMs / 1000
                } else {
                    currentText += body
                    wordEnd = toMs / 1000
                }
            }
            if !currentText.isEmpty { appendSegmentWord(currentText, wordStart, wordEnd) }

            if !reliable && segmentWords.count > 1 {
                let offsets = entry["offsets"] as? [String: Any]
                var fromSecs = ((offsets?["from"] as? Double) ?? 0) / 1000.0
                var toSecs = ((offsets?["to"] as? Double) ?? 0) / 1000.0
                if audioDuration > 0 {
                    fromSecs = min(max(fromSecs, 0), audioDuration)
                    toSecs = min(toSecs, audioDuration)
                }
                if toSecs <= fromSecs { toSecs = fromSecs + Double(segmentWords.count) * 0.3 }
                segmentWords = WordTimings.interpolate(segmentWords, from: fromSecs, to: toSecs)
            }
            words.append(contentsOf: segmentWords)
        }
        return WordTimings.finalize(words)
    }
}
