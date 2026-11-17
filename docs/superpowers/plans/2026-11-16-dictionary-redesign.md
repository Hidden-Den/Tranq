# Новый словарь: план реализации этапов 1–2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить пару «термины + автозамены» единым двуязычным словарём с наборами, ручным добавлением одним словом и 🎙. Выпуск — `v2.2.0`.

**Architecture:** Новый модуль `Golosok/Dictionary/` содержит четыре части:
- неизменяемый индекс `DictionaryIndex` с точной заменой, исправлением регистра и теневой нечёткой заменой;
- хранилище `DictionaryStore` для пользовательских записей, наборов из ресурсов и настроек;
- обучение на правках в истории;
- миграцию из `personalization.json`.

Пайплайн применяет индекс до и после языковой модели. `PersonalizationEngine` и вкладки старого словаря удаляются.

**Tech Stack:** Swift 5, SwiftUI, AppKit `NSSpellChecker`, XCTest и Swift Testing. Тесты запускаются через `xcodebuild`. Наборы хранятся в JSON в синхронизированной группе Xcode.

**Spec:** `docs/superpowers/specs/2026-11-16-dictionary-redesign-design.md`

**Не входит в план:**
- этап 3, обучение на правках в поле через Универсальный доступ;
- этап 4, контекст экрана.

Для них будет отдельный план после прототипа, который проверит, отдают ли приложения значение поля. Оверлей «Запомнил… · Отменить» и строка «Нужен Универсальный доступ» тоже относятся к этапу 3. В этом плане обучение идёт только по правкам в истории приложения и не требует разрешений.

## Global Constraints

- Ветка `feat/dictionary-redesign` от текущей `refactor/core-pipeline`. PR создаётся только по явной просьбе пользователя.
- Языки: только `ru` и `en`. Язык диктовки — `languageCode` активной модели `ModelStore`. GigaAM — `ru`, Whisper `en_turbo` и `en_medium` — `en`.
- Записи наборов в оригинальном написании: названия продуктов, сервисов, компаний, языков программирования, аббревиатуры.
- Обиходные англицизмы в наборы не попадают: спринт, оффер, деплой, онбординг, оффбординг, бэклог, ретро, стендап, дейли, синк, хотфикс, фронтенд, бэкенд, тимлид, продакт, роадмап, питчдек, кастдев.
- Ни один вариант набора или автоподбора не является словарным словом своего языка по `NSSpellChecker`.
- Нечёткая замена только в теневом режиме: пишет в лог и не меняет текст. Порог: длина токена не меньше 6 букв, нормализованное расстояние не больше 0.2, токен не словарный.
- Бюджеты: точная замена и регистр меньше 1 мс на фразу в 100 слов. Теневая нечёткая меньше 5 мс, в фоне. Загрузка наборов меньше 50 мс и меньше 2 МБ.
- Хранение:
  - `dictionary.json` в `AppEnvironment.dataDirectory`, с полем `schemaVersion: 1`;
  - атомарная запись;
  - перед перезаписью копия в `dictionary.backup.json`.
- Обучение:
  - засчитывается на второй одинаковой паре;
  - не больше 5 новых `.learned` в день;
  - `.learned` без срабатываний 60 дней удаляется.
- Интерфейс:
  - без круглых и квадратных скобок в тексте;
  - метки в 1–2 слова, подписи короче 8 слов;
  - все строки и в `ru`, и в `en` в `Golosok/Localizable.xcstrings`, исходный язык `ru`.
- Сбой словаря никогда не ломает диктовку: при ошибке текст отдаётся без замен, в лог пишется `warn`.

## Review Focus

1. **Слово рядом с пунктуацией и в начале предложения:** «Кубер, привет.» должно стать «Kubernetes, привет.» — пунктуация сохраняется, заглавная буква варианта не мешает совпадению. Тест в Task 3.
2. **Многословный вариант, который пересекается с однословным:** «эн восемь эн» и «эн восемь» в одном наборе. Побеждает самый длинный вариант. Тест в Task 3.
3. **Повреждённый `dictionary.json` при наличии резервной копии:** грузится копия, наборы работают, приложение не падает. Тест в Task 5.
4. **Повторный запуск миграции,** например после падения на середине: дублей не появляется. Тест в Task 7.
5. **Смена модели распознавания между диктовками:** русские варианты не срабатывают в английской диктовке, и наоборот. Тест в Task 3.

---

## Структура файлов

| Файл | Ответственность |
|---|---|
| `Golosok/Dictionary/DictionaryModels.swift` | `DictionaryLanguage`, `DictionaryEntry`, `DictionaryPack`, `PackEntry`, `AppliedReplacement` |
| `Golosok/Dictionary/CommonWordChecker.swift` | Протокол проверки «словарное ли слово» и реализация на `NSSpellChecker` с кэшем |
| `Golosok/Dictionary/Phonetics.swift` | Транслитерация латиницы в кириллицу, английский фонетический ключ, нормализованное расстояние |
| `Golosok/Dictionary/DictionaryIndex.swift` | Неизменяемый индекс: точная замена, регистр, словоформы, теневая нечёткая |
| `Golosok/Dictionary/DictionaryStore.swift` | Хранилище, наборы, настройки, подсказка модели, учёт замен по заметкам |
| `Golosok/Dictionary/DictionaryLearning.swift` | Фильтр пар, счётчик, обратные правки, лимиты |
| `Golosok/Dictionary/DictionaryMigration.swift` | Однократный перенос из `personalization.json` и `voice.userTerms` |
| `Golosok/Dictionary/VariantSuggester.swift` | Автоподбор вариантов при ручном добавлении |
| `Golosok/Dictionary/WordProbe.swift` | 🎙: запись, автостоп, распознавание, фильтры |
| `Golosok/Dictionaries/*.json` | 10 наборов |
| `scripts/annotate-dictionaries.swift` | Предвычисление `commonIn` для написаний наборов |
| `Golosok/DictionaryView.swift` | Экран, заменяет `VocabularyView.swift` |
| `Golosok/DictionaryAddWordSheet.swift` | Окно добавления слова с 🎙 |
| `Golosok/DictionaryPackDetailView.swift` | Список слов набора с выключателями |
| `GolosokTests/Dictionary/*.swift` | Тесты модуля |
| `GolosokTests/DictionaryCorpus/*` | Корпуса «не навреди» и «должно исправить» |

