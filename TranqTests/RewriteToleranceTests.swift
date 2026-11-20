import Testing
@testable import Tranq

/// Что валидатор не должен считать пересказом. Замер 20.11.2026 на 81 диктовке:
/// из 14 отказов «за пересказ» часть была починкой речи, а не новыми словами.
struct RewriteToleranceTests {
    private func validate(_ input: String, _ output: String) -> ValidationResult {
        GroundingValidator.validate(input: input, output: output, level: .clean)
    }

    // MARK: - Словоформы

    /// Модель чинит согласование: «какое окно идёт диктовка» → «в каком окне идёт диктовка».
    /// Это те же слова говорящего в другой форме, а не пересказ.
    @Test func inflectionIsNotANewWord() {
        let output = "Эта штука нужна, чтобы понимать, в каком окне идёт диктовка, нежно-салатовая рамка."
        #expect(validate("Эта штука нужна, чтобы понимать, какое окно идёт диктовка, нежно-салатовый рамка.", output)
                == .valid(sanitizedText: output))
    }

    @Test func sameLexemeAcceptsEndings() {
        #expect(GroundingValidator.sameLexeme("окно", "окне"))
        #expect(GroundingValidator.sameLexeme("каком", "какое"))
        #expect(GroundingValidator.sameLexeme("режима", "режимов"))
        #expect(GroundingValidator.sameLexeme("переключаться", "переключать"))
    }

    /// Короткие слова с разной согласной в конце это разные слова.
    @Test func sameLexemeKeepsShortWordsApart() {
        #expect(!GroundingValidator.sameLexeme("стол", "стоп"))
        #expect(!GroundingValidator.sameLexeme("кот", "кол"))
        #expect(!GroundingValidator.sameLexeme("взять", "ухватить"))
    }

    // MARK: - Числа прописью

    /// «Раз, 2, 3, 4, 5» → «Раз, два, три, четыре, пять»: те же числа, проверка чисел их
    /// уже сравнивает после нормализации, а пересказом они не считаются.
    @Test func spelledOutNumbersAreNotNewWords() {
        let output = "Раз, два, три, четыре, пять. Вышел зайчик погулять."
        #expect(validate("Раз, 2, 3, 4, 5. Вышел зайчик погулять.", output) == .valid(sanitizedText: output))
    }

    // MARK: - Настоящий пересказ

    @Test func realParaphraseIsStillRejected() {
        guard case .rejected(let reason) = validate(
            "Я не могу его взять за край и подвинуть, сделав больше или меньше.",
            "Нельзя ухватить панель за угол и перетащить, изменив размер."
        ) else { Issue.record("пересказ принят"); return }
        #expect(reason.contains("своими словами"))
    }

    // MARK: - Отозванный термин

    /// «какой-нибудь API, ну, не API» — говорящий сам отказался от термина,
    /// и модель убрала его по правилу самоисправления.
    @Test func retractedTermMayBeDropped() {
        let output = "Возможно, стоит поправить системный промпт."
        #expect(validate("Возможно, какой-нибудь API, ну, не API, системный промпт поправить.", output)
                == .valid(sanitizedText: output))
    }

    /// Термин, от которого не отказывались, по-прежнему обязан дожить до результата.
    @Test func termDroppedWithoutRetractionIsStillRejected() {
        guard case .rejected(let reason) = validate("Надо обновить API и проверить ключи доступа.", "Надо обновить и проверить ключи доступа.")
        else { Issue.record("потерянный термин принят"); return }
        #expect(reason.contains("api"))
    }
}
