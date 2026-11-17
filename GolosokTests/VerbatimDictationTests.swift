//
//  VerbatimDictationTests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

/// Диктовка почти дословно: модель только убирает мусор и не пересказывает мысль.
struct VerbatimDictationTests {

    // MARK: - Защита от пересказа

    @Test func cleanStyleRejectsParaphrase() {
        let input = "Нужно короче собрать RAG-систему на базе документов отдела и проверить качество ответов."
        let output = "Требуется разработать систему поиска по корпоративной базе знаний и оценить её эффективность."
        let result = GroundingValidator.validate(input: input, output: output, level: .clean)
        guard case .rejected = result else {
            Issue.record("Пересказ должен отклоняться, получено: \(result)")
            return
        }
    }

    @Test func cleanStyleAcceptsFillerRemoval() {
        let input = "Ну короче нужно как бы собрать RAG-систему на базе документов отдела."
        let output = "Нужно собрать RAG-систему на базе документов отдела."
        #expect(GroundingValidator.validate(input: input, output: output, level: .clean) == .valid(sanitizedText: output))
    }

    @Test func cleanStyleAcceptsSelfCorrection() {
        let input = "Давай встретимся в понедельник, ой, во вторник."
        let output = "Давай встретимся во вторник."
        #expect(GroundingValidator.validate(input: input, output: output, level: .clean) == .valid(sanitizedText: output))
    }

    @Test func cleanStyleAllowsOneGrammarFix() {
        let input = "Я думаю что мы успеем сделать отчет к пятнице если начнем сегодня."
        let output = "Я думаю, что мы успеем сделать отчёт к пятнице, если начнём сегодня."
        #expect(GroundingValidator.validate(input: input, output: output, level: .clean) == .valid(sanitizedText: output))
    }

    @Test func otherStylesMayRephrase() {
        let input = "Нужно собрать систему на базе документов отдела и проверить качество ответов."
        let output = "Прошу собрать систему по документам отдела и оценить качество ответов."
        #expect(GroundingValidator.rewriteViolation(input: input, output: output) != nil)
        #expect(GroundingValidator.validate(input: input, output: output, level: .rewrite(tone: "деловой")) == .valid(sanitizedText: output))
    }

    @Test func dictionaryTermsDoNotCountAsNovel() {
        let input = "Подключи ламу через олламу на сервере."
        let output = "Подключи Llama через Ollama на сервере."
        #expect(GroundingValidator.rewriteViolation(input: input, output: output, customTerms: ["Llama", "Ollama"]) == nil)
    }

    // MARK: - Пропуск модели

    @Test func cleanTextNeedsNoModel() {
        #expect(!DisfluencyPrefilter.needsCleanup("Собери RAG-систему на базе документов отдела и проверь ответы."))
        #expect(!DisfluencyPrefilter.needsCleanup("Это ты отлично придумал, давай так и сделаем."))
    }

    @Test func fillersAndCorrectionsNeedModel() {
        #expect(DisfluencyPrefilter.needsCleanup("Короче, надо собрать отчёт."))
        #expect(DisfluencyPrefilter.needsCleanup("Надо как бы собрать отчёт."))
        #expect(DisfluencyPrefilter.needsCleanup("Встреча в понедельник, ой, во вторник."))
        #expect(DisfluencyPrefilter.needsCleanup("Встреча в понедельник, то есть во вторник."))
        #expect(DisfluencyPrefilter.needsCleanup("Давай пое- поедем завтра."))
    }

    // MARK: - Словарь

    @Test func ragVariantsAreInAIPack() throws {
        let packs = DictionaryStore.loadPacks(from: .main)
        let ai = try #require(packs.first { $0.id == "ai" })
        let rag = try #require(ai.entries.first { $0.spelling == "RAG" })
        #expect(rag.variants[.ru]?.contains("эр эй джи") == true)
        let system = try #require(ai.entries.first { $0.spelling == "RAG-система" })
        #expect(system.variants[.ru]?.contains("рак система") == true)
    }
}
