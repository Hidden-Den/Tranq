import Testing
import Foundation
@testable import Golosok

/// Повторы слов через точку и вызов модели без слов-паразитов.
struct PrefilterRepeatTests {
    @Test func collapsesRepeatAcrossPeriod() {
        #expect(DisfluencyPrefilter.filter("Deploy. Deploy.") == "Deploy.")
        #expect(DisfluencyPrefilter.filter("Деплой. Деплой. Готово.") == "Деплой. Готово.")
        #expect(DisfluencyPrefilter.filter("Да. Да. Да.") == "Да.")
    }

    @Test func keepsDistinctSentences() {
        #expect(DisfluencyPrefilter.filter("Готово. Проверь.") == "Готово. Проверь.")
    }

    @Test func keepsRepeatThatEndsALongerSentence() {
        #expect(DisfluencyPrefilter.filter("Это сделал он. Он сказал.") == "Это сделал он. Он сказал.")
    }

    @Test func keepsOneWordSentenceBeforeLongerOne() {
        #expect(DisfluencyPrefilter.filter("Иван. Иван Петров пришёл.") == "Иван. Иван Петров пришёл.")
        #expect(DisfluencyPrefilter.filter("Москва. Москва-сити.") == "Москва. Москва-сити.")
    }

    @Test func collapsesRepeatFollowedByComma() {
        #expect(DisfluencyPrefilter.filter("Да. Да, конечно.") == "Да, конечно.")
    }

    @Test func collapsesRepeatAfterSeveralSpaces() {
        #expect(DisfluencyPrefilter.filter("Готово.  Деплой. Деплой.") == "Готово. Деплой.")
    }

    @Test func cleanCallsModelWithoutFillers() async {
        let stub = StubBackend(reply: "Давай перенесём встречу на четверг")
        _ = await ThoughtSynthesizer.shared.clean(
            "давай перенесём встречу на четверг давай на четверг", level: .clean,
            targetBundleId: nil, firedSpellings: [], language: .ru, backend: stub
        )
        #expect(stub.calls == 1)
        #expect(stub.lastUser == ThoughtSynthesizer.stageOne("давай перенесём встречу на четверг давай на четверг"))
    }
}
