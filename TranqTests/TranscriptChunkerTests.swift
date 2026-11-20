import Testing
import Foundation
@testable import Tranq

/// Нарезка длинной речи на куски для очистки. Замер 20.11.2026: на 395 словах модель
/// перестала чистить и стала пересказывать, срезала половину и потеряла все числа,
/// а валидатор выбросил очистку трёх минут целиком. Кусок до 800 знаков модель чистит.
struct TranscriptChunkerTests {

    /// Предложение на нужное число знаков: слово «слово» повторено, в конце точка.
    private func sentence(_ index: Int, words: Int = 12) -> String {
        "Предложение \(index) " + Array(repeating: "слово", count: words).joined(separator: " ") + "."
    }

    private func text(sentences: Int, words: Int = 12) -> String {
        (1...sentences).map { sentence($0, words: words) }.joined(separator: " ")
    }

    /// Короткая диктовка не режется: один запрос, как и раньше, и повторы мыслей
    /// по всему тексту модель видит целиком.
    @Test func shortTranscriptStaysWhole() {
        let short = text(sentences: 5)
        #expect(short.count <= TranscriptChunker.threshold)
        #expect(TranscriptChunker.chunks(short) == [short])
    }

    /// Длинная режется по границам предложений, и ни один кусок не больше цели.
    @Test func longTranscriptSplitsOnSentenceBoundaries() {
        let long = text(sentences: 40)
        #expect(long.count > TranscriptChunker.threshold)
        let chunks = TranscriptChunker.chunks(long)
        #expect(chunks.count > 1)
        for chunk in chunks {
            // Последний кусок может принять крошечный хвост и выйти за цель на его размер
            #expect(chunk.count <= TranscriptChunker.target + TranscriptChunker.minimum)
            #expect(chunk.hasSuffix("."))
            #expect(chunk.hasPrefix("Предложение"))
        }
        for chunk in chunks.dropLast() {
            #expect(chunk.count <= TranscriptChunker.target)
        }
    }

    /// Нарезка не теряет и не добавляет ни знака: склейка через пробел даёт исходный текст.
    @Test func chunksLoseNoText() {
        let long = text(sentences: 40) + " Хвост без точки"
        #expect(TranscriptChunker.chunks(long).joined(separator: " ") == long)
    }

    /// Вопрос и восклицание тоже конец предложения.
    @Test func questionAndExclamationEndSentences() {
        let long = (1...40).map { i in
            "Фраза \(i) " + Array(repeating: "слово", count: 12).joined(separator: " ") + (i.isMultiple(of: 2) ? "?" : "!")
        }.joined(separator: " ")
        for chunk in TranscriptChunker.chunks(long) {
            #expect(chunk.hasSuffix("?") || chunk.hasSuffix("!"))
        }
    }

    /// Предложение длиннее цели не режется посередине: целое предложение важнее размера.
    @Test func oversizedSentenceStaysWhole() {
        let giant = "Начало " + Array(repeating: "слово", count: 300).joined(separator: " ") + "."
        let long = text(sentences: 10) + " " + giant + " " + text(sentences: 10)
        let chunks = TranscriptChunker.chunks(long)
        #expect(chunks.contains(giant))
        #expect(chunks.joined(separator: " ") == long)
    }

    /// Крошечный хвост вроде «Вот.» приклеивается к предыдущему куску: отдельный запрос
    /// на одно слово модель принимает за обращение к себе и отвечает.
    /// Перебираются длины, чтобы хвост хоть раз оказался один после полного куска.
    @Test func tinyTailJoinsThePreviousChunk() {
        for count in 30...45 {
            let long = text(sentences: count) + " Вот."
            let chunks = TranscriptChunker.chunks(long)
            #expect(chunks.last?.hasSuffix("Вот.") == true)
            #expect(chunks.allSatisfy { $0.count >= TranscriptChunker.minimum })
            #expect(chunks.joined(separator: " ") == long)
        }
    }

    /// Точка в числе или сокращении без пробела после неё не конец предложения.
    @Test func dotInsideNumberDoesNotSplit() {
        let long = (1...40).map { "Версия 3.5 вышла, шаг \($0) " + Array(repeating: "слово", count: 10).joined(separator: " ") + "." }
            .joined(separator: " ")
        for chunk in TranscriptChunker.chunks(long) {
            #expect(!chunk.hasPrefix("5 вышла"))
        }
    }
}