Удаляются: `Golosok/PersonalizationEngine.swift`, `Golosok/VocabularyView.swift`, `GolosokTests/PersonalizationEngineTests.swift`.

Команда тестов, далее `TEST`:

```bash
xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests -derivedDataPath build/DerivedData-ci CODE_SIGN_IDENTITY=- 2>&1 | grep -E "error:|failed|passed|\*\* TEST" | tail -30
```

Один класс: добавить `-only-testing:GolosokTests/<ClassName>`.

---

### Task 1: Модели, язык и проверка словарных слов

**Files:**
- Create: `Golosok/Dictionary/DictionaryModels.swift`, `Golosok/Dictionary/CommonWordChecker.swift`
- Test: `GolosokTests/Dictionary/DictionaryModelsTests.swift` — с `import AppKit` для `NSSpellChecker`

**Interfaces:**
- Produces:
  - `enum DictionaryLanguage: String, Codable, CaseIterable { case ru, en }`
  - `static var DictionaryLanguage.current: DictionaryLanguage` — из `ModelStore.shared.model(named: activeModelID)?.languageCode`, всё кроме `"en"` даёт `.ru`.
  - `struct DictionaryEntry: Codable, Identifiable, Equatable` с полями:
    - `id: UUID`, `spelling: String`, `variants: [DictionaryLanguage: [String]]`;
    - `source: Source` (`enum Source: String, Codable { case manual, learned }`);
    - `forceCase: Bool`, `createdAt: Date`, `hits: Int`, `lastUsed: Date?`.
  - `struct PackEntry: Codable, Equatable`: `spelling: String`, `variants: [DictionaryLanguage: [String]]`, `commonIn: [DictionaryLanguage]`. Если `commonIn` нет в JSON, декодируется как `[]`.
  - `struct DictionaryPack: Codable, Identifiable`: `id: String`, `title: [DictionaryLanguage: String]`, `version: Int`, `entries: [PackEntry]`.
  - `struct AppliedReplacement: Equatable`: `original: String`, `replacement: String`, `entryKey: String` (`"user/<uuid>"` или `"<packId>/<spelling>"`), `variant: String`, `reason: Reason` (`enum Reason { case variant, caseFix }`).
  - `protocol CommonWordChecking { func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool }`
  - `final class SpellCommonWordChecker: CommonWordChecking`, `static let shared`. Внутри `NSSpellChecker.shared.checkSpelling(of:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:)`, кэш под `NSLock`.
  - `struct SetCommonWordChecker: CommonWordChecking` для тестов, инициализируется `[DictionaryLanguage: Set<String>]`.

- [ ] **Step 1: Создать ветку**

```bash
git checkout -b feat/dictionary-redesign
```

- [ ] **Step 2: Написать падающие тесты**

```swift
func testPackDecodesBilingualVariantsAndDefaultsCommonIn() throws {
    let json = #"{"id":"it","title":{"ru":"IT и разработка","en":"IT & Development"},"version":1,
      "entries":[{"spelling":"Kubernetes","variants":{"ru":["кубер"],"en":["cooper netties"]}}]}"#
    let pack = try JSONDecoder().decode(DictionaryPack.self, from: Data(json.utf8))
    XCTAssertEqual(pack.entries[0].variants[.ru], ["кубер"])
    XCTAssertEqual(pack.entries[0].variants[.en], ["cooper netties"])
    XCTAssertEqual(pack.entries[0].commonIn, [])
    XCTAssertEqual(pack.title[.en], "IT & Development")
}
func testSpellCheckerKnowsCommonWordsInBothLanguages() {
    let c = SpellCommonWordChecker.shared
    XCTAssertTrue(NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("ru") })
    XCTAssertTrue(c.isCommonWord("питон", language: .ru))
    XCTAssertFalse(c.isCommonWord("кубер", language: .ru))
    XCTAssertTrue(c.isCommonWord("slack", language: .en))
    XCTAssertFalse(c.isCommonWord("github", language: .en))
}
```

Важно: словарь в `[DictionaryLanguage: …]` по умолчанию кодируется массивом. Ключи должны кодироваться объектом `{"ru": …}` — для этого `DictionaryLanguage` реализует `CodingKeyRepresentable`.

- [ ] **Step 3: Запустить и убедиться, что падает.** `TEST` с `-only-testing:GolosokTests/DictionaryModelsTests`. Ожидается ошибка компиляции, типов ещё нет.
- [ ] **Step 4: Реализовать типы из Interfaces.**
- [ ] **Step 5: Запустить, ожидается PASS.**
- [ ] **Step 6: Коммит.**

```bash
git add Golosok/Dictionary GolosokTests/Dictionary && git commit -m "feat(dictionary): add bilingual dictionary models and common-word checker"
```

---

### Task 2: Фонетика

**Files:**
- Create: `Golosok/Dictionary/Phonetics.swift`
- Test: `GolosokTests/Dictionary/PhoneticsTests.swift`

