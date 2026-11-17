//
//  GolosokTests.swift
//  GolosokTests
//
//  Created by kozak_dev on 26.07.2026.
//

import Testing
import Foundation
import AppKit
@testable import Golosok

struct GolosokTests {

    // MARK: - TextFormatter

    @Test func emptyTextStaysEmpty() {
        #expect(TextFormatter.formatIntoParagraphs("") == "")
    }

    @Test func plainTextWithoutPunctuationIsUntouched() {
        #expect(TextFormatter.formatIntoParagraphs("просто строка") == "просто строка")
    }

    @Test func sentencesJoinIntoSingleParagraph() {
        let result = TextFormatter.formatIntoParagraphs("Привет. Как дела? Хорошо!")
        #expect(result == "Привет. Как дела? Хорошо!")
    }

    @Test func paragraphBreaksAfterThreeSentences() {
        let result = TextFormatter.formatIntoParagraphs("Первое. Второе. Третье. Четвертое.")
        #expect(result == "Первое. Второе. Третье.\n\nЧетвертое.")
    }

    @Test func dialogueLinesGetOwnParagraphs() {
        let result = TextFormatter.formatIntoParagraphs("— Привет. — Здравствуй!")
        #expect(result == "— Привет.\n\n— Здравствуй!")
    }

    // MARK: - Synced word alignment

    private func timedWords(_ texts: [String]) -> [TimedWord] {
        texts.enumerated().map { TimedWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 1) }
    }

    private func wordRanges(_ text: String, _ words: [TimedWord]) -> [NSRange] {
        SyncedTextView.Coordinator(onSeek: { _ in }).wordRanges(text: text, words: words)
    }

    @Test func exactWordsProducePositionalRanges() {
        let text = "Привет! Это проверка."
        let words = timedWords(["Привет!", "Это", "проверка."])
        let ranges = wordRanges(text, words)
        #expect(ranges.count == 3)
        #expect(ranges[0] == NSRange(location: 0, length: 7))
        #expect(ranges[1] == NSRange(location: 8, length: 3))
        #expect(ranges[2] == NSRange(location: 12, length: 9))
    }

    @Test func caseInsensitiveTokensStillAlign() {
        let text = "Привет мир"
        let words = timedWords(["привет", "мир"])
        let ranges = wordRanges(text, words)
        #expect(ranges[0].location == 0)
        #expect(ranges[1].location == 7)
    }

    @Test func extraTextWordIsSkippedByAlignment() {
        let text = "один два три"
        let words = timedWords(["один", "три"])
        let ranges = wordRanges(text, words)
        #expect(ranges[0] == NSRange(location: 0, length: 4))
        #expect(ranges[1] == NSRange(location: 9, length: 3))
    }

    @Test func missingWordBecomesNotFoundPlaceholder() {
        let text = "привет мир"
        let words = timedWords(["привет", "неттакого", "мир"])
        let ranges = wordRanges(text, words)
        #expect(ranges.count == 3)
        #expect(ranges[0] == NSRange(location: 0, length: 6))
        #expect(ranges[1].location == NSNotFound)
        #expect(ranges[2] == NSRange(location: 7, length: 3))
    }

    @Test func punctuationAttachedToTokensStillAligns() {
        let text = "Числа 1, 2, 3 и всё."
        let words = timedWords(["Числа", "1,", "2,", "3", "и", "всё."])
        let ranges = wordRanges(text, words)
        #expect(ranges.allSatisfy { $0.location != NSNotFound })
        #expect(ranges.count == 6)
    }

    @Test func emptyWordsProduceNoRanges() {
        #expect(wordRanges("", timedWords(["слово"])).isEmpty)
        #expect(wordRanges("текст", []).isEmpty)
    }

    // MARK: - Whisper timing interpolation

    @Test func interpolateTimingsSpreadsAcrossRange() {
        let words = timedWords(["а", "б", "в"])
        let result = WordTimings.interpolate(words, from: 1.0, to: 4.0)
        #expect(result.count == 3)
        #expect(result[0].start == 1.0)
        #expect(result[2].end <= 4.001)
        for i in 1..<result.count {
            #expect(result[i].start >= result[i - 1].end)
            #expect(result[i].end > result[i].start)
        }
    }

    @Test func interpolateTimingsPreservesOrder() {
        let words = timedWords(["один", "два", "три"])
        let result = WordTimings.interpolate(words, from: 0, to: 3.0)
        #expect(result.map(\.text) == ["один", "два", "три"])
        #expect(result[0].start == 0)
        #expect(result.last?.end == 3.0)
    }

    // MARK: - Whisper ms→s migration

    @Test func millisecondTimingsAreConvertedToSeconds() {
        let words = [TimedWord(text: "Привет", start: 0, end: 7650.5), TimedWord(text: "мир", start: 7650.5, end: 8000)]
        let result = WordTimings.normalized(words, duration: 7.6)
        #expect(result[0].end == 7.6505)
        #expect(result[1].start == 7.6505)
    }

    @Test func secondTimingsStayUntouched() {
        let words = [TimedWord(text: "Так,", start: 0.76, end: 1.04), TimedWord(text: "звук", start: 1.2, end: 1.48)]
        let result = WordTimings.normalized(words, duration: 6.6)
        #expect(result == words)
    }

    // MARK: - Version comparison (update check)

    @Test func versionComparisonHandlesSuffixes() {
        #expect(UpdateService.compareVersions("v1.12.2", "1.12.1") == .orderedDescending)
        #expect(UpdateService.compareVersions("1.10.0", "1.12.1") == .orderedAscending)
        #expect(UpdateService.compareVersions("1.12.1", "1.12.1") == .orderedSame)
        #expect(UpdateService.compareVersions("2.0", "1.99.9") == .orderedDescending)
        #expect(UpdateService.compareVersions("1.0", "1.0.1") == .orderedAscending)
    }

    // MARK: - Transcript search (⌘ + F)

    private func tw(_ texts: [String]) -> [TimedWord] {
        texts.enumerated().map { TimedWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 1) }
    }

    @Test func transcriptSearchMatchesWordsCaseInsensitive() {
        let words = tw(["Привет", "мир", "ПРИВЕТ", "дом"])
        let indices = TranscriptSearch.matchedWordIndices(in: words, query: "привет")
        #expect(indices == [0, 2])
    }

    @Test func transcriptSearchMatchesBySubstringWithinWord() {
        let words = tw(["прилетел", "привет", "ушёл"])
        let indices = TranscriptSearch.matchedWordIndices(in: words, query: "при")
        #expect(indices == [0, 1])
    }

    @Test func transcriptSearchIsDiacriticInsensitive() {
        let words = tw(["еле", "ёлка", "ёж"])
        let indices = TranscriptSearch.matchedWordIndices(in: words, query: "е")
        #expect(indices == [0, 1, 2])
    }

    @Test func transcriptSearchEmptyQueryReturnsNoMatches() {
        let words = tw(["слово", "текст"])
        #expect(TranscriptSearch.matchedWordIndices(in: words, query: "").isEmpty)
    }

    @Test func transcriptSearchNoMatchReturnsEmpty() {
        let words = tw(["кот", "пёс"])
        #expect(TranscriptSearch.matchedWordIndices(in: words, query: "слон").isEmpty)
    }

    @Test func transcriptSearchRangesFindAllOccurrences() {
        let text = "кот пошёл к коту за котёнком"
        let ranges = TranscriptSearch.matchedRanges(in: text, query: "кот")
        #expect(ranges.count == 3)
        let ns = text as NSString
        for r in ranges {
            #expect(ns.substring(with: r).lowercased().contains("кот"))
        }
    }

    @Test func transcriptSearchRangesAreCaseInsensitive() {
        let text = "Тест тест ТЕСТ"
        let ranges = TranscriptSearch.matchedRanges(in: text, query: "тест")
        #expect(ranges.count == 3)
    }

    @Test func transcriptSearchRangesEmptyQueryReturnsNothing() {
        #expect(TranscriptSearch.matchedRanges(in: "текст", query: "").isEmpty)
    }

    @Test func transcriptSearchRangesNoMatchReturnsEmpty() {
        #expect(TranscriptSearch.matchedRanges(in: "привет мир", query: "слон").isEmpty)
    }
}

