import Testing
import Foundation
@testable import Golosok

struct VariantSuggesterTests {
    private struct MockLLM: VariantLLM {
        let reply: String?
        func complete(system: String, user: String) async -> String? { reply }
    }

    private let checker = SetCommonWordChecker([.ru: ["кубик"], .en: ["cube"]])

    @Test func testInstantGivesCyrillicTransliterationForLatin() {
        let s = VariantSuggester(checker: checker, llm: nil)
        #expect(s.instant(for: "Kubernetes") == [.ru: ["кубернетес"]])
        #expect(s.instant(for: "Кубернетес").isEmpty)
    }

    @Test func testFilterDropsCommonWordsAndWrongScript() async {
        let llm = MockLLM(reply: #"{"ru":["кубик","cube","кубер"],"en":["cube","kuber","кубер"]}"#)
        let s = VariantSuggester(checker: checker, llm: llm)
        let result = await s.suggest(for: "Kubernetes")
        #expect(result[.ru]?.contains("кубер") == true)
        #expect(result[.ru]?.contains("кубик") == false)
        #expect(result[.ru]?.contains("cube") == false)
        #expect(result[.en] == ["kuber"])
    }

    @Test func testFilterCapsAndDeduplicatesAndDropsSpellingAndDenied() async {
        let llm = MockLLM(reply: #"{"ru":["аа","бб","вв","гг","дд","ее","ёё","кубик","питон"],"en":["kubernetes","Kubernetes","kuber kuber kuber kuber kuber"]}"#)
        let s = VariantSuggester(checker: SetCommonWordChecker([:]), llm: llm)
        let result = await s.suggest(for: "Kubernetes")
        #expect((result[.ru] ?? []).count == 5)
        #expect(result[.ru]?.contains("питон") == false)
        #expect(result[.en] == nil)
    }

    @Test func testInvalidLLMJsonFallsBackToInstant() async {
        let s = VariantSuggester(checker: checker, llm: MockLLM(reply: "sorry, no json"))
        let result = await s.suggest(for: "Kubernetes")
        #expect(result == s.instant(for: "Kubernetes"))
        let nilResult = await VariantSuggester(checker: checker, llm: MockLLM(reply: nil)).suggest(for: "Kubernetes")
        #expect(nilResult == s.instant(for: "Kubernetes"))
    }

    @Test func testMultiWordVariantOfCommonWordsIsRejected() async {
        let common = SetCommonWordChecker([.ru: ["дом", "кот"], .en: ["home", "cat"]])
        let llm = MockLLM(reply: #"{"ru":["дом кот","дом котлин"],"en":["home cat","home catlin"]}"#)
        let result = await VariantSuggester(checker: common, llm: llm).suggest(for: "Zzyzx")
        #expect(result[.ru]?.contains("дом кот") == false)
        #expect(result[.ru]?.contains("дом котлин") == true)
        #expect(result[.en] == ["home catlin"])
        // Путь наборов не меняется: многословный вариант из обычных слов там допустим.
        #expect(VariantRules.accepted("дом кот", spelling: "Zzyzx", language: .ru, checker: common) == "дом кот")
    }

    @Test func testCyrillicSpellingDropsEnglishVariants() async {
        let llm = MockLLM(reply: #"{"ru":["галосок"],"en":["golosok"]}"#)
        let result = await VariantSuggester(checker: SetCommonWordChecker([:]), llm: llm).suggest(for: "Голосок")
        #expect(result[.en] == nil)
        #expect(result[.ru] == ["галосок"])
    }
}

extension SharedSettingsSuites {
    @MainActor struct VariantLLMAvailabilityTests {
        @Test func testNoLLMWhenModelNotLoaded() {
            let settings = VoiceIntelligenceSettings.shared
            let engine = settings.engine
            defer { settings.engine = engine }

            settings.engine = .airGapped
            #expect(VariantSuggester.currentLLM() == nil)

            let store = AIProviderStore.shared
            let baseURL = store.baseURL
            defer { store.baseURL = baseURL }
            store.baseURL = ""
            settings.engine = .external
            #expect(VariantSuggester.currentLLM() == nil)
        }
    }
}
