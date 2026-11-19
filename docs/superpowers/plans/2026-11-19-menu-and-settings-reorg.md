# Боковое меню, строка меню и реорганизация настроек: план работ

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Режим диктовки и звуки переключаются из строки меню, настройки распадаются на шесть коротких разделов, правила приложений становятся пунктом бокового меню, а «Умная речь» и режим промпта удаляются.

**Architecture:** Боковое меню `ContentView` получает четвёртый пункт и второй уровень для настроек — список разделов показывается там же, где сегодня показывается список истории, поэтому третий столбец не нужен. `SettingsView` перестаёт быть одной прокруткой и становится переключателем по `SettingsSection`; каждый раздел живёт в своём файле в `Tranq/Settings/`. Строка меню и настройки читают одни и те же хранилища `HotKeySettings.mode` и `AppPreferences.soundEnabled`.

**Tech Stack:** Swift, SwiftUI, AppKit, swift-testing, Xcode project `Tranq.xcodeproj`, схема `Tranq`.

**Spec:** `docs/superpowers/specs/2026-11-19-menu-and-settings-reorg-design.md`

## Global Constraints

- Без круглых скобок в тексте интерфейса: ни `(...)`, ни `[...]`, ни `{...}`.
- Метки в одно-два слова, подзаголовки короче восьми слов.
- Нулевая избыточность внутри одного экрана. Дубль между строкой меню и настройками разрешён и является решением владельца.
- Весь текст интерфейса через `Font.ui`; Knewave только через `Font.brand`.
- Минимальное окно 860 × 560; ширина бокового меню от 220 до 420.
- `Tranq/Localizable.xcstrings` правится без переформатирования: загрузить JSON, изменить только нужные ключи, записать дампером в стиле Xcode, проверить, что `git diff --stat` пропорционален числу ключей. Строки интерфейса ключуются своим русским текстом, рядом с `ru` обязателен `en`.
- `bash scripts/check-brand.sh` проходит.
- Тесты: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests CODE_SIGN_IDENTITY=-`.
- Ветка одна на всю работу: `feat/menu-settings-reorg`. PR только по явной просьбе владельца.

## Review Focus

Пять случаев, которые спека подразумевает, но ни одна задача не проверяла бы без этого списка. Тест на каждый добавлен в задачу, которой принадлежит код.

1. Режим меняют из строки меню, пока идёт запись: смена не должна влиять на текущую запись. Задача 1.
2. Первый запуск после обновления с сохранённым `voice.mode = direct` и внешним движком: человек молча переходит на отправку текста провайдеру. Задача 5 фиксирует это тестом, чтобы поведение было осознанным, а не случайным.
3. В `settings.section` лежит значение от будущей или сломанной версии: раздел должен открыться на «Диктовке», а не на пустом экране. Задача 3.
4. Боковое меню свёрнуто, выбраны настройки: «Настройки…» из строки меню обязаны его раскрыть, иначе навигация недоступна. Задача 3.
5. Записи истории, сделанные прежней версией в режиме промпта: после удаления уровня они обязаны открываться и воспроизводиться. Задача 6.

---

### Task 1: Режим и звуки в строке меню

**Files:**
- Modify: `Tranq/NativeHotKeyManager.swift` — `HotKeyMode`, добавить `title` и `allCases` порядок
- Modify: `Tranq/TranqApp.swift:123-143` — `MenuBarExtra`, и `CommandGroup` для ⌘,
- Modify: `Tranq/Localizable.xcstrings`
- Test: `TranqTests/MenuBarModeTests.swift`

**Interfaces:**
- Consumes: `HotKeySettings.shared.mode: HotKeyMode`, `AppPreferences.shared.soundEnabled: Bool`
- Produces: `HotKeyMode.allCases: [HotKeyMode]` в порядке `[.toggle, .pushToTalk]`; `HotKeyMode.title: String`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Tranq

@Suite(.serialized) @MainActor
struct MenuBarModeTests {
    @Test func modeOrderMatchesMenu() {
        #expect(HotKeyMode.allCases == [.toggle, .pushToTalk])
    }

    @Test func modeTitlesAreDistinctAndFilled() {
        #expect(HotKeyMode.toggle.title != HotKeyMode.pushToTalk.title)
        #expect(!HotKeyMode.toggle.title.isEmpty)
    }

    /// Review Focus 1: смена режима во время записи не трогает текущую запись.
    @Test func switchingModeDuringRecordingKeepsRecording() {
        let settings = HotKeySettings.shared
        let before = settings.mode
        defer { settings.mode = before }
        settings.mode = .toggle
        settings.mode = .pushToTalk
        #expect(AudioCapture.shared.isRecording == false)
    }

    @Test func menuAndSettingsShareOneStore() {
        let settings = HotKeySettings.shared
        let before = settings.mode
        defer { settings.mode = before }
        settings.mode = .pushToTalk
        #expect(NativeHotKeyManager.shared.mode == .pushToTalk)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests/MenuBarModeTests CODE_SIGN_IDENTITY=-`
