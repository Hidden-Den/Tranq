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
        let llm = MockLLM(reply: #"{"ru":["а","б","в","г","д","е","ё","кубик","питон"],"en":["kubernetes","Kubernetes","kuber kuber kuber kuber kuber"]}"#)
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

    @Test func testNoLLMWhenModelNotLoaded() {
        // В тестах локальный сервер не запущен, внешний провайдер по умолчанию не настроен.
        let engine = VoiceIntelligenceSettings.shared.engine
        defer { VoiceIntelligenceSettings.shared.engine = engine }
        VoiceIntelligenceSettings.shared.engine = .airGapped
        #expect(VariantSuggester.currentLLM() == nil)
    }
}
