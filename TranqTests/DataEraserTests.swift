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
}