**Interfaces:**
- Produces: `enum Phonetics` со статическими функциями:
  - `transliterateToCyrillic(_ latin: String) -> String` — в нижнем регистре, по правилам: `sh→ш`, `ch→ч`, `ck→к`, `zh→ж`, `ts→ц`, `x→кс`, `w→в`, `y→и`, `j→дж`, `c→к`, `q→к`, `ee→и`, `oo→у`, `ph→ф`, `th→т`; цифры и символы удаляются.
  - `englishKey(_ word: String) -> String` — упрощённый Metaphone: гласные кроме первой удаляются, `ph→f`, `ck→k`, `c→k`, `q→k`, `x→ks`, `z→s`, двойные согласные схлопываются.
  - `normalizedDistance(_ a: String, _ b: String) -> Double` — Левенштейн, делённый на `max(a.count, b.count)`; для двух пустых строк `0`.
  - `similarity(token: String, spelling: String, language: DictionaryLanguage) -> Double`. Для `.ru` это `1 - normalizedDistance(token.lowercased(), transliterateToCyrillic(spelling))`. Для `.en` это `1 - normalizedDistance(englishKey(token), englishKey(spelling))`.

- [ ] **Step 1: Написать падающие тесты**

```swift
func testTransliteration() {
    XCTAssertEqual(Phonetics.transliterateToCyrillic("Kubernetes"), "кубернетес")
    XCTAssertEqual(Phonetics.transliterateToCyrillic("Docker"), "докер")
}
func testRussianSimilarityAboveThresholdForTypicalMisrecognition() {
    XCTAssertGreaterThanOrEqual(Phonetics.similarity(token: "кубернетис", spelling: "Kubernetes", language: .ru), 0.8)
    XCTAssertLessThan(Phonetics.similarity(token: "кубик", spelling: "Kubernetes", language: .ru), 0.8)
}
func testEnglishKeyMatchesSoundAlikes() {
    XCTAssertEqual(Phonetics.englishKey("postgress"), Phonetics.englishKey("postgres"))
    XCTAssertLessThan(Phonetics.similarity(token: "kitchen", spelling: "Kubernetes", language: .en), 0.8)
}
func testDistanceEdgeCases() {
    XCTAssertEqual(Phonetics.normalizedDistance("", ""), 0)
    XCTAssertEqual(Phonetics.normalizedDistance("abc", ""), 1)
}
```

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать `Phonetics`.** Таблица транслитерации применяется жадно, сначала диграфы. Двойные одинаковые кириллические буквы на выходе схлопываются.
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): add transliteration and phonetic similarity`.

---

### Task 3: Индекс — точная замена, регистр, словоформы

**Files:**
- Create: `Golosok/Dictionary/DictionaryIndex.swift`
- Test: `GolosokTests/Dictionary/DictionaryIndexTests.swift`

**Interfaces:**
- Consumes: Task 1 и Task 2.
- Produces:
  - `struct DictionaryIndex`:
    - `init(userEntries: [DictionaryEntry], packs: [DictionaryPack], disabledPacks: Set<String>, disabledPackWords: Set<String>, disabledPackVariants: Set<String>, checker: CommonWordChecking)`;
    - `func apply(to text: String, language: DictionaryLanguage) -> (text: String, replacements: [AppliedReplacement])`;
    - `var approvedSpellings: Set<String>` — все действующие написания.
  - Ключи выключения: слова — `"<packId>/<spelling>"`, варианта — `"<packId>/<spelling>/<variant>"`.

Правила, которые задают тесты:

1. Токенизация один раз: слово — непрерывные буквы, цифры, `-`, `.`, `/` внутри слова. Пунктуация вокруг сохраняется.
2. Сопоставление без учёта регистра. Многословные варианты ищутся по первому слову, побеждает самый длинный.
3. Приоритет: пользовательская запись важнее набора. Между наборами решает порядок `packs`.
4. Словоформы, только для `.ru`, если вариант не словарное слово:
   - если написание латиницей или аббревиатурой, заменяется вся словоформа «вариант + окончание»;
   - если написание кириллицей, окончание переносится.

   Окончания: `а у е ом ой ы ов ам ами ах и ю я ей`. Если вариант словарный, срабатывает только точная форма.
5. Регистр, только для `.en`. Токен равен написанию без учёта регистра, написание из одного слова, и одно из двух:
   - язык не входит в `commonIn` пакетной записи, либо у пользовательской записи `!checker.isCommonWord`;
   - или у записи `forceCase`.
6. Используются только варианты языка `language`.
7. Выключенные набор, слово или вариант игнорируются. Пользовательская запись работает, даже если то же слово выключено в наборе.

- [ ] **Step 1: Написать падающие тесты**

```swift
func testExactVariantKeepsPunctuationAndSentenceStart() {
    let r = idx.apply(to: "Кубер, привет.", language: .ru)
    XCTAssertEqual(r.text, "Kubernetes, привет.")
    XCTAssertEqual(r.replacements.first?.reason, .variant)
}
func testLongestMultiwordVariantWins() {
    XCTAssertEqual(idx.apply(to: "поставили эн восемь эн вчера", language: .ru).text, "поставили n8n вчера")
}
func testLatinSpellingSwallowsRussianEnding() {
    XCTAssertEqual(idx.apply(to: "в кубере упал под", language: .ru).text, "в Kubernetes упал под")
}
func testCyrillicSpellingKeepsEnding() {
    // пользовательская запись «Голосок», вариант «голосог»
    XCTAssertEqual(idx.apply(to: "у голосога", language: .ru).text, "у Голосока")
}
func testCommonWordVariantOnlyExactForm() {
    // пользовательская запись Python, вариант «питон», который словарный
    XCTAssertEqual(idx.apply(to: "питон и питона", language: .ru).text, "Python и питона")
}
func testEnglishCaseFix() {
    XCTAssertEqual(idx.apply(to: "push it to github", language: .en).text, "push it to GitHub")
    XCTAssertEqual(idx.apply(to: "cut me some slack", language: .en).text, "cut me some slack")
}
func testForceCaseOverridesCommonWord() { /* пользовательская Slack с forceCase → «on slack» → «on Slack» */ }
func testLanguageIsolation() {
    XCTAssertEqual(idx.apply(to: "кубер", language: .en).text, "кубер")
    XCTAssertEqual(idx.apply(to: "cooper netties", language: .ru).text, "cooper netties")
}
func testUserEntryBeatsPackAndSurvivesDisabledPackWord() { … }
func testDisabledPackAndVariantAreIgnored() { … }
func testExactMatchBudgetUnderOneMillisecond() {
    // индекс из 10 наборов по 100 записей; фраза из 100 слов; медиана 200 прогонов < 0.001 с
}
```

Наборы для тестов задаются в коде маленькими литералами и `SetCommonWordChecker`. Для бюджета — сгенерированные записи.

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать `DictionaryIndex`.** Индекс по языку: `[String: [Candidate]]`, ключ — первое слово варианта в нижнем регистре, кандидаты отсортированы по длине варианта по убыванию. Для словоформ дополнительный ключ — основа без окончания. Для регистра — `[String: Candidate]` по `spelling.lowercased()`.
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): add exact, case and word-form matching index`.