// MARK: - История и модели

@Suite(.serialized)
@MainActor
struct HistoryAndModelTests {

    /// История во временной папке: тесты не трогают настоящие заметки пользователя.
    static func makeIsolatedHistoryStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("golosok-tests-\(UUID().uuidString)", isDirectory: true)
        return HistoryStore(directory: dir)
    }

    // MARK: - ModelStore

    @Test func gigaAMModelConfiguration() {
        let giga = RecognitionModel.russianGigaAM
        #expect(giga.id == "ru_giga")
        #expect(giga.systemName == "GigaAM")
        #expect(giga.languageCode == "ru")
        #expect(giga.isBundled == true)
        #expect(giga.fileName == "gigaam")
    }

    @Test func modelStoreCatalogContainsGigaAM() {
        let store = ModelStore.shared
        let model = store.model(named: "ru_giga")
        #expect(model != nil)
        #expect(model?.systemName == "GigaAM")
    }
}

// MARK: - Window and Dock / MenuBar settings

struct WindowAndDockSettingsTests {
    @Test @MainActor func hideInDockPersistence() {
        let store = AppPreferences.shared
        let originalHideInDock = store.hideInDock
        defer {
            store.hideInDock = originalHideInDock
        }

        store.hideInDock = true
        #expect(store.hideInDock == true)
        #expect(AppEnvironment.defaults.bool(forKey: "hideInDock") == true)

        store.hideInDock = false
        #expect(store.hideInDock == false)
        #expect(AppEnvironment.defaults.bool(forKey: "hideInDock") == false)
    }

    @Test @MainActor func mainWindowControllerInterception() {
        let controller = MainWindowController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        controller.register(window: window)
        #expect(controller.mainWindow === window)
        #expect(window.isReleasedWhenClosed == false)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.isMovableByWindowBackground == true)

        window.orderFront(nil)
        #expect(window.isVisible)

        // windowShouldClose should intercept, order out, and return false
        let shouldClose = controller.windowShouldClose(window)
        #expect(shouldClose == false)
        #expect(!window.isVisible)

        // Other windows should not be blocked from closing
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.titled, .closable],
                                   backing: .buffered,
                                   defer: false)
        let otherShouldClose = controller.windowShouldClose(otherWindow)
        #expect(otherShouldClose == true)
    }
}