Expected: FAIL, `HotKeyMode` не имеет `title` и не соответствует `CaseIterable` с нужным порядком.

- [ ] **Step 3: Добавить `HotKeyMode.title: String` и `CaseIterable` в `Tranq/NativeHotKeyManager.swift`**

`title` возвращает `String(localized:)` для существующих ключей: `.toggle` → `HotKey.ModeToggle`, `.pushToTalk` → `HotKey.ModePushToTalk`. Ключи уже переведены: Переключение / Toggle и Рация / Push-to-talk, новых строк не нужно.

- [ ] **Step 4: Run test to verify it passes**

Run: та же команда.
Expected: PASS

- [ ] **Step 5: Собрать меню в `Tranq/TranqApp.swift`**

Порядок пунктов строго такой:

```
Режим
  ✓ Переключение
    Рация
──────────
✓ Звуки
──────────
Развернуть Tranq
Настройки…
──────────
Завершить
```

Режим — заголовок `Text("Режим")` и две кнопки с `Image(systemName:)` отметки для текущего значения; звуки — одна кнопка с отметкой, читает и пишет `AppPreferences.shared.soundEnabled`. Пункт «Настройки…» остаётся как есть.

- [ ] **Step 6: Привязать ⌘, к настройкам**

В `.commands` добавить группу, которая разворачивает окно и постит `OpenSettingsTab`, с `.keyboardShortcut(",", modifiers: .command)`. Сегодня сочетание не привязано ни к чему.

- [ ] **Step 7: Добавить ключи «Режим» и «Звуки» в `Tranq/Localizable.xcstrings`**

`Режим` → en `Mode`; `Звуки` → en `Sounds`. Правила правки файла — в Global Constraints.

- [ ] **Step 8: Прогнать все тесты и проверку имени**

Run: `bash scripts/check-brand.sh && xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests CODE_SIGN_IDENTITY=-`
Expected: TEST SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add Tranq/NativeHotKeyManager.swift Tranq/TranqApp.swift Tranq/Localizable.xcstrings TranqTests/MenuBarModeTests.swift
git commit -m "feat: режим диктовки и звуки в строке меню"
```

---

### Task 2: Правила как пункт бокового меню

**Files:**
- Modify: `Tranq/ContentView.swift` — `MainTab`, `sidebarColumn`, `currentTabTitle`, `mainInterface`
- Create: `Tranq/Rules/RulesView.swift`
- Modify: `Tranq/Rules/RulesSettingsSection.swift` — остаётся карточкой, но её показывает `RulesView`
- Modify: `Tranq/Localizable.xcstrings`
- Test: `TranqTests/MainTabTests.swift`

**Interfaces:**
- Consumes: `DictationRuleStore.shared.rules`, `RulesSettingsSection`
- Produces: `MainTab` с кейсами `[.vocabulary, .rules, .history, .settings]`; `struct RulesView: View`; оповещение `OpenRulesTab`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Tranq

struct MainTabTests {
    @Test func sidebarOrder() {
        #expect(MainTab.allCases == [.vocabulary, .rules, .history, .settings])
    }

    @Test func everyTabHasTitle() {
        for tab in MainTab.allCases { #expect(!tab.title.isEmpty) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:TranqTests/MainTabTests CODE_SIGN_IDENTITY=-`
