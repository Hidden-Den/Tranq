import Foundation

struct TimedWord: Codable, Hashable {
    let text: String
    let start: Double
    let end: Double
}

/// Сборка и нормализация таймингов слов, общая для всех движков распознавания.
enum WordTimings {
    /// Склейка подсловных токенов SentencePiece в слова: «▁» отмечает начало слова.
    /// Служебные токены вида `[_..._]` пропускаются. Время в секундах.
    static func assemble(tokens: [(text: String, start: Double, end: Double)]) -> [TimedWord] {
        var words: [TimedWord] = []
        var currentText = ""
        var wordStart = -1.0
        var wordEnd = -1.0
        for token in tokens {
            var body = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            if body.hasPrefix("[_") && body.hasSuffix("_]") { continue }
            let startsNewWord = body.hasPrefix("▁")
            if startsNewWord { body = String(body.dropFirst()) }
            if body.isEmpty { continue }
            if currentText.isEmpty || startsNewWord {
                if !currentText.isEmpty {
                    words.append(TimedWord(text: currentText, start: max(wordStart, 0), end: max(wordEnd, 0)))
                }
                currentText = body
                wordStart = token.start
                wordEnd = token.end
            } else {
                currentText += body
                wordEnd = token.end
            }
        }
        if !currentText.isEmpty {
            words.append(TimedWord(text: currentText, start: max(wordStart, 0), end: max(wordEnd, 0)))
        }
        return words
    }

    /// Устраняет нулевые и перекрывающиеся интервалы: конец слова не позже начала следующего.
    static func finalize(_ words: [TimedWord]) -> [TimedWord] {
        guard !words.isEmpty else { return [] }
        var result = words
        for i in 0..<(result.count - 1) {
            let nextStart = result[i + 1].start
            var end = result[i].end
            if end <= result[i].start || end >= nextStart { end = nextStart }
            if end <= result[i].start { end = result[i].start + 0.3 }
            result[i] = TimedWord(text: result[i].text, start: result[i].start, end: end)
        }
        let last = result.count - 1
        if result[last].end <= result[last].start {
            result[last] = TimedWord(text: result[last].text, start: result[last].start, end: result[last].start + 0.3)
        }
        return result
    }

    /// Равномерно распределяет слова по интервалу пропорционально их длине.
    static func interpolate(_ words: [TimedWord], from startSecs: Double, to endSecs: Double) -> [TimedWord] {
        guard words.count > 1, endSecs > startSecs else { return words }
        let weights: [Double] = words.map { max(1.0, Double(($0.text as NSString).length)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return words }
        var result: [TimedWord] = []
        var cursor = startSecs
        var acc = 0.0
        for (i, w) in words.enumerated() {
            acc += weights[i]
            let wordEndSecs = startSecs + min(1.0, acc / total) * (endSecs - startSecs)
            result.append(TimedWord(text: w.text, start: cursor, end: max(wordEndSecs, cursor + 0.001)))
            cursor = max(wordEndSecs, cursor + 0.001)
        }
        return result
    }

    static func shifted(_ words: [TimedWord], by offset: Double) -> [TimedWord] {
        words.map { TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
    }
}
