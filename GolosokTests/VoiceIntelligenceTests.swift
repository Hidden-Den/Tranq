//
//  VoiceIntelligenceTests.swift
//  GolosokTests
//

import Testing
import Foundation
import AppKit
@testable import Golosok

struct VoiceIntelligenceTests {

    // MARK: - DisfluencyPrefilter

    @Test func prefilterRemovesRussianFillers() {
        let raw = "Эээ, мы должны нуу, ммм, отправить отчет сегодня."
        let cleaned = DisfluencyPrefilter.filter(raw)
        #expect(!cleaned.contains("Эээ"))
        #expect(!cleaned.contains("нуу"))
        #expect(!cleaned.contains("ммм"))
        #expect(cleaned.contains("отправить отчет"))
        #expect(cleaned.contains("сегодня"))
    }

    @Test func prefilterCollapsesRepeatedWordStutters() {
        let raw = "Я я думаю мы мы сможем сделать это это быстро."
        let cleaned = DisfluencyPrefilter.filter(raw)
        #expect(!cleaned.contains("Я я"))
        #expect(!cleaned.contains("мы мы"))
        #expect(!cleaned.contains("это это"))
        #expect(cleaned.contains("думаю"))
        #expect(cleaned.contains("сможем"))
    }

    @Test func prefilterPreservesNumbersAndDates() {
        let raw = "Встреча в 14:30, переведи 2500 рублей на счет 40817810."
        let cleaned = DisfluencyPrefilter.filter(raw)
        #expect(cleaned.contains("14:30"))
        #expect(cleaned.contains("2500"))
        #expect(cleaned.contains("40817810"))
    }

    // MARK: - GroundingValidator

    @Test func validatorPassesCleanOutput() {
        let input = "Мы должны отправить отчет в пятницу до 18:00."
        let output = "Отправить отчет в пятницу до 18:00."
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        switch result {
        case .valid(let text):
            #expect(text == "Отправить отчет в пятницу до 18:00.")
        case .rejected(let reason):
            Issue.record("Expected valid, got rejected with: \(reason)")
        }
    }

    @Test func validatorRejectsHallucinatedNumbers() {
        let input = "Стоимость подписки составляет 500 рублей в месяц."
        let output = "Стоимость подписки составляет 999 рублей в месяц."
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        switch result {
        case .valid:
            Issue.record("Expected rejection for hallucinated number")
        case .rejected(let reason):
            #expect(reason.contains("число"))
        }
    }

    @Test func validatorRejectsHallucinatedLatinWords() {
        let input = "Нам нужно обновить серверную часть приложения."
        let output = "Нам нужно обновить серверную часть с использованием Kubernetes и Docker."
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        switch result {
        case .valid:
            Issue.record("Expected rejection for hallucinated Latin keywords")
        case .rejected(let reason):
            #expect(reason.contains("латинский") || reason.contains("термин"))
        }
    }

    @Test func validatorRejectsChatbotConversationalPreambles() {
        let input = "Купи молоко и хлеб."
        let output = "Конечно! Вот отредактированный текст: Купи молоко и хлеб."
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        switch result {
        case .valid:
            Issue.record("Expected rejection for conversational preamble")
        case .rejected(let reason):
            #expect(reason.contains("префикс") || reason.contains("вводные"))
        }
    }

    @Test func validatorRejectsAnswersToQuestionsInCleanStyle() {
        let input = "Сколько сейчас времени в Токио?"
        let output = "В Токио сейчас 9 часов вечера."
        let result = GroundingValidator.validate(input: input, output: output, style: .clean)
        switch result {
        case .valid:
            Issue.record("Expected rejection because question was turned into an answer")
        case .rejected(let reason):
            #expect(reason.contains("вопрос"))
        }
    }

    // MARK: - ThoughtSynthesizer Thinking Tags

    @Test func stripThinkingTagsRemovesCompleteTags() {
        let raw = "<think>Пользователь просит убрать заминки. Уберем эээ.</think>Встретимся завтра в офисе."
        let cleaned = ThoughtSynthesizer.stripThinkingTags(from: raw)
        #expect(cleaned == "Встретимся завтра в офисе.")
    }

    @Test func stripThinkingTagsRemovesUnclosedTags() {
        let raw = "Текст до тега.<think>Рассуждения, которые оборвались..."
        let cleaned = ThoughtSynthesizer.stripThinkingTags(from: raw)
        #expect(cleaned == "Текст до тега.")
    }

    // MARK: - InsertionService & Pasteboard

    @Test func copyToPasteboardSetsTransientTypes() {
        let pb = NSPasteboard.general
        let oldString = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let old = oldString {
                pb.setString(old, forType: .string)
            }
        }

        let service = InsertionService.shared
        let testString = "Test transient paste"
        service.copyToPasteboard(text: testString, markTransient: true)
        
        let stringVal = pb.string(forType: .string)
        #expect(stringVal == testString)
        
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        
        #expect(pb.string(forType: transientType) == "1")
        #expect(pb.string(forType: autoGeneratedType) == "1")
        #expect(pb.string(forType: concealedType) == "1")
    }

    // MARK: - VoiceIntelligenceSettings

    @Test func defaultSettingsAreCorrect() {
        let settings = VoiceIntelligenceSettings.shared
        #expect(settings.mode == .smart)
        #expect(settings.style == .clean)
        #expect(settings.engine == .openRouter)
        #expect(settings.adaptiveTimeoutSeconds == 3.0)
        #expect(VoiceInputMode.smart.title == "Умная речь")
        #expect(VoiceStyle.clean.title == "Чистая мысль")
        #expect(VoiceEngine.airGapped.title == "Air-Gapped на устройстве")
    }
}
