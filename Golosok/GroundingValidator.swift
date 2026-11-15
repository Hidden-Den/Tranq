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
        "очищенный текст"
    ]

    private static let promptStructuralTokens: Set<String> = [
        "role", "task", "constraints", "context", "input", "output", "prompt",
        "instructions", "goal", "example", "steps", "rules", "format"
    ]

    /// Полная детерминированная валидация сгенерированного текста с учетом дифференцированных порогов стилей
    public static func validate(
        input: String,
        output: String,
        style: VoiceStyle,
        customTerms: Set<String> = []
    ) -> ValidationResult {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var sanitizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitizedOutput.isEmpty else {
            return .rejected(reason: "Пустой ответ модели")
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
        let isInputQuestion = trimmedInput.contains("?") || hasQuestionKeyword(trimmedInput)
        if isInputQuestion {
            // Для чистой мысли и делового стиля вопрос обязан оставаться вопросом
            if (style == .clean || style == .formal) && !sanitizedOutput.contains("?") {
                return .rejected(reason: "Модель ответила на вопрос вместо сохранения вопроса")
            }
            if style == .clean && outputWordCount > max(6, inputWordCount + 4) {
                return .rejected(reason: "Модель попыталась ответить на вопрос вместо его очистки")
            }
        }

        // 4. Проверка чисел (Strict Numbers Grounding)
        let inputNumbers = extractNumbers(from: trimmedInput)
        let outputNumbers = extractNumbers(from: sanitizedOutput, excludingListIndices: style == .bullets)

        // В стилях clean, formal и bullets все исходные числа должны сохраняться
        if style == .clean || style == .formal || style == .bullets {
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
        if style != .prompt {
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
        }

        // 6. Проверка структуры маркированного списка для стиля «Тезисы»
        if style == .bullets && inputWordCount > 5 {
            let bulletRegex = #"(?m)^\s*([-•*]|\d+[.)])\s+"#
            let hasBullets = sanitizedOutput.range(of: bulletRegex, options: .regularExpression) != nil
            if !hasBullets {
                return .rejected(reason: "Стиль тезисов требует наличия маркированного списка")
            }
        }

        // 7. Дифференцированная проверка длины по стилям
        let maxAllowedWords: Int
        switch style {
        case .clean:
            maxAllowedWords = max(10, Int(Double(inputWordCount) * 1.8))
        case .formal:
            maxAllowedWords = max(12, Int(Double(inputWordCount) * 2.0))
        case .bullets:
            maxAllowedWords = max(15, Int(Double(inputWordCount) * 2.2))
        case .prompt:
            maxAllowedWords = max(25, Int(Double(inputWordCount) * 3.0))
        }

        if outputWordCount > maxAllowedWords {
            return .rejected(reason: "Выход модели превысил допустимый объем генерации для выбранного стиля")
        }

        return .valid(sanitizedText: sanitizedOutput)
    }

    // MARK: - Вспомогательные методы

    private static func hasQuestionKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["как ", "почему ", "где ", "когда ", "сколько ", "зачем ", "что такое", "кто такой"]
        return keywords.contains { lower.hasPrefix($0) || lower.contains(" " + $0) }
    }

    private static func extractNumbers(from text: String, excludingListIndices: Bool = false) -> Set<String> {
        var processedText = text
        if excludingListIndices {
            // Удаляем структурные маркеры нумерации списков в начале строк (например: "1. ", "2) ")
            let listIndexPattern = #"(?m)^\s*\d+[.)]\s+"#
            processedText = processedText.replacingOccurrences(of: listIndexPattern, with: "", options: .regularExpression)
        }
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
