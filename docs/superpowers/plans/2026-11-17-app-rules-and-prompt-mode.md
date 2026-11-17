# Правила приложений и сайтов, режим промпта — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать пользователю правила «приложение или сайт → тон» и режим промпта по Shift на одну диктовку; без правил везде остаётся уровень B.

**Architecture:** При начале записи снимается `DictationContext`: bundle id, домен активной вкладки браузера через Accessibility и признак Shift. Чистая функция `CleanupLevelResolver` превращает контекст, правила и режим ввода в `CleanupLevel` и подпись для экрана записи. Конвейер получает уровень готовым в `Job`. Режим промпта — вторая регистрация горячей клавиши с Shift или флаг Shift в event tap для одиночной клавиши.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, ApplicationServices Accessibility, Carbon hotkeys, CGEventTap, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-17-dictation-focus-design.md`, разделы 2, 4, 5.

План 2 из 4. План 1 `docs/superpowers/plans/2026-11-17-cleanup-levels-and-providers.md` выполнен в этой же ветке; сигнатуры сверены с кодом: `CleanupLevel` в `Golosok/CleanupModels.swift`, `TranscriptionPipeline.Job.level: CleanupLevel?`, `FallbackNotice.message(for:providerID:engine:)`. При расхождении следовать коду, а не этому плану.

## Global Constraints

- Ветка `feat/dictation-focus`, коммиты в неё, PR только по явной просьбе пользователя.
- Текст интерфейса: без скобок, метки 1–2 слова, подписи короче 8 слов. Новые строки через `String(localized:)` с английским переводом в `Localizable.xcstrings`.
- Правил по умолчанию нет. Без правила — уровень B.
- Порядок поиска: правило сайта → правило приложения → B.
- Промпт сам по сайту или приложению не включается, только по Shift на одну диктовку и только если режим включён в настройках. По умолчанию выключен.
- Режим «Прямой ввод» даёт уровень A и игнорирует правила; явный промпт по Shift работает и в нём.
- Адрес вкладки не сохраняется, не пишется в лог и не уходит в модель. В лог пишется только имя сработавшего правила.
- Accessibility-запросы не задерживают начало записи и не блокируют главный поток.
- Команда тестов, далее `TEST`:
  `xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/<Suite> CODE_SIGN_IDENTITY=- 2>&1 | grep -E "error:|✘|passed|failed|\*\* TEST"`
  Успех — `** TEST SUCCEEDED **`.

## Review Focus

- **Браузер не отвечает на Accessibility.** Ожидание: запись начинается сразу, через 0.3 секунды чтение адреса сдаётся, применяется правило приложения или B. Тест в задаче 2.
- **Горячая клавиша уже содержит Shift** или сама является Shift. Ожидание: режим промпта недоступен, вторая регистрация не создаётся, в настройках подпись «Недоступно с клавишей Shift». Тест в задаче 4.
- **Адрес с `www.`, портом, верхним регистром, точкой в конце.** Ожидание: правило `company.ru` срабатывает для `https://WWW.Mail.Company.RU.:8443/inbox`. Тест в задаче 1.
- **Пользователь вставил в поле домена целый адрес** `https://mail.company.ru/inbox?x=1`. Ожидание: сохраняется `mail.company.ru`. Тест в задаче 1.
- **Вкладку переключили во время записи.** Ожидание: действует правило, снятое при начале записи. Тест в задаче 3.

---

### Task 1: Модель правил, хранилище и выбор уровня

**Files:**
- Create: `Golosok/Rules/DictationRule.swift`
- Create: `Golosok/Rules/DictationRuleStore.swift`
- Create: `Golosok/Rules/CleanupLevelResolver.swift`
- Test: `GolosokTests/Rules/CleanupLevelResolverTests.swift`, `GolosokTests/Rules/DictationRuleStoreTests.swift`

