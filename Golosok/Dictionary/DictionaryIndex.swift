import Foundation

/// Точная замена по вариантам, словоформы и исправление регистра.
/// Строится один раз из записей и наборов, `apply` делает один проход по словам фразы.
struct DictionaryIndex {
    /// Все действующие написания: пользовательские и из включённых наборов.
    let approvedSpellings: Set<String>

    private let tables: [DictionaryLanguage: LanguageTable]
    private let checker: CommonWordChecking

    /// Окончания словоформ для русского.
    private static let endings: Set<String> = ["а", "у", "е", "ом", "ой", "ы", "ов", "ам", "ами", "ах", "и", "ю", "я", "ей"]
    private static let maxEndingLength = 3
    /// Гласная или мягкий знак в конце варианта, которые отбрасываются для второй основы.
    private static let droppableFinals: Set<Character> = ["а", "я", "о", "е", "ы", "и", "у", "ь", "й"]

    init(
        userEntries: [DictionaryEntry],
        packs: [DictionaryPack],
        disabledPacks: Set<String>,
        disabledPackWords: Set<String>,
        disabledPackVariants: Set<String>,
        checker: CommonWordChecking
    ) {
        self.checker = checker
        var builders: [DictionaryLanguage: LanguageTable] = [:]
        for language in DictionaryLanguage.allCases {
            builders[language] = LanguageTable()
        }
        var spellings = Set<String>()

        for entry in userEntries {
            spellings.insert(entry.spelling)
            let key = "user/\(entry.id.uuidString)"
            let caseFix = entry.forceCase || !checker.isCommonWord(entry.spelling, language: .en)
            for language in DictionaryLanguage.allCases {
                builders[language]?.add(
                    spelling: entry.spelling, entryKey: key, variants: entry.variants[language] ?? [],
                    caseFixEligible: caseFix, language: language, checker: checker
                )
            }
        }

        for pack in packs where !disabledPacks.contains(pack.id) {
            for entry in pack.entries {
                let key = "\(pack.id)/\(entry.spelling)"
                guard !disabledPackWords.contains(key) else { continue }
                spellings.insert(entry.spelling)
                for language in DictionaryLanguage.allCases {
                    let variants = (entry.variants[language] ?? []).filter {
                        !disabledPackVariants.contains("\(key)/\($0)")
                    }
                    builders[language]?.add(
                        spelling: entry.spelling, entryKey: key, variants: variants,
                        caseFixEligible: !entry.commonIn.contains(language), language: language, checker: checker
                    )
                }
            }
        }

        tables = builders
        approvedSpellings = spellings
    }

    func apply(to text: String, language: DictionaryLanguage) -> (text: String, replacements: [AppliedReplacement]) {
        guard !text.isEmpty, let table = tables[language], !table.isEmpty else { return (text, []) }
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return (text, []) }

        var output = ""
        output.reserveCapacity(text.utf8.count + 32)
        var replacements: [AppliedReplacement] = []
        var cursor = text.startIndex
        var i = 0

        func emit(_ range: Range<String.Index>, _ replacement: String, _ entryKey: String, _ variant: String, _ reason: AppliedReplacement.Reason) {
            let original = String(text[range])
            guard original != replacement else { return }
            output += text[cursor..<range.lowerBound]
            output += replacement
            cursor = range.upperBound
            replacements.append(AppliedReplacement(
                original: original, replacement: replacement, entryKey: entryKey, variant: variant, reason: reason
            ))
        }

        while i < tokens.count {
            let token = tokens[i]

            if let match = exactMatch(at: i, tokens: tokens, text: text, table: table) {
                let last = tokens[i + match.length - 1]
                let c = match.candidate
                emit(token.range.lowerBound..<last.range.upperBound, c.spelling, c.entryKey, c.variant, .variant)
                i += match.length
                continue
            }

            if language == .ru, let form = formMatch(token.lower, table: table) {
                emit(token.range, form.replacement, form.candidate.entryKey, form.candidate.variant, .variant)
            } else if language == .en, let c = table.caseFix[token.lower] {
                emit(token.range, c.spelling, c.entryKey, token.lower, .caseFix)
            }
            i += 1
        }

