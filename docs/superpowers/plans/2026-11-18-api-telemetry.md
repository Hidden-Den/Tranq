# Телеметрия внешнего API — план работ

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** показать расход токенов, задержки и исходы запросов к внешнему API в свёрнутом по умолчанию блоке раздела «ИИ-провайдер».

**Architecture:** замеры снимаются в единственной точке вызова бэкенда — `ThoughtSynthesizer.clean`. Хранилище `CleanupTelemetry.shared` ведёт одну открытую попытку за раз: `begin` открывает, `noteFirstToken` и `noteUsage` дополняют из потока, `finish` закрывает записью. Модель рассчитана на одну чистку за раз: две перекрывающиеся диктовки смешают записи телеметрии, сама диктовка не затрагивается.

**Tech Stack:** Swift, SwiftUI, swift-testing, JSON в `AppEnvironment.dataDirectory`.

**Spec:** `docs/superpowers/specs/2026-11-18-api-telemetry-design.md`

## Global Constraints

- Текст интерфейса без круглых скобок, метки 1–2 слова, подзаголовки короче 8 слов.
- Шрифты только через `Font.ui`, цвета только из токенов `MonoStyle.swift`.
- Акцентного цвета нет: монохром и семантические цвета состояний.
- Новые строки интерфейса заводятся в `Tranq/Localizable.xcstrings` с переводом на английский.
- Данные не покидают машину.
- Хранилище пишется в `AppEnvironment.dataDirectory`, иначе тесты затрут данные пользователя.

## Расхождения при исполнении

План писался до кода; по ходу работы и после ревью исполнение разошлось с ним так:

- `stream_options` уходит только на `api.openai.com` и `api.deepseek.com` при выбранных пресетах OpenAI и DeepSeek. Остальным серверам поле не шлётся: строгий шлюз отвечает 400, и очистка пропала бы ради отладочной цифры.
- `CleanupTelemetry` получил `init(storeURL:)`, а `ThoughtSynthesizer.clean` и `ExternalBackend` необязательный параметр `telemetry`. Тесты идут параллельно и делили бы один файл и одну открытую попытку.
- `averageTotal` считает только успешные ответы, `ModelTotals` хранит счётчик оценённых запросов `estimatedRequests`, а строка «Все модели» берёт пометку оценки из него.
- Расход из строки потока берётся независимо от текста в ней: часть шлюзов шлёт usage вместе с последним куском.
- Для потока добавлен сквозной тест на подменённой сети, `ExternalBackendTelemetryTests`.

## Review Focus

- Провайдер Anthropic присылает usage дважды, в `message_start` и в `message_delta`: выходные токены не должны сложиться вдвое. Тест на `UsageAccumulator` в задаче 2.
- Запрос упал до первого токена: `firstTokenSeconds` остаётся пустым, и среднее обязано считаться по тем записям, где оно есть, а не делить на общее число. Тест в задаче 3.
- Файл телеметрии повреждён или отсутствует: хранилище стартует пустым и не роняет приложение. Тест в задаче 3.
- Локальная модель токенов не сообщает: нули не должны попасть в расход и исказить средний размер запроса. Тест в задаче 4.
- Окно записей не растёт бесконечно: после 50 запросов держатся последние 50. Тест в задаче 3.

---

### Task 1: Запрос просит usage

**Files:**
- Modify: `Tranq/ChatRequestBuilder.swift:44-61`
- Test: `TranqTests/ChatRequestBuilderUsageTests.swift`

**Interfaces:**
- Consumes: `ChatRequestBuilder.streamRequest(config:system:user:)`, без изменения сигнатуры.
- Produces: тело потокового запроса с полями usage для формата OpenAI и для OpenRouter.

- [ ] **Step 1: Написать падающий тест**

