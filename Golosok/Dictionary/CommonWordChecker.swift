import AppKit

protocol CommonWordChecking {
    func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool
}

/// Словарное слово по `NSSpellChecker`. Результаты кэшируются.
final class SpellCommonWordChecker: CommonWordChecking {
    static let shared = SpellCommonWordChecker()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool {
        let key = "\(language.rawValue)|\(word.lowercased())"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let result = Self.check(word.lowercased(), language: language)

        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    private static func check(_ word: String, language: DictionaryLanguage) -> Bool {
        guard !word.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        guard let code = checker.availableLanguages.first(where: { $0.hasPrefix(language.rawValue) }) else {
            return false
        }
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: code, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }
}

/// Проверка по заданным множествам, для тестов.
struct SetCommonWordChecker: CommonWordChecking {
    private let words: [DictionaryLanguage: Set<String>]

    init(_ words: [DictionaryLanguage: Set<String>]) {
        self.words = words
    }

    func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool {
        words[language]?.contains(word.lowercased()) ?? false
    }
}
