# Подсветка окна диктовки: план работ

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Во время диктовки вокруг фокусного окна переднего приложения горит салатовая неоновая рамка, которая гаснет после вставки текста.

**Architecture:** Чистая логика геометрии и решения «показывать или нет» живёт в отдельном файле без зависимостей от AppKit-окон и тестируется напрямую. Поверх неё `WindowHighlightManager` ведёт прозрачную `NSPanel` по образцу `OverlayPanelManager`: смену переднего приложения ловит уведомление `NSWorkspace`, положение и размер окна опрашивает таймер 30 Гц через Accessibility. Источник рамки окна внедряется замыканием, поэтому менеджер тестируется без экрана.

**Tech Stack:** Swift 6, SwiftUI, AppKit, ApplicationServices (Accessibility), Swift Testing, Xcode 26.

**Spec:** [`docs/superpowers/specs/2026-11-19-dictation-window-highlight-design.md`](../specs/2026-11-19-dictation-window-highlight-design.md)

## Global Constraints

- Имя приложения только `Tranq`, латиницей. `scripts/check-brand.sh` обязан оставаться зелёным.
- Весь текст интерфейса — Inter через `Font.ui`. Новых шрифтов не добавляем.
- Микрокопирайтинг: метки 1–2 слова, подзаголовки строго меньше 8 слов, круглых и квадратных скобок в пользовательском тексте нет.
- Исходный язык каталога строк `Tranq/Localizable.xcstrings` — `ru`; у каждой новой строки должны быть локализации `en` и `ru` в состоянии `translated`. Файл редактируется только в формате Xcode, обычный `json.dump` ломает его.
- Цвет рамки `#CBFF6E`, линия 2 пт, радиус скругления 10 пт. Это единственное место в приложении, где появляется акцентный цвет.
- Новых системных разрешений не запрашиваем: используется уже выданный доступ Accessibility.
- Тесты пишутся на Swift Testing: `import Testing`, `struct ...Tests`, `@Test func`, `#expect`.
- Команда прогона тестов целиком: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests CODE_SIGN_IDENTITY=-`

## Review Focus

1. **Прав Accessibility нет** — рамка просто не появляется, приложение не падает и не пишет предупреждения в каждом такте таймера. Тест в задаче 1.
2. **Второй монитор выше или левее главного** — координаты Accessibility считаются от верхнего левого угла главного экрана, и при наивном пересчёте рамка уезжает на отрицательные координаты. Тест в задаче 1.
3. **Фокусного окна нет** — рабочий стол Finder, приложение без окон, окно свёрнуто в Dock. Рамка прячется, а не застывает на прежнем месте. Тест в задаче 1 и задаче 3.
4. **Переднее приложение — сам Tranq** — подсвечивать себя незачем, рамки быть не должно. Тест в задаче 1.
5. **Запись отменена по Esc или расшифровка не удалась** — таймер останавливается, панель гаснет, фоновой работы не остаётся. Тест в задаче 3.

---

### Task 1: Геометрия и правило показа

**Files:**
- Create: `Tranq/WindowHighlightGeometry.swift`
- Test: `TranqTests/WindowHighlightTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `enum WindowHighlightGeometry` со статическими членами:
    - `static let lineWidth: CGFloat` = 2
    - `static let cornerRadius: CGFloat` = 10
    - `static let glowOutset: CGFloat` = 26
    - `static func screenRect(axOrigin: CGPoint, axSize: CGSize, primaryHeight: CGFloat) -> CGRect` — пересчёт из координат Accessibility в координаты экрана AppKit.
    - `static func panelRect(for windowRect: CGRect) -> CGRect` — прямоугольник окна, расширенный на `glowOutset` в каждую сторону.
  - `enum WindowHighlightPolicy` со статическим `shouldShow(enabled: Bool, axTrusted: Bool, isOwnApp: Bool, windowRect: CGRect?) -> Bool`.

- [ ] **Step 1: Написать падающий тест**

