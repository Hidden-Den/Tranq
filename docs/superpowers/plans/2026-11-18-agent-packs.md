# Наборы агента Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Агент через MCP создаёт тематический набор слов, наполняет, правит и удаляет его; человек видит набор рядом со встроенными, включает, выключает и удаляет целиком.

**Architecture:** Наборы агента лежат в `dictionary.json` отдельным списком `agentPacks`, схема остаётся версии 1. `DictionaryStore.packs` равен встроенным наборам плюс наборам агента, поэтому экран, поиск, индекс и множества выключения работают без изменений. Дверь получает три команды и необязательный `pack_id` у двух прежних, Go-сервер получает три инструмента и то же поле у двух прежних.

**Tech Stack:** Swift 5 с Swift Testing и XCTest, SwiftUI, Go 1.27 с vendored `github.com/modelcontextprotocol/go-sdk` v1.8.0.

**Spec:** `docs/superpowers/specs/2026-11-18-agent-packs-design.md`. Читать вместе с планом: он описывает причины решений. Продолжает `docs/superpowers/specs/2026-11-18-mcp-server-design.md` и `mcp/PROTOCOL.md`.

## Global Constraints

- Ветка `feat/agent-packs` от `feat/mcp-server`. Коммиты по шагам, **без push и без PR** до отдельной просьбы пользователя. Неотслеживаемый `CLAUDE.md` в корне не коммитить, `git add` только названных файлов.
- Каждый коммит заканчивается строкой `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Версия остаётся 3.2: `MARKETING_VERSION` не трогать.
- Идентификатор набора агента: `agent-` и 8 строчных шестнадцатеричных знаков, не совпадает со встроенными и не начинается с `user/`.
- Пределы: 20 наборов агента, 500 слов в наборе, 50 слов за один `add_words`, название 1 до 60 знаков после обрезки пробелов по краям.
- Название одно на оба языка: `title[.ru] == title[.en]`. Совпадение без учёта регистра с названием встроенного набора на любом языке отвергается. Совпадение с названием набора агента не ошибка: `create_pack` возвращает существующий набор с `created: false`, и это верно и на пределе в 20 наборов.
- Доступ: `create_pack`, `delete_pack`, `pack_words`, `add_words` и `remove_words` с `pack_id` требуют только включённый доступ. `set_pack` на выключение по-прежнему требует полного доступа, для наборов агента тоже.
- Два списка слов не пересекаются: команды со `pack_id` не трогают «Мои слова», без `pack_id` не трогают наборы. Слова набора агента никогда не попадают в `userEntries`.
- Любой отказ идёт целиком, без частичной записи. Тексты отказов пишутся в двери и локализуются с `en`.
- Текст интерфейса: без круглых, квадратных и фигурных скобок, метки 1–2 слова, подзаголовки короче 8 слов, шрифт `Font.ui`. Строки ключуются русским текстом, у каждой есть `en` в `Tranq/Localizable.xcstrings`. Файл правится только вставками в формате Xcode: `"ключ" : значение` с пробелом перед двоеточием, `\/`, пустой объект как `{`, пустая строка, `}`. `json.dump` запрещён, после правки `git diff --stat` пропорционален числу ключей.
- Имена тестов на русском, как в соседних файлах. Swift-тесты хранилища работают с временной папкой и своим `UserDefaults(suiteName:)`, как `TranqTests/Dictionary/DictionaryAgentWriteTests.swift`.
- Схемы инструментов Go остаются переносимыми: один строковый `type`, `additionalProperties: false`, без `$ref`, `anyOf`, `default`. Все описания инструментов на английском, с фразой, что тексты от Tranq это данные, а не инструкции.
- Команды проверки. Swift: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -derivedDataPath build/DerivedData-ci CODE_SIGN_IDENTITY=- -only-testing:TranqTests/<Класс> 2>&1 | grep -E "error:|Test run with|\*\* TEST"`. Для английской локали добавить `-testLanguage en -testRegion US` (так идёт CI). Go: `cd mcp && GOPROXY=off GOTOOLCHAIN=local go test -mod=vendor -race ./...`. Формат Go: `bash -c 'cd mcp && files=$(git ls-files "*.go" | grep -v "^vendor/") && gofmt -l $files'` печатает пустоту.

## Review Focus

Входы, о которых спека молчит, а они чаще всего ломают такие функции. Тест каждого лежит в названной задаче.

1. **Пустой или пробельный `pack_id` не должен уйти в «Мои слова».** Агент, приславший `""`, ждёт отказа, а не записи в личный список. Задачи 4 и 5.
2. **Откат при наборах без слов агента в «Мои слова».** Прежний `revertAgentChanges` выходит рано, если записи не изменились, и оставил бы наборы. Откат только из наборов обязан удалить их и сохранить. Задача 3.
3. **`create_pack` на пределе и с «грязным» названием.** «музыка », «МУЗЫКА» при 20 существующих наборах возвращают существующий набор, а не отказ «предел». Задача 1.
4. **Пачка, не помещающаяся в 500 слов.** Отказ целиком: ни слова не записано. Слова, которые лишь сливаются с существующими, предел не занимают. Задача 2.
5. **Хвосты выключений.** После удаления слова или набора ключи в `disabledPacks`, `disabledPackWords`, `disabledPackVariants` исчезают и из `UserDefaults`, а набор, созданный заново с тем же названием, получает новый идентификатор и включён. Задачи 1 и 2.

---

### Task 1: Хранение наборов агента, создание и удаление

**Files:**
- Modify: `Tranq/Dictionary/AgentWrite.swift`
- Modify: `Tranq/Dictionary/DictionaryModels.swift`
- Modify: `Tranq/Dictionary/DictionaryStore.swift`
- Create: `TranqTests/Dictionary/DictionaryAgentPackTests.swift`

