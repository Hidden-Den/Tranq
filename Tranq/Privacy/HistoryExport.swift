import AppKit
import Darwin
import Foundation

enum HistoryExportError: Error, Equatable {
    /// История не открыта: выгружать нечего и спрашивать подтверждение нельзя.
    case notUnlocked
    /// Файл или папка не записались.
    case writeFailed
    /// Не нашлось свободного имени подпапки.
    case nameTaken
}

/// Итог выгрузки. `skippedAudio` — файлы звука и таймингов, которые не расшифровались.
struct HistoryExportResult: Equatable {
    let folder: URL
    let exportedNotes: Int
    let exportedAudio: Int
    let skippedAudio: Int
}

extension HistoryMigration {
    /// Выгружает открытую копию истории в новую подпапку `Tranq history <дата>` внутри `folder`:
    /// `history.json` и `Audio` с расшифрованными `<uuid>.wav` и `<uuid>.segments.json`.
    ///
    /// Только при `unlocked`, иначе `notUnlocked` и ничего не пишется. Заметки берутся из `items` хранилища.
    /// Функция `async`: список читается на главном потоке, остальное идёт в фоне, потому что
    /// расшифровка может показать диалог ключа. Звать можно откуда угодно, но не блокируя главный поток.
    /// Всё пишется во временную соседнюю папку и переименовывается в конце, при сбое она удаляется.
    /// Готовая подпапка никогда не перезаписывается: при совпадении имени добавляется число.
    /// Не расшифровавшееся аудио пропускается и считается, `HistoryKeyError` прерывает выгрузку.
    /// `now` и `beforeCommit` — для тестов.
    static func exportCopy(store: HistoryStore,
                           vault: HistoryVault,
                           to folder: URL,
                           now: Date = Date(),
                           beforeCommit: (() throws -> Void)? = nil) async throws -> HistoryExportResult {
        let (state, items) = await MainActor.run { (store.lockState, store.items) }
        guard state == .unlocked else { throw HistoryExportError.notUnlocked }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try writeExport(items: items, store: store, vault: vault, to: folder,
                                    now: now, beforeCommit: beforeCommit)
                })
            }
        }
    }

    private static func writeExport(items: [TranscriptionItem],
                                    store: HistoryStore,
                                    vault: HistoryVault,
                                    to folder: URL,
                                    now: Date,
                                    beforeCommit: (() throws -> Void)?) throws -> HistoryExportResult {
        let fm = FileManager.default
        let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        let temp = folder.appendingPathComponent(".Tranq-export-\(UUID().uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: owner)
        do {
            let audioFolder = temp.appendingPathComponent("Audio", isDirectory: true)
            try fm.createDirectory(at: audioFolder, withIntermediateDirectories: false, attributes: owner)

            var exportedAudio = 0
            var skipped = 0
            for item in items {
                if let wav = try readForExport({ try store.audioData(for: item.id) }, skipped: &skipped) {
                    try writePrivate(wav, to: audioFolder.appendingPathComponent("\(item.id.uuidString).wav"))
                    exportedAudio += 1
                }
                let timings = try readForExport({
                    try vault.readBlob(id: item.id, purpose: .timings)
                        ?? (try? Data(contentsOf: store.audioDirectory
                            .appendingPathComponent("\(item.id.uuidString).segments.json")))
                }, skipped: &skipped)
                if let timings {
                    try writePrivate(timings, to: audioFolder.appendingPathComponent("\(item.id.uuidString).segments.json"))
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try writePrivate(try encoder.encode(items), to: temp.appendingPathComponent("history.json"))

            try beforeCommit?()
            let final = try commit(temp, in: folder, now: now)
            return HistoryExportResult(folder: final, exportedNotes: items.count,
                                       exportedAudio: exportedAudio, skippedAudio: skipped)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Отказ ключа и запертая история прерывают выгрузку, порча одного файла только считается.
    private static func readForExport(_ read: () throws -> Data?, skipped: inout Int) throws -> Data? {
        do {
            return try read()
        } catch let error as HistoryKeyError {
            throw error
        } catch let error as HistoryAudioError {
            throw error
        } catch {
            skipped += 1
            return nil
        }
    }

    /// Файл 0600 с момента создания.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HistoryExportError.writeFailed
        }
    }

    /// Переименовывает временную папку в свободное имя. `RENAME_EXCL` не даёт заменить готовую папку.
    private static func commit(_ temp: URL, in folder: URL, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "Tranq history \(formatter.string(from: now))"
        for number in 1...1000 {
            let name = number == 1 ? base : "\(base) \(number)"
            let target = folder.appendingPathComponent(name, isDirectory: true)
            if renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw HistoryExportError.writeFailed }
        }
        throw HistoryExportError.nameTaken
    }
}

/// Кнопка «Выгрузить»: выбор папки на главном потоке, выгрузка в фоне.
@MainActor
enum HistoryExportAction {
    /// Отмена панели молча ничего не делает. Не расшифровавшееся аудио уходит в лог.
    static func run(store: HistoryStore = .shared,
                    vault: @MainActor () -> HistoryVault? = { HistoryLockCoordinator.shared.vault },
                    chooseFolder: @MainActor () async -> URL? = chooseFolder) async throws {
        guard store.lockState == .unlocked, let vault = vault() else { throw HistoryExportError.notUnlocked }
        guard let folder = await chooseFolder() else { return }
        let result = try await HistoryMigration.exportCopy(store: store, vault: vault, to: folder)
        if result.skippedAudio > 0 {
            AppLogger.shared.error("History", "Выгрузка без части звука", details: "файлов: \(result.skippedAudio)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([result.folder])
    }

    /// Панель только с папками. `nil`, если человек отменил.
    static func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Выберите папку")
        panel.prompt = String(localized: "Выгрузить")
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}
