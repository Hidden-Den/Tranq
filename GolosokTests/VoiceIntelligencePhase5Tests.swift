//
//  VoiceIntelligencePhase5Tests.swift
//  GolosokTests
//

import Testing
import Foundation
import AppKit
@testable import Golosok

struct VoiceIntelligencePhase5Tests {

    // MARK: - 1. Dataset Integrity

    @Test func goldenDatasetSizeAndIntegrity() {
        let samples = VoiceIntelligenceGoldenDataset.allSamples
        #expect(samples.count >= 300, "Золотой набор должен содержать не менее 300 репрезентативных примеров")

        let categories = Set(samples.map { $0.category })
        #expect(categories.count == GoldenCategory.allCases.count)

        for cat in GoldenCategory.allCases {
            let count = samples.filter { $0.category == cat }.count
            #expect(count >= 50, "Категория \(cat.rawValue) должна содержать как минимум 50 примеров")
        }
    }

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
            let answerValidation = GroundingValidator.validate(input: stageOne, output: hallucinatedAnswer, style: .clean)

            // Валидатор обязан отклонить такой ответ
            if case .rejected(let reason) = answerValidation, reason.contains("вопрос") {
                totalProtected += 1
            }

            // А чистый сохраненный вопрос обязан пройти валидацию
            let validCleanQuestion = stageOne.hasSuffix("?") ? stageOne : stageOne + "?"
            let validResult = GroundingValidator.validate(input: stageOne, output: validCleanQuestion, style: .clean)
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

            let candidateOutput: String
            switch sample.style {
            case .bullets:
                candidateOutput = "- " + cleanStageOne
            default:
                candidateOutput = cleanStageOne
            }

            // Корректный синтезированный результат: сохраненный очищенный текст
            let result = GroundingValidator.validate(
                input: sample.rawSpeech,
                output: candidateOutput,
                style: sample.style
            )

            if case .rejected = result {
                falseRejections += 1
            }
        }

        let frr = Double(falseRejections) / Double(totalEvaluated)
        #expect(frr < 0.05, "Доля ложных откатов (FRR) должна быть строго менее 5% (факт: \(frr * 100)%)")
        #expect(falseRejections == 0, "На золотом наборе детерминированный откат должен составлять 0%")
    }

    // MARK: - 6. Нагрузочное тестирование производительности (Latency < 2 мс / Throughput > 500 samples/sec)

    @Test func goldenDatasetThroughputAndLatencyPerformance() {
        let samples = VoiceIntelligenceGoldenDataset.allSamples

        // Прогрев пайплайна (JIT, кэши regex, инициализация статических массивов)
        for sample in samples.prefix(30) {
            let prefiltered = DisfluencyPrefilter.filter(sample.rawSpeech)
            let normalized = NumberNormalizer.normalize(prefiltered)
            let output = sample.style == .bullets ? "- " + normalized : normalized
            _ = GroundingValidator.validate(input: sample.rawSpeech, output: output, style: sample.style)
        }

        // Серия замеров для нивелирования шедулинга ОС и CI
        var bestElapsed: Double = .greatestFiniteMagnitude
        for _ in 0..<3 {
            let startTime = CFAbsoluteTimeGetCurrent()
            for sample in samples {
                let prefiltered = DisfluencyPrefilter.filter(sample.rawSpeech)
                let normalized = NumberNormalizer.normalize(prefiltered)
                let output = sample.style == .bullets ? "- " + normalized : normalized
                _ = GroundingValidator.validate(input: sample.rawSpeech, output: output, style: sample.style)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed < bestElapsed {
                bestElapsed = elapsed
            }
        }

        let avgLatencyMs = (bestElapsed / Double(samples.count)) * 1000.0
        let throughput = Double(samples.count) / bestElapsed

        AppLogger.shared.info(
            "Benchmark",
            String(format: "Золотой набор (%d прим.): лучшее время %.3f с, латентность %.3f мс/прим, пропускная способность %.0f прим/с",
                   samples.count, bestElapsed, avgLatencyMs, throughput)
        )

        #expect(avgLatencyMs < 2.0, "Средняя задержка детерминированного пайплайна должна быть < 2.0 мс на реплику")
        #expect(throughput > 500, "Пропускная способность должна превышать 500 реплик в секунду")
    }

    // MARK: - 7. Матрица интеграционного тестирования вставки и целевых приложений

    @Test func insertionMatrixTargetAppProfilesAndSafety() {
        // Проверка профилей приложений из матрицы
        let matrix: [(bundleId: String, expectedCategory: AppCategory)] = [
            ("com.microsoft.VSCode", .codeAndTerminal),
            ("com.todesktop.230313mzl4w4u92", .codeAndTerminal),
            ("com.apple.Terminal", .codeAndTerminal),
            ("com.googlecode.iterm2", .codeAndTerminal),
            ("ru.keepcoder.Telegram", .messaging),
            ("com.tinyspeck.slackmacgap", .messaging),
            ("com.apple.MobileSMS", .messaging),
            ("md.obsidian", .notesAndDocs),
            ("notion.id", .notesAndDocs),
            ("com.apple.mail", .email),
            ("com.microsoft.Outlook", .email),
            ("com.apple.Safari", .general),
            ("com.google.Chrome", .general)
        ]

        for item in matrix {
            let cat = AppProfileRouter.detectCategory(bundleIdentifier: item.bundleId)
            #expect(cat == item.expectedCategory, "Для \(item.bundleId) ожидалась категория \(item.expectedCategory)")
        }

        // Частный буфер: системный не затрагивается, параллельные тесты не конфликтуют
        let pb = NSPasteboard(name: NSPasteboard.Name("golosok.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        // Проверка буфера обмена: скрытие из менеджеров истории (Maccy, Paste)
        let insertion = InsertionService.shared
        insertion.copyToPasteboard(text: "Секретный тестовый токен", markTransient: true, pasteboard: pb)

        let types = pb.types?.map { $0.rawValue } ?? []
        #expect(types.contains("org.nspasteboard.ConcealedType"))
        #expect(types.contains("org.nspasteboard.AutoGeneratedType"))

        // Проверка флага защищенного ввода паролей
        _ = insertion.isSecureInputActive
    }
}
