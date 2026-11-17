//
//  VoiceIntelligencePhase2Tests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

struct VoiceIntelligencePhase2Tests {

    // MARK: - NumberNormalizer

    @Test func normalizerConvertsSimpleNumbers() {
        let input = "У меня есть два яблока и пять груш."
        let normalized = NumberNormalizer.normalize(input)
        #expect(normalized.contains("2"))
        #expect(normalized.contains("5"))
        #expect(!normalized.contains("два"))
        #expect(!normalized.contains("пять"))
    }

    @Test func normalizerConvertsTeensAndTens() {
        let input = "В классе одиннадцать мальчиков и двадцать девочек."
        let normalized = NumberNormalizer.normalize(input)
        #expect(normalized.contains("11"))
        #expect(normalized.contains("20"))
    }

    @Test func normalizerConvertsCompoundNumbers() {
        let input = "Переведи три тысячи пятьсот двадцать пять рублей."
        let normalized = NumberNormalizer.normalize(input)
        #expect(normalized.contains("3525"))
        #expect(!normalized.contains("три тысячи"))
        #expect(!normalized.contains("пятьсот"))
    }

    @Test func normalizerConvertsDatesWithMonthNames() {
        let input = "Встреча назначена на двадцать шестого мая в пятнадцать тридцать."
        let normalized = NumberNormalizer.normalize(input)
        #expect(normalized.contains("26 мая"))
        #expect(normalized.contains("15:30") || normalized.contains("15 30"))
    }

    @Test func normalizerKeepsOrdinalsOutsideDatesAsWords() {
        #expect(NumberNormalizer.normalize("Я бы взял вторую кандидатку.") == "Я бы взял вторую кандидатку.")
        #expect(NumberNormalizer.normalize("Не работает уже третий день.") == "Не работает уже третий день.")
        #expect(NumberNormalizer.normalize("Дедлайн первое марта.").contains("1 марта"))
    }

    @Test func normalizerKeepsScaleAfterFractionWord() {
        #expect(NumberNormalizer.normalize("Бюджет полтора миллиона.") == "Бюджет полтора миллиона.")
        #expect(NumberNormalizer.normalize("Бюджет два миллиона.").contains("2000000"))
    }

    @Test func normalizerPreservesExistingDigits() {
        let input = "Счет номер 40817810 и сумма 500 рублей."
        let normalized = NumberNormalizer.normalize(input)
        #expect(normalized.contains("40817810"))
        #expect(normalized.contains("500"))
    }

    @Test func normalizerIntegratesWithGroundingValidator() {
        let rawSpeech = "Отправь двадцать пять документов на почту."
        let normalized = NumberNormalizer.normalize(rawSpeech)
        // Модель на выходе дала текст с цифрой 25
        let modelOutput = "Отправь 25 документов на почту."
        let result = GroundingValidator.validate(input: normalized, output: modelOutput, level: .clean)
        switch result {
        case .valid(let text):
            #expect(text == "Отправь 25 документов на почту.")
        case .rejected(let reason):
            Issue.record("Expected valid because normalized input has 25, got rejected: \(reason)")
        }
    }

    // MARK: - Streaming Think Tag Parser

    @Test func streamingTagStripperHandlesChunks() {
        var stripper = StreamingThinkTagStripper()
        var emitted: [String] = []

        let chunks = [
            "Привет, ",
            "<think>",
            "пользователь поздоровался, ",
            "надо ответить вежливо",
            "</think>",
            "как дела?"
        ]

        for chunk in chunks {
            if let text = stripper.feed(chunk) {
                emitted.append(text)
            }
        }
        if let remaining = stripper.finish() {
            emitted.append(remaining)
        }

        let result = emitted.joined()
        #expect(result == "Привет, как дела?")
    }

    @Test func streamingTagStripperHandlesNoThinkTags() {
        var stripper = StreamingThinkTagStripper()
        var emitted: [String] = []

        let chunks = ["Это ", "обычный ", "поток ", "слов."]
        for chunk in chunks {
            if let text = stripper.feed(chunk) {
                emitted.append(text)
            }
        }
        if let remaining = stripper.finish() {
            emitted.append(remaining)
        }

        let result = emitted.joined()
        #expect(result == "Это обычный поток слов.")
    }
}