**Interfaces:**
- Consumes: `CleanupLevel` из плана 1; `VoiceInputMode`.
- Produces:
  ```swift
  enum RuleTarget: Codable, Equatable { case app(bundleId: String), site(domain: String) }
  enum RuleTone: Codable, Equatable {
      case business, casual, custom(String)
      var instruction: String
  }
  struct DictationRule: Codable, Identifiable, Equatable {
      let id: UUID; var target: RuleTarget; var displayName: String
      var tone: RuleTone; var isEnabled: Bool
  }
  struct DictationContext: Equatable {
      let bundleId: String?; let host: String?; let promptRequested: Bool
  }
  struct ResolvedLevel: Equatable { let level: CleanupLevel; let label: String; let ruleName: String? }
  enum CleanupLevelResolver {
      static func resolve(_ context: DictationContext, rules: [DictationRule],
                          mode: VoiceInputMode, promptModeEnabled: Bool) -> ResolvedLevel
  }
  enum DomainNormalizer {
      static func host(from input: String) -> String?   // URL или домен → «mail.company.ru»
      static func matches(host: String, ruleDomain: String) -> Bool
  }
  final class DictationRuleStore: ObservableObject {
      static let shared: DictationRuleStore
      @Published private(set) var rules: [DictationRule]
      init(defaults: UserDefaults)
      func add(_ rule: DictationRule); func update(_ rule: DictationRule); func remove(id: UUID)
  }
  ```
  Ключ хранения `dictation.rules`, JSON. Битый JSON — пустой список и предупреждение в `AppLogger`, без падения.

`RuleTone.instruction`, точная копия:
- `.business`: `деловой: вежливо и по делу, полными предложениями, без разговорных слов`
- `.casual`: `живой: коротко и просто, как в переписке с коллегой`
- `.custom(s)`: `s` без пробелов по краям

Подписи `ResolvedLevel.label`: `.verbatim` → «Дословно», `.clean` → «Чисто», `.prompt` → «Промпт», `.rewrite` → `displayName` правила.

Правила `resolve`:
1. `promptRequested && promptModeEnabled` → `.prompt`.
2. `mode == .direct` → `.verbatim`.
3. Включённое правило сайта, если `host` совпал; при нескольких совпадениях — с самым длинным доменом.
4. Включённое правило приложения по точному `bundleId`.
5. Иначе `.clean`.

- [ ] **Step 1: Write the failing tests**

```swift
let gmailSite = DictationRule(id: UUID(), target: .site(domain: "company.ru"), displayName: "Почта", tone: .business, isEnabled: true)
let chromeApp = DictationRule(id: UUID(), target: .app(bundleId: "com.google.Chrome"), displayName: "Chrome", tone: .casual, isEnabled: true)
func ctx(_ b: String?, _ h: String?, prompt: Bool = false) -> DictationContext { .init(bundleId: b, host: h, promptRequested: prompt) }

@Test func siteBeatsApp() {
    let r = CleanupLevelResolver.resolve(ctx("com.google.Chrome", "mail.company.ru"), rules: [chromeApp, gmailSite], mode: .smart, promptModeEnabled: false)
    #expect(r.level == .rewrite(tone: RuleTone.business.instruction)); #expect(r.label == "Почта")
}
@Test func unknownSiteFallsBackToAppRule() {
    let r = CleanupLevelResolver.resolve(ctx("com.google.Chrome", "chatgpt.com"), rules: [chromeApp, gmailSite], mode: .smart, promptModeEnabled: false)
    #expect(r.ruleName == "Chrome")
}
@Test func noRuleGivesClean() {
    #expect(CleanupLevelResolver.resolve(ctx("org.telegram.desktop", nil), rules: [], mode: .smart, promptModeEnabled: false).level == .clean)
}
@Test func disabledRuleIgnored() {
    var off = gmailSite; off.isEnabled = false
    #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [off], mode: .smart, promptModeEnabled: false).level == .clean)
}
@Test func promptNeedsSettingAndShift() {
    #expect(CleanupLevelResolver.resolve(ctx(nil, nil, prompt: true), rules: [], mode: .smart, promptModeEnabled: false).level == .clean)
    #expect(CleanupLevelResolver.resolve(ctx(nil, nil, prompt: true), rules: [], mode: .direct, promptModeEnabled: true).level == .prompt)
}
@Test func directModeIgnoresRules() {
    #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [gmailSite], mode: .direct, promptModeEnabled: true).level == .verbatim)
}
@Test func longestDomainWins() {
    let inner = DictationRule(id: UUID(), target: .site(domain: "mail.company.ru"), displayName: "Внутр", tone: .casual, isEnabled: true)
    #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [gmailSite, inner], mode: .smart, promptModeEnabled: false).ruleName == "Внутр")
}
@Test func domainNormalization() {
    #expect(DomainNormalizer.host(from: "https://WWW.Mail.Company.RU.:8443/inbox") == "mail.company.ru")
    #expect(DomainNormalizer.host(from: "https://mail.company.ru/inbox?x=1") == "mail.company.ru")
    #expect(DomainNormalizer.host(from: "company.ru") == "company.ru")
    #expect(DomainNormalizer.host(from: "   ") == nil)
    #expect(DomainNormalizer.matches(host: "mail.company.ru", ruleDomain: "company.ru"))
    #expect(!DomainNormalizer.matches(host: "notcompany.ru", ruleDomain: "company.ru"))
}
```

