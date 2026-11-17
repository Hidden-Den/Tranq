//
//  VoiceIntelligencePhase5Tests.swift
//  TranqTests
//

import Testing
import Foundation
import AppKit
@testable import Tranq

struct VoiceIntelligencePhase5Tests {

    // MARK: - 2. Метрика очистки заиканий и звуковых паразитов (Disfluency Reduction: 100%)

    @Test func goldenDatasetDisfluencyReductionMetric() {
        let samples = VoiceIntelligenceGoldenDataset.allSamples.filter {
            $0.category == .fillers || $0.category == .stutters
        }
        #expect(!samples.isEmpty)

        var totalChecked = 0
        var totalCleaned = 0

        for sample in samples {
            totalChecked += 1
            let filtered = DisfluencyPrefilter.filter(sample.rawSpeech)

            // Проверяем, что известные паразиты удалены
            var hasRemainingFiller = false
            for filler in sample.forbiddenFillers {
                if filtered.lowercased().contains(filler.lowercased()) {
                    hasRemainingFiller = true
                    break
                }
            }

            // Проверяем, что заикания схлопнуты (нет двух одинаковых подряд слов)
            let hasStutter = filtered.range(of: #"(?i)\b([a-zа-яё]+)\s+\1\b"#, options: .regularExpression) != nil

            if !hasRemainingFiller && !hasStutter {
                totalCleaned += 1
            }
        }

        let cleanRate = Double(totalCleaned) / Double(totalChecked)
        #expect(cleanRate == 1.0, "Доля успешной очистки паузных заполнителей и заиканий должна быть 100% (факт: \(cleanRate * 100)%)")
    }

    // MARK: - 3. Метрика сохранности чисел и дат (100% Retention)

    @Test func goldenDatasetNumberAndDatePreservationMetric() {
        let samples = VoiceIntelligenceGoldenDataset.allSamples.filter {
            $0.category == .numbersAndDates && !$0.expectedNumbers.isEmpty
        }
        #expect(!samples.isEmpty)

        var totalExpectedCount = 0
        var totalPreservedCount = 0

        for sample in samples {
            let stageOne = NumberNormalizer.normalize(sample.rawSpeech)
            for expected in sample.expectedNumbers {
                totalExpectedCount += 1
                if stageOne.contains(expected) {
                    totalPreservedCount += 1
                }
            }
        }

        let retentionRate = Double(totalPreservedCount) / Double(totalExpectedCount)
        #expect(retentionRate == 1.0, "Сохранность чисел и дат на этапе 1 должна быть 100% (факт: \(retentionRate * 100)%)")
    }

    // MARK: - 4. Метрика защиты вопросительной формы (0% ответов на вопросы)

    @Test func goldenDatasetQuestionIntegrityMetric() {
        let questionSamples = VoiceIntelligenceGoldenDataset.allSamples.filter { $0.isQuestion }
        #expect(!questionSamples.isEmpty)

        var totalQuestions = 0
        var totalProtected = 0

        for sample in questionSamples {
            totalQuestions += 1
            let stageOne = DisfluencyPrefilter.filter(sample.rawSpeech)

            // Симулируем попытку модели ответить на вопрос
            let hallucinatedAnswer = "Ответ на ваш вопрос: это произойдет скоро."
            let answerValidation = GroundingValidator.validate(input: stageOne, output: hallucinatedAnswer, level: .clean)

            // Валидатор обязан отклонить такой ответ
            if case .rejected(let reason) = answerValidation, reason.contains("вопрос") {
                totalProtected += 1
            }

            // А чистый сохраненный вопрос обязан пройти валидацию
            let validCleanQuestion = stageOne.hasSuffix("?") ? stageOne : stageOne + "?"
            let validResult = GroundingValidator.validate(input: stageOne, output: validCleanQuestion, level: .clean)
            if case .valid = validResult {
                // Успешный пропуск
            } else {
                Issue.record("Валидный вопрос \(stageOne) не должен отклоняться")
            }
        }

        let protectionRate = Double(totalProtected) / Double(totalQuestions)
        #expect(protectionRate == 1.0, "Защита вопросов от превращения в ответы должна быть 100% (0% ответов на вопросы)")
    }

    // MARK: - 5. Доля ложных откатов валидатора (False Rejection Rate < 5%)

    @Test func goldenDatasetFalseRejectionRateMetric() {
        let samples = VoiceIntelligenceGoldenDataset.allSamples
        var totalEvaluated = 0
        var falseRejections = 0

        for sample in samples {
            totalEvaluated += 1
            let cleanStageOne = DisfluencyPrefilter.filter(sample.rawSpeech)
            // Проверка получает текст после префильтра: звуки вроде «uh» из речи к ней не доходят

            let candidateOutput = cleanStageOne

            // Корректный синтезированный результат: сохраненный очищенный текст
            let result = GroundingValidator.validate(
                input: cleanStageOne,
                output: candidateOutput,
                level: sample.level
            )

            if case .rejected = result {
                falseRejections += 1
            }
        }

        let frr = Double(falseRejections) / Double(totalEvaluated)
        #expect(frr < 0.05, "Доля ложных откатов (FRR) должна быть строго менее 5% (факт: \(frr * 100)%)")
        #expect(falseRejections == 0, "На золотом наборе детерминированный откат должен составлять 0%")
    }

}
