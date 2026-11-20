import Testing
import Foundation
@testable import Tranq

/// Уровень с тоном правила переписывает речь, но не отвечает вместо неё и не теряет тему.
/// Случаи из замера делового тона 20.11.2026.
struct ToneValidatorTests {
    private let business = CleanupLevel.rewrite(tone: RuleTone.business.instruction)
    private let casual = CleanupLevel.rewrite(tone: RuleTone.casual.instruction)

    private func isValid(_ input: String, _ output: String, _ level: CleanupLevel) -> Bool {
        if case .valid = GroundingValidator.validate(input: input, output: output, level: level) { return true }
        return false
    }

    /// Причина отказа: тест проверяет именно ту проверку, ради которой написан.
    private func reason(_ input: String, _ output: String, _ level: CleanupLevel) -> String {
        if case .rejected(let reason) = GroundingValidator.validate(input: input, output: output, level: level) { return reason }
        return "принято"
    }

    // MARK: - Ответ модели вместо текста

    @Test func refusalInsteadOfTextIsRejected() {
        // Тема и термины речи на месте: отклонить может только признак отказа
        let angry = "Эти подрядчики совсем обнаглели, опять сорвали ремонт, чтоб они провалились."
        let refusals: [(String, CleanupLevel)] = [
            ("Подрядчики сорвали ремонт. Прошу предоставить более корректную форму обращения.", business),
            ("К сожалению, я не могу обработать текст про подрядчиков и ремонт.", business),
            ("Текст содержит оскорбления подрядчиков, ремонт упомянут грубо.", casual),
        ]
        for (output, level) in refusals {
            #expect(reason(angry, output, level).hasPrefix("Модель ответила вместо переписанной речи"), "\(output)")
        }
    }

    /// Ревью PR 19: общий отказ на короткую просьбу, где тему не сверить.
    @Test func genericRefusalOnShortRequestIsRejected() {
        let input = "Пришли мне отчёт завтра."
        for output in ["Не могу помочь с этим запросом.", "Не могу ответить на ваш запрос.", "Не могу выполнить эту просьбу."] {
            #expect(reason(input, output, business).hasPrefix("Модель ответила вместо переписанной речи"), "\(output)")
        }
    }

    @Test func talkAboutTheTaskIsRejected() {
        let input = "ну короче скинь мне отчёт по продажам до пятницы"
        #expect(!isValid(input, "Вот переписанный текст в деловом тоне: пришлите отчёт по продажам до пятницы.", business))
        #expect(!isValid(input, "Расшифровка не содержит текста для обработки.", business))
    }

    @Test func wordsFromSpeechAreNotMeta() {
        // «не могу» сказал сам говорящий: это не отказ модели
        let input = "я не могу прийти на встречу в четверг, давай перенесём"
        #expect(isValid(input, "Не могу прийти на встречу в четверг, предлагаю её перенести.", business))
    }

