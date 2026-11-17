import XCTest
@testable import Golosok

final class DictionaryIndexTests: XCTestCase {
    private let checker = SetCommonWordChecker([
        .ru: ["питон", "питона", "и", "у", "в", "привет"],
        .en: ["slack", "notion", "push", "it", "to"],
    ])

    private let devops = DictionaryPack(
        id: "devops",
        title: [.ru: "Разработка", .en: "Development"],
        version: 1,
        entries: [
            PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер", "кубернетес"], .en: ["cooper netties"]]),
            PackEntry(spelling: "n8n", variants: [.ru: ["эн восемь эн", "эн"], .en: ["n eight n"]]),
            PackEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]]),
            PackEntry(spelling: "Slack", variants: [.ru: ["слак"]], commonIn: [.en]),
            PackEntry(spelling: "Node.js", variants: [:]),
            PackEntry(spelling: "Jira", variants: [.ru: ["джира"]]),
            PackEntry(spelling: "НДС", variants: [.ru: ["эндээс"]]),
            PackEntry(spelling: "1С", variants: [.ru: ["одинэс"]]),
            PackEntry(spelling: "PostgreSQL", variants: [.ru: ["постгрес"]]),
        ]
    )

    private let other = DictionaryPack(
        id: "other",
        title: [.ru: "Другое", .en: "Other"],
        version: 1,
        entries: [
            PackEntry(spelling: "Kuber", variants: [.ru: ["кубер"]]),
        ]
    )

    private func user(_ spelling: String, ru: [String] = [], en: [String] = [], forceCase: Bool = false) -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(), spelling: spelling, variants: [.ru: ru, .en: en], source: .manual,
            forceCase: forceCase, createdAt: Date(timeIntervalSince1970: 0), hits: 0, lastUsed: nil
        )
    }

    private func makeIndex(
        users: [DictionaryEntry] = [],
        packs: [DictionaryPack]? = nil,
        disabledPacks: Set<String> = [],
        disabledWords: Set<String> = [],
        disabledVariants: Set<String> = []
    ) -> DictionaryIndex {
        DictionaryIndex(
            userEntries: users, packs: packs ?? [devops, other],
            disabledPacks: disabledPacks, disabledPackWords: disabledWords,
            disabledPackVariants: disabledVariants, checker: checker
        )
    }

    private var idx: DictionaryIndex {
        makeIndex(users: [user("Голосок", ru: ["голосог"]), user("Python", ru: ["питон"])])
    }

    // MARK: - Exact variants

    func testExactVariantKeepsPunctuationAndSentenceStart() {
        let r = idx.apply(to: "Кубер, привет.", language: .ru)
        XCTAssertEqual(r.text, "Kubernetes, привет.")
        XCTAssertEqual(r.replacements.first?.reason, .variant)
        XCTAssertEqual(r.replacements, [AppliedReplacement(
            original: "Кубер", replacement: "Kubernetes", entryKey: "devops/Kubernetes", variant: "кубер", reason: .variant
        )])
    }

    func testLongestMultiwordVariantWins() {
        XCTAssertEqual(idx.apply(to: "поставили эн восемь эн вчера", language: .ru).text, "поставили n8n вчера")
        XCTAssertEqual(idx.apply(to: "эн  восемь   эн", language: .ru).text, "n8n")
    }

    func testMultiwordVariantDoesNotCrossPunctuation() {
        XCTAssertEqual(idx.apply(to: "эн, восемь эн", language: .ru).text, "n8n, восемь n8n")
    }

    func testEnglishMultiwordVariant() {
        XCTAssertEqual(idx.apply(to: "deploy to Cooper Netties now", language: .en).text, "deploy to Kubernetes now")
    }

    func testEmptyTextUnchanged() {
        let r = idx.apply(to: "", language: .ru)
        XCTAssertEqual(r.text, "")
        XCTAssertTrue(r.replacements.isEmpty)
    }

    // MARK: - Word forms

    func testLatinSpellingSwallowsRussianEnding() {
        XCTAssertEqual(idx.apply(to: "в кубере упал под", language: .ru).text, "в Kubernetes упал под")
        XCTAssertEqual(idx.apply(to: "с кубером.", language: .ru).text, "с Kubernetes.")
    }

    func testTruncatedStemMatchesForm() {
        XCTAssertEqual(idx.apply(to: "задача в джире", language: .ru).text, "задача в Jira")
    }

    func testAcronymSwallowsEnding() {
        XCTAssertEqual(idx.apply(to: "без эндээса", language: .ru).text, "без НДС")
        XCTAssertEqual(idx.apply(to: "в одинэсе", language: .ru).text, "в 1С")
    }

    func testCyrillicSpellingKeepsEnding() {
        // пользовательская запись «Голосок», вариант «голосог»
        XCTAssertEqual(idx.apply(to: "у голосога", language: .ru).text, "у Голосока")
        XCTAssertEqual(idx.apply(to: "с голосогом", language: .ru).text, "с Голосоком")
    }

    func testCommonWordVariantOnlyExactForm() {
        // пользовательская запись Python, вариант «питон», который словарный
        XCTAssertEqual(idx.apply(to: "питон и питона", language: .ru).text, "Python и питона")
        // «питону» и «питоном» не словарные для проверки, их отсекает только словарность варианта
        XCTAssertEqual(idx.apply(to: "к питону с питоном", language: .ru).text, "к питону с питоном")
    }

    func testCommonTokenIsNotTakenAsWordForm() {
        let checker = SetCommonWordChecker([.ru: ["кубера"]])
        let index = DictionaryIndex(
            userEntries: [], packs: [devops], disabledPacks: [], disabledPackWords: [],
            disabledPackVariants: [], checker: checker
        )
        XCTAssertEqual(index.apply(to: "кубера кубером", language: .ru).text, "кубера Kubernetes")
    }

    func testWordFormsOnlyInRussian() {
        let index = makeIndex(users: [user("Zed", en: ["zedd"])])
        XCTAssertEqual(index.apply(to: "zedda zedd", language: .en).text, "zedda Zed")
    }

    // MARK: - Case

    func testEnglishCaseFix() {
        XCTAssertEqual(idx.apply(to: "push it to github", language: .en).text, "push it to GitHub")
        XCTAssertEqual(idx.apply(to: "cut me some slack", language: .en).text, "cut me some slack")
        let r = idx.apply(to: "github", language: .en)
        XCTAssertEqual(r.replacements.first?.reason, .caseFix)
        XCTAssertEqual(r.replacements.first?.entryKey, "devops/GitHub")
    }

    func testCaseFixKeepsInnerAndTrailingPunctuation() {
        XCTAssertEqual(idx.apply(to: "use node.js.", language: .en).text, "use Node.js.")
    }

    func testCaseFixOnlyInEnglish() {
        XCTAssertEqual(idx.apply(to: "github", language: .ru).text, "github")
    }

    func testCaseFixForUserEntryUsesChecker() {
        let index = makeIndex(users: [user("Notion"), user("Figma")], packs: [])
        XCTAssertEqual(index.apply(to: "notion and figma", language: .en).text, "notion and Figma")
    }

    func testForceCaseOverridesCommonWord() {
        let index = makeIndex(users: [user("Slack", forceCase: true)])
        XCTAssertEqual(index.apply(to: "on slack", language: .en).text, "on Slack")
    }

    func testUnchangedTokenIsNotReported() {
        XCTAssertTrue(idx.apply(to: "GitHub", language: .en).replacements.isEmpty)
    }

    // MARK: - Languages, priority, disabling

    func testLanguageIsolation() {
        XCTAssertEqual(idx.apply(to: "кубер", language: .en).text, "кубер")
        XCTAssertEqual(idx.apply(to: "cooper netties", language: .ru).text, "cooper netties")
    }

    func testPackOrderDecides() {
        XCTAssertEqual(makeIndex(packs: [devops, other]).apply(to: "кубер", language: .ru).text, "Kubernetes")
        XCTAssertEqual(makeIndex(packs: [other, devops]).apply(to: "кубер", language: .ru).text, "Kuber")
    }

    func testUserEntryBeatsPackAndSurvivesDisabledPackWord() {
        let pg = user("Postgres", ru: ["постгрес"])
        let r = makeIndex(users: [pg]).apply(to: "постгрес", language: .ru)
        XCTAssertEqual(r.text, "Postgres")
        XCTAssertEqual(r.replacements.first?.entryKey, "user/\(pg.id.uuidString)")

        let kube = user("Kubernetes", ru: ["кубик"])
        let index = makeIndex(users: [kube], disabledWords: ["devops/Kubernetes"])
        XCTAssertEqual(index.apply(to: "кубер кубик", language: .ru).text, "Kuber Kubernetes")
        XCTAssertTrue(index.approvedSpellings.contains("Kubernetes"))
    }

    func testDisabledPackAndVariantAreIgnored() {
        let noPack = makeIndex(disabledPacks: ["devops"])
        XCTAssertEqual(noPack.apply(to: "гитхаб", language: .ru).text, "гитхаб")
        XCTAssertEqual(noPack.apply(to: "github", language: .en).text, "github")
        XCTAssertFalse(noPack.approvedSpellings.contains("GitHub"))

        let noVariant = makeIndex(packs: [devops], disabledVariants: ["devops/Kubernetes/кубер"])
        XCTAssertEqual(noVariant.apply(to: "кубер кубернетес кубера", language: .ru).text, "кубер Kubernetes кубера")

        let noCaseFix = makeIndex(disabledVariants: ["devops/GitHub/github"])
        XCTAssertEqual(noCaseFix.apply(to: "github гитхаб", language: .en).text, "github гитхаб")
        XCTAssertEqual(noCaseFix.apply(to: "гитхаб", language: .ru).text, "GitHub")

        let noWord = makeIndex(disabledWords: ["devops/GitHub"])
        XCTAssertEqual(noWord.apply(to: "github", language: .en).text, "github")
        XCTAssertFalse(noWord.approvedSpellings.contains("GitHub"))
    }

    func testApprovedSpellings() {
        let index = makeIndex(users: [user("Голосок")], packs: [other])
        XCTAssertEqual(index.approvedSpellings, ["Голосок", "Kuber"])
    }

    // MARK: - Budget

    func testExactMatchBudgetUnderOneMillisecond() {
        let packs = (0..<10).map { p in
            DictionaryPack(
                id: "pack\(p)", title: [.ru: "Набор \(p)", .en: "Pack \(p)"], version: 1,
                entries: (0..<100).map { e in
                    PackEntry(
                        spelling: "Term\(p)x\(e)",
                        variants: [
                            .ru: ["терм\(p)ж\(e)", "терм \(p) ж \(e)"],
                            .en: ["term \(p) x \(e)"],
                        ]
                    )
                }
            )
        }
        let index = DictionaryIndex(
            userEntries: [], packs: packs, disabledPacks: [], disabledPackWords: [],
            disabledPackVariants: [], checker: SetCommonWordChecker([:])
        )
        let words = ["в", "кубере", "терм3ж7", "упал,", "терм", "5", "ж", "9", "и", "терм2ж4ах", "привет."]
        let phrase = (0..<100).map { words[$0 % words.count] }.joined(separator: " ")
        let english = (0..<100).map { ["push", "term1x2", "to", "term", "4", "x", "8", "now."][$0 % 8] }.joined(separator: " ")

        XCTAssertEqual(index.apply(to: phrase, language: .ru).replacements.count, 27)
        XCTAssertEqual(index.apply(to: english, language: .en).replacements.count, 25)

        var ru: [Double] = []
        var en: [Double] = []
        for _ in 0..<200 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = index.apply(to: phrase, language: .ru)
            ru.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            start = DispatchTime.now().uptimeNanoseconds
            _ = index.apply(to: english, language: .en)
            en.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        let medianRu = ru.sorted()[ru.count / 2]
        let medianEn = en.sorted()[en.count / 2]
        XCTAssertLessThan(medianRu, 0.001, "ru median \(medianRu)")
        XCTAssertLessThan(medianEn, 0.001, "en median \(medianEn)")
    }

    /// Записывает слова, которые индекс проверил по словарю.
    private final class RecordingChecker: CommonWordChecking {
        private let lock = NSLock()
        private var words: [String] = []
        var checked: [String] { lock.lock(); defer { lock.unlock() }; return words }

        func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool {
            lock.lock(); words.append(word.lowercased()); lock.unlock()
            return false
        }
    }

    func testPackVariantsAreNotSpellChecked() {
        let recorder = RecordingChecker()
        let index = DictionaryIndex(
            userEntries: [user("Grafana", ru: ["графана"])], packs: [devops],
            disabledPacks: [], disabledPackWords: [], disabledPackVariants: [], checker: recorder
        )
        XCTAssertTrue(recorder.checked.contains("графана"))
        for word in ["кубер", "кубернетес", "гитхаб", "джира", "эндээс", "одинэс", "постгрес", "слак", "эн"] {
            XCTAssertFalse(recorder.checked.contains(word), word)
        }
        // Словоформы варианта набора по-прежнему работают.
        XCTAssertEqual(index.apply(to: "в джире", language: .ru).text, "в Jira")
    }
}
