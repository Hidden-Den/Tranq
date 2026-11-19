//
//  HistoryStoreLockTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Состояния замка в `HistoryStore`: при замке заметки живут только конвертами,
/// общий `history.json` не пишется никогда.
@MainActor
struct HistoryStoreLockTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreLockTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(_ directory: URL, key: TestHistoryKey = TestHistoryKey(),
                           state: HistoryLockState) -> (HistoryStore, HistoryVault) {
        let vault = HistoryVault(directory: directory, key: key)
        let store = HistoryStore(directory: directory, saveDelay: 0, vault: vault, lockState: state)
        return (store, vault)
    }

    private func plainFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("history.json")
    }

    private func noteURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("Notes/\(id.uuidString).note")
    }

    private func dictation(_ text: String) -> TranscriptionItem {
        TranscriptionItem(date: TranscriptionItem.formattedNow(), text: text, duration: "0:05",
                          isUnread: true, spokenText: "ну \(text)")
    }

    @Test func addNoteWhileLockedWritesEnvelopeAndKeepsItemsEmpty() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault) = makeStore(directory, state: .locked)

        let id = store.addNote(text: "секретный план")
        store.flush()

        #expect(store.items.isEmpty)
        #expect(store.lockState == .locked)
        let raw = try Data(contentsOf: noteURL(id, in: directory))
        #expect(String(decoding: raw, as: UTF8.self).contains("секретный") == false)
        #expect(try vault.readNotes().map(\.text) == ["секретный план"])
        #expect(!FileManager.default.fileExists(atPath: plainFile(directory).path))
    }

    @Test func unlockReadsNotesWrittenWhileLocked() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        store.addNote(text: "первая")
        store.insert(dictation("вторая"))
        store.flush()

        await store.applyLockStateAndWait(.unlocked)

        #expect(store.lockState == .unlocked)
        #expect(Set(store.items.map(\.text)) == ["первая", "вторая"])
    }

    /// Review Focus 2.
    @Test func lockingClearsItemsAndWritesNothingToPlainFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault) = makeStore(directory, state: .locked)
        await store.applyLockStateAndWait(.unlocked)
        store.addNote(text: "до запирания")

        await store.applyLockStateAndWait(.locked)
        store.addNote(text: "после запирания")
        store.insert(dictation("диктовка"))
        store.flush()

        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plainFile(directory).path))
        #expect(vault.noteFileCount() == 3)
    }

    /// Review Focus 2.
    @Test func noteAddedDuringUnlockSurvivesImmediateLock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        await store.applyLockStateAndWait(.unlocked)

        store.insert(dictation("успела"))
        store.applyLockState(.locked)
        #expect(store.items.isEmpty)

        await store.applyLockStateAndWait(.unlocked)
        #expect(store.items.map(\.text) == ["успела"])
    }

    @Test func staleUnlockReadDoesNotRepopulateAfterLock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        store.addNote(text: "тайна")
        store.flush()

        store.applyLockState(.unlocked)
        await store.applyLockStateAndWait(.locked)
        store.flush()
        await Task.yield()

        #expect(store.lockState == .locked)
        #expect(store.items.isEmpty)
    }

    @Test func editingNoteWhileUnlockedRewritesOnlyItsFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault) = makeStore(directory, state: .locked)
        await store.applyLockStateAndWait(.unlocked)
        let edited = store.addNote(text: "черновик")
        let other = store.addNote(text: "соседка")
        store.flush()
        let otherBefore = try Data(contentsOf: noteURL(other, in: directory))
        let editedBefore = try Data(contentsOf: noteURL(edited, in: directory))
        let createdAt = store.items.first { $0.id == edited }?.createdAt

        store.replaceNoteText(id: edited, text: "чистовик")
        store.flush()

        #expect(try Data(contentsOf: noteURL(other, in: directory)) == otherBefore)
        #expect(try Data(contentsOf: noteURL(edited, in: directory)) != editedBefore)
        let reread = try vault.readNotes().first { $0.id == edited }
        #expect(reread?.text == "чистовик")
        #expect(reread?.createdAt == createdAt)
        #expect(!FileManager.default.fileExists(atPath: plainFile(directory).path))

        store.deleteItem(at: store.items.firstIndex { $0.id == other }!)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: noteURL(other, in: directory).path))
        #expect(vault.noteFileCount() == 1)
    }

    /// История как сегодня: один `history.json`, конвертов нет.
    @Test func lockOffBehavesLikeBefore() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault) = makeStore(directory, state: .off)

        store.addNote(text: "открытая")
        store.flush()

        #expect(store.lockState == .off)
        #expect(store.items.map(\.text) == ["открытая"])
        #expect(FileManager.default.fileExists(atPath: plainFile(directory).path))
        #expect(vault.noteFileCount() == 0)
        let reloaded = HistoryStore(directory: directory)
        #expect(reloaded.items.map(\.text) == ["открытая"])
    }

    @Test func notesWrittenWhileLockedArriveUnread() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        let note = dictation("новая диктовка")
        store.insert(note)
        store.flush()

        await store.applyLockStateAndWait(.unlocked)

        #expect(store.items.first?.id == note.id)
        #expect(store.items.first?.isUnread == true)
        store.markAsRead(id: note.id)
        await store.applyLockStateAndWait(.locked)
        await store.applyLockStateAndWait(.unlocked)
        #expect(store.items.first?.isUnread == false)
    }

    @Test func clearAllWhileLockedRemovesEnvelopes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault) = makeStore(directory, state: .locked)
        let id = store.addNote(text: "раз")
        try vault.writeBlob(Data([1, 2, 3]), id: id, purpose: .audio)
        store.flush()

        store.clearAll()
        store.flush()

        #expect(vault.noteFileCount() == 0)
        #expect(try vault.readBlob(id: id, purpose: .audio) == nil)
    }

    @Test func refusedKeyStaysLockedAndLostKeyIsUnavailable() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        let (store, _) = makeStore(directory, key: key, state: .locked)
        store.addNote(text: "закрыто")
        store.flush()

        key.failure = .denied
        await store.applyLockStateAndWait(.unlocked)
        #expect(store.lockState == .locked)
        #expect(store.items.isEmpty)

        key.failure = .unavailable
        await store.applyLockStateAndWait(.unlocked)
        #expect(store.lockState == .keyUnavailable)
        #expect(store.items.isEmpty)
    }

    @Test func attachingVaultAtRuntimeSwitchesWrites() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory, saveDelay: 0)
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())

        store.attach(vault: vault)
        await store.applyLockStateAndWait(.locked)
        store.addNote(text: "после включения")
        store.flush()

        #expect(store.items.isEmpty)
        #expect(vault.noteFileCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: plainFile(directory).path))
    }

    /// Отказ записи конверта: заметка ждёт в памяти и дописывается при следующей попытке.
    @Test func failedSealStaysPendingAndRetries() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        let (store, vault) = makeStore(directory, key: key, state: .locked)

        key.failure = .unavailable
        let note = dictation("не потеряйся")
        store.insert(note)
        store.flush()
        await mainHop()
        #expect(vault.noteFileCount() == 0)
        #expect(store.sealFailureCount == 1)
        #expect(!FileManager.default.fileExists(atPath: plainFile(directory).path))

        key.failure = nil
        await store.applyLockStateAndWait(.locked)
        store.flush()
        await mainHop()
        #expect(vault.noteFileCount() == 1)
        #expect(store.sealFailureCount == 0)
        await store.applyLockStateAndWait(.unlocked)
        #expect(store.items.map(\.id) == [note.id])
        #expect(store.items.first?.isUnread == true)
    }

    /// Без хранилища заметка держится в памяти и запечатывается после `attach`.
    @Test func noteWithoutVaultIsSealedAfterAttach() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory, saveDelay: 0, vault: nil, lockState: .locked)

        let note = dictation("ждёт ключа")
        store.insert(note)
        store.flush()
        await mainHop()
        #expect(store.sealFailureCount == 1)

        await store.applyLockStateAndWait(.unlocked)
        #expect(store.items.map(\.id) == [note.id])

        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        store.attach(vault: vault)
        store.flush()
        await mainHop()
        #expect(vault.noteFileCount() == 1)
        #expect(store.sealFailureCount == 0)
        #expect(!FileManager.default.fileExists(atPath: plainFile(directory).path))
    }

    /// Чтение конвертов, начатое до очистки, не возвращает стёртые заметки.
    @Test func clearAllDuringUnlockReadStaysEmpty() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, vault) = makeStore(directory, state: .locked)
        store.addNote(text: "раз")
        store.addNote(text: "два")
        store.flush()

        store.applyLockState(.unlocked)
        store.clearAll()
        store.flush()
        await mainHop()

        #expect(store.items.isEmpty)
        #expect(vault.noteFileCount() == 0)
    }

    private func mainHop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

extension HistoryStore {
    /// Переход с ожиданием: на `unlocked` дожидается чтения конвертов.
    func applyLockStateAndWait(_ state: HistoryLockState) async {
        await withCheckedContinuation { continuation in
            applyLockState(state) { continuation.resume() }
        }
    }
}
