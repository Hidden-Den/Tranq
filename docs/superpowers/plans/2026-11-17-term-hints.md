# Подсказка терминов модели очистки — план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** модель очистки получает к фразе короткий список терминов, которые распознавание могло исказить, и исправляет «IPI ключ» в «API-ключ», а проверка ответа такую замену принимает.

**Architecture:** после этапа 1 индекс словаря находит подозрительные слова: латиницу не из словаря и кириллицу заглавными. Для каждого он подбирает до шести терминов из словаря по звуковому ключу — скелету согласных, общему для латиницы и кириллицы. Подсказка добавляется в системный промпт рядом с нынешним «Словарь пользователя». `GroundingValidator` разрешает убрать подозрительное слово, если вместо него стоит один из подобранных терминов. Замер на тех же 100 фразах до и после решает, остаётся ли подсказка.

**Tech Stack:** Swift 6, XCTest и Swift Testing, llama-server b12441, Python 3 для сравнения отчётов.

**Spec:** `docs/eval-local-models-2026-11.md`, раздел «Распознавание терминов»; видение — `docs/superpowers/specs/2026-11-17-dictation-focus-design.md`.

## Global Constraints

- Ветка `feat/dictation-focus`, коммит после каждой задачи, PR только по прямой просьбе.
- `xcodebuild` запускать с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Записи и отчёты замера лежат в `~/golosok-eval`, в репозиторий не попадают.
- Подсказка работает только для русского языка диктовки, `DictionaryLanguage.ru`.
- Новых моделей, загрузок и настроек в интерфейсе нет: подсказка всегда включена, если её оставит замер.
- Замер — три модели каталога: Gemma 4 E4B QAT, T-lite 2.1, Gemma 4 E2B.

## Review Focus

1. **Чистая фраза без терминов.** Модель не должна вставлять термин, которого не было: «Антон прислал макет» остаётся без Pantone. Подозрительных слов в такой фразе нет, подсказки нет. Тест в задаче 2: `testCleanPhraseHasNoSuspects`.
2. **Правильный термин.** Слово уже из словаря, например Staging, CRM или pull request, подозрительным не считается. Тест в задаче 2: `testApprovedSpellingsAreNotSuspects`.
3. **Модель оставила мусор как есть.** Ответ с «IPI» на месте по-прежнему принимается. Тест в задаче 3: `suspectKeptIsStillValid`.
4. **Модель подставила термин не из списка.** «IPI» → «SDK» отклоняется как раньше. Тест в задаче 3: `suspectReplacedByOtherTermIsRejected`.
5. **Длинная фраза с кучей латиницы.** В подсказке не больше трёх подозрительных слов, промпт не раздувается. Тест в задаче 2: `testSuspectsAreCapped`.

---

### Task 1: Замер повторяет этап словаря и считает термины

Сейчас `liveEval` отдаёт модели сырой текст распознавания, а в приложении до модели работает словарь. Без этого «до» и «после» сравнивать нельзя.

**Files:**
- Modify: `GolosokTests/Eval/CleanupEvalTests.swift:65-85`
- Create: `scripts/eval-run-local.sh`, перенос из scratchpad `run-eval.sh`
- Create: `scripts/eval-compare.py`, перенос из scratchpad `compare.py` плюс метрики терминов
- Modify: `docs/eval.md`, абзац «Повторный замер»

**Interfaces:**
- Produces: `scripts/eval-run-local.sh <model.gguf>` пишет отчёт `report-<model>-<date>.md` в `$GOLOSOK_EVAL_DIR`, по умолчанию `~/golosok-eval`. `scripts/eval-compare.py <каталог до> <каталог после>` печатает две markdown-таблицы.

- [ ] **Step 1: этап словаря в `liveEval`.** Перед `clean` дождаться индекса через `DictionaryStore.shared.waitForIndex()`. Затем вызвать чистый `DictionaryStore.shared.index?.apply(to: evalCase.raw, language: .ru)`, без `DictionaryStage.apply`, чтобы замер не трогал счётчики словаря пользователя. В `clean` передать полученный текст и `firedSpellings` — `replacements.map(\.replacement)` без повторов. Повторный проход словаря по ответу модели делается так же, как в `TranscriptionPipeline.swift:252`.
- [ ] **Step 2: `scripts/eval-run-local.sh`.** Тело из scratchpad `run-eval.sh`: каталог проекта вычисляется от расположения скрипта, лог пишется в `$GOLOSOK_EVAL_DIR/logs/`.
- [ ] **Step 3: `scripts/eval-compare.py`.** Тело из scratchpad `compare.py`, каталоги передаются аргументами. Добавить колонки:
  - **Термины на месте** — по фразам, в эталоне которых есть латиница: доля латинских слов эталона, найденных в результате без учёта регистра. Формат `0,52`.
  - **Лишние термины** — число латинских слов результата, которых нет ни в эталоне, ни в распознанном тексте, по всем 100 фразам.

  Вторая таблица — по фразам категории «термины»: id, распознано, результат до, результат после.
