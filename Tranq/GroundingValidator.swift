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
            // Русские аббревиатуры тоже: БТИ или НДС в результате нечем заменить
            if let missing = missingCyrillicAbbreviation(input: trimmedInput, output: sanitizedOutput, termSuspects: termSuspects) {
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
        // 9. Тон переписывает речь, но не отвечает вместо неё и не уходит от её темы
        if isRewrite, let reason = toneViolation(input: trimmedInput, output: sanitizedOutput) {
            return .rejected(reason: reason)
        }

        if isClean, let reason = rewriteViolation(input: trimmedInput, output: sanitizedOutput, customTerms: customTerms.union(spokenTerms)) {
            return .rejected(reason: reason)
        }

        return .valid(sanitizedText: sanitizedOutput)
    }

    // MARK: - Уровень с тоном

    /// Слова ответа модели о самой задаче: отказ и разговор о тексте. Регулярные выражения
    /// по тексту в нижнем регистре; второе поле — начала слов речи, при которых те же слова
    /// сказал сам говорящий. Отдельные «не могу», «к сожалению», «нецензурная» бывают и
    /// в деловом переписывании, поэтому признаки отказа только связками.
    private static let toneMetaMarkers: [(pattern: String, spokenStems: [String])] = [
        (#"не (?:могу|буду|стану) (?:обработ|перепис|переформулир|отредакт)"#, []),
        // Общий отказ, если о помощи, ответе или выполнении говорящий сам не говорил
        (#"не (?:могу|буду|стану) (?:помочь|ответить|выполнить)"#, ["помо", "ответ", "выполн"]),
        (#"переформулируй|(?:прошу|просим|предлагаю|попробуйте|можете|могли бы вы) переформулир"#, ["формулир"]),
        (#"корректн\w* форм|форм\w* обращени|более корректн"#, []),
        (#"(?:текст|сообщени|расшифровк|запрос)\w* (?:не )?содерж"#, []),
        (#"расшифровк"#, ["расшифр"]), (#"транскрип"#, ["транскрип"]),
        (#"переписанн\w* (?:текст|вариант)|вот (?:текст|вариант)"#, []),
        (#"в (?:деловом|живом) (?:тоне|стиле)"#, ["тон", "стил"]),
    ]

    /// Пожелания и вежливые формулы от первого лица, которых в речи не было:
    /// «я хотел бы, чтобы вопрос был решён» к ругани про подрядчика не относится.
    private static let toneInventedCourtesy: [(marker: String, spokenStems: [String])] = [
        ("хотел бы", ["хоте", "хочу", "хочет"]), ("хотела бы", ["хоте", "хочу", "хочет"]),
        ("хотели бы", ["хоте", "хочу", "хочет"]), ("хотелось бы", ["хоте", "хочу", "хочет"]),
        ("буду признател", ["признател"]), ("будем признател", ["признател"]),
        ("буду благодар", ["благодар"]), ("будем благодар", ["благодар"]),
        ("благодарю за", ["благодар", "спасиб"]), ("заранее спасибо", ["спасиб"]),
        ("с уважением", ["уважени"]),
    ]

    /// Служебные слова, общие для любых двух текстов: по ним тему не сверить.
    private static let toneStopWords: Set<String> = [
        "этот", "этого", "этому", "этом", "эта", "эту", "этой", "эти", "этих", "этим", "это",
        "который", "которая", "которые", "которых", "чтобы", "когда", "если", "потом", "тоже",
        "только", "очень", "можно", "нужно", "надо", "будет", "было", "были", "есть", "себя",
        "свой", "своя", "свои", "такой", "такая", "такие", "также", "просто", "вообще", "тогда",
        "здесь", "сейчас", "именно", "ещё", "еще", "даже", "уже", "либо", "или", "как", "что",
        "так", "там", "тут", "вот", "они", "она", "оно", "него", "нему", "ними", "него", "мне",
        "меня", "тебя", "тебе", "нас", "вас", "нам", "вам", "всё", "все", "всех", "весь",
    ]

    /// Смысловых слов в речи, с которых сверяется тема. Короткую фразу деловой тон вправе
    /// переписать целиком: «спасибо огромное, вы нас выручили» и «благодарю за помощь».
    static let minToneContentWords = 5

    /// Ответ модели вместо переписанной речи: отказ, разговор о задаче, придуманное пожелание
    /// от первого лица или текст совсем о другом. Тон вправе менять слова, но не тему: если
    /// в речи от пяти смысловых слов, хотя бы одно из них остаётся в какой-то форме.
    static func toneViolation(input: String, output: String) -> String? {
        let spoken = input.lowercased().replacingOccurrences(of: "ё", with: "е")
        let written = output.lowercased().replacingOccurrences(of: "ё", with: "е")
        for (pattern, stems) in toneMetaMarkers where !stems.contains(where: spoken.contains) {
            guard let found = written.range(of: pattern, options: .regularExpression),
                  spoken.range(of: pattern, options: .regularExpression) == nil else { continue }
            return "Модель ответила вместо переписанной речи: «\(written[found])»"
        }
        for (marker, stems) in toneInventedCourtesy where written.contains(marker) && !spoken.contains(marker)
            && !stems.contains(where: spoken.contains) {
            return "Модель добавила пожелание от себя: «\(marker)»"
        }

        if let addressee = letterAddressee(input: input, output: output) {
            return "Модель написала письмо адресату вместо поручения: \(addressee)"
        }

        let spokenContent = Set(toneContentWords(input))
        guard spokenContent.count >= minToneContentWords else { return nil }
        let writtenContent = toneContentWords(output)
        let shared = spokenContent.contains { word in writtenContent.contains { sameRoot(word, $0) } }
        return shared ? nil : "Модель ушла от темы речи: ни одного общего слова"
    }

    /// Поручение написать или передать что-то человеку: «напиши Андрею», «передай Свете».
    private static let errandPattern = #"(?i)(?:напиши|напишите|скажи|скажите|передай|передайте|ответь|ответьте|спроси|спросите)\s+([А-ЯЁ][а-яё]+)"#

    /// Вежливый зачин письма перед обращением: «Добрый день, Андрей!».
    private static let letterGreeting = #"^(?:здравствуйте|добрый (?:день|вечер)|доброе утро|привет)[,!.]?\s*"#

    /// Имя адресата, если модель написала ему письмо вместо поручения: в речи «напиши Андрею»,
    /// а ответ начинается с обращения «Андрей,». Обращение к нему же в самой речи не в счёт.
    static func letterAddressee(input: String, output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: errandPattern) else { return nil }
        let ns = input as NSString
        let names = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).lowercased() }
        guard !names.isEmpty else { return nil }
        var opening = output.lowercased().replacingOccurrences(of: "ё", with: "е")
        if let greeting = opening.range(of: letterGreeting, options: .regularExpression) {
            opening = String(opening[greeting.upperBound...])
        }
        guard let first = opening.split(whereSeparator: \.isWhitespace).first,
              let mark = first.last, mark == "," || mark == "!" else { return nil }
        let addressed = String(first.dropLast())
        let spokenOpening = comparableWords(input).first ?? ""
        return names.first { sameLexeme($0, addressed) && !sameLexeme(spokenOpening, addressed) }
    }

    /// Смысловые слова для сверки темы: от четырёх букв, аббревиатуры и термины короче тоже.
    private static func toneContentWords(_ text: String) -> [String] {
        let abbreviations = Set(cyrillicAbbreviations(in: text).map { $0.lowercased() })
            .union(extractLatinTokens(from: text).map { $0.lowercased() })
        return comparableWords(text).filter { word in
            !containsDigit(word) && !toneStopWords.contains(word)
                && (word.count >= 4 || abbreviations.contains(word))
        }
    }

    /// Один корень при свободной смене формы: «сломали» и «сломалось», «играть» и «игры».
    /// Строже `sameLexeme` не нужно: здесь ищется хоть одна нить к речи, а не новые слова.
    private static func sameRoot(_ a: String, _ b: String) -> Bool {
        if sameLexeme(a, b) { return true }
        let x = Array(a), y = Array(b)
        let shorter = min(x.count, y.count)
        guard shorter >= 3 else { return a == b }
        var prefix = 0
        while prefix < shorter, x[prefix] == y[prefix] { prefix += 1 }
        return prefix >= min(4, shorter - 1)
    }

    // MARK: - Русские аббревиатуры

    /// Аббревиатуры речи кириллицей: от двух до восьми заглавных букв подряд, без строчных.
    /// «БТИ», «НДС», «ТЗ», «РОССТАТ».
    static func cyrillicAbbreviations(in text: String) -> Set<String> {
        let pattern = #"(?<![\p{L}\p{N}])[А-ЯЁ]{2,8}(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    /// Первая аббревиатура речи, которой нет в результате ни в какой форме: «БТИ» живёт и в «БТИшники»,
    /// а «ТЗ» в «техническом задании».
    /// Не требуются отозванная говорящим, «НДС, точнее НДФЛ», и латинский термин, который
    /// распознавание записало кириллицей: «ГИД» вместо Git, по словарю или по звучанию.
    static func missingCyrillicAbbreviation(input: String, output: String, termSuspects: [TermSuspect] = []) -> String? {
        let abbreviations = cyrillicAbbreviations(in: input)
        guard !abbreviations.isEmpty else { return nil }
        let lowered = Set(abbreviations.map { $0.lowercased() })
        let retracted = retractedTerms(in: input, among: lowered)
        let replaced = Set(termSuspects.filter { outputHasCandidate($0, output: output) }.map { $0.token.lowercased() })
        let written = comparableWords(output)
        let writtenLatin = extractLatinTokens(from: output)
        return abbreviations.sorted().first { abbreviation in
            let lower = abbreviation.lowercased()
            if retracted.contains(lower) || replaced.contains(lower) { return false }
            if written.contains(where: { $0.hasPrefix(lower) }) { return false }
            // Раскрытая аббревиатура: «ТЗ» как «техническое задание». Слова раскрытия от пяти букв
            // и не служебные, иначе «надо дать скидку» сошло бы за НДС
            let letters = Array(lower)
            if written.count >= letters.count, (0...(written.count - letters.count)).contains(where: { start in
                letters.indices.allSatisfy { index in
                    let word = written[start + index]
                    return word.first == letters[index] && word.count >= 5 && !toneStopWords.contains(word)
                }
            }) { return false }
            return !writtenLatin.contains { soundsSpoken($0, words: [lower]) }
        }
    }

    // MARK: - Словоформы

    /// Буквы окончаний коротких слов: «окно» и «окне» одно слово, «стол» и «стоп» разные.
    private static let endingLetters: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я", "ь", "й"]

    /// Одно ли это слово в разных формах. Модель чинит согласование: «какое окно идёт
    /// диктовка» → «в каком окне идёт диктовка», и новые формы не новые слова.
    /// Слова от пяти букв: общее начало не короче четырёх букв и расходятся не больше трёх
    /// последних. Короткие слова: расходится только последняя буква, и обе гласные.
    static func sameLexeme(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let shorter = min(x.count, y.count)
        guard shorter >= 3 else { return false }
        var prefix = 0
        while prefix < shorter, x[prefix] == y[prefix] { prefix += 1 }
        if shorter >= 5 { return prefix >= max(4, shorter - 3) }
        guard prefix >= shorter - 1 else { return false }
        return x[prefix...].allSatisfy(endingLetters.contains) && y[prefix...].allSatisfy(endingLetters.contains)
    }

    // MARK: - Отозванный термин

    /// Слова, после которых говорящий отменяет только что сказанный термин.
    private static let termRetractions: Set<String> = ["точнее", "вернее", "нет"]

    /// Латинские термины речи в нижнем регистре, от которых говорящий сам отказался:
    /// «какой-нибудь API, ну, не API» или «в Jira, точнее, в Linear». Модель убирает их
    /// по правилу самоисправления, и требовать их обратно нельзя. Нужен явный отказ:
    /// «не» и тот же термин, или «точнее», «вернее», «нет» не дальше четырёх слов.
    static func retractedTerms(in input: String) -> Set<String> {
        retractedTerms(in: input, among: Set(extractLatinTokens(from: input).map { $0.lowercased() }))
    }

    /// Те же отказы для заданных терминов речи в нижнем регистре.
    static func retractedTerms(in input: String, among latin: Set<String>) -> Set<String> {
        let words = comparableWords(input)
        var retracted = Set<String>()
        for (index, word) in words.enumerated() where latin.contains(word) {
            let window = words[(index + 1)..<min(index + 5, words.count)]
            for (offset, next) in zip(window.indices, window) {
                if termRetractions.contains(next)
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
        for suspect in suspects where outputHasCandidate(suspect, output: output) {
            replaced.formUnion(extractLatinTokens(from: suspect.token).map { $0.lowercased() })
        }
        return replaced
    }

    /// Стоит ли в ответе один из кандидатов подозрения целым словом.
    private static func outputHasCandidate(_ suspect: TermSuspect, output: String) -> Bool {
        suspect.candidates.contains { candidate in
            let words = candidate.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
            return output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
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
