import Foundation
import AppKit

public struct JournalRecord: Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let rawText: String
    public let stageOneText: String?
    public let finalPastedText: String?
    public let durationSec: Double
    public let targetAppName: String?
    public let targetPid: pid_t?
    public let targetBundleId: String?
    public let isFallback: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        stageOneText: String? = nil,
        finalPastedText: String? = nil,
        durationSec: Double = 0.0,
        targetAppName: String? = nil,
        targetPid: pid_t? = nil,
        targetBundleId: String? = nil,
        isFallback: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.stageOneText = stageOneText
        self.finalPastedText = finalPastedText
        self.durationSec = durationSec
        self.targetAppName = targetAppName
        self.targetPid = targetPid
        self.targetBundleId = targetBundleId
        self.isFallback = isFallback
    }
}

/// Как журнал пишет строки: открытым JSON или конвертом. Запечатать можно по одному публичному ключу.
enum JournalSealing {
    case off
    case sealed(key: HistoryKeyProviding)
}

public final class TranscriptJournal: ObservableObject {
    public static let shared = TranscriptJournal(directory: AppEnvironment.dataDirectory)

    @Published public private(set) var lastRecord: JournalRecord?

    private let ioQueue = DispatchQueue(label: "com.tranq.transcript.journal", qos: .utility)
    private var pendingRecords: [UUID: JournalRecord] = [:]
    private let pendingLock = NSLock()
    private let maxFileBytes: UInt64 = 5 * 1024 * 1024 // 5 MB ротация

    private let directory: URL
    /// Читается и меняется только на ioQueue, поэтому смена режима идёт в одном порядке с записями.
    private var sealing: JournalSealing

    private var journalFileURL: URL? {
        directory.appendingPathComponent("transcript_journal.jsonl")
    }

