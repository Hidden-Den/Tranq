import Foundation

/// Детерминированный префильтр однозначного речевого шума и заиканий
public struct DisfluencyPrefilter {

    /// Регулярные выражения для однозначных звуковых паразитов и хезитаций
    private static let fillerPatterns: [String] = [
        // Русские однозначные паузные заполнители
        #"(?i)(?<=^|\s)[эе]?[эе]{2,}(?=[,\s.!?]|$)"#,       // эээ, еее, ээ
        #"(?i)(?<=^|\s)[мm]{2,}(?=[,\s.!?]|$)"#,             // мм, ммм
        #"(?i)(?<=^|\s)[аa]{3,}(?=[,\s.!?]|$)"#,             // ааа, аааа
        #"(?i)(?<=^|\s)н[уu]{2,}(?=[,\s.!?]|$)"#,            // нуу, нууу
        #"(?i)(?<=^|\s)[хx][ммm]+(?=[,\s.!?]|$)"#,           // хм, хмм
        #"(?i)(?<=^|\s)[эe]-[эe]+(?=[,\s.!?]|$)"#,           // э-э
        #"(?i)(?<=^|\s)[аa]-[аa]+(?=[,\s.!?]|$)"#,           // а-а
        #"(?i)(?<=^|\s)[мm]-[мm]+(?=[,\s.!?]|$)"#,           // м-м

        // Английские однозначные паузные заполнители
        #"(?i)(?<=^|\s)uh+(?=[,\s.!?]|$)"#,                  // uh, uhh
        #"(?i)(?<=^|\s)um+(?=[,\s.!?]|$)"#,                  // um, umm
        #"(?i)(?<=^|\s)er+(?=[,\s.!?]|$)"#                   // er, err
    ]

    private static let compiledFillerRegexes: [NSRegularExpression] = {
        fillerPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Паттерн для схлопывания непосредственных повторов одинаковых слов (заиканий)
    /// Например: «я я думаю», «в в проекте», «надо надо сделать»
    private static let stutterRegex: NSRegularExpression? = {
        // Ловит два одинаковых слова подряд, разделенных пробелом
        let pattern = #"(?i)\b([a-zа-яё0-9]+)\s+\1\b"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Очистка текста от очевидных паузных заполнителей и заиканий
    public static func filter(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // 1. Схлопывание очевидных повторов слов (заиканий)
        if let stutterRegex = stutterRegex {
            var previous = ""
            // Прогоняем цикл до стабилизации (на случай тройных заиканий «я я я»)
            while previous != result {
                previous = result
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = stutterRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
            }
        }

        // 2. Удаление звуков-паразитов
        for regex in compiledFillerRegexes {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // 3. Нормализация пробелов и знаков препинания после удаления
        result = normalizeWhitespaceAndPunctuation(result)

        return result
    }

    private static func normalizeWhitespaceAndPunctuation(_ text: String) -> String {
        // Убираем двойные пробелы
        var cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Убираем пробелы перед знаками препинания: «привет , как дела» -> «привет, как дела»
        cleaned = cleaned.replacingOccurrences(of: #"\s+([,.:;!?])"#, with: "$1", options: .regularExpression)
        // Схлопываем повторяющиеся запятые: «привет,, как дела» -> «привет, как дела»
        cleaned = cleaned.replacingOccurrences(of: #",(\s*,)+"#, with: ",", options: .regularExpression)
        // Убираем висячие запятые в начале строки: «, привет» -> «привет»
        cleaned = cleaned.replacingOccurrences(of: #"^[,.:;!?\s]+"#, with: "", options: .regularExpression)
        // Капитализируем первую букву если она строчная
        if let first = cleaned.first, first.isLowercase {
            cleaned = first.uppercased() + cleaned.dropFirst()
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