---

### Task 4: Теневая нечёткая замена

**Files:**
- Modify: `Golosok/Dictionary/DictionaryIndex.swift`
- Test: `GolosokTests/Dictionary/DictionaryFuzzyTests.swift`

**Interfaces:**
- Produces:
  - `struct FuzzyHit: Equatable { let token: String; let spelling: String; let similarity: Double }`
  - `func DictionaryIndex.fuzzyHits(in text: String, language: DictionaryLanguage) -> [FuzzyHit]`

  Кандидат должен выполнить все условия:
  - токен не меньше 6 букв;
  - токен не заменён точно;
  - `!checker.isCommonWord(token)`;
  - `similarity >= 0.8`.

  Сравнение идёт только с написаниями из группы: та же первая буква фонетического ключа и длина ±3.

- [ ] **Step 1: Падающие тесты**

```swift
func testFuzzyFindsUnlistedMisrecognition() {
    XCTAssertEqual(idx.fuzzyHits(in: "развернули кубернетас", language: .ru).map(\.spelling), ["Kubernetes"])
}
func testFuzzySkipsShortAndCommonWords() {
    XCTAssertTrue(idx.fuzzyHits(in: "кубик и комната", language: .ru).isEmpty)
}
func testFuzzyBudgetUnderFiveMilliseconds() { /* 1000 записей, 100 слов, медиана < 0.005 с */ }
```

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать `fuzzyHits`.** Группы строятся в `init`.
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): add shadow fuzzy matching`.

---

### Task 5: Хранилище

**Files:**
- Create: `Golosok/Dictionary/DictionaryStore.swift`
- Test: `GolosokTests/Dictionary/DictionaryStoreTests.swift`. Это Swift Testing внутри `SharedSettingsSuites`, потому что меняется общий `AppEnvironment.defaults`.

**Interfaces:**
- Consumes: Task 1, Task 3.
- Produces: `final class DictionaryStore: ObservableObject`.
  - Создание:
    - `static let shared`;
    - `init(directory: URL, defaults: UserDefaults, packsBundle: Bundle, checker: CommonWordChecking)`, `shared` использует `AppEnvironment` и `Bundle.main`.
  - Опубликованные данные:
    - `userEntries: [DictionaryEntry]`, `packs: [DictionaryPack]`;
    - `disabledPacks`, `disabledPackWords`, `disabledPackVariants: Set<String>`;
    - `learningEnabled: Bool`, по умолчанию `true`, ключ `dictionary.learningEnabled`.
  - Запись:
    - `addEntry(spelling: String, variants: [DictionaryLanguage: [String]], source: DictionaryEntry.Source) -> DictionaryEntry` — если такое написание уже есть, без учёта регистра, варианты объединяются;
    - `updateEntry(_:)`, `removeEntry(id:)`;
    - `removeVariant(_ variant: String, language:, fromEntryKey: String)` — для пользовательской записи удаляет вариант, а при пустых вариантах и `.learned` удаляет запись; для набора добавляет ключ в `disabledPackVariants`;
    - `setPack(_ id: String, enabled: Bool)`, `setPackWord(_ key: String, enabled: Bool)`;
    - `resetLearned()` — удаляет все `.learned`.
  - Чтение:
    - `var index: DictionaryIndex?` — кэш, `nil` до первой сборки. Пересобирается при изменениях на фоновой очереди, чтение потокобезопасно;
    - `func promptHint(firedSpellings: [String], language: DictionaryLanguage) -> String`;
    - `func recordReplacements(_ r: [AppliedReplacement], noteId: UUID)` и `func replacements(for noteId: UUID) -> [AppliedReplacement]` — в памяти, не больше 50 заметок;
    - `func registerHits(_ r: [AppliedReplacement])` — увеличивает `hits` и `lastUsed` у пользовательских записей.

Детали:

- **Подсказка модели.** Сначала сработавшие написания, затем пользовательские записи по `lastUsed ?? createdAt` по убыванию, всего не больше 8. Префикс: `ru` — `"Словарь пользователя: "`, `en` — `"User dictionary: "`. Пустой список — пустая строка.
- **Наборы** читаются из `packsBundle` по `*.json` в подпапке `Dictionaries`. Порядок задаёт массив `DictionaryStore.packOrder = ["it","ai","apps","management","business","hr","finance","marketing","legal","design"]`. Битый файл набора пропускается с `warn`.
- **Сохранение:** debounce 1 с. Файл `{"schemaVersion":1,"entries":[…]}`. Предыдущий файл копируется в `dictionary.backup.json`, затем идёт атомарная запись.
- **Загрузка:** `dictionary.json`, при ошибке `dictionary.backup.json`, при ошибке пустой список. Ни одна ошибка не бросается наружу.
- **Очистка при загрузке:** удаляются `.learned`, у которых `lastUsed ?? createdAt` старше 60 дней, то есть запись ни разу не срабатывала за 60 дней.

- [ ] **Step 1: Падающие тесты**

```swift
@Test func addingSameSpellingMergesVariants()
@Test func corruptMainFileFallsBackToBackup()        // пишем мусор в dictionary.json, валидный backup → entries из backup
@Test func corruptBothFilesGivesEmptyButPacksWork()  // index.apply по варианту набора срабатывает
@Test func savesSchemaVersionAndBackup()
@Test func learnedEntryUnusedFor60DaysIsPurgedOnLoad()
@Test func removeVariantFromLearnedDeletesEntryWhenLast()
@Test func removeVariantFromPackDisablesItOnly()
@Test func promptHintCapsAtEightAndUsesLanguagePrefix()
@Test func packsLoadUnderFiftyMilliseconds()         // все 10 наборов из Bundle.main
```

Для тестов создаётся временная папка и отдельный `UserDefaults(suiteName:)`. Для теста наборов из `Bundle.main` нужен Task 9. До него тест помечается `.disabled("наборы появятся в Task 9")`, а в Task 9 метка снимается.

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать `DictionaryStore`.**
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): add persistent dictionary store with backup and packs`.

