import Testing
import Foundation
@testable import Tranq

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

    @Test func verbatimIsNotValidated() {
        #expect(GroundingValidator.validate(input: "а", output: "что угодно 42", level: .verbatim) == .valid(sanitizedText: "что угодно 42"))
    }

    // MARK: - Ложные отказы из замера 17 ноября 2026

    @Test func numberCorrectedBySpeakerMayBeDropped() {
        #expect(isValid("Скидка 10 процентов, нет, 15, мы так договорились.", "Скидка 15 процентов, мы так договорились."))
        #expect(isValid("Бронируй зал на 10 человек, ой, на 12.", "Бронируй зал на 12 человек."))
        #expect(isValid("Перенесли уже 3 сервиса из 5, ой, нет, 4 из 5.", "Перенесли уже 4 сервиса из 5."))
        #expect(isValid("Корпоратив в 7 вечера, ну, в 19:00.", "Корпоратив в 19:00."))
    }

    @Test func numberDroppedWithoutCorrectionIsRejected() {
        #expect(!isValid("Бюджет 500 и 600 на рекламу.", "Бюджет 600 на рекламу."))
        #expect(!isValid("Скидка 10 процентов.", "Скидка 15 процентов."))
        #expect(!isValid("Скидка 10 процентов, нет, 15.", "Скидка 10 процентов."))
        #expect(!isValid("У нас есть 3 варианта, есть 4 идеи.", "У нас есть 4 идеи."))
        #expect(isValid("Отправим 5, то есть 6 коробок.", "Отправим 6 коробок."))
    }

    @Test func numberAtSentenceEndIsChecked() {
        #expect(!isValid("Рост 7,3% за квартал.", "Рост 7% за квартал."))
        #expect(!isValid("Совещание в 9:45.", "Совещание в 9:30."))
    }

    @Test func countWordsMatchDigitsButOrdinalsDoNot() {
        #expect(isValid("Встреча на третьем этаже, ой, на четвёртом, в большой переговорке.", "Встреча на четвёртом этаже, в большой переговорке."))
        // Порядковое не равно количественному: «вторую» не превращается в «двух»
        #expect(!isValid("Я бы взял вторую кандидатку, Елену.", "Я бы взял двух кандидаток, Елену."))
        #expect(isValid("Из них 3 прошли в финал.", "Из них трое прошли в финал."))
        #expect(isValid("Я нашёл 2 поставщиков.", "Я нашёл двух поставщиков."))
    }

    @Test func timeIsOneNumber() {
        #expect(isValid("Созвон в 12, извини.", "Созвон в 12:00."))
        #expect(isValid("Совещание в 9:45, ну, без опозданий.", "Совещание в 9:45, без опозданий."))
        #expect(!isValid("Совещание в 9:45.", "Совещание в 9:30."))
    }

    @Test func fillerKakByIsNotAQuestion() {
        #expect(isValid("Как бы, нам нужно обновить прайс до конца месяца.", "Нам нужно обновить прайс до конца месяца."))
        #expect(isValid("Как бы, ну, я не против, но типа надо спросить у финансов.", "Я не против, но надо спросить у финансов."))
        #expect(!isValid("Как настроить уведомления в телеграме?", "Настройте уведомления в настройках."))
    }

    @Test func numberSignIsNotATerm() {
        #expect(isValid("Поезд в 6 утра, вагон No 9, место 23.", "Поезд в 6 утра, вагон 9, место 23."))
    }

    @Test func chatTemplateTokensAreStripped() {
        #expect(sanitized("Я заберу ноутбук.<|im_end|>") == "Я заберу ноутбук.")
        #expect(sanitized("<|channel|>Я заберу ноутбук.<end_of_turn>") == "Я заберу ноутбук.")
    }

    private let suspects = [TermSuspect(token: "IPI", candidates: ["API", "IPO"])]
    private let terms: Set<String> = ["API", "IPO", "SDK", "Git"]

    private func check(_ input: String, _ output: String, _ suspects: [TermSuspect]) -> ValidationResult {
        GroundingValidator.validate(input: input, output: output, level: .clean, customTerms: terms, termSuspects: suspects)
    }

    @Test func suspectReplacedByCandidateIsValid() {
        let result = check("Настрой IPI ключ для интеграции.", "Настрой API-ключ для интеграции.", suspects)
        #expect(result == .valid(sanitizedText: "Настрой API-ключ для интеграции."))
    }

    @Test func suspectKeptIsStillValid() {
        let result = check("Настрой IPI ключ для интеграции.", "Настрой IPI ключ для интеграции.", suspects)
        #expect(result == .valid(sanitizedText: "Настрой IPI ключ для интеграции."))
    }

    @Test func suspectReplacedByOtherTermIsRejected() {
        guard case .rejected(let reason) = check("Настрой IPI ключ для интеграции.", "Настрой SDK ключ для интеграции.", suspects) else {
            Issue.record("замена не из списка кандидатов принята")
            return
        }
        #expect(reason.hasPrefix("Пропущен исходный термин"))
    }

    @Test func droppedLatinWithoutSuspectIsRejected() {
        guard case .rejected = check("Настрой IPI ключ для интеграции.", "Настрой API-ключ для интеграции.", []) else {
            Issue.record("пропавшая латиница без подсказки принята")
            return
        }
    }

    @Test func cyrillicSuspectReplacedIsValid() {
        let gid = [TermSuspect(token: "ГИД", candidates: ["Git"])]
        let result = check("Подними версию в ГИД и поставь тег релиза.", "Подними версию в Git и поставь тег релиза.", gid)
        #expect(result == .valid(sanitizedText: "Подними версию в Git и поставь тег релиза."))
    }

    @Test func twoWordSuspectReplacedIsValid() {
        let power = [TermSuspect(token: "Power B", candidates: ["Power BI"])]
        let result = GroundingValidator.validate(
            input: "Выгрузи отчёт из Power B в PDF.", output: "Выгрузи отчёт из Power BI в PDF.",
            level: .clean, customTerms: ["Power BI", "PDF"], termSuspects: power
        )
        #expect(result == .valid(sanitizedText: "Выгрузи отчёт из Power BI в PDF."))
    }

    private func isValid(_ input: String, _ output: String) -> Bool {
        if case .valid = GroundingValidator.validate(input: input, output: output, level: .clean) { return true }
        return false
    }

    private func sanitized(_ output: String) -> String? {
        if case .valid(let text) = GroundingValidator.validate(input: "Я заберу ноутбук.", output: output, level: .clean) { return text }
        return nil
    }
}

/// Числа и время при сравнении речи с ответом.
struct TimeNumberTests {
    @Test func timeMinutesKeepOneFormWithSpokenMinutes() {
        #expect(GroundingValidator.normalizedNumbers(in: "встреча в 9:05").map(\.value) == ["9", "5"])
        #expect(GroundingValidator.normalizedNumbers(in: "встреча в 14:30").map(\.value) == ["14", "30"])
    }
}
