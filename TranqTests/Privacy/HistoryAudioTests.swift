//
//  HistoryAudioTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Аудио заметок при замке: конверт вместо открытого `.wav`, чтение только разлоченным,
/// воспроизведение из памяти и сброс расшифрованного при запирании.
@MainActor
struct HistoryAudioTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryAudioTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(_ directory: URL, key: TestHistoryKey = TestHistoryKey(),
                           state: HistoryLockState) -> (HistoryStore, HistoryVault) {
        let vault = HistoryVault(directory: directory, key: key)
        let store = HistoryStore(directory: directory, saveDelay: 0, vault: vault, lockState: state)
        return (store, vault)
    }

    private func sealedURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("Audio/\(id.uuidString).wav.sealed")
    }

    /// Исходник во временной папке теста, как wav после распознавания.
    private func writeSource(_ data: Data, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func loadAudio(_ store: HistoryStore, _ id: UUID) async -> Result<Data?, Error> {
        await withCheckedContinuation { continuation in
            store.loadAudio(for: id) { continuation.resume(returning: $0) }
        }
    }

    @Test func storedAudioReadsBackByteEqual() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = randomData(64 * 1024)

        // Без замка: открытый файл, как раньше.
        let plainStore = HistoryStore(directory: directory.appendingPathComponent("off"), saveDelay: 0)
        let plainId = UUID()
        plainStore.storeAudio(for: plainId, from: try writeSource(bytes, in: directory), move: true)
        plainStore.flush()
        #expect(try plainStore.audioData(for: plainId) == bytes)
        #expect(plainStore.hasAudio(for: plainId))

        // С замком: конверт, чтение после разлочки, и синхронно, и через фон.
        let (store, _) = makeStore(directory.appendingPathComponent("lock"), state: .locked)
        let id = UUID()
        store.storeAudio(for: id, from: try writeSource(bytes, in: directory), move: true)
        store.flush()
        await store.applyLockStateAndWait(.unlocked)
        #expect(store.hasAudio(for: id))
        #expect(try store.audioData(for: id) == bytes)
        let loaded = try await loadAudio(store, id).get()
        #expect(loaded == bytes)
        #expect(try store.audioData(for: UUID()) == nil)
    }

    @Test func plainWavIsRemovedAfterSealing() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        let bytes = Data("RIFF-голос-голос".utf8)
        let source = try writeSource(bytes, in: directory)
        let id = UUID()

        store.storeAudio(for: id, from: source, move: true)
        store.flush()

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
        let raw = try Data(contentsOf: sealedURL(id, in: directory))
        #expect(raw.range(of: bytes) == nil)
        #expect(store.hasAudio(for: id))
    }

    @Test func audioUnavailableWhileLocked() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        let id = UUID()
        store.storeAudio(for: id, from: try writeSource(randomData(1024), in: directory), move: true)
        store.flush()

        #expect(throws: HistoryAudioError.locked) { try store.audioData(for: id) }
        if case .success = await loadAudio(store, id) { Issue.record("запертая история отдала аудио") }

        await store.applyLockStateAndWait(.keyUnavailable)
        #expect(throws: HistoryAudioError.locked) { try store.audioData(for: id) }
    }

    /// Неудачная запечатка не теряет аудио: открытый файл остаётся и запечатывается позже.
    @Test func failedSealKeepsPlainAudioAndRetries() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        let (store, _) = makeStore(directory, key: key, state: .locked)
        let bytes = randomData(2048)
        let id = UUID()

        key.failure = .unavailable
        store.storeAudio(for: id, from: try writeSource(bytes, in: directory), move: true)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
        #expect(!FileManager.default.fileExists(atPath: sealedURL(id, in: directory).path))

        key.failure = nil
        await store.applyLockStateAndWait(.locked)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
        await store.applyLockStateAndWait(.unlocked)
        #expect(try store.audioData(for: id) == bytes)
    }

    /// Review Focus 5: около 30 МБ проходят конверт без потерь.
    @Test func largeAudioRoundTrips() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        let bytes = randomData(30 * 1024 * 1024)
        let id = UUID()

        store.storeAudio(for: id, from: try writeSource(bytes, in: directory), move: true)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
        await store.applyLockStateAndWait(.unlocked)

        let loaded = try #require(try await loadAudio(store, id).get())
        #expect(loaded.count == bytes.count)
        #expect(loaded == bytes)
    }

    /// Review Focus 5: при запирании плеер останавливается и отпускает расшифрованные байты.
    @Test func lockingDropsCachedAudio() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("voice.wav")
        #expect(AudioPCM.writeWav(samples: [Float](repeating: 0.1, count: 16_000 * 2), to: source))
        let id = UUID()
        store.storeAudio(for: id, from: source, move: true)
        store.flush()
        await store.applyLockStateAndWait(.unlocked)

        let playback = PlaybackController(history: store)
        playback.toggleSyncedPlayback(for: id)
        try await waitUntil { playback.isAudioLoaded }
        #expect(playback.playingItemId == id)
        #expect((playback.durations[id] ?? 0) > 1)

        await store.applyLockStateAndWait(.locked)

        #expect(!playback.isAudioLoaded)
        #expect(playback.playingItemId == nil)
        #expect(!playback.isPlayerPlaying)
        #expect(playback.durations.isEmpty)

        // Запертая история не даёт запустить воспроизведение снова.
        playback.toggleSyncedPlayback(for: id)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!playback.isAudioLoaded)
    }

    /// Загрузка, начатая до запирания, не оживляет плеер после него.
    @Test func lockDuringLoadDiscardsAudio() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = makeStore(directory, state: .locked)
        let id = UUID()
        store.storeAudio(for: id, from: try writeSource(randomData(4096), in: directory), move: true)
        store.flush()
        await store.applyLockStateAndWait(.unlocked)

        // Загрузка уходит в фон, запирание приходит раньше её ответа на главный поток.
        let result: Result<Data?, Error> = await withCheckedContinuation { continuation in
            store.loadAudio(for: id) { continuation.resume(returning: $0) }
            store.applyLockState(.locked)
        }
        if case .success(let data) = result, data != nil {
            Issue.record("загрузка после запирания вернула байты")
        }
    }

    /// Открытый wav с прошлого запуска в папке аудио.
    private func placeOrphan(_ bytes: Data, in directory: URL) throws -> (UUID, URL) {
        let id = UUID()
        let audio = directory.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let url = audio.appendingPathComponent("\(id.uuidString).wav")
        try bytes.write(to: url)
        return (id, url)
    }

    @Test func orphanPlainWavIsSealedOnEnteringLock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = randomData(2048)
        let (id, plain) = try placeOrphan(bytes, in: directory)
        let stranger = directory.appendingPathComponent("Audio/notes.wav")
        try Data([1]).write(to: stranger)

        // Хранилище подключается позже: метка `locked` без vault, затем `attach`.
        let store = HistoryStore(directory: directory, saveDelay: 0, vault: nil, lockState: .locked)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: plain.path))
        store.attach(vault: HistoryVault(directory: directory, key: TestHistoryKey()))
        store.flush()

        #expect(!FileManager.default.fileExists(atPath: plain.path))
        #expect(FileManager.default.fileExists(atPath: sealedURL(id, in: directory).path))
        #expect(FileManager.default.fileExists(atPath: stranger.path), "чужие имена не трогаются")

        // И при входе в `locked` из `off`.
        let other = makeDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let (otherId, otherPlain) = try placeOrphan(bytes, in: other)
        let (offStore, _) = makeStore(other, state: .off)
        await offStore.applyLockStateAndWait(.locked)
        #expect(!FileManager.default.fileExists(atPath: otherPlain.path))
        await offStore.applyLockStateAndWait(.unlocked)
        #expect(try offStore.audioData(for: otherId) == bytes)
    }

    @Test func unsealedAudioIsCountedAsFailure() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        key.failure = .unavailable
        _ = try placeOrphan(randomData(512), in: directory)
        let (store, _) = makeStore(directory, key: key, state: .locked)
        store.storeAudio(for: UUID(), from: try writeSource(randomData(512), in: directory), move: true)
        store.flush()
        await mainHop()
        #expect(store.sealFailureCount == 2)

        key.failure = nil
        await store.applyLockStateAndWait(.locked)
        await mainHop()
        #expect(store.sealFailureCount == 0)
    }

    @Test func clearAllWhileLockedRemovesPlainWavs() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = TestHistoryKey()
        key.failure = .unavailable
        let (_, orphan) = try placeOrphan(randomData(512), in: directory)
        let (store, _) = makeStore(directory, key: key, state: .locked)
        let id = UUID()
        store.storeAudio(for: id, from: try writeSource(randomData(512), in: directory), move: true)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: id).path))

        store.clearAll()
        store.flush()
        await mainHop()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
        #expect(store.sealFailureCount == 0)
    }

    @Test func offStateDoesNotSweepPlainWavs() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (id, plain) = try placeOrphan(randomData(512), in: directory)
        let (store, _) = makeStore(directory, state: .off)
        store.attach(vault: HistoryVault(directory: directory, key: TestHistoryKey()))
        await store.applyLockStateAndWait(.off)

        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(!FileManager.default.fileExists(atPath: sealedURL(id, in: directory).path))
        #expect(store.sealFailureCount == 0)
    }

    private func mainHop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(condition())
    }
}