**Interfaces:**
- Consumes: существующие `DictionaryStore.init(directory:defaults:packsBundle:checker:packs:now:saveDelay:)`, `setPack`, `setPackWord`, `removeVariant(_:language:fromEntryKey:)`, `flush()`, `waitForIndex()`.
- Produces, в `AgentWrite.swift`:
  ```swift
  struct AgentPackCreateResult: Equatable { var id: String; var title: String; var created: Bool }
  struct AgentPackDeleteResult: Equatable { var id: String; var title: String; var removedWords: Int }
  enum AgentPackError: Error, Equatable {
      case emptyTitle
      case titleTooLong(limit: Int)
      case titleTakenByBuiltIn
      case tooManyPacks(limit: Int)
      case builtInPack(id: String)
      case noSuchPack(id: String)
      case tooManyWords(limit: Int, free: Int)
  }
  ```
  и в `AgentRevertResult` поле `var removedPacks = 0` с значением по умолчанию, чтобы прежние вызовы `AgentRevertResult(removedWords:removedVariants:)` компилировались.
- Produces, в `DictionaryModels.swift`: `DictionaryPack: Equatable` (синтезируется, все поля уже `Equatable`).
- Produces, в `DictionaryStore`:
  ```swift
  static let maxAgentPacks = 20
  static let maxWordsPerAgentPack = 500
  static let maxAgentPackTitleLength = 60
  @Published private(set) var agentPacks: [DictionaryPack]   // порядок создания
  // packs == встроенные + agentPacks, всегда; переприсваивается при каждом изменении agentPacks
  func createAgentPack(title: String) throws -> AgentPackCreateResult
  func deleteAgentPack(id: String) throws -> AgentPackDeleteResult
  func agentPack(id: String) throws -> DictionaryPack   // .builtInPack или .noSuchPack
  ```
  Остальные задачи опираются на эти имена.

- [ ] **Step 1: Write the failing tests** в `DictionaryAgentPackTests.swift`: `@MainActor final class`, поля и `init`/`deinit` как в `DictionaryAgentWriteTests`, `makeStore(packs: [DictionaryPack] = [])` с `SetCommonWordChecker([:])`, `reload(packs:)` создаёт второй `DictionaryStore` на той же папке и `defaults` после `flush()` первого. Встроенный набор для тестов: `id: "med"`, названия `[.ru: "Медицина", .en: "Medicine"]`.
  - `созданиеНабораДаётИдентификаторИНазваниеНаОбоихЯзыках`: результат `created == true`, `id` подходит под `^agent-[0-9a-f]{8}$`, `title == "Музыка"`, у набора в `store.agentPacks` `title[.ru] == "Музыка"`, `title[.en] == "Музыка"`, `version == 1`, `entries.isEmpty`, `store.packs.last?.id == id`, встроенный набор остаётся первым.
  - `повторноеСозданиеСТемЖеНазваниемВозвращаетТотЖеНабор`: после «Музыка» вызовы с «музыка », «МУЗЫКА» возвращают тот же `id` и `created == false`, `agentPacks.count == 1`.
  - `названиеВстроенногоНабораОтвергается`: «медицина» и «MEDICINE» бросают `.titleTakenByBuiltIn`, `agentPacks.isEmpty`.
  - `пустоеИСлишкомДлинноеНазвание`: `"   "` бросает `.emptyTitle`; 61 знак бросает `.titleTooLong(limit: 60)`; ровно 60 знаков проходит. Знаки считаются как `Character`.
  - `впределеДвадцатиНаборовНовыйОтвергаетсяАСуществующийВозвращается`: 20 разных названий созданы; 21-е бросает `.tooManyPacks(limit: 20)`, число остаётся 20; повтор любого из 20 названий возвращает его с `created == false`.
  - `наборыПереживаютПерезагрузку`: два набора, `reload()` возвращает `agentPacks` равные исходным и в том же порядке, `packs` тоже.
  - `старыйФайлБезНаборовЧитается`: в папку записан `{"schemaVersion":1,"entries":[]}`, новое хранилище поднимается с `agentPacks.isEmpty`.
  - `испорченныйФайлСНаборамиУходитВCorruptИВосстанавливаетсяИзКопии`: создать «Музыка», `flush()`, создать «Кино», `flush()` (теперь копия хранит только «Музыка»), перезаписать `dictionary.json` текстом `{"schemaVersion":1,"entries":[],"agentPacks":"oops"}`; новое хранилище читает `agentPacks.map(\.id)` равным id «Музыка», `dictionary.corrupt.json` существует.
  - `загрузкаОтбрасываетПовторИдентификатораИСовпадениеСоВстроенным`: файл с тремя наборами агента, у двух одинаковый `id`, у третьего `id == "med"`; остаётся первый из повторяющихся пары, остальные отброшены.
  - `удалениеНабораЧиститВыключенияИТолькоЕго`: набор «Музыка» и встроенный `med`; `setPack(id, enabled: false)`, `setPackWord("\(id)/Слово", enabled: false)`, `removeVariant("вар", language: .ru, fromEntryKey: "\(id)/Слово")`, а для встроенного `setPackWord("med/Аспирин", enabled: false)`. После `deleteAgentPack(id:)` в `disabledPacks`, `disabledPackWords`, `disabledPackVariants` нет ни одного ключа, равного `id` или начинающегося с `"\(id)/"`, ключ `med/Аспирин` на месте, и те же множества в `defaults` (`dictionary.disabledPacks`, `.disabledPackWords`, `.disabledPackVariants`) не содержат ключей набора. Результат `removedWords == 0`, `title == "Музыка"`.
  - `наборСозданныйЗановоПослеУдаленияВключёнИИмеетНовыйИдентификатор`: «Музыка» выключен через `setPack`, удалён, создан снова: `id` другой, `disabledPacks.contains(newId) == false`.
  - `удалениеВстроенногоИНеизвестного`: `deleteAgentPack(id: "med")` бросает `.builtInPack(id: "med")`, `deleteAgentPack(id: "agent-00000000")` бросает `.noSuchPack(id: "agent-00000000")`, встроенный набор на месте. `agentPack(id:)` бросает те же ошибки и возвращает набор агента по его `id`.
