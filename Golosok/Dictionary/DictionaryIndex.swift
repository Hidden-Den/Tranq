import Foundation

/// Похожее по звучанию слово фразы, которое не заменено и только попадает в лог.
struct FuzzyHit: Equatable {
    let token: String
    let spelling: String
    let similarity: Double
}

/// Слово распознавания, похожее на искажённый термин, и термины словаря, похожие на него по звучанию.
public struct TermSuspect: Equatable {
    public let token: String
    public let candidates: [String]

    public init(token: String, candidates: [String]) {
        self.token = token
        self.candidates = candidates
    }
}

/// Точная замена по вариантам, словоформы и исправление регистра.
/// Строится один раз из записей и наборов, `apply` делает один проход по словам фразы.
struct DictionaryIndex {
    /// Все действующие написания: пользовательские и из включённых наборов.
    let approvedSpellings: Set<String>

    private let tables: [DictionaryLanguage: LanguageTable]
    /// Кандидаты нечёткого поиска: язык, затем первая буква ключа.
    private let fuzzyGroups: [DictionaryLanguage: [FuzzyGroupKey: [FuzzyCandidate]]]
    private let checker: CommonWordChecking
    /// Звуковые ключи написаний и их русских вариантов для подсказки модели.
    private let soundTerms: [SoundTerm]
    /// Написания и их отдельные слова в нижнем регистре: такие слова не подозрительны.
    private let approvedLower: Set<String>
    private let approvedWordsLower: Set<String>

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
        var fuzzy: [DictionaryLanguage: [FuzzyGroupKey: [FuzzyCandidate]]] = [:]

        var sounds: [SoundTerm] = []
        func addSound(_ spelling: String, ruVariants: [String]) {
            let keys = Set(([spelling] + ruVariants).map(Phonetics.soundKey)).filter { !$0.isEmpty }
            guard !keys.isEmpty else { return }
            sounds.append(SoundTerm(
                spelling: spelling, lowered: spelling.lowercased(), keys: keys.map { Array($0) },
                letters: Phonetics.latinLetters(spelling), ordinal: sounds.count
            ))
        }

        var ordinal = 0
        func addFuzzy(_ spelling: String) {
            defer { ordinal += 1 }
            for language in DictionaryLanguage.allCases {
                let key = Self.fuzzyKey(spelling, language: language)
                guard let first = key.first else { continue }
                let scalars = key.unicodeScalars.map(\.value)
                fuzzy[language, default: [:]][FuzzyGroupKey(first: first, length: scalars.count), default: []]
                    .append(FuzzyCandidate(spelling: spelling, lowered: spelling.lowercased(), key: scalars, mask: Self.letterMask(scalars), ordinal: ordinal))
            }
        }

