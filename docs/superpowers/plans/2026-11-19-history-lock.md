# Замок истории Tranq 3.5: план работ

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Панель истории открывается только после Touch ID, а записи, голос и сырые расшифровки до разлочки лежат на диске шифротекстом.

**Architecture:** Асимметричная схема: долгий ключ согласования под защитой Secure Enclave или Связки ключей с условием `userPresence`, публичный ключ открыто. Запись новой заметки идёт эфемерной парой и не требует подтверждения, чтение — только после разлочки. Единый `history.json` разъезжается на конверт-файл на заметку, поэтому запись при запертой истории не перезаписывает общий массив.

**Tech Stack:** Swift, SwiftUI, CryptoKit, LocalAuthentication, Security, AVFoundation, swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-19-history-lock-design.md`

## Global Constraints

- `MACOSX_DEPLOYMENT_TARGET = 13.5`, приложение без песочницы, hardened runtime.
- Secure Enclave есть не на всех поддерживаемых машинах: обязателен путь на `Curve25519.KeyAgreement` с ключом в Связке ключей, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` плюс `userPresence`.
- Подтверждение личности — `LAPolicy.deviceOwnerAuthentication`, то есть Touch ID с паролем Mac как запасным путём.
- Тесты не касаются настоящей Связки ключей и не вызывают `LocalAuthentication`: ключ и подтверждение — только через протоколы из задачи 1.
- Текст интерфейса — через `String(localized:)` и `Localizable.xcstrings`. Файл правится дампером в стиле Xcode, не `json.dump`.
- Правила интерфейса проекта: без круглых скобок в пользовательском тексте, метки 1–2 слова, подзаголовки короче 8 слов, шрифт через `Font.ui`, акцентных цветов нет.
- Все новые пути данных живут под `AppEnvironment.dataDirectory`, чтобы тесты шли во временной папке.
- Релиз `3.5.0`: `MARKETING_VERSION = 3.5` в `Tranq.xcodeproj/project.pbxproj`, тег `v3.5.0`.
- Тесты: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' -only-testing:TranqTests/<Suite> CODE_SIGN_IDENTITY=-`, из корня проекта, с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Ветка `feat/history-lock`. PR только по прямой просьбе пользователя.

## Review Focus

Пять случаев, которые спека подразумевает, но ни один шаг сам по себе не проверяет. Тест на каждый добавлен в задачу, которой принадлежит код.

1. Повреждённый или обрезанный конверт на диске: заметка пропускается, остальные читаются, файл не удаляется молча. Задача 2.
2. Диктовка во время разлочки и в момент запирания: запись не теряется и не уходит в открытый файл. Задача 3.
3. Включённый замок, но в `Notes/` пусто, а `history.json` остался от сбоя миграции: открытый файл читается и не затирается. Задача 9.
4. Отказ или отмена подтверждения личности, в том числе трижды подряд: остаётся `заперто`, а не `ключ недоступен`. Задача 6.
5. Заметка с аудио на десятки мегабайт: воспроизведение из памяти не падает и не держит расшифрованные байты после запирания. Задача 4.

---

## Структура файлов

Создаются:

- `Tranq/Privacy/HistoryCrypto.swift` — конверт: формат, `seal`, `open`, назначения HKDF.
- `Tranq/Privacy/HistoryKeys.swift` — протокол доступа к ключу, реализации на Secure Enclave и на Связке ключей.
- `Tranq/Privacy/PresenceGate.swift` — протокол подтверждения личности, реализация на `LocalAuthentication`.
- `Tranq/Privacy/HistoryVault.swift` — файлы конвертов: заметки, аудио, тайминги.
- `Tranq/Privacy/HistoryLock.swift` — состояния замка, разлочка, правила повторного запирания.
- `Tranq/Privacy/HistoryMigration.swift` — включение и выключение замка, выгрузка копии.
- `Tranq/HistoryLockedView.swift` — заглушка запертой истории и экран недоступного ключа.

Правятся:

