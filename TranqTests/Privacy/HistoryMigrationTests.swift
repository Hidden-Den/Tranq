//
//  HistoryMigrationTests.swift
//  TranqTests
//

import CryptoKit
import Foundation
import Testing
@testable import Tranq

/// Ключ со сценарием сбоев: публичный ключ отдаётся `publicLimit` раз, согласование можно сломать.
final class ScriptedHistoryKey: HistoryKeyProviding {
    let inner: TestHistoryKey
    var publicLimit = Int.max
    var agreeFails = false
    /// Ключ есть, но не читается, пока его не создадут заново.
    var broken = false
    /// Файл публичного ключа обрезан, пока ключ не создадут заново.
    var truncatedPublic = false
    /// Публичный ключ — точка чужого ключа, пока ключ не создадут заново.
    var wrongPublic = false
    private let stranger = Curve25519.KeyAgreement.PrivateKey()
    private(set) var publicCalls = 0
    private(set) var creates = 0
    private(set) var destroys = 0
    private let lock = NSLock()

    init(created: Bool = true) { inner = TestHistoryKey(created: created) }

    var exists: Bool { inner.exists }

    var publicKey: Data {
        get throws {
            lock.lock()
            publicCalls += 1
            let over = publicCalls > publicLimit
            lock.unlock()
            if over || broken { throw HistoryKeyError.unavailable }
            if truncatedPublic { return Data(repeating: 7, count: 10) }
            if wrongPublic { return stranger.publicKey.rawRepresentation }
            return try inner.publicKey
        }
    }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        if agreeFails || broken { throw HistoryKeyError.unavailable }
        return try inner.agree(withEphemeral: ephemeral)
    }

    func create() throws {
        creates += 1
        broken = false; truncatedPublic = false; wrongPublic = false
        try inner.create()
    }
    func destroy() throws { destroys += 1; try inner.destroy() }

    /// С этого момента публичный ключ не отдаётся.
    func stopPublicKey() {
        lock.lock(); publicLimit = publicCalls; lock.unlock()
    }
}

/// Миграция замка: конверты пишутся рядом, читаются обратно, и только потом уходят исходники.
@MainActor
struct HistoryMigrationTests {
    private final class FlagLog { var values: [Bool] = [] }

    private struct Rig {
        let directory: URL
        let key: ScriptedHistoryKey
        let vault: HistoryVault
        let store: HistoryStore
        let journal: TranscriptJournal
        let flags: FlagLog
    }

    private struct Seed {
        var items: [TranscriptionItem]
        var audio: [UUID: Data]
        var timings: [UUID: Data]
    }

