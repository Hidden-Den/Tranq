import XCTest
@testable import Tranq

private struct LCG {
    var seed: UInt64
    mutating func next(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(bound))
    }
}

final class DictionaryFuzzyTests: XCTestCase {
    private let checker = SetCommonWordChecker([
        .ru: ["кубик", "комната", "привет"],
        .en: ["kubernetes"],
    ])

    private let pack = DictionaryPack(
        id: "devops",
        title: [.ru: "Разработка", .en: "Development"],
        version: 1,
        entries: [
            PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"], .en: []]),
            PackEntry(spelling: "PostgreSQL", variants: [.ru: ["постгрес"]]),
            PackEntry(spelling: "1С", variants: [.ru: ["одинэс"]]),
            PackEntry(spelling: "Яндекс", variants: [:]),
        ]
    )

    private func user(_ spelling: String) -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(), spelling: spelling, variants: [:], source: .manual,
            forceCase: false, createdAt: Date(timeIntervalSince1970: 0), hits: 0, lastUsed: nil
        )
    }

    private func makeIndex(
        users: [DictionaryEntry] = [], packs: [DictionaryPack]? = nil,
        disabledPacks: Set<String> = [], disabledWords: Set<String> = []
    ) -> DictionaryIndex {
        DictionaryIndex(
            userEntries: users, packs: packs ?? [pack], disabledPacks: disabledPacks,
            disabledPackWords: disabledWords, disabledPackVariants: [], checker: checker
        )
    }

    func testFuzzyFindsUnlistedMisrecognition() {
        XCTAssertEqual(makeIndex().fuzzyHits(in: "развернули кубернетас", language: .ru).map(\.spelling), ["Kubernetes"])
    }

    func testFuzzySkipsShortAndCommonWords() {
        XCTAssertTrue(makeIndex().fuzzyHits(in: "кубик и комната", language: .ru).isEmpty)
    }

    func testFuzzySkipsCommonWordEvenWhenSimilar() {
        let idx = DictionaryIndex(
            userEntries: [], packs: [pack], disabledPacks: [], disabledPackWords: [], disabledPackVariants: [],
            checker: SetCommonWordChecker([.ru: ["кубернетас"]])
        )
        XCTAssertTrue(idx.fuzzyHits(in: "кубернетас", language: .ru).isEmpty)
    }

    func testFuzzyCountsLettersOnly() {
        // Five letters plus a digit and a dot are not six letters.
        XCTAssertTrue(makeIndex(users: [user("Kuber")]).fuzzyHits(in: "кубер1.", language: .ru).isEmpty)
    }

    func testFuzzySkipsExactlyReplacedTokens() {
        // "постгрес" is an exact pack variant, so it is replaced and never reported; "кубернетес" is not a variant.
        let idx = makeIndex(users: [user("Kubernetes")])
        XCTAssertEqual(idx.fuzzyHits(in: "постгрес кубернетес", language: .ru).map(\.token), ["кубернетес"])
        XCTAssertTrue(idx.fuzzyHits(in: "постгрес", language: .ru).isEmpty)
    }

    func testFuzzyIgnoresSpellingsWithoutLatinLettersForRussian() {
        let idx = makeIndex()
        XCTAssertTrue(idx.fuzzyHits(in: "яндексом одинэс", language: .ru).isEmpty)
    }

    func testFuzzyEnglishUsesPhoneticKey() {
        let idx = makeIndex(users: [user("Postgres")])
        XCTAssertTrue(idx.fuzzyHits(in: "deploying postgres", language: .en).isEmpty) // identical text needs no fix
        XCTAssertEqual(idx.fuzzyHits(in: "deploying postgress", language: .en).map(\.spelling), ["Postgres"])
    }

    func testFuzzyRespectsDisabledPackAndWord() {
        XCTAssertTrue(makeIndex(disabledPacks: ["devops"]).fuzzyHits(in: "кубернетас", language: .ru).isEmpty)
        XCTAssertTrue(makeIndex(disabledWords: ["devops/Kubernetes"]).fuzzyHits(in: "кубернетас", language: .ru).isEmpty)
    }

    func testFuzzyReturnsOneBestHitPerTokenInOrderUserFirstOnTies() {
        let userEntry = user("Kubernetes")
        let hits = makeIndex(users: [userEntry, user("Postgres")]).fuzzyHits(in: "кубернетас и постгрис", language: .ru)
        XCTAssertEqual(hits.map(\.token), ["кубернетас", "постгрис"])
        XCTAssertEqual(hits.map(\.spelling), ["Kubernetes", "Postgres"])

        let better = makeIndex(users: [user("Kubernetas")]).fuzzyHits(in: "кубернетас", language: .ru)
        XCTAssertEqual(better.map(\.spelling), ["Kubernetas"])
        XCTAssertEqual(better.count, 1)

        let tied = makeIndex(users: [user("Kubernetis"), user("Kubernetus")]).fuzzyHits(in: "кубернетас", language: .ru)
        XCTAssertEqual(tied.map(\.spelling), ["Kubernetis"])
    }

    func testFuzzyTieAcrossLengthGroupsPrefersUserEntry() {
        // Pack "Kuberneta" has a shorter key (9) than user "Kubernetis" (10) but the same score 0.9.
        let shorter = DictionaryPack(id: "p", title: [:], version: 1, entries: [PackEntry(spelling: "Kuberneta", variants: [:])])
        let hits = makeIndex(users: [user("Kubernetis")], packs: [shorter]).fuzzyHits(in: "кубернетас", language: .ru)
        XCTAssertEqual(hits.map(\.spelling), ["Kubernetis"])
    }

    func testFuzzyBudgetUnderFiveMilliseconds() {
        // Deterministic pseudo-random product names, 5 to 10 letters, spread over the alphabet.
        var rng = LCG(seed: 42)
        func next(_ bound: Int) -> Int { rng.next(bound) }
        let letters = Array("abcdefghijklmnoprstuvwxyz")
        var users: [DictionaryEntry] = []
        for _ in 0..<1000 {
            let name = (0..<(5 + next(6))).map { _ in String(letters[next(letters.count)]) }.joined()
            users.append(user(name.capitalized))
        }
        let idx = DictionaryIndex(
            userEntries: users, packs: [pack], disabledPacks: [], disabledPackWords: [], disabledPackVariants: [],
            checker: SetCommonWordChecker([:])
        )
        let words = ["развернули", "кубернетас", "сегодня", "утром", "постгрис", "тулабикс"]
        let phrase = (0..<100).map { words[$0 % words.count] }.joined(separator: " ")
        var times: [Double] = []
        for _ in 0..<200 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = idx.fuzzyHits(in: phrase, language: .ru)
            times.append(CFAbsoluteTimeGetCurrent() - start)
        }
        let median = times.sorted()[times.count / 2]
        XCTAssertLessThan(median, 0.005, "median \(median)")
    }

    func testFuzzyPruningMatchesBruteForceSimilarity() {
        var rng = LCG(seed: 7)
        func next(_ bound: Int) -> Int { rng.next(bound) }
        let latin = Array("abdeghiklmnoprstuv")
        let cyrillic = Array("абдегхиклмнорстув")
        let names = (0..<150).map { _ in String((0..<(6 + next(5))).map { _ in latin[next(latin.count)] }).capitalized }
        let idx = DictionaryIndex(
            userEntries: names.map(user), packs: [], disabledPacks: [], disabledPackWords: [], disabledPackVariants: [],
            checker: SetCommonWordChecker([:])
        )
        for _ in 0..<300 {
            var chars = Array(Phonetics.transliterateToCyrillic(names[next(names.count)]))
            for _ in 0..<next(3) where !chars.isEmpty {
                let at = next(chars.count)
                switch next(3) {
                case 0: chars[at] = cyrillic[next(cyrillic.count)]
                case 1: chars.remove(at: at)
                default: chars.insert(cyrillic[next(cyrillic.count)], at: at)
                }
            }
            let token = String(chars)
            guard token.count >= 6 else { continue }
            let expected = names
                .filter { Phonetics.transliterateToCyrillic($0).first == token.first && abs(Phonetics.transliterateToCyrillic($0).count - token.count) <= 3 }
                .map { Phonetics.similarity(token: token, spelling: $0, language: .ru) }
                .max() ?? 0
            let hit = idx.fuzzyHits(in: token, language: .ru).first
            if expected >= 0.8 {
                XCTAssertEqual(hit?.similarity ?? 0, expected, accuracy: 1e-9, token)
            } else {
                XCTAssertNil(hit, token)
            }
        }
    }
}
