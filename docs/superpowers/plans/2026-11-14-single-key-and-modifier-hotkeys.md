# Single Key & Modifier Hotkeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable single modifier keys (Fn / Globe, Right Option, Right Command, etc.) as dictation triggers alongside existing key combinations, supporting both Push-to-Talk (walkie-talkie) and Toggle modes.

**Architecture:** A hybrid hotkey engine in `NativeHotKeyManager`: standard key combinations use Carbon's `RegisterEventHotKey`, while single modifier keys use a Quartz `CGEventTap` listening to `flagsChanged` events by hardware `keyCode`. `HotKeySettings` handles interactive capture of both modifier and standard key events, and `SettingsView` surfaces preset buttons and live badges under a minimalist Notion/Linear aesthetic.

**Tech Stack:** Swift 5.9+, AppKit (`NSEvent`), CoreGraphics (`CGEventTap`, `CGEventFlags`), Carbon (`RegisterEventHotKey`), SwiftUI, Swift Testing.

**Spec:** [docs/superpowers/specs/2026-11-14-fn-key-hotkey-support-design.md](docs/superpowers/specs/2026-11-14-fn-key-hotkey-support-design.md)

## Global Constraints

- Never use parentheses in UI labels or badges (Minimal App Design rule).
- Preserve 100% backward compatibility for users with `⌥ + Space` (default).
- All changes must compile cleanly under macOS 13.5+ with zero duplicate compile targets.
- All unit tests in `GolosokTests` must pass with `xcodebuild test`.

## Review Focus

- Rapid tapping of `Fn` or modifier key: must not crash or leak event tap resources.
- `CGEventTap` disabled/timeout by macOS: must handle `kCGEventTapDisabledByTimeout` and re-enable cleanly.
- System action conflict: when `Fn` is the trigger, events must be swallowed during dictation so macOS doesn't open the emoji viewer or switch keyboard layouts.
- Left vs Right modifier distinction: pressing Left Option must not trigger dictation when Right Option is selected.
- Switching between Carbon combination and single modifier at runtime: old listener must be cleanly unregistered before registering the new one.

---

### Task 1: Core Key & Modifier Abstractions (`SingleModifierKey` and `HotKeyTrigger`)

**Files:**
- Create: `Golosok/HotKeyTrigger.swift`
- Test: `GolosokTests/HotKeyTriggerTests.swift`

**Interfaces:**
- Produces:
  - `enum SingleModifierKey: UInt32, CaseIterable, Codable, Sendable`
    - `case fn = 63`
    - `case rightOption = 61`
    - `case leftOption = 58`
    - `case rightCommand = 54`
    - `case leftCommand = 55`
    - `case rightControl = 62`
    - `case leftControl = 59`
    - `case rightShift = 60`
    - `case leftShift = 56`
    - `case capsLock = 57`
    - `var displayName: String { get }`
    - `static func from(keyCode: UInt32) -> SingleModifierKey?`
    - `func isPressed(flags: CGEventFlags) -> Bool`
  - `enum HotKeyTrigger: Equatable, Codable, Sendable`
    - `case combination(keyCode: UInt32, modifiers: UInt32)`
    - `case singleModifier(SingleModifierKey)`
    - `var displayName: String { get }`

- [ ] **Step 1: Write the failing test**

```swift
// GolosokTests/HotKeyTriggerTests.swift
import Testing
import CoreGraphics
@testable import Golosok

struct HotKeyTriggerTests {
    @Test func singleModifierKeyCodeMapping() {
        #expect(SingleModifierKey.from(keyCode: 63) == .fn)
        #expect(SingleModifierKey.from(keyCode: 61) == .rightOption)
        #expect(SingleModifierKey.from(keyCode: 58) == .leftOption)
        #expect(SingleModifierKey.from(keyCode: 54) == .rightCommand)
        #expect(SingleModifierKey.from(keyCode: 55) == .leftCommand)
        #expect(SingleModifierKey.from(keyCode: 999) == nil)
    }

    @Test func singleModifierDisplayNames() {
        #expect(SingleModifierKey.fn.displayName == "Fn")
        #expect(SingleModifierKey.rightOption.displayName == "Правый ⌥")
        #expect(SingleModifierKey.leftOption.displayName == "Левый ⌥")
    }

    @Test func hotKeyTriggerDisplayName() {
        let fnTrigger = HotKeyTrigger.singleModifier(.fn)
        #expect(fnTrigger.displayName == "Fn")
        let comboTrigger = HotKeyTrigger.combination(keyCode: 49, modifiers: 2048) // Option + Space
        #expect(comboTrigger.displayName.contains("Space"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/HotKeyTriggerTests`