- [ ] **Step 2: Run to verify they fail** (не компилируются: нет типов). Команда: Swift, класс `DictionaryAgentPackTests`. Expected: сборка падает на неизвестных `createAgentPack`, `AgentPackError`.
- [ ] **Step 3: Add the types** в `AgentWrite.swift` и `Equatable` в `DictionaryModels.swift` по блоку Interfaces.
- [ ] **Step 4: Persist `agentPacks` in `DictionaryStore`.** `StoredFile` получает `var agentPacks: [DictionaryPack]?` (ключ необязателен, nil не пишется). Снимок отложенного сохранения вместо `pendingEntries: [DictionaryEntry]?` содержит оба списка; `scheduleSave`, `writePending`, `write` и чтение (`loadEntries`, `readEntries`) переводятся на `StoredFile`, поведение копии и `dictionary.corrupt.json` не меняется. Хранилище держит встроенные наборы в `private let builtinPacks` и переприсваивает `packs = builtinPacks + agentPacks` в `didSet` у `agentPacks`, а в `init` после загрузки присваивает явно (наблюдатели в `init` не срабатывают). При загрузке наборы с повторным `id` и с `id`, равным id встроенного, отбрасываются с `AppLogger.shared.warn("Dictionary", ...)`.
- [ ] **Step 5: Implement `createAgentPack`, `deleteAgentPack`, `agentPack(id:)`** внутри `onMain`. Порядок проверок `createAgentPack`: обрезать пробелы по краям, пусто, длина, совпадение с названием встроенного на любом языке без учёта регистра (`caseInsensitiveCompare`), существующий набор агента с тем же названием (возврат с `created: false`), предел 20, создание. Идентификатор это `agent-` и первые 8 знаков `UUID().uuidString.lowercased()`, взятые до первого дефиса; генерация повторяется, пока такой `id` есть среди `packs`. После создания и удаления: `scheduleSave()` и `rebuildIndex()`. `deleteAgentPack` убирает из `disabledPacks` сам `id`, из `disabledPackWords` и `disabledPackVariants` ключи с префиксом `"\(id)/"`, и сохраняет изменённые множества в `defaults` тем же способом, что `setPack`, `setPackWord`.
- [ ] **Step 6: Run to verify they pass.** Swift, класс `DictionaryAgentPackTests`, затем `DictionaryStoreTests` и `DictionaryAgentWriteTests`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 7: Commit**
  ```bash
  git add Tranq/Dictionary/AgentWrite.swift Tranq/Dictionary/DictionaryModels.swift Tranq/Dictionary/DictionaryStore.swift TranqTests/Dictionary/DictionaryAgentPackTests.swift
  git commit -m "feat: store agent packs in the dictionary file"
  ```

---

### Task 2: Слова в наборе агента

**Files:**
- Modify: `Tranq/Dictionary/DictionaryStore.swift`
- Modify: `TranqTests/Dictionary/DictionaryAgentPackTests.swift`

**Interfaces:**
- Consumes: Task 1 (`agentPacks`, `agentPack(id:)`, `AgentPackError`, `maxWordsPerAgentPack`), существующие `AgentWord`, `AgentWriteResult`, приватные `agentVariantRejection(_:spelling:)` и `mergedVariants(_:_:)` в `DictionaryStore`.
- Produces:
  ```swift
  @discardableResult
  func addToAgentPack(id: String, words: [AgentWord]) throws -> AgentWriteResult
  @discardableResult
  func removeFromAgentPack(id: String, spellings: [String]) throws -> AgentWriteResult
  ```
  `AgentWriteResult.added` для `removeFromAgentPack` содержит снятые написания, как у `removeFromAgent`.

