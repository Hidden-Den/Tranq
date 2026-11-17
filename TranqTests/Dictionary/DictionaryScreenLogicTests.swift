import XCTest
@testable import Tranq

/// Логика экрана словаря: поиск, строки вариантов, названия наборов, проверка вариантов и черновик добавления.
final class DictionaryScreenLogicTests: XCTestCase {
    private func entry(_ spelling: String, _ variants: [DictionaryLanguage: [String]], source: DictionaryEntry.Source = .manual) -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(), spelling: spelling, variants: variants, source: source,
            forceCase: false, createdAt: Date(), hits: 0, lastUsed: nil
        )
    }

    private let packs = [
        DictionaryPack(id: "it", title: [.ru: "IT и разработка", .en: "IT and development"], version: 1, entries: [
            PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубернетис"], .en: ["cooper netties"]]),
            PackEntry(spelling: "PostgreSQL", variants: [.ru: ["постгрес"], .en: ["post gress"]]),
        ]),
        DictionaryPack(id: "ai", title: [.ru: "AI и нейросети", .en: "AI"], version: 1, entries: [
            PackEntry(spelling: "postgresql", variants: [.ru: ["постгре"]]),
            PackEntry(spelling: "Claude", variants: [.ru: ["клод код"]]),
        ]),
    ]

    // MARK: - Поиск

    func testEmptyQueryReturnsNothing() {
        XCTAssertEqual(DictionaryScreenLogic.search("  ", userEntries: [entry("Голосок", [:])], packs: packs), [])
    }

    func testSearchMatchesSpellingAndVariantsOfBothLanguages() {
        let results = DictionaryScreenLogic.search("post gr", userEntries: [], packs: packs)
        XCTAssertEqual(results.map(\.spelling), ["PostgreSQL"])
        XCTAssertEqual(results.first?.source, .pack(id: "it"))

        let ru = DictionaryScreenLogic.search("КУБЕР", userEntries: [], packs: packs)
        XCTAssertEqual(ru.map(\.spelling), ["Kubernetes"])
    }

    func testSearchKeepsOneRowPerSpellingAndPrefersUserEntry() {
        let mine = entry("kubernetes", [.ru: ["кубер"]])
        let results = DictionaryScreenLogic.search("kube", userEntries: [mine], packs: packs)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.source, .user(mine.id))
        XCTAssertEqual(results.first?.spelling, "kubernetes")
    }

    func testSearchDedupsAcrossPacksInPackOrder() {
        let results = DictionaryScreenLogic.search("postgres", userEntries: [], packs: packs)
        XCTAssertEqual(results.map(\.spelling), ["PostgreSQL"])
        XCTAssertEqual(results.first?.source, .pack(id: "it"))
    }

    func testSearchListsUserEntriesBeforePacks() {
        let mine = entry("Клод", [.ru: ["клод"]])
        let results = DictionaryScreenLogic.search("клод", userEntries: [mine], packs: packs)
        XCTAssertEqual(results.map(\.spelling), ["Клод", "Claude"])
    }

    // MARK: - Варианты

    func testVariantLineShowsOnlyRequestedLanguageJoinedWithDots() {
        let variants: [DictionaryLanguage: [String]] = [.ru: ["кубер", "кубернетис"], .en: ["cooper netties"]]
        XCTAssertEqual(DictionaryScreenLogic.variantLine(variants, language: .ru), "кубер · кубернетис")
        XCTAssertEqual(DictionaryScreenLogic.variantLine(variants, language: .en), "cooper netties")
        XCTAssertEqual(DictionaryScreenLogic.variantLine([:], language: .en), "")
    }

    func testPackVariantsSkipDisabledOnes() {
        let packEntry = packs[0].entries[0]
        let disabled: Set<String> = ["it/Kubernetes/кубернетис"]
        XCTAssertEqual(DictionaryScreenLogic.packVariants(packEntry, packId: "it", language: .ru, disabled: disabled), [])
        XCTAssertEqual(DictionaryScreenLogic.packVariants(packEntry, packId: "it", language: .en, disabled: disabled), ["cooper netties"])
    }

    func testPackWordKey() {
        XCTAssertEqual(DictionaryScreenLogic.packWordKey(packId: "it", spelling: "Kubernetes"), "it/Kubernetes")
    }

    // MARK: - Язык интерфейса

    func testPackTitleFollowsInterfaceLanguageWithFallback() {
        XCTAssertEqual(DictionaryScreenLogic.packTitle(packs[0], uiLanguage: .en), "IT and development")
        XCTAssertEqual(DictionaryScreenLogic.packTitle(packs[0], uiLanguage: .ru), "IT и разработка")
        let onlyRu = DictionaryPack(id: "x", title: [.ru: "Только русский"], version: 1, entries: [])
        XCTAssertEqual(DictionaryScreenLogic.packTitle(onlyRu, uiLanguage: .en), "Только русский")
        let none = DictionaryPack(id: "x", title: [:], version: 1, entries: [])
        XCTAssertEqual(DictionaryScreenLogic.packTitle(none, uiLanguage: .en), "x")
    }

    func testInterfaceLanguageIsEnglishOnlyForEnglishLocalization() {
        XCTAssertEqual(DictionaryScreenLogic.uiLanguage(preferredLocalizations: ["en"]), .en)
        XCTAssertEqual(DictionaryScreenLogic.uiLanguage(preferredLocalizations: ["en-GB"]), .en)
        XCTAssertEqual(DictionaryScreenLogic.uiLanguage(preferredLocalizations: ["ru"]), .ru)
        XCTAssertEqual(DictionaryScreenLogic.uiLanguage(preferredLocalizations: []), .ru)
    }

    // MARK: - Ввод варианта

    func testTypedVariantIsValidatedByRulesAndScript() {
        let checker = SetCommonWordChecker([.ru: ["кубик"]])
        XCTAssertEqual(DictionaryScreenLogic.typedVariant("  Кубер ", spelling: "Kubernetes", language: .ru, existing: [], checker: checker), "кубер")
        XCTAssertNil(DictionaryScreenLogic.typedVariant("кубик", spelling: "Kubernetes", language: .ru, existing: [], checker: checker))
        XCTAssertNil(DictionaryScreenLogic.typedVariant("kuber", spelling: "Kubernetes", language: .ru, existing: [], checker: checker))
        XCTAssertNil(DictionaryScreenLogic.typedVariant("kubernetes", spelling: "Kubernetes", language: .en, existing: [], checker: checker))
        XCTAssertNil(DictionaryScreenLogic.typedVariant("кубер", spelling: "Kubernetes", language: .ru, existing: ["Кубер"], checker: checker))
    }

    // MARK: - Черновик добавления

    func testDraftMergesSuggestionsRecordedAndRemovals() {
        var draft = AddWordDraft()
        draft.applySuggestions([.ru: ["кубернетес"], .en: ["cooper netties"]])
        draft.addRecorded("кубер", language: .ru)
        draft.addRecorded("Кубер", language: .ru)
        XCTAssertEqual(draft.variants(for: .ru), ["кубернетес", "кубер"])

        draft.remove("кубернетес", language: .ru)
        // Повторная подсказка не возвращает удалённый вариант.
        draft.applySuggestions([.ru: ["кубернетес", "кубер нетис"]])
        XCTAssertEqual(draft.variants(for: .ru), ["кубер нетис", "кубер"])
        XCTAssertEqual(draft.variants(for: .en), [])
        XCTAssertEqual(draft.allVariants, [.ru: ["кубер нетис", "кубер"]])
    }

    func testDraftSavesOnlyShownLanguage() {
        var draft = AddWordDraft()
        draft.applySuggestions([.ru: ["кубернетес"], .en: ["cooper netties"]])
        draft.addRecorded("кубер", language: .ru)
        XCTAssertEqual(draft.variantsToSave(shown: .ru), [.ru: ["кубернетес", "кубер"]])
        XCTAssertEqual(draft.variantsToSave(shown: .en), [.en: ["cooper netties"]])
        var empty = AddWordDraft()
        empty.applySuggestions([.en: ["cooper netties"]])
        XCTAssertEqual(empty.variantsToSave(shown: .ru), [:])
    }

    // MARK: - Удаление варианта

    func testRemovingLastVariantOfLearnedEntryDeletesIt() {
        func entry(_ source: DictionaryEntry.Source, _ variants: [DictionaryLanguage: [String]]) -> DictionaryEntry {
            DictionaryEntry(id: UUID(), spelling: "Kubernetes", variants: variants, source: source,
                            forceCase: false, createdAt: Date(), hits: 0, lastUsed: nil)
        }
        XCTAssertTrue(DictionaryScreenLogic.removalDeletesEntry(entry(.learned, [.ru: ["кубер"]]), variant: "кубер", language: .ru))
        XCTAssertTrue(DictionaryScreenLogic.removalDeletesEntry(entry(.learned, [.ru: ["Кубер"], .en: []]), variant: "кубер", language: .ru))
        XCTAssertFalse(DictionaryScreenLogic.removalDeletesEntry(entry(.learned, [.ru: ["кубер", "кубернетес"]]), variant: "кубер", language: .ru))
        XCTAssertFalse(DictionaryScreenLogic.removalDeletesEntry(entry(.learned, [.ru: ["кубер"], .en: ["kuber"]]), variant: "кубер", language: .ru))
        XCTAssertFalse(DictionaryScreenLogic.removalDeletesEntry(entry(.manual, [.ru: ["кубер"]]), variant: "кубер", language: .ru))
    }

    func testDraftRemovingRecordedVariantDropsIt() {
        var draft = AddWordDraft()
        draft.addRecorded("кубер", language: .ru)
        draft.remove("кубер", language: .ru)
        XCTAssertEqual(draft.allVariants, [:])
    }

    // MARK: - 🎙

    func testProbeOutcomesMapToMessages() {
        XCTAssertEqual(DictionaryScreenLogic.probeResult(.tooQuiet), .notHeard)
        XCTAssertEqual(DictionaryScreenLogic.probeResult(.noise), .notHeard)
        XCTAssertEqual(DictionaryScreenLogic.probeResult(.tooManyWords), .justTheWord)
        XCTAssertEqual(DictionaryScreenLogic.probeResult(.alreadyCorrect), .alreadyRecognized)
        XCTAssertEqual(DictionaryScreenLogic.probeResult(.variant("кубер")), .heard("кубер"))
    }
}