В `DictationRuleStoreTests`: добавить, перечитать новым экземпляром на том же `UserDefaults(suiteName:)` — правило на месте; записать мусор в `dictation.rules` — `rules.isEmpty`.

- [ ] **Step 2: Run** `TEST` с `CleanupLevelResolverTests` и `DictationRuleStoreTests`. Expected: ошибки компиляции.

- [ ] **Step 3: Implement** типы и функции. `host(from:)`: если нет схемы, добавить `https://`, взять `URL.host`, нижний регистр, снять точку в конце и префикс `www.`.

- [ ] **Step 4: Run** те же наборы. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Golosok/Rules GolosokTests/Rules
git commit -m "feat(rules): dictation rules, domain matching and cleanup level resolver"
```

---

### Task 2: Адрес активной вкладки браузера

**Files:**
- Create: `Golosok/Rules/BrowserURLReader.swift`
- Test: `GolosokTests/Rules/BrowserURLReaderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol FocusedURLSource { func focusedURL(pid: pid_t, bundleId: String) -> URL? }   // синхронный, может блокировать
  struct AccessibilityURLSource: FocusedURLSource {}
  enum BrowserURLReader {
      static let browserBundleIds: Set<String>
      static let chromiumBundleIds: Set<String>
      static func isBrowser(_ bundleId: String?) -> Bool
      static func readHost(pid: pid_t, bundleId: String?, source: FocusedURLSource,
                           deadline: TimeInterval = 0.3) async -> String?
  }
  ```
  `browserBundleIds`: `com.apple.Safari`, `com.apple.SafariTechnologyPreview`, `com.google.Chrome`, `com.google.Chrome.canary`, `company.thebrowser.Browser`, `com.microsoft.edgemac`, `com.brave.Browser`, `com.operasoftware.Opera`, `com.vivaldi.Vivaldi`, `ru.yandex.desktop.yandex-browser`, `org.mozilla.firefox`. `chromiumBundleIds` — все из списка, кроме Safari, Safari TP и Firefox.

`AccessibilityURLSource.focusedURL`:
1. `AXUIElementCreateApplication(pid)`, `AXUIElementSetMessagingTimeout(app, 0.25)`.
2. Для Chromium один раз на pid выставить `AXManualAccessibility` = `true` на элементе приложения; повторно не выставлять.
3. `kAXFocusedWindowAttribute` → обход в ширину до 400 элементов по `kAXChildrenAttribute` в поиске роли `AXWebArea`.
4. Вернуть атрибут `AXURL` первого найденного `AXWebArea`.
5. Любая ошибка AX → `nil`.

`readHost`: не браузер → `nil` без обращения к источнику; вызов источника в `Task.detached`, гонка с ожиданием `deadline`; результат через `DomainNormalizer.host(from:)`.

- [ ] **Step 1: Write the failing tests** с `final class FakeURLSource: FocusedURLSource` — изменяемый `var url: URL?`, задержка `delay: TimeInterval = 0` и счётчик `calls`.

```swift
@Test func nonBrowserSkipsSource() async {
    let fake = FakeURLSource(url: URL(string: "https://x.ru")!)
    #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "org.telegram.desktop", source: fake) == nil)
    #expect(fake.calls == 0)
}
@Test func browserReturnsNormalizedHost() async {
    let fake = FakeURLSource(url: URL(string: "https://www.Mail.Company.ru/inbox")!)
    #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "com.google.Chrome", source: fake) == "mail.company.ru")
}
@Test func hangingBrowserGivesUpByDeadline() async {
    let fake = FakeURLSource(url: URL(string: "https://x.ru")!, delay: 2)
    let start = Date()
    #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "com.apple.Safari", source: fake, deadline: 0.3) == nil)
    #expect(Date().timeIntervalSince(start) < 0.6)
}
```

- [ ] **Step 2: Run** `TEST` с `BrowserURLReaderTests`. Expected: ошибки компиляции.

- [ ] **Step 3: Implement** по описанию выше.

- [ ] **Step 4: Run** `TEST` с `BrowserURLReaderTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Проверить вручную** временным логом домена через `AppLogger` в отладочной сборке: Safari, Chrome, Arc, Яндекс Браузер с открытой страницей возвращают домен; Firefox допустимо `nil`. Временный лог удалить до коммита.

