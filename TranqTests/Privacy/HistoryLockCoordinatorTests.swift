//
//  HistoryLockCoordinatorTests.swift
//  TranqTests
//

import CryptoKit
import Foundation
import Testing
@testable import Tranq

/// Ключ, который согласуется `agreeLimit` раз, а потом бросает `failure`.
/// Проверка ключа при разлочке проходит, чтение конвертов в хранилище падает.
private final class FlakyHistoryKey: HistoryKeyProviding {
    let inner = TestHistoryKey()
    var agreeLimit = Int.max
    var failure: HistoryKeyError = .unavailable
    private var agrees = 0

    var exists: Bool { inner.exists }
    var publicKey: Data { get throws { try inner.publicKey } }

    func agree(withEphemeral ephemeral: Data) throws -> SymmetricKey {
        agrees += 1
        if agrees > agreeLimit { throw failure }
        return try inner.agree(withEphemeral: ephemeral)
    }

    var createFails = false

    func create() throws {
        if createFails { throw HistoryKeyError.unavailable }
        try inner.create()
    }
    func destroy() throws { try inner.destroy() }
}

/// Проводка замка: состояние замка доходит до хранилища и журнала, хранилище тянет замок за собой.
@MainActor
struct HistoryLockCoordinatorTests {
    private final class Counter { var count = 0 }

    private struct Rig {
        let directory: URL
        let store: HistoryStore
        let journal: TranscriptJournal
        let coordinator: HistoryLockCoordinator
        let presence: TestPresence
        let clock: TestClock
        let erases: Counter
    }