    private func makeRig(keyCreated: Bool = true) -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let key = ScriptedHistoryKey(created: keyCreated)
        return Rig(directory: directory, key: key,
                   vault: HistoryVault(directory: directory, key: key),
                   store: HistoryStore(directory: directory, saveDelay: 0),
                   journal: TranscriptJournal(directory: directory),
                   flags: FlagLog())
    }

    private func cleanup(_ rig: Rig) {
        rig.store.flush()
        rig.journal.flush()
        try? FileManager.default.removeItem(at: rig.directory)
    }

    private func note(_ text: String, date: String, createdAt: Date?) -> TranscriptionItem {
        TranscriptionItem(date: date, text: text, duration: "0:05", isUnread: false,
                          spokenText: "ну \(text)", createdAt: createdAt)
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func audioFolder(_ rig: Rig) -> URL { rig.directory.appendingPathComponent("Audio", isDirectory: true) }
    private func historyURL(_ rig: Rig) -> URL { rig.directory.appendingPathComponent("history.json") }
    private func timingsURL(_ id: UUID, _ rig: Rig) -> URL {
        audioFolder(rig).appendingPathComponent("\(id.uuidString).segments.json")
    }
    private func journalURL(_ rig: Rig) -> URL { rig.directory.appendingPathComponent("transcript_journal.jsonl") }

    /// Открытая история: три заметки, аудио у двух, тайминги у одной, две строки журнала.
    @discardableResult
    private func seed(_ rig: Rig, items: [TranscriptionItem]? = nil) throws -> Seed {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = items ?? [
            note("секрет третий", date: "03.11.2026, 12:00", createdAt: base.addingTimeInterval(120)),
            note("секрет второй", date: "02.11.2026, 11:00", createdAt: base.addingTimeInterval(60)),
            note("секрет первый", date: "01.11.2026, 10:00", createdAt: base),
        ]
        // Вставка от старой к новой: в массиве новые первыми.
        for item in items.reversed() { rig.store.insert(item) }
        var audio: [UUID: Data] = [:]
        var timings: [UUID: Data] = [:]
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)
        for item in items.prefix(2) {
            let bytes = randomData(4096)
            let source = rig.directory.appendingPathComponent("source-\(UUID().uuidString).wav")
            try bytes.write(to: source)
            rig.store.storeAudio(for: item.id, from: source, move: true)
            audio[item.id] = bytes
        }
        if let first = items.first {
            let bytes = Data("[{\"word\":\"секрет\",\"start\":0.5}]".utf8)
            try bytes.write(to: timingsURL(first.id, rig))
            timings[first.id] = bytes
        }
        let recordID = UUID()
        rig.journal.recordInitial(id: recordID, rawText: "сырой секрет", durationSec: 2, targetAppName: "Notes")
        rig.journal.updateFinal(id: recordID, stageOneText: nil, finalText: "чистый секрет", isFallback: false)
        rig.store.flush()
        rig.journal.flush()
        return Seed(items: rig.store.items, audio: audio, timings: timings)
    }

    /// Байты всех открытых файлов истории.
    private func plainFiles(_ rig: Rig) -> [String: Data] {
        var result: [String: Data] = [:]
        let fm = FileManager.default
        for name in ["history.json", "transcript_journal.jsonl", "transcript_journal.1.jsonl"] {
            if let data = fm.contents(atPath: rig.directory.appendingPathComponent(name).path) { result[name] = data }
        }
        for name in (try? fm.contentsOfDirectory(atPath: audioFolder(rig).path)) ?? []
        where name.hasSuffix(".wav") || name.hasSuffix(".segments.json") {
            result["Audio/" + name] = fm.contents(atPath: audioFolder(rig).appendingPathComponent(name).path)
        }
        return result
    }

    private func allFiles(_ rig: Rig) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: rig.directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }

    private func envelopeCount(_ rig: Rig) -> Int {
        allFiles(rig).filter { $0.pathExtension == "note" || $0.pathExtension == "sealed" }.count
    }

    private func leftovers(_ rig: Rig) -> [String] {
        allFiles(rig).map(\.lastPathComponent)
            .filter { $0.hasSuffix(".restore") || $0.hasSuffix(".restoring") || $0.hasSuffix(".migrating")
                || $0 == HistoryMigration.markerName }
    }

    private func enable(_ rig: Rig, afterCopies: (@MainActor () -> Void)? = nil) async throws {
        try await HistoryMigration.enable(store: rig.store, journal: rig.journal, vault: rig.vault,
                                          setFlag: { rig.flags.values.append($0) }, afterCopies: afterCopies)
    }

    private func disable(_ rig: Rig, afterCopies: (@MainActor () -> Void)? = nil) async throws {
        try await HistoryMigration.disable(store: rig.store, journal: rig.journal, vault: rig.vault,
                                           setFlag: { rig.flags.values.append($0) }, afterCopies: afterCopies)
    }

    private func decodeHistory(_ rig: Rig) throws -> [TranscriptionItem] {
        try JSONDecoder().decode([TranscriptionItem].self, from: Data(contentsOf: historyURL(rig)))
    }

    private func journalLines(_ rig: Rig) -> [String] {
        let text = (try? String(contentsOf: journalURL(rig), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func mainHop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Включение

    @Test func enableSealsEverythingAndRemovesPlainFiles() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let plainJournal = journalLines(rig)

        try await enable(rig)
        rig.journal.flush()

        #expect(rig.flags.values == [true])
        #expect(rig.store.lockState == .locked)
        #expect(!FileManager.default.fileExists(atPath: historyURL(rig).path))
        for id in seed.audio.keys {
            #expect(!FileManager.default.fileExists(atPath: rig.store.audioURL(for: id).path))
            #expect(rig.vault.hasBlob(id: id, purpose: .audio))
        }
        for id in seed.timings.keys {
            #expect(!FileManager.default.fileExists(atPath: timingsURL(id, rig).path))
            #expect(rig.vault.hasBlob(id: id, purpose: .timings))
        }
        #expect(rig.vault.noteFileCount() == seed.items.count)
        // Журнал: строк столько же, каждая — конверт, записи читаются ключом.
        let sealedJournal = journalLines(rig)
        #expect(sealedJournal.count == plainJournal.count)
        #expect(try rig.journal.readAllRecords(key: rig.key).count == plainJournal.count)
        // Ни в одном файле нет открытого текста.
        let secret = Data("секрет".utf8)
        for url in allFiles(rig) {
            let data = try Data(contentsOf: url)
            #expect(data.range(of: secret) == nil, "открытый текст в \(url.lastPathComponent)")
        }
        #expect(leftovers(rig).isEmpty)
    }

    /// Подставная ошибка чтения: конверты не прочитались обратно, открытые файлы целы, флаг не тронут.
    @Test func enableVerifiesBeforeDeleting() async throws {
        let rig = makeRig(keyCreated: false)
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let before = plainFiles(rig)
        rig.key.agreeFails = true

        await #expect(throws: (any Error).self) { try await enable(rig) }

        #expect(plainFiles(rig) == before)
        #expect(envelopeCount(rig) == 0)
        #expect(rig.flags.values.isEmpty)
        #expect(rig.store.lockState == .off)
        #expect(rig.store.items == seed.items)
        #expect(leftovers(rig).isEmpty)
        // Ключ создан этим прогоном и конвертов на нём не осталось: он убран.
        #expect(rig.key.creates == 1)
        #expect(!rig.key.exists)
    }

    @Test func failureMidwayLeavesPlainFilesReadable() async throws {
        let rig = makeRig(keyCreated: false)
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let before = plainFiles(rig)
        // Заметки запечатаны, на первом аудио ключ пропадает.
        rig.key.publicLimit = seed.items.count

        await #expect(throws: (any Error).self) { try await enable(rig) }

        #expect(plainFiles(rig) == before)
        #expect(envelopeCount(rig) == 0)
        #expect(rig.flags.values.isEmpty)
        #expect(!rig.key.exists)
        let reopened = HistoryStore(directory: rig.directory)
        #expect(reopened.items == seed.items)
        for (id, bytes) in seed.audio { #expect(try reopened.audioData(for: id) == bytes) }
    }

    /// Папку конвертов нельзя создать: сбой на первом же шаге.
    @Test func unwritableNotesFolderLeavesPlainFiles() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let before = plainFiles(rig)
        try Data("не папка".utf8).write(to: rig.directory.appendingPathComponent("Notes"))

        await #expect(throws: (any Error).self) { try await enable(rig) }

        #expect(plainFiles(rig) == before)
        #expect(rig.flags.values.isEmpty)
        #expect(rig.store.lockState == .off)
    }

    /// Ключ, которому есть что держать, миграция не пересоздаёт и при сбое не убирает.
    @Test func abortKeepsKeyThatHoldsOtherEnvelopes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let orphan = note("сирота", date: "01.01.2026, 10:00", createdAt: nil)
        try rig.vault.writeNote(orphan)
        rig.key.agreeFails = true

        await #expect(throws: (any Error).self) { try await enable(rig) }

        #expect(rig.key.creates == 0)
        #expect(rig.key.destroys == 0)
        #expect(rig.key.exists)
        #expect(rig.vault.noteFileCount() == 1)
    }

    /// Заметка, надиктованная во время миграции, попадает в конверт, а не теряется.
    @Test func noteAddedDuringEnableIsSealed() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        var late: UUID?

        try await enable(rig) {
            if late == nil { late = rig.store.addNote(text: "поздняя") }
        }
        await rig.store.applyLockStateAndWait(.unlocked)

        #expect(rig.store.items.contains { $0.id == late })
        #expect(!FileManager.default.fileExists(atPath: historyURL(rig).path))
    }

    /// Заметки прошлых версий без `createdAt` сохраняют порядок массива после разлочки и выключения.
    @Test func orderPreservedThroughEnableUnlockAndDisable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            note("новая", date: "05.11.2026, 09:00", createdAt: base),
            note("старая четыре", date: "04.11.2026, 10:00", createdAt: nil),
            note("старая три", date: "04.11.2026, 10:00", createdAt: nil),
            note("старая два", date: "04.11.2026, 10:00", createdAt: nil),
            note("старая один", date: "03.11.2026, 08:00", createdAt: nil),
        ]
        let seed = try seed(rig, items: items)

        try await enable(rig)
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items.map(\.id) == seed.items.map(\.id))

        try await disable(rig)
        #expect(try decodeHistory(rig).map(\.id) == seed.items.map(\.id))
        #expect(rig.store.items.map(\.id) == seed.items.map(\.id))
    }

    // MARK: - Выключение

    @Test func disableRestoresSameNotes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let before = plainFiles(rig)

        try await enable(rig)
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items == seed.items)

        try await disable(rig)
        rig.journal.flush()

        #expect(rig.flags.values == [true, false])
        #expect(rig.store.lockState == .off)
        #expect(rig.store.items == seed.items)
        #expect(try decodeHistory(rig) == seed.items)
        #expect(envelopeCount(rig) == 0)
        #expect(leftovers(rig).isEmpty)
        // Аудио, тайминги и журнал байт в байт.
        let after = plainFiles(rig)
        for (name, data) in before where name != "history.json" { #expect(after[name] == data, "\(name)") }
        for (id, bytes) in seed.audio { #expect(try rig.store.audioData(for: id) == bytes) }
        for (id, bytes) in seed.timings { #expect(try Data(contentsOf: timingsURL(id, rig)) == bytes) }
    }

    @Test func disableFromLockedStateReadsEnvelopes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        #expect(rig.store.lockState == .locked)

        try await disable(rig)

        #expect(rig.store.items == seed.items)
        #expect(envelopeCount(rig) == 0)
    }

    @Test func largeAudioSurvivesRoundTripByteEqual() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let item = note("секрет звук", date: "01.11.2026, 10:00", createdAt: Date())
        try seed(rig, items: [item])
        let big = randomData(6 * 1024 * 1024)
        let source = rig.directory.appendingPathComponent("big.wav")
        try big.write(to: source)
        rig.store.storeAudio(for: item.id, from: source, move: true)

        try await enable(rig)
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(try rig.store.audioData(for: item.id) == big)

        try await disable(rig)
        #expect(try Data(contentsOf: rig.store.audioURL(for: item.id)) == big)
    }

    @Test func journalRoundTripKeepsEveryLine() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        // Повтор одной записи и обновление: строки не схлопываются.
        let id = UUID()
        rig.journal.recordInitial(id: id, rawText: "раз", durationSec: 1, targetAppName: nil)
        rig.journal.updateFinal(id: id, stageOneText: "два", finalText: "три", isFallback: false)
        rig.journal.flush()
        let original = try Data(contentsOf: journalURL(rig))
        let lineCount = journalLines(rig).count

        try await enable(rig)
        rig.journal.flush()
        let records = try rig.journal.readAllRecords(key: rig.key)
        #expect(records.count == lineCount)
        #expect(records.filter { $0.id == id }.count == 2)

        try await disable(rig)
        rig.journal.flush()
        #expect(try Data(contentsOf: journalURL(rig)) == original)
    }

    /// Заметка, ждущая конверта, при выключении уходит в `history.json` и не запечатывается потом.
    @Test func pendingSealIsDrainedOnDisable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try await enable(rig)
        rig.key.stopPublicKey()
        let stranded = rig.store.addNote(text: "ждёт конверта")
        rig.store.flush()
        await mainHop()
        #expect(rig.store.sealFailureCount == 1)

        try await disable(rig)
        rig.store.flush()
        await mainHop()

        #expect(try decodeHistory(rig).contains { $0.id == stranded })
        #expect(rig.store.items.contains { $0.id == stranded })
        #expect(rig.store.sealFailureCount == 0)
        #expect(rig.vault.noteFileCount() == 0)
    }

    @Test func noteAddedDuringDisableIsRestored() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try await enable(rig)
        var late: UUID?

        try await disable(rig) {
            if late == nil { late = rig.store.addNote(text: "поздняя под замком") }
        }

        #expect(rig.store.items.contains { $0.id == late })
        #expect(try decodeHistory(rig).contains { $0.id == late })
        #expect(rig.vault.noteFileCount() == 0)
    }

    /// Сбой расшифровки при выключении: конверты на месте, флаг не тронут.
    @Test func disableFailureKeepsEnvelopes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let envelopes = envelopeCount(rig)
        rig.key.agreeFails = true

        await #expect(throws: (any Error).self) { try await disable(rig) }

        #expect(rig.flags.values == [true])
        #expect(envelopeCount(rig) == envelopes)
        #expect(rig.store.lockState == .locked)
        #expect(!FileManager.default.fileExists(atPath: historyURL(rig).path))
        #expect(leftovers(rig).isEmpty)
        rig.key.agreeFails = false
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items == seed.items)
    }

    // MARK: - Следующий запуск

    /// Включение упало до флага: конверты рядом с живым `history.json` убираются, исходники целы.
    @Test func halfDoneEnvelopesAreCleanedOnNextLaunch() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let before = plainFiles(rig)
        for item in seed.items { try rig.vault.writeNote(item) }
        for (id, bytes) in seed.audio { try rig.vault.writeBlob(bytes, id: id, purpose: .audio) }
        for (id, bytes) in seed.timings { try rig.vault.writeBlob(bytes, id: id, purpose: .timings) }
        // Конверт без открытого двойника не трогается: удалять его не за чем.
        let orphan = note("сирота", date: "01.01.2026, 10:00", createdAt: nil)
        try rig.vault.writeNote(orphan)
        try Data("x".utf8).write(to: rig.directory.appendingPathComponent("transcript_journal.jsonl.migrating"))

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                         setLockEnabled: { rig.flags.values.append($0) })

        #expect(plainFiles(rig) == before)
        #expect(rig.vault.noteFileCount() == 1)
        for id in seed.audio.keys { #expect(!rig.vault.hasBlob(id: id, purpose: .audio)) }
        for id in seed.timings.keys { #expect(!rig.vault.hasBlob(id: id, purpose: .timings)) }
        #expect(rig.flags.values.isEmpty)
        #expect(leftovers(rig).isEmpty)
    }

    /// Review Focus 3: замок включён, `Notes/` пуст, `history.json` остался от сбоя. Открытый файл побеждает.
    @Test func plainHistoryFileWinsWhenNotesFolderEmpty() async throws {
        let rig = makeRig(keyCreated: false)
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let before = plainFiles(rig)

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true,
                                                      setLockEnabled: { rig.flags.values.append($0) })

        #expect(notice == .lockTurnedOff)
        #expect(rig.flags.values == [false])
        #expect(plainFiles(rig) == before)
        let reopened = HistoryStore(directory: rig.directory)
        #expect(reopened.items == seed.items)
    }

    /// Замок включён и конверты есть: лишний `history.json` не удаляется, а при выключении вливается.
    @Test func strayPlainHistoryIsKeptAndMergedOnDisable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let stray = note("из старого файла", date: "01.10.2026, 10:00", createdAt: nil)
        let strayData = try JSONEncoder().encode([stray])
        try strayData.write(to: historyURL(rig))

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true,
                                                      setLockEnabled: { rig.flags.values.append($0) })
        #expect(notice == .leftoverPlainHistory)
        #expect(rig.flags.values == [true])
        #expect(try Data(contentsOf: historyURL(rig)) == strayData)

        try await disable(rig)
        let restored = try decodeHistory(rig)
        #expect(restored.contains(stray))
        #expect(Set(restored.map(\.id)) == Set(seed.items.map(\.id) + [stray.id]))
    }

    // MARK: - Лог при включении

    /// Лог с текстом диктовки, записанным до замка.
    private func seededLogger(_ rig: Rig) async -> AppLogger {
        let logger = AppLogger(directory: rig.directory)
        logger.info("Test", "Распознано: «секрет из лога»")
        logger.flush()
        await mainHop()
        return logger
    }

    private func logHasSecret(_ logger: AppLogger) async -> Bool {
        logger.flush()
        await mainHop()
        let file = logger.logFileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return file.contains("секрет из лога") || logger.entries.contains { $0.message.contains("секрет из лога") }
    }

    @Test func enableClearsLog() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let logger = await seededLogger(rig)
        #expect(await logHasSecret(logger))

        try await HistoryMigration.enable(store: rig.store, journal: rig.journal, vault: rig.vault,
                                          setFlag: { rig.flags.values.append($0) }, logger: logger)

        #expect(rig.flags.values == [true])
        #expect(await logHasSecret(logger) == false)
    }

    @Test func failedEnableKeepsLog() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let logger = await seededLogger(rig)
        rig.key.agreeFails = true

        await #expect(throws: (any Error).self) {
            try await HistoryMigration.enable(store: rig.store, journal: rig.journal, vault: rig.vault,
                                              setFlag: { rig.flags.values.append($0) }, logger: logger)
        }

        #expect(rig.flags.values.isEmpty)
        #expect(await logHasSecret(logger))
    }

    @Test func launchFinishingEnableClearsLog() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        for item in seed.items { try rig.vault.writeNote(item) }
        try HistoryMigration.writeMarker(.enable, in: rig.directory)
        let logger = await seededLogger(rig)

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                         setLockEnabled: { rig.flags.values.append($0) }, logger: logger)

        #expect(rig.flags.values == [true])
        #expect(await logHasSecret(logger) == false)
    }

    /// Выключение лог не трогает.
    @Test func launchWithoutEnableMarkerKeepsLog() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let logger = await seededLogger(rig)

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                         setLockEnabled: { rig.flags.values.append($0) }, logger: logger)

        #expect(await logHasSecret(logger))
    }

    /// Сбой после фиксации включения: запуск доводит до конца и поднимает флаг.
    @Test func committedEnableIsFinishedOnNextLaunch() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let plainJournal = journalLines(rig)
        for item in seed.items { try rig.vault.writeNote(item) }
        for (id, bytes) in seed.audio { try rig.vault.writeBlob(bytes, id: id, purpose: .audio) }
        for (id, bytes) in seed.timings { try rig.vault.writeBlob(bytes, id: id, purpose: .timings) }
        try HistoryMigration.writeMarker(.enable, in: rig.directory)

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                         setLockEnabled: { rig.flags.values.append($0) })

        #expect(rig.flags.values == [true])
        #expect(plainFiles(rig).keys.filter { $0 != "transcript_journal.jsonl" }.isEmpty)
        #expect(rig.vault.noteFileCount() == seed.items.count)
        #expect(leftovers(rig).isEmpty)
        // Сбой пришёлся до журнала: запуск запечатал его по публичному ключу.
        #expect(!journalLines(rig).isEmpty)
        #expect(journalLines(rig).allSatisfy(HistoryMigration.isSealedLine))
        #expect(try rig.journal.readAllRecords(key: rig.key).count == plainJournal.count)
    }

    /// Не каждая заметка `history.json` лежит конвертом: открытый файл остаётся.
    @Test func committedEnableKeepsUncoveredHistory() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try rig.vault.writeNote(seed.items[0])
        try HistoryMigration.writeMarker(.enable, in: rig.directory)

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                                      setLockEnabled: { rig.flags.values.append($0) })

        #expect(FileManager.default.fileExists(atPath: historyURL(rig).path))
        #expect(notice == .leftoverPlainHistory)
        #expect(rig.flags.values == [true])
        #expect(leftovers(rig).isEmpty)
    }

    /// Флаг уже опущен, метка осталась: запуск переименовывает копии и убирает конверты.
    @Test func committedDisableIsFinishedOnNextLaunch() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        for item in seed.items { try rig.vault.writeNote(item) }
        for (id, bytes) in seed.audio { try rig.vault.writeBlob(bytes, id: id, purpose: .audio) }
        let fm = FileManager.default
        try fm.moveItem(at: historyURL(rig), to: historyURL(rig).appendingPathExtension("restore"))
        for id in seed.audio.keys {
            let plain = rig.store.audioURL(for: id)
            try fm.moveItem(at: plain, to: plain.appendingPathExtension("restore"))
        }
        try HistoryMigration.writeMarker(.disable, in: rig.directory)

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                         setLockEnabled: { rig.flags.values.append($0) })

        #expect(rig.flags.values.isEmpty)
        #expect(try decodeHistory(rig) == seed.items)
        for (id, bytes) in seed.audio { #expect(try Data(contentsOf: rig.store.audioURL(for: id)) == bytes) }
        #expect(rig.vault.noteFileCount() == 0)
        for id in seed.audio.keys { #expect(!rig.vault.hasBlob(id: id, purpose: .audio)) }
        #expect(leftovers(rig).isEmpty)
    }

    /// Прерванное выключение до фиксации: копии убираются, конверты целы, флаг остаётся.
    @Test func uncommittedDisableCopiesAreDropped() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        try Data("[]".utf8).write(to: historyURL(rig).appendingPathExtension("restore"))
        let id = try #require(seed.audio.keys.first)
        try Data("копия".utf8).write(to: rig.store.audioURL(for: id).appendingPathExtension("restore"))

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true,
                                         setLockEnabled: { rig.flags.values.append($0) })

        #expect(rig.flags.values == [true])
        #expect(leftovers(rig).isEmpty)
        #expect(rig.vault.hasBlob(id: id, purpose: .audio))
        #expect(rig.vault.noteFileCount() == seed.items.count)
    }

    // MARK: - Журнал, ключ и откат

    /// Метка `enableJournal` держится, пока журнал не запечатан, и снимается, когда ключ снова есть.
    @Test func journalMarkerIsRetriedUntilSealed() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try HistoryMigration.writeMarker(.enableJournal, in: rig.directory)
        rig.key.publicLimit = 0

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })
        #expect(leftovers(rig) == [HistoryMigration.markerName])
        #expect(!journalLines(rig).contains(where: HistoryMigration.isSealedLine))

        rig.key.publicLimit = Int.max
        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })
        #expect(leftovers(rig).isEmpty)
        #expect(journalLines(rig).allSatisfy(HistoryMigration.isSealedLine))
    }

    /// Метка `enableJournal` не прячет открытую историю: уведомление об остатке сохраняется.
    @Test func journalMarkerReportsRetainedPlainHistory() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try HistoryMigration.writeMarker(.enableJournal, in: rig.directory)

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })

        #expect(notice == .leftoverPlainHistory)
    }

    /// Журнал не открылся при выключении: замок остаётся, журнал запечатан, заметки читаются.
    @Test func failedDisableJournalStepKeepsLockOn() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        rig.journal.flush()
        let envelopes = envelopeCount(rig)
        // Папка на месте копии журнала: запись копии падает.
        try FileManager.default.createDirectory(at: journalURL(rig).appendingPathExtension("migrating"),
                                                withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) { try await disable(rig) }
        rig.journal.flush()

        #expect(rig.flags.values == [true])
        #expect(rig.store.lockState == .locked)
        #expect(journalLines(rig).allSatisfy(HistoryMigration.isSealedLine))
        #expect(!FileManager.default.fileExists(atPath: historyURL(rig).path))
        #expect(envelopeCount(rig) == envelopes)
        #expect(leftovers(rig).isEmpty)
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items == seed.items)

        // Повтор проходит.
        try await disable(rig)
        #expect(rig.flags.values == [true, false])
        #expect(try decodeHistory(rig) == seed.items)
    }

    /// Запуск с меткой `disable` и включённым флагом: откат, замок остаётся, заметки читаются.
    @Test func disableMarkerWithFlagOnRollsBack() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let plainJournal = try Data(contentsOf: journalURL(rig))
        try await enable(rig)
        rig.journal.flush()
        // Сбой после перехода и открытия журнала, до флага.
        let data = try JSONEncoder().encode(seed.items)
        try data.write(to: historyURL(rig))
        try plainJournal.write(to: journalURL(rig))
        try HistoryMigration.writeMarker(.disable, in: rig.directory, digest: HistoryMigration.digest(data))

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true,
                                                      setLockEnabled: { rig.flags.values.append($0) })

        #expect(notice == nil)
        #expect(rig.flags.values == [true])
        #expect(!FileManager.default.fileExists(atPath: historyURL(rig).path))
        #expect(leftovers(rig).isEmpty)
        #expect(journalLines(rig).allSatisfy(HistoryMigration.isSealedLine))
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items == seed.items)
    }

    /// Откат не удаляет открытую историю, в которой есть заметка без конверта.
    @Test func rollbackKeepsPlainHistoryWithUnsealedNote() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let extra = note("только открытая", date: "10.11.2026, 10:00", createdAt: Date())
        let data = try JSONEncoder().encode([extra] + seed.items)
        try data.write(to: historyURL(rig))
        try HistoryMigration.writeMarker(.disable, in: rig.directory, digest: HistoryMigration.digest(data))

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })

        #expect(notice == .leftoverPlainHistory)
        #expect(try Data(contentsOf: historyURL(rig)) == data)
        #expect(leftovers(rig).isEmpty)
    }

    /// Все заметки удалены под замком, рядом остался старый `history.json`, ключ есть:
    /// замок не выключается и удалённое не возвращается.
    @Test func leftoverPlainHistoryWithKeyDoesNotTurnLockOff() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        await rig.store.applyLockStateAndWait(.unlocked)
        while !rig.store.items.isEmpty { rig.store.deleteItem(at: 0) }
        rig.store.flush()
        #expect(rig.vault.noteFileCount() == 0)
        let leftover = try JSONEncoder().encode(seed.items)
        try leftover.write(to: historyURL(rig))

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true,
                                                      setLockEnabled: { rig.flags.values.append($0) })

        #expect(notice == .leftoverPlainHistory)
        #expect(rig.flags.values == [true])
        #expect(try Data(contentsOf: historyURL(rig)) == leftover)
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items.isEmpty)
    }

    /// Ключ с запечатанными строками журнала переживает следующее включение, строки открываются.
    @Test func existingKeyWithSealedJournalIsReused() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let old = UUID()
        rig.journal.setSealing(.sealed(key: rig.key))
        rig.journal.recordInitial(id: old, rawText: "старый секрет", durationSec: 1, targetAppName: nil)
        rig.journal.setSealing(.off)
        rig.journal.flush()
        try seed(rig)

        try await enable(rig)
        rig.journal.flush()

        #expect(rig.key.creates == 0)
        #expect(rig.key.destroys == 0)
        let records = try rig.journal.readAllRecords(key: rig.key)
        #expect(records.contains { $0.id == old && $0.rawText == "старый секрет" })
        #expect(journalLines(rig).allSatisfy(HistoryMigration.isSealedLine))
    }

    /// Порченый конверт остаётся после выключения, но метку не держит: следующее включение проходит.
    @Test func corruptEnvelopeDoesNotBlockNextEnable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try await enable(rig)
        let corrupt = rig.directory.appendingPathComponent("Notes/\(UUID().uuidString).note")
        try Data("порча".utf8).write(to: corrupt)

        try await disable(rig)
        #expect(leftovers(rig).isEmpty)
        #expect(FileManager.default.fileExists(atPath: corrupt.path))

        try await enable(rig)
        #expect(rig.flags.values == [true, false, true])
        #expect(leftovers(rig).isEmpty)
    }

    // MARK: - Откат по содержимому и нечитаемый ключ

    /// Правка X' ждёт конверта рядом со старым `X.note`. Под замком, без конверта, правку пишет
    /// только `pendingSeal`.
    private func strandEdit(_ rig: Rig, seed: Seed) async throws -> TranscriptionItem {
        try await enable(rig)
        await rig.store.applyLockStateAndWait(.unlocked)
        rig.key.stopPublicKey()
        let id = seed.items[0].id
        rig.store.appendTextToNote(id: id, text: "правка без конверта")
        rig.store.flush()
        await mainHop()
        #expect(rig.store.sealFailureCount == 1)
        return try #require(rig.store.items.first { $0.id == id })
    }

    @Test func pendingEditSurvivesFailedJournalStep() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let edited = try await strandEdit(rig, seed: seed)
        try FileManager.default.createDirectory(at: journalURL(rig).appendingPathExtension("migrating"),
                                                withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) { try await disable(rig) }

        #expect(rig.flags.values == [true])
        #expect(rig.store.lockState == .locked)
        #expect(try decodeHistory(rig).contains(edited))
    }

    /// Сбой сразу после перехода: состояние диска того момента и уборка запуска.
    @Test func pendingEditSurvivesCrashAfterDeactivate() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let edited = try await strandEdit(rig, seed: seed)
        try FileManager.default.createDirectory(at: journalURL(rig).appendingPathExtension("migrating"),
                                                withIntermediateDirectories: true)
        let marker = rig.directory.appendingPathComponent(HistoryMigration.markerName)
        var snapshot: (marker: Data, history: Data)?

        await #expect(throws: (any Error).self) {
            try await HistoryMigration.disable(
                store: rig.store, journal: rig.journal, vault: rig.vault,
                deactivate: {
                    rig.journal.setSealing(.off)
                    rig.store.applyLockState(.off)
                    rig.store.attach(vault: nil)
                    if let m = FileManager.default.contents(atPath: marker.path),
                       let h = FileManager.default.contents(atPath: historyURL(rig).path) {
                        snapshot = (m, h)
                    }
                },
                setFlag: { rig.flags.values.append($0) })
        }
        let state = try #require(snapshot)
        try state.marker.write(to: marker)
        try state.history.write(to: historyURL(rig))

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })

        #expect(notice == .leftoverPlainHistory)
        #expect(try decodeHistory(rig).contains(edited))
    }

    /// Те же id, другие байты: откат файл не удаляет.
    @Test func rollbackKeepsChangedPlainHistoryWithSameIDs() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let placed = try JSONEncoder().encode(seed.items)
        let changed = try JSONEncoder().encode([seed.items[0].withText("правка после перехода")] + seed.items.dropFirst())
        try changed.write(to: historyURL(rig))
        try HistoryMigration.writeMarker(.disable, in: rig.directory, digest: HistoryMigration.digest(placed))

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })

        #expect(notice == .leftoverPlainHistory)
        #expect(try Data(contentsOf: historyURL(rig)) == changed)
    }

    /// Тайминги с другими байтами рядом с конвертом откат не удаляет.
    @Test func rollbackKeepsChangedTimings() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let id = try #require(seed.timings.keys.first)
        let changed = Data("[{\"word\":\"другое\"}]".utf8)
        try changed.write(to: timingsURL(id, rig))
        try HistoryMigration.writeMarker(.disable, in: rig.directory, digest: nil)

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })

        #expect(try Data(contentsOf: timingsURL(id, rig)) == changed)
        #expect(rig.vault.hasBlob(id: id, purpose: .timings))
    }

    /// Ключ есть, но не читается и ничего не держит: создаётся заново один раз, включение проходит.
    @Test func unreadableKeyWithoutDataIsReplacedOnce() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        rig.key.broken = true

        try await enable(rig)

        #expect(rig.key.creates == 1)
        #expect(rig.flags.values == [true])
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items == seed.items)
    }

    /// Пустая история: нечитаемый ключ ловит пробная сверка.
    @Test func unreadableKeyIsReplacedEvenWithEmptyHistory() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        rig.key.broken = true

        try await enable(rig)

        #expect(rig.key.creates == 1)
        #expect(!rig.key.broken)
        #expect(rig.flags.values == [true])
    }

    /// Нечитаемый ключ держит запечатанную строку журнала: не пересоздаётся, включение падает, ключ цел.
    @Test func unreadableKeyHoldingJournalIsKept() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        rig.journal.setSealing(.sealed(key: rig.key))
        rig.journal.recordInitial(id: UUID(), rawText: "старое", durationSec: 1, targetAppName: nil)
        rig.journal.setSealing(.off)
        rig.journal.flush()
        try seed(rig)
        let before = plainFiles(rig)
        rig.key.broken = true

        await #expect(throws: HistoryKeyError.self) { try await enable(rig) }

        #expect(rig.key.creates == 0)
        #expect(rig.key.destroys == 0)
        #expect(rig.key.exists)
        #expect(plainFiles(rig) == before)
        #expect(rig.flags.values.isEmpty)
    }

    /// Нечитаемый ключ держит конверт-сироту: не пересоздаётся.
    @Test func unreadableKeyHoldingOrphanIsKept() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try rig.vault.writeNote(note("сирота", date: "01.01.2026, 10:00", createdAt: nil))
        rig.key.broken = true

        await #expect(throws: HistoryKeyError.self) { try await enable(rig) }

        #expect(rig.key.creates == 0)
        #expect(rig.key.exists)
        #expect(rig.vault.noteFileCount() == 1)
    }

    /// Ключ остаётся нечитаемым и после замены: одна замена, без петли.
    @Test func keyReplacementHappensAtMostOnce() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        rig.key.broken = true
        rig.key.agreeFails = true

        await #expect(throws: (any Error).self) { try await enable(rig) }

        #expect(rig.key.creates == 1)
        #expect(rig.flags.values.isEmpty)
    }

    // MARK: - Две версии заметки

    /// После отката с правкой X' следующее выключение оставляет и X, и X'.
    @Test func rollbackEditSurvivesNextDisable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let original = seed.items[0]
        let edited = try await strandEdit(rig, seed: seed)
        try FileManager.default.createDirectory(at: journalURL(rig).appendingPathExtension("migrating"),
                                                withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await disable(rig) }
        #expect(try decodeHistory(rig).contains(edited))
        rig.key.publicLimit = Int.max

        try await disable(rig)

        let final = try decodeHistory(rig)
        // Обе версии на месте. Прежняя версия могла остаться и копией с новым id: дубль лучше потери.
        #expect(final.contains { $0.text == original.text })
        #expect(final.contains { $0.text == edited.text })
        for item in seed.items.dropFirst() { #expect(final.contains(item)) }
        #expect(rig.vault.noteFileCount() == 0)
    }

    /// Оставшаяся копия истории с заметкой не из конвертов переживает следующее выключение.
    @Test func leftoverRestoreSurvivesDisable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let lone = note("только в копии", date: "12.11.2026, 10:00", createdAt: Date())
        try JSONEncoder().encode([lone]).write(to: historyURL(rig).appendingPathExtension("restore"))

        try await disable(rig)

        let final = try decodeHistory(rig)
        #expect(final.contains(lone))
        #expect(final.count == seed.items.count + 1)
        #expect(leftovers(rig).isEmpty)
    }

    /// Та же заметка в конверте и в открытом файле сливается в одну.
    @Test func identicalDuplicatesCollapse() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        try JSONEncoder().encode([seed.items[1]]).write(to: historyURL(rig))
        try JSONEncoder().encode([seed.items[2]]).write(to: historyURL(rig).appendingPathExtension("restore"))

        try await disable(rig)

        #expect(try decodeHistory(rig) == seed.items)
    }

    /// Разные версии одной заметки при слиянии: обе остаются, вторая рядом с первой.
    @Test func mergeKeepsBothVersionsSideBySide() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let x = note("икс", date: "01.11.2026, 10:00", createdAt: base)
        let other = note("другая", date: "01.11.2026, 10:00", createdAt: base.addingTimeInterval(-30))
        let edited = x.withText("икс правка")
        var sameButTime = x
        sameButTime.createdAt = base.addingTimeInterval(5)

        let merged = HistoryMigration.mergeKeepingBoth([[x, other], [edited, sameButTime]])

        try #require(merged.count == 3)
        #expect(merged[0] == x)
        #expect(merged[1].text == "икс правка" && merged[1].id != x.id)
        #expect(merged[2] == other)
    }

    /// Открытые файлы рядом с конвертами, и журнал тоже: ни в одном нет текста заметок из конвертов.
    private func plainTextLeaks(_ rig: Rig) throws -> [String] {
        let secret = Data("секрет".utf8)
        return try allFiles(rig)
            .filter { !["note", "sealed"].contains($0.pathExtension) }
            .filter { try Data(contentsOf: $0).range(of: secret) != nil }
            .map(\.lastPathComponent)
    }

    /// Оставшаяся копия с заметкой не из конвертов: её байты, расшифрованного рядом нет.
    private func writeLeftover(_ rig: Rig) throws -> (url: URL, bytes: Data, note: TranscriptionItem) {
        let lone = note("только в копии", date: "12.11.2026, 10:00", createdAt: Date())
        let url = historyURL(rig).appendingPathExtension("restore")
        let bytes = try JSONEncoder().encode([lone])
        try bytes.write(to: url)
        return (url, bytes, lone)
    }

    /// Отмена из-за сбоя записи копии аудио: оставшаяся копия байт в байт прежняя, расшифрованного нет.
    @Test func abortKeepsPreexistingRestoreBytes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        try await enable(rig)
        let leftover = try writeLeftover(rig)
        let audioID = try #require(seed.audio.keys.first)
        try FileManager.default.createDirectory(at: rig.store.audioURL(for: audioID).appendingPathExtension("restore"),
                                                withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) { try await disable(rig) }

        #expect(try Data(contentsOf: leftover.url) == leftover.bytes)
        #expect(try plainTextLeaks(rig).isEmpty)
        #expect(rig.store.lockState == .locked)
    }

    /// Отмена из-за истории, менявшейся на каждой попытке: то же.
    @Test func busyAbortKeepsPreexistingRestoreBytes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try await enable(rig)
        let leftover = try writeLeftover(rig)

        await #expect(throws: HistoryMigrationError.busy) {
            try await disable(rig) { rig.store.addNote(text: "каждый раз новая") }
        }

        #expect(try Data(contentsOf: leftover.url) == leftover.bytes)
        #expect(try plainTextLeaks(rig).isEmpty)
    }

    /// Сбой сразу после записи своей копии: запуск не оставляет расшифрованного сверх прежней копии.
    @Test func crashAfterCopyLeavesNoDecryptedHistory() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try await enable(rig)
        let leftover = try writeLeftover(rig)
        let candidate = historyURL(rig).appendingPathExtension("restoring")
        var written: Data?

        await #expect(throws: HistoryMigrationError.busy) {
            try await disable(rig) {
                if written == nil { written = FileManager.default.contents(atPath: candidate.path) }
                rig.store.addNote(text: "каждый раз новая")
            }
        }
        // Диск в момент сбоя: своя копия прогона лежит рядом.
        let copy = try #require(written)
        #expect(copy.range(of: Data("секрет".utf8)) != nil)
        try copy.write(to: candidate)

        HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: true, setLockEnabled: { _ in })

        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(try plainTextLeaks(rig).isEmpty)
        let kept = [leftover.url, historyURL(rig)].compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(kept == [leftover.bytes])
    }

    /// Правка X', ждавшая конверта, заменяет конверт X: одна заметка, без дубля.
    @Test func pendingEditSupersedesSealedVersion() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let edited = try await strandEdit(rig, seed: seed)

        try await disable(rig)

        let final = try decodeHistory(rig)
        #expect(final.filter { $0.id == edited.id } == [edited])
        #expect(!final.contains { $0.text == seed.items[0].text })
        #expect(final.count == seed.items.count)
    }

    /// Обрезанный файл публичного ключа без данных: ключ создаётся заново, включение проходит.
    @Test func truncatedPublicKeyWithoutDataIsReplaced() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        rig.key.truncatedPublic = true

        try await enable(rig)

        #expect(rig.key.creates == 1)
        #expect(rig.flags.values == [true])
        await rig.store.applyLockStateAndWait(.unlocked)
        #expect(rig.store.items == seed.items)
    }

    /// Обрезанный публичный ключ рядом с запечатанной строкой журнала: ключ не пересоздаётся.
    @Test func truncatedPublicKeyHoldingJournalIsKept() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        rig.journal.setSealing(.sealed(key: rig.key))
        rig.journal.recordInitial(id: UUID(), rawText: "старое", durationSec: 1, targetAppName: nil)
        rig.journal.setSealing(.off)
        rig.journal.flush()
        try seed(rig)
        rig.key.truncatedPublic = true

        await #expect(throws: (any Error).self) { try await enable(rig) }

        #expect(rig.key.creates == 0)
        #expect(rig.key.exists)
        #expect(rig.flags.values.isEmpty)
    }

    /// Чужая точка публичного ключа на пустой истории: пробная сверка ловит её, ключ создаётся заново.
    @Test func wrongPublicKeyCaughtByProbe() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        rig.key.wrongPublic = true

        try await enable(rig)

        #expect(rig.key.creates == 1)
        #expect(rig.flags.values == [true])
    }

    // MARK: - Закрытия настроек

    private func makeMigrator(_ rig: Rig, defaults: UserDefaults) -> HistoryLockMigrator {
        HistoryLockMigrator(store: rig.store, journal: rig.journal, vault: rig.vault,
                            setFlag: { AppPreferences.setHistoryLockEnabled($0, in: defaults) })
    }

    private func makeDefaults() -> UserDefaults {
        let name = "HistoryMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func settingsShowStoredFlagAfterEnableAndDisable() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let defaults = makeDefaults()
        let migrator = makeMigrator(rig, defaults: defaults)
        let model = HistoryLockSettingsModel(isOn: false, presence: TestPresence(),
                                             onEnable: { try await migrator.enable() },
                                             onDisable: { try await migrator.disable() })

        model.requestToggle(to: true)
        await model.confirm()
        #expect(model.isOn == true)
        #expect(model.isOn == AppPreferences.historyLockEnabled(in: defaults))

        model.requestToggle(to: false)
        await model.confirm()
        #expect(model.isOn == false)
        #expect(model.isOn == AppPreferences.historyLockEnabled(in: defaults))
    }

    @Test func failedEnableLeavesStoredFlagAndSwitchOff() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        let defaults = makeDefaults()
        let migrator = makeMigrator(rig, defaults: defaults)
        let model = HistoryLockSettingsModel(isOn: false, presence: TestPresence(),
                                             onEnable: { try await migrator.enable() })
        rig.key.agreeFails = true

        model.requestToggle(to: true)
        await model.confirm()

        #expect(model.isOn == false)
        #expect(defaults.object(forKey: "historyLockEnabled") == nil)
        #expect(model.errorMessage != nil)
    }

    /// Проводка с координатором: после включения замок заперт, после разлочки заметки на месте.
    @Test func migratorDrivesCoordinator() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let coordinator = HistoryLockCoordinator(
            enabled: false, store: rig.store, journal: rig.journal, key: rig.key, presence: TestPresence(),
            directory: rig.directory, erase: { [] }, resetSession: {})
        let defaults = makeDefaults()
        let migrator = HistoryLockMigrator(coordinator: coordinator, store: rig.store, journal: rig.journal,
                                           directory: rig.directory,
                                           setFlag: { AppPreferences.setHistoryLockEnabled($0, in: defaults) })

        try await migrator.enable()
        #expect(coordinator.state == .locked)
        #expect(AppPreferences.historyLockEnabled(in: defaults))

        await coordinator.unlock()
        for _ in 0..<300 where rig.store.items.count != seed.items.count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(rig.store.items == seed.items)

        try await migrator.disable()
        #expect(coordinator.state == .off)
        #expect(rig.store.items == seed.items)
        #expect(!AppPreferences.historyLockEnabled(in: defaults))
    }
    // MARK: - Замечания ревью

    /// Флаг опускается раньше уборки конвертов: сбой посреди неё запуск доведёт, а не откатит.
    @Test func disableLowersFlagBeforeRemovingEnvelopes() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        try seed(rig)
        try await enable(rig)
        var notesWhenFlagLowered = -1

        try await HistoryMigration.disable(store: rig.store, journal: rig.journal, vault: rig.vault,
                                           setFlag: {
                                               notesWhenFlagLowered = rig.vault.noteFileCount()
                                               rig.flags.values.append($0)
                                           })

        #expect(rig.flags.values.suffix(1) == [false])
        #expect(notesWhenFlagLowered > 0)
        #expect(rig.vault.noteFileCount() == 0)
    }

    /// Метка включения, а ключа уже нет: конверты не открыть, открытая история остаётся единственной копией.
    @Test func enableMarkerWithoutKeyKeepsPlainHistory() async throws {
        let rig = makeRig()
        defer { cleanup(rig) }
        let seed = try seed(rig)
        let before = plainFiles(rig)
        for item in seed.items { try rig.vault.writeNote(item) }
        try HistoryMigration.writeMarker(.enable, in: rig.directory)
        try rig.key.destroy()

        let notice = HistoryMigration.cleanupHalfDone(vault: rig.vault, lockEnabled: false,
                                                      setLockEnabled: { rig.flags.values.append($0) })

        #expect(notice == nil)
        #expect(plainFiles(rig) == before)
        #expect(rig.flags.values.isEmpty)
        #expect(leftovers(rig).isEmpty)
    }

    /// Журнал, который не читается, не заменяется пустой копией.
    @Test func journalRewriteRefusesUnreadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalUnreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: directory.appendingPathComponent("j.jsonl").path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("j.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        #expect(throws: (any Error).self) { try TranscriptJournal.rewrite([url]) { $0 } }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == Data("{\"a\":1}\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension(TranscriptJournal.migrationSuffix).path))
    }
}
