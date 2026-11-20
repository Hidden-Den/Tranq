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

    // MARK: - Ответ модели вместо текста

    @Test func refusalInsteadOfTextIsRejected() {
        let angry = "Эти ребята из БТИ совсем обнаглели, чтоб они провалились."
        #expect(!isValid(angry, "Прошу предоставить более корректную форму обращения.", business))
        #expect(!isValid(angry, "К сожалению, я не могу обработать этот текст.", business))
        #expect(!isValid(angry, "Текст содержит оскорбления, перепишите его.", casual))
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
        #expect(isValid("мы не можем дать скидку больше десяти процентов",
                        "К сожалению, мы не можем предоставить скидку больше 10 процентов.", business))
    }

    // MARK: - Потеря темы

    @Test func lostTopicIsRejected() {
        let input = "эти подрядчики опять сорвали сроки по ремонту офиса"
        #expect(!isValid(input, "Благодарю за обращение, вопрос будет рассмотрен в ближайшее время.", business))
    }

    @Test func shortSpeechIsNotCheckedForTopic() {
        #expect(isValid("ок, договорились", "Хорошо, согласовано.", business))
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
