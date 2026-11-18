# MCP-сервер Tranq: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Человек подключает Tranq к своему ИИ-агенту одной строкой конфига и настраивает словарь в разговоре, а не руками.

**Architecture:** Отдельный stdio-бинарник `tranq-mcp` на Go внутри бандла держит протокол MCP и ходит в приложение через Unix-сокет в папке данных. Приложение про MCP не знает: оно отвечает на семь команд построчного JSON и остаётся единственным, кто пишет в словарь. Доступ разбит на три уровня, все по умолчанию выключены.

**Tech Stack:** Swift (в проекте `SWIFT_VERSION = 5.0`), SwiftUI, swift-testing; Go с `github.com/modelcontextprotocol/go-sdk`; Xcode build phase для `go build`.

**Spec:** `docs/superpowers/specs/2026-11-18-mcp-server-design.md`

## Global Constraints

- Работа начинается после того, как редизайн словаря влит в `main`, вместе с наборами `medicine` и `psychology`.
- Текст интерфейса: без круглых, квадратных и фигурных скобок; метки в одно-два слова; подзаголовки короче восьми слов. Шрифт только через `Font.ui`. Акцентного цвета нет.
- Имя бренда в путях, конфиге и текстах — `Tranq` и `tranq`; `scripts/check-brand.sh` остаётся зелёным.
- `Localizable.xcstrings` правится только дампером в формате Xcode, никогда `json.dump`.
- Swift-тесты на swift-testing: `import Testing`, `struct …Tests`, `#expect`.
- Протокол двери зафиксирован в `mcp/PROTOCOL.md`: имена команд и полей, формы ответов. Swift и Go следуют ему буквально, поля в `snake_case`.
- Стор получает `defaults` через инициализатор. Код, работающий со стором, пользуется его `defaults`, а не `AppEnvironment.defaults` напрямую, иначе тесты со своим `suiteName` читают чужое состояние.
- Хранилища мутируются с главного потока. Настройки — через `AppEnvironment.defaults`, не `UserDefaults.standard`.
- Сборка Go: только `arm64`, подпись ad-hoc, зависимости вендорятся, сеть при сборке не нужна.
- Пределы из спеки: 50 слов за вызов `add_words`; `list_dictations` по умолчанию 20 записей, не больше 100.
- Версия релиза `3.2`, `MARKETING_VERSION` в `Tranq.xcodeproj/project.pbxproj`.
- Проект на синхронизированных группах Xcode: новые файлы Swift и тестов подхватываются сами, править `project.pbxproj` для них не нужно. Папка `mcp/` лежит в корне репозитория и в группы приложения не входит.

## Review Focus

- **Два клиента сразу.** Человек держит Tranq подключённым и в Claude Code, и в Antigravity: сокет принимает несколько соединений одновременно, и ответ одного клиента не уходит другому. Тест в задаче 5.
- **Мусорные слова в `add_words`.** Пустое написание, одни пробелы, дубль внутри одного вызова: запись не создаётся, остальные слова пачки проходят. Тест в задаче 2.
- **Вариант, равный написанию, и вариант из одного символа.** В индекс такое пускать нельзя, иначе диктовка начнёт подменять всё подряд. Тест в задаче 2.
- **Откат после правок человека.** Человек сам удалил запись или убрал вариант, который добавил агент: откат не падает и не оставляет висящих ключей в списке. Тест в задаче 2.
- **Границы `list_dictations`.** `limit` равный нулю, отрицательный и больше сотни; заметки без `spokenText`. Тест в задаче 9.

---

### Task 1: Источник `mcp` и снисходительный разбор

**Files:**
- Modify: `Tranq/Dictionary/DictionaryModels.swift:44-70`
- Test: `TranqTests/Dictionary/DictionaryModelsTests.swift`

