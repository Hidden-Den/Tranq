import Testing
import Foundation
@testable import Tranq

/// Детерминированный этап 1: этот текст человек получает целиком без модели,
/// и он же уходит модели на вход.
struct StageOneTests {

    // MARK: - Запятая после конца предложения

    /// Паразит после точки снят, его запятая не должна остаться: «кнопкой., тоже».
    @Test func noCommaAfterSentenceEnd() {
        #expect(DisfluencyPrefilter.filter("Нажми другой кнопкой. Э-э, тоже можно.")
            == "Нажми другой кнопкой. Тоже можно.")
        #expect(DisfluencyPrefilter.filter("Работает? Ммм, наверное.") == "Работает? Наверное.")
        #expect(DisfluencyPrefilter.filter("Готово! Ээ, дальше.") == "Готово! Дальше.")
        #expect(DisfluencyPrefilter.filter("Подумаю… Хм, ладно.") == "Подумаю… Ладно.")
    }

    // MARK: - Заглавная после снятого паразита

    /// Паразит в начале предложения снят: предложение начинается с заглавной.
    @Test func capitalizesSentenceAfterRemovedFiller() {
        #expect(DisfluencyPrefilter.filter("Ну. Э-э, тоже можно.") == "Ну. Тоже можно.")
        #expect(DisfluencyPrefilter.filter("Ээ, давай завтра.") == "Давай завтра.")
    }

    /// Там, где префильтр ничего не снял, регистр распознавателя остаётся.
    @Test func keepsRecognizerCaseWhereNothingRemoved() {
        #expect(DisfluencyPrefilter.filter("Готово. iPhone обновлён.") == "Готово. iPhone обновлён.")
        #expect(DisfluencyPrefilter.filter("давай завтра. потом решим.") == "давай завтра. потом решим.")
        #expect(DisfluencyPrefilter.filter("Давай ээ завтра.") == "Давай завтра.")
    }

    // MARK: - Абзацы

    /// Нормализатор чисел не стирает переводы строк.
    @Test func numberNormalizerKeepsNewlines() {
        #expect(NumberNormalizer.normalize("Первый абзац.\n\nВторой абзац.") == "Первый абзац.\n\nВторой абзац.")
        #expect(NumberNormalizer.normalize("Купи пять яблок.\n\nДвадцать пять груш.")
            == "Купи 5 яблок.\n\n25 груш.")
    }

    /// Длинная диктовка после этапа 1 разбита на абзацы.
    @Test func stageOneKeepsParagraphs() {
        let speech = (1...9).map { "Предложение номер \($0) про настройки экрана." }.joined(separator: " ")
        let result = ThoughtSynthesizer.stageOne(speech)
        #expect(result.components(separatedBy: "\n\n").count == 3)
    }
}
