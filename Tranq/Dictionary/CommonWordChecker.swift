import AppKit

protocol CommonWordChecking {
    func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool
}

/// Словарное слово по `NSSpellChecker`. Результаты кэшируются.
/// Индекс словаря строится на фоновой очереди, поэтому вызовы `NSSpellChecker` идут строго по одному.
final class SpellCommonWordChecker: CommonWordChecking {
    static let shared = SpellCommonWordChecker()

    /// Общий для всех экземпляров: `NSSpellChecker.shared` один на процесс.
    private static let spellLock = NSLock()
    /// Найденные коды языков проверки, под `spellLock`. Недоступный язык ищется снова: словарь может появиться позже.
    private static var languageCodes: [DictionaryLanguage: String] = [:]

    /// Прогрев на главном потоке при запуске: первое обращение к `NSSpellChecker.shared` дорогое
    /// и иначе случилось бы при сборке индекса или в окне добавления.
    func warmUp() {
        Self.spellLock.lock()
        defer { Self.spellLock.unlock() }
        for language in DictionaryLanguage.allCases {
            _ = Self.languageCode(language, checker: NSSpellChecker.shared)
        }
    }

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

        // Недоступный язык не кэшируется: словарь может появиться позже.
        guard let result = Self.check(word.lowercased(), language: language) else { return false }

        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    /// Вызывается под `spellLock`.
    private static func languageCode(_ language: DictionaryLanguage, checker: NSSpellChecker) -> String? {
        if let code = languageCodes[language] { return code }
        let code = checker.availableLanguages.first { $0.hasPrefix(language.rawValue) }
        if let code { languageCodes[language] = code }
        return code
    }

    /// `nil`, если язык недоступен в системе.
    private static func check(_ word: String, language: DictionaryLanguage) -> Bool? {
        guard !word.isEmpty else { return false }
        spellLock.lock()
        defer { spellLock.unlock() }
        let checker = NSSpellChecker.shared
        guard let code = languageCode(language, checker: checker) else { return nil }
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