- [ ] **Step 1: Write the failing tests** в `DictionaryAgentPackTests.swift`. Помощник `makePack(_ store:) -> String` создаёт «Музыка» и возвращает `id`.
  - `словоЛожитсяВНаборАНеВМоиСлова`: `addToAgentPack(id:, words: [AgentWord(spelling: "Ableton", variants: [.ru: ["эйблтон"]], forceCase: false)])` даёт `added == ["Ableton"]`, `skipped.isEmpty`, у набора `entries.map(\.spelling) == ["Ableton"]`, `entries[0].variants[.ru] == ["эйблтон"]`, `store.userEntries.isEmpty`, `store.agentWordCount` не меняется этим тестом (проверяется в Task 3).
  - `повторБезУчётаРегистраСливаетВариантыИНеДублирует`: «Ableton» с `[эйблтон]`, затем «ableton» с `[эйблтон, аблтон]`: одна запись, написание «Ableton», `variants[.ru] == ["эйблтон", "аблтон"]`, `added == ["ableton"]`.
  - `негодныйВариантОтбрасываетсяАСловоПроходит`: варианты `["к", "ableton", "эйблтон"]` у «Ableton»: `added == ["Ableton"]`, `skipped["Ableton / к"]` и `skipped["Ableton / ableton"]` непусты, `variants[.ru] == ["эйблтон"]`.
  - `пустоеНаписаниеИПовторВЗапросеПропускаются`: `["", "Serum", "serum"]` даёт `added == ["Serum"]`, у `skipped` ключи `""` и `"serum"` с причинами.
  - `commonInСчитаетсяПравиломСкрипта`: хранилище с `SetCommonWordChecker([.ru: ["кубик"], .en: ["reaper"]])`. Слово «Кубик» получает `commonIn == [.ru]`, «Reaper» `[.en]`, «Kubernetes» `[]`, «n8n» `[]` (цифры), «FL Studio» `[]`, «Logic Pro» `[]`.
  - `предел500СловАтомарен`: набор доведён до 500 слов (`слово0`…`слово499` одним вызовом хранилища). Новое слово бросает `.tooManyWords(limit: 500, free: 0)`, `entries.count == 500`. После `removeFromAgentPack` одного слова в набор помещается ровно одно: пачка из двух новых слов бросает `.tooManyWords(limit: 500, free: 1)` и не записывает **ни одного**, пачка из одного нового и одного повтора уже существующего проходит. На 500 словах пачка только из повторов существующих слов проходит.
  - `добавлениеВВстроенныйИНеизвестныйНабор`: `.builtInPack(id: "med")` и `.noSuchPack(id: "agent-00000000")`, встроенный набор не изменён.
  - `снятиеСловаБезУчётаРегистраИПричиныОтказов`: после `["ABLETON", "нет", "ABLETON"]` из набора с «Ableton»: `added == ["ABLETON"]`, `skipped["нет"]` и `skipped["ABLETON"]` (повтор) непусты, `entries.isEmpty`. Набор остаётся в `agentPacks`, пустой.
  - `снятиеСловаЧиститВыключенияЭтогоСлова`: `setPackWord("\(id)/Ableton", enabled: false)`, `removeVariant("эйблтон", language: .ru, fromEntryKey: "\(id)/Ableton")`, ключ другого слова `"\(id)/Serum"` выключен; после снятия «Ableton» его два ключа ушли из множеств и из `defaults`, ключ «Serum» остался. Добавление «Ableton» заново даёт слово включённым.
  - `спискиНеПересекаются`: «Мои слова» содержат «Serum» (`addEntry`), набор тоже; `removeFromAgentPack(["Serum"])` оставляет запись в `userEntries`, а `removeFromAgent(spellings: ["Serum"], fullAccess: true)` оставляет слово в наборе.
  - `словаНабораПереживаютПерезагрузку`: слово с вариантами и `commonIn` после `flush()` и `reload()` равно исходному.
- [ ] **Step 2: Run to verify they fail.** Expected: сборка падает на `addToAgentPack`.
- [ ] **Step 3: Implement `addToAgentPack(id:words:)`** внутри `onMain`. Алгоритм: `agentPack(id:)` для проверки набора; первый проход считает, сколько слов реально станут новыми записями (не пустое написание, не повтор без учёта регистра в этом запросе, нет в наборе без учёта регистра) и бросает `.tooManyWords(limit: 500, free: 500 - entries.count)` до любой записи; второй проход пишет. Отбор вариантов как в `addFromAgent`: обрезка пробелов, `agentVariantRejection`, причина в `skipped` под ключом `"\(spelling) / \(variant)"`. Слияние вариантов через `mergedVariants`. `forceCase` игнорируется: у `PackEntry` его нет. Новая запись: `PackEntry(spelling:, variants:, commonIn:)`, `commonIn` считается приватным `commonLanguages(for:)` по правилу `scripts/annotate-dictionaries.swift`: буквы без пробелов; все кириллические (U+0400–U+04FF) дают кандидата `.ru`, все ASCII `.en`, иначе кандидатов нет; из кандидатов остаются те, для которых `checker.isCommonWord(spelling, language:)`. Одно присваивание `agentPacks` и одно сохранение на вызов.
- [ ] **Step 4: Implement `removeFromAgentPack(id:spellings:)`** по образцу `removeFromAgent`: причины отказов «такого слова нет в наборе», «повтор в списке», `fullAccess` не нужен. Для каждого снятого слова из `disabledPackWords` убирается `"\(id)/\(spelling)"`, из `disabledPackVariants` ключи с префиксом `"\(id)/\(spelling)/"`, множества сохраняются в `defaults`. Пустой набор остаётся.
- [ ] **Step 5: Run to verify they pass.** Swift, класс `DictionaryAgentPackTests`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 6: Commit**
  ```bash
  git add Tranq/Dictionary/DictionaryStore.swift TranqTests/Dictionary/DictionaryAgentPackTests.swift
  git commit -m "feat: add and remove words in agent packs"
  ```

---

### Task 3: Откат, счётчик и замена слов из наборов агента

