import Testing
import Foundation
@testable import Golosok

/// Проверка ответа модели по уровням очистки: повторы мыслей можно сжимать, факты и термины защищены.
struct LevelValidatorTests {
    private let meeting = "Слушай, ну короче, я тут подумал, что нам надо перенести встречу, ну то есть встречу с клиентом, на четверг, потому что в среду я не успеваю, ну не успею подготовить презентацию, короче давай на четверг перенесём"

    @Test func cleanAcceptsCondensedRepetition() {
        let out = "Давай перенесём встречу с клиентом на четверг: в среду я не успею подготовить презентацию"
        #expect(GroundingValidator.validate(input: meeting, output: out, level: .clean) == .valid(sanitizedText: out))
    }

    @Test func cleanRejectsDroppedNumber() {
        let result = GroundingValidator.validate(
            input: "перенесём встречу на 15 часов, ну на 15 часов в четверг",
            output: "Перенесём встречу на четверг", level: .clean
        )
        guard case .rejected = result else { Issue.record("\(result)"); return }
    }

    @Test func cleanRejectsNewLatinTerm() {
        let result = GroundingValidator.validate(
            input: "закинь ну короче в CRM карточку клиента", output: "Закинь в Jira карточку клиента", level: .clean
        )
        guard case .rejected = result else { Issue.record("\(result)"); return }
    }

    @Test func cleanRejectsDroppedLatinTerm() {
        let result = GroundingValidator.validate(
            input: "закинь ну короче в CRM карточку клиента", output: "Закинь карточку клиента", level: .clean
        )
        guard case .rejected = result else { Issue.record("потеря CRM должна отклоняться: \(result)"); return }
    }

    @Test func rewriteRejectsDroppedLatinTerm() {
        let result = GroundingValidator.validate(
            input: "закинь ну короче в CRM карточку клиента", output: "Прошу добавить карточку клиента", level: .rewrite(tone: "деловой")
        )
        guard case .rejected = result else { Issue.record("потеря CRM должна отклоняться: \(result)"); return }
    }

    @Test func latinTermKeptInAnyCaseIsAccepted() {
        let out = "Закинь в crm карточку клиента"
        #expect(GroundingValidator.validate(input: "закинь ну короче в CRM карточку клиента", output: out, level: .clean) == .valid(sanitizedText: out))
    }

    @Test func cleanRejectsGrowthOverLimit() {
        let input = "давай короче перенесём встречу на четверг"
        let output = "Давай перенесём встречу на четверг, потому что так будет удобнее всем участникам команды"
        guard case .rejected = GroundingValidator.validate(input: input, output: output, level: .clean) else {
            Issue.record("рост текста должен отклоняться"); return
        }
    }

    @Test func cleanLimitIsTwentyPercentOverSpeech() {
        let input = "давай завтра в офисе соберёмся утром обсудим план релиза проверим тесты и распределим задачи между всеми членами нашей команды сегодня вечером"
        let words = input.split(separator: " ").map(String.init)
        #expect(words.count == 21)
        let within = input + " " + words.prefix(4).joined(separator: " ")
        let over = input + " " + words.prefix(5).joined(separator: " ")
        #expect(GroundingValidator.validate(input: input, output: within, level: .clean) == .valid(sanitizedText: within))
        guard case .rejected = GroundingValidator.validate(input: input, output: over, level: .clean) else {
            Issue.record("26 слов на входе из 21 выходят за предел"); return
        }
    }

    @Test func rewriteAllowsNewToneWords() {
        let out = "Добрый день! Предлагаю перенести встречу с клиентом на четверг, так как к среде не успею подготовить презентацию."
        #expect(GroundingValidator.validate(input: meeting, output: out, level: .rewrite(tone: "деловой")) == .valid(sanitizedText: out))
    }

    @Test func promptAllowsStructureButNoNewNumbers() {
        let ok = "Помоги составить сообщение клиенту о переносе встречи со среды на четверг. Причина: не успеваю подготовить презентацию."
        #expect(GroundingValidator.validate(input: meeting, output: ok, level: .prompt) == .valid(sanitizedText: ok))
        guard case .rejected = GroundingValidator.validate(input: meeting, output: ok + " Уложись в 100 слов.", level: .prompt) else {
            Issue.record("новое число в промпте"); return
        }
    }

    @Test func verbatimIsNotValidated() {
        #expect(GroundingValidator.validate(input: "а", output: "что угодно 42", level: .verbatim) == .valid(sanitizedText: "что угодно 42"))
    }
}