- [ ] **Step 4: проверка.** Запустить `python3 scripts/eval-compare.py ~/golosok-eval/baseline ~/golosok-eval/baseline`. Ожидается, что таблица печатается, а значения «до» и «после» совпадают.
- [ ] **Step 5: базовая линия.** Для трёх моделей каталога запустить `scripts/eval-run-local.sh ~/golosok-eval/models/<файл>.gguf`. Отчёты перенести в `~/golosok-eval/terms-before/`. Записать «Термины на месте» и «Лишние термины» каждой модели: это база задачи 4.
- [ ] **Step 6: коммит** `test(eval): mirror dictionary stage in live eval, count terms`.

### Task 2: Подозрительные слова и кандидаты

**Files:**
- Modify: `Golosok/Dictionary/Phonetics.swift`
- Modify: `Golosok/Dictionary/DictionaryIndex.swift`
- Test: `GolosokTests/Dictionary/PhoneticsTests.swift`
- Create: `GolosokTests/Dictionary/TermSuspectTests.swift`

**Interfaces:**
- Produces:
  - `Phonetics.soundKey(_ text: String) -> String`
  - `struct TermSuspect: Equatable { let token: String; let candidates: [String] }` в `DictionaryIndex.swift`
  - `DictionaryIndex.termSuspects(in text: String, language: DictionaryLanguage) -> [TermSuspect]`

- [ ] **Step 1: тесты звукового ключа** в `PhoneticsTests.testSoundKey`:

```swift
XCTAssertEqual(Phonetics.soundKey("IPI"), "p")
XCTAssertEqual(Phonetics.soundKey("API"), "p")
XCTAssertEqual(Phonetics.soundKey("эй пи ай"), "p")
XCTAssertEqual(Phonetics.soundKey("BB"), "pp")
XCTAssertEqual(Phonetics.soundKey("B2B"), "pp")
XCTAssertEqual(Phonetics.soundKey("жиру"), "jr")
XCTAssertEqual(Phonetics.soundKey("Jira"), "jr")
XCTAssertEqual(Phonetics.soundKey("ГИД"), "kt")
XCTAssertEqual(Phonetics.soundKey("Git"), "kt")
XCTAssertEqual(Phonetics.soundKey("Power B"), "pfrp")
XCTAssertEqual(Phonetics.soundKey("эс кью эл"), "skl")
```

- [ ] **Step 2: реализовать `soundKey`.** Порядок фиксирован, тесты его не определяют полностью:
  1. Строчные буквы. Кириллица в латиницу: а a, б b, в v, г g, д d, е ё э e, ж zh, з z, и ы й i, к k, л l, м m, н n, о o, п p, р r, с s, т t, у u, ф f, х h, ц ts, ч ch, ш щ sh, ь ъ пусто, ю u, я a.
  2. Всё, кроме a–z, выбросить, включая цифры, пробелы и `&`.
  3. Замены по порядку: dzh→j, zh→j, dj→j, ch→`C`, sh→`S`, ph→f, ck→k, th→t, q→k, x→ks, w→v, c→s. `C` и `S` — заглавные заглушки для отдельных звуков.
  4. Оглушение: b→p, d→t, g→k, v→f, z→s.
  5. Удалить a e i o u y h.

  Сдвоенные согласные не схлопывать: «BB» и «API» должны различаться.
- [ ] **Step 3: тесты кандидатов** в `TermSuspectTests` на реальных наборах. Индекс строится как в `DictionaryCorpusTests.setUpWithError`: `Bundle.main`, `SpellCommonWordChecker.shared`. Каждая пара ниже — распознанная фраза из замера и термин, который обязан быть среди кандидатов этого слова:

```swift
let cases: [(String, String, String)] = [
    ("Настрой IPI ключ для интеграции.", "IPI", "API"),
    ("Мы работаем в BB, а не в Buce.", "BB", "B2B"),
    ("Мы работаем в BB, а не в Buce.", "Buce", "B2C"),
    ("Вопрос про CNT лучше задать HR-бизнес-партнёру.", "CNT", "C&B"),
    ("Пришли Sk-запрос, я проверю.", "Sk", "SQL"),
    ("Выгрузи отчёт из Power B в PDF.", "Power B", "Power BI"),
    ("Подними версию в ГИД и поставь тег.", "ГИД", "Git"),
]
// для каждого: suspect с token == слово существует, candidates.contains(термин)
```

  Ещё три теста:
  - `testCleanPhraseHasNoSuspects`: «Антон прислал макет, проверь сроки.» → `[]`.
  - `testApprovedSpellingsAreNotSuspects`: «Открой Pull Request на Staging, обнови CRM.» → `[]`.
  - `testSuspectsAreCapped`: фраза с пятью мусорными латинскими словами «IPI BB Buce CNT Sk» → `count == 3`, у каждого `candidates.count <= 6`.
- [ ] **Step 4: реализовать `termSuspects`.** Для `language != .ru` пустой массив.
  - **Индекс при сборке** хранит для каждого написания из словаря пользователя и наборов множество ключей: `soundKey` написания и каждого русского варианта, пустые ключи отброшены.
  - **Подозрительное слово.** Латинское слово, которое не совпадает без учёта регистра ни с одним `approvedSpellings` или его словом и не общеупотребительное: `!checker.isCommonWord(_, language: .en)`. Однобуквенное латинское слово склеивается с предыдущим латинским через пробел, как «Power B», и тогда считается подозрительным целиком. Однобуквенное без соседа пропускается. Кириллическое слово подозрительно, только если оно целиком заглавное, в нём 2–5 букв и его нет в словаре.

    Кириллические слова, похожие на варианты, например «жиру» и «джиру», в первую версию не входят. Прогон по 100 фразам дал 1 верную находку на 8 ложных: «Антон» → Pantone, «срок» → Grok.
  - **Совпадение ключей.** `k` — ключ слова, `t` — ключ термина, `m = max(k.count, t.count)`, `d` — расстояние Левенштейна. Допуск: при `m <= 2` только `d == 0`, при `m` от 3 до 5 — `d <= 1`, иначе `d <= 2`. Сходство термина — лучшее `1 - d/m` по его ключам.
  - **Порядок кандидатов.** Сначала по сходству, по убыванию. При равенстве — по `Phonetics.normalizedDistance` между буквами слова в латинице и буквами написания в нижнем регистре, по возрастанию. Затем в порядке наборов. Оставить первые 6.
  - **Без кандидатов** слово в результат не попадает. В результате не больше 3 слов, в порядке появления во фразе.
- [ ] **Step 5: прогнать** `-only-testing:GolosokTests/PhoneticsTests -only-testing:GolosokTests/TermSuspectTests` и словарные наборы `DictionaryIndexTests`, `DictionaryCorpusTests`, `PackValidationTests`. Ожидается PASS.
- [ ] **Step 6: коммит** `feat(dictionary): find misrecognized terms by sound key`.

### Task 3: Подсказка в промпте и проверка замены

**Files:**
- Modify: `Golosok/ThoughtSynthesizer.swift:78-110`
- Modify: `Golosok/Dictionary/DictionaryStore.swift`, рядом с `promptHint`
- Modify: `Golosok/GroundingValidator.swift:26-31`, `:129-140`
- Test: `GolosokTests/LevelValidatorTests.swift`, `GolosokTests/Dictionary/DictionaryStoreTests.swift`

**Interfaces:**
- Consumes: `TermSuspect`, `DictionaryIndex.termSuspects(in:language:)` из задачи 2.
- Produces:
  - `DictionaryStore.termHint(_ suspects: [TermSuspect]) -> String`
  - `GroundingValidator.validate(input:output:level:customTerms:termSuspects: [TermSuspect] = [])`

- [ ] **Step 1: тест текста подсказки** `testTermHintFormat`. Пустой массив даёт `""`. Для двух слов ожидается ровно:

```
Распознавание могло исказить термины. Замени слово на термин, только если он подходит по смыслу фразы.
«IPI»: API, IPO
«BB»: B2B, P2P
```