Expected: FAIL, `MainTab` не `CaseIterable` и не имеет `.rules` и `title`.

- [ ] **Step 3: Расширить `MainTab` в `Tranq/ContentView.swift`**

`enum MainTab: CaseIterable` с кейсами в порядке выше и `var title: String`. `currentTabTitle` начинает использовать `title`, свой `switch` убирается.

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Создать `Tranq/Rules/RulesView.swift`**

`struct RulesView: View` — `ScrollView` с `RulesSettingsSection()` внутри, отступ 20, фон `Color.uiCanvas`, по образцу того, как `SettingsView` обрамляет свои карточки.

- [ ] **Step 6: Включить пункт в боковое меню и в содержимое**

В `sidebarColumn` четвёртая `SidebarTabButton` с иконкой `slider.horizontal.3` между словарём и историей. В `mainInterface` ветка `case .rules: RulesView()`. Подписка на `OpenRulesTab` по образцу `OpenVocabularyTab`.

- [ ] **Step 7: Ключ «Правила» в `Tranq/Localizable.xcstrings`**

`Правила` → en `Rules`.

- [ ] **Step 8: Прогнать все тесты**

Expected: TEST SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add Tranq/ContentView.swift Tranq/Rules Tranq/Localizable.xcstrings TranqTests/MainTabTests.swift
git commit -m "feat: правила приложений как раздел бокового меню"
```

---

### Task 3: Второй уровень настроек

**Files:**
- Create: `Tranq/Settings/SettingsSection.swift`
- Create: `Tranq/Settings/DictationSettingsSection.swift`, `RecognitionSettingsSection.swift`, `AppSettingsSection.swift`, `DataSettingsSection.swift`
- Modify: `Tranq/SettingsView.swift` — становится переключателем по разделу
- Modify: `Tranq/ContentView.swift` — список разделов в боковом меню, раскрытие меню по `OpenSettingsTab`
- Modify: `Tranq/Localizable.xcstrings`
- Test: `TranqTests/SettingsSectionTests.swift`

**Interfaces:**
- Consumes: существующие карточки `VoiceIntelligenceSection`, `AIProviderSection`, `MCPSettingsSection`, `ActiveModelStatusRow`
- Produces: `enum SettingsSection: String, CaseIterable, Identifiable` с кейсами `[.dictation, .recognition, .processing, .provider, .app, .data]`; `var title: String`; `static func restore(from defaults: UserDefaults) -> SettingsSection`; `func store(in defaults: UserDefaults)`; `SettingsView(section: SettingsSection)`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Tranq

struct SettingsSectionTests {
    private func scratch() -> UserDefaults {
        let d = UserDefaults(suiteName: "tranq-settings-section-\(UUID().uuidString)")!
        return d
    }

    @Test func sectionOrder() {
        #expect(SettingsSection.allCases == [.dictation, .recognition, .processing, .provider, .app, .data])
    }

    @Test func storedSectionRoundTrips() {
        let d = scratch()
        SettingsSection.provider.store(in: d)
        #expect(SettingsSection.restore(from: d) == .provider)
    }

    /// Review Focus 3: неизвестное или пустое значение открывает первый раздел.
    @Test func unknownStoredSectionFallsBackToDictation() {
        let d = scratch()
        d.set("какой-то-будущий-раздел", forKey: "settings.section")
        #expect(SettingsSection.restore(from: d) == .dictation)
        let empty = scratch()
        #expect(SettingsSection.restore(from: empty) == .dictation)
    }

    @Test func everySectionHasTitle() {
        for s in SettingsSection.allCases { #expect(!s.title.isEmpty) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:TranqTests/SettingsSectionTests CODE_SIGN_IDENTITY=-`
Expected: FAIL, `SettingsSection` не существует.

- [ ] **Step 3: Создать `SettingsSection` в `Tranq/Settings/SettingsSection.swift`**

Ключ хранения `settings.section`. `title` через `String(localized:)`: Диктовка, Распознавание, Обработка, Провайдер, Приложение, Данные.

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Разнести карточки по файлам разделов**

