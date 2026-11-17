# Офлайн-модели по замеру, проверка ответа и словари терминов — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Убрать ложные отказы проверки ответа, оставить в каталоге три модели, выбранные замером, пометить рекомендуемую по памяти Mac и дополнить словари терминами из замера.

**Architecture:**
- `GroundingValidator` сравнивает числа после той же нормализации, что и вход, понимает время и самоисправления в числах и не принимает «как бы» за вопрос.
- `SLMModel` получает класс памяти и признак «только через llama-server».
- Каталог сокращается до решения замера. Чистая функция `SLMRecommendation` выбирает рекомендуемую модель по `ProcessInfo.physicalMemory`, настройки её только помечают.
- Файлы выведенных моделей удаляются при запуске.
- Словари меняются в JSON-пакетах, правило охраняется `PackValidationTests` и корпусами.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, XCTest для корпусов, llama.cpp `b12441`, GGUF.

**Spec:** `docs/superpowers/specs/2026-11-17-dictation-focus-design.md`, разделы 3, 6 и 8. Замер и решение — `docs/eval-local-models-2026-11.md`. Принцип «пользователь выбирает, приложение рекомендует по памяти» сохраняется.

План 3 из 4. Планы 1 и 2 выполнены в этой же ветке. Порядок выполнения: задача 1, задача 5, затем задачи 2, 3 и 4. Сигнатуры сверены с кодом на коммите `7870d91`; при расхождении следовать коду.

## Решение замера

Замер от 17 ноября 2026, 100 надиктованных фраз, 8 моделей. Подробности — в `docs/eval-local-models-2026-11.md`.

| ID | Название | Файл | МБ | Память | Источник | Роль |
| --- | --- | --- | --- | --- | --- | --- |
| `gemma_4_e4b_qat` | Gemma 4 E4B | `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` | 4210 | 16 | `unsloth/gemma-4-E4B-it-qat-GGUF` | рекомендуемая |
| `tlite_2.1` | T-lite 2.1 | `T-lite-it-2.1-Q4_K_M.gguf` | 5030 | 16 | `t-tech/T-lite-it-2.1-GGUF` | запасная |
| `gemma_4_e2b` | Gemma 4 E2B | `gemma-4-E2B-it-Q4_K_M.gguf` | 3110 | 8 | `unsloth/gemma-4-E2B-it-GGUF` | рекомендуемая |

URL: `https://huggingface.co/<Источник>/resolve/main/<Файл>`, одно зеркало.

Выводятся все прежние модели: `vikhr_0.5b`, `vikhr_1.5b`, `qvikhr_3_4b`, `qwen_3.5_0.8b`, `qwen_3.5_2b`, `llama_3.2_1b`. GigaChat 3.1, Qwen 3.5 4B и Gemma 4 12B замерены, но в каталог не входят.

## Global Constraints