```swift
import Testing
import Foundation
@testable import Tranq

struct ChatRequestBuilderUsageTests {
    private func body(_ config: AIProviderConfig) throws -> [String: Any] {
        let request = try ChatRequestBuilder.streamRequest(config: config, system: "s", user: "u")
        return try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any] ?? [:]
    }

    @Test func openAIFormatAsksForUsage() throws {
        let config = AIProviderConfig(providerID: "openai", baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-6-luna")
        let options = try body(config)["stream_options"] as? [String: Any]
        #expect(options?["include_usage"] as? Bool == true)
    }

    @Test func openRouterAsksForUsage() throws {
        let config = AIProviderConfig(providerID: "openrouter", baseURL: "https://openrouter.ai/api/v1", apiKey: "k", model: "deepseek/deepseek-v4")
        let usage = try body(config)["usage"] as? [String: Any]
        #expect(usage?["include"] as? Bool == true)
    }

    @Test func anthropicSendsNoUsageField() throws {
        let config = AIProviderConfig(providerID: "anthropic", baseURL: "https://api.anthropic.com", apiKey: "k", model: "claude-opus-5")
        let dict = try body(config)
        #expect(dict["stream_options"] == nil)
        #expect(dict["usage"] == nil)
    }
}
```

Сверить инициализатор `AIProviderConfig` с его объявлением и подставить фактические имена параметров.

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug test -only-testing:TranqTests/ChatRequestBuilderUsageTests`
Expected: FAIL, `stream_options` отсутствует.

- [ ] **Step 3: Добавить поля в `streamRequest`**

В ветке формата OpenAI: для OpenRouter `body["usage"] = ["include": true]`, иначе `body["stream_options"] = ["include_usage": true]`. Ветку Anthropic не трогать: там usage приходит сам.

- [ ] **Step 4: Запустить тесты**

Run: та же команда.
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add Tranq/ChatRequestBuilder.swift TranqTests/ChatRequestBuilderUsageTests.swift
git commit -m "feat: запрашивать расход токенов в потоковом запросе"
```

---

### Task 2: Поток отдаёт токены

**Files:**
- Modify: `Tranq/CleanupBackends.swift:79-108`
- Test: `TranqTests/StreamEventTests.swift`

**Interfaces:**
- Consumes: ничего из предыдущих задач.
- Produces: `ExternalBackend.StreamEvent.usage(input: Int?, output: Int?)` — новый случай существующего перечисления; `struct UsageAccumulator` с `input`, `output` и `mutating func apply(input: Int?, output: Int?)`.

- [ ] **Step 1: Написать падающие тесты, дописав их в `StreamEventTests`**

```swift
@Test func openAIFinalChunkGivesUsage() {
    #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":48}}"#) == .usage(input: 120, output: 48))
}

@Test func anthropicStartGivesInputTokens() {
    #expect(ExternalBackend.parseStreamLine(#"data: {"type":"message_start","message":{"usage":{"input_tokens":120,"output_tokens":1}}}"#) == .usage(input: 120, output: 1))
}

@Test func anthropicDeltaGivesOutputTokensOnly() {
    #expect(ExternalBackend.parseStreamLine(#"data: {"type":"message_delta","usage":{"output_tokens":48}}"#) == .usage(input: nil, output: 48))
}

@Test func textChunkWithoutUsageStaysText() {
    #expect(ExternalBackend.parseStreamLine(#"data: {"choices":[{"delta":{"content":"при"}}]}"#) == .text("при"))
}

@Test func accumulatorKeepsFirstInputAndLastOutput() {
    var acc = UsageAccumulator()
    acc.apply(input: 120, output: 1)
    acc.apply(input: nil, output: 48)
    #expect(acc.input == 120)
    #expect(acc.output == 48)
}

@Test func accumulatorStaysEmptyWithoutUsage() {
    var acc = UsageAccumulator()
    #expect(acc.input == nil)
    #expect(acc.output == nil)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug test -only-testing:TranqTests/StreamEventTests`
Expected: FAIL, случая `.usage` нет.

- [ ] **Step 3: Добавить случай `.usage(input: Int?, output: Int?)` и его разбор в `parseStreamLine`**

Проверку usage поставить после `[DONE]` и ошибки, но **до** разбора `choices` и `delta`: у финального куска OpenAI массив `choices` пуст, и текущий разбор вернул бы `.skip`. Источники: корневой `usage` с ключами `prompt_tokens` и `completion_tokens`, `message.usage` у `message_start` и корневой `usage` у `message_delta` с ключами `input_tokens` и `output_tokens`.

- [ ] **Step 4: Добавить `UsageAccumulator` в `Tranq/CleanupBackends.swift`**

`struct UsageAccumulator { private(set) var input: Int?; private(set) var output: Int?; mutating func apply(input: Int?, output: Int?) }`: входные токены берутся первым непустым значением и дальше не меняются, выходные заменяются каждым непустым. Так двойной usage Anthropic не складывается.