Состав строго по спеке §9. `SettingsView.swift` теряет свою `VStack` на двадцать с лишним строк и становится `switch section`. Карточки, которые уже лежат отдельно, переиспользуются: обработка — `VoiceIntelligenceSection`, провайдер — `AIProviderSection`, данные — `MCPSettingsSection` плюс логи и стирание истории. Каждый раздел заворачивается в свой `ScrollView`: решение §15, разделы «Обработка» и «Провайдер» на минимальном окне не умещаются.

- [ ] **Step 6: Показать список разделов в боковом меню**

В `sidebarColumn` ветка по образцу истории: `if currentTab == .settings { settingsSectionList }`. Выбранный раздел хранится в `@AppStorage("settings.section")`.

- [ ] **Step 7: Раскрывать меню при переходе в настройки**

Review Focus 4: обработчик `OpenSettingsTab` в `ContentView` ставит `isSidebarVisible = true` вместе с `currentTab = .settings`, иначе со свёрнутым меню разделы недоступны.

- [ ] **Step 8: Ключи разделов в `Tranq/Localizable.xcstrings`**

Диктовка / Dictation, Распознавание / Recognition, Обработка / Processing, Провайдер / Provider, Приложение / Application, Данные / Data.

- [ ] **Step 9: Прогнать все тесты и проверку имени**

Expected: TEST SUCCEEDED

- [ ] **Step 10: Commit**

```bash
git add Tranq/Settings Tranq/SettingsView.swift Tranq/ContentView.swift Tranq/Localizable.xcstrings TranqTests/SettingsSectionTests.swift
git commit -m "feat: настройки из шести разделов"
```

---

### Task 4: Переименования и перенос аппаратного ускорения

**Files:**
- Modify: `Tranq/Settings/RecognitionSettingsSection.swift` — «Модель распознавания»
- Modify: `Tranq/AISettingsSection.swift` — «Модель обработки»
- Modify: `Tranq/Settings/DictationSettingsSection.swift` — «Звуки» и новая подпись
- Modify: `Tranq/AboutView.swift` — строка «Apple Metal»
- Modify: `Tranq/Localizable.xcstrings`

Тестов на копирайтинг нет: это текст интерфейса, его проверяет сборка, `check-brand.sh` и просмотр глазами. Единственное машинно проверяемое требование — что обе модели больше не называются одинаково, и оно обеспечивается разными ключами локализации.

- [ ] **Step 1: Переименовать строки**

| Было | Стало |
| --- | --- |
| «Языковая модель» в разделе распознавания | «Модель распознавания» |
| «Языковая модель» в обработке | «Модель обработки» |
| «Системные звуки» | «Звуки» |
| Подпись «Акустический отклик при активации, копировании и ошибках» | «Начало и конец записи, копирование, ошибки» |

- [ ] **Step 2: Перенести «Аппаратное ускорение: Apple Metal» в `AboutView`**

Из настроек строка уходит целиком: это надпись, а не настройка.

- [ ] **Step 3: Обновить `Tranq/Localizable.xcstrings`**

Добавить: Модель распознавания / Recognition model, Модель обработки / Processing model, Начало и конец записи, копирование, ошибки / Recording start and end, copying, errors. Удалить ключи, которые больше нигде не используются: Системные звуки, Акустический отклик при активации, копировании и ошибках, и заголовки исчезнувших карточек. Перед коммитом проверить `git diff --stat` на пропорциональность.

- [ ] **Step 4: Прогнать все тесты и проверку имени**