    /// Архив, в который журнал уходит при ротации.
    private static func archiveURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("1.jsonl")
    }

    /// `directory` подменяется в тестах, чтобы не трогать настоящий журнал пользователя.
    init(directory: URL, sealing: JournalSealing = .off) {
        self.directory = directory
        self.sealing = sealing
        // Запечатанную строку без подтверждения личности не прочесть: последнюю запись с диска не поднимаем.
        if case .off = sealing { loadLastRecordFromDisk() }
    }

    /// Переключает режим записи на ходу. Встаёт в очередь записи, поэтому уже принятые строки уйдут в прежнем режиме.
    func setSealing(_ sealing: JournalSealing) {
        ioQueue.async { self.sealing = sealing }
    }

    /// Стирает журнал, его архив и последнюю запись в памяти. «Вставить оригинал речи» после этого ничего не найдёт.
    public func clear() {
        pendingLock.lock()
        pendingRecords.removeAll()
        pendingLock.unlock()
        DispatchQueue.main.async { self.lastRecord = nil }
        ioQueue.async {
            guard let url = self.journalFileURL else { return }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Self.archiveURL(for: url))
        }
    }

    /// Ждёт, пока завершится отложенная запись на диск или стирание.
    func flush() {
        ioQueue.sync {}
    }

    /// Сохранение сырой расшифровки на диск ДО начала синтеза мысли
    public func recordInitial(
        id: UUID,
        rawText: String,
        durationSec: Double,
        targetAppName: String?,
        targetPid: pid_t? = nil,
        targetBundleId: String? = nil
    ) {
        let record = JournalRecord(
            id: id,
            timestamp: Date(),
            rawText: rawText,
            durationSec: durationSec,
            targetAppName: targetAppName,
            targetPid: targetPid,
            targetBundleId: targetBundleId
        )

        pendingLock.lock()
        pendingRecords[id] = record
        pendingLock.unlock()

        DispatchQueue.main.async {
            self.lastRecord = record
        }

        ioQueue.async {
            self.appendToFile(record)
        }
    }

    /// Обновление записи финальным результатом после валидатора или отката
    public func updateFinal(id: UUID, stageOneText: String?, finalText: String, isFallback: Bool) {
        pendingLock.lock()
        let initial = pendingRecords.removeValue(forKey: id)
        pendingLock.unlock()

        let updated = JournalRecord(
            id: id,
            timestamp: Date(),
            rawText: initial?.rawText ?? lastRecord?.rawText ?? finalText,
            stageOneText: stageOneText,
            finalPastedText: finalText,
            durationSec: initial?.durationSec ?? lastRecord?.durationSec ?? 0,
            targetAppName: initial?.targetAppName ?? lastRecord?.targetAppName,
            targetPid: initial?.targetPid ?? lastRecord?.targetPid,
            targetBundleId: initial?.targetBundleId ?? lastRecord?.targetBundleId,
            isFallback: isFallback
        )

        DispatchQueue.main.async {
            self.lastRecord = updated
        }

        ioQueue.async {
            self.appendToFile(updated)
        }
    }

    /// Восстановление дословного оригинала речи: вставка под курсор или копирование в буфер
    public func pasteOriginal(completion: @escaping (Bool) -> Void) {
        guard let record = lastRecord, !record.rawText.isEmpty else {
            completion(false)
            return
        }

        let raw = record.rawText
        AppLogger.shared.info("Journal", "Восстановление оригинального транскрипта", details: "\(raw.count) симв.")

        let target: FocusSnapshot?
        if let pid = record.targetPid, let name = record.targetAppName {
            target = FocusSnapshot(pid: pid, bundleIdentifier: record.targetBundleId, appName: name)
        } else {
            target = InsertionService.shared.captureFocus()
        }

        InsertionService.shared.paste(text: raw, target: target, autoPasteEnabled: true) { result in
            DispatchQueue.main.async {
                completion(result == .pasted || result == .copied)
            }
        }
    }

    private func loadLastRecordFromDisk() {
        ioQueue.async {
            guard let url = self.journalFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else { return }

            let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let lastLine = lines.last, let lineData = lastLine.data(using: .utf8) else { return }
            if let decoded = try? JSONDecoder().decode(JournalRecord.self, from: lineData) {
                DispatchQueue.main.async {
                    if self.lastRecord == nil {
                        self.lastRecord = decoded
                    }
                }
            }
        }
    }

    /// Строка файла: открытый JSON или base64 конверта, смотря по режиму. Без публичного ключа строки нет, открытым не пишем.
    private func encodeLine(_ record: JournalRecord) throws -> Data? {
        let json = try JSONEncoder().encode(record)
        switch sealing {
        case .off:
            return json
        case .sealed(let key):
            let envelope = try HistoryCrypto.seal(json, purpose: .journal, publicKey: key.publicKey)
            return Data(try JSONEncoder().encode(envelope).base64EncodedString().utf8)
        }
    }

    private func appendToFile(_ record: JournalRecord) {
        guard let url = journalFileURL else { return }
        do {
            guard var entryData = try encodeLine(record) else { return }
            entryData.append(0x0A)

            if FileManager.default.fileExists(atPath: url.path) {
                // Ротация при превышении 5 МБ: архивируем в .1.jsonl
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let fileSize = attrs[.size] as? UInt64, fileSize > maxFileBytes {
                    let backupURL = Self.archiveURL(for: url)
                    try? FileManager.default.removeItem(at: backupURL)
                    try? FileManager.default.moveItem(at: url, to: backupURL)
                }
            }

            if FileManager.default.fileExists(atPath: url.path) {
                let fileHandle = try FileHandle(forWritingTo: url)
                fileHandle.seekToEndOfFile()
                try fileHandle.write(contentsOf: entryData)
                try fileHandle.close()
            } else {
                try entryData.write(to: url, options: .atomic)
            }
        } catch {
            AppLogger.shared.error("Journal", "Не удалось записать журнал транскриптов", details: error.localizedDescription)
        }
    }

    // MARK: - Миграция замка

    /// Суффикс копии, которую миграция пишет рядом с файлом журнала до замены.
    static let migrationSuffix = "migrating"

    /// Файлы журнала по порядку: архив, затем текущий.
    var migrationFiles: [URL] {
        guard let url = journalFileURL else { return [] }
        return [Self.archiveURL(for: url), url]
    }

    /// Все строки архива и текущего файла как есть, по порядку. Пустые строки пропускаются.
    func migrationLines() -> [String] {
        ioQueue.sync { migrationFiles.flatMap { Self.lines(of: $0) } }
    }

    /// Переписывает архив и текущий файл построчно в очереди записи, поэтому ни одна строка не теряется
    /// и не встаёт между чтением и заменой. Каждый файл сначала пишется копией рядом, копия читается
    /// обратно и сверяется, и только потом атомарно заменяет исходник. Сбой до замены убирает копии,
    /// исходники остаются как были. В конце журнал пишет в режиме `sealing`.
    func rewriteForMigration(sealing: JournalSealing, transform: (String) throws -> String) throws {
        try ioQueue.sync {
            var copies: [(copy: URL, original: URL)] = []
            do {
                for original in migrationFiles where FileManager.default.fileExists(atPath: original.path) {
                    let source = Self.lines(of: original)
                    let output = try source.map(transform)
                    guard output.count == source.count, !output.contains(where: { $0.contains("\n") }) else {
                        throw HistoryMigrationError.verificationFailed
                    }
                    let data = Data((output.map { $0 + "\n" }.joined()).utf8)
                    let copy = original.appendingPathExtension(Self.migrationSuffix)
                    copies.append((copy, original))
                    try data.write(to: copy, options: .atomic)
                    guard (try? Data(contentsOf: copy)) == data else { throw HistoryMigrationError.verificationFailed }
                }
            } catch {
                for item in copies { try? FileManager.default.removeItem(at: item.copy) }
                throw error
            }
            // Копии проверены: замена атомарная, исходник уходит только вместе с появлением копии.
            for item in copies where Darwin.rename(item.copy.path, item.original.path) != 0 {
                try? FileManager.default.removeItem(at: item.copy)
                AppLogger.shared.error("Journal", "Файл журнала не заменён при миграции", details: item.original.lastPathComponent)
            }
            self.sealing = sealing
        }
    }

    /// Строки файла по `\n`, байт в байт. Нет файла — нет строк.
    private static func lines(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Читает архив и текущий файл, открывая каждую запечатанную строку. Нечитаемые строки пропускает,
    /// ошибки ключа `HistoryKeyError` отдаёт наружу. Может показать запрос подтверждения: не звать с главного потока.
    func readAllRecords(key: HistoryKeyProviding) throws -> [JournalRecord] {
        // Снимок файлов берём в очереди записи, расшифровку делаем вне её: диалог не должен держать запись.
        let contents: [String] = ioQueue.sync {
            guard let url = journalFileURL else { return [] }
            return [Self.archiveURL(for: url), url].compactMap { fileURL in
                (try? Data(contentsOf: fileURL)).map { String(decoding: $0, as: UTF8.self) }
            }
        }

        var records: [JournalRecord] = []
        for content in contents {
            for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                guard let data = Data(base64Encoded: line),
                      let envelope = try? JSONDecoder().decode(SealedEnvelope.self, from: data) else { continue }
                do {
                    let json = try HistoryCrypto.open(envelope, purpose: .journal, key: key)
                    if let record = try? JSONDecoder().decode(JournalRecord.self, from: json) {
                        records.append(record)
                    }
                } catch let error as HistoryKeyError {
                    throw error
                } catch {
                    continue
                }
            }
        }
        return records
    }
}