- `Tranq/HistoryStore.swift` — хранение на файл на заметку, состояния замка.
- `Tranq/PlaybackController.swift` — воспроизведение из памяти.
- `Tranq/TranscriptJournal.swift` — строки журнала конвертами.
- `Tranq/ContentView.swift` — вкладка истории, боковой список, поиск, авто-открытие.
- `Tranq/Settings/DataSettingsSection.swift` — переключатель, предупреждение, выгрузка.
- `Tranq/AppPreferences.swift` — флаг включённого замка.
- `Tranq/MCP/MCPAccess.swift`, `Tranq/MCP/MCPDoor.swift` — отказ при запертой истории.
- `Tranq/AppLogger.swift` — не писать текст расшифровок при включённом замке.
- `Tranq/AudioPCM.swift` — права на временные файлы.
- `Tranq/DataEraser.swift` — стирание конвертов и ключа.
- `Tranq/Localizable.xcstrings`, `README_RU.md`, `README.md`, `Tranq.xcodeproj/project.pbxproj`.

---

### Task 1: Конверт и доступ к ключу

**Files:**
- Create: `Tranq/Privacy/HistoryCrypto.swift`, `Tranq/Privacy/HistoryKeys.swift`, `Tranq/Privacy/PresenceGate.swift`
- Test: `TranqTests/Privacy/HistoryCryptoTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `enum HistoryCryptoPurpose: String { case note, audio, timings, journal }`
  - `struct SealedEnvelope: Codable { let version: Int; let ephemeralPublicKey: Data; let nonce: Data; let ciphertext: Data }`
  - `protocol HistoryKeyProviding { var publicKey: Data { get throws }; func agree(withEphemeral: Data) throws -> SymmetricKey; func create() throws; func destroy() throws; var exists: Bool { get } }`
  - `enum HistoryKeyError: Error { case unavailable, denied }` — `denied` отдаётся, когда человек отказал или отменил подтверждение; `unavailable`, когда ключа нет или он не читается на этой машине.
  - `enum HistoryCrypto { static func seal(_ data: Data, purpose: HistoryCryptoPurpose, publicKey: Data) throws -> SealedEnvelope; static func open(_ envelope: SealedEnvelope, purpose: HistoryCryptoPurpose, key: HistoryKeyProviding) throws -> Data }`
  - `protocol PresenceAuthorizing { func authorize(reason: String) async throws }`
  - `struct SecureEnclaveHistoryKey: HistoryKeyProviding`, `struct KeychainHistoryKey: HistoryKeyProviding`, `struct LocalAuthPresenceGate: PresenceAuthorizing`
  - `enum HistoryKeyFactory { static func make() -> HistoryKeyProviding }` — Secure Enclave, где он есть, иначе Связка ключей.

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryCryptoTests {
    @Test func sealedDataOpensBack()
    @Test func envelopeFromAnotherPurposeDoesNotOpen()
    @Test func flippedByteFailsToOpen()        // ошибка, не мусор
    @Test func twoSealsOfSameDataDiffer()      // эфемерная пара каждый раз новая
}
```

Подставной ключ `TestHistoryKey: HistoryKeyProviding` на `Curve25519` в памяти живёт в `TranqTests/Privacy/TestHistoryKey.swift` и используется всеми задачами плана.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:TranqTests/HistoryCryptoTests`
Expected: FAIL, типы не найдены.

- [ ] **Step 3: Implement**

Схема: эфемерная пара той же кривой, что долгий ключ, `sharedSecretFromKeyAgreement`, `hkdfDerivedSymmetricKey` с `SHA256`, фиксированной солью `"tranq.history.v1"` и `sharedInfo` из `purpose.rawValue`, `AES.GCM` с 256-битным ключом. `version = 1`. Релизы подписаны ad-hoc, и защищённая связка отвечает ошибкой -34018, поэтому ключ Secure Enclave лежит файлом `history-key.se` с правами `0o600` рядом с открытым `history-key.pub`, с флагами `privateKeyUsage` и `userPresence`. Без Secure Enclave запасной путь: байты Curve25519 в обычной связке входа под сервисом `nuter.Tranq.historyKey` и программная проверка Touch ID через общий `LAContext`. Запасной путь слабее, и в релизных заметках это сказано.

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Tranq/Privacy TranqTests/Privacy && git commit -m "feat: конверт и ключ истории"
```