Expected: FAIL with "cannot find type 'SingleModifierKey' in scope"

- [ ] **Step 3: Implement `SingleModifierKey` and `HotKeyTrigger` in `Golosok/HotKeyTrigger.swift`**

Implement the enums, `from(keyCode:)`, `displayName`, and `isPressed(flags:)` using bitmask checks against `CGEventFlags`.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/HotKeyTriggerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Golosok/HotKeyTrigger.swift GolosokTests/HotKeyTriggerTests.swift
git commit -m "feat: add SingleModifierKey and HotKeyTrigger models"
```

---

### Task 2: Event Tap & Hybrid Dispatcher in `NativeHotKeyManager`

**Files:**
- Modify: `Golosok/NativeHotKeyManager.swift`
- Test: `GolosokTests/HotKeyTriggerTests.swift`

**Interfaces:**
- Consumes: `SingleModifierKey`, `HotKeyTrigger` from Task 1
- Produces:
  - `NativeHotKeyManager.shared.trigger: HotKeyTrigger` (getter and setter, persisted to UserDefaults)
  - `NativeHotKeyManager.shared.setTrigger(_ trigger: HotKeyTrigger)`
  - Active `CFMachPort?` event tap listening to `flagsChanged` when a `singleModifier` trigger is set.

- [ ] **Step 1: Write the failing test for trigger persistence and switching**

```swift
// in GolosokTests/HotKeyTriggerTests.swift
@Test func nativeHotKeyManagerTriggerPersistence() {
    let manager = NativeHotKeyManager.shared
    let original = manager.trigger
    defer { manager.trigger = original }

    manager.trigger = .singleModifier(.fn)
    #expect(manager.trigger == .singleModifier(.fn))
    #expect(manager.displayName() == "Fn")

    manager.trigger = .singleModifier(.rightOption)
    #expect(manager.trigger == .singleModifier(.rightOption))
    #expect(manager.displayName() == "Правый ⌥")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/HotKeyTriggerTests/nativeHotKeyManagerTriggerPersistence`
Expected: FAIL with "value of type 'NativeHotKeyManager' has no member 'trigger'"

- [ ] **Step 3: Implement CGEventTap and hybrid registration in `Golosok/NativeHotKeyManager.swift`**

1. Add `trigger` computed property backed by `UserDefaults` (storing `hotkey.type`: `"combo"` vs `"modifier"`, and the associated values).
2. Implement `setupEventTap()` using `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue, callback: ..., userInfo: ...)`:
   - Match `keyCode == activeModifier.rawValue`.
   - Track key-down vs key-up using `activeModifier.isPressed(flags:)`.
   - On key-down: call `onHotKeyPressed?()`.
   - On key-up: in `pushToTalk` mode call `onHotKeyReleased?()`.
   - For `Fn` (`keyCode == 63`): return `nil` to suppress system Emoji/Input switcher popup.
   - For `kCGEventTapDisabledByTimeout`: call `CGEventTapEnable(tap, true)`.
3. In `register()`:
   - If `trigger` is `.singleModifier`, tear down Carbon and start `CGEventTap`.
   - If `trigger` is `.combination`, tear down `CGEventTap` and register Carbon `RegisterEventHotKey`.
4. Ensure clean teardown in `unregister()` and `deinit`.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/HotKeyTriggerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Golosok/NativeHotKeyManager.swift GolosokTests/HotKeyTriggerTests.swift
git commit -m "feat: implement CGEventTap and hybrid registration in NativeHotKeyManager"
```

---

### Task 3: Interactive Capture & Presets in `HotKeySettings`

**Files:**
- Modify: `Golosok/HotKeySettings.swift`
- Test: `GolosokTests/HotKeyTriggerTests.swift`

**Interfaces:**
- Consumes: `NativeHotKeyManager.shared.trigger` from Task 2
- Produces:
  - `HotKeySettings.shared.setPreset(_ trigger: HotKeyTrigger)`
  - `HotKeySettings.shared.beginCapture()` capturing both `.keyDown` and `.flagsChanged`
  - `HotKeySettings.shared.trigger: HotKeyTrigger`

- [ ] **Step 1: Write the failing test for presets in `HotKeySettings`**

```swift
// in GolosokTests/HotKeyTriggerTests.swift
@Test func hotKeySettingsPresets() {
    let settings = HotKeySettings.shared
    settings.setPreset(.singleModifier(.fn))
    #expect(settings.hotKeyName == "Fn")

    settings.setPreset(.singleModifier(.rightOption))
    #expect(settings.hotKeyName == "Правый ⌥")

    settings.reset()
    #expect(settings.hotKeyName.contains("Space"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/HotKeyTriggerTests/hotKeySettingsPresets`
Expected: FAIL with "value of type 'HotKeySettings' has no member 'setPreset'"

- [ ] **Step 3: Implement updated capture and presets in `Golosok/HotKeySettings.swift`**

1. Add `setPreset(_ trigger: HotKeyTrigger)`:
   - Updates `NativeHotKeyManager.shared.trigger = trigger`.
   - Calls `refreshName()`.
2. Expand `beginCapture()`:
   - Listen to `[.keyDown, .flagsChanged]` using `NSEvent.addLocalMonitorForEvents`.
   - If `.flagsChanged`: inspect `event.keyCode`. If it corresponds to a valid `SingleModifierKey` and the flag is set (key pressed down), set trigger to `.singleModifier(key)`, refresh name, and call `endCapture()`.
   - If `.keyDown`: existing combination capture logic (with Esc key 53 canceling capture).

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests/HotKeyTriggerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Golosok/HotKeySettings.swift GolosokTests/HotKeyTriggerTests.swift
git commit -m "feat: add single modifier capture and presets to HotKeySettings"
```

---

### Task 4: UI Updates in `SettingsView`

**Files:**
- Modify: `Golosok/SettingsView.swift`
- Modify: `Golosok/Localizable.xcstrings`

**Interfaces:**
- Consumes: `HotKeySettings.shared` from Task 3
- Produces: Minimalist controls in `SettingsView`:
  - Quick preset pills: `Fn`, `Правый ⌥`, `⌥ + Space`
  - Interactive "Изменить" button with active capture state
  - Mode dropdown: `Переключатель`, `Рация` (strictly without parentheses)

- [ ] **Step 1: Write test or verify existing view compilation and strings**

Verify `Localizable.xcstrings` contains keys for `"HotKey.Preset.Fn"`, `"HotKey.Preset.RightOption"`, `"HotKey.Preset.Default"`, `"HotKey.ModeToggle"`, `"HotKey.ModePushToTalk"`.

- [ ] **Step 2: Update `SettingsView.swift`**

1. Replace rigid HotKey row with clean preset selector:
   - Display current key badge (`hotKey.hotKeyName`).
   - Quick preset buttons (`Fn`, `Правый ⌥`, `⌥ + Space`) for 1-click assignment.
   - Outline button `Изменить` (or `Отмена` during capture).
2. Clean up labels: remove all parentheses per `minimal-app-design` rules.

- [ ] **Step 3: Run full test suite and verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests`
Expected: PASS (all tests pass)

- [ ] **Step 4: Commit**

```bash
git add Golosok/SettingsView.swift Golosok/Localizable.xcstrings
git commit -m "feat: update SettingsView with single key presets and minimal controls"
```
