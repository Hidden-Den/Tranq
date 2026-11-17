import Foundation

/// Детерминированный префильтр однозначного речевого шума и заиканий
public struct DisfluencyPrefilter {

    /// Регулярные выражения для однозначных звуковых паразитов и хезитаций
    private static let fillerPatterns: [String] = [
        // Русские однозначные паузные заполнители
        #"(?i)(?<=^|\s)э{2,}(?=[,\s.!?]|$)"#,               // ээ, эээ
        #"(?i)(?<=^|\s)е{3,}(?=[,\s.!?]|$)"#,               // еее (3+ буквы, чтобы не удалять местоимение «ее»)
        #"(?i)(?<!\d)(?<!\d\s)(?<=^|\s)[мm]{2,}(?=[,\s.!?]|$)"#, // мм, ммм (не после цифр: сохраняет «5 мм»)
        #"(?i)(?<=^|\s)[аa]{3,}(?=[,\s.!?]|$)"#,             // ааа, аааа
        #"(?i)(?<=^|\s)н[уu]{2,}(?=[,\s.!?]|$)"#,            // нуу, нууу
        #"(?i)(?<=^|\s)[хx][ммm]+(?=[,\s.!?]|$)"#,           // хм, хмм
        #"(?i)(?<=^|\s)[эe](-[эe]+)+(?=[,\s.!?]|$)"#,        // э-э, э-э-э, э-э-э-э
        #"(?i)(?<=^|\s)[аa](-[аa]+)+(?=[,\s.!?]|$)"#,        // а-а, а-а-а
        #"(?i)(?<=^|\s)[мm](-[мm]+)+(?=[,\s.!?]|$)"#,        // м-м, м-м-м

        // Английские однозначные паузные заполнители
        #"(?i)(?<=^|\s)uh+(?=[,\s.!?]|$)"#,                  // uh, uhh
        #"(?i)(?<=^|\s)um+(?=[,\s.!?]|$)"#                   // um, umm
    ]

    private static let compiledFillerRegexes: [NSRegularExpression] = {
        fillerPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Паттерн для схлопывания непосредственных повторов одинаковых слов (заиканий)
    /// Например: «я я думаю», «и как, как нам», «надо надо сделать»
    /// Ограничен только буквенными токенами, чтобы не повреждать группы цифр («999 999»)
    private static let stutterRegex: NSRegularExpression? = {
        let pattern = #"(?i)\b([a-zа-яё]+)(?:,\s*|\s+)\1\b"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Повтор слова-предложения через точку: «Деплой. Деплой.». Первое слово должно быть целым предложением,
    /// иначе схлопнулись бы соседние предложения вроде «Это сделал он. Он сказал.». Второе должно тоже
    /// закончить предложение или часть: «Иван. Иван Петров пришёл.» остаётся как есть.
    private static let sentenceRepeatRegex: NSRegularExpression? = {
        let pattern = #"(?i)(?<=^|[.!?]\s{1,8})([a-zа-яё]+)\.\s+\1(?=[.!?,]|\s*$)"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Очистка текста от очевидных паузных заполнителей и заиканий
    public static func filter(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // 1. Схлопывание очевидных повторов буквенных слов (заиканий)
        var previous = ""
        // Прогоняем цикл до стабилизации (на случай тройных заиканий «я я я»)
        while previous != result {
            previous = result
            for regex in [stutterRegex, sentenceRepeatRegex].compactMap({ $0 }) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
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
        // Убираем запятые перед точкой или концом предложения: «думаю,.» -> «думаю.»
        cleaned = cleaned.replacingOccurrences(of: #",+\s*([.:;!?])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #",+\s*$"#, with: "", options: .regularExpression)
        // Убираем висячие запятые в начале строки: «, привет» -> «привет»
        cleaned = cleaned.replacingOccurrences(of: #"^[,.:;!?\s]+"#, with: "", options: .regularExpression)
        // Сохраняем оригинальную капитализацию расшифровки
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
