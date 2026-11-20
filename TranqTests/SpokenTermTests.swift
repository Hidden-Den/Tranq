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
}