**Files:**
- Modify: `Tranq/Dictionary/DictionaryStore.swift`
- Modify: `TranqTests/Dictionary/DictionaryAgentPackTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2, существующие `revertAgentChanges() -> AgentRevertResult`, `agentWordCount`, `DictionaryStore.index`, `waitForIndex()`, `DictionaryIndex.apply(to:language:).text`.
- Produces: `revertAgentChanges()` заполняет `removedPacks`; `agentWordCount` включает слова наборов агента; новых публичных имён нет. Для UI Task 6 хранилище отдаёт `agentPacks` (Task 1).

- [ ] **Step 1: Write the failing tests** в `DictionaryAgentPackTests.swift`.
  - `откатУдаляетНаборыСчитаетИхИЧиститВыключения`: слово агента в «Мои слова» (`addFromAgent`), два набора агента со словами и выключениями (`setPack`, `setPackWord`, вариант), выключение встроенного `med/Аспирин`. `revertAgentChanges()` возвращает `removedWords == 1`, `removedPacks == 2`; `agentPacks.isEmpty`, `packs.map(\.id) == ["med"]`, ключей наборов агента нет в трёх множествах и в `defaults`, ключ `med/Аспирин` на месте. После `flush()` и `reload()` наборов нет.
  - `откатТолькоИзНаборовБезСловАгентаВМоихСловах`: в «Мои слова» одно ручное слово, наборы есть, слов агента нет. Откат даёт `removedWords == 0`, `removedPacks == N`, `agentPacks.isEmpty`, после `flush()` и `reload()` наборов нет, ручное слово цело.
  - `откатБезЧегоЛибоНичегоНеМеняетИДаётНули`: пустое хранилище, результат `AgentRevertResult(removedWords: 0, removedVariants: 0)` с `removedPacks == 0`.
  - `счётчикАгентаВидитСловаНаборов`: `agentWordCount == 0` у пустого набора и у набора без слов агента; два слова в наборе дают `2` вместе с одним словом агента в «Мои слова» `== 3`; после отката `0`.
  - `индексЗаменяетВариантИзНабораАгента`: после `waitForIndex()` фраза «эйблтон» с `language: .ru` даёт «Ableton».
  - `встроенныйНаборВыигрываетПриСовпаденииВарианта`: встроенный `med` и набор агента имеют вариант «аспирин» с разными написаниями, побеждает встроенный.
  - `выключенныйНаборИВыключенноеСловоНеПрименяются`: `setPack(id, enabled: false)` убирает замену, обратно включает; `setPackWord("\(id)/Ableton", enabled: false)` убирает замену только этого слова.
  - `записьПользователяВажнееНабораАгента`: «Мои слова» и набор агента заявляют один вариант с разными написаниями, побеждает «Мои слова».
  - `удалённыйНаборПерестаётЗаменять`: после `deleteAgentPack` замена пропала.
- [ ] **Step 2: Run to verify they fail.** Expected: падают `removedPacks`, счётчик, откат из наборов.
- [ ] **Step 3: Extend `revertAgentChanges()`.** Откат дополнительно удаляет все наборы агента и чистит их ключи выключений теми же правилами, что `deleteAgentPack` (общая приватная функция, чтобы правило было одно). Ранний выход «записи не изменились» не должен пропускать удаление наборов: сохранение и пересборка индекса идут, если изменились записи **или** наборы. Результат получает `removedPacks`.
- [ ] **Step 4: Extend `agentWordCount`.** К прежнему подсчёту прибавляется число слов во всех наборах агента.
- [ ] **Step 5: Run to verify they pass.** Swift: `DictionaryAgentPackTests`, `DictionaryAgentWriteTests`, `DictionaryIndexTests`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 6: Commit**
  ```bash
  git add Tranq/Dictionary/DictionaryStore.swift TranqTests/Dictionary/DictionaryAgentPackTests.swift
  git commit -m "feat: revert agent packs and count their words"
  ```

---

### Task 4: Дверь, доступ и протокол

**Files:**
- Modify: `Tranq/MCP/MCPAccess.swift`
- Modify: `Tranq/MCP/MCPDoor.swift`
- Modify: `Tranq/Localizable.xcstrings`
- Modify: `mcp/PROTOCOL.md`
- Modify: `TranqTests/MCP/MCPAccessTests.swift`
- Modify: `TranqTests/MCP/MCPDoorTests.swift`
- Modify: `TranqTests/MCP/MCPLocalizationTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 (`createAgentPack`, `deleteAgentPack`, `agentPack(id:)`, `addToAgentPack`, `removeFromAgentPack`, `AgentPackError`, `agentPacks`, `AgentRevertResult.removedPacks`).
- Produces: команды двери, на которые опирается Task 5. Точные формы, они же строки в `PROTOCOL.md`:
  | cmd | args | data |
  |---|---|---|
  | `create_pack` | `{"title"}` | `{"id","title","created"}` |
  | `delete_pack` | `{"id"}` | `{"id","title","removed_words"}` |
  | `pack_words` | `{"id"}` | `[{"spelling","variants":{"ru":[…],"en":[…]}}]`, оба языка всегда |
  | `add_words`, `remove_words` | прежние плюс необязательный `"pack_id"` | прежние |
  | `packs`, `set_pack` | как прежде | у объекта набора добавлено `"source":"builtin"` или `"agent"` |
  | `revert_agent_words` | нет | `{"removed_words","removed_variants","removed_packs"}` |
  `MCPCommandName` получает `createPack = "create_pack"`, `deletePack = "delete_pack"`, `packWords = "pack_words"`. Заголовки названий наборов в ответах идут через `DictionaryScreenLogic.packTitle(_, uiLanguage: language)`.
  Правила `pack_id`: ключ отсутствует или `null` значит «Мои слова»; любое значение кроме непустой строки без одних пробелов, включая `""`, `"  "`, число, булево, даёт отказ и **ничего не пишет**.