---

### Task 6: Обучение на правках в истории

**Files:**
- Create: `Golosok/Dictionary/DictionaryLearning.swift`
- Modify: `Golosok/HistoryStore.swift:93`, `Golosok/HistoryStore.swift:108` — вызов `PersonalizationEngine.shared.learnFromEdit` заменяется на `DictionaryLearning.shared.learn(original:edited:noteId:)`
- Test: `GolosokTests/Dictionary/DictionaryLearningTests.swift`

**Interfaces:**
- Consumes: Task 2, Task 5.
- Produces:
  - `final class DictionaryLearning`:
    - `static let shared`;
    - `init(store: DictionaryStore, checker: CommonWordChecking, now: @escaping () -> Date)`;
    - `func learn(original: String, edited: String, noteId: UUID?, language: DictionaryLanguage = .current)` — работает на фоновой очереди, в тестах есть синхронный вариант `learnSync`.
  - `static func extractDiffPairs(original:edited:) -> [(pattern: String, replacement: String)]` — переносится из `PersonalizationEngine` без изменений вместе с её тестами.
  - `static func isLearnablePair(pattern: String, replacement: String, language: DictionaryLanguage) -> Bool` — фильтр из спеки:
    - обе стороны по 1–2 слова;
    - `replacement` — латиница, аббревиатура или слово с заглавной буквы;
    - `similarity(pattern, replacement) >= 0.6`, порог для обучения мягче нечёткой замены, потому что пара пришла от пользователя;
    - для `.en` отдельно засчитывается пара, отличающаяся только регистром.

Порядок в `learn`:

1. Если выключено `learningEnabled`, ничего не делать.
2. **Обратные правки.** Каждая `store.replacements(for: noteId)`, у которой `replacement` исчез из `edited`, а `original` появился, вызывает `store.removeVariant(variant, language, entryKey)`.
3. Пары из `extractDiffPairs` фильтруются через `isLearnablePair`. Счётчик ведётся по ключу `"\(language)|\(pattern.lowercased())|\(replacement)"` и хранится в `defaults` под ключом `dictionary.pendingPairs`.
4. На втором повторе, если сегодня создано меньше 5 записей, вызывается `store.addEntry(spelling: replacement, variants: [language: [pattern]], source: .learned)`. Для пары, отличающейся только регистром, — запись без вариантов с `forceCase = true`.

- [ ] **Step 1: Падающие тесты** — плюс перенесённые `testExtractDiffPairs*`.

```swift
func testSinglePairIsNotLearnedYet()
func testSecondIdenticalPairCreatesLearnedEntry()   // «кубернетис»→«Kubernetes» дважды
func testRephrasingIsNotLearned()                    // «давай завтра созвонимся»→«созвон перенесём на пятницу»
func testCommonRussianWordEditNotLearned()          // «дом»→«квартира»
func testEnglishCaseOnlyEditLearnsForceCase()       // «slack»→«Slack» дважды, en
func testReverseEditRemovesVariant()                 // recordReplacements(кубер→Kubernetes), правка Kubernetes→кубер
func testDailyCapOfFive()                            // 6 разных пар по 2 раза → 5 записей
func testLearningDisabledDoesNothing()
```

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать и подключить в `HistoryStore`.**
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): learn from history edits with reverse-edit unlearning`.

---

### Task 7: Миграция

**Files:**
- Create: `Golosok/Dictionary/DictionaryMigration.swift`
- Test: `GolosokTests/Dictionary/DictionaryMigrationTests.swift`

**Interfaces:**
- Consumes: Task 5, Task 6 (`isLearnablePair`).
- Produces: `enum DictionaryMigration`, `static func runIfNeeded(store: DictionaryStore, directory: URL, defaults: UserDefaults)`. Вызывается из `DictionaryStore.shared` после загрузки.
  - Внутри — собственные копии старых Codable-структур `LegacyRule` и `LegacyTerm` и снимок старого списка `builtinRules`. Копия нужна, чтобы файл не зависел от удаляемого `PersonalizationEngine`.

Правила из спеки:

- Запускается, только если есть `personalization.json` и нет `personalization.v1.json`. По окончании первый переименовывается во второй.
- Правила `manual` и `edit` группируются по `replacement`, а `pattern` становится вариантом под `.ru`. Правила `edit` берутся, только если проходят `isLearnablePair(.ru)`.
- Источник записи: `.manual`, если в группе есть хоть одно `manual`, иначе `.learned`.
- Правило `builtin`, чья пара отличается от снимка старого `builtinRules`, считается `.manual`. Неизменённые `builtin` отбрасываются.
- Пустая замена отбрасывается с записью в лог.
- Термины с `isManual`, которых нет в старом `builtinTerms`, и строки `voice.userTerms` становятся записями `.manual` без вариантов. После этого ключ `voice.userTerms` удаляется.
- Повторный запуск идемпотентен: `addEntry` объединяет записи по написанию.

- [ ] **Step 1: Падающие тесты**

```swift
func testGroupsRulesByReplacement()          // кубер→K8s, кубернетис→K8s → одна запись с 2 вариантами
func testEditRuleFailingFilterIsDropped()     // edit: «дом»→«квартира»
func testModifiedBuiltinBecomesManual()       // builtin «кубер»→«K8s» вместо Kubernetes
func testUnmodifiedBuiltinAndAutoTermsDropped()
func testUserTermsMigratedAndKeyRemoved()
func testRunsOnceAndRenamesFile()
func testRerunAfterPartialRunCreatesNoDuplicates() // запись есть, а файл ещё не переименован
```

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): migrate legacy personalization data`.

