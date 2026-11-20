import Foundation

/// Нарезка длинной речи на куски для очистки.
///
/// Замер 20.11.2026, haiku 5.5: на диктовке в 395 слов модель перестала чистить и стала
/// пересказывать, срезала половину текста и потеряла все числа. Валидатор справедливо
/// отклонил ответ, и вместе с одним потерянным числом пропала очистка трёх минут речи.
/// Кусок до 800 знаков модель чистит, а отказ по нему стоит одного абзаца, а не всего.
///
/// Режется только по концу предложения: точке, вопросу, восклицанию или многоточию,
/// за которыми идёт пробел. Предложение длиннее цели не рвётся посередине.
enum TranscriptChunker {
    /// Речь до этого размера идёт одним запросом: модель видит её целиком и сводит
    /// повторы мыслей по всему тексту. Это полторы-две минуты речи.
    static let threshold = 1200
    /// Желаемый размер куска.
    static let target = 800
    /// Кусок меньше этого приклеивается к соседу: на одно-два предложения модель
    /// отвечает как на обращение к себе, а не чистит.
    static let minimum = 200

    /// Куски речи по порядку. Каждый кусок это непрерывный отрезок исходного текста.
    static func chunks(_ text: String) -> [String] {
        guard text.count > threshold else { return [text] }

        var chunks: [String] = []
        var current = ""
        for (separator, sentence) in segments(text) {
            if current.isEmpty {
                current = sentence
            } else if current.count + separator.count + sentence.count <= target || current.count < minimum {
                // Короткий кусок не уходит отдельно и в середине речи, даже ценой размера
                current += separator + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }

        // Крошечный хвост к предыдущему куску, даже если тот выйдет за цель
        if chunks.count > 1, let last = chunks.last, last.count < minimum {
            chunks.removeLast()
            chunks[chunks.count - 1] += " " + last
        }
        return chunks
    }

    /// Знаки, которые закрывают цитату или скобку после конца предложения: «…закрываем».
    private static let closers: Set<Character> = ["»", "\"", "”", "’", ")"]

    /// Предложения с пробельным разделителем перед каждым. Конец предложения это знак
    /// конца, за которым, возможно после кавычки, идёт пробел или перенос строки:
    /// точка внутри «3.5» предложение не заканчивает.
    static func segments(_ text: String) -> [(separator: String, sentence: String)] {
        let enders: Set<Character> = [".", "!", "?", "…"]
        var result: [(String, String)] = []
        var separator = ""
        var current = ""
        var gap = ""
        for char in text {
            if char.isWhitespace {
                let core = current.reversed().first { !closers.contains($0) }
                if gap.isEmpty, let core, enders.contains(core) {
                    result.append((separator, current))
                    separator = ""
                    current = ""
                    gap.append(char)
                    continue
                }
                if !gap.isEmpty { gap.append(char); continue }
                current.append(char)
            } else {
                if !gap.isEmpty { separator = gap; gap = "" }
                current.append(char)
            }
        }
        if !current.isEmpty { result.append((separator, current)) }
        return result
    }
}