- [ ] **Step 1: Write the failing tests.**
  - `MCPAccessTests`: в списке «разрешено при включённом доступе» (`for command in [MCPCommandName.packs, .words, ...]`, около строки 113) добавить `.createPack, .deletePack, .packWords`; тест «без доступа любая команда отклоняется» уже обходит `allCases` и покроет их сам.
  - `MCPDoorTests` (помощники `makeSetup`, `request`, `parse`, `isOK` в файле есть; `makeSetup` подставляет встроенные `it`, `legal`):
    - `packsПоказываетИсточник`: у `it` `source == "builtin"`, у созданного набора `source == "agent"`; `set_pack` возвращает объект с `source`.
    - `createPackСоздаётНабор`: `create_pack {"title":"Музыка"}` даёт `ok`, `created == true`, `id` подходит под `^agent-[0-9a-f]{8}$`, `title == "Музыка"`; повтор с «музыка » даёт `created == false` и тот же `id`.
    - `createPackОтказы`: без `title`, `title` числом, пустое, 61 знак, `"Программирование"` (название встроенного) и `"programming"`: каждый `ok == false` с непустым `error`, `dictionary.agentPacks` пуст. Двадцать первый набор: `ok == false`.
    - `addWordsСPackIdПишетВНаборНеВМоиСлова`: после `create_pack` слово уходит в набор, `dictionary.userEntries.isEmpty`, `pack_words` возвращает `[{"spelling":"Ableton","variants":{"ru":["эйблтон"],"en":[]}}]`.
    - `addWordsСНедопустимымPackIdОтказИНичегоНеЗаписано`: `pack_id` равный `""`, `"   "`, `42`, `true`, `"it"` (встроенный), `"agent-00000000"` (неизвестный): `ok == false`, `error` непустой, `dictionary.userEntries.isEmpty` и ни один набор не изменился. `"pack_id": null` пишет в «Мои слова».
    - `addWordsПределыПачкиИНабора`: 51 слово со `pack_id` отклоняется целиком существующим отказом пачки; набор заполнен до 500 слов вызовом `dictionary.addToAgentPack` напрямую, после чего ещё одно новое слово через дверь даёт `ok == false` с текстом про предел и ничего не меняет.
    - `removeWordsСPackIdНеТрогаетМоиСлова`: при `fullAccess == false` слово снимается из набора, одноимённое в «Мои слова» остаётся; без `pack_id` слово из набора остаётся. Неизвестный и встроенный `pack_id` дают отказ.
    - `deletePack`: возвращает `removed_words` равное числу слов и `title`; встроенный и неизвестный `id` дают отказ; набор исчез из `packs`.
    - `packWordsВстроенныйИНеизвестныйОтказ`.
    - `revertAgentWordsВозвращаетRemovedPacks`: после двух наборов `removed_packs == 2`, `packs` показывает только встроенные.
    - `выключениеНабораАгентаТребуетПолногоДоступа`: `set_pack {"id":<агент>,"enabled":false}` без полного доступа отказ с тем же текстом, что даёт `MCPAccess.verdict`, с полным доступом проходит, включение проходит всегда.
    - `новыеКомандыПриВыключенномДоступеДаютОтказШлюза`: три команды при `enabled == false` возвращают текст `MCPAccess` и ничего не меняют.
  - `MCPLocalizationTests.addedKeys`: добавить все новые ключи из шага 4.
- [ ] **Step 2: Run to verify they fail.** Swift: `MCPAccessTests`, `MCPDoorTests`, `MCPLocalizationTests`. Expected: сборка падает на `.createPack`.
- [ ] **Step 3: Extend `MCPCommandName` and `MCPAccess.verdict`**: три новых случая разрешены при включённом доступе, в одной ветке с `.packs, .words, ...`.
- [ ] **Step 4: Implement the door.** В `run` добавить три команды в `switch`; `packObject` получает `"source"`, определяемый по `dictionary.agentPacks`. Приватные `createPack(_:)`, `deletePack(_:)`, `packWords(_:)`; `addWords` и `removeWords` читают `pack_id` приватным `packID(_ args:) throws -> String?` по правилу из Interfaces и при наличии идут в `addToAgentPack` и `removeFromAgentPack`. `AgentPackError` превращается в `Refusal` одной функцией со следующими текстами, они же новые ключи `Localizable.xcstrings` с `en`:
  - `Для набора нужно поле title со строкой.`
  - `Название набора не может быть пустым.`
  - `Название набора длиннее %lld знаков.`
  - `Такое название у встроенного набора. Выберите другое.`
  - `Наборов агента уже %lld, это предел. Удалите ненужный набор.`
  - `Это встроенный набор. Работать можно только с наборами агента.`
  - `В наборе не больше %lld слов, свободно %lld. Ничего не записано.`
  - `Поле pack_id должно быть непустой строкой.`
  - `.noSuchPack` использует уже существующий ключ `Набора %@ нет. Список наборов даёт команда packs.`
  Ответ `revert_agent_words` получает `"removed_packs"`.
- [ ] **Step 5: Update `mcp/PROTOCOL.md`**: таблицу команд (три новые строки, правки `packs`, `add_words`, `remove_words`, `revert_agent_words`) и раздел «Правила»: `pack_id` и его отказы, доступ новых команд, правило списков, пределы 20, 500 и 50, `set_pack` по-прежнему требует полного доступа.
- [ ] **Step 6: Run to verify they pass**, в обеих локалях: Swift `MCPAccessTests`, `MCPDoorTests`, `MCPLocalizationTests`, `MCPSocketServerTests`, затем снова с `-testLanguage en -testRegion US`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 7: Commit**
  ```bash
  git add Tranq/MCP Tranq/Localizable.xcstrings mcp/PROTOCOL.md TranqTests/MCP
  git commit -m "feat: add the agent pack commands to the MCP door"
  ```

---

### Task 5: Инструменты MCP на Go

**Files:**
- Create: `mcp/tools/packs.go`
- Create: `mcp/tools/packs_test.go`
- Modify: `mcp/tools/tools.go` (в `Register` строка `registerPacks(s, d)`)
- Modify: `mcp/tools/write.go`
- Modify: `mcp/tools/read.go`
- Modify: `mcp/main.go` (константа `instructions`)
- Modify: `mcp/tools/write_test.go`, `mcp/tools/read_test.go`, `mcp/main_test.go`

**Interfaces:**
- Consumes: команды двери из Task 4 по точным формам.
- Produces: десять инструментов. Новые: `create_pack` (вход `{title}`, дверь `create_pack` с `{"title":"…"}`), `delete_pack` (вход `{id}`, дверь `delete_pack` с `{"id":"…"}`), `list_pack_words` (вход `{id}`, дверь `pack_words` с `{"id":"…"}`). Поля входа обязательны. Прежние: `addWordsInput` и `removeWordsInput` получают `PackID *string \`json:"pack_id"\``, `doorWords` и `doorSpellings` получают после прежних полей `PackID *string \`json:"pack_id,omitempty"\``. Указатель нужен, чтобы `""` дошёл до двери и был там отклонён, а не пропал. Подсказки: `create_pack` `writing("Create an agent pack", false, true)`, `delete_pack` `writing("Delete an agent pack", true, true)`, `list_pack_words` `readOnly("List agent pack words")`.