**Interfaces:**
- Produces: `DictionaryEntry.Source` с третьим значением `mcp`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func неизвестныйИсточникЧитаетсяКакРучной() throws {
    let json = Data(#"{"id":"\#(UUID().uuidString)","spelling":"КПТ","variants":{"ru":["ка пэ тэ"]},"source":"future","forceCase":false,"createdAt":0,"hits":0}"#.utf8)
    let entry = try JSONDecoder().decode(DictionaryEntry.self, from: json)
    #expect(entry.source == .manual)
    #expect(entry.spelling == "КПТ")
}

@Test func источникMCPПроходитКругЧерезJSON() throws {
    let entry = DictionaryEntry(id: UUID(), spelling: "атомоксетин", variants: [.ru: ["атомо ксетин"]], source: .mcp, forceCase: false, createdAt: Date(timeIntervalSince1970: 0), hits: 0, lastUsed: nil)
    let decoded = try JSONDecoder().decode(DictionaryEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded.source == .mcp)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests/DictionaryModelsTests CODE_SIGN_IDENTITY=-`
Expected: FAIL — у `Source` нет значения `mcp`.

- [ ] **Step 3: Добавить `case mcp` в `DictionaryEntry.Source` и читать источник как `Source(rawValue:) ?? .manual` в `DictionaryEntry.init(from:)`**

Сейчас неизвестное значение бросает ошибку, а `DictionaryStore.readEntries` ловит её на уровне файла и уходит на резервную копию, то есть одна запись теряет весь словарь.

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tranq/Dictionary/DictionaryModels.swift TranqTests/Dictionary/DictionaryModelsTests.swift
git commit -m "feat: источник mcp у записи словаря и снисходительный разбор источника"
```

---

### Task 2: Запись от агента и откат в сторе

**Files:**
- Modify: `Tranq/Dictionary/DictionaryStore.swift` — `Keys`, блок «Записи»
- Create: `Tranq/Dictionary/AgentWrite.swift`
- Test: `TranqTests/Dictionary/DictionaryAgentWriteTests.swift`

**Interfaces:**
- Consumes: `DictionaryEntry.Source.mcp` из задачи 1; `DictionaryStore.addEntry(spelling:variants:source:forceCase:)`.
- Produces:
```swift
struct AgentWord: Equatable {
    var spelling: String
    var variants: [DictionaryLanguage: [String]]
    var forceCase: Bool
}

struct AgentWriteResult: Equatable {
    var added: [String]
    var skipped: [String: String]   // написание → причина для человека
}

extension DictionaryStore {
    func addFromAgent(_ words: [AgentWord]) -> AgentWriteResult
    func removeFromAgent(spellings: [String], fullAccess: Bool) -> AgentWriteResult
    func revertAgentChanges()
    var agentWordCount: Int { get }
}
```

**Требования:**
- Новое написание создаёт запись с источником `mcp`.
- Существующее написание сохраняет свой источник, а варианты агента дописываются и запоминаются в `defaults` стора под ключом `dictionary.mcpVariants`, ключами `<id записи>/<язык>/<вариант>` — по образцу `dictionary.disabledPackVariants`. Жёсткий регистр, впервые поставленный агентом, запоминается ключом `<id записи>/forceCase`.
- Отбрасываются: пустое написание и одни пробелы, повтор внутри одной пачки, вариант равный написанию без учёта регистра, вариант короче двух символов. Причина отказа ложится в `skipped`, остальные слова пачки проходят.
- `removeFromAgent` без полного доступа снимает только записи `mcp`, на `manual` и `learned` даёт `skipped` с причиной.
- `revertAgentChanges` удаляет записи `mcp`, снимает запомненные варианты из чужих записей, снимает запомненный жёсткий регистр и чистит список. Висящие ключи — запись или вариант, уже удалённые человеком — пропускаются без ошибки.
- `agentWordCount` — число записей `mcp` плюс число записей, в которых остались варианты или жёсткий регистр агента. Стор шлёт `objectWillChange` при каждом изменении списка агента, иначе кнопка отката в экране словаря не появится, когда агент только дописал варианты в ручные записи.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func новоеСловоПолучаетИсточникMCP()
@Test func вариантыАгентаДописываютсяВРучнуюЗаписьИОткатСнимаетТолькоИх()
// запись manual «арипипразол» с вариантом человека, агент добавляет два своих,
// после revertAgentChanges запись на месте, вариант человека на месте, вариантов агента нет
@Test func мусорныеСловаОтбрасываютсяОстальныеПроходят()
// "", "   ", дубль в одной пачке, вариант равный написанию, вариант из одного символа
@Test func удалениеБезПолногоДоступаНеТрогаетРучныеСлова()
@Test func удалениеСПолнымДоступомСнимаетРучноеСлово()
@Test func откатПослеТогоКакЧеловекУдалилЗаписьНеПадает()
@Test func откатСнимаетЖёсткийРегистрТолькоЕслиЕгоПоставилАгент()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test … -only-testing:TranqTests/DictionaryAgentWriteTests CODE_SIGN_IDENTITY=-`
Expected: FAIL — `addFromAgent` не определён.

- [ ] **Step 3: Реализовать `AgentWord`, `AgentWriteResult` в `AgentWrite.swift` и четыре члена расширения в `DictionaryStore.swift`**

Все мутации — внутри `onMain`, как остальные методы стора. Список вариантов агента хранится отсортированным массивом строк, как `disabledPackVariants`.

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Tranq/Dictionary/AgentWrite.swift Tranq/Dictionary/DictionaryStore.swift TranqTests/Dictionary/DictionaryAgentWriteTests.swift
git commit -m "feat: запись словаря от агента, список его вариантов и откат"
```

---

### Task 3: Уровни доступа

**Files:**
- Create: `Tranq/MCP/MCPAccess.swift`
- Test: `TranqTests/MCP/MCPAccessTests.swift`

**Interfaces:**
- Produces:
```swift
enum MCPCommandName: String, CaseIterable {
    case packs, words, setPack = "set_pack", addWords = "add_words"
    case removeWords = "remove_words", revertAgentWords = "revert_agent_words", dictations
}

final class MCPAccess: ObservableObject {
    static let shared: MCPAccess
    init(defaults: UserDefaults = AppEnvironment.defaults)   // тесты передают свой suite
    @Published var enabled: Bool          // ключ mcp.enabled
    @Published var fullAccess: Bool       // mcp.fullAccess
    @Published var historyAccess: Bool    // mcp.historyAccess

    enum Verdict: Equatable { case allow, deny(String) }
    func verdict(for command: MCPCommandName, disablingPack: Bool) -> Verdict
}
```

**Требования:**
- Все три флага по умолчанию выключены, живут в `AppEnvironment.defaults`.
- `enabled` выключен → любая команда получает `deny` с текстом «Доступ для нейронок выключен. Включите его в настройках Tranq.»
- Выключение `enabled` сбрасывает `fullAccess` и `historyAccess` и записывает их выключенными: повторное включение доступа начинает с нуля, оба права включаются заново. Сброс стоит в самом `MCPAccess`, а не в экране, чтобы покрыть любой путь выключения. Если при создании сохранено `enabled == false`, а права сохранены включёнными, они сбрасываются и записываются выключенными.
- `dictations` без `historyAccess` → `deny` с текстом про доступ к истории.
- `setPack` с `disablingPack: true` без `fullAccess` → `deny` с текстом про полный доступ. Включение набора разрешено всегда. `removeWords` при включённом `enabled` разрешён всегда: без полного доступа сам стор снимает только слова агента, `removeFromAgent(spellings:fullAccess:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func поУмолчаниюВсёВыключено()
@Test func безДоступаЛюбаяКомандаОтклоняется()
@Test func историяТребуетСвоегоРазрешения()
@Test func выключениеНабораТребуетПолногоДоступа()
@Test func удалениеСловДоступноБезПолногоДоступа()
@Test func включениеНабораРазрешеноБезПолногоДоступа()
@Test func выключениеДоступаСбрасываетПолныйДоступИИсторию()
@Test func повторноеВключениеДоступаНеВозвращаетПолныйДоступИИсторию()
@Test func приСозданииСВыключеннымДоступомСохранённыеПраваСбрасываютсяИЗаписываются()
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Реализовать `MCPAccess` и `MCPCommandName`**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

```bash
git add Tranq/MCP/MCPAccess.swift TranqTests/MCP/MCPAccessTests.swift
git commit -m "feat: три уровня доступа для MCP"
```

---

### Task 4: Команды двери

**Files:**
- Create: `Tranq/MCP/MCPDoor.swift`
- Test: `TranqTests/MCP/MCPDoorTests.swift`

**Interfaces:**
- Consumes: `AgentWord`, `AgentWriteResult`, `DictionaryStore`, `HistoryStore`, `MCPAccess`, `DictionaryScreenLogic.packTitle(_:uiLanguage:)`.
- Produces:
```swift
struct MCPDoor {
    init(dictionary: DictionaryStore, history: HistoryStore, access: MCPAccess, language: DictionaryLanguage)
    func handle(line: String) -> String   // строка JSON ответа, без перевода строки
}
```

**Требования:**
- Запрос `{"cmd": "...", "args": {...}}`, ответ `{"ok":true,"data":…,"language":"ru"}` или `{"ok":false,"error":"текст для человека"}`.
- Нечитаемый JSON и неизвестная команда дают `ok:false` с понятным текстом, а не падение.
- `packs` отдаёт `id`, название на языке приложения, число слов, включён ли.
- `words` отдаёт написание, варианты по языкам, источник, `hits`, `lastUsed`.
- `dictations` берёт `TranscriptionItem` из `HistoryStore`, пропускает записи без `spokenText`, отдаёт дату, сырую расшифровку и итоговый текст; `limit` по умолчанию 20, больше 100 обрезается до 100, ноль и отрицательное дают 20.
- `add_words` больше 50 слов — отказ целиком с просьбой разбить.
- Каждая команда сначала спрашивает `MCPAccess.verdict`.
- `handle(line:)` сам переходит на главный поток, если вызван не с него, и безопасен при вызове с главного: стор и история мутируются только там, а сокет зовёт дверь с фоновой очереди.
- Имена команд, поля запросов и формы ответов — по `mcp/PROTOCOL.md`. Дверь выводит «выключение набора» из `enabled == false`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func битыйJSONДаётПонятнуюОшибку()
@Test func неизвестнаяКомандаДаётПонятнуюОшибку()
@Test func packsОтдаётНазванияНаЯзыкеПриложения()
@Test func addWordsБольшеПятидесятиОтклоняетсяЦеликом()
@Test func dictationsБезРазрешенияОтклоняется()
@Test func ответНесётЯзыкПриложения()
@Test func dictationsПропускаетЗаметкиБезСыройРасшифровки()
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Реализовать `MCPDoor.handle(line:)`**

Разбор и сборка — `JSONSerialization`, чтобы не заводить типы на каждую команду.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

```bash
git add Tranq/MCP/MCPDoor.swift TranqTests/MCP/MCPDoorTests.swift
git commit -m "feat: команды двери MCP поверх словаря и истории"
```

---

### Task 5: Сокет

**Files:**
- Create: `Tranq/MCP/MCPSocketServer.swift`
- Modify: `Tranq/TranqApp.swift` — старт сервера при запуске приложения
- Test: `TranqTests/MCP/MCPSocketServerTests.swift`

**Interfaces:**
- Consumes: `MCPDoor.handle(line:)`.
- Produces:
```swift
final class MCPSocketServer {
    static let shared: MCPSocketServer
    static var socketURL: URL { get }   // AppEnvironment.dataDirectory/mcp.sock
    func start(door: MCPDoor)
    func stop()
}
```

**Требования:**
- Сокет живёт, пока запущено приложение, независимо от переключателей: отказы выдаёт дверь.
- Права файла `0600`; оставшийся от прошлого запуска файл удаляется перед `bind`.
- Построчный протокол: запрос — одна строка, ответ — одна строка.
- Несколько соединений одновременно, каждое в своей задаче; ответ уходит только своему клиенту.
- Путь сокета длиннее 103 байт не помещается в `sockaddr_un`: сервер пишет предупреждение в `AppLogger` и не стартует, приложение не падает.
- Поведение выше обязательно, фреймворк свободен: допустимы и `Network.framework`, и POSIX-сокеты на `DispatchQueue`, смотря что даёт права `0600` без гонки.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func сокетСоздаётсяСПравами0600()
@Test func двеОдновременныеСессииПолучаютСвоиОтветы()
// два соединения, в каждое своя команда, ответы не перепутаны
@Test func файлОтПрошлогоЗапускаНеМешаетСтарту()
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Реализовать `MCPSocketServer` и позвать `start` из `TranqApp`**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

```bash
git add Tranq/MCP/MCPSocketServer.swift Tranq/TranqApp.swift TranqTests/MCP/MCPSocketServerTests.swift
git commit -m "feat: локальный сокет для MCP-сервера"
```

---

### Task 6: Экран настроек и откат в словаре

**Files:**
- Create: `Tranq/MCPSettingsSection.swift`
- Modify: `Tranq/SettingsView.swift:327` — секция после `AIProviderSection()`
- Modify: `Tranq/DictionaryView.swift:46-49,116` — действие и подтверждение
- Modify: `Tranq/Localizable.xcstrings`
- Test: `TranqTests/MCP/MCPConfigSnippetTests.swift`

**Interfaces:**
- Consumes: `MCPAccess.shared`, `DictionaryStore.revertAgentChanges()`, `DictionaryStore.agentWordCount`.
- Produces: `MCPSettingsSection: View`, `MCPConfigSnippet.text(binaryURL: URL) -> String`.

**Требования:**
- Заголовок секции `ДОСТУП ДЛЯ НЕЙРОНОК`, подзаголовок короче восьми слов и без скобок.
- Три переключателя: доступ, полный доступ, доступ к истории. Полный доступ и история при включении показывают предупреждение: полный доступ — что агент сможет удалить из словаря всё и что отката для чужих слов нет; история — что диктовки уйдут в стороннюю модель вместе с их содержимым.
- Блок конфига виден только при включённом доступе, с кнопкой скопировать. Путь берётся из `Bundle.main.executableURL`, папка `MacOS`, имя `tranq-mcp`.
- В словаре, в меню рядом со «Сбросить выученное», действие `Снять слова агента`; видно только когда `agentWordCount > 0`; подтверждение перед снятием.
- Новые строки идут в `Localizable.xcstrings` с переводами `ru` и `en`, формат файла — Xcode.

- [ ] **Step 1: Write the failing test**

```swift
@Test func конфигУказываетНаБинарникРядомСПриложением() {
    let exe = URL(fileURLWithPath: "/Users/kto/Applications/Tranq.app/Contents/MacOS/Tranq")
    let text = MCPConfigSnippet.text(binaryURL: exe)
    #expect(text.contains("/Users/kto/Applications/Tranq.app/Contents/MacOS/tranq-mcp"))
    #expect(text.contains("\"tranq\""))
}
```

- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Реализовать `MCPConfigSnippet`, секцию настроек и действие в словаре**
- [ ] **Step 4: Run test to verify it passes, затем `bash scripts/check-brand.sh`**
- [ ] **Step 5: Commit**

```bash
git add Tranq/MCPSettingsSection.swift Tranq/SettingsView.swift Tranq/DictionaryView.swift Tranq/Localizable.xcstrings TranqTests/MCP/MCPConfigSnippetTests.swift
git commit -m "feat: секция доступа для нейронок и откат слов агента в словаре"
```

---

### Task 7: Go-сервер: каркас и чтение

**Files:**
- Create: `mcp/go.mod`, `mcp/main.go`, `mcp/door/door.go`, `mcp/tools/read.go`
- Test: `mcp/door/door_test.go`, `mcp/tools/read_test.go`

**Interfaces:**
- Consumes: протокол двери из задачи 4.
- Produces:
```go
package door
type Client struct{ ... }
func New(socketPath string) *Client
func (c *Client) Call(ctx context.Context, cmd string, args any) (json.RawMessage, error)
func SocketPath() string   // ~/Library/Application Support/Tranq/mcp.sock
func (c *Client) EnsureApp(ctx context.Context) error
```

**Требования:**
- Модуль `github.com/Nuteres/Tranq/mcp`, зависимости вендорятся: `go mod vendor`, папка `vendor` коммитится.
- Сокета нет — `EnsureApp` открывает приложение и ждёт сокет до пяти секунд; не дождался, возвращает ошибку «Откройте Tranq и включите доступ для нейронок в настройках».
- Ответ двери с `ok:false` превращается в ошибку инструмента с текстом из `error` как есть: его читает человек.
- Инструменты `list_dictionary_packs` и `list_user_words`, описания на английском, подробные: что инструмент делает, когда его звать, что значит каждое поле.

- [ ] **Step 1: Write the failing tests**

```go
func TestCallReturnsDoorError(t *testing.T)        // ok:false → ошибка с тем же текстом
func TestCallSurvivesGarbageLine(t *testing.T)     // дверь ответила не-JSON
func TestMissingSocketGivesHumanError(t *testing.T)
func TestReadToolsDescribeEveryField(t *testing.T) // описания непустые, на английском
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp && go test ./...`
Expected: FAIL — пакеты не компилируются.

- [ ] **Step 3: Реализовать клиент двери, регистрацию сервера на `modelcontextprotocol/go-sdk` со stdio-транспортом и два инструмента чтения**

- [ ] **Step 4: Run tests to verify they pass, затем проверить руками: подключить сервер в Claude Code и запросить наборы**

- [ ] **Step 5: Commit**

```bash
git add mcp
git commit -m "feat: MCP-сервер на Go, клиент двери и инструменты чтения"
```

---

### Task 8: Go-сервер: запись

**Files:**
- Create: `mcp/tools/write.go`
- Test: `mcp/tools/write_test.go`

**Interfaces:**
- Consumes: `door.Client.Call`.
- Produces: инструменты `set_pack_enabled`, `add_words`, `remove_words`, `revert_agent_words`.

**Требования:**
- `add_words` принимает список: `spelling`, `variants` с ключами `ru` и `en`, `force_case`. Пустой список — отказ без обращения к двери. Больше 50 — отказ с просьбой разбить, тоже без обращения.
- Ответ инструмента перечисляет, что добавлено и что отброшено с причиной: агент должен рассказать это человеку.
- Описание `remove_words` прямо говорит, что без полного доступа снимаются только слова, добавленные агентом.

- [ ] **Step 1: Write the failing tests**

```go
func TestAddWordsRejectsEmptyList(t *testing.T)
func TestAddWordsRejectsOverFifty(t *testing.T)
func TestAddWordsReportsSkippedWithReason(t *testing.T)
func TestSetPackEnabledSendsIdAndEnabled(t *testing.T)   // args ровно {id, enabled}, отдельного флага нет
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Реализовать четыре инструмента записи**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

```bash
git add mcp/tools/write.go mcp/tools/write_test.go
git commit -m "feat: инструменты записи словаря через MCP"
```

---

### Task 9: Go-сервер: история

**Files:**
- Create: `mcp/tools/dictations.go`
- Test: `mcp/tools/dictations_test.go`

**Interfaces:**
- Produces: инструмент `list_dictations`.

**Требования:**
- `limit` ноль, отрицательный и отсутствующий дают 20; больше 100 — 100.
- Отказ двери по разрешению отдаётся человеку как есть, без переформулировок.
- В описании инструмента прямо сказано: отдаёт сырую расшифровку, нужен для поиска систематических промахов распознавания, аудио не отдаёт.

- [ ] **Step 1: Write the failing tests**

```go
func TestLimitDefaultsToTwenty(t *testing.T)
func TestLimitCapsAtHundred(t *testing.T)
func TestZeroAndNegativeLimitFallBackToTwenty(t *testing.T)
func TestPermissionErrorReachesTheUserVerbatim(t *testing.T)
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Реализовать инструмент**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

```bash
git add mcp/tools/dictations.go mcp/tools/dictations_test.go
git commit -m "feat: чтение истории диктовок через MCP"
```

---

### Task 10: Сборка, подпись, CI

**Files:**
- Modify: `Tranq.xcodeproj/project.pbxproj` — фаза `Build tranq-mcp` и копирование в `Contents/MacOS`
- Modify: `scripts/build-dmg.sh:46-48`
- Modify: `.github/workflows/ci.yml`

**Требования:**
- В цели приложения `ENABLE_USER_SCRIPT_SANDBOXING = YES`: скрипт-фаза не сможет ни писать кэш Go, ни читать `mcp/`. Фаза объявляет входы и выходы либо цель получает `NO`; выбор за исполнителем, причина записывается в сообщение коммита.
- Фаза сборки запускает `go build -o "$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH/tranq-mcp" .` в `mcp/`: собирается корневой пакет команды, а не `./...`, с которым `-o` не даёт одного исполняемого файла. Сборка с `GOARCH=arm64` и `-mod=vendor`. Нет Go на машине — фаза падает с текстом «нет Go, установите toolchain», а не пропускается.
- Бинарник подписывается до подписи бандла, чтобы `codesign --verify --strict` в `build-dmg.sh` проходил.
- В `build-dmg.sh` список обязательных файлов пополняется `Contents/MacOS/tranq-mcp`.
- В CI добавляется шаг `go test ./...` в папке `mcp` перед сборкой Xcode.

- [ ] **Step 1: Добавить фазу сборки, копирование и подпись**
- [ ] **Step 2: Прогнать `scripts/build-dmg.sh` и убедиться, что проверка подписи и проверка наличия `tranq-mcp` проходят**

`Tranq/gigaam.gguf` и `Vendor/llama/llama-server` в этом дереве есть, скрипт должен дойти до конца.
- [ ] **Step 3: Проверить, что вложенный бинарник запускается из чужого процесса**

Исполнитель проверяет то, что доступно без интерактивного клиента: `codesign --verify --strict --deep` на собранном `.app`, запуск `Contents/MacOS/tranq-mcp` из обычной оболочки с проставленным `com.apple.quarantine` на копии бандла и после `xattr -cr`, рукопожатие `initialize` по stdio, `echo '{"jsonrpc":"2.0",…}' | tranq-mcp`. Подключение в Claude Code и ещё одном клиенте остаётся человеку: в отчёте это значится как «не проверено», а не как пройденное. Отказ Gatekeeper означает, что stdio для этого клиента не работает и нужно возвращаться к HTTP внутри приложения — решение принимает человек, не исполнитель.

- [ ] **Step 4: Добавить шаг `go test` в CI и убедиться, что задача зелёная**

- [ ] **Step 5: Поднять `MARKETING_VERSION` до `3.2`**

Функциональный релиз по регламенту версионирования: добавилась подсистема и в файле словаря появилось новое значение источника, которое прошлые версии не прочитают.

- [ ] **Step 6: Commit**

```bash
git add Tranq.xcodeproj/project.pbxproj scripts/build-dmg.sh .github/workflows/ci.yml
git commit -m "build: сборка и подпись tranq-mcp, go test в CI, версия 3.2"
```
