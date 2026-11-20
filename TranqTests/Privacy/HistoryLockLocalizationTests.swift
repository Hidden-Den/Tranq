//
//  HistoryLockLocalizationTests.swift
//  TranqTests
//

import Foundation
import Testing
@testable import Tranq

/// Строки замка истории переведены на английский в собранном каталоге приложения.
struct HistoryLockLocalizationTests {
    private static let keys: [String] = [
        "История заперта",
        "Разблокировать",
        "История не читается на этом Mac",
        "Ключ остался на прежнем Mac",
        "открыть историю",
        "Замок истории",
        "Требовать Touch ID",
        "Ключ хранится на этом Mac",
        "Выгрузить",
        "Выберите папку",
        "Включить замок",
        "Ключ привязан к этому Mac.",
        "На другом Mac история не прочитается.",
        "Копию можно сохранить заранее.",
        "Вернуть её в Tranq пока нельзя.",
        "Выключить замок",
        "История снова будет доступна без подтверждения",
        "Выключить",
        "Не удалось включить",
        "Не удалось выключить",
        "Не удалось выгрузить",
        "выключить замок истории",
        "История заперта. Разблокируйте её в Tranq.",
        "Замок был выключен после сбоя",
        "Осталась открытая копия истории",
        "Логи приложения будут очищены.",
        "Не всё удалось стереть",
    ]

    private static let missing = "\u{1}нет перевода"

    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func уКаждойСтрокиЕстьАнглийскийПеревод() throws {
        let english = try bundle("en")
        for key in Self.keys {
            let value = english.localizedString(forKey: key, value: Self.missing, table: nil)
            #expect(value != Self.missing, "нет перевода: \(key)")
            #expect(value != key, "перевод совпал с ключом: \(key)")
        }
    }

    @Test func русскийТекстСовпадаетСКлючом() throws {
        let russian = try bundle("ru")
        for key in Self.keys {
            #expect(russian.localizedString(forKey: key, value: Self.missing, table: nil) == key, "разошлось: \(key)")
        }
    }

    @Test func вСтрокахНетСкобок() {
        for key in Self.keys {
            #expect(!key.contains { "()[]{}".contains($0) }, "скобки: \(key)")
        }
    }
}