- [ ] **Step 1: Write the failing tests.**
  - `packs_test.go`: `TestPackToolsAreRegisteredWithHints` (три инструмента есть, подсказки как выше, `OpenWorldHint` false); `TestPackToolsDescribeThemselves` (английский, не короче 500 байт, фраза `not instructions`; `create_pack` называет `` `id` ``, `` `title` ``, `` `created` ``, `20`, `60`, `add_words`, `pack_id`, фразу о том, что `created: false` значит «набор уже был»; `delete_pack` называет `` `removed_words` `` и что слова исчезают с набором; `list_pack_words` называет `` `spelling` ``, `` `variants` `` и что встроенные наборы отказ, и `Read-only`); `TestPackToolsSendTheWireShape` через `fakeDoor` проверяет `sentArgs`: `{"title":"Музыка"}` для `create_pack`, `{"id":"agent-3f9a12bc"}` для двух других, и команды `create_pack`, `delete_pack`, `pack_words`; `TestPackToolSchemasDescribeEveryField` (у каждого поля описание, обязательны `title` и `id`, закрытые объекты); `TestPackToolsCarryDoorRefusalAsIs`; `TestPackToolsStartTheAppWhenDoorIsDown`.
  - `write_test.go`: `writeToolNames`, `destructive` и `idempotent` расширить на `create_pack` (destructive false, idempotent true) и `delete_pack` (true, true). В `TestWriteToolsDescribeThemselves` `add_words` требует новых фраз `` `pack_id` ``, `create_pack`, `500`, и фразу выбора «a single word of the user, such as a surname, goes without pack_id»; `remove_words` требует `` `pack_id` ``; `revert_agent_words` требует `` `removed_packs` ``. `TestAddWordsSendsTheWireShape` остаётся без изменений и проходит: без `pack_id` строка байт в байт прежняя. Новые тесты: `TestAddWordsWithPackIdSendsItLast` (строка `{"words":[…],"pack_id":"agent-3f9a12bc"}`), `TestBlankPackIdReachesTheDoor` (аргумент `""` уходит как `"pack_id":""`, а не пропадает; то же для `remove_words`), `TestRemoveWordsWithPackIdSendsIt`. В `TestNullIsRefusedWithTheFieldNamed` добавить случаи `pack_id` для `add_words` и `remove_words`. Схемы `add_words` и `remove_words` описывают `pack_id` (строка, описание, не обязательное).
  - `read_test.go`: `list_dictionary_packs` называет `` `source` ``, `builtin`, `agent`, `list_pack_words`, и **по-прежнему** содержит `not exposed by this server` (про состав встроенных наборов).
  - `main_test.go`: в `writeCases` добавить `create_pack` (запрос `{"cmd":"create_pack","args":{"title":"Музыка"}}`), `delete_pack` (`{"cmd":"delete_pack","args":{"id":"agent-3f9a12bc"}}`) и вариант `add_words` с `pack_id` (`{"cmd":"add_words","args":{"words":[...],"pack_id":"agent-3f9a12bc"}}`); в таблицу сквозных чтений `list_pack_words` (`{"cmd":"pack_words","args":{"id":"agent-3f9a12bc"}}`); в `TestEndToEndWriteToolsAreListed` три новых имени; `TestInstructionsNameThePackTools` проверяет, что `instructions` содержит `create_pack`, `delete_pack`, `list_pack_words`, `pack_id`. `TestEveryToolAdvertisesAPortableSchema` должен проходить без правок и теперь обходит десять инструментов.
- [ ] **Step 2: Run to verify they fail.** `cd mcp && GOPROXY=off GOTOOLCHAIN=local go test -mod=vendor ./...`. Expected: FAIL, инструментов нет.
- [ ] **Step 3: Implement `packs.go`** с `registerPacks(s *mcp.Server, d Door)`, описаниями, схемами через существующие `property`, `closedObject`; `createPackInput{Title string}`, `packIDInput{ID string}` с тегами `json:"title"` и `json:"id"`. Описание `create_pack` объясняет: звать, когда человек просит тематический словарь, например музыкальный; название одно на оба языка, 1 до 60 знаков, не совпадает с названием встроенного набора; предел 20 наборов; затем `add_words` с `pack_id`; человек видит набор в списке с подписью «from agent», может выключить и удалить его; `created: false` значит, что набор с таким названием уже есть и его надо использовать. Обработчики зовут дверь через существующий `ask`.
- [ ] **Step 4: Change `write.go`, `read.go`, `main.go`.** Добавить `pack_id` во входы, схемы и структуры двери по блоку Interfaces. Описание `add_words` получает правило выбора: тематический словарь собирается в набор (`create_pack`, затем `add_words` с `pack_id`, до 500 слов в наборе, `force_case` со `pack_id` не действует), отдельное слово человека, например фамилия, идёт без `pack_id` в «Мои слова». Остальные фразы и ограничения прежние. Описание `remove_words`: со `pack_id` снимает слова набора агента, полный доступ не нужен; без него прежнее поведение. `revert_agent_words` называет `removed_packs` и просит сказать человеку все три числа. `list_dictionary_packs` называет `source` и ведёт к `list_pack_words`. `instructions` в `main.go` упоминает три новых инструмента и `pack_id` одним предложением.
- [ ] **Step 5: Run to verify they pass.** Go-команда из Global Constraints и проверка формата. Expected: `ok` для всех пакетов, `gofmt -l` пуст.
- [ ] **Step 6: Commit**
  ```bash
  git add mcp/main.go mcp/main_test.go mcp/tools
  git commit -m "feat: add the agent pack tools to the MCP server"
  ```

