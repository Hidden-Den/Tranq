//
//  HistoryVaultTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Хранилище конвертов: заметки и блобы лежат на диске только запечатанными.
struct HistoryVaultTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryVaultTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func item(_ text: String, date: String = "19.11.2026, 10:00") -> TranscriptionItem {
        TranscriptionItem(date: date, text: text, duration: "0:05", spokenText: "ну \(text)")
    }

    private func noteURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("Notes/\(id.uuidString).note")
    }

    @Test func writtenNoteReadsBack() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let note = item("привет мир")
        try vault.writeNote(note)
        #expect(try vault.readNotes() == [note])
        #expect(vault.noteFileCount() == 1)
        #expect(vault.corruptedNoteFiles.isEmpty)
    }

    @Test func notesComeNewestFirst() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let old = item("старая", date: "01.11.2026, 09:00")
        let middle = item("средняя", date: "10.11.2026, 09:00")
        let new = item("новая", date: "19.11.2026, 09:00")
        for note in [middle, new, old] { try vault.writeNote(note) }
        #expect(try vault.readNotes().map(\.text) == ["новая", "средняя", "старая"])
    }

    @Test func rewritingOlderNoteKeepsOrder() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        var older = item("раньше")
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        var newer = item("позже")
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        try vault.writeNote(older)
        try vault.writeNote(newer)
        #expect(try vault.readNotes().map(\.text) == ["позже", "раньше"])

        // Перезапись старой, как в markAsRead, порядок не меняет.
        try vault.writeNote(older.withText("раньше правка"))
        #expect(try vault.readNotes().map(\.text) == ["позже", "раньше правка"])
    }

    @Test func notesWithoutStampComeInStableIdOrder() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        var notes = (0..<6).map { item("заметка \($0)") }
        for index in notes.indices { notes[index].createdAt = nil }
        for note in notes.reversed() { try vault.writeNote(note) }
        let expected = notes.map(\.id.uuidString).sorted()
        for _ in 0..<3 {
            #expect(try vault.readNotes().map(\.id.uuidString) == expected)
        }
    }

    @Test func stampedNotesComeBeforeUnstampedOnes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        var legacy = item("старая версия")
        legacy.createdAt = nil
        try vault.writeNote(legacy)
        try vault.writeNote(item("со штампом"))
        #expect(try vault.readNotes().map(\.text) == ["со штампом", "старая версия"])
    }

    @Test func corruptedFileIsSkippedAndKept() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let good = item("целая")
        let broken = item("битая")
        try vault.writeNote(good)
        try vault.writeNote(broken)
        let brokenURL = noteURL(broken.id, in: directory)
        let whole = try Data(contentsOf: brokenURL)
        try whole.prefix(whole.count / 2).write(to: brokenURL)

        #expect(try vault.readNotes() == [good])
        #expect(FileManager.default.fileExists(atPath: brokenURL.path))
        #expect(vault.corruptedNoteFiles.map(\.lastPathComponent) == [brokenURL.lastPathComponent])
        #expect(vault.noteFileCount() == 2)

        // Повторное чтение пересобирает список, а не копит.
        #expect(try vault.readNotes() == [good])
        #expect(vault.corruptedNoteFiles.count == 1)
    }

    @Test func tamperedCiphertextIsCorruptedToo() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let note = item("подмена")
        try vault.writeNote(note)
        let url = noteURL(note.id, in: directory)
        var envelope = try JSONDecoder().decode(SealedEnvelope.self, from: Data(contentsOf: url))
        var bytes = envelope.ciphertext
        bytes[0] ^= 0xFF
        envelope = SealedEnvelope(version: envelope.version, ephemeralPublicKey: envelope.ephemeralPublicKey,
                                  nonce: envelope.nonce, ciphertext: bytes)
        try JSONEncoder().encode(envelope).write(to: url)

        #expect(try vault.readNotes().isEmpty)
        #expect(vault.corruptedNoteFiles.count == 1)
    }

    @Test func deniedKeyIsNotCorruption() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        let vault = HistoryVault(directory: directory, key: key)
        try vault.writeNote(item("секрет"))

        for failure in [HistoryKeyError.denied, .unavailable] {
            key.failure = failure
            #expect(throws: HistoryKeyError.self) { try vault.readNotes() }
            #expect(vault.corruptedNoteFiles.isEmpty)
        }
        key.failure = nil
        #expect(try vault.readNotes().count == 1)
    }

    @Test func writeNoteNeedsOnlyPublicKey() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        let vault = HistoryVault(directory: directory, key: key)
        try vault.writeNote(item("без подтверждения"))
        try vault.writeBlob(Data([1, 2, 3]), id: UUID(), purpose: .audio)
        #expect(key.agreeCount == 0)
    }

    @Test func audioBlobRoundTrips() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let id = UUID()
        let wav = Data((0..<2048).map { UInt8($0 % 251) })
        let timings = Data("[0.0,0.4]".utf8)
        try vault.writeBlob(wav, id: id, purpose: .audio)
        try vault.writeBlob(timings, id: id, purpose: .timings)
        #expect(try vault.readBlob(id: id, purpose: .audio) == wav)
        #expect(try vault.readBlob(id: id, purpose: .timings) == timings)
        #expect(try vault.readBlob(id: UUID(), purpose: .audio) == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Audio/\(id.uuidString).wav.sealed").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Audio/\(id.uuidString).segments.sealed").path))
    }

    @Test func blobRejectsForeignPurposes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        for purpose in [HistoryCryptoPurpose.note, .journal] {
            #expect(throws: (any Error).self) { try vault.writeBlob(Data([1]), id: UUID(), purpose: purpose) }
            #expect(throws: (any Error).self) { try vault.readBlob(id: UUID(), purpose: purpose) }
        }
    }

    @Test func blobKeyErrorPropagates() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        let vault = HistoryVault(directory: directory, key: key)
        let id = UUID()
        try vault.writeBlob(Data([9]), id: id, purpose: .audio)
        key.failure = .denied
        #expect(throws: HistoryKeyError.self) { try vault.readBlob(id: id, purpose: .audio) }
    }

    @Test func deleteRemovesNoteAndItsBlobs() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let doomed = item("удалить")
        let kept = item("оставить")
        try vault.writeNote(doomed)
        try vault.writeNote(kept)
        try vault.writeBlob(Data([1]), id: doomed.id, purpose: .audio)
        try vault.writeBlob(Data([2]), id: doomed.id, purpose: .timings)
        try vault.writeBlob(Data([3]), id: kept.id, purpose: .audio)

        vault.deleteNote(id: doomed.id)
        vault.deleteBlobs(id: doomed.id)

        #expect(try vault.readNotes() == [kept])
        #expect(vault.noteFileCount() == 1)
        #expect(try vault.readBlob(id: doomed.id, purpose: .audio) == nil)
        #expect(try vault.readBlob(id: doomed.id, purpose: .timings) == nil)
        #expect(try vault.readBlob(id: kept.id, purpose: .audio) == Data([3]))
    }

    @Test func plainTextOfNoteIsNotOnDisk() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let text = "уникальнаяфразаштрихкод"
        let note = item(text)
        try vault.writeNote(note)
        let onDisk = try Data(contentsOf: noteURL(note.id, in: directory))
        #expect(!onDisk.isEmpty)
        #expect(onDisk.range(of: Data(text.utf8)) == nil)
        #expect(onDisk.range(of: Data(note.date.utf8)) == nil)
    }

    @Test func foldersAndFilesArePrivate() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = HistoryVault(directory: directory, key: TestHistoryKey())
        let note = item("права")
        try vault.writeNote(note)
        try vault.writeBlob(Data([1]), id: note.id, purpose: .audio)

        func mode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
        }
        #expect(try mode(directory.appendingPathComponent("Notes")) == 0o700)
        #expect(try mode(directory.appendingPathComponent("Audio")) == 0o700)
        #expect(try mode(noteURL(note.id, in: directory)) == 0o600)
        #expect(try mode(directory.appendingPathComponent("Audio/\(note.id.uuidString).wav.sealed")) == 0o600)
    }
}
