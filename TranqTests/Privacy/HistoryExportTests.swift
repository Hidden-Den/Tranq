//
//  HistoryExportTests.swift
//  TranqTests
//

import CryptoKit
import Foundation
import Testing
@testable import Tranq

/// Ключ, который перестаёт согласовываться после `allowed` успешных вызовов.
private final class CountdownKey: HistoryKeyProviding {
    let inner = TestHistoryKey()
    var allowed: Int
    private let lock = NSLock()

    init(allowed: Int) { self.allowed = allowed }

    var exists: Bool { inner.exists }
    var publicKey: Data { get throws { try inner.publicKey } }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        lock.lock()
        let left = allowed
        allowed -= 1
        lock.unlock()
        if left <= 0 { throw HistoryKeyError.denied }
        return try inner.agree(withEphemeral: ephemeral)
    }

    func create() throws { try inner.create() }
    func destroy() throws { try inner.destroy() }
}

/// Выгрузка копии: открытый JSON, расшифрованное аудио, отказ при замке, чистка после сбоя.
@MainActor
struct HistoryExportTests {

    private struct Rig {
        let directory: URL
        let target: URL
        let vault: HistoryVault
        let store: HistoryStore
        let items: [TranscriptionItem]
        let audio: [UUID: Data]
        let timings: [UUID: Data]
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// Разлоченное хранилище: три заметки, у первых двух аудио, у первой ещё тайминги.
    private func makeRig(key: HistoryKeyProviding = TestHistoryKey(),
                         state: HistoryLockState = .unlocked) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryExportTests-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = directory.appendingPathComponent("data", isDirectory: true)
        let vault = HistoryVault(directory: data, key: key)
        let store = HistoryStore(directory: data, saveDelay: 0, vault: vault, lockState: .locked)

        var items: [TranscriptionItem] = []
        var audio: [UUID: Data] = [:]
        var timings: [UUID: Data] = [:]
        for index in 0..<3 {
            let item = TranscriptionItem(date: "19.11.2026, 10:0\(index)", text: "секрет \(index)",
                                         duration: "0:0\(index)", isUnread: false,
                                         spokenText: "ну секрет \(index)",
                                         createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            store.insert(item)
            items.append(item)
            if index < 2 {
                let bytes = randomData(48 * 1024)
                let source = directory.appendingPathComponent("src-\(index).wav")
                try bytes.write(to: source)
                store.storeAudio(for: item.id, from: source, move: true)
                audio[item.id] = bytes
            }
            if index == 0 {
                let json = Data(#"[{"start":0,"end":1,"word":"секрет"}]"#.utf8)
                try vault.writeBlob(json, id: item.id, purpose: .timings)
                timings[item.id] = json
            }
        }
        store.flush()
        store.waitForIO()
        if state != .locked { await store.applyLockStateAndWait(state) }
        return Rig(directory: directory, target: target, vault: vault, store: store,
                   items: items, audio: audio, timings: timings)
    }

    private func cleanup(_ rig: Rig) {
        rig.store.flush()
        try? FileManager.default.removeItem(at: rig.directory)
    }

    private func exportFolders(_ rig: Rig) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: rig.target, includingPropertiesForKeys: nil)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func exportWritesPlainNotesAndAudio() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }

