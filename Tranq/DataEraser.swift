import Foundation

/// «Стереть историю»: всё, где остаётся речь пользователя.
/// Заметки со звуком в обеих формах, открытой и конвертами, журнал диктовок для «Вставить оригинал речи»,
/// лог, куда пишутся распознанные тексты, и ключ истории.
enum DataEraser {
    /// Шаги стирания. Сбой одного не останавливает остальные.
    enum Step: String {
        case history, envelopes, migrationCopies, journal, log, key
    }

    /// `vault` и `key` равны `nil` — этот шаг пропускается: так тесты не трогают настоящий ключ.
    /// Флаг замка не меняется: новый ключ заводит `HistoryLockCoordinator`.
    /// Возвращает шаги, которые не удались.
    @discardableResult
    static func eraseAll(
        history: HistoryStore = .shared,
        journal: TranscriptJournal = .shared,
        logger: AppLogger = .shared,
        vault: HistoryVault? = nil,
        key: HistoryKeyProviding? = nil
    ) -> [Step] {
        var failed: [Step] = []
        var leftFiles: [String] = []
        let fm = FileManager.default

        history.clearAll()
        // Дождаться очереди хранилища: конверт, записанный до стирания, не переживёт его.
        // flush сразу пишет пустой список, а не после задержки: выход сразу после стирания не вернёт заметки.
        history.flush()
        if history.lockState != .off {
            // Открытая копия, оставшаяся от прерванной миграции.
            let plain = history.directory.appendingPathComponent("history.json")
            if fm.fileExists(atPath: plain.path), (try? fm.removeItem(at: plain)) == nil { failed.append(.history) }
        }

        // Копии прерванной миграции и открытый звук: иначе уборка при запуске вернёт стёртое.
        let left = removeMigrationCopies(in: history.directory)
        if !left.isEmpty {
            failed.append(.migrationCopies)
            leftFiles += left
        }

        if let vault {
            vault.deleteAll()
            if vault.noteFileCount() > 0 || hasSealedBlobs(in: vault) { failed.append(.envelopes) }
        }

        // Журнал стирается целиком, открытый и запечатанный.
        journal.clear()
        logger.clear()

        if let key {
            do { try key.destroy() } catch { failed.append(.key) }
        }

        if !failed.isEmpty {
            logger.error("DataEraser", "Стирание не завершено: \(failed.map(\.rawValue).joined(separator: ", "))",
                         details: leftFiles.isEmpty ? nil : leftFiles.joined(separator: ", "))
        }
        return failed
    }

    /// Открытые копии миграции, её метка, копии журнала, открытый звук и тайминги.
    /// Конверты не трогает: их убирает `HistoryVault.deleteAll`. Возвращает имена файлов, что остались.
    private static func removeMigrationCopies(in directory: URL) -> [String] {
        let layout = HistoryMigration.Layout(directory: directory)
        var urls = [layout.historyRestore, layout.historyCandidate, layout.markerURL]
        for suffix in [".wav", ".segments.json"] {
            urls += layout.files(in: layout.audio, suffix: suffix).values
            urls += layout.files(in: layout.audio, suffix: suffix + "." + HistoryMigration.restoreExtension).values
        }
        urls += TranscriptJournal.migrationFiles(in: directory)
            .map { $0.appendingPathExtension(TranscriptJournal.migrationSuffix) }
        let fm = FileManager.default
        return urls.compactMap { url in
            guard fm.fileExists(atPath: url.path) else { return nil }
            return (try? fm.removeItem(at: url)) == nil ? url.lastPathComponent : nil
        }
    }

    private static func hasSealedBlobs(in vault: HistoryVault) -> Bool {
        let blobs = (try? FileManager.default.contentsOfDirectory(at: vault.audioDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return blobs.contains { $0.pathExtension == "sealed" }
    }
}