- [ ] **Step 5: Запустить тесты**

Expected: PASS, включая прежние тесты файла.

- [ ] **Step 6: Коммит**

```bash
git add Tranq/CleanupBackends.swift TranqTests/StreamEventTests.swift
git commit -m "feat: разбирать расход токенов в потоке ответа"
```

---

### Task 3: Хранилище телеметрии

**Files:**
- Create: `Tranq/CleanupTelemetry.swift`
- Test: `TranqTests/CleanupTelemetryTests.swift`

**Interfaces:**
- Consumes: `AppEnvironment.dataDirectory`.
- Produces:
  - `struct TelemetryRecord: Codable, Equatable { let model: String; let inputTokens: Int; let outputTokens: Int; let estimated: Bool; let firstTokenSeconds: Double?; let totalSeconds: Double; let outcome: TelemetryOutcome; let date: Date }`
  - `enum TelemetryOutcome: String, Codable { case success, timeout, error }`
  - `struct ModelTotals: Codable, Equatable { var requests: Int; var failures: Int; var inputTokens: Int; var outputTokens: Int }`
  - `final class CleanupTelemetry: ObservableObject` со `static let shared`, доступным `init()` для тестов и:
    - `@Published private(set) var totals: [String: ModelTotals]`
    - `@Published private(set) var records: [TelemetryRecord]` — последние `maxRecords` = 50, новые в начале
    - `func begin(model: String)`
    - `func noteFirstToken(seconds: Double)`
    - `func noteUsage(input: Int?, output: Int?, estimated: Bool)`
    - `func finish(outcome: TelemetryOutcome, totalSeconds: Double)`
    - `func reset()`
    - `func averageFirstToken(model: String) -> Double?`
    - `func averageTotal(model: String) -> Double?`
    - `static func estimateTokens(_ text: String) -> Int`

- [ ] **Step 1: Написать падающие тесты**

```swift
import Testing
import Foundation
@testable import Tranq

struct CleanupTelemetryTests {
    @Test func estimateIsThreeCharactersPerToken() {
        #expect(CleanupTelemetry.estimateTokens("") == 0)
        #expect(CleanupTelemetry.estimateTokens("абв") == 1)
        #expect(CleanupTelemetry.estimateTokens("абвг") == 2)
    }

    @Test func finishedAttemptBecomesRecordAndTotals() {
        let t = CleanupTelemetry()
        t.begin(model: "m")
        t.noteFirstToken(seconds: 0.5)
        t.noteUsage(input: 100, output: 40, estimated: false)
        t.finish(outcome: .success, totalSeconds: 2.0)
        #expect(t.records.count == 1)
        #expect(t.totals["m"] == ModelTotals(requests: 1, failures: 0, inputTokens: 100, outputTokens: 40))
        #expect(t.records.first?.estimated == false)
    }

    @Test func failureCountsAsFailure() {
        let t = CleanupTelemetry()
        t.begin(model: "m")
        t.finish(outcome: .timeout, totalSeconds: 3.0)
        #expect(t.totals["m"]?.failures == 1)
        #expect(t.records.first?.firstTokenSeconds == nil)
    }

    @Test func averageFirstTokenSkipsAttemptsWithoutToken() {
        let t = CleanupTelemetry()
        t.begin(model: "m"); t.noteFirstToken(seconds: 1.0); t.finish(outcome: .success, totalSeconds: 2.0)
        t.begin(model: "m"); t.finish(outcome: .timeout, totalSeconds: 3.0)
        #expect(t.averageFirstToken(model: "m") == 1.0)
    }

    @Test func averagesIgnoreOtherModels() {
        let t = CleanupTelemetry()
        t.begin(model: "a"); t.noteFirstToken(seconds: 1.0); t.finish(outcome: .success, totalSeconds: 2.0)
        t.begin(model: "b"); t.noteFirstToken(seconds: 5.0); t.finish(outcome: .success, totalSeconds: 9.0)
        #expect(t.averageFirstToken(model: "a") == 1.0)
        #expect(t.averageTotal(model: "a") == 2.0)
    }

    @Test func windowKeepsLastFifty() {
        let t = CleanupTelemetry()
        for i in 0..<60 {
            t.begin(model: "m\(i)")
            t.finish(outcome: .success, totalSeconds: 1.0)
        }
        #expect(t.records.count == 50)
        #expect(t.records.first?.model == "m59")
        #expect(t.totals.count == 60)
    }

    @Test func brokenFileLeavesStoreEmpty() throws {
        let url = AppEnvironment.dataDirectory.appendingPathComponent("telemetry.json")
        try "не json".data(using: .utf8)!.write(to: url)
        let t = CleanupTelemetry()
        #expect(t.records.isEmpty)
        #expect(t.totals.isEmpty)
    }

    @Test func resetClearsEverything() {
        let t = CleanupTelemetry()
        t.begin(model: "m"); t.finish(outcome: .success, totalSeconds: 1.0)
        t.reset()
        #expect(t.records.isEmpty)
        #expect(t.totals.isEmpty)
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug test -only-testing:TranqTests/CleanupTelemetryTests`
Expected: FAIL, типа `CleanupTelemetry` нет.

