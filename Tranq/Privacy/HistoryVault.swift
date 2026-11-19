import Darwin
import Foundation

enum HistoryVaultError: Error {
    /// Блоб бывает только аудио или таймингами: остальное — ошибка вызывающего.
    case unsupportedPurpose
    case writeFailed
}

/// Хранилище запечатанных файлов истории под `directory`:
/// `Notes/<uuid>.note`, `Audio/<uuid>.wav.sealed`, `Audio/<uuid>.segments.sealed`.
/// На диске лежит JSON `SealedEnvelope`, открытого текста нет.
final class HistoryVault: @unchecked Sendable {
    private let directory: URL
    private let key: HistoryKeyProviding
    private let lock = NSLock()
    private var corrupted: [URL] = []

    init(directory: URL, key: HistoryKeyProviding) {
        self.directory = directory
        self.key = key
    }

    private var notesDirectory: URL { directory.appendingPathComponent("Notes", isDirectory: true) }
    private var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }

    /// Что не прочиталось на последнем `readNotes`. Файлы остаются на диске.
    var corruptedNoteFiles: [URL] {
        lock.lock(); defer { lock.unlock() }
        return corrupted
    }

    // MARK: Заметки

    /// Нужен только публичный ключ: подтверждения личности не требует.
    func writeNote(_ item: TranscriptionItem) throws {
        let plain = try JSONEncoder().encode(item)
        let envelope = try HistoryCrypto.seal(plain, purpose: .note, publicKey: key.publicKey)
        try write(envelope, to: noteURL(item.id), in: notesDirectory)
    }

    /// Новые первыми: по дате заметки, затем по `createdAt` (пусто в конце), затем по id.
    /// Дата заметки хранится строкой с точностью до минуты, поэтому нужны запасные ключи.
    /// Порченый конверт пропускается и остаётся на диске, его адрес попадает в `corruptedNoteFiles`.
    /// Отказ или недоступность ключа порчей не считаются и уходят наружу как есть.
    /// Согласование ключа может показать диалог: с главного потока не звать.
    func readNotes() throws -> [TranscriptionItem] {
        setCorrupted([])
        let files = noteFiles()
        var found: [(item: TranscriptionItem, date: Date)] = []
        var broken: [URL] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? JSONDecoder().decode(SealedEnvelope.self, from: data) else {
                broken.append(url)
                continue
            }
            let plain: Data
            do {
                plain = try HistoryCrypto.open(envelope, purpose: .note, key: key)
            } catch let error as HistoryKeyError {
                throw error
            } catch {
                broken.append(url)
                continue
            }
            guard let item = try? JSONDecoder().decode(TranscriptionItem.self, from: plain) else {
                broken.append(url)
                continue
            }
            found.append((item, Self.parse(item.date)))
        }
        setCorrupted(broken)
        found.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            let (left, right) = (lhs.item.createdAt ?? .distantPast, rhs.item.createdAt ?? .distantPast)
            if left != right { return left > right }
            return lhs.item.id.uuidString < rhs.item.id.uuidString
        }
        return found.map(\.item)
    }

    func deleteNote(id: UUID) {
        try? FileManager.default.removeItem(at: noteURL(id))
    }

    /// Все файлы заметок на диске, и порченые тоже.
    func noteFileCount() -> Int {
        noteFiles().count
    }

    /// Стирает все конверты заметок, аудио и таймингов: имена заметок для этого не нужны.
    func deleteAll() {
        let fm = FileManager.default
        for url in noteFiles() { try? fm.removeItem(at: url) }
        let blobs = (try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in blobs where url.pathExtension == "sealed" { try? fm.removeItem(at: url) }
    }

    // MARK: Блобы

    /// Только `.audio` и `.timings`.
    func writeBlob(_ data: Data, id: UUID, purpose: HistoryCryptoPurpose) throws {
        let url = try blobURL(id, purpose)
        let envelope = try HistoryCrypto.seal(data, purpose: purpose, publicKey: key.publicKey)
        try write(envelope, to: url, in: audioDirectory)
    }

    /// `nil`, если файла нет. Порча конверта и отказ ключа бросают ошибку.
    /// Согласование ключа может показать диалог: с главного потока не звать.
    func readBlob(id: UUID, purpose: HistoryCryptoPurpose) throws -> Data? {
        let url = try blobURL(id, purpose)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try JSONDecoder().decode(SealedEnvelope.self, from: Data(contentsOf: url))
        return try HistoryCrypto.open(envelope, purpose: purpose, key: key)
    }

    func deleteBlobs(id: UUID) {
        for purpose in [HistoryCryptoPurpose.audio, .timings] {
            if let url = try? blobURL(id, purpose) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Файлы

    private func noteURL(_ id: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(id.uuidString).note")
    }

    private func blobURL(_ id: UUID, _ purpose: HistoryCryptoPurpose) throws -> URL {
        switch purpose {
        case .audio: audioDirectory.appendingPathComponent("\(id.uuidString).wav.sealed")
        case .timings: audioDirectory.appendingPathComponent("\(id.uuidString).segments.sealed")
        case .note, .journal: throw HistoryVaultError.unsupportedPurpose
        }
    }

    private func noteFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: notesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "note" }
    }

    private func setCorrupted(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        corrupted = urls
    }

    /// Папка 0700, файл 0600 с момента создания, замена атомарная.
    private func write(_ envelope: SealedEnvelope, to url: URL, in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(envelope)
        let temp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HistoryVaultError.writeFailed
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw HistoryVaultError.writeFailed
        }
    }

    private static func parse(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = TranscriptionItem.dateFormat
        return formatter.date(from: string) ?? .distantPast
    }
}
