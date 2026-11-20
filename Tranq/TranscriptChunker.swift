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

    /// Куски речи по порядку. Склейка через пробел даёт исходный текст.
    static func chunks(_ text: String) -> [String] {
        guard text.count > threshold else { return [text] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences(text) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= target {
                current += " " + sentence
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

    /// Предложения без пробелов между ними. Конец предложения это знак конца,
    /// за которым идёт пробел: точка внутри «3.5» предложение не заканчивает.
    static func sentences(_ text: String) -> [String] {
        let enders: Set<Character> = [".", "!", "?", "…"]
        var result: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if char == " ", let last = current.last, enders.contains(last) {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = next
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
