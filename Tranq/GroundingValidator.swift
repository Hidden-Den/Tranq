import Foundation

public enum ValidationResult: Equatable {
    case valid(sanitizedText: String)
    case rejected(reason: String)
}

public struct GroundingValidator {

    private static let forbiddenPreambles: [String] = [
        "вот ваш текст",
        "исправленный вариант",
        "результат",
        "конечно",
        "я исправил",
        "текст расшифровки",
        "очищенный текст",
        "исходный текст"
    ]

    /// Полная детерминированная валидация сгенерированного текста с учетом дифференцированных порогов стилей
    public static func validate(
        input: String,
        output: String,
        level: CleanupLevel,
        customTerms: Set<String> = [],
        termSuspects: [TermSuspect] = []
    ) -> ValidationResult {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Уровень A обходится без модели, проверять нечего
        if level == .verbatim { return .valid(sanitizedText: output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let isClean = level == .clean
        var isRewrite = false
        if case .rewrite = level { isRewrite = true }
        var sanitizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitizedOutput.isEmpty else {
            return .rejected(reason: "Пустой ответ модели")
        }

        // Очистка от шаблонных меток разделения (например: "Исходный текст: ... Очищенный текст: ...")
        let sectionPattern = #"(?is)^\s*исходный\s+текст\s*:.*?(?:очищенный|исправленный|отредактированный)\s+текст\s*:\s*"#
        if let match = sanitizedOutput.range(of: sectionPattern, options: .regularExpression) {
            let extracted = String(sanitizedOutput[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty {
                sanitizedOutput = extracted
            }
        }

        // 0. Служебные метки шаблона чата, которые модель иногда выдаёт вместе с ответом
        sanitizedOutput = stripChatTemplateTokens(sanitizedOutput)

        // 1. Очистка внешних кавычек если модель их добавила
        if (sanitizedOutput.hasPrefix("\"") && sanitizedOutput.hasSuffix("\"")) ||
           (sanitizedOutput.hasPrefix("«") && sanitizedOutput.hasSuffix("»")) {
            sanitizedOutput = String(sanitizedOutput.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !sanitizedOutput.isEmpty else {
            return .rejected(reason: "Пустой ответ после очистки кавычек")
        }

        // 2. Проверка на мета-зачины
        let lowerOutput = sanitizedOutput.lowercased()
        for preamble in forbiddenPreambles {
            if lowerOutput.hasPrefix(preamble) {
                return .rejected(reason: "Обнаружен мета-префикс в начале ответа")
            }
        }

        let inputWordCount = trimmedInput.split(whereSeparator: { $0.isWhitespace }).count
        let outputWordCount = sanitizedOutput.split(whereSeparator: { $0.isWhitespace }).count

        // 3. Проверка вопросов (защита от чат-бот ответов)
        let isDirectQuestion = (hasLeadingQuestionKeyword(trimmedInput) || (inputWordCount <= 12 && trimmedInput.hasSuffix("?")))
        let hasQuestionMark = trimmedInput.contains("?")

        if isDirectQuestion {
            // Для чистой мысли и делового стиля прямой вопрос обязан оставаться вопросом
            if (isClean || isRewrite) && !sanitizedOutput.contains("?") && !hasLeadingQuestionKeyword(sanitizedOutput) {
                return .rejected(reason: "Модель ответила на вопрос вместо сохранения вопроса")
            }
            if isClean && outputWordCount > max(6, inputWordCount + 4) {
                return .rejected(reason: "Модель попыталась ответить на вопрос вместо его очистки")
            }
        } else if hasQuestionMark {
            // Если вопросительный знак встретился в длинной мысли или сложноподчиненном предложении
            // (например, «Нужно подумать, как сделать...?»), отклоняем только если модель развернула ответ
            if isClean && outputWordCount > max(6, inputWordCount + 4) {
                return .rejected(reason: "Модель попыталась ответить на вопрос вместо его очистки")
            }
        }

        // 4. Проверка чисел (Strict Numbers Grounding)
        // Оба текста сравниваются после одной нормализации: «четвёртом» и «4», «12:00» и «12» равны
        let inputNumbers = Set(normalizedNumbers(in: trimmedInput).map(\.value))
        let outputNumbers = Set(normalizedNumbers(in: sanitizedOutput).map(\.value))

        // На уровнях очистки и переписывания исходные числа сохраняются,
        // кроме тех, что говорящий сам исправил: «10 процентов, нет, 15»
        if isClean || isRewrite {
            let corrected = correctedNumbers(in: trimmedInput)
            for num in inputNumbers.sorted() where !outputNumbers.contains(num) && !corrected.contains(num) {
                return .rejected(reason: "Пропущено исходное число \(num)")
            }
        }

        for num in outputNumbers.sorted() where !inputNumbers.contains(num) {
            return .rejected(reason: "Модель придумала число \(num), отсутствовавшее в речи")
        }

        // 5. Проверка латиницы и пользовательского словаря терминов
        let inputLatinLower = Set(extractLatinTokens(from: withoutNumberSign(trimmedInput)).map { $0.lowercased() })
        let outputLatin = extractLatinTokens(from: withoutNumberSign(sanitizedOutput))
        var customTermsTokens = Set<String>()
        for term in customTerms {
            for tok in extractLatinTokens(from: term) {
                customTermsTokens.insert(tok.lowercased())
            }
        }

        // Термины, записанные латиницей вместо русского звучания: промпт сам велит так писать
        let spokenWords = cyrillicWords(trimmedInput)
        var spokenTerms = Set<String>()
        for token in outputLatin {
            let lowerToken = token.lowercased()
            if inputLatinLower.contains(lowerToken) || customTermsTokens.contains(lowerToken) {
                continue
            }
            if soundsSpoken(token, words: spokenWords) {
                spokenTerms.insert(token)
                continue
            }
            return .rejected(reason: "Новый термин \(token) не найден в речи или словаре")
        }

        // Латинские термины речи, как и числа, обязаны дожить до результата
        if isClean || isRewrite {
            let outputLatinLower = Set(outputLatin.map { $0.lowercased() })
            // Слово, которое распознавание исказило из термина, можно заменить подобранным термином
            let replaced = replacedSuspectWords(termSuspects, output: sanitizedOutput)
                .union(retractedTerms(in: trimmedInput))
            if let missing = inputLatinLower.sorted().first(where: { !outputLatinLower.contains($0) && !replaced.contains($0) }) {
                return .rejected(reason: "Пропущен исходный термин \(missing)")
            }
        }

        // 7. Дифференцированная проверка длины по стилям
        let maxAllowedWords: Int
        switch level {
        case .verbatim, .clean:
            maxAllowedWords = max(inputWordCount + 2, Int(Double(inputWordCount) * 1.2))
        case .rewrite:
            maxAllowedWords = max(12, Int(Double(inputWordCount) * 2.0))
        }

        if outputWordCount > maxAllowedWords {
            return .rejected(reason: "Выход модели превысил допустимый объем генерации для выбранного стиля")
        }

        // 8. Чистая мысль только удаляет мусор: пересказ своими словами отклоняется
        if isClean, let reason = rewriteViolation(input: trimmedInput, output: sanitizedOutput, customTerms: customTerms.union(spokenTerms)) {
            return .rejected(reason: reason)
        }

        return .valid(sanitizedText: sanitizedOutput)
    }

    // MARK: - Словоформы

    /// Буквы окончаний коротких слов: «окно» и «окне» одно слово, «стол» и «стоп» разные.
    private static let endingLetters: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я", "ь", "й"]

    /// Буквы, из которых складываются окончания длинных слов: «каком» и «какое»,
    /// «режима» и «режимов», «делал» и «делаю», «какого» и «какой».
    private static let inflectionLetters = endingLetters.union(["м", "х", "т", "ш", "в", "л", "г"])

    /// Одно ли это слово в разных формах. Модель чинит согласование: «какое окно идёт
    /// диктовка» → «в каком окне идёт диктовка», и новые формы не новые слова.
    /// Слова от пяти букв: общее начало не короче четырёх букв, расходятся не больше трёх
    /// последних, и расходятся только буквы окончаний: «запас» и «запах», «переход»
    /// и «перевод» разные слова. Короткие слова: расходится только последняя гласная.
    /// «-ся» меняет значение глагола: «переключать» и «переключаться» разные слова.
    static func sameLexeme(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        var x = Array(a), y = Array(b)
        let reflexive = { (word: [Character]) in word.count > 4 && ["ся", "сь"].contains(String(word.suffix(2))) }
        guard reflexive(x) == reflexive(y) else { return false }
        if reflexive(x) { x.removeLast(2); y.removeLast(2) }
        let shorter = min(x.count, y.count)
        guard shorter >= 3 else { return false }
        var prefix = 0
        while prefix < shorter, x[prefix] == y[prefix] { prefix += 1 }
        if shorter >= 5 {
            return prefix >= max(4, shorter - 3)
                && x[prefix...].allSatisfy(inflectionLetters.contains) && y[prefix...].allSatisfy(inflectionLetters.contains)
        }
        guard prefix >= shorter - 1 else { return false }
        return x[prefix...].allSatisfy(endingLetters.contains) && y[prefix...].allSatisfy(endingLetters.contains)
    }

    // MARK: - Отозванный термин

    /// Слова, после которых говорящий отменяет только что сказанный термин.
    private static let termRetractions: Set<String> = ["точнее", "вернее", "нет"]

    /// Латинские термины речи в нижнем регистре, от которых говорящий сам отказался:
    /// «какой-нибудь API, ну, не API» или «в Jira, точнее, в Linear». Модель убирает их
    /// по правилу самоисправления, и требовать их обратно нельзя. Нужен явный отказ:
    /// «не» и тот же термин, или «точнее», «вернее», «нет» не дальше четырёх слов и за ними
    /// не дальше трёх слов другой термин. «В этом API нет ошибок» обычное отрицание.
    static func retractedTerms(in input: String) -> Set<String> {
        let words = comparableWords(input)
        let latin = Set(extractLatinTokens(from: input).map { $0.lowercased() })
        var retracted = Set<String>()
        for (index, word) in words.enumerated() where latin.contains(word) {
            let window = words[(index + 1)..<min(index + 5, words.count)]
            for (offset, next) in zip(window.indices, window) {
                let replacement = words[(offset + 1)..<min(offset + 4, words.count)]
                    .contains { latin.contains($0) && $0 != word }
                if (termRetractions.contains(next) && replacement)
                    || (next == "не" && offset + 1 < words.count && words[offset + 1] == word) {
                    retracted.insert(word)
                }
            }
        }
        return retracted
    }

    // MARK: - Термин по звучанию

    /// Наименьшая похожесть написаний, при которой латинский термин считается записью
    /// русского слова из речи. Совпадения скелета согласных мало: «камень» и Gemini оба
    /// дают к-м-н, а пишутся непохоже.
    static let minSpokenTermSimilarity = 0.5

    /// Звучит ли латинский термин как одно из русских слов речи: «Джиминай» как Gemini,
    /// «антигравити» как Antigravity, «Линяр» как Linear. Нужны оба совпадения: скелет
    /// согласных из `Phonetics.soundKey` и похожее написание после транслитерации.
    static func soundsSpoken(_ term: String, words: [String]) -> Bool {
        let lower = term.lowercased()
        // Мягкое g перед e, i, y читается «дж»: Gemini это «джемини», а скелет у g твёрдый
        let soft = lower.replacingOccurrences(of: #"g(?=[eiy])"#, with: "dzh", options: .regularExpression)
        let readings = lower == soft ? [lower] : [lower, soft]
        for word in words {
            let wordKey = Phonetics.soundKey(word)
            // Короткий термин вроде RAG: скелет из двух согласных, поэтому нужно точное написание
            if wordKey.count == 2, readings.contains(where: {
                Phonetics.soundKey($0) == wordKey && Phonetics.transliterateToCyrillic($0) == word
            }) { return true }
            guard wordKey.count >= 3 else { continue }
            for reading in readings {
                let key = Phonetics.soundKey(reading)
                guard key.count >= 3 else { continue }
                // Короткий скелет только целиком, длинный с одной ошибкой на четыре звука
                let skeleton = key == wordKey
                    || (min(key.count, wordKey.count) >= 4 && Phonetics.normalizedDistance(key, wordKey) <= 0.25)
                guard skeleton else { continue }
                let letters = 1 - Phonetics.normalizedDistance(word, Phonetics.transliterateToCyrillic(reading))
                if letters >= minSpokenTermSimilarity { return true }
            }
        }
        return false
    }

    /// Русские слова речи в нижнем регистре, без знаков.
    static func cyrillicWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { word in word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
    }

    // MARK: - Защита от пересказа

    /// Доля слов результата, которых не было в речи, выше которой ответ считается пересказом.
    static let maxNovelWordShare = 0.2

    /// Сравнивает слова речи и результата без учёта порядка: перестановка «успеем ли мы» не пересказ.
    /// Числа не учитываются, их сверяет проверка чисел. Возвращает причину отказа, если модель добавила
    /// много новых слов. Сокращение речи не ошибка: уровень очистки убирает повторы мыслей.
    static func rewriteViolation(input: String, output: String, customTerms: Set<String> = []) -> String? {
        // Числа прописью сравниваются как цифры: «два» и «2» одно число, его сверяет проверка чисел
        let inputWords = comparableWords(normalizedWords(input).joined(separator: " ")).filter { !containsDigit($0) }
        let outputWords = comparableWords(normalizedWords(output).joined(separator: " ")).filter { !containsDigit($0) }
        guard !inputWords.isEmpty, !outputWords.isEmpty else { return nil }

        let allowed = Set(customTerms.flatMap { comparableWords($0) })
        var remaining = Dictionary(inputWords.map { ($0, 1) }, uniquingKeysWith: +)
        var novel = 0
        for word in outputWords {
            if let count = remaining[word], count > 0 {
                remaining[word] = count - 1
            } else if let form = remaining.first(where: { $0.value > 0 && sameLexeme($0.key, word) })?.key {
                // Та же лексема в другой форме: модель починила согласование
                remaining[form]! -= 1
            } else if !allowed.contains(word) {
                novel += 1
            }
        }

        let novelBudget = max(1, Int((Double(outputWords.count) * maxNovelWordShare).rounded(.down)))
        if novel > novelBudget {
            return "Модель переписала речь своими словами: \(novel) новых слов из \(outputWords.count)"
        }

        return nil
    }

    /// Латинские слова подозрений в нижнем регистре, вместо которых в ответе стоит один из их кандидатов.
    static func replacedSuspectWords(_ suspects: [TermSuspect], output: String) -> Set<String> {
        var replaced = Set<String>()
        for suspect in suspects {
            let hasCandidate = suspect.candidates.contains { candidate in
                let words = candidate.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
                return output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if hasCandidate {
                replaced.formUnion(extractLatinTokens(from: suspect.token).map { $0.lowercased() })
            }
        }
        return replaced
    }

    /// Слова в нижнем регистре без знаков препинания по краям; «ё» приравнивается к «е».
    static func comparableWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace || $0 == "—" || $0 == "–" })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    private static func containsDigit(_ word: String) -> Bool {
        word.contains(where: \.isNumber)
    }

    // MARK: - Вспомогательные методы

    /// Паразиты и обращения в начале фразы, после которых ищется вопросительное слово.
    /// «Как бы» стоит первым: иначе оно читается как вопрос «как».
    private static let leadingFillers = [
        "как бы", "ну", "э-э", "эээ", "ээ", "ммм", "так", "слушай", "короче", "типа", "подскажи", "скажи"
    ]

    private static func hasLeadingQuestionKeyword(_ text: String) -> Bool {
        var lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = true
        while stripped {
            stripped = false
            for filler in leadingFillers where lower.hasPrefix(filler) {
                let rest = lower.dropFirst(filler.count)
                guard let next = rest.first, next == "," || next == " " || next == "." else { continue }
                lower = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: ",. "))
                stripped = true
                break
            }
        }
        let keywords = ["как ", "почему ", "где ", "когда ", "сколько ", "зачем ", "что такое", "кто такой"]
        return keywords.contains(where: { lower.hasPrefix($0) })
    }

    private static func stripChatTemplateTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|>]{1,40}\|>|<start_of_turn>|<end_of_turn>|<eos>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// «No 9» и «N 9» — знак номера из распознавания, а не латинский термин.
    private static func withoutNumberSign(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b(?:No|N)\.?\s*(?=\d)"#, with: "", options: .regularExpression)
    }

    // MARK: - Числа

    struct NumberToken: Equatable {
        let value: String
        /// Номер слова в нормализованном тексте, нужен для поиска самоисправлений.
        let index: Int
    }

    /// Собирательные числительные, которых нет в NumberNormalizer: «трое прошли в финал».
    private static let collectiveNumerals: [String: String] = [
        "двое": "2", "трое": "3", "четверо": "4", "пятеро": "5", "шестеро": "6",
        "семеро": "7", "восьмеро": "8", "девятеро": "9", "десятеро": "10"
    ]

    /// Слова текста после той же нормализации, что у входа модели: «ё» как «е», числительные цифрами.
    static func normalizedWords(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let collective = lowered.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let core = word.trimmingCharacters(in: .punctuationCharacters)
            guard let digit = collectiveNumerals[core] else { return String(word) }
            return String(word).replacingOccurrences(of: core, with: digit)
        }.joined(separator: " ")
        return NumberNormalizer.normalize(collective)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Числа текста после нормализации. Время «H:MM» даёт часы и минуты: «14:30» равно «14 часов 30 минут»,
    /// а «12:00» равно «12».
    static func normalizedNumbers(in text: String) -> [NumberToken] {
        var tokens: [NumberToken] = []
        let edge = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: ":"))
        for (index, raw) in normalizedWords(text).enumerated() {
            let word = raw.trimmingCharacters(in: edge.union(CharacterSet(charactersIn: ":")))
            guard let first = word.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) else { continue }
            if let time = word.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) {
                let parts = word[time].split(separator: ":")
                tokens.append(NumberToken(value: String(Int(parts[0]) ?? 0), index: index))
                if parts[1] != "00" { tokens.append(NumberToken(value: String(Int(parts[1]) ?? 0), index: index)) }
                continue
            }
            if let number = word.range(of: #"^\d+(?:[.,]\d+)?"#, options: .regularExpression) {
                tokens.append(NumberToken(value: word[number].replacingOccurrences(of: ".", with: ","), index: index))
            }
        }
        return tokens
    }

    /// Слова, которыми говорящий отменяет только что сказанное число.
    private static let correctionMarkers: Set<String> = [
        "нет", "ой", "точнее", "вернее", "подожди", "стоп", "извини", "ну", "есть"
    ]

    /// Числа речи, которые говорящий сам исправил: за числом не дальше шести слов идёт
    /// маркер исправления, а за маркером не дальше четырёх слов — другое число.
    /// «есть» в маркерах ловит «то есть».
    static func correctedNumbers(in input: String) -> Set<String> {
        let words = normalizedWords(input).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let numbers = normalizedNumbers(in: input)
        var corrected = Set<String>()
        for number in numbers {
            let markerRange = (number.index + 1)...min(number.index + 6, max(number.index + 1, words.count - 1))
            guard let marker = markerRange.first(where: { index in
                guard index < words.count, correctionMarkers.contains(words[index]) else { return false }
                return words[index] != "есть" || (index > 0 && words[index - 1] == "то")
            }) else { continue }
            let replaced = numbers.contains { $0.index > marker && $0.index <= marker + 4 && $0.value != number.value }
            if replaced { corrected.insert(number.value) }
        }
        return corrected
    }

    private static func extractLatinTokens(from text: String) -> Set<String> {
        // Дефис входит в слово, только если за ним снова латиница: «API-ключ» даёт API, а не «API-»
        let pattern = #"\b[A-Za-z][A-Za-z0-9_]*(?:-[A-Za-z0-9_]+)*\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        var tokens = Set<String>()
        for m in matches {
            tokens.insert(nsString.substring(with: m.range))
        }
        return tokens
    }
}