- [ ] **Step 3: Реализовать `CleanupTelemetry` в `Tranq/CleanupTelemetry.swift`**

`estimateTokens` — число символов, делённое на 3 с округлением вверх; пустая строка даёт 0. Открытая попытка держится в приватном поле; повторный `begin` заменяет незакрытую, диктовка идёт по одной. `finish` без `begin` ничего не делает. Запись и чтение JSON в `AppEnvironment.dataDirectory/telemetry.json`, ошибка чтения или разбора оставляет хранилище пустым. Сохранять после каждого `finish` и после `reset`. Все методы вызываются с главного потока, пометить класс `@MainActor`.

- [ ] **Step 4: Запустить тесты**

Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add Tranq/CleanupTelemetry.swift TranqTests/CleanupTelemetryTests.swift
git commit -m "feat: хранилище телеметрии очистки"
```

---

### Task 4: Замеры на боевом пути

**Files:**
- Modify: `Tranq/ThoughtSynthesizer.swift:88-105`
- Modify: `Tranq/CleanupBackends.swift:32-77`
- Test: `TranqTests/CleanupTelemetryPipelineTests.swift`

**Interfaces:**
- Consumes: `CleanupTelemetry.shared` из задачи 3, `StreamEvent.usage` из задачи 2.
- Produces: записи телеметрии на каждый вызов бэкенда.

- [ ] **Step 1: Написать падающий тест на поддельном бэкенде**

```swift
import Testing
import Foundation
@testable import Tranq

private struct StubBackend: CleanupBackend {
    let reply: String?
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        guard let reply else { throw CleanupBackendError.timeout }
        return reply
    }
}

@MainActor
struct CleanupTelemetryPipelineTests {
    @Test func successfulCleanupIsRecorded() async {
        CleanupTelemetry.shared.reset()
        _ = await ThoughtSynthesizer.shared.clean(
            "это довольно длинная фраза для очистки",
            level: .clean, targetBundleId: nil, firedSpellings: [], language: .russian,
            backend: StubBackend(reply: "Это длинная фраза для очистки.")
        )
        #expect(CleanupTelemetry.shared.records.first?.outcome == .success)
    }

    @Test func timeoutIsRecordedAsFailure() async {
        CleanupTelemetry.shared.reset()
        _ = await ThoughtSynthesizer.shared.clean(
            "это довольно длинная фраза для очистки",
            level: .clean, targetBundleId: nil, firedSpellings: [], language: .russian,
            backend: StubBackend(reply: nil)
        )
        #expect(CleanupTelemetry.shared.records.first?.outcome == .timeout)
    }

    @Test func backendWithoutTokensRecordsZeroAndNotEstimated() async {
        CleanupTelemetry.shared.reset()
        _ = await ThoughtSynthesizer.shared.clean(
            "это довольно длинная фраза для очистки",
            level: .clean, targetBundleId: nil, firedSpellings: [], language: .russian,
            backend: StubBackend(reply: "Это длинная фраза для очистки.")
        )
        let totals = CleanupTelemetry.shared.totals.values.first
        #expect(totals?.inputTokens == 0)
        #expect(totals?.outputTokens == 0)
    }
}
```

Сверить фактическое имя точки входа `ThoughtSynthesizer` и перечисления `CleanupLevel`, `DictionaryLanguage` с объявлениями.

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug test -only-testing:TranqTests/CleanupTelemetryPipelineTests`
Expected: FAIL, записей нет.

