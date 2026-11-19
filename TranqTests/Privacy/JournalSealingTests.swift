//
//  JournalSealingTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Журнал диктовок при замке: каждая строка — конверт в base64, ротация и чтение работают на конвертах.
@Suite(.serialized)
struct JournalSealingTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tranq-journal-seal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func journalFile(_ dir: URL) -> URL { dir.appendingPathComponent("transcript_journal.jsonl") }
    private func archiveFile(_ dir: URL) -> URL { dir.appendingPathComponent("transcript_journal.1.jsonl") }

    private func lines(of url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private func add(_ journal: TranscriptJournal, _ text: String) {
        journal.recordInitial(id: UUID(), rawText: text, durationSec: 1, targetAppName: "Notes")
        journal.flush()
    }

    @Test func sealedLineIsNotReadableAsJSON() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: TestHistoryKey()))

        add(journal, "ну это секретная фраза")

        let raw = try Data(contentsOf: journalFile(dir))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains("секретная"))
        #expect(!text.contains("rawText"))
        let fileLines = lines(of: journalFile(dir))
        #expect(fileLines.count == 1)
        let decoded = try #require(Data(base64Encoded: fileLines[0]))
        #expect((try? JSONDecoder().decode(JournalRecord.self, from: decoded)) == nil)
        #expect((try? JSONDecoder().decode(SealedEnvelope.self, from: decoded)) != nil)
    }

    @Test func sealedLinesReadBackInOrder() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: key))

        for word in ["первая", "вторая", "третья"] { add(journal, word) }

        let records = try journal.readAllRecords(key: key)
        #expect(records.map(\.rawText) == ["первая", "вторая", "третья"])
        #expect(lines(of: journalFile(dir)).count == 3)
    }

    @Test func appendingNeedsOnlyPublicKey() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: key))

        add(journal, "тихая запись")

        #expect(key.agreeCount == 0)
    }

    @Test func rotationKeepsWorkingOnSealedFile() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: key))
        let big = String(repeating: "a", count: 1_000_000)

        // Пишем, пока файл не уйдёт в архив: строка больше мегабайта, порог 5 МБ.
        var written = 0
        while !FileManager.default.fileExists(atPath: archiveFile(dir).path), written < 10 {
            add(journal, "\(written)\(big)")
            written += 1
        }

        #expect(FileManager.default.fileExists(atPath: archiveFile(dir).path))
        #expect(lines(of: archiveFile(dir)).count == written - 1)
        #expect(lines(of: journalFile(dir)).count == 1)
        for url in [archiveFile(dir), journalFile(dir)] {
            for line in lines(of: url) {
                let data = try #require(Data(base64Encoded: line))
                #expect((try? JSONDecoder().decode(SealedEnvelope.self, from: data)) != nil)
            }
        }
        let records = try journal.readAllRecords(key: key)
        #expect(records.count == written)
        #expect(records.map { String($0.rawText.first!) } == (0..<written).map { String($0) })
    }

    @Test func lastRecordNotRestoredFromDiskWhenSealed() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        add(TranscriptJournal(directory: dir, sealing: .sealed(key: key)), "было до перезапуска")

        let reopened = TranscriptJournal(directory: dir, sealing: .sealed(key: key))
        reopened.flush()
        await MainActor.run {}

        #expect(reopened.lastRecord == nil)
        #expect(key.agreeCount == 0)
        var pasted: Bool?
        reopened.pasteOriginal { pasted = $0 }
        #expect(pasted == false)
    }

    @Test func lastRecordStillWorksWithinSession() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: TestHistoryKey()))
        let id = UUID()

        journal.recordInitial(id: id, rawText: "сырой текст", durationSec: 1, targetAppName: "Notes")
        await MainActor.run {}
        #expect(journal.lastRecord?.rawText == "сырой текст")

        journal.updateFinal(id: id, stageOneText: nil, finalText: "чистый текст", isFallback: false)
        journal.flush()
        await MainActor.run {}
        #expect(journal.lastRecord?.finalPastedText == "чистый текст")
        #expect(journal.lastRecord?.rawText == "сырой текст")
    }

    @Test func offModeStillRestoresLastRecordFromDisk() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        add(TranscriptJournal(directory: dir), "открытая запись")

        let reopened = TranscriptJournal(directory: dir)
        reopened.flush()
        await MainActor.run {}

        #expect(reopened.lastRecord?.rawText == "открытая запись")
    }

    @Test func setSealingSwitchesAtRuntime() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir)

        add(journal, "открытая")
        journal.setSealing(.sealed(key: key))
        add(journal, "запечатанная")
        journal.setSealing(.off)
        add(journal, "снова открытая")

        let fileLines = lines(of: journalFile(dir))
        #expect(fileLines.count == 3)
        #expect(fileLines[0].contains("открытая"))
        #expect(!fileLines[1].contains("запечатанная"))
        #expect(Data(base64Encoded: fileLines[1]) != nil)
        #expect(fileLines[2].contains("снова открытая"))
        // Открытые строки читалка пропускает как нечитаемые.
        #expect(try journal.readAllRecords(key: key).map(\.rawText) == ["запечатанная"])
    }

    @Test func setSealingIsOrderedWithAppendsInFlight() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir)

        for index in 0..<20 {
            journal.recordInitial(id: UUID(), rawText: "открытая \(index)", durationSec: 1, targetAppName: nil)
        }
        journal.setSealing(.sealed(key: key))
        for index in 0..<20 {
            journal.recordInitial(id: UUID(), rawText: "закрытая \(index)", durationSec: 1, targetAppName: nil)
        }
        journal.flush()

        let fileLines = lines(of: journalFile(dir))
        #expect(fileLines.count == 40)
        #expect(fileLines.prefix(20).allSatisfy { $0.contains("открытая") })
        #expect(fileLines.suffix(20).allSatisfy { !$0.contains("закрытая") })
        #expect(try journal.readAllRecords(key: key).count == 20)
    }

    @Test func readAllRecordsSkipsCorruptLines() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: key))
        add(journal, "до порчи")

        let junk = "это не base64 и не конверт\n" + Data("{}".utf8).base64EncodedString() + "\n"
        let handle = try FileHandle(forWritingTo: journalFile(dir))
        handle.seekToEndOfFile()
        handle.write(Data(junk.utf8))
        try handle.close()
        add(journal, "после порчи")

        #expect(try journal.readAllRecords(key: key).map(\.rawText) == ["до порчи", "после порчи"])
    }

    @Test func readAllRecordsRethrowsKeyErrors() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = TestHistoryKey()
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: key))
        add(journal, "запись")

        key.failure = .denied
        #expect(throws: HistoryKeyError.denied) { try journal.readAllRecords(key: key) }
        key.failure = .unavailable
        #expect(throws: HistoryKeyError.unavailable) { try journal.readAllRecords(key: key) }
    }

    @Test func readAllRecordsWithoutFilesIsEmpty() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: TestHistoryKey()))

        #expect(try journal.readAllRecords(key: TestHistoryKey()).isEmpty)
    }

    @Test func unavailableKeyDropsRecordWithoutCrash() async {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = TranscriptJournal(directory: dir, sealing: .sealed(key: TestHistoryKey(created: false)))

        add(journal, "некуда запечатать")
        await MainActor.run {}

        #expect(!FileManager.default.fileExists(atPath: journalFile(dir).path))
        #expect(journal.lastRecord?.rawText == "некуда запечатать")
    }
}
