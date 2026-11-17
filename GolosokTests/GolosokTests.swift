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

    // MARK: - Whisper timing interpolation

    private func timedWords(_ texts: [String]) -> [TimedWord] {
        texts.enumerated().map { TimedWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 1) }
    }

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

    // MARK: - Version comparison (update check)

    @Test func versionComparisonHandlesSuffixes() {
        #expect(UpdateService.compareVersions("v1.12.2", "1.12.1") == .orderedDescending)
        #expect(UpdateService.compareVersions("1.10.0", "1.12.1") == .orderedAscending)
        #expect(UpdateService.compareVersions("1.12.1", "1.12.1") == .orderedSame)
        #expect(UpdateService.compareVersions("2.0", "1.99.9") == .orderedDescending)
        #expect(UpdateService.compareVersions("1.0", "1.0.1") == .orderedAscending)
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