---

### Task 2: Хранилище конвертов

**Files:**
- Create: `Tranq/Privacy/HistoryVault.swift`
- Test: `TranqTests/Privacy/HistoryVaultTests.swift`

**Interfaces:**
- Consumes: всё из задачи 1.
- Produces:
  - `final class HistoryVault { init(directory: URL, key: HistoryKeyProviding) }`
  - `func writeNote(_ item: TranscriptionItem) throws` — конверт в `Notes/<id>.note`, подтверждения не требует.
  - `func readNotes() throws -> [TranscriptionItem]` — порядок по дате заметки, новые первыми.
  - `func deleteNote(id: UUID)`, `func noteFileCount() -> Int`
  - `func writeBlob(_ data: Data, id: UUID, purpose: HistoryCryptoPurpose) throws`, `func readBlob(id: UUID, purpose: HistoryCryptoPurpose) throws -> Data?`, `func deleteBlobs(id: UUID)`
  - `var corruptedNoteFiles: [URL]` — что не прочиталось на последнем чтении.

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryVaultTests {
    @Test func writtenNoteReadsBack()
    @Test func notesComeNewestFirst()
    @Test func corruptedFileIsSkippedAndKept()   // Review Focus 1: остальные читаются, файл на диске остался
    @Test func audioBlobRoundTrips()
    @Test func deleteRemovesNoteAndItsBlobs()
    @Test func plainTextOfNoteIsNotOnDisk()      // байты заметки не ищутся в файле
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement `HistoryVault`**

Имена файлов: `Notes/<uuid>.note`, `Audio/<uuid>.wav.sealed`, `Audio/<uuid>.segments.sealed`. Конверт на диске — JSON `SealedEnvelope`, запись атомарная.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 3: `HistoryStore` и состояния замка

**Files:**
- Modify: `Tranq/HistoryStore.swift`
- Test: `TranqTests/Privacy/HistoryStoreLockTests.swift`

**Interfaces:**
- Consumes: `HistoryVault`, `TestHistoryKey`.
- Produces:
  - `enum HistoryLockState: Equatable { case off, locked, unlocked, keyUnavailable }`
  - `HistoryStore.lockState: HistoryLockState` — `@Published`, только чтение извне.
  - `func applyLockState(_ state: HistoryLockState)` — переход: на `unlocked` читает конверты в `items`, на `locked` и `keyUnavailable` очищает `items`.
  - `init(directory: URL, saveDelay: TimeInterval = 0.5, vault: HistoryVault? = nil, lockState: HistoryLockState = .off)`

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryStoreLockTests {
    @Test func addNoteWhileLockedWritesEnvelopeAndKeepsItemsEmpty()
    @Test func unlockReadsNotesWrittenWhileLocked()
    @Test func lockingClearsItemsAndWritesNothingToPlainFile()   // Review Focus 2
    @Test func noteAddedDuringUnlockSurvivesImmediateLock()      // Review Focus 2
    @Test func editingNoteWhileUnlockedRewritesOnlyItsFile()
    @Test func lockOffBehavesLikeBefore()                        // history.json как сегодня
    @Test func notesWrittenWhileLockedArriveUnread()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

При `off` — сегодняшний путь с `history.json`. При остальных состояниях отложенная перезапись массива не планируется никогда, каждая правка пишет файл своей заметки, удаление — `vault.deleteNote`. `clearAll` удаляет и конверты.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 4: Аудио и тайминги

**Files:**
- Modify: `Tranq/HistoryStore.swift`, `Tranq/PlaybackController.swift`
- Test: `TranqTests/Privacy/HistoryAudioTests.swift`

**Interfaces:**
- Consumes: `HistoryVault`, `HistoryStore.lockState`.
- Produces:
  - `HistoryStore.audioData(for id: UUID) throws -> Data?` — расшифрованные байты при замке, чтение файла при `off`.
  - `HistoryStore.storeAudio(for:from:move:)` — при включённом замке кладёт конверт и удаляет исходник.
  - `PlaybackController` строит `AVAudioPlayer(data:)`.

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryAudioTests {
    @Test func storedAudioReadsBackByteEqual()
    @Test func plainWavIsRemovedAfterSealing()
    @Test func audioUnavailableWhileLocked()
    @Test func largeAudioRoundTrips()        // Review Focus 5: ~30 МБ, байты совпали
    @Test func lockingDropsCachedAudio()     // Review Focus 5: расшифрованного в памяти не осталось
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 5: Журнал построчно

**Files:**
- Modify: `Tranq/TranscriptJournal.swift`
- Test: `TranqTests/Privacy/JournalSealingTests.swift`

**Interfaces:**
- Consumes: `HistoryCrypto`, `HistoryKeyProviding`.
- Produces:
  - `TranscriptJournal.init(directory: URL, sealing: JournalSealing)` где `enum JournalSealing { case off, sealed(key: HistoryKeyProviding) }`
  - Поведение `lastRecord`: при `sealed` с диска при запуске не поднимается.

- [ ] **Step 1: Write the failing tests**

```swift
struct JournalSealingTests {
    @Test func sealedLineIsNotReadableAsJSON()
    @Test func sealedLinesReadBackInOrder()
    @Test func rotationKeepsWorkingOnSealedFile()
    @Test func lastRecordNotRestoredFromDiskWhenSealed()
    @Test func lastRecordStillWorksWithinSession()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Строка файла — base64 конверта, по одной записи на строку, ротация по тем же 5 МБ.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 6: Правила замка

**Files:**
- Create: `Tranq/Privacy/HistoryLock.swift`
- Test: `TranqTests/Privacy/HistoryLockTests.swift`

**Interfaces:**
- Consumes: `HistoryKeyProviding`, `PresenceAuthorizing`, `HistoryLockState`.
- Produces:
  - `final class HistoryLock: ObservableObject { @Published private(set) var state: HistoryLockState }`
  - `init(enabled: Bool, key: HistoryKeyProviding, presence: PresenceAuthorizing, now: @escaping () -> Date = Date.init)`
  - `func unlock() async` — на успехе `unlocked`, на `HistoryKeyError.denied` остаётся `locked`, на `unavailable` даёт `keyUnavailable`.
  - `func noteWindowVisibility(_ onScreen: Bool)`, `func noteSystemDidWake()`, `func tick()` — чистые входы, чтобы правила проверялись без таймеров.
  - `static let idleTimeout: TimeInterval = 15 * 60`

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryLockTests {
    @Test func startsLockedWhenEnabled()
    @Test func unlockSucceedsWithPresence()
    @Test func deniedPresenceKeepsLocked()              // Review Focus 4
    @Test func threeDenialsStillLockedNotUnavailable()  // Review Focus 4
    @Test func missingKeyGivesKeyUnavailable()
    @Test func sleepLocksImmediately()
    @Test func fifteenMinutesHiddenLocks()
    @Test func visibleWindowNeverLocks()                // таймер не идёт, пока окно на экране
    @Test func repeatedUnlocksAllowedInOneRun()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Подписки на `NSWorkspace.willSleepNotification` и на видимость окна через `MainWindowController.isMainWindowOnScreen` живут в приложении и вызывают эти методы; сам класс системных уведомлений не слушает.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 7: Экран запертой истории

**Files:**
- Create: `Tranq/HistoryLockedView.swift`
- Modify: `Tranq/ContentView.swift`, `Tranq/AutoOpenPolicy.swift`, `Tranq/TranqApp.swift`
- Test: `TranqTests/Privacy/LockedUIPolicyTests.swift`

**Interfaces:**
- Consumes: `HistoryLock.state`, `HistoryStore.lockState`.
- Produces:
  - `struct HistoryLockedView: View { let state: HistoryLockState; let onUnlock: () -> Void; let onErase: () -> Void }`
  - `AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled:isWindowVisible:lockState:)`

- [ ] **Step 1: Write the failing tests**

```swift
struct LockedUIPolicyTests {
    @Test func autoOpenDoesNotSwitchWhileLocked()
    @Test func autoOpenWorksWhenLockOff()
    @Test func autoOpenDoesNotSwitchWhenKeyUnavailable()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Проводка живёт здесь: `TranqApp` создаёт `HistoryLock` на реальном ключе и `LocalAuthPresenceGate`, подписывается на `NSWorkspace.willSleepNotification` и на видимость главного окна, прокидывает `state` в `HistoryStore.applyLockState` и в `MCPAccess.historyLocked`, а при запуске с включённым замком зовёт `HistoryMigration.cleanupHalfDone`.

`locked`: монограмма, `История заперта`, кнопка `Разблокировать`. `keyUnavailable`: `История не читается на этом Mac`, строкой ниже короткое объяснение про ключ на прежней машине, кнопка `Стереть историю` с подтверждением. Счётчика записей и точек непрочитанного на заглушке нет. Боковой список и поиск при запертой истории не показываются. Диалог подтверждения вызывается только по нажатию кнопки, не при появлении экрана.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 8: Переключатель в настройках

**Files:**
- Modify: `Tranq/Settings/DataSettingsSection.swift`, `Tranq/AppPreferences.swift`
- Test: `TranqTests/Privacy/LockPreferenceTests.swift`

**Interfaces:**
- Produces: `AppPreferences.historyLockEnabled` с ключом `historyLockEnabled`, по умолчанию `false`; `AppPreferences.historyLockEnabled(in:)` как у подсветки окна.

- [ ] **Step 1: Write the failing tests**

```swift
struct LockPreferenceTests {
    @Test func defaultsToOff()
    @Test func valuePersists()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Карточка в разделе «Данные» над «Стереть историю»: `Замок истории`, подзаголовок `Требовать Touch ID`. Включённый замок добавляет строку `Ключ хранится на этом Mac` и кнопку `Выгрузить`. Включение показывает лист: ключ привязан к этому Mac, на другом история не прочитается, копию можно сохранить заранее, но вернуть её в Tranq пока нельзя; кнопки `Включить` и `Отмена`. Выключение — лист `История снова будет доступна без подтверждения` и подтверждение личности.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 9: Миграция туда и обратно

**Files:**
- Create: `Tranq/Privacy/HistoryMigration.swift`
- Test: `TranqTests/Privacy/HistoryMigrationTests.swift`

**Interfaces:**
- Consumes: `HistoryVault`, `HistoryStore`, `TranscriptJournal`.
- Produces:
  - `enum HistoryMigration { static func enable(store:journal:vault:) throws; static func disable(store:journal:vault:) throws; static func cleanupHalfDone(vault:) }`

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryMigrationTests {
    @Test func enableSealsEverythingAndRemovesPlainFiles()
    @Test func enableVerifiesBeforeDeleting()            // подставная ошибка чтения: открытые файлы целы
    @Test func failureMidwayLeavesPlainFilesReadable()
    @Test func halfDoneEnvelopesAreCleanedOnNextLaunch()
    @Test func disableRestoresSameNotes()
    @Test func plainHistoryFileWinsWhenNotesFolderEmpty() // Review Focus 3: ничего не затёрли
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Порядок: создать ключ, записать конверты рядом, прочитать каждый обратно и сверить с исходным, записать метку `history-migration`, и только потом удалить `history.json`, открытые `.wav`, `.segments.json` и открытый журнал, и лишь затем поднять флаг. Запуск доводит или откатывает прерванную миграцию по метке; недописанные конверты при живом `history.json` без метки удаляются.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 10: Выгрузка копии

**Files:**
- Modify: `Tranq/Privacy/HistoryMigration.swift`, `Tranq/Settings/DataSettingsSection.swift`
- Test: `TranqTests/Privacy/HistoryExportTests.swift`

**Interfaces:**
- Produces: `HistoryMigration.exportCopy(store:vault:to folder: URL) throws` — `history.json` открытым текстом плюс папка `Audio` с `.wav` и таймингами.

- [ ] **Step 1: Write the failing tests**

```swift
struct HistoryExportTests {
    @Test func exportWritesPlainNotesAndAudio()
    @Test func exportedNotesDecodeAsTranscriptionItems()
    @Test func exportRefusesWhileLocked()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Кнопка `Выгрузить` открывает `NSOpenPanel` с выбором папки, доступна только в состоянии `unlocked`.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 11: MCP и логи

**Files:**
- Modify: `Tranq/MCP/MCPAccess.swift`, `Tranq/MCP/MCPDoor.swift`, `Tranq/AppLogger.swift`
- Test: `TranqTests/MCP/MCPLockTests.swift`

**Interfaces:**
- Produces: `MCPAccess.historyLocked: Bool` и ветка в `verdict(for:disablingPack:)`: при `historyLocked` команда `.dictations` даёт `.deny(String(localized: "История заперта. Разблокируйте её в Tranq."))`.

- [ ] **Step 1: Write the failing tests**

```swift
struct MCPLockTests {
    @Test func dictationsDeniedWhileLocked()
    @Test func denialIsErrorNotEmptyList()
    @Test func toolsStillListedWhileLocked()
    @Test func wordsStillAllowedWhileLocked()
    @Test func dictationsAllowedAfterUnlock()
    @Test func loggerOmitsTranscriptTextWhenLockEnabled()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Логгер при включённом замке вместо текста расшифровки и слов словаря пишет длину и идентификатор. Сам лог не шифруется. Тексты, записанные до замка, остаются в нём, поэтому лог очищается после успешного включения, а при сбое между меткой и очисткой его чистит запуск.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 12: Гигиена временных файлов

**Files:**
- Modify: `Tranq/AudioPCM.swift`
- Test: `TranqTests/Privacy/TempFilesTests.swift`

**Interfaces:**
- Produces: `TempFiles.makeURL(prefix:ext:)` создаёт файл с правами `0o600`; `TempFiles.directory` создаётся с правами `0o700`.

- [ ] **Step 1: Write the failing tests**

```swift
struct TempFilesTests {
    @Test func tempFileIsOwnerOnly()
    @Test func tempDirectoryIsOwnerOnly()
    @Test func purgeStaleRemovesOldFiles()
}
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

Замок на путь распознавания не распространяется, см. раздел 2 спеки: файлы остаются, но закрыты правами и удаляются сразу после работы движка.

- [ ] **Step 4: Run tests to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 13: Стирание, версия, документация

**Files:**
- Modify: `Tranq/DataEraser.swift`, `Tranq.xcodeproj/project.pbxproj`, `README_RU.md`, `README.md`, `Tranq/Localizable.xcstrings`
- Test: `TranqTests/DataEraserTests.swift`

**Interfaces:**
- Produces: `DataEraser.eraseAll(history:journal:logger:vault:key:)` — убирает открытые файлы, конверты и сам ключ.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func eraseRemovesEnvelopesAndKey()
@Test func eraseLeavesLockEnabledForNewKey()
```

- [ ] **Step 2: Run tests to verify they fail**
- [ ] **Step 3: Implement**

`MARKETING_VERSION = 3.5` в обеих конфигурациях. В оба README — короткий абзац про замок истории и про то, что ключ живёт на этой машине. Новые строки интерфейса — в `Localizable.xcstrings` дампером в стиле Xcode.

- [ ] **Step 4: Run the whole suite**

Run: `xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: все наборы зелёные.

- [ ] **Step 5: Commit**
