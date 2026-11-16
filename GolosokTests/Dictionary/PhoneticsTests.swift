import XCTest
@testable import Golosok

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

    func testDistanceEdgeCases() {
        XCTAssertEqual(Phonetics.normalizedDistance("", ""), 0)
        XCTAssertEqual(Phonetics.normalizedDistance("abc", ""), 1)
    }
}
