import Foundation

/// Обучение словаря на правках заметок в истории: пара «ошибка → правильное написание»
/// засчитывается на втором повторе, а отменённые пользователем замены снимаются.
final class DictionaryLearning {
    static let shared = DictionaryLearning(
        store: DictionaryStore.shared,
        checker: SpellCommonWordChecker.shared,
        now: Date.init
    )

    /// Ключи счётчиков в `defaults`; `DictionaryStore.resetLearned` их стирает.
    enum Keys {
        static let pendingPairs = "dictionary.pendingPairs"
        static let learnedToday = "dictionary.learnedToday"
    }

    private static let repeatsToLearn = 2
    private static let dailyCap = 5
    private static let similarityThreshold = 0.6
    private static let maxPendingPairs = 500

    private let store: DictionaryStore
    private let checker: CommonWordChecking
    private let now: () -> Date
    private let queue = DispatchQueue(label: "tranq.dictionary.learning", qos: .utility)
    /// Счётчики лежат в `defaults` хранилища; блокировка не даёт фоновому и синхронному вызову смешать записи.
    private let countersLock = NSLock()

    init(store: DictionaryStore, checker: CommonWordChecking, now: @escaping () -> Date) {
        self.store = store
        self.checker = checker
        self.now = now
    }

    /// Вызывается с главного потока: состояние `learningEnabled` читается здесь, работа идёт на фоне.
    func learn(original: String, edited: String, noteId: UUID?, language: DictionaryLanguage = .current) {
        guard store.learningEnabled else { return }
        queue.async { [self] in
            process(original: original, edited: edited, noteId: noteId, language: language)
        }
    }

    /// Та же логика на потоке вызывающего, для тестов.
    func learnSync(original: String, edited: String, noteId: UUID?, language: DictionaryLanguage) {
        guard store.learningEnabled else { return }
        process(original: original, edited: edited, noteId: noteId, language: language)
    }

    // MARK: - Логика

    private func process(original: String, edited: String, noteId: UUID?, language: DictionaryLanguage) {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !edited.isEmpty, original != edited else { return }

        if let noteId { undoReverted(original: original, edited: edited, noteId: noteId, language: language) }

        var pairs = Self.extractDiffPairs(original: original, edited: edited)
        if language == .en { pairs += Self.caseOnlyPairs(original: original, edited: edited) }

        var seen = Set<String>()
        for pair in pairs {
            guard Self.isLearnablePair(pattern: pair.pattern, replacement: pair.replacement, language: language),
                  !isGrammarFix(pair.pattern, replacement: pair.replacement, language: language) else { continue }
            let key = "\(language)|\(pair.pattern.lowercased())|\(pair.replacement)"
            guard seen.insert(key).inserted else { continue }
            register(pair, key: key, language: language)
        }
    }

    /// Замена отменена, если её текст исчез из правки, а исходный появился.
    private func undoReverted(original: String, edited: String, noteId: UUID, language: DictionaryLanguage) {
        let editedTokens = Self.tokens(edited)
        var consumed: [AppliedReplacement] = []
        defer { store.forgetReplacements(consumed, noteId: noteId) }
        for replacement in store.replacements(for: noteId) {
            let exact = replacement.reason == .caseFix
            let replacementTokens = Self.tokens(replacement.replacement)
            let originalTokens = Self.tokens(replacement.original)
            guard !Self.contains(editedTokens, replacementTokens, caseSensitive: exact),
                  Self.contains(editedTokens, originalTokens, caseSensitive: exact) else { continue }
            store.removeVariant(replacement.variant, language: language, fromEntryKey: replacement.entryKey)
            consumed.append(replacement)
            AppLogger.shared.info("Dictionary", "Замена отменена правкой", details: "\(AppLogger.shared.transcript(replacement.original, id: noteId, quoted: false)) -> \(AppLogger.shared.transcript(replacement.replacement, id: noteId, quoted: false))")
        }
    }

    private enum Decision { case wait, capped, learn(isNew: Bool) }