    private func makeRig(enabled: Bool, key: HistoryKeyProviding = TestHistoryKey(),
                         erase: @escaping () -> Void = {}) -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryLockCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(directory: directory, saveDelay: 0)
        let journal = TranscriptJournal(directory: directory)
        let presence = TestPresence()
        let clock = TestClock()
        let erases = Counter()
        let coordinator = HistoryLockCoordinator(
            enabled: enabled, store: store, journal: journal, key: key, presence: presence,
            directory: directory, erase: { erases.count += 1; erase() }, resetSession: {}, now: { clock.date })
        return Rig(directory: directory, store: store, journal: journal, coordinator: coordinator,
                   presence: presence, clock: clock, erases: erases)
    }

    private func cleanup(_ rig: Rig) {
        rig.store.flush()
        rig.journal.flush()
        try? FileManager.default.removeItem(at: rig.directory)
    }

    /// Ждёт ответа фонового чтения хранилища.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func notesCount(_ directory: URL) -> Int {
        let notes = directory.appendingPathComponent("Notes", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [])
            .filter { $0.hasSuffix(".note") }.count
    }

    @Test func disabledStaysOff() {
        let rig = makeRig(enabled: false)
        defer { cleanup(rig) }
        #expect(rig.coordinator.state == .off)
        #expect(rig.store.lockState == .off)
        #expect(rig.coordinator.isEnabled == false)
    }

    @Test func enabledStartsLockedWithVaultAttached() {
        let rig = makeRig(enabled: true)
        defer { cleanup(rig) }
        #expect(rig.coordinator.state == .locked)
        #expect(rig.store.lockState == .locked)
        #expect(rig.coordinator.isEnabled)

        rig.store.addNote(text: "тайна")
        rig.store.flush()
        #expect(rig.store.items.isEmpty)
        #expect(notesCount(rig.directory) == 1)
        #expect(!FileManager.default.fileExists(atPath: rig.directory.appendingPathComponent("history.json").path))
    }

    @Test func enabledSealsJournal() throws {
        let key = TestHistoryKey()
        let rig = makeRig(enabled: true, key: key)
        defer { cleanup(rig) }
        rig.journal.recordInitial(id: UUID(), rawText: "сырая тайна", durationSec: 1, targetAppName: nil)
        rig.journal.flush()

        let raw = try String(contentsOf: rig.directory.appendingPathComponent("transcript_journal.jsonl"), encoding: .utf8)
        #expect(!raw.contains("сырая"))
        #expect(try rig.journal.readAllRecords(key: key).map(\.rawText) == ["сырая тайна"])
    }

    @Test func unlockMirrorsIntoStore() async {
        let rig = makeRig(enabled: true)
        defer { cleanup(rig) }
        rig.store.addNote(text: "первая")
        rig.store.flush()

        await rig.coordinator.unlock()
        await waitUntil { rig.store.items.count == 1 }

        #expect(rig.coordinator.state == .unlocked)
        #expect(rig.store.lockState == .unlocked)
        #expect(rig.store.items.map(\.text) == ["первая"])
        #expect(rig.presence.calls == 1)
    }

    @Test func sleepRelocksStore() async {
        let rig = makeRig(enabled: true)
        defer { cleanup(rig) }
        rig.store.addNote(text: "первая")
        rig.store.flush()
        await rig.coordinator.unlock()
        await waitUntil { rig.store.items.count == 1 }

        rig.coordinator.noteSystemWillSleep()

        #expect(rig.coordinator.state == .locked)
        #expect(rig.store.lockState == .locked)
        #expect(rig.store.items.isEmpty)
    }

    @Test func storeReadFailureMakesKeyUnavailable() async {
        let key = FlakyHistoryKey()
        let rig = makeRig(enabled: true, key: key)
        defer { cleanup(rig) }
        rig.store.addNote(text: "первая")
        rig.store.flush()
        // Одно согласование уходит на проверку ключа, чтение конверта уже падает.
        key.agreeLimit = 1

        await rig.coordinator.unlock()
        await waitUntil { rig.coordinator.state != .unlocked }

        #expect(rig.coordinator.state == .keyUnavailable)
        #expect(rig.store.lockState == .keyUnavailable)
        #expect(rig.store.items.isEmpty)
    }

    @Test func storeReadDenialRelocks() async {
        let key = FlakyHistoryKey()
        key.failure = .denied
        let rig = makeRig(enabled: true, key: key)
        defer { cleanup(rig) }
        rig.store.addNote(text: "первая")
        rig.store.flush()
        key.agreeLimit = 1

        await rig.coordinator.unlock()
        await waitUntil { rig.coordinator.state != .unlocked }

        #expect(rig.coordinator.state == .locked)
        #expect(rig.store.lockState == .locked)

        // Следующая разлочка снова читает хранилище.
        key.agreeLimit = .max
        await rig.coordinator.unlock()
        await waitUntil { rig.store.items.count == 1 }
        #expect(rig.coordinator.state == .unlocked)
        #expect(rig.store.items.map(\.text) == ["первая"])
    }

    @Test func idleWindowRelocksAfterTimeout() async {
        let rig = makeRig(enabled: true)
        defer { cleanup(rig) }
        rig.coordinator.noteWindowVisibility(false)
        await rig.coordinator.unlock()
        rig.clock.advance(HistoryLock.idleTimeout + 1)
        rig.coordinator.tick()
        #expect(rig.coordinator.state == .locked)
        #expect(rig.store.lockState == .locked)
    }

    @Test func visibleWindowKnownAcrossRuntimeEnable() async {
        let rig = makeRig(enabled: false)
        defer { cleanup(rig) }
        rig.coordinator.noteWindowVisibility(true)

        rig.coordinator.setEnabled(true)
        #expect(rig.coordinator.state == .locked)
        #expect(rig.store.lockState == .locked)

        await rig.coordinator.unlock()
        rig.clock.advance(HistoryLock.idleTimeout * 2)
        rig.coordinator.tick()
        #expect(rig.coordinator.state == .unlocked)

        rig.coordinator.noteWindowVisibility(false)
        rig.clock.advance(HistoryLock.idleTimeout + 1)
        rig.coordinator.tick()
        #expect(rig.coordinator.state == .locked)
    }

    @Test func runtimeEnableAttachesVaultBeforeLocking() {
        let rig = makeRig(enabled: false)
        defer { cleanup(rig) }
        rig.coordinator.setEnabled(true)

        rig.store.addNote(text: "после включения")
        rig.store.flush()
        #expect(notesCount(rig.directory) == 1)
        #expect(rig.coordinator.vault != nil)
    }

    @Test func runtimeDisableTurnsOff() async {
        let rig = makeRig(enabled: true)
        defer { cleanup(rig) }
        await rig.coordinator.unlock()

        rig.coordinator.setEnabled(false)

        #expect(rig.coordinator.state == .off)
        #expect(rig.store.lockState == .off)
        #expect(rig.coordinator.isEnabled == false)
        #expect(rig.coordinator.vault == nil)
        // Выключенный замок разлочку не просит.
        await rig.coordinator.unlock()
        #expect(rig.presence.calls == 1)
    }

    /// Стирание уничтожает ключ: координатор заводит новый и ставит замок заново, заметки ложатся конвертами.
    @Test func eraseGoesThroughEraserAndReinstallsLock() async throws {
        let key = TestHistoryKey()
        let rig = makeRig(enabled: true, key: key, erase: { try? key.destroy() })
        defer { cleanup(rig) }
        await rig.coordinator.unlock()
        let oldVault = rig.coordinator.vault

        rig.coordinator.eraseHistory()

        #expect(rig.erases.count == 1)
        #expect(key.exists)
        #expect(rig.coordinator.state == .locked)
        #expect(rig.store.lockState == .locked)
        #expect(rig.coordinator.vault != nil)
        #expect(rig.coordinator.vault !== oldVault)
        _ = rig.store.addNote(text: "после стирания")
        rig.store.flush()
        #expect(notesCount(rig.directory) == 1)
        #expect(rig.store.sealFailureCount == 0)
    }

    /// Экран «не читается на этом Mac»: стирание ведёт обратно в рабочее запертое состояние.
    @Test func eraseFromKeyUnavailableLandsOnLocked() async {
        let key = TestHistoryKey(created: false)
        let rig = makeRig(enabled: true, key: key)
        defer { cleanup(rig) }
        await rig.coordinator.unlock()
        #expect(rig.coordinator.state == .keyUnavailable)

        rig.coordinator.eraseHistory()

        #expect(key.exists)
        #expect(rig.coordinator.state == .locked)
        await rig.coordinator.unlock()
        #expect(rig.coordinator.state == .unlocked)
    }

    /// Новый ключ не создался: честное `keyUnavailable`, а не включённый замок без ключа.
    @Test func eraseWithFailedKeyCreationLandsOnKeyUnavailable() {
        let key = FlakyHistoryKey()
        key.createFails = true
        let rig = makeRig(enabled: true, key: key, erase: { try? key.destroy() })
        defer { cleanup(rig) }

        rig.coordinator.eraseHistory()

        #expect(rig.erases.count == 1)
        #expect(rig.coordinator.state == .keyUnavailable)
        #expect(rig.store.lockState == .keyUnavailable)
        #expect(rig.coordinator.isEnabled)
    }

    /// Выключенный замок после стирания ключа не заводит.
    @Test func eraseWithLockOffStaysOff() {
        let key = TestHistoryKey(created: false)
        let rig = makeRig(enabled: false, key: key)
        defer { cleanup(rig) }

        rig.coordinator.eraseHistory()

        #expect(rig.erases.count == 1)
        #expect(rig.coordinator.state == .off)
        #expect(!key.exists)
        #expect(rig.coordinator.vault == nil)
    }
}