        let result = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)

        #expect(result.exportedNotes == 3)
        #expect(result.exportedAudio == 2)
        #expect(result.skippedAudio == 0)
        let folders = try exportFolders(rig)
        #expect(folders.count == 1)
        #expect(folders[0].lastPathComponent == result.folder.lastPathComponent)
        #expect(folders[0].lastPathComponent.hasPrefix("Tranq history "))
        // В выбранную папку ничего россыпью: только одна подпапка.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.target.path).count == 1)

        let json = try String(contentsOf: result.folder.appendingPathComponent("history.json"), encoding: .utf8)
        // Открытым текстом, без конвертов.
        #expect(json.contains("секрет 0"))
        let audioFolder = result.folder.appendingPathComponent("Audio")
        let names = try FileManager.default.contentsOfDirectory(atPath: audioFolder.path).sorted()
        let expected = (rig.audio.keys.map { "\($0.uuidString).wav" }
                        + rig.timings.keys.map { "\($0.uuidString).segments.json" }).sorted()
        #expect(names == expected)
        // Аудио совпадает с оригиналом до байта, тайминги тоже.
        for (id, bytes) in rig.audio {
            #expect(try Data(contentsOf: audioFolder.appendingPathComponent("\(id.uuidString).wav")) == bytes)
        }
        for (id, bytes) in rig.timings {
            #expect(try Data(contentsOf: audioFolder.appendingPathComponent("\(id.uuidString).segments.json")) == bytes)
        }
    }

    @Test func exportedNotesDecodeAsTranscriptionItems() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }

        let result = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)

        let data = try Data(contentsOf: result.folder.appendingPathComponent("history.json"))
        let decoded = try JSONDecoder().decode([TranscriptionItem].self, from: data)
        #expect(decoded == rig.store.items)
        #expect(Set(decoded.map(\.id)) == Set(rig.items.map(\.id)))
        #expect(decoded.first { $0.id == rig.items[1].id }?.spokenText == "ну секрет 1")
    }

    @Test func exportRefusesWhileLocked() async throws {
        for state in [HistoryLockState.locked, .keyUnavailable, .off] {
            let rig = try await makeRig(state: state)
            defer { cleanup(rig) }

            await #expect(throws: HistoryExportError.notUnlocked) {
                try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)
            }
            #expect(try exportFolders(rig).isEmpty)
        }
    }

    @Test func exportNeverOverwritesExistingFolder() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault,
                                                          to: rig.target, now: now)
        let marker = first.folder.appendingPathComponent("marker.txt")
        try Data("мой файл".utf8).write(to: marker)
        let second = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault,
                                                           to: rig.target, now: now)
        let third = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault,
                                                          to: rig.target, now: now)

        #expect(Set([first.folder, second.folder, third.folder]).count == 3)
        #expect(try Data(contentsOf: marker) == Data("мой файл".utf8))
        #expect(second.folder.lastPathComponent.hasSuffix(" 2"))
        #expect(third.folder.lastPathComponent.hasSuffix(" 3"))
        #expect(try exportFolders(rig).count == 3)
    }

    @Test func partialFailureLeavesNoHalfExport() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        struct Boom: Error {}

        await #expect(throws: Boom.self) {
            try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target,
                                                  beforeCommit: { throw Boom() })
        }
        #expect(try exportFolders(rig).isEmpty)
    }

    @Test func keyErrorAbortsAndCleansUp() async throws {
        // Ключ отказывает на первом же чтении таймингов первой заметки, после записи её аудио.
        let key = CountdownKey(allowed: 1000)
        let rig = try await makeRig(key: key)
        defer { cleanup(rig) }
        key.allowed = 1

        await #expect(throws: HistoryKeyError.denied) {
            try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)
        }
        #expect(try exportFolders(rig).isEmpty)
    }

    @Test func brokenAudioIsSkippedAndCounted() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        let broken = rig.items[1].id
        try Data("не конверт".utf8).write(to: rig.vault.blobURL(broken, .audio))

        let result = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)

        #expect(result.exportedNotes == 3)
        #expect(result.exportedAudio == 1)
        #expect(result.skippedAudio == 1)
        let audioFolder = result.folder.appendingPathComponent("Audio")
        #expect(!FileManager.default.fileExists(atPath: audioFolder.appendingPathComponent("\(broken.uuidString).wav").path))
        let data = try Data(contentsOf: result.folder.appendingPathComponent("history.json"))
        #expect(try JSONDecoder().decode([TranscriptionItem].self, from: data).count == 3)
    }

    @Test func notesWithoutAudioAreExported() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        // Третья заметка без аудио.
        let result = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)

        let audioFolder = result.folder.appendingPathComponent("Audio")
        let withoutAudio = rig.items[2].id.uuidString
        let names = try FileManager.default.contentsOfDirectory(atPath: audioFolder.path)
        #expect(!names.contains { $0.hasPrefix(withoutAudio) })
        let data = try Data(contentsOf: result.folder.appendingPathComponent("history.json"))
        #expect(try JSONDecoder().decode([TranscriptionItem].self, from: data).contains { $0.id == rig.items[2].id })
    }

    @Test func exportFilesAreOwnerOnly() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }

        let result = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target)

        #expect(try permissions(result.folder) == 0o700)
        let audioFolder = result.folder.appendingPathComponent("Audio")
        #expect(try permissions(audioFolder) == 0o700)
        #expect(try permissions(result.folder.appendingPathComponent("history.json")) == 0o600)
        for name in try FileManager.default.contentsOfDirectory(atPath: audioFolder.path) {
            #expect(try permissions(audioFolder.appendingPathComponent(name)) == 0o600)
        }
    }

    /// Том без `RENAME_EXCL`: любое переименование отвечает `ENOTSUP`.
    private func noExclusiveOps(code: Int32 = ENOTSUP,
                                move: @escaping (URL, URL) throws -> Void = HistoryExportCommitOps.system.move)
        -> HistoryExportCommitOps {
        HistoryExportCommitOps(exclusiveRename: { _, _ in code }, move: move)
    }

    @Test func fallbackWorksWhenExclusiveRenameIsUnsupported() async throws {
        for code in [ENOTSUP, EINVAL] {
            let rig = try await makeRig()
            defer { cleanup(rig) }

            let result = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target,
                                                               commitOps: noExclusiveOps(code: code))

            #expect(result.exportedNotes == 3)
            #expect(result.exportedAudio == 2)
            let entries = try FileManager.default.contentsOfDirectory(atPath: rig.target.path)
            #expect(entries == [result.folder.lastPathComponent])
            let data = try Data(contentsOf: result.folder.appendingPathComponent("history.json"))
            #expect(try JSONDecoder().decode([TranscriptionItem].self, from: data) == rig.store.items)
            let audioFolder = result.folder.appendingPathComponent("Audio")
            for (id, bytes) in rig.audio {
                #expect(try Data(contentsOf: audioFolder.appendingPathComponent("\(id.uuidString).wav")) == bytes)
            }
            for (id, bytes) in rig.timings {
                #expect(try Data(contentsOf: audioFolder.appendingPathComponent("\(id.uuidString).segments.json")) == bytes)
            }
            #expect(try permissions(result.folder) == 0o700)
            #expect(try permissions(audioFolder) == 0o700)
            #expect(try permissions(result.folder.appendingPathComponent("history.json")) == 0o600)
            for name in try FileManager.default.contentsOfDirectory(atPath: audioFolder.path) {
                #expect(try permissions(audioFolder.appendingPathComponent(name)) == 0o600)
            }
        }
    }

    @Test func fallbackNeverOverwritesExistingFolder() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ops = noExclusiveOps()

        let first = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target,
                                                          now: now, commitOps: ops)
        let marker = first.folder.appendingPathComponent("marker.txt")
        try Data("мой файл".utf8).write(to: marker)
        let second = try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target,
                                                           now: now, commitOps: ops)

        #expect(first.folder != second.folder)
        #expect(second.folder.lastPathComponent.hasSuffix(" 2"))
        #expect(try Data(contentsOf: marker) == Data("мой файл".utf8))
        #expect(try exportFolders(rig).count == 2)
    }

    @Test func fallbackMoveFailureLeavesNoFolderBehind() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        struct Boom: Error {}
        var moves = 0
        let ops = noExclusiveOps(move: { from, to in
            moves += 1
            if moves == 2 { throw Boom() }
            try HistoryExportCommitOps.system.move(from, to)
        })

        await #expect(throws: Boom.self) {
            try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: rig.target, commitOps: ops)
        }
        #expect(moves == 2)
        #expect(try exportFolders(rig).isEmpty)
    }

    @Test func missingTargetFolderThrowsAndWritesNothing() async throws {
        let rig = try await makeRig()
        defer { cleanup(rig) }
        let missing = rig.directory.appendingPathComponent("nowhere", isDirectory: true)

        await #expect(throws: (any Error).self) {
            try await HistoryMigration.exportCopy(store: rig.store, vault: rig.vault, to: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
