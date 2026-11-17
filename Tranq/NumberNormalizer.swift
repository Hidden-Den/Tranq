import Foundation

public struct NumberNormalizer {

    private static let units: [String: Int] = [
        "ноль": 0, "нуль": 0,
        "один": 1, "одна": 1, "одно": 1, "одного": 1, "одному": 1, "одним": 1, "одном": 1,
        "два": 2, "две": 2, "двух": 2, "двум": 2, "двумя": 2,
        "три": 3, "трех": 3, "трёх": 3, "трем": 3, "трём": 3, "тремя": 3,
        "четыре": 4, "четырех": 4, "четырёх": 4, "четырем": 4, "четырём": 4, "четырьмя": 4,
        "пять": 5, "пяти": 5, "пятью": 5,
        "шесть": 6, "шести": 6, "шестью": 6,
        "семь": 7, "семи": 7, "семью": 7,
        "восемь": 8, "восьми": 8, "восемью": 8,
        "девять": 9, "девяти": 9, "девятью": 9
    ]

    private static let teens: [String: Int] = [
        "десять": 10, "десяти": 10, "десятью": 10,
        "одиннадцать": 11, "одиннадцати": 11,
        "двенадцать": 12, "двенадцати": 12,
        "тринадцать": 13, "тринадцати": 13,
        "четырнадцать": 14, "четырнадцати": 14,
        "пятнадцать": 15, "пятнадцати": 15,
        "шестнадцать": 16, "шестнадцати": 16,
        "семнадцать": 17, "семнадцати": 17,
        "восемнадцать": 18, "восемнадцати": 18,
        "девятнадцать": 19, "девятнадцати": 19
    ]

    private static let tens: [String: Int] = [
        "двадцать": 20, "двадцати": 20,
        "тридцать": 30, "тридцати": 30,
        "сорок": 40, "сорока": 40,
        "пятьдесят": 50, "пятидесяти": 50,
        "шестьдесят": 60, "шестидесяти": 60,
        "семьдесят": 70, "семидесяти": 70,
        "восемьдесят": 80, "восьмидесяти": 80,
        "девяносто": 90, "девяноста": 90
    ]

    private static let hundreds: [String: Int] = [
        "сто": 100, "ста": 100,
        "двести": 200, "двухсот": 200,
        "триста": 300, "трехсот": 300, "трёхсот": 300,
        "четыреста": 400, "четырехсот": 400, "четырёхсот": 400,
        "пятьсот": 500, "пятисот": 500,
        "шестьсот": 600, "шестисот": 600,
        "семьсот": 700, "семисот": 700,
        "восемьсот": 800, "восьмисот": 800,
        "девятьсот": 900, "девятисот": 900
    ]

    private static let scales: [String: Int] = [
        "тысяча": 1000, "тысячи": 1000, "тысяч": 1000,
        "миллион": 1_000_000, "миллиона": 1_000_000, "миллионов": 1_000_000,
        "миллиард": 1_000_000_000, "миллиарда": 1_000_000_000, "миллиардов": 1_000_000_000
    ]

    private static let ordinals: [String: Int] = [
        "первый": 1, "первого": 1, "первом": 1, "первая": 1, "первое": 1, "первую": 1,
        "второй": 2, "второго": 2, "втором": 2, "вторая": 2, "второе": 2, "вторую": 2,
        "третий": 3, "третьего": 3, "третьем": 3, "третья": 3, "третье": 3, "третью": 3,
        "четвертый": 4, "четвертого": 4, "четвертом": 4, "четвертая": 4, "четвертое": 4,
        "пятый": 5, "пятого": 5, "пятом": 5, "пятая": 5, "пятое": 5,
        "шестой": 6, "шестого": 6, "шестом": 6, "шестая": 6, "шестое": 6,
        "седьмой": 7, "седьмого": 7, "седьмом": 7, "седьмая": 7, "седьмое": 7,
        "восьмой": 8, "восьмого": 8, "восьмом": 8, "восьмая": 8, "восьмое": 8,
        "девятый": 9, "девятого": 9, "девятом": 9, "девятая": 9, "девятое": 9,
        "десятый": 10, "десятого": 10, "десятом": 10, "десятая": 10, "десятое": 10,
        "одиннадцатый": 11, "одиннадцатого": 11,
        "двенадцатый": 12, "двенадцатого": 12,
        "тринадцатый": 13, "тринадцатого": 13,
        "четырнадцатый": 14, "четырнадцатого": 14,
        "пятнадцатый": 15, "пятнадцатого": 15,
        "шестнадцатый": 16, "шестнадцатого": 16,
        "семнадцатый": 17, "семнадцатого": 17,
        "восемнадцатый": 18, "восемнадцатого": 18,
        "девятнадцатый": 19, "девятнадцатого": 19,
        "двадцатый": 20, "двадцатого": 20,
        "тридцатый": 30, "тридцатого": 30
    ]

    private static let fractionWords: Set<String> = ["полтора", "полторы", "пол"]