---

### Task 8: Подключение к пайплайну и удаление старого движка

**Files:**
- Modify: `Golosok/TranscriptionPipeline.swift:183-258`
- Modify: `Golosok/ThoughtSynthesizer.swift`:
  - строки 75–83 и 444–453 — подсказка модели;
  - строки 100 и 366 — `customTerms`.
- Modify: `Golosok/AudioCapture.swift:275` — удалить `observeSpeech`
- Modify: `Golosok/VoiceIntelligenceSettings.swift` — удалить `userTerms`, `addUserTerm`, `removeUserTerm`, `clearUserTerms`
- Modify: `GolosokTests/VoiceIntelligenceTests.swift:149-159`, `GolosokTests/VoiceIntelligencePhase4Tests.swift:140-160` — убрать `userTerms`
- Delete: `Golosok/PersonalizationEngine.swift`, `GolosokTests/PersonalizationEngineTests.swift`
- Create: `Golosok/Dictionary/DictionaryStage.swift`
- Test: `GolosokTests/Dictionary/DictionaryStageTests.swift`

**Interfaces:**
- Consumes: Task 3–6.
- Produces: `enum DictionaryStage`:
  - `static func apply(_ text: String, noteId: UUID, language: DictionaryLanguage, store: DictionaryStore = .shared) -> (text: String, fired: [String])`:
    - вызывает `index.apply`, затем `recordReplacements`, затем `registerHits`;
    - пишет в `AppLogger` по строке на замену: `"Словарь: «X» → «Y», причина, источник"`;
    - сама функция не бросает ошибок. Если индекс ещё не построен, например наборы грузятся при старте, возвращается исходный текст с `warn`.
  - `static func shadowFuzzy(_ text: String, language: DictionaryLanguage)` — выполняется в `DispatchQueue.global(qos: .utility)` и только пишет в лог «заменил бы X на Y, сходство S».

Порядок в `finish`:

1. `stageOneText` проходит через `DictionaryStage.apply` до любой модели.
2. Модель получает текст уже с заменами. `ThoughtSynthesizer` строит подсказку через `store.promptHint(firedSpellings:language:)`. `GroundingValidator` получает `store.index?.approvedSpellings ?? []`.
3. После модели повторно вызывается `DictionaryStage.apply` как страховка.
4. После `deliver` вызывается `DictionaryStage.shadowFuzzy(finalText, language)`.

Ветка без синтеза делает шаги 1 и 4.

- [ ] **Step 1: Падающие тесты**

```swift
func testStageAppliesAndRecordsReplacementsForNote()
func testStageReturnsOriginalTextWhenIndexNotReady()
func testShadowFuzzyNeverChangesText()
```

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать `DictionaryStage`, подключить в пайплайн и синтезатор, удалить старое.** После удаления проверить, что упоминаний не осталось: `grep -rn "PersonalizationEngine\|userTerms" Golosok GolosokTests` должен вернуть пустой результат.
- [ ] **Step 4: Запустить полный `TEST`, ожидается `** TEST SUCCEEDED **`.**
- [ ] **Step 5: Коммит** `refactor(dictionary): route pipeline through new dictionary and remove PersonalizationEngine`.

---

### Task 9: Формат наборов, разметка и проверка, набор IT

**Files:**
- Create: `scripts/annotate-dictionaries.swift`, `Golosok/Dictionaries/it.json`
- Test: `GolosokTests/Dictionary/PackValidationTests.swift`

**Interfaces:**
- Produces:
  - Скрипт: `swift scripts/annotate-dictionaries.swift Golosok/Dictionaries`. Для каждой записи он проставляет `commonIn` — языки, где `spelling.lowercased()` словарное слово по `NSSpellChecker`. Файл перезаписывается с сортировкой ключей и отступом 2.
  - Тесты проверки, общие для всех файлов в `Bundle.main` / `Dictionaries`:
    - `testEveryPackHasBothTitles`;
    - `testNoVariantIsCommonWordInItsLanguage`;
    - `testNoVariantMapsToTwoSpellings` — по всем наборам, внутри одного языка;
    - `testNoVariantEqualsAnotherSpelling`;
    - `testNoLoanwordsFromBlocklist` — список англицизмов из Global Constraints как написания и как варианты;
    - `testCommonInIsUpToDate` — пересчитанный `commonIn` совпадает с файлом, иначе подсказка «запустите scripts/annotate-dictionaries.swift»;
    - `testPackIdsMatchPackOrder`.

- [ ] **Step 1: Написать тесты проверки.** Набор `it.json` пока пустой (`entries: []`), остальные id из `packOrder` временно убраны из проверки `testPackIdsMatchPackOrder`.
- [ ] **Step 2: Заполнить `it.json`.**
  - Около 120 записей: инструменты, облака, базы данных, языки, Git-платформы, CI/CD.
  - Варианты `ru` — как произносят русскоязычные. Варианты `en` — типичные ошибки англоязычного Whisper.
  - Источники сверки: `tvly search "glossary of DevOps terms" --json`, `tvly search "словарь IT-сленга разработчиков" --json`.
  - Старые встроенные IT-пары из `PersonalizationEngine.builtinRules` берутся за основу, но опасные варианты убираются, например «кубик», «питон», «свифт», «кафка».
- [ ] **Step 3: Запустить скрипт разметки, затем `PackValidationTests`. Ожидается PASS.** Нарушения исправлять в данных, а не ослаблять тесты.
- [ ] **Step 4: Снять `.disabled` с `packsLoadUnderFiftyMilliseconds` в Task 5 и запустить.**
- [ ] **Step 5: Коммит** `feat(dictionary): add pack tooling, validation tests and IT pack`.

