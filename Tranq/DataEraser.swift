import Foundation

/// «Стереть историю»: всё, где остаётся речь пользователя.
/// Заметки со звуком в обеих формах, открытой и конвертами, журнал диктовок для «Вставить оригинал речи»,
/// лог, куда пишутся распознанные тексты, и ключ истории.
enum DataEraser {
    /// Шаги стирания. Сбой одного не останавливает остальные.
    enum Step: String {
        case history, envelopes, journal, log, key
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
        let fm = FileManager.default

        history.clearAll()
        // Дождаться очереди хранилища: конверт, записанный до стирания, не переживёт его.
        history.waitForIO()
        if history.lockState != .off {
            // Открытая копия, оставшаяся от прерванной миграции.
            let plain = history.directory.appendingPathComponent("history.json")
            if fm.fileExists(atPath: plain.path), (try? fm.removeItem(at: plain)) == nil { failed.append(.history) }
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
            logger.error("DataEraser", "Стирание не завершено: \(failed.map(\.rawValue).joined(separator: ", "))")
        }
        return failed
    }

    private static func hasSealedBlobs(in vault: HistoryVault) -> Bool {
        let blobs = (try? FileManager.default.contentsOfDirectory(at: vault.audioDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return blobs.contains { $0.pathExtension == "sealed" }
    }
}