    private func register(_ pair: (pattern: String, replacement: String), key: String, language: DictionaryLanguage) {
        // Блокировка охватывает только счётчики: вызовы хранилища уходят на главный поток и идут уже без неё.
        let decision: Decision = withCounters {
            var pending = store.defaults.dictionary(forKey: Keys.pendingPairs) as? [String: Int] ?? [:]
            if pending.count >= Self.maxPendingPairs, pending[key] == nil { pending = [:] }
            let count = (pending[key] ?? 0) + 1
            let isNew = !store.hasEntry(spelling: pair.replacement)
            if count < Self.repeatsToLearn {
                pending[key] = count
                store.defaults.set(pending, forKey: Keys.pendingPairs)
                return .wait
            }
            if isNew, learnedToday() >= Self.dailyCap {
                pending[key] = count
                store.defaults.set(pending, forKey: Keys.pendingPairs)
                return .capped
            }
            pending[key] = nil
            store.defaults.set(pending, forKey: Keys.pendingPairs)
            if isNew { incrementLearnedToday() }
            return .learn(isNew: isNew)
        }

        switch decision {
        case .wait:
            return
        case .capped:
            AppLogger.shared.info("Dictionary", "Дневной лимит обучения исчерпан", details: AppLogger.shared.transcript(pair.replacement, quoted: false))
        case .learn:
            let caseOnly = pair.pattern.lowercased() == pair.replacement.lowercased()
            let entry = store.addEntry(
                spelling: pair.replacement,
                variants: caseOnly ? [:] : [language: [pair.pattern]],
                source: .learned,
                forceCase: caseOnly
            )
            // Подкреплённая запись не должна попасть под удаление неиспользуемых за 60 дней.
            store.touch(id: entry.id)
            AppLogger.shared.info("Dictionary", "Слово выучено из правки", details: "\(AppLogger.shared.transcript(pair.pattern, quoted: false)) -> \(AppLogger.shared.transcript(pair.replacement, quoted: false))")
        }
    }

    private func withCounters<T>(_ body: () -> T) -> T {
        countersLock.lock()
        defer { countersLock.unlock() }
        return body()
    }

    /// Правка обычных слов в кириллическую форму с заглавной, например «давай» в «Давайте», это грамматика,
    /// а не термин. Латиница и аббревиатуры допустимы: такой вариант срабатывает только в точной форме.
    private func isGrammarFix(_ pattern: String, replacement: String, language: DictionaryLanguage) -> Bool {
        if pattern.lowercased() == replacement.lowercased() { return false }
        let words = pattern.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.allSatisfy({ checker.isCommonWord($0, language: language) }) else { return false }
        let hasLatin = replacement.contains { $0.isASCII && $0.isLetter }
        return !hasLatin && !Self.isAcronym(replacement)
    }

    private static func isAcronym(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        return chars.count >= 2 && chars.allSatisfy { $0.isLetter || $0.isNumber } && !chars.contains(where: \.isLowercase)
    }

    // MARK: - Дневной лимит