---

### Task 6: Интерфейс наборов агента

**Files:**
- Modify: `Tranq/DictionaryView.swift`
- Modify: `Tranq/DictionaryPackDetailView.swift`
- Modify: `Tranq/Localizable.xcstrings`
- Modify: `TranqTests/MCP/MCPLocalizationTests.swift`

**Interfaces:**
- Consumes: `DictionaryStore.agentPacks`, `deleteAgentPack(id:)`, `agentWordCount` (Tasks 1–3). Набор агента отличается от встроенного тем, что его `id` есть в `store.agentPacks`.
- Produces: новые строки каталога, все с `en`, и они же в `MCPLocalizationTests.addedKeys`:
  - `от агента` — подпись в строке набора
  - `Удалить набор` — кнопка и `accessibilityLabel` в шапке состава
  - `Удалить набор?` — заголовок подтверждения
  - `Набор и его слова исчезнут.` — текст подтверждения
  - заменяет `Удалятся слова и варианты агента. Ваши останутся.` на `Удалятся слова, варианты и наборы агента. Ваши останутся.`: старый ключ убирается из каталога и из `addedKeys`
  `Удалить` и `Отмена` уже есть в каталоге, `reusedKeys` дополняется ключом `Удалить`, если его там нет.

- [ ] **Step 1: Write the failing test.** В `MCPLocalizationTests.addedKeys` добавить четыре новых ключа и заменить старый ключ отката новым. Run: Swift `MCPLocalizationTests`. Expected: FAIL, ключей нет в каталоге.
- [ ] **Step 2: Add the strings** в `Localizable.xcstrings` вставками в формате Xcode, перевод на английский: `from agent`, `Delete pack`, `Delete pack?`, `The pack and its words will disappear.`, `Words, variants and agent packs will be removed. Yours stay.` Проверить `git diff --stat`: число строк пропорционально пяти ключам.
- [ ] **Step 3: Row label.** В `packRow` рядом с `Text("\(pack.entries.count) слов")` для набора агента добавить `Text("от агента")` шрифтом `.ui(.caption)` цветом `.uiMidGray`. Встроенные наборы выглядят как прежде.
- [ ] **Step 4: Delete button.** В `DictionaryPackDetailView.header` для набора агента, справа от `Spacer()`, кнопка «Удалить набор» в стиле существующих кнопок экрана (`TactileButtonStyle`, `Font.ui`) с `accessibilityLabel`. Нажатие показывает `.alert("Удалить набор?", ...)` с текстом «Набор и его слова исчезнут.», кнопки «Удалить» с ролью `.destructive` и «Отмена». «Удалить» вызывает `try? store.deleteAgentPack(id: pack.id)` и `onBack()`. У встроенного набора кнопки нет. Один `.alert` на вид.
- [ ] **Step 5: Revert menu.** В `DictionaryView.menuItems` условие показа пункта «Снять слова агента» становится `store.agentWordCount > 0 || !store.agentPacks.isEmpty`; текст в `.alert("Снять слова агента", ...)` — новый ключ.
- [ ] **Step 6: Run to verify**. Swift: `MCPLocalizationTests`, затем полная сборка и классы `DictionaryScreenLogicTests`, `DictionaryAgentPackTests`. Expected: `** TEST SUCCEEDED **`, сборка без новых предупреждений в изменённых файлах.
- [ ] **Step 7: Commit**
  ```bash
  git add Tranq/DictionaryView.swift Tranq/DictionaryPackDetailView.swift Tranq/Localizable.xcstrings TranqTests/MCP/MCPLocalizationTests.swift
  git commit -m "feat: show agent packs in the dictionary screen"
  ```

---

### Task 7: Документы и проверка

**Files:**
- Modify: `docs/superpowers/specs/2026-11-18-mcp-server-design.md`

**Interfaces:**
- Consumes: всё предыдущее. README перечня инструментов не содержит (проверено: упоминает только сборку Go), его не менять.

- [ ] **Step 1: Update the MCP design doc.** В разделе «Инструменты сервера» дописать три новых инструмента и `pack_id` у `add_words` и `remove_words` одним абзацем со ссылкой на `2026-11-18-agent-packs-design.md`; заменить «семь команд» и «семь простых команд» на «десять» там, где речь о текущем состоянии двери.
- [ ] **Step 2: Full local verification.**
  - Swift, весь набор: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests -derivedDataPath build/DerivedData-ci CODE_SIGN_IDENTITY=-`, затем то же с `-testLanguage en -testRegion US`. Expected: `** TEST SUCCEEDED **` оба раза. Если корпусные тесты показывают промахи «докере», «зуме», «эксель», «ютубе», они существовали до этой работы: назвать их в отчёте как прежние, а не чинить здесь.
  - Go: `cd mcp && GOPROXY=off GOTOOLCHAIN=local go test -mod=vendor -race ./...` и `go vet ./...`, формат Go по Global Constraints.
  - `bash scripts/check-brand.sh`.
  - `git diff --stat feat/mcp-server..HEAD`: только файлы этого плана.
- [ ] **Step 3: Live check only with the user's word.** Живой цикл (создать «Музыка» из клиента, увидеть в списке, выключить, включить, продиктовать фразу с вариантом, удалить, «Снять слова агента») идёт на установленном приложении с его настоящим словарём. Не устанавливать сборку поверх `/Applications/Tranq.app` и не запускать другую сборку на данных пользователя без прямой просьбы. Вместо этого в отчёте сказать, что живой цикл не выполнен, и дать список ручных проверок из спеки.
- [ ] **Step 4: Commit**
  ```bash
  git add docs/superpowers/specs/2026-11-18-mcp-server-design.md
  git commit -m "docs: add the agent pack tools to the MCP design"
  ```
