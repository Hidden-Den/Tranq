//
//  VoiceIntelligencePhase4Tests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

extension SharedSettingsSuites {
    struct VoiceIntelligencePhase4Tests {

        // MARK: - Differentiated Validator Thresholds

        @Test func cleanStyleStrictExtractionPreservesNumbersAndRejectsHallucinations() {
            let input = "Встреча назначена на 14 часов 30 минут"
            let validOutput = "Встреча в 14:30"
            let validResult = GroundingValidator.validate(input: input, output: validOutput, level: .clean)
            if case .valid(let text) = validResult {
                #expect(!text.isEmpty)
            } else {
                Issue.record("Должно быть валидно")
            }

            // Число 14 пропущено
            let missingNumOutput = "Встреча в 30 минут"
            let missingResult = GroundingValidator.validate(input: input, output: missingNumOutput, level: .clean)
            #expect(missingResult == .rejected(reason: "Пропущено исходное число 14"))

            // Придуманное число 99
            let hallucinatedNumOutput = "Встреча в 14:30 в кабинете 99"
            let hallucinatedResult = GroundingValidator.validate(input: input, output: hallucinatedNumOutput, level: .clean)
            #expect(hallucinatedResult == .rejected(reason: "Модель придумала число 99, отсутствовавшее в речи"))
        }

        @Test func cleanStylePreservesQuestionMark() {
            let input = "Мы успеем отправить релиз сегодня?"
            let invalidStatementOutput = "Мы успеем отправить релиз сегодня."
            let result = GroundingValidator.validate(input: input, output: invalidStatementOutput, level: .clean)
            #expect(result == .rejected(reason: "Модель ответила на вопрос вместо сохранения вопроса"))

            let validQuestionOutput = "Успеем ли мы отправить релиз сегодня?"
            let validResult = GroundingValidator.validate(input: input, output: validQuestionOutput, level: .clean)
            if case .valid(let text) = validResult {
                #expect(text.contains("?"))
            } else {
                Issue.record("Должно быть валидно для вопроса")
            }
        }

        @Test func subordinateClauseWithQuestionWordIsNotFalselyRejected() {
            let input = "Раз, 2, 3, 4, 5. Я иду искать. Нужно подумать про No8M и про Кубернейтс под тем, как эффективно сделать интеграцию с онлайн-университетом для No8?"
            let output = "Раз, 2, 3, 4, 5. Я иду искать. Нужно подумать о No8M и Кубернейтс, как эффективно интегрировать с онлайн-университетом для No8."
            let result = GroundingValidator.validate(input: input, output: output, level: .clean)
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
            let result = GroundingValidator.validate(input: input, output: output, level: .clean)
            #expect(result == .valid(sanitizedText: "Надо подумать о задаче."))
        }

        @Test func formalStyleAllowsPoliteRestructuringWithinLimits() {
            let input = "Слушай давай созвонимся завтра в 10 утра обсудим контракт"
            let formalOutput = "Коллеги, предлагаю провести встречу завтра в 10 утра для обсуждения контракта."
            let result = GroundingValidator.validate(input: input, output: formalOutput, level: .rewrite(tone: "деловой"))
            if case .valid(let text) = result {
                #expect(text.contains("10"))
            } else {
                Issue.record("Деловой стиль должен разрешать вежливую реструктуризацию")
            }

            // Если при перефразировании потеряли число
            let missingNumFormal = "Коллеги, предлагаю встретиться завтра утром для обсуждения контракта."
            let missingResult = GroundingValidator.validate(input: input, output: missingNumFormal, level: .rewrite(tone: "деловой"))
            #expect(missingResult == .rejected(reason: "Пропущено исходное число 10"))
        }

        // MARK: - User Terms Dictionary

        @Test func userCustomTermsWhitelistedInValidator() {
            let input = "Мы используем эту систему в проде"
            let outputWithTerm = "Мы используем Tranq в проде"

            // Без добавления в словарь — отклоняется как неизвестный латинский термин
            let rejected = GroundingValidator.validate(input: input, output: outputWithTerm, level: .clean)
            #expect(rejected == .rejected(reason: "Новый термин Tranq не найден в речи или словаре"))

            // С добавлением в словарь — пропускается
            let allowed = GroundingValidator.validate(
                input: input,
                output: outputWithTerm,
                level: .clean,
                customTerms: ["Tranq"]
            )
            if case .valid(let text) = allowed {
                #expect(text.contains("Tranq"))
            } else {
                Issue.record("Пользовательский термин из словаря должен быть разрешен")
            }
        }
    }
}
