//
//  DataEraserTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// «Стереть историю» убирает всё, где остаётся речь: заметки, звук, журнал диктовок и лог.
@Suite(.serialized)
struct DataEraserTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tranq-eraser-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func journalFile(in dir: URL) -> URL { dir.appendingPathComponent("transcript_journal.jsonl") }
    private func archiveFile(in dir: URL) -> URL { dir.appendingPathComponent("transcript_journal.1.jsonl") }
    private func logFile(in dir: URL) -> URL { dir.appendingPathComponent("Logs/app.log") }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Журнал с одной записью на диске и в памяти.
    private func journalWithRecord(in dir: URL) -> TranscriptJournal {
        let journal = TranscriptJournal(directory: dir)
        journal.recordInitial(id: UUID(), rawText: "ну это секретная фраза", durationSec: 2, targetAppName: "Telegram")
        journal.flush()
        return journal
    }

    @Test func journalClearRemovesFileAndArchive() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = journalWithRecord(in: dir)
        try Data("старая запись\n".utf8).write(to: archiveFile(in: dir))
        #expect(exists(journalFile(in: dir)))

        journal.clear()
        journal.flush()

        #expect(!exists(journalFile(in: dir)))
        #expect(!exists(archiveFile(in: dir)))
    }

    @Test func journalClearForgetsLastRecord() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = journalWithRecord(in: dir)
        await MainActor.run {}
        #expect(journal.lastRecord != nil)

        journal.clear()
        await MainActor.run {}

        #expect(journal.lastRecord == nil)
    }

    @Test func pasteOriginalFindsNothingAfterClear() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = journalWithRecord(in: dir)
        await MainActor.run {}

        journal.clear()
        await MainActor.run {}

        let pasted = await withCheckedContinuation { continuation in
            journal.pasteOriginal { continuation.resume(returning: $0) }
        }
        #expect(pasted == false)
    }

    @Test func journalKeepsWorkingAfterClear() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = journalWithRecord(in: dir)
        journal.clear()

        journal.recordInitial(id: UUID(), rawText: "новая диктовка", durationSec: 1, targetAppName: nil)
        journal.flush()

        let text = (try? String(contentsOf: journalFile(in: dir), encoding: .utf8)) ?? ""
        #expect(text.contains("новая диктовка"))
        #expect(!text.contains("секретная фраза"))
    }

    @Test func eraseAllWipesHistoryAudioJournalAndLog() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let history = HistoryStore(directory: dir, saveDelay: 0)
        let noteId = history.addNote(text: "заметка")
        let source = dir.appendingPathComponent("source.wav")
        try Data([0, 1, 2, 3]).write(to: source)
        history.storeAudio(for: noteId, from: source, move: false)
        #expect(history.hasAudio(for: noteId))

        let journal = journalWithRecord(in: dir)

        let logger = AppLogger(directory: dir)
        logger.info("Test", "Распознано: «секретная фраза»")
        logger.flush()
        #expect(exists(logFile(in: dir)))

        DataEraser.eraseAll(history: history, journal: journal, logger: logger)
        history.flush()
        journal.flush()
        logger.flush()
        await MainActor.run {}

        #expect(history.items.isEmpty)
        #expect(!history.hasAudio(for: noteId))
        #expect(!exists(journalFile(in: dir)))
        #expect(!exists(logFile(in: dir)))
        #expect(journal.lastRecord == nil)
    }

    private func sealedFiles(in dir: URL) -> [String] {
        let fm = FileManager.default
        let notes = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Notes").path)) ?? []
        let audio = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Audio").path)) ?? []
        return notes.filter { $0.hasSuffix(".note") } + audio.filter { $0.hasSuffix(".sealed") }
    }

    /// Запертая история: конверты заметок и аудио, запечатанный журнал, забытый открытый `history.json` и ключ.
    @Test func eraseRemovesEnvelopesAndKey() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let vault = HistoryVault(directory: dir, key: key)
        let item = TranscriptionItem(date: "d", text: "секретная заметка", duration: "1 сек")
        try vault.writeNote(item)
        try vault.writeBlob(Data([0, 1, 2, 3]), id: item.id, purpose: .audio)
        let leftover = dir.appendingPathComponent("history.json")
        try JSONEncoder().encode([TranscriptionItem(date: "d", text: "забытая копия", duration: "1 сек")]).write(to: leftover)
        let history = await MainActor.run { HistoryStore(directory: dir, saveDelay: 0, vault: vault, lockState: .locked) }

        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: key))
        journal.recordInitial(id: UUID(), rawText: "ну это секретная фраза", durationSec: 2, targetAppName: nil)
        journal.flush()
        #expect(exists(journalFile(in: dir)))
        #expect(sealedFiles(in: dir).count == 2)

        let logger = AppLogger(directory: dir)
        let failed = await MainActor.run {
            DataEraser.eraseAll(history: history, journal: journal, logger: logger, vault: vault, key: key)
        }
        history.flush()
        journal.flush()
        logger.flush()

        #expect(failed.isEmpty)
        #expect(sealedFiles(in: dir).isEmpty)
        #expect(!exists(journalFile(in: dir)))
        #expect(!exists(leftover))
        #expect(!key.exists)
    }

    /// После стирания замок остаётся включённым: новый ключ, новая заметка ложится конвертом и читается.
    @MainActor
    @Test func eraseLeavesLockEnabledForNewKey() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let store = HistoryStore(directory: dir, saveDelay: 0)
        let journal = TranscriptJournal(directory: dir)
        let logger = AppLogger(directory: dir)
        let coordinator = HistoryLockCoordinator(
            enabled: true, store: store, journal: journal, key: key, presence: TestPresence(), directory: dir,
            erase: { DataEraser.eraseAll(history: store, journal: journal, logger: logger,
                                         vault: HistoryVault(directory: dir, key: key), key: key) },
            resetSession: {})
        _ = store.addNote(text: "старая заметка")
        store.flush()
        let oldPublicKey = try key.publicKey

        coordinator.eraseHistory()
        store.flush()
        journal.flush()

        #expect(coordinator.isEnabled)
        #expect(coordinator.state == .locked)
        #expect(key.exists)
        #expect(try key.publicKey != oldPublicKey)
        #expect(sealedFiles(in: dir).isEmpty)

        _ = store.addNote(text: "новая заметка")
        store.flush()
        #expect(sealedFiles(in: dir).count == 1)
        #expect(store.sealFailureCount == 0)

        await coordinator.unlock()
        for _ in 0..<300 where store.items.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .unlocked)
        #expect(store.items.map(\.text) == ["новая заметка"])
    }

    // MARK: - Копии миграции

    /// Запертая история с копиями прерванной миграции: открытая копия истории и звук `.restore`.
    private func lockedHistoryWithRestoreCopies(in dir: URL, key: TestHistoryKey) async throws -> (HistoryStore, UUID) {
        let layout = HistoryMigration.Layout(directory: dir)
        let item = TranscriptionItem(date: "d", text: "стёртая заметка", duration: "1 сек")
        try FileManager.default.createDirectory(at: layout.audio, withIntermediateDirectories: true)
        try JSONEncoder().encode([item]).write(to: layout.historyRestore)
        try Data([0, 1, 2, 3]).write(to: layout.restore(layout.plainAudio(item.id)))
        try Data("[]".utf8).write(to: layout.restore(layout.plainTimings(item.id)))
        try Data("[]".utf8).write(to: layout.historyCandidate)
        let vault = HistoryVault(directory: dir, key: key)
        let store = await MainActor.run { HistoryStore(directory: dir, saveDelay: 0, vault: vault, lockState: .locked) }
        return (store, item.id)
    }

    private func audioFiles(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: HistoryMigration.Layout(directory: dir).audio.path)) ?? []
    }

    /// Стёртая история не возвращается уборкой при запуске, когда новый ключ создан.
    @Test func eraseRemovesRestoreCopiesSoLaunchCleanupBringsNothingBack() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let (store, id) = try await lockedHistoryWithRestoreCopies(in: dir, key: key)
        let journal = TranscriptJournal(directory: dir)
        let logger = AppLogger(directory: dir)

        let failed = DataEraser.eraseAll(history: store, journal: journal, logger: logger,
                                         vault: HistoryVault(directory: dir, key: key), key: key)
        store.flush()
        try key.create()

        var flag: Bool?
        let notice = HistoryMigration.cleanupHalfDone(vault: HistoryVault(directory: dir, key: key), lockEnabled: true,
                                                      setLockEnabled: { flag = $0 })
        let layout = HistoryMigration.Layout(directory: dir)
        #expect(failed.isEmpty)
        #expect(notice == nil)
        #expect(flag == nil)
        #expect(!exists(layout.history))
        #expect(!exists(layout.historyRestore))
        #expect(!exists(layout.historyCandidate))
        #expect(!exists(layout.plainAudio(id)))
        #expect(audioFiles(in: dir).isEmpty)
    }

    /// Ключ после стирания не создался: стёртая копия не выключает замок и не встаёт историей.
    @Test func eraseWithoutNewKeyDoesNotTurnLockOffAtLaunch() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let (store, id) = try await lockedHistoryWithRestoreCopies(in: dir, key: key)
        let journal = TranscriptJournal(directory: dir)
        let logger = AppLogger(directory: dir)

        DataEraser.eraseAll(history: store, journal: journal, logger: logger,
                            vault: HistoryVault(directory: dir, key: key), key: key)
        store.flush()
        #expect(!key.exists)

        var flag: Bool?
        let notice = HistoryMigration.cleanupHalfDone(vault: HistoryVault(directory: dir, key: key), lockEnabled: true,
                                                      setLockEnabled: { flag = $0 })
        let layout = HistoryMigration.Layout(directory: dir)
        #expect(notice == nil)
        #expect(flag == nil)
        #expect(!exists(layout.history))
        #expect(!exists(layout.plainAudio(id)))
    }

    /// Открытые тайминги без заметки и метка миграции уходят вместе с историей.
    @Test func eraseRemovesOrphanTimingsAndMarker() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let layout = HistoryMigration.Layout(directory: dir)
        try FileManager.default.createDirectory(at: layout.audio, withIntermediateDirectories: true)
        let orphan = layout.plainTimings(UUID())
        try Data("[]".utf8).write(to: orphan)
        try HistoryMigration.writeMarker(.enableJournal, in: dir)
        let vault = HistoryVault(directory: dir, key: key)
        let store = await MainActor.run { HistoryStore(directory: dir, saveDelay: 0, vault: vault, lockState: .locked) }

        DataEraser.eraseAll(history: store, journal: TranscriptJournal(directory: dir), logger: AppLogger(directory: dir),
                            vault: vault, key: key)
        store.flush()

        #expect(!exists(orphan))
        #expect(!layout.hasMarker)
    }
}
