import Foundation
import AppKit

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Субтитры SRT и VTT, экспорт заметок в файлы.
enum SubtitleExporter {
    static func makeCues(from words: [TimedWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var buffer: [String] = []
        var cueStart = 0.0
        var cueEnd = 0.0

        func flush() {
            guard !buffer.isEmpty else { return }
            let end = max(cueEnd, cueStart + 0.5)
            cues.append(SubtitleCue(start: cueStart, end: end, text: buffer.joined(separator: " ")))
            buffer.removeAll()
        }

        for word in words {
            if buffer.isEmpty { cueStart = word.start }
            buffer.append(word.text)
            cueEnd = max(word.end, word.start + 0.2)
            let last = word.text.last
            let isSentenceEnd = last == "." || last == "!" || last == "?" || last == "…"
            if isSentenceEnd || buffer.count >= 12 || (word.end - cueStart) >= 6.0 {
                flush()
            }
        }
        flush()
        return cues
    }

    static func makeCues(fromText text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var t = 0.0
        for sentence in splitIntoSentences(text) {
            let words = sentence.split(separator: " ").count
            let dur = max(1.2, Double(words) * 0.4)
            cues.append(SubtitleCue(start: t, end: t + dur, text: sentence))
            t += dur + 0.05
        }
        return cues
    }

    static func splitIntoSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    static func srtContent(cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    static func vttContent(cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(vttTime(cue.start)) --> \(vttTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    static func srtTime(_ t: Double) -> String { timestamp(t, separator: ",") }
    static func vttTime(_ t: Double) -> String { timestamp(t, separator: ".") }

    private static func timestamp(_ t: Double, separator: String) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, millis)
    }

    /// Экспорт в файл. CSV пишется с BOM, чтобы Excel и Numbers правильно открывали кириллицу.
    static func export(_ item: TranscriptionItem, format: String, history: HistoryStore = .shared) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Сохранить транскрипцию")
        panel.nameFieldStringValue = "Заметка_\(item.date.replacingOccurrences(of: ":", with: "-")).\(format)"
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        let prettyText = TextFormatter.formatIntoParagraphs(item.text)
        let content: String
        switch format.lowercased() {
        case "md":
            content = "# Транскрипция Голосок\n**Дата:** \(item.date)\n**Длительность:** \(item.duration)\n\n---\n\n\(prettyText)"
        case "txt":
            content = "Голосок — Транскрипция\nДата: \(item.date)\nДлительность: \(item.duration)\n\n\(prettyText)"
        case "csv":
            content = "\u{FEFF}\"Дата\",\"Длительность\",\"Текст\"\n\"\(item.date)\",\"\(item.duration)\",\"\(item.text.replacingOccurrences(of: "\"", with: "\"\""))\""
        case "json":
            let dict: [String: Any] = ["id": item.id.uuidString, "date": item.date, "duration": item.duration, "text": item.text]
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
                content = String(data: data, encoding: .utf8) ?? ""
            } else {
                content = ""
            }
        case "srt", "vtt":
            let cues: [SubtitleCue]
            if let timings = history.timings(for: item.id), !timings.words.isEmpty {
                cues = makeCues(from: timings.words)
            } else {
                cues = makeCues(fromText: item.text)
            }
            content = format.lowercased() == "srt" ? srtContent(cues: cues) : vttContent(cues: cues)
        default:
            content = prettyText
        }
        try? content.write(to: saveURL, atomically: true, encoding: .utf8)
    }
}