        guard !replacements.isEmpty else { return (text, []) }
        output += text[cursor...]
        return (output, replacements)
    }

    // MARK: - Matching

    private func exactMatch(at i: Int, tokens: [Token], text: String, table: LanguageTable) -> (candidate: Candidate, length: Int)? {
        guard let bucket = table.exact[tokens[i].lower] else { return nil }
        for length in bucket.lengths {
            if length == 1 {
                if let c = bucket.phrases[tokens[i].lower] { return (c, 1) }
                continue
            }
            guard i + length <= tokens.count else { continue }
            var phrase = tokens[i].lower
            var joined = true
            for k in (i + 1)..<(i + length) {
                guard Self.isSpaceGap(text[tokens[k - 1].range.upperBound..<tokens[k].range.lowerBound]) else {
                    joined = false
                    break
                }
                phrase += " "
                phrase += tokens[k].lower
            }
            if joined, let c = bucket.phrases[phrase] { return (c, length) }
        }
        return nil
    }

    private func formMatch(_ token: String, table: LanguageTable) -> (candidate: Candidate, replacement: String)? {
        guard !table.forms.isEmpty else { return nil }
        let count = token.count
        guard count > 1 else { return nil }
        for endingLength in 1...min(Self.maxEndingLength, count - 1) {
            let split = token.index(token.endIndex, offsetBy: -endingLength)
            let ending = String(token[split...])
            guard Self.endings.contains(ending), let form = table.forms[String(token[..<split])] else { continue }
            guard !checker.isCommonWord(token, language: .ru) else { return nil }
            let replacement = form.swallowsEnding ? form.candidate.spelling : form.carryBase + ending
            return (form.candidate, replacement)
        }
        return nil
    }

    // MARK: - Tokens

    private struct Token {
        let range: Range<String.Index>
        let lower: String
    }

    /// Слово: буквы и цифры, внутри слова также `-`, `.`, `/`.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index)
            if isWordCharacter(c) {
                if start == nil { start = index }
            } else if let s = start {
                let joinsWord = isJoiner(c) && next < text.endIndex && isWordCharacter(text[next])
                if !joinsWord {
                    tokens.append(Token(range: s..<index, lower: text[s..<index].lowercased()))
                    start = nil
                }
            }
            index = next
        }
        if let s = start {
            tokens.append(Token(range: s..<text.endIndex, lower: text[s...].lowercased()))
        }
        return tokens
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    private static func isJoiner(_ c: Character) -> Bool { c == "-" || c == "." || c == "/" }

    /// Между словами многословного варианта допустимы только пробелы.
    private static func isSpaceGap(_ gap: Substring) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0.isWhitespace && !$0.isNewline }
    }

    // MARK: - Tables

    private struct Candidate {
        let spelling: String
        let entryKey: String
        let variant: String
    }

    private struct Bucket {
        /// Длины вариантов в словах, по убыванию.
        var lengths: [Int] = []
        /// Вариант в нижнем регистре, слова через один пробел.
        var phrases: [String: Candidate] = [:]
    }

    private struct Form {
        let candidate: Candidate
        let swallowsEnding: Bool
        /// Написание, к которому дописывается окончание.
        let carryBase: String
    }

    private struct LanguageTable {
        var exact: [String: Bucket] = [:]
        var forms: [String: Form] = [:]
        var caseFix: [String: Candidate] = [:]

        var isEmpty: Bool { exact.isEmpty && caseFix.isEmpty }

        /// Записи добавляются в порядке приоритета, поэтому первая вставка побеждает.
        mutating func add(
            spelling: String, entryKey: String, variants: [String],
            caseFixEligible: Bool, language: DictionaryLanguage, checker: CommonWordChecking
        ) {
            for variant in variants {
                let words = variant.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                guard let first = words.first else { continue }
                let phrase = words.joined(separator: " ")
                let candidate = Candidate(spelling: spelling, entryKey: entryKey, variant: variant)

                var bucket = exact[first] ?? Bucket()
                if bucket.phrases[phrase] == nil {
                    bucket.phrases[phrase] = candidate
                    if !bucket.lengths.contains(words.count) {
                        bucket.lengths.append(words.count)
                        bucket.lengths.sort(by: >)
                    }
                }
                exact[first] = bucket

                if language == .ru, words.count == 1, !checker.isCommonWord(first, language: .ru) {
                    addForms(variant: first, candidate: candidate)
                }
            }

            if language == .en, caseFixEligible, !spelling.contains(where: \.isWhitespace) {
                let key = spelling.lowercased()
                if caseFix[key] == nil {
                    caseFix[key] = Candidate(spelling: spelling, entryKey: entryKey, variant: key)
                }
            }
        }

        private mutating func addForms(variant: String, candidate: Candidate) {
            let spelling = candidate.spelling
            let swallows = DictionaryIndex.swallowsEnding(spelling)
            if forms[variant] == nil {
                forms[variant] = Form(candidate: candidate, swallowsEnding: swallows, carryBase: spelling)
            }
            guard variant.count >= 4, let final = variant.last, DictionaryIndex.droppableFinals.contains(final) else { return }
            let stem = String(variant.dropLast())
            guard forms[stem] == nil else { return }
            // «Джира» + «е» даёт «Джире»: отбрасываем ту же букву у написания, если она там есть.
            let carryBase = spelling.last.map { $0.lowercased() == String(final) } == true
                ? String(spelling.dropLast())
                : spelling
            forms[stem] = Form(candidate: candidate, swallowsEnding: swallows, carryBase: carryBase)
        }
    }

    /// Латинское написание или кириллическая аббревиатура заменяют всю словоформу.
    private static func swallowsEnding(_ spelling: String) -> Bool {
        let hasCyrillic = spelling.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        guard hasCyrillic else { return true }
        let letters = spelling.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }
}
