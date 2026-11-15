//
//  VoiceIntelligencePhase4Tests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

struct VoiceIntelligencePhase4Tests {

    // MARK: - Differentiated Validator Thresholds

    @Test func cleanStyleStrictExtractionPreservesNumbersAndRejectsHallucinations() {
        let input = "Встреча назначена на 14 часов 30 минут"
        let validOutput = "Встреча в 14:30"
        let validResult = GroundingValidator.validate(input: input, output: validOutput, style: .clean)
        if case .valid(let text) = validResult {
            #expect(!text.isEmpty)
        } else {
            Issue.record("Должно быть валидно")
        }

        // Число 14 пропущено
        let missingNumOutput = "Встреча в 30 минут"
        let missingResult = GroundingValidator.validate(input: input, output: missingNumOutput, style: .clean)
        #expect(missingResult == .rejected(reason: "Пропущено исходное число 14"))

        // Придуманное число 99
        let hallucinatedNumOutput = "Встреча в 14:30 в кабинете 99"
        let hallucinatedResult = GroundingValidator.validate(input: input, output: hallucinatedNumOutput, style: .clean)
        #expect(hallucinatedResult == .rejected(reason: "Модель придумала число 99, отсутствовавшее в речи"))
    }

    @Test func cleanStylePreservesQuestionMark() {
        let input = "Мы успеем отправить релиз сегодня?"
        let invalidStatementOutput = "Мы успеем отправить релиз сегодня."
        let result = GroundingValidator.validate(input: input, output: invalidStatementOutput, style: .clean)
        #expect(result == .rejected(reason: "Модель ответила на вопрос вместо сохранения вопроса"))

        let validQuestionOutput = "Успеем ли мы отправить релиз сегодня?"
        let validResult = GroundingValidator.validate(input: input, output: validQuestionOutput, style: .clean)
        if case .valid(let text) = validResult {
            #expect(text.contains("?"))
        } else {
            Issue.record("Должно быть валидно для вопроса")
        }
    }

    @Test func subordinateClauseWithQuestionWordIsNotFalselyRejected() {
        let input = "Раз, 2, 3, 4, 5. Я иду искать. Нужно подумать про No8M и про Кубернейтс под тем, как эффективно сделать интеграцию с онлайн-университетом для No8?"
        let output = "Раз, 2, 3, 4, 5. Я иду искать. Нужно подумать о No8M и Кубернейтс, как эффективно интегрировать с онлайн-университетом для No8."
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        if case .valid(let text) = result {
            #expect(text.contains("No8M"))
            #expect(text.contains("2"))
        } else {
            Issue.record("Сложное предложение с 'как' не должно отклоняться как вопрос: \(result)")
        }
    }

    @Test func modelOutputWithPreambleSectionsIsSanitized() {
        let input = "Надо подумать о задаче"
        let output = """
        Исходный текст:
        Надо подумать о задаче

        Очищенный текст:
        Надо подумать о задаче.
        """
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        #expect(result == .valid(sanitizedText: "Надо подумать о задаче."))
    }

    @Test func formalStyleAllowsPoliteRestructuringWithinLimits() {
        let input = "Слушай давай созвонимся завтра в 10 утра обсудим контракт"
        let formalOutput = "Коллеги, предлагаю провести встречу завтра в 10 утра для обсуждения контракта."
        let result = GroundingValidator.validate(input: input, output: formalOutput, style: .formal)
        if case .valid(let text) = result {
            #expect(text.contains("10"))
        } else {
            Issue.record("Деловой стиль должен разрешать вежливую реструктуризацию")
        }

        // Если при перефразировании потеряли число
        let missingNumFormal = "Коллеги, предлагаю встретиться завтра утром для обсуждения контракта."
        let missingResult = GroundingValidator.validate(input: input, output: missingNumFormal, style: .formal)
        #expect(missingResult == .rejected(reason: "Пропущено исходное число 10"))
    }