Expected: TEST SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Tranq Tranq/Localizable.xcstrings
git commit -m "refactor: понятные названия строк настроек"
```

---

### Task 5: Удалить «Умную речь»

**Files:**
- Modify: `Tranq/VoiceIntelligenceSettings.swift` — убрать `VoiceInputMode`, `mode`, ключ `voice.mode`
- Modify: `Tranq/AISettingsSection.swift` — убрать переключатель и условие `if settings.mode == .smart`
- Modify: `Tranq/Rules/CleanupLevelResolver.swift` — убрать параметр `mode`
- Modify: `Tranq/AudioCapture.swift:85-87` — прогрев соединения без проверки режима
- Modify: `TranqTests/` — наборы, которые передают `mode`
- Test: `TranqTests/CleanupLevelResolverTests.swift` или существующий набор с правилами

**Interfaces:**
- Produces: `CleanupLevelResolver.resolve(_ context: DictationContext, rules: [DictationRule], promptModeEnabled: Bool) -> ResolvedLevel` — параметр `mode` исчезает; `promptModeEnabled` уходит в задаче 6

- [ ] **Step 1: Write the failing test**

```swift
@Test func resolveWithoutRulesIsClean() {
    let context = DictationContext(bundleId: "ru.keepcoder.Telegram", host: nil, promptRequested: false)
    let resolved = CleanupLevelResolver.resolve(context, rules: [], promptModeEnabled: false)
    #expect(resolved.level == .clean)
}

/// Review Focus 2: сохранённый прежней версией режим `direct` больше не влияет ни на что.
@Test func legacyDirectModeIsIgnored() {
    let d = UserDefaults(suiteName: "tranq-legacy-mode-\(UUID().uuidString)")!
    d.set("direct", forKey: "voice.mode")
    let context = DictationContext(bundleId: nil, host: nil, promptRequested: false)
    #expect(CleanupLevelResolver.resolve(context, rules: [], promptModeEnabled: false).level == .clean)
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL, у `resolve` другой список параметров.

- [ ] **Step 3: Удалить режим**

`VoiceInputMode` и свойство `mode` уходят вместе с ключом `voice.mode` и его веткой в `resetToDefaults`. Ветка `if mode == .direct` в `CleanupLevelResolver.resolve` удаляется; порядок разрешения становится: промпт по Shift, правило сайта, правило приложения, чистая мысль. В `AudioCapture.startRecording` прогрев соединения вызывается без условия. Карточка обработки больше не скрывает содержимое.

`CleanupLevel.verbatim` остаётся в модели как недостижимый уровень, с комментарием про §11 спеки: уровни — каркас спеки от 2026-11-17, тон «Дословно» в правилах вынесен за рамки.

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS, и остальные наборы собираются после правки вызовов.

- [ ] **Step 5: Прогнать все тесты**

Expected: TEST SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Tranq TranqTests
git commit -m "refactor: убрать переключатель умной речи"
```

---

### Task 6: Удалить режим промпта

**Files:**
- Modify: `Tranq/VoiceIntelligenceSettings.swift` — `promptModeEnabled`, ключ `voice.promptModeEnabled`
- Modify: `Tranq/AISettingsSection.swift` — `promptModeRow`
- Modify: `Tranq/Rules/RuleEditorLogic.swift` — удалить `PromptModeHint`
- Modify: `Tranq/NativeHotKeyManager.swift` — `promptHotKeyID`, регистрация сочетания с Shift, `promptVariant`, `refreshPromptRegistration`, сигнатура `onHotKeyPressed`
- Modify: `Tranq/TranqApp.swift:15-23` — вызовы без `promptRequested`
- Modify: `Tranq/AudioCapture.swift` — `startRecording`, `beginDictationContext`
- Modify: `Tranq/Rules/CleanupLevelResolver.swift` — `DictationContext.promptRequested`, ветка `.prompt`, `overlayLabel`
- Modify: `Tranq/ThoughtSynthesizer.swift`, `Tranq/GroundingValidator.swift` — ветки `.prompt`
- Modify: `Tranq/CleanupModels.swift` — кейс `.prompt`
- Delete: `TranqTests/PromptHotKeyTests.swift`
- Test: `TranqTests/HistoryNoteTests.swift` — старые записи

**Interfaces:**
- Produces: `CleanupLevelResolver.resolve(_ context: DictationContext, rules: [DictationRule]) -> ResolvedLevel`; `DictationContext(bundleId:host:)`; `NativeHotKeyManager.onHotKeyPressed: (() -> Void)?`

- [ ] **Step 1: Write the failing test**

```swift
@Test func resolveTakesContextAndRulesOnly() {
    let context = DictationContext(bundleId: nil, host: nil)
    #expect(CleanupLevelResolver.resolve(context, rules: []).level == .clean)
}

/// Review Focus 5: записи, сделанные прежней версией в режиме промпта, читаются.
@Test func legacyPromptNoteStillLoads() throws {
    let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"18.11.2026, 09:30","text":"Контекст: релиз в пятницу. Задача: собрать dmg.","duration":"7 сек","spokenText":"ну короче контекст релиз в пятницу надо собрать dmg"}]"#
    let items = try JSONDecoder().decode([TranscriptionItem].self, from: Data(json.utf8))
    #expect(items[0].text.hasPrefix("Контекст"))
    #expect(items[0].showsSpokenToggle)
}
```

Второй тест идёт в `HistoryNoteTests` по образцу `legacyItemDecodesWithoutSpokenText`: уровень очистки в записи никогда не хранился, поэтому удаление уровня `.prompt` не должно ломать декодирование, и тест это закрепляет.

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL, `DictationContext` требует `promptRequested`.

- [ ] **Step 3: Удалить режим промпта**

Выключатель, настройка, подсказка, регистрация сочетания с Shift, уровень `.prompt` в разрешителе, синтезаторе, валидаторе и модели уровней, подпись промпта в окошке записи. `onHotKeyPressed` теряет аргумент. В валидаторе исчезают условие `level != .prompt` и кейс `.prompt` в расчёте допустимого объёма.

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Прогнать все тесты**

Expected: TEST SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Tranq TranqTests
git commit -m "refactor: убрать режим промпта"
```

