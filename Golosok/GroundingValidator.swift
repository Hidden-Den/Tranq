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

    private static let promptStructuralTokens: Set<String> = [
        "role", "task", "constraints", "context", "input", "output", "prompt",
        "instructions", "goal", "example", "steps", "rules", "format"
    ]

    /// Полная детерминированная валидация сгенерированного текста с учетом дифференцированных порогов стилей
    public static func validate(
        input: String,
        output: String,
        level: CleanupLevel,
        customTerms: Set<String> = []
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
        let inputNumbers = extractNumbers(from: trimmedInput)
        let outputNumbers = extractNumbers(from: sanitizedOutput)

        // На уровнях очистки и переписывания все исходные числа должны сохраняться
        if isClean || isRewrite {
            for num in inputNumbers {
                if !outputNumbers.contains(num) {
                    return .rejected(reason: "Пропущено исходное число \(num)")
                }
            }
        }

        for num in outputNumbers {
            if !inputNumbers.contains(num) {
                return .rejected(reason: "Модель придумала число \(num), отсутствовавшее в речи")
            }
        }

        // 5. Проверка латиницы и пользовательского словаря терминов
        if level != .prompt {
            let inputLatinLower = Set(extractLatinTokens(from: trimmedInput).map { $0.lowercased() })
            let outputLatin = extractLatinTokens(from: sanitizedOutput)
            var customTermsTokens = Set<String>()
            for term in customTerms {
                for tok in extractLatinTokens(from: term) {
                    customTermsTokens.insert(tok.lowercased())
                }
            }

            for token in outputLatin {
                let lowerToken = token.lowercased()
                if inputLatinLower.contains(lowerToken) || customTermsTokens.contains(lowerToken) {
                    continue
                }
                return .rejected(reason: "Новый термин \(token) не найден в речи или словаре")
            }

            // Латинские термины речи, как и числа, обязаны дожить до результата
            if isClean || isRewrite {
                let outputLatinLower = Set(outputLatin.map { $0.lowercased() })
                if let missing = inputLatinLower.sorted().first(where: { !outputLatinLower.contains($0) }) {
                    return .rejected(reason: "Пропущен исходный термин \(missing)")
                }
            }
        }

        // 7. Дифференцированная проверка длины по стилям
        let maxAllowedWords: Int
        switch level {
        case .verbatim, .clean:
            maxAllowedWords = max(inputWordCount + 2, Int(Double(inputWordCount) * 1.2))
        case .rewrite:
            maxAllowedWords = max(12, Int(Double(inputWordCount) * 2.0))
        case .prompt:
            maxAllowedWords = max(25, Int(Double(inputWordCount) * 3.0))
        }

        if outputWordCount > maxAllowedWords {
            return .rejected(reason: "Выход модели превысил допустимый объем генерации для выбранного стиля")
        }

        // 8. Чистая мысль только удаляет мусор: пересказ своими словами отклоняется
        if isClean, let reason = rewriteViolation(input: trimmedInput, output: sanitizedOutput, customTerms: customTerms) {
            return .rejected(reason: reason)
        }

        return .valid(sanitizedText: sanitizedOutput)
    }

    // MARK: - Защита от пересказа

    /// Доля слов результата, которых не было в речи, выше которой ответ считается пересказом.
    static let maxNovelWordShare = 0.2

    /// Сравнивает слова речи и результата без учёта порядка: перестановка «успеем ли мы» не пересказ.
    /// Числа не учитываются, их сверяет проверка чисел. Возвращает причину отказа, если модель добавила
    /// много новых слов. Сокращение речи не ошибка: уровень очистки убирает повторы мыслей.
    static func rewriteViolation(input: String, output: String, customTerms: Set<String> = []) -> String? {
        let inputWords = comparableWords(input).filter { !containsDigit($0) }
        let outputWords = comparableWords(output).filter { !containsDigit($0) }
        guard !inputWords.isEmpty, !outputWords.isEmpty else { return nil }

        let allowed = Set(customTerms.flatMap { comparableWords($0) })
        var remaining = Dictionary(inputWords.map { ($0, 1) }, uniquingKeysWith: +)
        var novel = 0
        for word in outputWords {
            if let count = remaining[word], count > 0 {
                remaining[word] = count - 1
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

    private static func hasLeadingQuestionKeyword(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = ["как ", "почему ", "где ", "когда ", "сколько ", "зачем ", "что такое", "кто такой"]
        if keywords.contains(where: { lower.hasPrefix($0) }) {
            return true
        }
        let conversationalPrefixes = ["подскажи, ", "подскажи ", "скажи, ", "скажи ", "слушай, ", "слушай "]
        for prefix in conversationalPrefixes {
            if lower.hasPrefix(prefix) {
                let remainder = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if keywords.contains(where: { remainder.hasPrefix($0) }) {
                    return true
                }
            }
        }
        return false
    }

    private static func extractNumbers(from text: String) -> Set<String> {
        let processedText = text
        let pattern = #"(?<![\d.,])\d+(?:[.,]\d+)?(?![\d.,])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = processedText as NSString
        let matches = regex.matches(in: processedText, options: [], range: NSRange(location: 0, length: nsString.length))
        var numbers = Set<String>()
        for m in matches {
            numbers.insert(nsString.substring(with: m.range))
        }
        return numbers
    }

    private static func extractLatinTokens(from text: String) -> Set<String> {
        let pattern = #"\b[A-Za-z][A-Za-z0-9_-]*\b"#
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