    @Test func bulletsStyleEnforcesListMarkers() {
        let input = "Нужно купить молоко хлеб и сыр а также не забыть заехать на почту"
        let noBulletsOutput = "Нужно купить молоко, хлеб, сыр и заехать на почту."
        let rejectedResult = GroundingValidator.validate(input: input, output: noBulletsOutput, style: .bullets)
        #expect(rejectedResult == .rejected(reason: "Стиль тезисов требует наличия маркированного списка"))

        let validBulletsOutput = "- Купить продукты: молоко, хлеб, сыр\n- Заехать на почту"
        let validResult = GroundingValidator.validate(input: input, output: validBulletsOutput, style: .bullets)
        if case .valid(let text) = validResult {
            #expect(text.contains("- "))
        } else {
            Issue.record("Должно быть валидно для маркированного списка")
        }
    }

    @Test func promptStyleAllowsStructuralTokensAndExpandedLength() {
        let input = "Сделай парсер логов на питоне"
        let promptOutput = "Role: Senior Python Developer\nTask: Напиши парсер логов на Python с обработкой ошибок.\nConstraints: Используй стандартную библиотеку."
        let result = GroundingValidator.validate(input: input, output: promptOutput, style: .prompt)
        if case .valid(let text) = result {
            #expect(text.contains("Role:"))
            #expect(text.contains("Task:"))
        } else {
            Issue.record("Стиль промпта должен разрешать структурные токены")
        }
    }

    // MARK: - User Terms Dictionary

    @Test func userCustomTermsWhitelistedInValidator() {
        let input = "Мы используем эту систему в проде"
        let outputWithTerm = "Мы используем Golosok в проде"

        // Без добавления в словарь — отклоняется как неизвестный латинский термин
        let rejected = GroundingValidator.validate(input: input, output: outputWithTerm, style: .clean)
        #expect(rejected == .rejected(reason: "Новый термин Golosok не найден в речи или словаре"))

        // С добавлением в словарь — пропускается
        let allowed = GroundingValidator.validate(
            input: input,
            output: outputWithTerm,
            style: .clean,
            customTerms: ["Golosok"]
        )
        if case .valid(let text) = allowed {
            #expect(text.contains("Golosok"))
        } else {
            Issue.record("Пользовательский термин из словаря должен быть разрешен")
        }
    }

    @Test func userCustomTermsPersistenceInSettings() {
        let settings = VoiceIntelligenceSettings.shared
        let testTerm = "TestTerm\(Int.random(in: 1000...9999))"

        settings.addUserTerm(testTerm)
        #expect(settings.userTerms.contains(testTerm))

        // Повторное добавление не должно дублировать
        settings.addUserTerm(testTerm)
        let occurrences = settings.userTerms.filter { $0 == testTerm }.count
        #expect(occurrences == 1)

        settings.removeUserTerm(testTerm)
        #expect(!settings.userTerms.contains(testTerm))
    }

    // MARK: - AppProfileRouter Context Awareness

    @Test func appProfileRouterDetectsCorrectCategory() {
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "ru.keepcoder.Telegram") == .messaging)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "com.tinyspeck.slackmacgap") == .messaging)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "com.microsoft.VSCode") == .codeAndTerminal)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "com.apple.Terminal") == .codeAndTerminal)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "md.obsidian") == .notesAndDocs)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "notion.id") == .notesAndDocs)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "com.apple.mail") == .email)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: "com.random.unknown") == .general)
        #expect(AppProfileRouter.detectCategory(bundleIdentifier: nil) == .general)
    }

    @Test func appProfileGuidancePromptsAreNonEmptyForSpecializedApps() {
        #expect(!AppCategory.messaging.guidancePrompt.isEmpty)
        #expect(!AppCategory.codeAndTerminal.guidancePrompt.isEmpty)
        #expect(!AppCategory.notesAndDocs.guidancePrompt.isEmpty)
        #expect(!AppCategory.email.guidancePrompt.isEmpty)
        #expect(AppCategory.general.guidancePrompt.isEmpty)
    }
}