- [ ] **Step 2: реализовать `termHint`** точно по тексту выше, строки через `\n`.
- [ ] **Step 3: тесты проверки** в `LevelValidatorTests`. `s` — `[TermSuspect(token: "IPI", candidates: ["API", "IPO"])]`, уровень `.clean`, `customTerms` — `["API", "IPO", "SDK", "Git"]`:
  - `suspectReplacedByCandidateIsValid`: «Настрой IPI ключ для интеграции.» → «Настрой API-ключ для интеграции.» — `.valid`.
  - `suspectKeptIsStillValid`: тот же вход → «Настрой IPI ключ для интеграции.» — `.valid`.
  - `suspectReplacedByOtherTermIsRejected`: тот же вход → «Настрой SDK ключ для интеграции.» — `.rejected`, причина начинается с «Пропущен исходный термин».
  - `droppedLatinWithoutSuspectIsRejected`: тот же вход и выход, что в первом тесте, но `termSuspects: []` — `.rejected`. Это сегодняшнее поведение.
  - `cyrillicSuspectReplacedIsValid`: «Подними версию в ГИД и поставь тег релиза.» → «Подними версию в Git и поставь тег релиза.» с `TermSuspect(token: "ГИД", candidates: ["Git"])` — `.valid`.
- [ ] **Step 4: реализовать правило в `validate`.** В проверке «Пропущен исходный термин», строка 136, латинское слово входа можно пропустить, если оно входит в `token` какого-то подозрения: для «Power B» это оба слова. При этом хотя бы один кандидат этого подозрения должен встречаться в выходе как слово или последовательность слов без учёта регистра. Добавить «IPI» в разрешённые слова `rewriteViolation`, только если на его месте стоит кандидат. Иначе «пересказ своими словами» отклонит ту же замену.
- [ ] **Step 5: подключить в `ThoughtSynthesizer.clean`.** После `stageOne`:

```swift
let suspects = language == .ru ? (DictionaryStore.shared.index?.termSuspects(in: stageOne, language: language) ?? []) : []
```

  Если массив не пуст, добавить `"\n\n" + DictionaryStore.shared.termHint(suspects)` после словарной подсказки и записать в лог `info("Pipeline", "Этап 2: подсказка терминов", details: <подсказка>)`. В `GroundingValidator.validate` передать `termSuspects: suspects`.
- [ ] **Step 6: прогнать** `LevelValidatorTests`, `DictionaryStoreTests`, `VoiceIntelligencePhase2Tests`, `VoiceIntelligencePhase4Tests`, `CleanupEvalTests` без живого замера. Ожидается PASS. `cleanStyleStrictExtractionPreservesNumbersAndRejectsHallucinations` уже падал до этого плана: сравнить с `git stash` и не чинить здесь, если падение старое.
- [ ] **Step 7: коммит** `feat(cleanup): hint misrecognized terms to the model and accept the fix`.

### Task 4: Замер и решение

**Files:**
- Modify: `docs/eval-local-models-2026-11.md`, новый раздел «Подсказка терминов»

- [ ] **Step 1: прогон.** Для трёх моделей каталога запустить `scripts/eval-run-local.sh`, отчёты перенести в `~/golosok-eval/terms-after/`.
- [ ] **Step 2: сравнение.** Запустить `python3 scripts/eval-compare.py ~/golosok-eval/terms-before ~/golosok-eval/terms-after`.
- [ ] **Step 3: решение по критериям.** Подсказка остаётся, если для Gemma 4 E4B QAT выполнено всё:
  - исправлены хотя бы 4 из 6 фраз p067, p068, p071, p072, p075, p077;
  - «Лишних терминов» не больше, чем в базе;
  - похожесть вне категории «термины» упала не больше чем на 0,005;
  - медиана выросла не больше чем на 0,03 с;
  - принятых не меньше, чем в базе, минус 1.

  Если хоть одно не выполнено, сначала проверить по разбору: виновата одна модель или правило подозрительных слов. Если правило — поправить порог в задаче 2 и повторить замер один раз. Не помогло — убрать вызов из `ThoughtSynthesizer.clean`, оставив код и тесты, и записать причину.
- [ ] **Step 4: раздел в отчёт.** Таблица «до → после» по трём моделям: похожесть, термины на месте, лишние термины, принято, медиана. Таблица по фразам терминов. Одна строка решения. Отдельно перечислить, что подсказка не лечит:
  - пропавшее слово, p073 Slack;
  - не термины, p063 «The Ley Fix», p074 «Афиче»;
  - кириллические похожие слова, p065 «жиру».
- [ ] **Step 5: коммит** `docs(eval): measure term hints on 100 phrases`.