---

### Task 10: Остальные девять наборов

**Files:**
- Create: `Golosok/Dictionaries/{ai,apps,management,business,hr,finance,marketing,legal,design}.json`

Объёмы по спеке:

| Набор | Записей |
|---|---|
| ai | 60 |
| apps | 80 |
| management | 50 |
| business | 60 |
| hr | 40 |
| finance | 60 |
| marketing | 60 |
| legal | 40 |
| design | 40 |

Чисто российские записи вроде НДС, ЭДО и 1С остаются без `en`.

- [ ] **Step 1: Для каждого набора** выполнить `tvly search "<домен> glossary" --json` и `tvly search "<домен> термины глоссарий" --json`, затем собрать записи по правилу написания.
- [ ] **Step 2: Вернуть все id в `testPackIdsMatchPackOrder`.** Запустить скрипт разметки и `PackValidationTests`, ожидается PASS.
- [ ] **Step 3: Коммит** `feat(dictionary): add AI, apps, management, business, HR, finance, marketing, legal and design packs`.

---

### Task 11: Корпуса «не навреди» и «должно исправить»

**Files:**
- Create:
  - `GolosokTests/DictionaryCorpus/no_harm_ru.txt` и `no_harm_en.txt` — по строке на фразу, не меньше 2000 фраз в каждом;
  - `GolosokTests/DictionaryCorpus/should_fix_ru.tsv` и `should_fix_en.tsv` — колонки `вход<TAB>ожидаемо`, не меньше 150 строк в каждом.
- Test: `GolosokTests/Dictionary/DictionaryCorpusTests.swift`

Корпуса берутся не из чужих текстов, а пишутся заново. В них синтетические, но реалистичные фразы: рабочая переписка, бытовое, письма. Обязательно должны быть словарные слова, похожие на варианты: кубик, питон, комната, slack, swift, notion, linear, go. Фразы «должно исправить» — для слов из всех наборов, с падежами и пунктуацией.

**Interfaces:**
- Consumes: `DictionaryStore` с `Bundle.main` и пустыми пользовательскими записями, `SpellCommonWordChecker`.

- [ ] **Step 1: Тесты**

```swift
func testNoHarmRussianCorpusUnchanged()   // каждая строка: apply(.ru).text == строка; при провале — список первых 20 нарушений
func testNoHarmEnglishCorpusUnchanged()
func testShouldFixRussianAtLeast95Percent()
func testShouldFixEnglishAtLeast95Percent()
func testFuzzyShadowReportOnShouldFix()   // не проверка: печатает долю попаданий fuzzyHits для решения о боевом режиме
```

- [ ] **Step 2: Написать корпуса.**
- [ ] **Step 3: Запустить.** При провале «не навреди» исправлять наборы, то есть убирать опасный вариант. При доле меньше 95% — добавлять варианты.
- [ ] **Step 4: Коммит** `test(dictionary): add no-harm and should-fix corpora`.

---

### Task 12: Автоподбор вариантов и 🎙

**Files:**
- Create: `Golosok/Dictionary/VariantSuggester.swift`, `Golosok/Dictionary/WordProbe.swift`
- Test: `GolosokTests/Dictionary/VariantSuggesterTests.swift`, `GolosokTests/Dictionary/WordProbeTests.swift`

**Interfaces:**
- Produces:
  - `struct VariantSuggester`:
    - `init(checker: CommonWordChecking, llm: VariantLLM?)`;
    - `func instant(for spelling: String) -> [DictionaryLanguage: [String]]` — `ru: [transliterateToCyrillic]` для латинского написания, `[:]` для кириллического;
    - `func suggest(for spelling: String) async -> [DictionaryLanguage: [String]]` — `instant` плюс ответ модели, всё через фильтр.
  - Фильтр вариантов:
    - не словарное слово;
    - не равен написанию без учёта регистра;
    - 1–4 слова;
    - для `ru` только кириллица, пробел и дефис;
    - для `en` только латиница, пробел и дефис;
    - не больше 5 вариантов на язык.
  - `protocol VariantLLM { func complete(system: String, user: String) async -> String? }` и `static func VariantSuggester.currentLLM() -> VariantLLM?`:
    - для `.airGapped` — обёртка над `LocalLLMServer.shared.complete`, только если `LocalLLMServer.shared.isReady(for: path)`;
    - для `.external` — обёртка над `AIService.shared.chat`, только если `AIProviderStore.shared.isConfigured`;
    - иначе `nil`. Модель ради этого не загружается.
  - Системный промпт модели — строгий JSON-ответ `{"ru":[…],"en":[…]}`. Невалидный JSON означает пустой результат.
  - `enum WordProbeOutcome: Equatable { case tooQuiet, tooManyWords, noise, alreadyCorrect, variant(String) }`.
  - `static func WordProbe.evaluate(recognized: String, spelling: String, peakDb: Float, language: DictionaryLanguage) -> WordProbeOutcome`, проверки по порядку:
    1. `peakDb < -40` → `tooQuiet`;
    2. текст после `DisfluencyPrefilter.filter` и очистки пунктуации пуст → `noise`;
    3. больше 3 слов → `tooManyWords`;
    4. равен написанию без учёта регистра → `alreadyCorrect`;
    5. иначе `variant(очищенный текст в нижнем регистре)`.
  - `final class WordProbe: ObservableObject`:
    - `@Published level: Float`;
    - `func start(spelling: String, completion: @escaping (WordProbeOutcome) -> Void)` — `AudioRecorder`, автостоп через 0,6 с тишины ниже −45 дБ после начала речи или через 3 с, затем распознавание `SpeechRecognizerFactory.current()` по `AudioChunkReader` на фоне, затем `evaluate`;
    - `func cancel()`.

- [ ] **Step 1: Падающие тесты**