- [ ] **Step 6: Commit**

```bash
git add Golosok/Rules/BrowserURLReader.swift GolosokTests/Rules/BrowserURLReaderTests.swift
git commit -m "feat(rules): read active browser tab host via Accessibility"
```

---

### Task 3: Контекст при начале записи и уровень в конвейере

**Files:**
- Create: `Golosok/Rules/DictationContextCapture.swift`
- Modify: `Golosok/AudioCapture.swift` — `startRecording(promptRequested: Bool = false)`; захват контекста при начале; разрешение уровня при остановке; подпись режима.
- Modify: `Golosok/AudioCapture.swift:128` — `Job.level` уже есть после плана 1 и сейчас выводится из режима ввода; заменить на результат `CleanupLevelResolver`. `TranscriptionPipeline.Job` не меняется, импорт файлов по-прежнему передаёт `nil`.
- Modify: `Golosok/OverlayPanel.swift:330-345` — справа от таймера в `RecordingLevelView` подпись `AudioCapture.shared.modeLabel` мелким шрифтом, только если она не «Чисто» и не «Дословно»: обычный режим не подписывается, видно лишь «Промпт» или имя правила.
- Test: `GolosokTests/Rules/DictationContextCaptureTests.swift`

**Interfaces:**
- Consumes: `DictationContext`, `CleanupLevelResolver`, `DictationRuleStore`, `BrowserURLReader`, `FocusedURLSource`.
- Produces:
  ```swift
  final class DictationContextCapture {
      init(source: FocusedURLSource = AccessibilityURLSource())
      func begin(app: (pid: pid_t, bundleId: String?)?, promptRequested: Bool)   // запускает чтение адреса в фоне
      func finish() async -> DictationContext                                      // ждёт фоновое чтение не дольше его deadline
  }
  extension AudioCapture {
      @Published var modeLabel: String     // «Чисто», «Промпт», «Дословно» или имя правила
  }
  ```
  `VoiceIntelligenceSettings.promptModeEnabled: Bool`, ключ `voice.promptModeEnabled`, по умолчанию `false`.