    /// Ложные отказы из повтора замера: деловые слова, а не разговор модели о задаче.
    @Test func businessWordsAreNotMeta() {
        #expect(isValid("даже не представляю, в каком случае нужна прямая диктовка",
                        "Не могу представить, в каком случае нужна прямая диктовка.", business))
        #expect(isValid("деловой стиль должен убирать матерные слова и ругательства",
                        "Деловой стиль должен убирать нецензурную лексику и ругательства.", business))
        #expect(isValid("напиши заготовки, я их надиктую, используя деловой стиль",
                        "Подготовьте заготовки, я надиктую их в деловом тоне.", business))
        #expect(isValid("ты диктуешь, а слова по ходу меняются и смысл фразы поправляется",
                        "При диктовке слова по ходу переформулируются, и смысл фразы корректируется.", business))
        #expect(isValid("я с ними больше работать не буду, они опять сорвали сроки",
                        "Они снова сорвали сроки. Дальнейшее сотрудничество с ними я не буду продолжать.", business))
        #expect(isValid("я без понятия, что ответить клиенту по срокам поставки",
                        "Не могу ответить клиенту по срокам поставки.", business))
        #expect(isValid("мы не можем дать скидку больше десяти процентов",
                        "К сожалению, мы не можем предоставить скидку больше 10 процентов.", business))
    }

    // MARK: - Письмо адресату вместо поручения

    /// Замер 20.11.2026: haiku во всех вариантах промпта писала само письмо Андрею.
    @Test func letterToAddresseeInsteadOfRequestIsRejected() {
        let input = "Слушай, напиши Андрею, что встреча переносится, и спроси, удобно ли ему во вторник."
        #expect(!isValid(input, "Андрей, встреча переносится. Удобно ли вам во вторник?", business))
        #expect(!isValid(input, "Андрей, здравствуйте! Встреча переносится. Удобно ли вам во вторник?", business))
        #expect(!isValid(input, "Добрый день, Андрей! Встреча переносится. Удобно ли вам во вторник?", business))
        #expect(!isValid("передай Свете, что отчёт готов", "Света, отчёт готов.", casual))
    }

    @Test func requestToAddresseeStaysValid() {
        let input = "Слушай, напиши Андрею, что встреча переносится, и спроси, удобно ли ему во вторник."
        #expect(isValid(input, "Напишите Андрею, что встреча переносится, и уточните, удобно ли ему во вторник.", business))
        // Обращение к адресату сказал сам говорящий
        #expect(isValid("Андрей, напиши Свете, что встреча переносится", "Андрей, напишите Свете, что встреча переносится.", business))
    }

    // MARK: - Потеря темы

    @Test func lostTopicIsRejected() {
        let input = "эти подрядчики опять сорвали сроки по ремонту офиса"
        #expect(reason(input, "Вопрос будет рассмотрен в ближайшее время ответственным специалистом.", business)
            .hasPrefix("Модель ушла от темы речи"))
    }

    @Test func letterWithLineBreakIsRejected() {
        let input = "Слушай, напиши Андрею, что встреча переносится, и спроси, удобно ли ему во вторник."
        #expect(!isValid(input, "Андрей,\nвстреча переносится. Удобно ли вам во вторник?", business))
    }

    @Test func shortSpeechIsNotCheckedForTopic() {
        #expect(isValid("ок, договорились", "Хорошо, согласовано.", business))
        // Замер 50 деловых диктовок: короткую фразу деловой тон переписывает целиком
        #expect(isValid("Спасибо огромное, вы нас очень выручили.", "Благодарю за помощь.", business))
        #expect(isValid("Да ну нахер, опять переделывать.", "Необходимо повторно выполнять доработки.", business))
    }

    @Test func businessRewritesKeepTheirTopic() {
        let cases: [(String, String)] = [
            ("Какого хрена они до сих пор не провели счёт? Это уже бесит.",
             "Почему до сих пор не проведён счёт? Это уже неприемлемо."),
            ("Товар пришёл битый. Уже второй раз. Верните деньги или замените партию.",
             "Товар пришёл повреждённым второй раз подряд. Прошу вернуть деньги или заменить партию."),
            ("Ну, отлично, просто прекрасно. Опять всё сломали перед релизом, молодцы.",
             "Перед релизом снова всё сломалось, и это крайне огорчает."),
            ("Не знаю, эта игра дерьмо какое-то, вообще невозможно играть.",
             "Эта игра совершенно непригодна для игры."),
            ("Да пошли они, я не буду это подписывать.", "Я не буду это подписывать."),
            ("Эти ребята из BTC совсем дебилы. Как можно вообще с ними общаться?",
             "Эти ребята из BTC совершенно не понимают, как вести диалог. Как с ними общаться?"),
        ]
        for (input, output) in cases {
            #expect(isValid(input, output, business), "\(output)")
        }
    }

    // MARK: - Придуманные пожелания от первого лица

    @Test func inventedFirstPersonWishIsRejected() {
        let input = "Эти ребята из БТИ совсем обнаглели, чтоб они провалились."
        #expect(!isValid(input, "Сотрудники БТИ ведут себя непрофессионально, и я хотел бы, чтобы этот вопрос был решён.", business))
        #expect(!isValid("скинь отчёт до пятницы", "Пришлите отчёт до пятницы. Буду признателен за оперативность.", business))
        #expect(!isValid("скинь отчёт до пятницы", "Пришлите отчёт до пятницы. С уважением.", business))
    }

    @Test func requestFromSpeechMayBecomePolite() {
        #expect(isValid("Верните деньги или замените партию.", "Прошу вернуть деньги или заменить партию.", business))
        #expect(isValid("я бы хотел перенести встречу на четверг", "Хотел бы перенести встречу на четверг.", business))
    }

    // MARK: - Русские аббревиатуры

    @Test func russianAbbreviationMustSurvive() {
        let input = "документы из БТИ так и не пришли, без них регистрацию не примут"
        #expect(!isValid(input, "Документы так и не пришли, без них регистрацию не примут.", .clean))
        #expect(!isValid(input, "Документы так и не поступили, без них регистрацию не примут.", business))
        #expect(isValid(input, "Документы из БТИ так и не поступили, без них регистрацию не примут.", business))
    }

    @Test func longAbbreviationMustSurvive() {
        #expect(!isValid("данные из РОССТАТ за прошлый год не сходятся", "Данные за прошлый год не сходятся.", .clean))
    }

    /// Первые буквы случайных слов не раскрытие: «надо дать скидку» не НДС.
    @Test func randomWordsAreNotAnExpansion() {
        let input = "заложи НДС в смету, а клиенту надо дать скидку"
        #expect(!isValid(input, "Заложи в смету, а клиенту надо дать скидку.", .clean))
    }

    @Test func expandedAbbreviationSurvives() {
        let input = "Нужно подготовить ТЗ для нового модуля и заложить НДС в смету."
        #expect(isValid(input, "Необходимо подготовить техническое задание для нового модуля и учесть НДС в смете.", business))
        #expect(!isValid(input, "Необходимо подготовить задание для нового модуля и учесть НДС в смете.", business))
    }

    @Test func retractedRussianAbbreviationMayBeDropped() {
        #expect(isValid("заложи в смету НДС, точнее НДФЛ, на всю сумму", "Заложи в смету НДФЛ на всю сумму.", .clean))
    }

    @Test func capitalizedWordIsNotAnAbbreviation() {
        // Одна заглавная буква в начале слова не аббревиатура
        #expect(isValid("Ну Андрей сказал что всё готово", "Андрей сказал, что всё готово.", .clean))
    }
}