    private static let monthNames: Set<String> = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря"
    ]

    /// Преобразование словесных числительных в цифры
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Токенизация с сохранением пунктуации
        let tokens = tokenize(text)
        var resultTokens: [String] = []
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            let lower = token.word.lowercased()

            // 1. Проверяем, не является ли это датой перед месяцем (например: "двадцать шестого мая")
            if let dateRange = tryParseDate(tokens: tokens, startIndex: i) {
                resultTokens.append(dateRange.formatted)
                i = dateRange.nextIndex
                continue
            }

            // 2. Проверяем время (например: "пятнадцать тридцать")
            if let timeRange = tryParseTime(tokens: tokens, startIndex: i) {
                resultTokens.append(timeRange.formatted)
                i = timeRange.nextIndex
                continue
            }

            // 3. Проверяем составное число
            if let firstRank = getRank(lower) {
                var numberTokens: [(val: Int, scale: Bool)] = []
                var j = i
                var lastRank = firstRank

                while j < tokens.count {
                    let w = tokens[j].word.lowercased()
                    guard let rank = getRank(w) else { break }

                    if j > i && !canFollow(prev: lastRank, next: rank) {
                        break
                    }

                    if let s = scales[w] {
                        numberTokens.append((s, true))
                    } else if let v = valueOfWord(w) {
                        numberTokens.append((v, false))
                    }

                    lastRank = rank
                    let hasPunct = !tokens[j].trailingPunctuation.isEmpty
                    j += 1
                    if hasPunct {
                        break
                    }
                }

                // Порядковые вне дат остаются словами: «вторую кандидатку» не «2 кандидатку».
                // Иначе модель читает цифру как количество и пишет «двух кандидаток».
                let words = tokens[i..<j].map { $0.word.lowercased() }
                let hasOrdinal = words.contains { ordinals[$0] != nil }
                // «Полтора миллиона» — не «полтора 1000000»
                let previous = i > 0 ? tokens[i - 1].word.lowercased() : ""
                let loneScaleAfterFraction = words.allSatisfy { scales[$0] != nil } && fractionWords.contains(previous)
                if hasOrdinal || loneScaleAfterFraction {
                    resultTokens.append(contentsOf: tokens[i..<j].map(\.raw))
                    i = j
                    continue
                }

                if !numberTokens.isEmpty {
                    let total = calculateCompoundValue(numberTokens)
                    let trailingPunct = tokens[j - 1].trailingPunctuation
                    resultTokens.append("\(total)\(trailingPunct)")
                    i = j
                    continue
                }
            }

            // 4. Обычное слово
            resultTokens.append(token.raw)
            i += 1
        }

        return resultTokens.joined(separator: " ")
    }

    // MARK: - Вспомогательные методы парсинга

    private struct Token {
        let raw: String
        let word: String
        let trailingPunctuation: String
    }

    private static func tokenize(_ text: String) -> [Token] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.map { raw in
            var cleanWord = raw
            var punct = ""
            while let last = cleanWord.last, last.isPunctuation {
                punct.insert(cleanWord.removeLast(), at: punct.startIndex)
            }
            return Token(raw: raw, word: cleanWord, trailingPunctuation: punct)
        }
    }

    private enum NumRank: Int {
        case unit = 1
        case teen = 2
        case ten = 3
        case hundred = 4
        case scale = 5
    }

    private static func getRank(_ word: String) -> NumRank? {
        if scales[word] != nil { return .scale }
        if hundreds[word] != nil { return .hundred }
        if tens[word] != nil { return .ten }
        if teens[word] != nil { return .teen }
        if units[word] != nil || ordinals[word] != nil { return .unit }
        return nil
    }

    private static func canFollow(prev: NumRank, next: NumRank) -> Bool {
        if next == .scale { return true }
        if prev == .scale { return true }
        if prev == .hundred && (next == .ten || next == .teen || next == .unit) { return true }
        if prev == .ten && next == .unit { return true }
        return false
    }

    private static func valueOfWord(_ word: String) -> Int? {
        units[word] ?? teens[word] ?? tens[word] ?? hundreds[word] ?? ordinals[word]
    }

    private static func calculateCompoundValue(_ tokens: [(val: Int, scale: Bool)]) -> Int {
        var total = 0
        var current = 0

        for t in tokens {
            if t.scale {
                if current == 0 { current = 1 }
                total += current * t.val
                current = 0
            } else {
                current += t.val
            }
        }
        total += current
        return total
    }

    private static func tryParseDate(tokens: [Token], startIndex: Int) -> (formatted: String, nextIndex: Int)? {
        guard startIndex < tokens.count else { return nil }

        // Ищем паттерны:
        // [число_слово] [порядковое_число] [месяц] -> "26 мая"
        // или [порядковое_число] [месяц] -> "5 мая"
        var candidateNumbers: [Int] = []
        var j = startIndex

        while j < tokens.count && j < startIndex + 3 {
            let lower = tokens[j].word.lowercased()
            if monthNames.contains(lower) {
                // Если перед месяцем были числа
                if !candidateNumbers.isEmpty {
                    let day = candidateNumbers.reduce(0, +)
                    if day >= 1 && day <= 31 {
                        let punct = tokens[j].trailingPunctuation
                        return ("\(day) \(tokens[j].word)\(punct)", j + 1)
                    }
                }
                return nil
            } else if let v = tens[lower] ?? units[lower] ?? teens[lower] ?? ordinals[lower] {
                candidateNumbers.append(v)
                j += 1
            } else {
                break
            }
        }
        return nil
    }

    private static func tryParseTime(tokens: [Token], startIndex: Int) -> (formatted: String, nextIndex: Int)? {
        guard startIndex + 1 < tokens.count else { return nil }
        let hWord = tokens[startIndex].word.lowercased()
        let mWord = tokens[startIndex + 1].word.lowercased()

        // Числа вида tens + units (например "двадцать пять") — это число 25, а не время 20:05!
        if tens[hWord] != nil && units[mWord] != nil {
            return nil
        }

        let hourVal = tens[hWord] ?? teens[hWord] ?? units[hWord]
        let minVal = tens[mWord] ?? teens[mWord]

        if let h = hourVal, let m = minVal, h >= 0 && h <= 23 && m >= 10 && m <= 59 {
            let punct = tokens[startIndex + 1].trailingPunctuation
            return ("\(h):\(m)\(punct)", startIndex + 2)
        }
        return nil
    }
}