```swift
import Testing
import Foundation
@testable import Tranq

struct WindowHighlightGeometryTests {
    /// Главный экран высотой 1000: окно в 100 пунктах от верхнего края AX
    /// начинается в 700 пунктах от нижнего края AppKit.
    @Test func convertsAccessibilityOriginToScreenOrigin() {
        let rect = WindowHighlightGeometry.screenRect(
            axOrigin: CGPoint(x: 50, y: 100),
            axSize: CGSize(width: 400, height: 200),
            primaryHeight: 1000
        )
        #expect(rect == CGRect(x: 50, y: 700, width: 400, height: 200))
    }

    /// Review Focus 2: монитор над главным даёт отрицательный y в координатах AX.
    @Test func handlesDisplayAbovePrimary() {
        let rect = WindowHighlightGeometry.screenRect(
            axOrigin: CGPoint(x: 0, y: -500),
            axSize: CGSize(width: 300, height: 300),
            primaryHeight: 1000
        )
        #expect(rect == CGRect(x: 0, y: 1200, width: 300, height: 300))
    }

    /// Review Focus 2: монитор левее главного даёт отрицательный x, он сохраняется как есть.
    @Test func handlesDisplayLeftOfPrimary() {
        let rect = WindowHighlightGeometry.screenRect(
            axOrigin: CGPoint(x: -1200, y: 0),
            axSize: CGSize(width: 600, height: 400),
            primaryHeight: 1000
        )
        #expect(rect == CGRect(x: -1200, y: 600, width: 600, height: 400))
    }

    @Test func panelIsOutsetOnEverySide() {
        let panel = WindowHighlightGeometry.panelRect(for: CGRect(x: 100, y: 100, width: 400, height: 200))
        let outset = WindowHighlightGeometry.glowOutset
        #expect(panel == CGRect(x: 100 - outset, y: 100 - outset,
                                width: 400 + outset * 2, height: 200 + outset * 2))
    }
}

struct WindowHighlightPolicyTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func showsForForeignWindow() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: false, windowRect: rect) == true)
    }

    @Test func hiddenWhenSettingOff() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: false, axTrusted: true, isOwnApp: false, windowRect: rect) == false)
    }

    /// Review Focus 1: без прав Accessibility рамки нет.
    @Test func hiddenWithoutAccessibility() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: false, isOwnApp: false, windowRect: rect) == false)
    }

    /// Review Focus 4: себя не подсвечиваем.
    @Test func hiddenForOwnApp() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: true, windowRect: rect) == false)
    }

    /// Review Focus 3: фокусное окно не определилось.
    @Test func hiddenWithoutWindow() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: false, windowRect: nil) == false)
    }

    @Test func hiddenForEmptyWindow() {
        #expect(WindowHighlightPolicy.shouldShow(enabled: true, axTrusted: true, isOwnApp: false, windowRect: .zero) == false)
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Выполнить: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests/WindowHighlightGeometryTests CODE_SIGN_IDENTITY=-`
Ожидаемо: сборка падает, `cannot find 'WindowHighlightGeometry' in scope`.

- [ ] **Step 3: Реализовать `WindowHighlightGeometry` и `WindowHighlightPolicy` в `Tranq/WindowHighlightGeometry.swift`**

Пустым считается прямоугольник с нулевой шириной или высотой. Файл добавить в цель `Tranq` в `Tranq.xcodeproj`.

- [ ] **Step 4: Прогнать тесты и убедиться, что они проходят**

Выполнить команду из шага 2.
Ожидаемо: PASS, 10 тестов.

- [ ] **Step 5: Коммит**

```bash
git add Tranq/WindowHighlightGeometry.swift TranqTests/WindowHighlightTests.swift Tranq.xcodeproj
git commit -m "feat: геометрия и правило показа подсветки окна"
```

---

### Task 2: Настройка «Подсветка окна»

