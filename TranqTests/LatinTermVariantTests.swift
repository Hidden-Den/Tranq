import Testing
import Foundation
@testable import Tranq

/// Латинский термин, который распознаватель записал с ошибкой, модель вправе дописать правильно:
/// регистр, дефис и пробел не делают термин новым, одна буква на восемь тоже. Случаи из замера
/// 23.11.2026 на 95 диктовках. Выдумка, непохожая ни на одно слово речи, по-прежнему отклоняется.
struct LatinTermVariantTests {

    @Test func hyphenAndCaseDoNotMakeNewTerm() {
        let input = "Вот эта история куда сложнее организовать на lang-flow, это не то, для чего Lang Flow создавался"
        let output = "Эта история куда сложнее организовать на LangFlow, это не то, для чего LangFlow создавался"
        #expect(GroundingValidator.validate(input: input, output: output, level: .clean) == .valid(sanitizedText: output))
    }

    @Test func spacedTermKeepsWhenJoined() {
        // Обратное направление: термин речи «lang-flow» дожил до результата как «Lang Flow»
        let input = "Вот эта история куда сложнее организовать на lang-flow, ну реально сложнее"
        let output = "Эта история куда сложнее организовать на Lang Flow, реально сложнее"
        #expect(GroundingValidator.validate(input: input, output: output, level: .clean) == .valid(sanitizedText: output))
    }

    @Test func oneLetterSlipInLongTermIsCorrection() {
        let input = "И это вполне себе то, что делается с помощью land flow, ну в принципе"
        let output = "Это вполне то, что делается с помощью Langflow"
        #expect(GroundingValidator.validate(input: input, output: output, level: .clean) == .valid(sanitizedText: output))
    }

    @Test func misheardTermSplitIntoWords() {
        let input = "Закинь Pullequest Flack на ревью, ну, сегодня надо"
        let output = "Закинь pull request Flack на ревью, сегодня надо"
        let result = GroundingValidator.validate(input: input, output: output, level: .clean)
        #expect(result == .valid(sanitizedText: output), "\(result)")
    }

    @Test func inventedTermIsStillRejected() {
        // «main» не похож ни на одно слово речи: это выдумка модели
        let input = "Проверь, что Stanging собирается, ну и UA тоже"
        let output = "Проверь, что staging собирается из main, и UA тоже"
        guard case .rejected(let reason) = GroundingValidator.validate(input: input, output: output, level: .clean) else {
            Issue.record("main должен отклоняться"); return
        }
        #expect(reason.contains("main"))
    }

    /// 25.11.2026 название сверяется целиком по звучанию: «cload fla» звучит как Claude Flow,
    /// и раньше верная догадка модели уходила в отказ. Далёкая догадка по-прежнему отказ.
    @Test func farGuessIsStillRejected() {
        let spoken = "Полностью удали скиллы cload fla, ну все"
        let named = "Полностью удали скиллы Claude Flow"
        #expect(GroundingValidator.validate(input: spoken, output: named, level: .clean) == .valid(sanitizedText: named))

        let input = "Полностью удали скиллы клоуна, ну все"
        guard case .rejected = GroundingValidator.validate(input: input, output: named, level: .clean) else {
            Issue.record("Claude Flow без опоры в речи должен отклоняться"); return
        }
    }

    @Test func shortTermNeedsExactSpelling() {
        // В коротком термине одна буква меняет смысл: CI не становится CD
        let input = "Настрой ну CI на воркерах"
        let output = "Настрой CD на воркерах"
        guard case .rejected = GroundingValidator.validate(input: input, output: output, level: .clean) else {
            Issue.record("CD вместо CI должен отклоняться"); return
        }
    }
}