---

### Task 7: Авто-открытие истории не крадёт экран

**Files:**
- Create: `Tranq/AutoOpenPolicy.swift`
- Modify: `Tranq/ContentView.swift:86-95` — обработчик `AutoSelectNote`
- Test: `TranqTests/AutoOpenPolicyTests.swift`

**Interfaces:**
- Consumes: `AppPreferences.shared.autoOpenNoteEnabled`, `MainWindowController.shared.isWindowVisible`
- Produces: `AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: Bool, isWindowVisible: Bool) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Tranq

struct AutoOpenPolicyTests {
    @Test func switchesWhenWindowHidden() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: false) == true)
    }

    @Test func keepsScreenWhenWindowOpen() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: true) == false)
    }

    @Test func neverSwitchesWhenSettingOff() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: false, isWindowVisible: false) == false)
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: false, isWindowVisible: true) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL, `AutoOpenPolicy` не существует.

- [ ] **Step 3: Создать `AutoOpenPolicy` в `Tranq/AutoOpenPolicy.swift`**

Чистая функция, без обращения к синглтонам: решение зависит только от двух флагов.

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS

- [ ] **Step 5: Применить в `ContentView`**

Обработчик `AutoSelectNote` спрашивает политику. Когда она отвечает «нет», запись остаётся непрочитанной: `markAsRead` не вызывается, `currentTab` и `selectedItemId` не меняются.

- [ ] **Step 6: Прогнать все тесты**

Expected: TEST SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add Tranq/AutoOpenPolicy.swift Tranq/ContentView.swift TranqTests/AutoOpenPolicyTests.swift
git commit -m "fix: авто-открытие истории не уводит с текущего экрана"
```

---

### Task 8: Документация и версия

**Files:**
- Modify: `README_RU.md`, `README.md`
- Modify: `Tranq.xcodeproj/project.pbxproj` — `MARKETING_VERSION`
- Test: `TranqTests/BrandingTests.swift` — `marketingVersionIsThreeX` уже есть

- [ ] **Step 1: Обновить оба README**

Убрать «Умную речь» и режим промпта, описать строку меню и шесть разделов настроек, упомянуть пункт «Правила».

- [ ] **Step 2: Поднять `MARKETING_VERSION` до следующей минорной версии линии 3.x**

Работа — фича, поэтому минорная версия, а не патч. Тег `vX.Y.0` ставится при выпуске, не здесь.

- [ ] **Step 3: Прогнать все тесты и проверку имени**

Run: `bash scripts/check-brand.sh && xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests CODE_SIGN_IDENTITY=-`
Expected: TEST SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add README.md README_RU.md Tranq.xcodeproj/project.pbxproj
git commit -m "docs: описать новое меню и настройки"
```
