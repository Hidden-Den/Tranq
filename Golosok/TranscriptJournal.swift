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

public final class TranscriptJournal: ObservableObject {
    public static let shared = TranscriptJournal()

    @Published public private(set) var lastRecord: JournalRecord?

    private let ioQueue = DispatchQueue(label: "com.golosok.transcript.journal", qos: .utility)
    private var pendingRecords: [UUID: JournalRecord] = [:]
    private let pendingLock = NSLock()
    private let maxFileBytes: UInt64 = 5 * 1024 * 1024 // 5 MB ротация

    private var journalFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript_journal.jsonl")
    }

    private init() {
        loadLastRecordFromDisk()
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

    private func appendToFile(_ record: JournalRecord) {
        guard let url = journalFileURL else { return }
        do {
            let data = try JSONEncoder().encode(record)
            if let line = String(data: data, encoding: .utf8) {
                let entry = line + "\n"
                guard let entryData = entry.data(using: .utf8) else { return }

                if FileManager.default.fileExists(atPath: url.path) {
                    // Ротация при превышении 5 МБ: архивируем в .1.jsonl
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let fileSize = attrs[.size] as? UInt64, fileSize > maxFileBytes {
                        let backupURL = url.deletingPathExtension().appendingPathExtension("1.jsonl")
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
            }
        } catch {
            AppLogger.shared.error("Journal", "Не удалось записать журнал транскриптов", details: error.localizedDescription)
        }
    }
}
