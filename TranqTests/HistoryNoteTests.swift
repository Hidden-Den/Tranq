//
//  HistoryNoteTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Сырая расшифровка в заметке и переключатель «Итог / Сказано».
struct HistoryNoteTests {

    @Test func legacyItemDecodesWithoutSpokenText() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"17.11.2026, 12:59","text":"БТИ","duration":"2 сек"}]"#
        let items = try JSONDecoder().decode([TranscriptionItem].self, from: Data(json.utf8))
        #expect(items[0].spokenText == nil)
        #expect(items[0].showsSpokenToggle == false)
    }

    /// Записи, сделанные прежней версией в режиме промпта, читаются: уровень очистки в записи не хранился.
    @Test func legacyPromptNoteStillLoads() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"18.11.2026, 09:30","text":"Контекст: релиз в пятницу. Задача: собрать dmg.","duration":"7 сек","spokenText":"ну короче контекст релиз в пятницу надо собрать dmg"}]"#
        let items = try JSONDecoder().decode([TranscriptionItem].self, from: Data(json.utf8))
        #expect(items[0].text.hasPrefix("Контекст"))
        #expect(items[0].showsSpokenToggle)
    }

    @Test func spokenToggleOnlyWhenDifferent() {
        var item = TranscriptionItem(date: "d", text: "Давай перенесём встречу", duration: "1 сек")
        item.spokenText = "ну давай перенесём встречу"
        #expect(item.showsSpokenToggle)
        item.spokenText = " Давай перенесём встречу "
        #expect(item.showsSpokenToggle == false)
        item.spokenText = "   "
        #expect(item.showsSpokenToggle == false)
    }

    @Test func editKeepsSpokenText() {
        var item = TranscriptionItem(date: "d", text: "a", duration: "1 сек")
        item.spokenText = "ну a"
        #expect(item.withText("b").spokenText == "ну a")
    }

    @Test func spokenTextSurvivesEncoding() throws {
        var item = TranscriptionItem(date: "d", text: "a", duration: "1 сек")
        item.spokenText = "ну a"
        let decoded = try JSONDecoder().decode(TranscriptionItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.spokenText == "ну a")
    }
}
