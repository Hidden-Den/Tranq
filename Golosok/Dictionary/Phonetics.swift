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

    private static func collapseDoubles(_ chars: [Character]) -> String {
        var out: [Character] = []
        for ch in chars where out.last != ch { out.append(ch) }
        return String(out)
    }
}
