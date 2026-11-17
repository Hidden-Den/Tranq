# Упрощение истории и удаление лишнего — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Оставить в приложении только диктовку: убрать расшифровку файлов, Борд, ИИ-действия, промпты и заставку, упростить экран заметки и выпустить версию 2.3.0.

**Architecture:** Удаление идёт файлами: проект использует синхронизированные группы Xcode, поэтому удалённый из `Golosok/` файл уходит из сборки. Экран заметки выносится из `ContentView.swift` в `HistoryNoteView.swift`. Сырая расшифровка для «Сказано» хранится в самой заметке новым необязательным полем.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Swift Testing, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-11-17-dictation-focus-design.md`, разделы 9, 10, 12 пункты 8–9.

План 4 из 4. Планы 1–3 уже в ветке `feat/dictation-focus`.

## Global Constraints

- Ветка `feat/dictation-focus`; PR только по явной просьбе пользователя.
- Текст интерфейса без скобок, метки 1–2 слова, подписи короче 8 слов.
- Правки текста заметки по-прежнему идут через `HistoryStore.replaceNoteText` — на них учится словарь.
- Короткие звуки начала и конца записи остаются: `LuxurySoundSynth` не трогаем.
- `AIService` остаётся: им пользуется `VariantSuggester` словаря и проверка подключения.
- `MARKETING_VERSION = 2.3.0`. Тег и релиз — только по просьбе пользователя.
- Команда тестов `TEST`: `xcodebuild test -project Golosok.xcodeproj -scheme Golosok -destination 'platform=macOS' -only-testing:GolosokTests CODE_SIGN_IDENTITY=- 2>&1 | grep -E "error:|✘|\*\* TEST"`; успех — `** TEST SUCCEEDED **`.

## Review Focus

- **Старая история без нового поля.** `history.json` прошлых версий не содержит `spokenText`; заметки должны загрузиться, переключатель «Итог / Сказано» не показывается. Тест в задаче 4.
- **Заметка без аудио.** Ручная заметка или удалённый WAV — строка плеера не показывается, без падения.
- **Правка текста и переключение заметки.** Несохранённая правка записывается до смены заметки, вкладки или переключения на «Сказано».
- **«Сказано» совпадает с итогом.** Переключатель не показывается, чтобы не дублировать одно и то же.
- **Старые настройки Борда и промптов.** Ключи `UserDefaults` и файлы промптов остаются на диске, но ничего не читает их; приложение не падает.

---

### Task 1: Убрать расшифровку файлов

**Files:**
- Modify: `Golosok/TranscriptionPipeline.swift` — удалить `Source.mediaFile`, `isFileImport`, ветку конвертации.
- Modify: `Golosok/AudioCapture.swift` — удалить `importAndTranscribeFile`, `importFiles`, `processNextFile`, `isMediaURL`, `isProcessingFile`, `fileProcessingProgress` и ветки `isFileImport`.
- Modify: `Golosok/AudioPCM.swift` — удалить `convertMediaToWav` и запуск ffmpeg.
- Modify: `Golosok/GolosokApp.swift:94-99` — убрать пункт ⌘O.
- Modify: `Golosok/ContentView.swift` — убрать `onDrop`, `FileDropOverlay`, строку «Расшифровать файл» и подсказку о перетаскивании; подзаголовок пустого экрана: «Чистый текст голосом в любом приложении».
- Modify: `Golosok/OverlayPanel.swift` — убрать отображение прогресса файла, если оно завязано на удалённые свойства.
- Delete: `Golosok/SubtitleExporter.swift`; тесты `SubtitleExporter` в `GolosokTests/GolosokTests.swift`; тесты импорта в `GolosokTests/CorePipelineTests.swift`.
- Modify: `scripts/fetch-deps.sh` — убрать ffmpeg из списка и подсказки; `.gitignore` — строку `Golosok/ffmpeg`; удалить локальный `Golosok/ffmpeg`.

- [ ] **Step 1:** Удалить перечисленное. **Step 2:** `TEST`, ожидается `** TEST SUCCEEDED **`. **Step 3:** Коммит `refactor: remove media file transcription and export`.

### Task 2: Убрать Борд

**Files:**
- Delete: `Golosok/DashboardView.swift`, `Golosok/DashboardCharts.swift`.
- Modify: `Golosok/HistoryStore.swift:40`, `Golosok/AudioCapture.swift:47-49` — убрать `DashboardStatsStore`.
- Modify: `Golosok/ContentView.swift` — убрать `MainTab.dashboard`, кнопку «Борд», ветку `switch`.
- Modify: `Golosok.xcodeproj/project.pbxproj` — убрать висячие ссылки `C4F2FF4130168DD0006F9170` и `C4F2FF4030168DD0006F9170` на несуществующий корневой `DashboardView.swift`.

- [ ] **Step 1:** Удалить. **Step 2:** `TEST`. **Step 3:** Коммит `refactor: remove dashboard`.

### Task 3: Убрать ИИ-действия, промпты и заставку

**Files:**
- Delete: `Golosok/AIActionView.swift`, `Golosok/AISelectionToolbar.swift`, `Golosok/AIPromptTemplates.swift`, `Golosok/PromptManagerView.swift`, `Golosok/PromptStore.swift`, `Golosok/SplashView.swift`, `Golosok/StartupSoundSynth.swift`.
- Modify: `Golosok/ContentView.swift` — убрать меню «ИИ», `aiRequest`, `showPromptManager`, `showCreatePrompt`, `promptStore`, `NoteSelection`, `handleNoteSelectionChange`, `openSelectionAI`, вызовы `AISelectionToolbarPresenter`.

- [ ] **Step 1:** Удалить. **Step 2:** `TEST`. **Step 3:** Коммит `refactor: remove AI note actions, prompt manager and splash`.

### Task 4: Сырая расшифровка в заметке

**Files:**
- Modify: `Golosok/HistoryStore.swift` — поле `var spokenText: String?` в `TranscriptionItem`, сохранять в `withText`.
- Modify: `Golosok/AudioCapture.swift` `save(_:)` — заполнять `spokenText` из `output.rawText`.
- Test: `GolosokTests/HistoryNoteTests.swift`

**Interfaces:**
- Produces: `TranscriptionItem.spokenText: String?`; `extension TranscriptionItem { var showsSpokenToggle: Bool }` — истина, когда `spokenText` не пуст и после обрезки пробелов отличается от `text`.

- [ ] **Step 1: Тесты**

```swift
@Test func legacyItemDecodesWithoutSpokenText() throws {
    let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"17.11.2026, 12:59","text":"БТИ","duration":"2 сек"}]"#
    let items = try JSONDecoder().decode([TranscriptionItem].self, from: Data(json.utf8))
    #expect(items[0].spokenText == nil); #expect(items[0].showsSpokenToggle == false)
}
@Test func spokenToggleOnlyWhenDifferent() {
    var item = TranscriptionItem(date: "d", text: "Давай перенесём встречу", duration: "1 сек")
    item.spokenText = "ну давай перенесём встречу"
    #expect(item.showsSpokenToggle)
    item.spokenText = " Давай перенесём встречу "
    #expect(item.showsSpokenToggle == false)
}
@Test func editKeepsSpokenText() {
    var item = TranscriptionItem(date: "d", text: "a", duration: "1 сек"); item.spokenText = "ну a"
    #expect(item.withText("b").spokenText == "ну a")
}
```

- [ ] **Step 2:** `TEST`, падает компиляция. **Step 3:** Реализовать. **Step 4:** `TEST` проходит. **Step 5:** Коммит `feat(history): keep spoken text with each note`.

### Task 5: Новый экран заметки

**Files:**
- Create: `Golosok/HistoryNoteView.swift` — экран выбранной заметки и пустой экран.
- Modify: `Golosok/ContentView.swift` — `historyDetailView` заменяется на `HistoryNoteView`; удалить `NativeTextView`, `SyncedPlayerView`, `SyncedTextView`, `TranscriptSearch`, `MetadataPill`, `EditToggleButton`, поиск по заметке, кнопку «+» и `createNote`, обработчики `ToggleTranscriptSearch`, `FindNextInTranscript`, `FindPreviousInTranscript`.
- Modify: `Golosok/GolosokApp.swift:108-124` — убрать пункты ⌘F, ⌘G, ⇧⌘G.
- Modify: `Golosok/PlaybackController.swift` — опубликовать длительность загруженного аудио для строки плеера, если её нет.

**Interfaces:**
- Consumes: `TranscriptionItem.spokenText`, `showsSpokenToggle` из задачи 4; `HistoryStore.replaceNoteText`; `PlaybackController.toggleSyncedPlayback`, `seekSynced`, `playheadTime`.
- Produces: `struct HistoryNoteView: View { let item: TranscriptionItem?; let onDelete: (UUID) -> Void }`.

Раскладка, сверху вниз:
1. Строка: дата крупно; время и длительность серым одним текстом «12:59 · 21 сек»; справа переключатель «Итог / Сказано» если `showsSpokenToggle`; кнопка «Скопировать»; меню «⋯» с пунктами «Вставить ещё раз» и «Удалить».
2. Текст: в режиме «Итог» — сразу редактируемый `EditableTextView`, сохранение с задержкой 0,4 с и при уходе с заметки; в режиме «Сказано» — тот же вид только для чтения со `spokenText`.
3. Строка плеера, только если есть WAV: кнопка воспроизведения, `UISeekSlider`, время «0:21».

«Вставить ещё раз»: `NSApp.hide(nil)`, через 0,3 с `InsertionService.shared.paste(text:target: nil, autoPasteEnabled: true)` — текст уходит в приложение, которое стало активным. «Скопировать» копирует текст текущего режима. «Удалить» — через существующее подтверждение «Удалить запись?».

- [ ] **Step 1:** Реализовать экран и удалить старые компоненты. **Step 2:** `TEST`. **Step 3:** Собрать и запустить приложение; проверить заметку с аудио, без аудио, с «Сказано», правку с переключением заметки, удаление, «Вставить ещё раз». **Step 4:** Коммит `feat(history): one-row note screen with inline editing`.

### Task 6: Документация и версия

**Files:**
- Modify: `README_RU.md`, `README.md` — описание диктовки: уровни очистки, правила приложений, режим промпта, три способа обработки, корпоративный шлюз; убрать расшифровку файлов, субтитры, справочник «сотни терминов» оставить коротко, размер DMG пересчитать по `build/Golosok.dmg` после сборки или убрать цифру.
- Modify: `docs/VOICE_INTELLIGENCE_PLAN.md` — первой строкой пометка «Устарело: актуальные решения в спеке 2026-11-17».
- Modify: `Golosok.xcodeproj/project.pbxproj` — `MARKETING_VERSION = 2.3.0` в обеих конфигурациях.

- [ ] **Step 1:** Правки. **Step 2:** `TEST` и `xcodebuild build`. **Step 3:** Коммит `chore: docs for dictation focus, bump version to 2.3.0`.