Поток в `AudioCapture`:
1. `startRecording(promptRequested:)` вызывает `capture.begin` с `NSWorkspace.shared.frontmostApplication` и сразу ставит `modeLabel` по предварительному `resolve` без адреса.
2. Когда фоновое чтение адреса завершилось, `modeLabel` обновляется на главном потоке.
3. `stopRecording` ждёт `capture.finish()`, вызывает `resolve`, пишет в `AppLogger` «Правило: <имя>» только при `ruleName != nil`, создаёт `Job` с `level`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func contextFrozenAtBegin() async {
    let fake = FakeURLSource(url: URL(string: "https://mail.company.ru")!)
    let capture = DictationContextCapture(source: fake)
    capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), promptRequested: true)
    try? await Task.sleep(for: .milliseconds(100))
    fake.url = URL(string: "https://chatgpt.com")!
    let c = await capture.finish()
    #expect(c == DictationContext(bundleId: "com.google.Chrome", host: "mail.company.ru", promptRequested: true))
    #expect(fake.calls == 1)
}
@Test func noFrontAppGivesEmptyContext() async {
    let capture = DictationContextCapture(source: FakeURLSource(url: nil))
    capture.begin(app: nil, promptRequested: false)
    #expect(await capture.finish() == DictationContext(bundleId: nil, host: nil, promptRequested: false))
}
```

`FakeURLSource` перенести в `GolosokTests/TestSupport/FakeURLSource.swift`.

- [ ] **Step 2: Run** `TEST` с `DictationContextCaptureTests`. Expected: ошибки компиляции.

- [ ] **Step 3: Implement** `DictationContextCapture`, изменения `AudioCapture`, `OverlayPanel`, `promptModeEnabled`. Во всех вызовах `startRecording()` без Shift поведение прежнее.

- [ ] **Step 4: Run** весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Проверить вручную:** правило сайта для открытого в Safari домена с тоном «Деловой» → на экране записи имя правила, вставленный текст в деловом тоне; Telegram без правила → подписи нет, текст уровня B.

- [ ] **Step 6: Commit**

```bash
git add -A Golosok GolosokTests
git commit -m "feat(rules): resolve cleanup level from app and tab at recording start"
```

---

### Task 4: Сочетание с Shift для режима промпта

**Files:**
- Modify: `Golosok/HotKeyTrigger.swift` — вычисление сочетания промпта.
- Modify: `Golosok/NativeHotKeyManager.swift` — вторая регистрация Carbon с id `2`; Shift в event tap; колбэк с признаком.
- Modify: `Golosok/GolosokApp.swift:15-28` — передавать признак в `startRecording(promptRequested:)` и `toggleRecording(promptRequested:)`.
- Modify: `Golosok/AudioCapture.swift` — `toggleRecording(promptRequested: Bool = false)`; признак учитывается только при начале записи.
- Test: `GolosokTests/PromptHotKeyTests.swift`

**Interfaces:**
- Consumes: `VoiceIntelligenceSettings.promptModeEnabled` из задачи 3.
- Produces:
  ```swift
  extension HotKeyTrigger {
      var promptVariant: HotKeyTrigger?   // nil — режим промпта недоступен с этой клавишей
  }
  // NativeHotKeyManager
  public var onHotKeyPressed: ((_ promptRequested: Bool) -> Void)?
  func refreshPromptRegistration()   // вызывать при смене клавиши и переключателя
  ```

`promptVariant`:
- `.combination(k, m)` без `shiftKey` в `m` → `.combination(k, m | shiftKey)`; с `shiftKey` → `nil`.
- `.singleModifier(.leftShift)`, `.singleModifier(.rightShift)` → `nil`; остальные `.singleModifier(x)` → `.singleModifier(x)`, Shift проверяется по флагам события.
- `.none` → `nil`.

Поведение:
- Комбинация: при `promptModeEnabled` и `promptVariant != nil` регистрируется второй `RegisterEventHotKey` с id `2`; обработчик различает id через `GetEventParameter(kEventParamDirectObject)`; id `2` → `onHotKeyPressed(true)`, отпускание → `onHotKeyReleased`. Отключение переключателя снимает регистрацию id `2`.
- Одиночная клавиша: в `handleEventTap` при нажатии `promptRequested = promptModeEnabled && event.flags.contains(.maskShift)`. Shift нужно зажать до клавиши.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func promptVariantForCombination() {
    #expect(HotKeyTrigger.optionSpace.promptVariant == .combination(keyCode: 49, modifiers: UInt32(optionKey | shiftKey)))
    #expect(HotKeyTrigger.combination(keyCode: 49, modifiers: UInt32(optionKey | shiftKey)).promptVariant == nil)
}
@Test func promptVariantForShiftKeysIsNil() {
    #expect(HotKeyTrigger.singleModifier(.leftShift).promptVariant == nil)
    #expect(HotKeyTrigger.singleModifier(.rightShift).promptVariant == nil)
    #expect(HotKeyTrigger.none.promptVariant == nil)
    #expect(HotKeyTrigger.fnKey.promptVariant == .fnKey)
}
@Test func fnWithShiftRequestsPrompt() {
    // trigger = .fnKey, promptModeEnabled = true; сохранить и восстановить значения как в HotKeyTriggerTests
    var received: Bool?
    manager.onHotKeyPressed = { received = $0 }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
    down.flags = [.maskSecondaryFn, .maskShift]
    manager.handleEventTap(type: .flagsChanged, event: down)
    // дождаться главного потока, как в HotKeyTriggerTests
    #expect(received == true)
}
@Test func fnWithShiftWhenDisabledIsPlain() { /* то же при promptModeEnabled = false → received == false */ }
```