    private func dayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now())
    }

    private func learnedToday() -> Int {
        guard let stored = store.defaults.dictionary(forKey: Keys.learnedToday),
              stored["day"] as? String == dayString() else { return 0 }
        return stored["count"] as? Int ?? 0
    }

    private func incrementLearnedToday() {
        store.defaults.set(["day": dayString(), "count": learnedToday() + 1] as [String: Any], forKey: Keys.learnedToday)
    }

    // MARK: - Фильтр пар

    /// 1–2 слова с обеих сторон, замена в латинице, аббревиатура или с заглавной, и похожесть не ниже 0.6.
    /// Для английского засчитывается и пара, отличающаяся только регистром.
    static func isLearnablePair(pattern: String, replacement: String, language: DictionaryLanguage) -> Bool {
        let patternWords = pattern.split(whereSeparator: \.isWhitespace).map(String.init)
        let replacementWords = replacement.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...2).contains(patternWords.count), (1...2).contains(replacementWords.count) else { return false }

        let patternText = patternWords.joined(separator: " ")
        let replacementText = replacementWords.joined(separator: " ")
        if patternText.lowercased() == replacementText.lowercased() {
            return language == .en && patternText != replacementText && replacementText.contains(where: \.isUppercase)
        }

        // Положение в предложении неизвестно, поэтому подходит любое слово с заглавной.
        let hasLatin = replacementWords.contains { $0.contains { $0.isASCII && $0.isLetter } }
        let hasCapital = replacementWords.contains { $0.first?.isUppercase == true }
        guard hasLatin || hasCapital else { return false }

        let lhs = patternWords.joined()
        let rhs = replacementWords.joined()
        let score: Double
        if hasLatin {
            score = Phonetics.similarity(token: lhs, spelling: rhs, language: language)
        } else {
            score = 1 - Phonetics.normalizedDistance(lhs.lowercased(), rhs.lowercased())
        }
        return score >= similarityThreshold
    }

    // MARK: - Разбор правки

    /// Слова с различием только в регистре на тех же позициях: `extractDiffPairs` такие пары отбрасывает.
    private static func caseOnlyPairs(original: String, edited: String) -> [(pattern: String, replacement: String)] {
        let lhs = original.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map { cleanWord(String($0)) }
        let rhs = edited.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map { cleanWord(String($0)) }
        guard lhs.count == rhs.count else { return [] }
        // Первое слово текста и слово после . ! ? пишутся с заглавной по грамматике, а не по желанию пользователя.
        let raw = original.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map(String.init)
        var pairs: [(pattern: String, replacement: String)] = []
        for i in lhs.indices where !lhs[i].isEmpty && lhs[i] != rhs[i] && lhs[i].lowercased() == rhs[i].lowercased() {
            let sentenceStart = i == 0 || raw[i - 1].last.map { ".!?".contains($0) } == true
            if !sentenceStart { pairs.append((pattern: lhs[i], replacement: rhs[i])) }
        }
        return pairs
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { cleanWord(String($0)) }.filter { !$0.isEmpty }
    }

    private static func contains(_ tokens: [String], _ phrase: [String], caseSensitive: Bool) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        let normalize: (String) -> String = { caseSensitive ? $0 : $0.lowercased() }
        let haystack = tokens.map(normalize)
        let needle = phrase.map(normalize)
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    private static func cleanWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// Перенесено из удалённого движка персонализации без изменений.
    static func extractDiffPairs(original: String, edited: String) -> [(pattern: String, replacement: String)] {
        let origTokens = original.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map { String($0) }
        let editTokens = edited.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map { String($0) }

        let n = origTokens.count
        let m = editTokens.count
        guard n > 0 && m > 0 else { return [] }

        // DP таблица наибольшей общей подпоследовательности (LCS)
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if cleanWord(origTokens[i - 1]).lowercased() == cleanWord(editTokens[j - 1]).lowercased() {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        enum Op {
            case match(String, String)
            case delete(String)
            case insert(String)
        }

        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && cleanWord(origTokens[i - 1]).lowercased() == cleanWord(editTokens[j - 1]).lowercased() {
                ops.append(.match(origTokens[i - 1], editTokens[j - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                ops.append(.insert(editTokens[j - 1]))
                j -= 1
            } else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
                ops.append(.delete(origTokens[i - 1]))
                i -= 1
            }
        }
        ops.reverse()

        var results: [(pattern: String, replacement: String)] = []
        var curDel: [String] = []
        var curIns: [String] = []

        func flush() {
            if !curDel.isEmpty || !curIns.isEmpty {
                let pat = curDel.map { cleanWord($0) }.filter { !$0.isEmpty }.joined(separator: " ")
                let rep = curIns.map { cleanWord($0) }.filter { !$0.isEmpty }.joined(separator: " ")
                if !pat.isEmpty && curDel.count <= 4 && curIns.count <= 4 && pat.lowercased() != rep.lowercased() {
                    results.append((pattern: pat, replacement: rep))
                }
                curDel.removeAll()
                curIns.removeAll()
            }
        }

        for op in ops {
            switch op {
            case .match:
                flush()
            case .delete(let d):
                curDel.append(d)
            case .insert(let ins):
                curIns.append(ins)
            }
        }
        flush()
        return results
    }
}
