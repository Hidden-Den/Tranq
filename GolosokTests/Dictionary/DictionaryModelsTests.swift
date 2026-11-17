import XCTest
import AppKit
@testable import Golosok

final class DictionaryModelsTests: XCTestCase {
    func testPackDecodesBilingualVariantsAndDefaultsCommonIn() throws {
        let json = #"{"id":"it","title":{"ru":"IT и разработка","en":"IT & Development"},"version":1,"entries":[{"spelling":"Kubernetes","variants":{"ru":["кубер"],"en":["cooper netties"]}}]}"#
        let pack = try JSONDecoder().decode(DictionaryPack.self, from: Data(json.utf8))
        XCTAssertEqual(pack.entries[0].variants[.ru], ["кубер"])
        XCTAssertEqual(pack.entries[0].variants[.en], ["cooper netties"])
        XCTAssertEqual(pack.entries[0].commonIn, [])
        XCTAssertEqual(pack.title[.en], "IT & Development")
    }

    func testLanguageKeyedDictionaryEncodesAsObject() throws {
        let entry = PackEntry(spelling: "X", variants: [.ru: ["икс"]], commonIn: [.en])
        let data = try JSONEncoder().encode(entry)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variants = try XCTUnwrap(obj["variants"] as? [String: Any])
        XCTAssertEqual(variants["ru"] as? [String], ["икс"])
        XCTAssertEqual(try JSONDecoder().decode(PackEntry.self, from: data), entry)
    }

    func testSpellCheckerKnowsCommonWordsInBothLanguages() {
        let c = SpellCommonWordChecker.shared
        XCTAssertTrue(NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("ru") })
        XCTAssertTrue(c.isCommonWord("питон", language: .ru))
        XCTAssertFalse(c.isCommonWord("кубер", language: .ru))
        XCTAssertTrue(c.isCommonWord("slack", language: .en))
        XCTAssertFalse(c.isCommonWord("github", language: .en))
    }

    func testSpellCheckerGivesSameAnswersFromManyThreads() {
        let c = SpellCommonWordChecker()
        let words: [(String, DictionaryLanguage, Bool)] = [
            ("питон", .ru, true), ("кубер", .ru, false), ("slack", .en, true), ("github", .en, false),
        ]
        let mismatches = NSLock()
        var wrong = 0
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let (word, language, expected) = words[i % words.count]
            if c.isCommonWord(word, language: language) != expected {
                mismatches.lock()
                wrong += 1
                mismatches.unlock()
            }
        }
        XCTAssertEqual(wrong, 0)
    }

    func testSetCheckerIsCaseInsensitive() {
        let c = SetCommonWordChecker([.en: ["slack"]])
        XCTAssertTrue(c.isCommonWord("Slack", language: .en))
        XCTAssertFalse(c.isCommonWord("slack", language: .ru))
    }

    func testUnknownLanguageKeysAreDropped() throws {
        let packJSON = #"{"id":"it","title":{"ru":"IT","de":"IT DE"},"version":1,"entries":[{"spelling":"Kubernetes","variants":{"ru":["кубер"],"de":["kuba"]},"commonIn":["de","en"]}]}"#
        let pack = try JSONDecoder().decode(DictionaryPack.self, from: Data(packJSON.utf8))
        XCTAssertEqual(pack.title, [.ru: "IT"])
        XCTAssertEqual(pack.entries[0].variants, [.ru: ["кубер"]])
        XCTAssertEqual(pack.entries[0].commonIn, [.en])

        let entryJSON = #"{"id":"9F1C8C42-7B39-4C5B-9E0D-2A1B3C4D5E6F","spelling":"Grafana","variants":{"ru":["графана"],"de":["grafana"]},"source":"manual","forceCase":false,"createdAt":0,"hits":2}"#
        let entry = try JSONDecoder().decode(DictionaryEntry.self, from: Data(entryJSON.utf8))
        XCTAssertEqual(entry.variants, [.ru: ["графана"]])
        XCTAssertEqual(entry.hits, 2)

        // Кодирование прежнее: объект с ключами языков.
        let data = try JSONEncoder().encode(entry)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((obj["variants"] as? [String: Any])?["ru"] as? [String], ["графана"])
        XCTAssertEqual(try JSONDecoder().decode(DictionaryEntry.self, from: data), entry)
    }
}
