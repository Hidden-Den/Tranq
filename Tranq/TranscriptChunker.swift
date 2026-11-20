import Foundation

/// Нарезка длинной речи на куски для очистки.
///
/// Замер 20.11.2026, haiku 5.5: на диктовке в 395 слов модель перестала чистить и стала
/// пересказывать, срезала половину текста и потеряла все числа. Валидатор справедливо
/// отклонил ответ, и вместе с одним потерянным числом пропала очистка трёх минут речи.
/// Кусок до 800 знаков модель чистит, а отказ по нему стоит одного абзаца, а не всего.
///
/// Режется только по концу предложения: точке, вопросу, восклицанию или многоточию,
/// за которыми идёт пробел, или по переводу строки между абзацами. Предложение длиннее
/// цели не рвётся посередине. Если в куске есть граница абзаца, кусок кончается на ней:
/// очищенные куски склеиваются абзацами, и абзацы этапа 1 остаются на своих местах.
enum TranscriptChunker {
    /// Речь до этого размера идёт одним запросом: модель видит её целиком и сводит
    /// повторы мыслей по всему тексту. Это полторы-две минуты речи.
    static let threshold = 1200
    /// Желаемый размер куска.
    static let target = 800
    /// Кусок меньше этого приклеивается к соседу: на одно-два предложения модель
    /// отвечает как на обращение к себе, а не чистит.
    static let minimum = 200

    /// Предложение и пробел или переводы строк перед ним, как в исходном тексте.
    private struct Unit {
        let gap: String
        let text: String
        var startsParagraph: Bool { gap.contains(where: \.isNewline) }
    }

    /// Куски речи по порядку, без пробелов по краям. Если вернуть между ними
    /// исходный пробел или перевод строки, получится исходный текст.
    static func chunks(_ text: String) -> [String] {
        guard text.count > threshold else { return [text] }
        let units = self.units(text)
        guard !units.isEmpty else { return [text] }

        func length(_ range: Range<Int>) -> Int {
            units[range].reduce(0) { $0 + $1.gap.count + $1.text.count } - units[range.lowerBound].gap.count
        }

        var bounds: [Range<Int>] = []
        var start = 0
        var end = 1
        while end < units.count {
            if length(start..<(end + 1)) <= target {
                end += 1
                continue
            }
            // Кусок полон: режем по последней границе абзаца, если кусок до неё не крошечный
            let paragraphCut = ((start + 1)...end).last { units[$0].startsParagraph && length(start..<$0) >= minimum }
            let cut = paragraphCut ?? end
            bounds.append(start..<cut)
            start = cut
            end = cut + 1
        }
        bounds.append(start..<units.count)

        // Крошечный хвост к предыдущему куску, даже если тот выйдет за цель
        if bounds.count > 1, let last = bounds.last, length(last) < minimum {
            bounds.removeLast()
            bounds[bounds.count - 1] = bounds[bounds.count - 1].lowerBound..<last.upperBound
        }
        return bounds.map { range in
            units[range].enumerated().map { $0.offset == 0 ? $0.element.text : $0.element.gap + $0.element.text }.joined()
        }
    }

    /// Предложения без пробелов между ними. Конец предложения это знак конца,
    /// за которым идёт пробел, или перевод строки: точка внутри «3.5» предложение не заканчивает.
    static func sentences(_ text: String) -> [String] {
        units(text).map(\.text)
    }

    private static func units(_ text: String) -> [Unit] {
        let enders: Set<Character> = [".", "!", "?", "…"]
        var result: [Unit] = []
        var gap = ""
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace {
                // Пробелы до следующего непробельного знака
                var next = index
                var run = ""
                while next < text.endIndex, text[next].isWhitespace {
                    run.append(text[next])
                    next = text.index(after: next)
                }
                let endsSentence = current.last.map(enders.contains) == true || run.contains(where: \.isNewline)
                if current.isEmpty {
                    gap += run
                } else if endsSentence {
                    result.append(Unit(gap: gap, text: current))
                    gap = run
                    current = ""
                } else {
                    current += run
                }
                index = next
            } else {
                current.append(char)
                index = text.index(after: index)
            }
        }
        if !current.isEmpty { result.append(Unit(gap: gap, text: current)) }
        return result
    }
}
