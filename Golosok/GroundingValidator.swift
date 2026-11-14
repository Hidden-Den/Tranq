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

    /// Полная детерминированная валидация сгенерированного текста
    public static func validate(input: String, output: String, style: VoiceStyle) -> ValidationResult {
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

        // 3. Проверка длины: выход не должен быть в 2.5 раза длиннее входа
        let inputWordCount = trimmedInput.split(whereSeparator: { $0.isWhitespace }).count
        let outputWordCount = sanitizedOutput.split(whereSeparator: { $0.isWhitespace }).count
        if outputWordCount > max(8, Int(Double(inputWordCount) * 2.2)) {
            return .rejected(reason: "Выход модели превысил допустимый объем генерации")
        }

        // 4. Проверка вопросов (защита от чат-бот ответов)
        let isInputQuestion = trimmedInput.contains("?") || hasQuestionKeyword(trimmedInput)
        if isInputQuestion {
            // Если на входе был вопрос, в чистом стиле выход должен остаться вопросом
            if style == .clean && trimmedInput.hasSuffix("?") && !sanitizedOutput.contains("?") {
                return .rejected(reason: "Модель ответила на вопрос вместо сохранения вопроса")
            }
            if outputWordCount > max(6, inputWordCount + 4) {
                return .rejected(reason: "Модель попыталась ответить на вопрос вместо его очистки")
            }
        }

        // 5. Проверка чисел (Strict Numbers Grounding)
        let inputNumbers = extractNumbers(from: trimmedInput)
        let outputNumbers = extractNumbers(from: sanitizedOutput)

        // В чистом стиле все надиктованные числа должны сохраняться
        if style == .clean {
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

        // 6. Проверка латиницы и технических терминов
        let inputLatin = extractLatinTokens(from: trimmedInput)
        let outputLatin = extractLatinTokens(from: sanitizedOutput)
        for token in outputLatin {
            if !inputLatin.contains(token.lowercased()) {
                // Если стиль не Prompt и токена не было вовсе — проверяем строгость
                if style != .prompt {
                    return .rejected(reason: "Новый латинский термин \(token) не найден в речи")
                }
            }
        }

        return .valid(sanitizedText: sanitizedOutput)
    }

    // MARK: - Вспомогательные методы

    private static func hasQuestionKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["как ", "почему ", "где ", "когда ", "сколько ", "зачем ", "что такое", "кто такой"]
        return keywords.contains { lower.hasPrefix($0) || lower.contains(" " + $0) }
    }

    private static func extractNumbers(from text: String) -> Set<String> {
        let pattern = #"(?<![\d.,])\d+(?:[.,]\d+)?(?![\d.,])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
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
            tokens.insert(nsString.substring(with: m.range).lowercased())
        }
        return tokens
    }
}
