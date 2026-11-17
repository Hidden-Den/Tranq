import Foundation

/// Phonetic helpers for the dictionary: transliteration, an English key and similarity.
enum Phonetics {
    private static let digraphs: [(String, String)] = [
        ("sh", "ш"), ("ch", "ч"), ("ck", "к"), ("zh", "ж"), ("ts", "ц"),
        ("ee", "и"), ("oo", "у"), ("ph", "ф"), ("th", "т")
    ]

    private static let singles: [Character: String] = [
        "a": "а", "b": "б", "c": "к", "d": "д", "e": "е", "f": "ф", "g": "г",
        "h": "х", "i": "и", "j": "дж", "k": "к", "l": "л", "m": "м", "n": "н",
        "o": "о", "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "у",
        "v": "в", "w": "в", "x": "кс", "y": "и", "z": "з"
    ]

    /// Lowercase Cyrillic approximation of a Latin spelling. Digits and symbols are dropped.
    static func transliterateToCyrillic(_ latin: String) -> String {
        let chars = Array(latin.lowercased())
        var result: [Character] = []
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count {
                let pair = String(chars[i...i + 1])
                if let hit = digraphs.first(where: { $0.0 == pair }) {
                    result.append(contentsOf: hit.1)
                    i += 2
                    continue
                }
            }
            if let single = singles[chars[i]] {
                result.append(contentsOf: single)
            }
            i += 1
        }
        return collapseDoubles(result)
    }

    /// Simplified Metaphone: doubles collapsed, then only a leading vowel survives, common digraphs unified.
    static func englishKey(_ word: String) -> String {
        var s = word.lowercased().filter { $0.isLetter && $0.isASCII }
        for (from, to) in [("ph", "f"), ("ck", "k"), ("c", "k"), ("q", "k"), ("x", "ks"), ("z", "s")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // Doubles collapse first, so consonants split by a vowel never merge: "banana" stays apart from "bin".
        let collapsed = Array(collapseDoubles(Array(s)))
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var out: [Character] = []
        for (index, ch) in collapsed.enumerated() where index == 0 || !vowels.contains(ch) {
            out.append(ch)
        }
        return String(out)
    }

    /// Levenshtein distance over Characters divided by the longer length. Empty pair gives 0.
    static func normalizedDistance(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        if longest == 0 { return 0 }
        if x.isEmpty || y.isEmpty { return 1 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return Double(prev[y.count]) / Double(longest)
    }

    static func similarity(token: String, spelling: String, language: DictionaryLanguage) -> Double {
        let lhs: String, rhs: String
        switch language {
        case .ru:
            lhs = token.lowercased()
            rhs = transliterateToCyrillic(spelling)
        case .en:
            lhs = englishKey(token)
            rhs = englishKey(spelling)
        }
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return 1 - normalizedDistance(lhs, rhs)
    }

    private static let cyrillicToLatin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "э": "e", "ж": "zh",
        "з": "z", "и": "i", "ы": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
        "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch",
        "ш": "sh", "щ": "sh", "ь": "", "ъ": "", "ю": "u", "я": "a"
    ]

    /// Порядок важен: сначала многобуквенные звуки, `C` и `S` — заглушки для «ч» и «ш».
    private static let soundReplacements: [(String, String)] = [
        ("dzh", "j"), ("zh", "j"), ("dj", "j"), ("ch", "C"), ("sh", "S"), ("ph", "f"),
        ("ck", "k"), ("th", "t"), ("q", "k"), ("x", "ks"), ("w", "v"), ("c", "s")
    ]

    private static let devoiced: [Character: Character] = ["b": "p", "d": "t", "g": "k", "v": "f", "z": "s"]
    private static let soundVowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "h"]

    /// Скелет согласных, общий для латиницы и кириллицы: «IPI», «API» и «эй пи ай» дают `p`.
    /// Цифры и знаки выбрасываются, звонкие оглушаются, гласные удаляются, сдвоенные остаются.
    static func soundKey(_ text: String) -> String {
        var latin = ""
        for ch in text.lowercased() {
            if let mapped = cyrillicToLatin[ch] {
                latin += mapped
            } else if ch.isASCII, ch.isLetter {
                latin.append(ch)
            }
        }
        for (from, to) in soundReplacements {
            latin = latin.replacingOccurrences(of: from, with: to)
        }
        return String(latin.compactMap { ch -> Character? in
            let sound = devoiced[ch] ?? ch
            return soundVowels.contains(sound) ? nil : sound
        })
    }

    /// Буквы слова в латинице без знаков: для сравнения написаний разных алфавитов.
    static func latinLetters(_ text: String) -> String {
        var latin = ""
        for ch in text.lowercased() {
            if let mapped = cyrillicToLatin[ch] {
                latin += mapped
            } else if ch.isASCII, ch.isLetter {
                latin.append(ch)
            }
        }
        return latin
    }

    private static func collapseDoubles(_ chars: [Character]) -> String {
        var out: [Character] = []
        for ch in chars where out.last != ch { out.append(ch) }
        return String(out)
    }
}