Существующие тесты `HotKeyTriggerTests` обновить под новую сигнатуру колбэка.

- [ ] **Step 2: Run** `TEST` с `PromptHotKeyTests`. Expected: ошибки компиляции.

- [ ] **Step 3: Implement** `promptVariant`, вторую регистрацию, флаг в event tap, проводку в `GolosokApp` и `AudioCapture`.

- [ ] **Step 4: Run** весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Проверить вручную** при включённом режиме: `⌥⇧Space` в режиме переключения → подпись «Промпт», результат — запрос к нейросети; следом `⌥Space` в том же чате → подписи нет, обычный текст B. То же для Fn: зажать Shift, затем Fn. В режиме рации — удержание с Shift.

- [ ] **Step 6: Commit**

```bash
git add -A Golosok GolosokTests
git commit -m "feat(prompt): Shift with hotkey runs one dictation in prompt mode"
```

---

### Task 5: Настройки правил и режима промпта

**Files:**
- Create: `Golosok/Rules/RulesSettingsSection.swift`
- Create: `Golosok/Rules/RuleEditorSheet.swift`
- Create: `Golosok/Rules/RuleEditorLogic.swift`
- Modify: `Golosok/SettingsView.swift:320` — `RulesSettingsSection()` после `VoiceIntelligenceSection()`.
- Modify: `Golosok/AISettingsSection.swift` — в `VoiceIntelligenceSection` переключатель «Режим промпта».
- Modify: `Golosok/Localizable.xcstrings`
- Test: `GolosokTests/Rules/RuleEditorLogicTests.swift`