        for entry in userEntries {
            spellings.insert(entry.spelling)
            addFuzzy(entry.spelling)
            addSound(entry.spelling, ruVariants: entry.variants[.ru] ?? [])
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
                addFuzzy(entry.spelling)
                addSound(entry.spelling, ruVariants: (entry.variants[.ru] ?? []).filter {
                    !disabledPackVariants.contains("\(key)/\($0)")
                })
                // Отменённое исправление регистра выключает вариант «<packId>/<spelling>/<spelling в нижнем регистре>».
                let caseFixDisabled = disabledPackVariants.contains("\(key)/\(entry.spelling.lowercased())")
                for language in DictionaryLanguage.allCases {
                    let variants = (entry.variants[language] ?? []).filter {
                        !disabledPackVariants.contains("\(key)/\($0)")
                    }
                    // Варианты наборов проверены PackValidationTests: словарными они не бывают.
                    builders[language]?.add(
                        spelling: entry.spelling, entryKey: key, variants: variants,
                        caseFixEligible: !caseFixDisabled && !entry.commonIn.contains(language),
                        language: language, checker: nil
                    )
                }
            }
        }

        tables = builders
        fuzzyGroups = fuzzy
        approvedSpellings = spellings
        soundTerms = sounds
        approvedLower = Set(spellings.map { $0.lowercased() })
        approvedWordsLower = Set(spellings.flatMap {
            $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        })
    }

    func apply(to text: String, language: DictionaryLanguage) -> (text: String, replacements: [AppliedReplacement]) {
        guard !text.isEmpty, let table = tables[language], !table.isEmpty else { return (text, []) }
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return (text, []) }
        let result = rewrite(text, tokens: tokens, language: language, table: table)
        return (result.text, result.replacements)
    }

    /// Слова, которые точная замена или исправление регистра уже обработали, считаются заменёнными.
    private func rewrite(
        _ text: String, tokens: [Token], language: DictionaryLanguage, table: LanguageTable
    ) -> (text: String, replacements: [AppliedReplacement], handled: Set<Int>) {
        var handled = Set<Int>()

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
                handled.formUnion(i..<(i + match.length))
                i += match.length
                continue
            }

            if language == .ru, let form = formMatch(token.lower, table: table) {
                emit(token.range, form.replacement, form.candidate.entryKey, form.candidate.variant, .variant)
                handled.insert(i)
            } else if language == .en, let c = table.caseFix[token.lower] {
                emit(token.range, c.spelling, c.entryKey, token.lower, .caseFix)
                handled.insert(i)
            }
            i += 1
        }

        guard !replacements.isEmpty else { return (text, [], handled) }
        output += text[cursor...]
        return (output, replacements, handled)
    }

    // MARK: - Подозрительные слова

    private static let maxSuspects = 3
    private static let maxCandidates = 6
    private static let suspectPattern = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9&]*|[А-ЯЁа-яё]+")

    /// Слова, которые распознавание могло исказить из термина, с кандидатами по звуковому ключу.
    /// Только для русской диктовки: не больше трёх слов, у каждого не больше шести кандидатов.
    func termSuspects(in text: String, language: DictionaryLanguage) -> [TermSuspect] {
        guard language == .ru, !text.isEmpty, !soundTerms.isEmpty else { return [] }
        var result: [TermSuspect] = []
        var seen = Set<String>()
        for word in Self.suspectWords(in: text) where result.count < Self.maxSuspects {
            guard seen.insert(word.lowercased()).inserted, isSuspect(word) else { continue }
            let candidates = candidates(for: word)
            if !candidates.isEmpty { result.append(TermSuspect(token: word, candidates: candidates)) }
        }
        return result
    }

    /// Латинские и кириллические слова по порядку. Однобуквенное латинское слово склеивается
    /// с предыдущим латинским через пробел, как «Power B», а без такого соседа пропускается.
    private static func suspectWords(in text: String) -> [String] {
        let ns = text as NSString
        var words: [String] = []
        var previous: (range: NSRange, latin: Bool)?
        for match in suspectPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            let latin = word.unicodeScalars.first.map { $0.isASCII } ?? false
            defer { previous = (match.range, latin) }
            guard latin, word.count == 1 else {
                words.append(word)
                continue
            }
            guard let prev = previous, prev.latin else { continue }
            let gapStart = prev.range.location + prev.range.length
            let gap = ns.substring(with: NSRange(location: gapStart, length: match.range.location - gapStart))
            guard gap == " ", let last = words.last else { continue }
            words[words.count - 1] = last + " " + word
        }
        return words
    }

    private func isSuspect(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard !approvedLower.contains(lower) else { return false }
        if word.unicodeScalars.first?.isASCII == true {
            if word.contains(" ") { return true }
            guard !approvedWordsLower.contains(lower) else { return false }
            // Проверка орфографии принимает короткие аббревиатуры вроде «BB» за слова
            let shortAcronym = word.count <= 4 && word == word.uppercased()
            return shortAcronym || !checker.isCommonWord(word, language: .en)
        }
        return (2...5).contains(word.count) && word == word.uppercased()
    }

    private func candidates(for word: String) -> [String] {
        let key = Array(Phonetics.soundKey(word))
        guard !key.isEmpty else { return [] }
        let letters = Phonetics.latinLetters(word)
        let lower = word.lowercased()
        var scored: [(similarity: Double, distance: Double, ordinal: Int, spelling: String)] = []
        for term in soundTerms where term.lowered != lower {
            var best: Double?
            for termKey in term.keys {
                let longest = max(key.count, termKey.count)
                let limit = longest <= 2 ? 0 : (longest <= 5 ? 1 : 2)
                let distance = Self.levenshtein(key, termKey)
                if distance <= limit { best = max(best ?? 0, 1 - Double(distance) / Double(longest)) }
            }
            if let best {
                scored.append((best, Phonetics.normalizedDistance(letters, term.letters), term.ordinal, term.spelling))
            }
        }
        scored.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.ordinal < $1.ordinal
        }
        var seen = Set<String>()
        return scored.map(\.spelling).filter { seen.insert($0.lowercased()).inserted }.prefix(Self.maxCandidates).map { $0 }
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: - Fuzzy

    private static let fuzzyMinLetters = 6
    private static let fuzzyThreshold = 0.8
    private static let fuzzyLengthSlack = 3

    /// Теневой режим: похожие по звучанию слова, которые точная замена не тронула. Текст не меняется.
    func fuzzyHits(in text: String, language: DictionaryLanguage) -> [FuzzyHit] {
        guard !text.isEmpty, let groups = fuzzyGroups[language], !groups.isEmpty else { return [] }
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return [] }
        let handled = tables[language].map {
            rewrite(text, tokens: tokens, language: language, table: $0).handled
        } ?? []

        var hits: [FuzzyHit] = []
        var rows: [Int] = []
        for (index, token) in tokens.enumerated() where !handled.contains(index) {
            guard token.lower.reduce(0, { $1.isLetter ? $0 + 1 : $0 }) >= Self.fuzzyMinLetters else { continue }
            let tokenKey = language == .ru ? token.lower : Phonetics.englishKey(token.lower)
            let scalars = tokenKey.unicodeScalars.map(\.value)
            guard let first = tokenKey.first else { continue }
            let tokenMask = Self.letterMask(scalars)
            guard !checker.isCommonWord(token.lower, language: language) else { continue }

            var best: (spelling: String, similarity: Double, ordinal: Int)?
            for length in max(1, scalars.count - Self.fuzzyLengthSlack)...(scalars.count + Self.fuzzyLengthSlack) {
                guard let group = groups[FuzzyGroupKey(first: first, length: length)] else { continue }
                // Порог 0.8 означает расстояние не больше пятой части длиннейшего ключа.
                let longest = max(length, scalars.count)
                let limit = longest / 5
                guard abs(length - scalars.count) <= limit else { continue }
                for candidate in group where (candidate.mask ^ tokenMask).nonzeroBitCount <= 2 * limit && candidate.lowered != token.lower {
                    guard let distance = Self.boundedDistance(scalars, candidate.key, limit: limit, rows: &rows) else { continue }
                    let score = 1 - Double(distance) / Double(longest)
                    guard score >= Self.fuzzyThreshold else { continue }
                    if let current = best, score < current.similarity || (score == current.similarity && candidate.ordinal > current.ordinal) { continue }
                    best = (candidate.spelling, score, candidate.ordinal)
                }
            }
            if let best {
                hits.append(FuzzyHit(token: String(text[token.range]), spelling: best.spelling, similarity: best.similarity))
            }
        }
        return hits
    }

    /// Одна правка меняет набор букв не больше чем на два бита, поэтому больше 2 * limit битов значит отказ.
    private static func letterMask(_ scalars: [UInt32]) -> UInt32 {
        scalars.reduce(0) { $0 | (1 << ($1 % 32)) }
    }

    /// Расстояние Левенштейна, если оно не больше `limit`; иначе nil.
    /// Считается только полоса шириной `limit` вокруг диагонали и обрывается, когда вся строка выше лимита.
    private static func boundedDistance(_ a: [UInt32], _ b: [UInt32], limit: Int, rows: inout [Int]) -> Int? {
        let n = a.count, m = b.count
        if abs(n - m) > limit { return nil }
        if n == 0 || m == 0 { return max(n, m) }
        let width = m + 2
        if rows.count < 2 * width { rows = Array(repeating: 0, count: 2 * width) }
        let inf = limit + 1
        return rows.withUnsafeMutableBufferPointer { buffer -> Int? in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    var prev = buffer.baseAddress!
                    var cur = prev + width
                    for j in 0...m { prev[j] = min(j, inf) }
                    for i in 1...n {
                        let lo = max(1, i - limit), hi = min(m, i + limit)
                        cur[lo - 1] = lo == 1 ? min(i, inf) : inf
                        var rowMin = cur[lo - 1]
                        let x = a[i - 1]
                        for j in lo...hi {
                            let value = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x == b[j - 1] ? 0 : 1), inf)
                            cur[j] = value
                            if value < rowMin { rowMin = value }
                        }
                        if hi < m { cur[hi + 1] = inf }
                        if rowMin > limit { return nil }
                        swap(&prev, &cur)
                    }
                    return prev[m] <= limit ? prev[m] : nil
                }
            }
        }
    }

    /// Ключ написания: кириллическая транслитерация для русского, английский ключ для английского.
    private static func fuzzyKey(_ word: String, language: DictionaryLanguage) -> String {
        switch language {
        case .ru: return Phonetics.transliterateToCyrillic(word)
        case .en: return Phonetics.englishKey(word)
        }
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

    private struct SoundTerm {
        let spelling: String
        let lowered: String
        let keys: [[Character]]
        let letters: String
        /// Порядок добавления: сначала пользовательские записи, затем наборы.
        let ordinal: Int
    }

    private struct FuzzyGroupKey: Hashable {
        let first: Character
        let length: Int
    }

    private struct FuzzyCandidate {
        let spelling: String
        let lowered: String
        let key: [UInt32]
        /// Набор букв ключа по модулю 32, быстрый отсев до подсчёта расстояния.
        let mask: UInt32
        /// Порядок добавления: сначала пользовательские записи, затем наборы.
        let ordinal: Int
    }

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
        /// `checker` проверяет однословные русские варианты; `nil` для заранее проверенных вариантов наборов.
        mutating func add(
            spelling: String, entryKey: String, variants: [String],
            caseFixEligible: Bool, language: DictionaryLanguage, checker: CommonWordChecking?
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

                // `checker == nil`: вариант заранее проверен и не словарный.
                if language == .ru, words.count == 1, checker?.isCommonWord(first, language: .ru) != true {
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

    /// Латинское написание или кириллическая аббревиатура, например НДС или 1С, заменяют всю словоформу.
    private static func swallowsEnding(_ spelling: String) -> Bool {
        guard spelling.contains(where: isCyrillic) else { return true }
        return spelling.count >= 2
            && spelling.allSatisfy { ($0.isLetter || $0.isNumber) && !$0.isLowercase }
            && spelling.contains { isCyrillic($0) && $0.isUppercase }
    }

    private static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