- [ ] **Step 3: Обернуть вызов бэкенда замерами**

В `ThoughtSynthesizer.clean` вокруг `resolvedBackend.complete`: перед вызовом `begin` с именем модели — модель внешнего провайдера из `AIProviderStore.shared.config.model`, локальная из `settings.localModel`, подставной бэкенд даёт имя типа. Засечь время, в успехе `finish(outcome: .success, totalSeconds:)`, в `CleanupBackendError.timeout` — `.timeout`, в остальных ошибках — `.error`.

В `ExternalBackend.stream` при первом токене вызвать `noteFirstToken`, на событии `.usage` складывать значения через `UsageAccumulator` из задачи 2. После цикла вызвать `noteUsage`: если провайдер ничего не прислал, подставить `estimateTokens` по тексту запроса и ответа и пометить `estimated: true`.

Случай `.usage` в цикле обязан делать `continue`: иначе он выйдет из цикла, как `.done`, и ответ оборвётся.

- [ ] **Step 4: Запустить тесты**

Run: та же команда, затем весь `TranqTests`.
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add Tranq/ThoughtSynthesizer.swift Tranq/CleanupBackends.swift TranqTests/CleanupTelemetryPipelineTests.swift
git commit -m "feat: снимать задержки и расход на каждой очистке"
```

---

### Task 5: Раскрывающийся блок телеметрии

**Files:**
- Create: `Tranq/TelemetrySection.swift`
- Modify: `Tranq/AISettingsSection.swift:34-53`
- Modify: `Tranq/Localizable.xcstrings`

**Interfaces:**
- Consumes: `CleanupTelemetry.shared`, `AIProviderStore.shared.model`.
- Produces: `struct TelemetryDisclosure: View` без параметров.

- [ ] **Step 1: Собрать представление**

`TelemetryDisclosure` держит `@State private var isExpanded = false`, состояние между запусками не хранится. Свёрнутый вид — строка «Телеметрия» со стрелкой `chevron.right`, повёрнутой на 90 градусов при раскрытии, по образцу `DictionaryView.swift:294`. Раскрытый вид показывает для текущей модели: «Запросов», «Отказов», «Входящих», «Исходящих», «Первый токен», «Ответ»; ниже строку «Всего по всем моделям» с суммой входных и выходных токенов; ниже последние пять записей строками «модель, токены, время, исход»; внизу `UIOutlineButton` «Сбросить», вызывающий `reset`. Пустое хранилище показывает одну строку «Пока нет запросов». Секунды с одним знаком после запятой, токены с разделителем тысяч через `Decimal.FormatStyle`. Оценочные цифры помечать словом «оценка» рядом с числом.

- [ ] **Step 2: Встроить в раздел**

Добавить `TelemetryDisclosure()` в `AIProviderSection` последним элементом `VStack`, после строки с кнопкой «Проверить».

- [ ] **Step 3: Завести строки интерфейса**

Все новые подписи добавить в `Tranq/Localizable.xcstrings` с английским переводом.

- [ ] **Step 4: Проверить сборку и бренд**

Run: `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug build` и `bash scripts/check-brand.sh`
Expected: BUILD SUCCEEDED, «Старого имени нет».

- [ ] **Step 5: Коммит**

```bash
git add Tranq/TelemetrySection.swift Tranq/AISettingsSection.swift Tranq/Localizable.xcstrings
git commit -m "feat: свёрнутый блок телеметрии в разделе провайдера"
```

---

### Task 6: Сборка и проверка целиком

**Files:**
- Modify: `docs/superpowers/specs/2026-11-18-api-telemetry-design.md` при расхождениях с тем, что вышло.

- [ ] **Step 1: Прогнать все тесты**

Run: `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug build-for-testing` затем `xcodebuild -project Tranq.xcodeproj -scheme Tranq -configuration Debug test-without-building -only-testing:TranqTests`
Expected: TEST EXECUTE SUCCEEDED.

- [ ] **Step 2: Собрать образ**

Run: `scripts/build-dmg.sh`
Expected: «Готово: build/Tranq.dmg».

- [ ] **Step 3: Коммит, если спека правилась**

```bash
git add docs/superpowers/specs/2026-11-18-api-telemetry-design.md
git commit -m "docs: уточнить проект телеметрии по итогам работы"
```