**Interfaces:**
- Consumes: `DictationRuleStore`, `DictationRule`, `RuleTone`, `DomainNormalizer`, `HotKeyTrigger.promptVariant`, `NativeHotKeyManager.refreshPromptRegistration`.
- Produces:
  ```swift
  struct RuleDraft: Equatable {
      enum Kind { case app, site }
      var kind: Kind; var bundleId: String?; var appName: String?
      var domainInput: String; var tone: RuleTone; var customText: String
  }
  enum RuleEditorLogic {
      static func makeRule(from draft: RuleDraft, existing: [DictationRule], id: UUID = UUID()) -> Result<DictationRule, RuleEditorError>
      static func runningApps() -> [(bundleId: String, name: String)]   // .regular, без Голоска, по имени
  }
  enum RuleEditorError: Equatable { case emptyTarget, invalidDomain, emptyCustomTone, duplicate }
  ```
  `displayName`: для сайта — нормализованный домен, для приложения — имя приложения. `duplicate` — уже есть правило с той же целью.

Тексты, точная копия:

| Место | Текст |
| --- | --- |
| Заголовок раздела | Приложения |
| Подпись раздела | Тон текста по приложению или сайту |
| Пустой список | Правил нет, везде чистый текст |
| Кнопка | Добавить |
| Переключатель вида | Приложение / Сайт |
| Поле домена, подсказка | mail.company.ru |
| Выбор тона | Деловой / Живой / Свой |
| Поле своего тона, подсказка | Как писать текст |
| Ошибки | Укажите приложение · Неверный адрес · Опишите тон · Правило уже есть |
| Переключатель промпта | Режим промпта |
| Подпись промпта | `⇧ + <имя клавиши>` на одну диктовку |
| Подпись, если недоступно | Недоступно с клавишей Shift |

Строка правила: имя, тон, переключатель включения, удаление по кнопке корзины без подтверждения.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func siteDraftNormalizesPastedURL() throws {
    let d = RuleDraft(kind: .site, bundleId: nil, appName: nil, domainInput: "https://mail.company.ru/inbox?x=1", tone: .business, customText: "")
    let rule = try RuleEditorLogic.makeRule(from: d, existing: []).get()
    #expect(rule.target == .site(domain: "mail.company.ru")); #expect(rule.displayName == "mail.company.ru")
}
@Test func editorErrors() {
    let base = RuleDraft(kind: .site, bundleId: nil, appName: nil, domainInput: "", tone: .business, customText: "")
    #expect(RuleEditorLogic.makeRule(from: base, existing: []) == .failure(.invalidDomain))
    var custom = base; custom.domainInput = "x.ru"; custom.tone = .custom("  ")
    #expect(RuleEditorLogic.makeRule(from: custom, existing: []) == .failure(.emptyCustomTone))
    let app = RuleDraft(kind: .app, bundleId: nil, appName: nil, domainInput: "", tone: .casual, customText: "")
    #expect(RuleEditorLogic.makeRule(from: app, existing: []) == .failure(.emptyTarget))
}
@Test func duplicateTargetRejected() throws {
    let d = RuleDraft(kind: .site, bundleId: nil, appName: nil, domainInput: "x.ru", tone: .business, customText: "")
    let first = try RuleEditorLogic.makeRule(from: d, existing: []).get()
    #expect(RuleEditorLogic.makeRule(from: d, existing: [first]) == .failure(.duplicate))
}
```

- [ ] **Step 2: Run** `TEST` с `RuleEditorLogicTests`. Expected: ошибки компиляции.

- [ ] **Step 3: Implement** логику, раздел, лист редактора и переключатель на существующих компонентах `UICard`, `UISegmented`, `UIDropdownPicker`, `UIOutlineButton`. Переключатель промпта вызывает `NativeHotKeyManager.shared.refreshPromptRegistration()`; при `promptVariant == nil` он выключен и показана подпись недоступности.

- [ ] **Step 4: Run** весь `GolosokTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Проверить вручную:** добавить правило приложения из списка запущенных, правило сайта вставкой полного адреса, свой тон; выключить и удалить правило; перезапустить приложение — правила на месте; включить режим промпта с клавишей `⇧` — переключатель недоступен.

- [ ] **Step 6: Commit**

```bash
git add -A Golosok GolosokTests
git commit -m "feat(rules): settings section for app and site rules and prompt mode"
```