**Files:**
- Modify: `Tranq/AppPreferences.swift`
- Modify: `Tranq/Settings/DictationSettingsSection.swift`
- Modify: `Tranq/Localizable.xcstrings`
- Test: `TranqTests/WindowHighlightTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces: `AppPreferences.shared.windowHighlightEnabled: Bool`, ключ `UserDefaults` — `windowHighlightEnabled`, по умолчанию `true`.

- [ ] **Step 1: Написать падающий тест**

Добавить в `TranqTests/WindowHighlightTests.swift`:

```swift
struct WindowHighlightPreferenceTests {
    @Test func defaultsToOnWhenNothingStored() {
        let d = UserDefaults(suiteName: "tranq-highlight-\(UUID().uuidString)")!
        #expect(AppPreferences.windowHighlightEnabled(in: d) == true)
    }

    @Test func storedValueWins() {
        let d = UserDefaults(suiteName: "tranq-highlight-\(UUID().uuidString)")!
        d.set(false, forKey: "windowHighlightEnabled")
        #expect(AppPreferences.windowHighlightEnabled(in: d) == false)
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Выполнить: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests/WindowHighlightPreferenceTests CODE_SIGN_IDENTITY=-`
Ожидаемо: сборка падает, у `AppPreferences` нет члена `windowHighlightEnabled(in:)`.

- [ ] **Step 3: Добавить настройку в `Tranq/AppPreferences.swift`**

Статический `static func windowHighlightEnabled(in defaults: UserDefaults) -> Bool` читает ключ `windowHighlightEnabled` и возвращает `true`, если значения нет. Опубликованное свойство `@Published var windowHighlightEnabled: Bool` инициализируется через него от `AppEnvironment.defaults` и в `didSet` пишет значение обратно — ровно как соседние `soundEnabled` и `autoPasteEnabled`.

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Выполнить команду из шага 2.
Ожидаемо: PASS, 2 теста.

- [ ] **Step 5: Добавить переключатель в раздел «Диктовка»**

В `Tranq/Settings/DictationSettingsSection.swift` после блока «Звуки» добавить `Divider().background(Color.uiHairline)` и строку по образцу блока «Звуки»: заголовок `Text("Подсветка окна")`, подпись `Text("Рамка вокруг окна диктовки")`, `Toggle("", isOn: $preferences.windowHighlightEnabled)` с `.labelsHidden()` и `.toggleStyle(SwitchToggleStyle(tint: Color.uiSuccess))`.

- [ ] **Step 6: Добавить строки в каталог локализации**

В `Tranq/Localizable.xcstrings` добавить два ключа в формате Xcode, по образцу ключа `Звуки`, с локализациями `en` и `ru` в состоянии `translated`:

| Ключ | ru | en |
| --- | --- | --- |
| `Подсветка окна` | Подсветка окна | Window highlight |
| `Рамка вокруг окна диктовки` | Рамка вокруг окна диктовки | Frame around the dictation window |

Файл править только инструментом, сохраняющим формат Xcode: порядок ключей, отступы и экранирование должны остаться прежними.

- [ ] **Step 7: Собрать проект и проверить формат каталога**

Выполнить: `xcodebuild build -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Выполнить: `git diff --stat Tranq/Localizable.xcstrings`
Ожидаемо: сборка успешна, в каталоге изменены только добавленные строки, перестановки остального файла нет.

- [ ] **Step 8: Коммит**

```bash
git add Tranq/AppPreferences.swift Tranq/Settings/DictationSettingsSection.swift Tranq/Localizable.xcstrings TranqTests/WindowHighlightTests.swift
git commit -m "feat: переключатель подсветки окна в разделе Диктовка"
```

---

### Task 3: Панель рамки

**Files:**
- Create: `Tranq/WindowHighlightPanel.swift`
- Test: `TranqTests/WindowHighlightTests.swift`

**Interfaces:**
- Consumes: `WindowHighlightGeometry`, `WindowHighlightPolicy` из задачи 1; `AppPreferences.shared.windowHighlightEnabled` из задачи 2.
- Produces:
  - `struct HighlightTarget: Equatable { let pid: pid_t; let windowRect: CGRect? }`
  - `final class WindowHighlightManager` с членами:
    - `static let shared: WindowHighlightManager`
    - `init(targetProvider: @escaping () -> HighlightTarget?)` — для тестов; `shared` создаётся с провайдером поверх Accessibility.
    - `private(set) var isTracking: Bool`
    - `private(set) var isPanelVisible: Bool`
    - `func start()`
    - `func stop()`
  - `struct WindowHighlightView: View` — сама рамка.

- [ ] **Step 1: Написать падающий тест**

Добавить в `TranqTests/WindowHighlightTests.swift`:

```swift
@MainActor
struct WindowHighlightManagerTests {
    /// Review Focus 3: цели нет — панель не показывается, хотя слежение идёт.
    @Test func doesNotShowPanelWithoutTarget() {
        let manager = WindowHighlightManager(targetProvider: { nil })
        manager.start()
        #expect(manager.isTracking == true)
        #expect(manager.isPanelVisible == false)
        manager.stop()
    }

    /// Review Focus 5: после остановки слежения не остаётся.
    @Test func stopEndsTracking() {
        let manager = WindowHighlightManager(targetProvider: { nil })
        manager.start()
        manager.stop()
        #expect(manager.isTracking == false)
        #expect(manager.isPanelVisible == false)
    }

    /// Review Focus 5: повторная остановка безопасна.
    @Test func stopIsIdempotent() {
        let manager = WindowHighlightManager(targetProvider: { nil })
        manager.stop()
        manager.stop()
        #expect(manager.isTracking == false)
    }

    /// Review Focus 3: цель без прямоугольника окна панель не показывает.
    @Test func doesNotShowPanelForTargetWithoutWindow() {
        let manager = WindowHighlightManager(targetProvider: { HighlightTarget(pid: 999, windowRect: nil) })
        manager.start()
        #expect(manager.isPanelVisible == false)
        manager.stop()
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Выполнить: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests/WindowHighlightManagerTests CODE_SIGN_IDENTITY=-`
Ожидаемо: сборка падает, `cannot find 'WindowHighlightManager' in scope`.

- [ ] **Step 3: Реализовать `WindowHighlightView` в `Tranq/WindowHighlightPanel.swift`**

`RoundedRectangle(cornerRadius: WindowHighlightGeometry.cornerRadius)` со штрихом цвета `#CBFF6E` толщиной `WindowHighlightGeometry.lineWidth`, вписанный с отступом `WindowHighlightGeometry.glowOutset`. Свечение — два `.shadow` того же семейства цветов наружу: ближний `#B6F040` радиусом 7 при непрозрачности 0,8, дальний `#9FE03A` радиусом 17 при непрозрачности 0,33. Дыхание — непрозрачность всей фигуры ходит между 1,0 и 0,62, анимация `.easeInOut(duration: 2.4).repeatForever(autoreverses: true)`, запускается в `.onAppear`.

- [ ] **Step 4: Реализовать `WindowHighlightManager` в том же файле**

Панель создаётся лениво при первом показе: `NSPanel` со стилем `[.borderless, .nonactivatingPanel]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, `level = .screenSaver`, `isFloatingPanel = true`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, содержимое — `NSHostingView(rootView: WindowHighlightView())`.

`start()` поднимает `isTracking`, подписывается на `NSWorkspace.shared.notificationCenter`, `didActivateApplicationNotification`, запускает `Timer` с интервалом `1.0 / 30.0` в `.common` и сразу делает один такт. `stop()` снимает подписку, гасит таймер, прячет панель с анимацией непрозрачности 0,2 с и обнуляет оба флага.

Такт: берёт цель у `targetProvider`, спрашивает `WindowHighlightPolicy.shouldShow(enabled:axTrusted:isOwnApp:windowRect:)`, где `enabled` — `AppPreferences.shared.windowHighlightEnabled`, `axTrusted` — `AXIsProcessTrusted()`, `isOwnApp` — совпадение `pid` цели с `ProcessInfo.processInfo.processIdentifier`. При `false` прячет панель, при `true` ставит её в `WindowHighlightGeometry.panelRect(for:)` через `setFrame(_:display:)` без анимации и показывает через `orderFrontRegardless()`. Плавная анимация только у появления и скрытия, 0,2 с.

- [ ] **Step 5: Реализовать провайдер цели поверх Accessibility**

Приватный `static func accessibilityTarget() -> HighlightTarget?` в том же файле: `NSWorkspace.shared.frontmostApplication` даёт `pid`; `AXUIElementCreateApplication(pid)` и `kAXFocusedWindowAttribute` дают окно; `kAXPositionAttribute` и `kAXSizeAttribute` читаются через `AXValueGetValue` в `CGPoint` и `CGSize`; результат пересчитывается `WindowHighlightGeometry.screenRect(axOrigin:axSize:primaryHeight:)`, где `primaryHeight` — высота `NSScreen.screens.first?.frame.height`. Любая неудача даёт `windowRect: nil`, без записи в журнал: такт повторяется 30 раз в секунду. `shared` создаётся с этим провайдером. Файл добавить в цель `Tranq` в `Tranq.xcodeproj`.

- [ ] **Step 6: Прогнать тесты и убедиться, что они проходят**

Выполнить команду из шага 2.
Ожидаемо: PASS, 4 теста.

- [ ] **Step 7: Коммит**

```bash
git add Tranq/WindowHighlightPanel.swift TranqTests/WindowHighlightTests.swift Tranq.xcodeproj
git commit -m "feat: панель подсветки окна диктовки"
```

---

### Task 4: Подключение к циклу записи

**Files:**
- Modify: `Tranq/AudioCapture.swift:94` (старт записи), `Tranq/AudioCapture.swift:171-184` (отмена), `Tranq/AudioCapture.swift:195-217` (неудачная расшифровка), `Tranq/AudioCapture.swift:240-272` (вставка)
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: `WindowHighlightManager.shared.start()` и `.stop()` из задачи 3.
- Produces: ничего.

- [ ] **Step 1: Включить рамку в начале записи**

В `startRecording`, сразу после `OverlayPanelManager.shared.showOverlay()`, вызвать `WindowHighlightManager.shared.start()`.

- [ ] **Step 2: Погасить рамку на всех исходах**

Вызвать `WindowHighlightManager.shared.stop()` в четырёх местах:
- в `cancelRecording`, рядом с `OverlayPanelManager.shared.hideOverlay()`;
- в ветке `.failure` метода `handle(_:job:then:)`, перед `OverlayPanelManager.shared.showWarning(message:)`;
- в `insert(_:target:then:)` в ветке выключенной авто-вставки, перед `next()`;
- в `insert(_:target:then:)` внутри замыкания `InsertionService.shared.paste`, в блоке `DispatchQueue.main.async` перед `next()`, то есть на всех пяти исходах вставки сразу.

- [ ] **Step 3: Записать исключение из правила бренда**

В `AGENTS.md`, в разделе 2.1, заменить строку про отсутствие акцентного цвета на две: прежнее правило и одно исключение — рамка подсветки окна диктовки цвета `#CBFF6E` как семантический цвет состояния «идёт запись»; внутри окон Tranq этот цвет не используется.

- [ ] **Step 4: Прогнать весь набор тестов и проверку имени**

Выполнить: `bash scripts/check-brand.sh`
Выполнить: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests CODE_SIGN_IDENTITY=-`
Ожидаемо: «Старого имени нет.» и `** TEST SUCCEEDED **`.

- [ ] **Step 5: Проверить руками**

Собрать и запустить приложение. Проверить: Safari, Терминал, VS Code; переключение приложений во время записи; отмена по Esc; выключение переключателя в настройках гасит рамку; два монитора и полноэкранное окно, если они доступны. Записать найденное.

- [ ] **Step 6: Коммит**

```bash
git add Tranq/AudioCapture.swift AGENTS.md
git commit -m "feat: рамка подсветки на время диктовки"
```
