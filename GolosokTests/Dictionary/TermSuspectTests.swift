import XCTest
@testable import Golosok

/// Подозрительные слова распознавания и кандидаты из словаря на реальных наборах.
final class TermSuspectTests: XCTestCase {
    private var index: DictionaryIndex!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("golosok-suspects-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "golosok.suspects.\(UUID().uuidString)")!
        let store = DictionaryStore(
            directory: directory, defaults: defaults, packsBundle: Bundle.main, checker: SpellCommonWordChecker.shared
        )
        store.waitForIndex()
        index = try XCTUnwrap(store.index)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSkippedSingleLetterDoesNotMergeLaterOnes() {
        XCTAssertEqual(DictionaryIndex.suspectWords(in: "привет A B"), ["привет"])
        XCTAssertEqual(DictionaryIndex.suspectWords(in: "Выгрузи Power B"), ["Выгрузи", "Power B"])
    }

    /// Пары из замера: распознанная фраза, искажённое слово и термин, который был сказан.
    func testMisrecognizedTermsGetTheSpokenCandidate() {
        let cases: [(String, String, String)] = [
            ("Настрой IPI ключ для интеграции.", "IPI", "API"),
            ("Мы работаем в BB, а не в Buce.", "BB", "B2B"),
            ("Мы работаем в BB, а не в Buce.", "Buce", "B2C"),
            ("Вопрос про CNT лучше задать HR-бизнес-партнёру.", "CNT", "C&B"),
            ("Выгрузи отчёт из Power B в PDF.", "Power B", "Power BI"),
        ]
        for (text, token, term) in cases {
            let suspects = index.termSuspects(in: text, language: .ru)
            let suspect = suspects.first { $0.token == token }
            XCTAssertNotNil(suspect, "\(token) не найден в «\(text)»: \(suspects)")
            XCTAssertTrue(suspect?.candidates.contains(term) == true, "\(token): \(suspect?.candidates ?? [])")
        }
    }

    func testCleanPhraseHasNoSuspects() {
        XCTAssertEqual(index.termSuspects(in: "Антон прислал макет, проверь сроки.", language: .ru), [])
    }

    func testApprovedSpellingsAreNotSuspects() {
        XCTAssertEqual(index.termSuspects(in: "Открой Pull Request на Staging, обнови CRM.", language: .ru), [])
    }

    func testSuspectsAreCapped() {
        let suspects = index.termSuspects(in: "IPI BB Buce CNT Sk", language: .ru)
        XCTAssertEqual(suspects.count, 3)
        XCTAssertTrue(suspects.allSatisfy { $0.candidates.count <= 6 })
    }

    /// Один согласный звук совпадает почти с чем угодно: «Ley» стало LOI. Такой ключ годится только аббревиатуре.
    func testSingleSoundKeyNeedsUppercase() {
        let suspects = index.termSuspects(in: "The Ley Fix на Staging, скинь ссылку.", language: .ru)
        XCTAssertNil(suspects.first { $0.token == "Ley" }, "\(suspects)")
        XCTAssertNotNil(index.termSuspects(in: "Настрой IPI ключ.", language: .ru).first { $0.token == "IPI" })
    }

    /// Обычные русские аббревиатуры не термины: «ЗП» не должно превращаться в C&B, «СМИ» в CMS.
    func testCommonRussianAbbreviationsAreNotSuspects() {
        let text = "Скинь ТЗ по ЗП до пятницы, СМИ и ГОСТ подождут, МВД тоже."
        XCTAssertEqual(index.termSuspects(in: text, language: .ru), [])
    }

    /// Бренды вне словаря не получают далёких по буквам терминов: Ozon не станет Asana или C&B.
    func testBrandsOutsideDictionaryGetNoDistantTerms() {
        let suspects = index.termSuspects(in: "Закажи на Ozon, потом зайди на Avito.", language: .ru)
        let ozon = suspects.first { $0.token == "Ozon" }?.candidates ?? []
        let avito = suspects.first { $0.token == "Avito" }?.candidates ?? []
        XCTAssertTrue(Set(ozon).isDisjoint(with: ["Asana", "Suno", "УСН", "C&B"]), "\(ozon)")
        XCTAssertFalse(avito.contains("FTE"), "\(avito)")
    }

    /// Две буквы не заглавными слишком мало говорят о термине: «Sk» модель меняла то на SQL, то на SDK.
    func testShortMixedCaseWordIsNotSuspect() {
        XCTAssertEqual(index.termSuspects(in: "Пришли Sk-запрос, я проверю.", language: .ru), [])
    }

    func testCyrillicIsNotSuspect() {
        XCTAssertEqual(index.termSuspects(in: "Подними версию в ГИД и поставь тег.", language: .ru), [])
    }

    func testOnlyRussianDictation() {
        XCTAssertEqual(index.termSuspects(in: "Настрой IPI ключ для интеграции.", language: .en), [])
    }
}