```swift
func testInstantGivesCyrillicTransliterationForLatin()
func testFilterDropsCommonWordsAndWrongScript()      // LLM-мок вернул «кубик», «cube», «кубер», «kuber» → ru: [кубер], en: [kuber]
func testInvalidLLMJsonFallsBackToInstant()
func testNoLLMWhenModelNotLoaded()                    // currentLLM() == nil при неготовом сервере
func testProbeOutcomes() {
    XCTAssertEqual(WordProbe.evaluate(recognized: "кубер", spelling: "Kubernetes", peakDb: -20, language: .ru), .variant("кубер"))
    XCTAssertEqual(WordProbe.evaluate(recognized: "кубер", spelling: "Kubernetes", peakDb: -50, language: .ru), .tooQuiet)
    XCTAssertEqual(WordProbe.evaluate(recognized: "ну это вот кубер да", spelling: "Kubernetes", peakDb: -20, language: .ru), .tooManyWords)
    XCTAssertEqual(WordProbe.evaluate(recognized: "Kubernetes.", spelling: "Kubernetes", peakDb: -20, language: .ru), .alreadyCorrect)
    XCTAssertEqual(WordProbe.evaluate(recognized: "э-э", spelling: "Kubernetes", peakDb: -20, language: .ru), .noise)
}
```

- [ ] **Step 2: Запустить, ожидается FAIL.**
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4: Запустить, ожидается PASS.**
- [ ] **Step 5: Коммит** `feat(dictionary): add variant suggestions and word probe`.

---

### Task 13: Экран словаря и перенос системного промпта

**Files:**
- Create: `Golosok/DictionaryView.swift`, `Golosok/DictionaryAddWordSheet.swift`, `Golosok/DictionaryPackDetailView.swift`
- Delete: `Golosok/VocabularyView.swift`
- Modify:
  - `Golosok/ContentView.swift:714` — `VocabularyView()` заменяется на `DictionaryView()`;
  - `Golosok/AISettingsSection.swift:229-245` — новая подпись строки словаря и строка «Инструкция модели» с редактором `customSystemPrompt` и кнопкой «По умолчанию»;
  - `Golosok/Localizable.xcstrings`.

**Interfaces:**
- Consumes: `DictionaryStore.shared`, `VariantSuggester`, `WordProbe`, `DictionaryLanguage.current`.

Строки интерфейса, `ru` → `en`:

| ru | en |
|---|---|
| Словарь | Dictionary |
| Слово | Word |
| Поиск | Search |
| Мои слова | My words |
| Наборы | Packs |
| Обучение | Learning |
| Учиться на правках | Learn from edits |
| выучено | learned |
| %lld слов | %lld words, с plural-вариациями |
| Пока пусто | Nothing yet |
| Узнаю как | Recognized as |
| Произнести | Say it |
| Скажите слово | Say the word |
| Услышал | Heard |
| Сохранить | Save |
| Ещё раз | Again |
| Добавить | Add |
| Не расслышал | Didn't catch that |
| Скажите только слово | Say just the word |
| Уже распознаётся верно | Already recognized |
| Сбросить выученное | Reset learned |
| Инструкция модели | Model instructions |
| По умолчанию | Default |
| Свои слова и наборы терминов | Your words and term packs |

Поведение по спеке, раздел «Экран»:

- Строка слова: написание, варианты текущего языка через « · », метка «выучено». По клику раскрываются строки RU и EN с вариантами, крестик у каждого варианта, «+ вариант», 🎙, удаление.
- Строка набора: название на языке интерфейса, число слов, переключатель. По клику — `DictionaryPackDetailView` со списком и выключателем у каждого слова.
- Раздел «Обучение» содержит одну строку: «Учиться на правках» с переключателем `learningEnabled`. Строка про Универсальный доступ и переключатель контекста экрана появятся на этапах 3–4.
- Поиск идёт по пользовательским записям и наборам, одна строка на написание. У результатов из наборов подпись — название набора.
- Меню «…» у «Моих слов» содержит «Сбросить выученное» с подтверждением.
- Окно добавления:
  - поле написания;
  - `instant` показывается сразу, `suggest` дополняет асинхронно;
  - 🎙 с индикатором уровня и результатом «Услышал: «X»» и кнопками «Сохранить» и «Ещё раз»;
  - сообщения отказов из таблицы.

- [ ] **Step 1: Реализовать экран, окно добавления и страницу набора. Перенести редактор промпта. Удалить `VocabularyView.swift`.**
- [ ] **Step 2: Собрать проект и запустить полный `TEST`, ожидается `** TEST SUCCEEDED **`.**
- [ ] **Step 3: Запустить приложение и проверить руками:**
  - добавить «Kubernetes» — появляются варианты;
  - 🎙 с тишиной — «Не расслышал»;
  - выключить набор, затем выключить слово в наборе;
  - поиск;
  - сброс выученного;
  - редактор промпта в настройках AI;
  - переключить язык интерфейса на английский — нет русских строк.
- [ ] **Step 4: Коммит** `feat(dictionary): new dictionary screen, add-word sheet and pack details`.

---

### Task 14: Финальная проверка

- [ ] **Step 1: Убедиться, что нигде не осталось старого.** Команда

```bash
grep -rn "PersonalizationEngine\|userTerms\|VocabularyView\|builtinRules" Golosok GolosokTests
```

должна вернуть пустой результат. Исключение — снимок `builtinRules` внутри `DictionaryMigration.swift`.
- [ ] **Step 2: Запустить полный `TEST`, ожидается `** TEST SUCCEEDED **`.**
- [ ] **Step 3: Продиктовать в приложении по пять фраз на `ru` с GigaAM и на `en` с Whisper,** если модель скачана. В логах должны быть строки «Словарь: …» и теневые «заменил бы…».
- [ ] **Step 4: Коммит исправлений, если они были.** Версия `2.2.0` выставляется при релизе по регламенту из AGENTS.md, не в этом плане.
