import Foundation

/// Правила вариантов, общие для наборов, автоподбора и тестов.
enum VariantRules {
    /// Варианты, которые нельзя ни в наборах, ни в автоподборе.
    static let denied: Set<String> = [
        "кубик", "питон", "свифт", "сас", "рои", "сла", "хр",
        "jason", "джейсон", "джанго", "no js", "view js", "sas",
        // Отзыв по задаче 10: обычные строки, имена и естественные английские фразы.
        "дал и", "а о", "о о о", "сок два", "смарт цели", "лин менеджмент", "москов приоритизация", "райс приоритизация", "пип план", "фрэнд лицензии", "мау юзеры", "дау юзеры", "вау юзеры", "продакт оунер", "стабильная диффузия", "диаграмма ганта", "клод", "джемма", "лотти", "кими", "тим тейлор", "асана", "мурал", "роми", "гант", "ашар", "дрибл", "бик", "вк", "чёрн", "черн", "ванг драйв", "base camp", "sales force", "head hunter", "work day", "success factors", "in design", "light room", "story book", "tail wind", "power point", "tick tock", "linked in", "one password", "face time", "drop box", "share point", "air table", "click up", "web flow", "pine cone", "cloud code", "lead pages", "link tree", "melt water", "red mine", "you track", "smart sheet", "product board", "brand watch", "hot jar", "mix panel", "sub stack", "tech stars", "fresh desk", "type form", "fire fox", "quick books", "deep mind", "free pic", "pen pot", "wind surf", "талент акйизишн", "гугл календар", "гугл мийт", "тексторс", "анспласт", "эксклидро", "эксалидро", "хироуикон", "team tailor", "юпитер ноутбук", "хром браузер",
        // Корпус «не навреди»: естественные английские фразы.
        "zen desk", "pro create", "hub spot", "pay pal", "mail chimp",
        // Корпус «не навреди», раунд 2: естественная речь и клички.
        "one on one", "лум", "ро и", "вак", "рест", "рэст",
    ]

    /// Токен годится для сопоставления: буквы и цифры с внутренними - . /.
    static func isMatchableToken(_ word: String) -> Bool {
        let chars = Array(word)
        guard let first = chars.first, let last = chars.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber else { return false }
        return chars.allSatisfy { $0.isLetter || $0.isNumber || "-./".contains($0) }
    }

    static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
    }

    static func isCyrillic(_ text: String) -> Bool {
        text.filter(\.isLetter).allSatisfy { $0.unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) } }
    }

    static func isLatin(_ text: String) -> Bool {
        text.filter(\.isLetter).allSatisfy(\.isASCII)
    }

    /// Нормализованный вариант или nil, если он не проходит правила наборов.
    static func accepted(_ raw: String, spelling: String, language: DictionaryLanguage, checker: CommonWordChecking) -> String? {
        let variant = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let words = variant.split(separator: " ").map(String.init)
        // Одна буква, например «c» для C#, совпадает со слишком многими словами.
        guard (1...4).contains(words.count), variant.count >= 2, variant != spelling.lowercased() else { return nil }
        guard words.allSatisfy(isMatchableToken) else { return nil }
        guard variant.contains(where: \.isLetter), language == .ru ? isCyrillic(variant) : isLatin(variant) else { return nil }
        guard !denied.contains(variant) else { return nil }
        if words.count == 1, checker.isCommonWord(variant, language: language) { return nil }
        return variant
    }
}
