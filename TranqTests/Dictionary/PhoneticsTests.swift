import XCTest
@testable import Tranq

final class PhoneticsTests: XCTestCase {
    func testTransliteration() {
        XCTAssertEqual(Phonetics.transliterateToCyrillic("Kubernetes"), "кубернетес")
        XCTAssertEqual(Phonetics.transliterateToCyrillic("Docker"), "докер")
    }

    func testRussianSimilarityAboveThresholdForTypicalMisrecognition() {
        XCTAssertGreaterThanOrEqual(Phonetics.similarity(token: "кубернетис", spelling: "Kubernetes", language: .ru), 0.8)
        XCTAssertLessThan(Phonetics.similarity(token: "кубик", spelling: "Kubernetes", language: .ru), 0.8)
    }

    func testEnglishKeyMatchesSoundAlikes() {
        XCTAssertEqual(Phonetics.englishKey("postgress"), Phonetics.englishKey("postgres"))
        XCTAssertLessThan(Phonetics.similarity(token: "kitchen", spelling: "Kubernetes", language: .en), 0.8)
    }

    func testSoundKey() {
        XCTAssertEqual(Phonetics.soundKey("IPI"), "p")
        XCTAssertEqual(Phonetics.soundKey("API"), "p")
        XCTAssertEqual(Phonetics.soundKey("эй пи ай"), "p")
        XCTAssertEqual(Phonetics.soundKey("BB"), "pp")
        XCTAssertEqual(Phonetics.soundKey("B2B"), "pp")
        XCTAssertEqual(Phonetics.soundKey("жиру"), "jr")
        XCTAssertEqual(Phonetics.soundKey("Jira"), "jr")
        XCTAssertEqual(Phonetics.soundKey("ГИД"), "kt")
        XCTAssertEqual(Phonetics.soundKey("Git"), "kt")
        XCTAssertEqual(Phonetics.soundKey("Power B"), "pfrp")
        XCTAssertEqual(Phonetics.soundKey("эс кью эл"), "skl")
    }

    func testDistanceEdgeCases() {
        XCTAssertEqual(Phonetics.normalizedDistance("", ""), 0)
        XCTAssertEqual(Phonetics.normalizedDistance("abc", ""), 1)
    }

    func testEnglishKeyDoesNotMergeConsonantsSplitByVowel() {
        XCTAssertNotEqual(Phonetics.englishKey("banana"), Phonetics.englishKey("bin"))
    }

    func testSimilarityIsZeroWhenKeyIsEmpty() {
        XCTAssertEqual(Phonetics.similarity(token: "кубернетес", spelling: "1С", language: .ru), 0)
        XCTAssertEqual(Phonetics.similarity(token: "яндекс", spelling: "Яндекс", language: .ru), 0)
        XCTAssertEqual(Phonetics.similarity(token: "кубернетес", spelling: "Kubernetes", language: .en), 0)
        XCTAssertEqual(Phonetics.similarity(token: "kubernetes", spelling: "1С", language: .en), 0)
    }
}
