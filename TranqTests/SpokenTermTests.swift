import Testing
@testable import Tranq

/// Латинский термин, который модель записала вместо русского звучания.
///
/// Промпт велит писать термины латиницей, а валидатор отклонял любую латиницу, которой
/// не было в речи и нет в словаре: модель наказывали за выполнение инструкции.
/// Замер 20.11.2026: «в Джиминай... не в Джименна, а в антигравити» стало «в Gemini...
/// не Gemini, а Antigravity», и кусок отклонён как выдумка.
struct SpokenTermTests {
    private func validate(_ input: String, _ output: String) -> ValidationResult {
        GroundingValidator.validate(input: input, output: output, level: .clean)
    }

    /// Ревью PR 18: у короткого термина скелет из двух согласных, «раг» и RAG.
    /// Такой принимается только при точном совпадении написания.
    @Test func shortTermWithExactSpellingIsAccepted() {
        #expect(GroundingValidator.soundsSpoken("RAG", words: ["раг"]))
        #expect(!GroundingValidator.soundsSpoken("RAG", words: ["рог"]))
    }

    @Test func termWrittenFromItsRussianSoundIsAccepted() {
        #expect(validate("Расскажи про линиар и как его настроить", "Расскажи про Linear и как его настроить")
                == .valid(sanitizedText: "Расскажи про Linear и как его настроить"))
    }

    /// Мягкое g: Gemini читается «джемини», а скелет согласных у буквы g твёрдый.
    @Test func softGTermIsAccepted() {
        #expect(validate("Короче в Джиминай есть такая функция", "В Gemini есть такая функция")
                == .valid(sanitizedText: "В Gemini есть такая функция"))
    }

    @Test func longTermIsAccepted() {
        #expect(validate("Ну в антигравити встроена такая штука", "В Antigravity встроена такая штука")
                == .valid(sanitizedText: "В Antigravity встроена такая штука"))
    }

    /// Распознаватель исказил слово: «Линяр» звучит иначе, но скелет тот же.
    @Test func distortedSpellingIsAccepted() {
        #expect(validate("Все таски бы через Линяр вёл", "Все таски бы через Linear вёл")
                == .valid(sanitizedText: "Все таски бы через Linear вёл"))
    }

    /// Выдуманный термин, которого не было в речи ни в каком виде, по-прежнему отказ.
    @Test func inventedTermIsStillRejected() {
        guard case .rejected(let reason) = validate("Надо поправить кнопку в настройках", "Надо поправить кнопку в настройках Kubernetes") else {
            Issue.record("выдуманный термин принят"); return
        }
        #expect(reason.contains("Kubernetes"))
    }

    /// Совпал один скелет согласных: «камень» и Gemini оба дают к-м-н, но пишутся непохоже.
    /// Одного скелета мало, иначе модель могла бы выдать любой термин за любое слово.
    @Test func sameSkeletonWithDifferentLettersIsRejected() {
        guard case .rejected = validate("На дороге лежал большой камень", "На дороге лежал большой Gemini") else {
            Issue.record("термин принят за случайное совпадение скелета"); return
        }
    }

    // MARK: - Названия из нескольких слов и исправленные термины

    private func accepts(_ input: String, _ output: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = validate(input, output)
        #expect(result == .valid(sanitizedText: output), "\(input) → \(output): \(result)", sourceLocation: sourceLocation)
    }

    /// Замер 25.11.2026: модель верно восстановила название, а валидатор сверял слова поодиночке.
    @Test func multiWordNameFromTwoSpokenWordsIsAccepted() {
        accepts("Запушь ветку на гид хоп и открой пул реквест.", "Запушь ветку на git hub и открой pull request.")
        accepts("В тест Флейт отправил новую сборку.", "В TestFlight отправил новую сборку.")
        accepts("Хаф Лайф 3 так и не вышла.", "Half-Life 3 так и не вышла.")
        accepts("Ну у меня антигравити открыт", "У меня Anti Gravity открыт")
    }

    @Test func nameWithServiceWordIsAccepted() {
        accepts("Лига Легенд на мобилках называется Wild Rift.", "League of Legends на мобилках называется Wild Rift.")
        accepts("я десять лет играл в ворлд оф варкрафт", "Я десять лет играл в World of Warcraft")
    }

    /// Распознаватель записал часть названия латиницей с ошибкой, модель исправила всё название.
    @Test func correctedLatinPartOfNameIsNotLost() {
        accepts("Спроси у чат GPT, он быстро ответит.", "Спроси у ChatGPT, он быстро ответит.")
        accepts("Таблицу сделай в Google Shits, а не в Excel.", "Таблицу сделай в Google Sheets, а не в Excel.")
        accepts("Созвон будет в Zoom Google Mid.", "Созвон будет в Zoom Google Meet.")
        accepts("Купил Steam Deck, теперь играю в Baldurs Gade в метро.", "Купил Steam Deck, теперь играю в Baldur's Gate в метро.")
        accepts("Пиши задачи в liner", "Пиши задачи в Linear")
    }

    /// Английские буквы, которых нет в русском звучании: c читается к, w читается в, tion читается шн.
    @Test func englishSpellingRulesAreApplied() {
        accepts("Взяли в аренду Toyota Камри на неделю.", "Взяли в аренду Toyota Camry на неделю.")
        accepts("покемоны на свиче опять тормозят", "Покемоны на Switch опять тормозят")
        accepts("Спека лежит в наушен, глянь", "Спека лежит в Notion, глянь")
        accepts("ну clod лучше пишет код", "Claude лучше пишет код")
    }

    /// Сверка по звучанию не пропускает название, которого в речи не было.
    @Test func multiWordNameNotSpokenIsRejected() {
        guard case .rejected = validate("Вчера посмотрел хороший сериал", "Вчера посмотрел Breaking Bad") else {
            Issue.record("название без опоры в речи принято"); return
        }
        guard case .rejected = validate("Купил новую клавиатуру", "Купил новую клавиатуру Logitech") else {
            Issue.record("бренд без опоры в речи принят"); return
        }
    }

    /// Пропавший латинский термин без похожей замены по-прежнему отказ.
    @Test func droppedLatinTermWithoutReplacementIsRejected() {
        guard case .rejected = validate("Созвон будет в Zoom в пять", "Созвон будет в пять") else {
            Issue.record("пропажа Zoom принята"); return
        }
    }

    /// Короткие названия и русские окончания: «на Арк», «на хайку», «в Тредах».
    @Test func shortAndInflectedNamesAreAccepted() {
        accepts("Перешёл с Хрома на Арк, потом обратно.", "Перешёл с Хрома на Arc, потом обратно.")
        accepts("Антропик снизили цены на хайку.", "Anthropic снизили цены на Haiku.")
        accepts("В Тредах сейчас пишут больше, чем в Твиттере.", "В Threads сейчас пишут больше, чем в Twitter.")
    }

    /// Совпадение букв нужно полное: «арка» не Arc, а случайное слово не Haiku.
    @Test func shortNameNeedsExactSound() {
        guard case .rejected = validate("Мы прошли под аркой", "Мы прошли под Arc") else {
            Issue.record("короткий термин принят за другое слово"); return
        }
        guard case .rejected = validate("Купили хурму на рынке", "Купили Haiku на рынке") else {
            Issue.record("Haiku принят без опоры в речи"); return
        }
    }

    /// Живая диктовка 25.11.2026: «задеплой фичу на staging» распознано как «The Dieplay Fitun Astaging».
    /// Целиком «Debian Vite staging» звучит похоже, но два слова из трёх модель придумала.
    @Test func nameWithSeveralInventedWordsIsRejected() {
        guard case .rejected = validate("The Dieplay Fitun Astaging, прогони тесты в CI.", "Debian Vite staging, прогони тесты в CI.") else {
            Issue.record("придуманные слова приняты внутри похожего названия"); return
        }
    }
}