- Ветка `feat/dictation-focus`, коммиты в неё, PR только по явной просьбе пользователя.
- Текст интерфейса: без скобок, метки 1–2 слова, подписи короче 8 слов. Новые строки через `String(localized:)` с английским переводом в `Localizable.xcstrings`.
- Модель выбирает пользователь. Рекомендация только помечает модель и не меняет `voice.localModel`, кроме случая, когда сохранённая модель выведена из каталога.
- Порог памяти: меньше 15.5 ГиБ — класс 8, иначе класс 16.
- Модель класса 16 на Mac с меньшей памятью не скрывается, но получает подпись «Нужно 16 ГБ».
- Правило написания: латинские термины и аббревиатуры латиницей; русские аббревиатуры кириллицей; слова с русскими окончаниями, прежде всего глаголы, кириллицей.
- Проверка ответа остаётся строгой к выдуманным числам и терминам: ослабляется только там, где замер показал ложный отказ.
- Нарушения словарных тестов исправляются в данных, а не в тестах.
- Команда тестов, далее `TEST`:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/<Suite> CODE_SIGN_IDENTITY=- 2>&1 | grep -E "error:|✘|passed|failed|\*\* TEST"`
  Успех — `** TEST SUCCEEDED **`. `DEVELOPER_DIR` нужен, потому что `xcode-select` указывает на Command Line Tools.

## Review Focus

- **Самоисправление в числах против выдуманного числа.** «Скидка 10%, нет, 15%» → «Скидка 15%» принимается. «Скидка 10%» → «Скидка 15%» без маркера исправления отклоняется. Тесты в задаче 1.
- **Пропуск числа без исправления.** «Бюджет 500 и 600» → «Бюджет 600» по-прежнему отклоняется. Тест в задаче 1.
- **Настоящий вопрос.** «Как настроить уведомления?» без знака вопроса в ответе по-прежнему отклоняется, а «Как бы, нам нужно обновить прайс.» вопросом не считается. Тесты в задаче 1.
- **Новая модель, а llama-server ещё грузится.** Встроенный `llama-cli` поставляется вручную. В замере первая диктовка каждого прогона уходила в него, и в ответ попадали метки im_end и channel. Ожидание: для моделей с `requiresServer` запасной путь через `llama-cli` не запускается, диктовка получает текст A, сервер догружается для следующей. Тест в задаче 2.
- **Сохранённая модель выведена из каталога.** Ожидание: выбор переходит на `gemma_4_e2b`, приложение не падает, файл выведенной модели удалён. Тест в задаче 3.
- **В каталоге моделей лежит посторонний файл** или файл живой модели. Ожидание: удаляются только файлы из списка выведенных. Тест в задаче 3.
- **Mac на 16 ГБ сообщает чуть меньше 16 ГиБ.** Ожидание: класс 16. Тест в задаче 3.
- **Обычная речь со словом «гид»** и падежные формы терминов: «на стейджинге», «два пулл реквеста». Ожидание: «гид» не меняется, термины уходят в латиницу. Строки корпуса в задаче 4.

---

### Task 1: Ложные отказы проверки ответа

**Files:**
- Modify: `Golosok/GroundingValidator.swift`
- Test: `GolosokTests/LevelValidatorTests.swift`

Причины и доли — раздел «Проверка ответа» в `docs/eval-local-models-2026-11.md`.

**Interfaces:**
- Produces, внутри `GroundingValidator`:
  ```swift
  /// Числа текста после NumberNormalizer; время «H:MM» даёт часы и минуты, «H:00» — только часы.
  static func normalizedNumbers(in text: String) -> [NumberToken]
  /// Число речи, которое говорящий сам исправил: за ним не дальше шести слов идёт маркер
  /// исправления, а за маркером не дальше четырёх слов — другое число.
  static func correctedNumbers(in input: String) -> Set<String>
  ```
  `NumberToken` — значение и позиция в словах, только для этих двух функций.

- [ ] **Step 1: Write the failing tests** в `LevelValidatorTests.swift`. Каждый тест вызывает `GroundingValidator.validate(input:output:level: .clean)`.

```swift
@Test func numberCorrectedBySpeakerMayBeDropped() {
    #expect(isValid("Скидка 10 процентов, нет, 15, мы так договорились.", "Скидка 15 процентов, мы так договорились."))
    #expect(isValid("Бронируй зал на 10 человек, ой, на 12.", "Бронируй зал на 12 человек."))
    #expect(isValid("Перенесли уже 3 сервиса из 5, ой, нет, 4 из 5.", "Перенесли уже 4 сервиса из 5."))
    #expect(isValid("Корпоратив в 7 вечера, ну, в 19:00.", "Корпоратив в 19:00."))
}
@Test func numberDroppedWithoutCorrectionIsRejected() {
    #expect(!isValid("Бюджет 500 и 600 на рекламу.", "Бюджет 600 на рекламу."))
    #expect(!isValid("Скидка 10 процентов.", "Скидка 15 процентов."))
}
@Test func ordinalAndCountWordsMatchDigits() {
    #expect(isValid("Встреча на 3 этаже, ой, на 4, в большой переговорке.", "Встреча на четвёртом этаже, в большой переговорке."))
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

private func isValid(_ input: String, _ output: String) -> Bool {
    if case .valid = GroundingValidator.validate(input: input, output: output, level: .clean) { return true }
    return false
}
private func sanitized(_ output: String) -> String? {
    if case .valid(let text) = GroundingValidator.validate(input: "Я заберу ноутбук.", output: output, level: .clean) { return text }
    return nil
}
```

- [ ] **Step 2: Run** `TEST` с `LevelValidatorTests`. Expected: новые тесты падают, остальные проходят.

- [ ] **Step 3: Implement**
  - **Служебные токены.** До проверки зачинов удалить из ответа `<\|[^|>]{1,40}\|>`, `<start_of_turn>`, `<end_of_turn>` и `<eos>`.
  - **Вопрос.** Из `hasLeadingQuestionKeyword` исключить начало «как бы». Перед проверкой ключевых слов срезать ведущие паразиты «ну», «э-э», «эээ», «так», «слушай», «короче» вместе с запятыми.
  - **Числа.** `extractNumbers` заменить на `normalizedNumbers`: оба текста пропускаются через `NumberNormalizer.normalize`, потом извлекаются числа. Время `\d{1,2}:\d{2}` даёт часы и минуты, «H:00» — только часы: так «14:30» равно «14 часов 30 минут», а «12:00» равно «12». Число в конце предложения, «15.», тоже извлекается: прежний шаблон его пропускал. Для уровня `.clean` и `.rewrite` пропуск исходного числа допустим, если оно входит в `correctedNumbers(in:)`. Маркеры исправления: «нет», «ой», «точнее», «вернее», «то есть», «подожди», «стоп», «извини», «ну». «Придумала число» проверяется по-прежнему для всех чисел ответа.
  - **Знак номера.** Токены `No` и `N` непосредственно перед числом не считаются латинскими терминами.

- [ ] **Step 4: Run** `TEST` с `LevelValidatorTests`, затем весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Golosok/GroundingValidator.swift GolosokTests/LevelValidatorTests.swift
git commit -m "fix(validator): accept number self-corrections, times, ordinals and filler 'как бы'"
```

---

### Task 2: Модели замера в каталоге

**Files:**
- Modify: `Golosok/SLMModelStore.swift` — поля `SLMModel`, записи каталога.
- Modify: `Golosok/LocalSynthServiceClient.swift:69-76` — не запускать `llama-cli` для `requiresServer`.
- Test: `GolosokTests/SLMCatalogTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SLMModel {
      // существующие поля и:
      public let memoryClassGB: Int        // 8 или 16
      public let requiresServer: Bool      // true — только llama-server
  }
  extension SLMModelStore {
      static func model(forPath path: String) -> SLMModel?   // по lastPathComponent == fileName
  }
  extension LocalSynthServiceClient {
      func allowsCLIFallback(modelPath: String) -> Bool
  }
  ```
  `requiresServer = true` для трёх моделей из таблицы «Решение замера». Новые поля получают значения по умолчанию в обоих `init`: `memoryClassGB: 8`, `requiresServer: false`.

Описания, точная копия:
- `gemma_4_e4b_qat`: «Точная очистка, быстрая»
- `tlite_2.1`: «Сильна в терминах»
- `gemma_4_e2b`: «Лёгкая и быстрая»

- [ ] **Step 1: Write the failing tests**

```swift
@Test func measuredModelsArePresent() {
    let ids = Set(SLMModelStore.catalog.map(\.id))
    #expect(ids.isSuperset(of: ["gemma_4_e4b_qat", "tlite_2.1", "gemma_4_e2b"]))
}
@Test func measuredModelsRequireServer() {
    for id in ["gemma_4_e4b_qat", "tlite_2.1", "gemma_4_e2b"] {
        #expect(SLMModelStore.catalog.first { $0.id == id }?.requiresServer == true)
    }
}
@Test func memoryClassesAreEightOrSixteen() {
    for model in SLMModelStore.catalog { #expect([8, 16].contains(model.memoryClassGB)) }
    #expect(SLMModelStore.catalog.first { $0.id == "gemma_4_e4b_qat" }?.memoryClassGB == 16)
    #expect(SLMModelStore.catalog.first { $0.id == "gemma_4_e2b" }?.memoryClassGB == 8)
}
@Test func descriptionsFitCopyRules() {
    for model in SLMModelStore.catalog {
        #expect(model.description.split(separator: " ").count < 8)
        #expect(!model.description.contains("("))
    }
}
@Test func cliFallbackSkippedForServerOnlyModels() {
    let client = LocalSynthServiceClient.shared
    let model = SLMModelStore.catalog.first { $0.id == "gemma_4_e4b_qat" }!
    #expect(client.allowsCLIFallback(modelPath: "/tmp/\(model.fileName)") == false)
    #expect(client.allowsCLIFallback(modelPath: "/tmp/QVikhr-2.5-1.5B-Instruct-SMPO-Q4_K_M.gguf") == true)
}
```

- [ ] **Step 2: Run** `TEST` с `SLMCatalogTests`. Expected: ошибки компиляции.

- [ ] **Step 3: Implement** поля, три записи по таблице, `model(forPath:)` и `allowsCLIFallback`: `false`, если модель по пути найдена и `requiresServer`. В `synthesize` при `false` вместо `llama-cli` вернуть `nil` с записью в лог «Модель работает только через llama-server». Прежние модели пока остаются с `memoryClassGB` 8, кроме `qvikhr_3_4b` — 16; их убирает задача 3.

- [ ] **Step 4: Проверить запуск каждой из трёх моделей вручную.** Скачать модель через настройки, выбрать её, надиктовать фразу с паразитами два раза подряд. Ожидание:
  - вторая диктовка очищена моделью;
  - в логе «Инференс через llama-server»;
  - в ответе нет `<think>`, im_end и channel.

  Шаблон чата Gemma 4 в llama-server `b12441` замер подтвердил. Если модель всё же не грузится, удалить её из каталога и сообщить пользователю.

- [ ] **Step 5: Run** весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Golosok GolosokTests
git commit -m "feat(offline): add Gemma 4 E4B QAT, T-lite 2.1 and Gemma 4 E2B to local catalog"
```

---

### Task 3: Каталог по решению и рекомендация в настройках

**Files:**
- Create: `Golosok/SLMRecommendation.swift`
- Modify: `Golosok/SLMModelStore.swift` — удалить выведенные записи, `retiredFileNames`, `model(named:)` для выведенных ID, очистка файлов.
- Modify: `Golosok/VoiceIntelligenceSettings.swift:152,171-176` — запасной ID `SLMRecommendation.smallID` вместо `"vikhr_1.5b"`.
- Modify: `Golosok/GolosokApp.swift` — запуск очистки в фоне.
- Modify: `Golosok/AISettingsSection.swift:184-189` — подписи списка и метки в `ActiveSLMModelStatusRow`.
- Modify: `Golosok/Localizable.xcstrings`
- Test: `GolosokTests/SLMRecommendationTests.swift`, дополнить `GolosokTests/SLMCatalogTests.swift`

**Interfaces:**
- Consumes: `SLMModel.memoryClassGB` из задачи 2.
- Produces:
  ```swift
  enum SLMRecommendation {
      static let threshold: UInt64 = 16_642_998_272        // 15.5 ГиБ
      static let smallID = "gemma_4_e2b"
      static let largeID = "gemma_4_e4b_qat"
      static func memoryClass(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int
      static func recommendedModelID(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String
      static func pickerLabel(for model: SLMModel, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String
  }
  extension SLMModelStore {
      static let retiredFileNames: [String]
      static func retiredFiles(in directory: URL, retired: [String] = retiredFileNames) -> [URL]
      func removeRetiredModels()
  }
  ```
  `pickerLabel`:
  - `"\(name) · Рекомендуем"` — для рекомендуемой модели;
  - `"\(name) · Нужно 16 ГБ"` — для модели класса 16 на Mac класса 8;
  - иначе `name`.

  Подписи локализуются.

- [ ] **Step 1: Write the failing tests**

```swift
let gib: UInt64 = 1_073_741_824
@Test func memoryClassThreshold() {
    #expect(SLMRecommendation.memoryClass(physicalMemory: 8 * gib) == 8)
    #expect(SLMRecommendation.memoryClass(physicalMemory: 16 * gib - 300 * 1_048_576) == 16)
}
@Test func recommendationByMemory() {
    #expect(SLMRecommendation.recommendedModelID(physicalMemory: 8 * gib) == "gemma_4_e2b")
    #expect(SLMRecommendation.recommendedModelID(physicalMemory: 32 * gib) == "gemma_4_e4b_qat")
}
@Test func recommendedModelsMatchTheirClass() {
    let small = SLMModelStore.catalog.first { $0.id == SLMRecommendation.smallID }
    let large = SLMModelStore.catalog.first { $0.id == SLMRecommendation.largeID }
    #expect(small?.memoryClassGB == 8); #expect(large?.memoryClassGB == 16)
}
@Test func pickerLabels() {
    let large = SLMModelStore.catalog.first { $0.id == "gemma_4_e4b_qat" }!
    let spare = SLMModelStore.catalog.first { $0.id == "tlite_2.1" }!
    #expect(SLMRecommendation.pickerLabel(for: large, physicalMemory: 32 * gib).hasSuffix("Рекомендуем"))
    #expect(SLMRecommendation.pickerLabel(for: spare, physicalMemory: 32 * gib) == spare.name)
    #expect(SLMRecommendation.pickerLabel(for: large, physicalMemory: 8 * gib).hasSuffix("Нужно 16 ГБ"))
}
```

В `SLMCatalogTests.swift`:
```swift
let retiredIDs = ["vikhr_0.5b", "vikhr_1.5b", "qvikhr_3_4b", "qwen_3.5_0.8b", "qwen_3.5_2b", "llama_3.2_1b"]
@Test func catalogMatchesDecision() {
    #expect(Set(SLMModelStore.catalog.map(\.id)) == ["gemma_4_e4b_qat", "tlite_2.1", "gemma_4_e2b"])
}
@Test func retiredIDsFallBackToSmallRecommendation() {
    for id in retiredIDs + ["qwen_0.5b"] {
        #expect(SLMModelStore.shared.model(named: id)?.id == SLMRecommendation.smallID)
    }
}
@Test func retiredFilesSelectsOnlyRetiredNames() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["QVikhr-3-4B-Instruction-Q4_K_M.gguf", "gemma-4-E2B-it-Q4_K_M.gguf", "notes.txt"] {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
    }
    #expect(SLMModelStore.retiredFiles(in: dir).map(\.lastPathComponent) == ["QVikhr-3-4B-Instruction-Q4_K_M.gguf"])
}
@Test func retiredNamesNeverOverlapCatalog() {
    #expect(Set(SLMModelStore.catalog.map(\.fileName)).isDisjoint(with: SLMModelStore.retiredFileNames))
}
```

Тест `measuredModelsArePresent` из задачи 2 удалить: его заменяет `catalogMatchesDecision`.

- [ ] **Step 2: Run** `TEST` с `SLMRecommendationTests` и `SLMCatalogTests`. Expected: ошибки компиляции и падения.

- [ ] **Step 3: Implement** по интерфейсам.
  - `retiredFileNames` — `fileName` выведенных записей дословно.
  - `model(named:)` для выведенных ID и для существующих legacy-ключей возвращает модель `smallID`.
  - `removeRetiredModels()` удаляет `retiredFiles(in: modelsDirectory)` и пишет имя каждого файла в лог. Вызывается из `GolosokApp` через `Task.detached(priority: .utility)`.
  - В `AISettingsSection` подписи списка — через `pickerLabel`.
  - В `ActiveSLMModelStatusRow` метка «Рекомендуем» шрифтом `.ui(.micro)` цвета `.uiSuccess`, только у рекомендуемой модели.
  - `VoiceIntelligenceSettings` ставит `SLMRecommendation.smallID`, если сохранённой модели нет в каталоге, и при новой установке без сохранённого значения. Рекомендацию по памяти при этом не применять.

- [ ] **Step 4: Run** весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Golosok GolosokTests
git commit -m "feat(offline): keep measured models, recommend by Mac memory, remove retired files"
```

---

### Task 4: Словари по правилу написания терминов

**Files:**
- Modify: `Golosok/Dictionaries/it.json` — `staging`, `pull request`, варианты `Git`, `Power BI`.
- Modify: `Golosok/Dictionaries/hr.json` — `C&B`.
- Modify: `GolosokTests/Dictionary/PackValidationTests.swift` — список англицизмов, тест глагольных форм.
- Modify: `GolosokTests/DictionaryCorpus/should_fix_ru.tsv`, `GolosokTests/DictionaryCorpus/no_harm_ru.txt`

Записи, точная копия написаний и вариантов `ru`; `en` пустые, кроме `Power BI`. `commonIn` проставляет скрипт.

| Пакет | Написание | Варианты ru | Варианты en |
| --- | --- | --- | --- |
| it | `staging` | стейджинг, стейджинга, стейджингу, стейджингом, стейджинге | — |
| it | `pull request` | пулл реквест, пулл реквеста, пулл реквесту, пулл реквестом, пулл реквесте, пулл реквесты, пул реквест, пул реквеста, пул реквесты, пулреквест, пулреквеста, пулреквесты | — |
| it | `Git` | — | — |
| it | `Power BI` | пауэр би, пауэр биай, пауэрби | Power B |
| hr | `C&B` | си энд би, си эн би, компенсейшн энд бенефитс | — |

«Гид» в варианты `Git` не входит: это обычное слово. «Жира», «жиру» и «жире» в варианты `Jira` не входят по той же причине.

- [ ] **Step 1: Write the failing tests** в `PackValidationTests.swift`

```swift
/// Слова с русскими окончаниями пишутся кириллицей: вариант-глагол не может вести в латинское написание.
static let russianVerbEndings = ["ить", "ать", "ять", "еть", "уть", "ться", "тся", "ишь", "ешь", "ил", "ила", "или", "ило"]
/// Существительные с похожими окончаниями, проверенные вручную.
static let verbLikeNouns: Set<String> = []

@Test func testNoRussianVerbFormMapsToLatinSpelling() {
    for item in allVariants where item.language == .ru && VariantRules.isLatin(item.spelling) {
        for word in item.variant.split(whereSeparator: \.isWhitespace) where !Self.verbLikeNouns.contains(String(word)) {
            #expect(!Self.russianVerbEndings.contains { word.hasSuffix($0) },
                    "\(item.pack)/\(item.spelling): глагольная форма «\(item.variant)» должна остаться кириллицей")
        }
    }
}

@Test func testTermsFromSpecArePresent() {
    let spellings = Set(packs.flatMap { $0.entries.map(\.spelling) })
    #expect(spellings.isSuperset(of: ["staging", "pull request", "Git", "C&B", "CRM", "B2B", "B2C", "Power BI"]))
}
```

В `loanwordBlocklist` добавить: «задеплоить», «митинг», «фича», «фичи», «запушить», «смерджить», «онбординг».

Строки в `should_fix_ru.tsv`, в блок `# independent`:
```
Выкатим релиз на стейджинг после обеда.	Выкатим релиз на staging после обеда.
На стейджинге упал логин.	На staging упал логин.
Посмотри мой пулл реквест до вечера.	Посмотри мой pull request до вечера.
Там висят два пул реквеста от Артёма.	Там висят два pull request от Артёма.
Залей изменения в гит и скинь ссылку.	Залей изменения в Git и скинь ссылку.
Вопрос по си энд би отправь в отдел кадров.	Вопрос по C&B отправь в отдел кадров.
Выгрузи отчёт из пауэр би в PDF.	Выгрузи отчёт из Power BI в PDF.
```

Строки в `no_harm_ru.txt`:
```
Наш гид рассказал про историю музея и показал старые карты.
Надо задеплоить сервис до пятницы, иначе митинг перенесут.
Эта фича пока сырая, давай её не показывать клиенту.
Онбординг новичков сейчас слабый, его надо переделать.
```

- [ ] **Step 2: Run** `TEST` с `PackValidationTests` и `DictionaryCorpusTests`. Expected: `testTermsFromSpecArePresent` и новые строки `should_fix` падают; `testNoRussianVerbFormMapsToLatinSpelling` может найти нарушения в существующих пакетах.

- [ ] **Step 3: Implement** записи таблицы в `it.json` и `hr.json`.
  - **Нарушения `testNoRussianVerbFormMapsToLatinSpelling`.** Настоящий глагол удалить из данных. Существительное с похожим окончанием, например падежную форму названия продукта, внести в `verbLikeNouns`.
  - **Однословный вариант помечен `testNoVariantIsCommonWordInItsLanguage`,** например «гит». Удалить этот вариант вместе со строкой корпуса, которая на него опирается, и вписать это в отчёт задачи.
  - **Затем проставить `commonIn`:**
    `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/annotate-dictionaries.swift Golosok/Dictionaries`

- [ ] **Step 4: Run** весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Golosok/Dictionaries GolosokTests
git commit -m "feat(dictionary): staging, pull request, Git, Power BI and C&B terms, keep Russian verb forms Cyrillic"
```

- [ ] **Step 6: Сообщить пользователю** три вещи, которые код не меняет:
  - «гид», «жиру» и «слаг» останутся как есть: это обычные слова, и словарь не может вести их в Git, Jira и Slack;
  - распознавание пишет часть терминов латинским мусором: «BB», «Buce», «CNT», «IPI», «Sk». Словарь с этим не справится, нужна работа с распознаванием, она за пределами плана;
  - если в личном словаре есть латинские написания для русских слов или аббревиатур, например `BTI` или `Deploy`, их нужно поправить в разделе «Словарь»: `BTI` заменить на `БТИ`, `Deploy` удалить.

---

### Task 5: Повторный замер всех моделей и сверка решения

**Выполняется сразу после задачи 1, до задач 2–4.** Замер не зависит от каталога, а его итог может поменять каталог.

Решение по каталогу принято при ложных отказах проверки. После задачи 1 порядок моделей может измениться, поэтому прогоняются все восемь моделей, а не только три из каталога.

**Files:**
- Modify: `docs/eval-local-models-2026-11.md` — раздел «После исправлений».

- [ ] **Step 1: Сохранить исходные отчёты.** Перенести `~/golosok-eval/report-*.md` первого замера в `~/golosok-eval/baseline/`, если они ещё там. Это точка сравнения.

- [ ] **Step 2: Прогнать замер всех восьми моделей** на том же наборе `~/golosok-eval/cases.jsonl`. Набор не пересобирать. Модели лежат в `~/golosok-eval/models`, QVikhr 3 4B — в каталоге моделей приложения. Перед прогоном закрыть приложение. Для каждой модели:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_GOLOSOK_EVAL_DIR=$HOME/golosok-eval \
TEST_RUNNER_GOLOSOK_EVAL_LOCAL_MODEL=<путь к модели> \
xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' \
  -only-testing:GolosokTests/CleanupEvalTests CODE_SIGN_IDENTITY=-
```

  Фильтр `-only-testing` — по набору `CleanupEvalTests`, а не по отдельному `liveEval`: фильтр по имени теста Swift Testing не находит.

- [ ] **Step 3: Сравнить с первым замером.** Таблица «до → после» по каждой модели: похожесть, принято, потери смысла, медиана и p95. Похожесть и потери смысла считаются тем же способом, что в первом замере: совпадение слов с эталоном и пропуск двух и больше значимых слов, которые распознавание услышало верно. Отдельно:
  - какие отказы исчезли и какие остались;
  - не появились ли принятые ответы с настоящей ошибкой — выдуманным числом, потерянным смыслом или ответом на вопрос. Каждый такой случай — дефект задачи 1, его надо исправить до коммита.

- [ ] **Step 4: Сверить решение.** Если по новой таблице другая модель лучше выбранной в своём классе памяти, показать пользователю таблицу и предложить замену. С его согласия поправить таблицу «Решение замера» и ID в задачах 2 и 3 до начала их выполнения. Без согласия решение не менять.

- [ ] **Step 5: Записать** таблицу «до → после», разбор оставшихся отказов и итог сверки в раздел «После исправлений».

- [ ] **Step 6: Commit**

```bash
git add docs/eval-local-models-2026-11.md
git commit -m "docs(eval): compare all local models before and after validator fixes"
```
