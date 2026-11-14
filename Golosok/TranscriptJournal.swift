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
    public let isFallback: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        stageOneText: String? = nil,
        finalPastedText: String? = nil,
        durationSec: Double = 0.0,
        targetAppName: String? = nil,
        isFallback: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.stageOneText = stageOneText
        self.finalPastedText = finalPastedText
        self.durationSec = durationSec
        self.targetAppName = targetAppName
        self.isFallback = isFallback
    }
}

public final class TranscriptJournal: ObservableObject {
    public static let shared = TranscriptJournal()

    @Published public private(set) var lastRecord: JournalRecord?

    private let ioQueue = DispatchQueue(label: "com.golosok.transcript.journal", qos: .utility)
    private let maxRecords = 200

    private var journalFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript_journal.jsonl")
    }

    private init() {}

    /// Сохранение сырой расшифровки на диск ДО начала синтеза мысли
    public func recordInitial(id: UUID, rawText: String, durationSec: Double, targetAppName: String?) {
        let record = JournalRecord(
            id: id,
            timestamp: Date(),
            rawText: rawText,
            durationSec: durationSec,
            targetAppName: targetAppName
        )

        DispatchQueue.main.async {
            self.lastRecord = record
        }

        ioQueue.async {
            self.appendToFile(record)
        }
    }

    /// Обновление записи финальным результатом после валидатора или отката
    public func updateFinal(id: UUID, stageOneText: String?, finalText: String, isFallback: Bool) {
        let updated = JournalRecord(
            id: id,
            timestamp: Date(),
            rawText: lastRecord?.rawText ?? finalText,
            stageOneText: stageOneText,
            finalPastedText: finalText,
            durationSec: lastRecord?.durationSec ?? 0,
            targetAppName: lastRecord?.targetAppName,
            isFallback: isFallback
        )

        DispatchQueue.main.async {
            self.lastRecord = updated
        }

        ioQueue.async {
            self.appendToFile(updated)
        }
    }

    /// Действие «Вставить оригинал» — копирует в буфер обмена и вставляет исходный дословный текст
    public func pasteOriginal(completion: @escaping (Bool) -> Void) {
        guard let record = lastRecord, !record.rawText.isEmpty else {
            completion(false)
            return
        }

        let raw = record.rawText
        InsertionService.shared.copyToPasteboard(text: raw, markTransient: false)
        AppLogger.shared.info("Journal", "Восстановлен оригинальный сырой транскрипт", details: raw)
        completion(true)
    }

    private func appendToFile(_ record: JournalRecord) {
        guard let url = journalFileURL else { return }
        do {
            let data = try JSONEncoder().encode(record)
            if let line = String(data: data, encoding: .utf8) {
                let entry = line + "\n"
                if FileManager.default.fileExists(atPath: url.path) {
                    let fileHandle = try FileHandle(forWritingTo: url)
                    fileHandle.seekToEndOfFile()
                    if let entryData = entry.data(using: .utf8) {
                        fileHandle.write(entryData)
                    }
                    try fileHandle.close()
                } else {
                    try entry.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            AppLogger.shared.error("Journal", "Не удалось записать журнал транскриптов", details: error.localizedDescription)
        }
    }
}
