import CryptoKit
import Darwin
import Foundation

enum HistoryMigrationError: Error, Equatable {
    /// Копия не совпала с исходником при чтении обратно.
    case verificationFailed
    /// История менялась на каждой попытке: тихого момента для переключения не нашлось.
    case busy
    /// На диске след прерванной миграции, его доводит следующий запуск.
    case interrupted
    /// Открытый `history.json` есть, но не читается: затирать его нельзя.
    case unreadablePlainHistory
    /// Замок уже в нужном положении.
    case wrongState
    /// Пробная сверка ключа на пустой истории не открылась: ключ нечитаем.
    case keyProbeFailed
}

/// Перевод истории между открытыми файлами и конвертами в обе стороны.
///
/// Включение: ключ, конверты рядом с исходниками, чтение каждого обратно и сверка,
/// метка фиксации, переключение хранилища, и только потом удаление `history.json`, открытых `.wav`,
/// `.segments.json` и замена открытого журнала. Флаг поднимается последним.
/// Выключение — то же в обратную сторону: открытые копии рядом, сверка, метка, переключение, удаление конвертов.
///
/// Метка `history-migration` пишется только после проверки и означает «новые файлы полные, старые можно убрать».
/// Без неё на следующем запуске побеждают исходники, с ней — запуск доводит миграцию до конца.
/// Удаление обычное, без перезаписи блоков.
enum HistoryMigration {
    enum Direction: String {
        /// Включение зафиксировано: убрать открытые файлы и запечатать журнал.
        case enable
        /// Включение доделано, кроме журнала: его запечатать по публичному ключу.
        case enableJournal
        /// Выключение зафиксировано, флаг ещё не опущен.
        case disable
    }

    /// Что запуск нашёл и о чём стоит сказать человеку.
    enum LaunchNotice: Equatable {
        /// Замок выключен: ключа и конвертов нет, единственная копия истории — открытый файл.
        case lockTurnedOff
        /// Рядом с конвертами лежит открытая история. Замок не выключен, файл не тронут.
        case leftoverPlainHistory
    }

    /// Итог уборки при этом запуске. Пишется один раз до создания координатора.
    static var launchNotice: LaunchNotice?

    static let markerName = "history-migration"
    /// Суффикс открытой копии при выключении: обход wav её не видит и не запечатывает.
    static let restoreExtension = "restore"
    /// Сколько раз копии переснимаются, если история менялась во время миграции.
    static let attempts = 3

    // MARK: - Включение

    /// Включает замок. Звать с главного потока, тяжёлая работа идёт в фоне.
    /// `activate` переключает хранилище и журнал на конверты, по умолчанию как `HistoryLockCoordinator`.
    /// `setFlag(true)` зовётся только после успеха всей миграции. `afterCopies` — для тестов.
    @MainActor
    static func enable(store: HistoryStore,
                       journal: TranscriptJournal,
                       vault: HistoryVault,
                       activate: (@MainActor () -> Void)? = nil,
                       setFlag: @MainActor (Bool) -> Void,
                       afterCopies: (@MainActor () -> Void)? = nil) async throws {
        let layout = Layout(directory: vault.directory)
        guard store.lockState == .off else { throw HistoryMigrationError.wrongState }
        guard !layout.hasMarker else { throw HistoryMigrationError.interrupted }
        let run = EnableRun(layout: layout, vault: vault)

        do {
            var fingerprint = enableFingerprint(store: store, layout: layout)
            try await offMain { try run.prepareKey() }
            var committed = false
            for _ in 0..<attempts {
                let notes = assignCreatedAt(fingerprint.items)
                try await offMain { try run.sealCopiesReplacingUnreadableKey(notes: notes, journal: journal) }
                afterCopies?()
                let current = enableFingerprint(store: store, layout: layout)
                guard current == fingerprint else {
                    fingerprint = current
                    continue
                }
                // Точка фиксации: копии полные и проверены, хранилище ещё ничего не записало мимо них.
                try writeMarker(.enable, in: layout.directory)
                store.excludeFromAudioSweep(run.audio)
                (activate ?? defaultActivation(store: store, journal: journal, vault: vault))()
                committed = true
                break
            }
            guard committed else { throw HistoryMigrationError.busy }
        } catch {
            await offMain { run.abort() }
            throw error
        }

        let journalSealed = await offMain { () -> Bool in
            store.waitForIO()
            return run.finish(journal: journal)
        }
        setFlag(true)
        // Остатки открытых файлов метку не держат: здесь сверено содержимое, а повтор на запуске
        // сверил бы только наличие конвертов. Держит метку только незапечатанный журнал:
        // запуск запечатает его по публичному ключу.
        if journalSealed {
            removeMarker(in: layout.directory)
        } else {
            try? writeMarker(.enableJournal, in: layout.directory)
        }
    }

    /// Хранилище и журнал на конвертах, как при включении в `HistoryLockCoordinator`.
    @MainActor
    private static func defaultActivation(store: HistoryStore, journal: TranscriptJournal,
                                          vault: HistoryVault) -> @MainActor () -> Void {
        {
            store.attach(vault: vault)
            journal.setSealing(.sealed(key: vault.key))
            store.applyLockState(.locked)
        }
    }

    /// Снимок для сверки: заметки в памяти и открытые файлы аудио и таймингов.
    @MainActor
    private static func enableFingerprint(store: HistoryStore, layout: Layout) -> Fingerprint {
        store.flush()
        let files = Array(layout.files(in: layout.audio, suffix: ".wav").values)
            + Array(layout.files(in: layout.audio, suffix: ".segments.json").values)
        return Fingerprint(items: store.items, pending: [], files: stamps(files))
    }

    /// У заметок прошлых версий нет `createdAt`. Ставим его от начала минуты заметки плюс микросекунды
    /// по месту в массиве: внутри одной минуты порядок массива, новые первыми, переживает сортировку,
    /// а заметки с настоящим `createdAt` той же минуты остаются выше. Без даты основа — 2001 год.
    static func assignCreatedAt(_ items: [TranscriptionItem]) -> [TranscriptionItem] {
        let formatter = DateFormatter()
        formatter.dateFormat = TranscriptionItem.dateFormat
        let count = items.count
        return items.enumerated().map { index, item in
            guard item.createdAt == nil else { return item }
            var copy = item
            let base = formatter.date(from: item.date) ?? Date(timeIntervalSinceReferenceDate: 0)
            copy.createdAt = base.addingTimeInterval(Double(count - index) * 1e-6)
            return copy
        }
    }

    /// Слияние без потерь. Группы идут по старшинству: у одной заметки первая версия сохраняет id.
    /// Та же заметка с тем же содержимым — `createdAt` не в счёт — сливается в одну. Другая версия
    /// той же заметки остаётся отдельной заметкой с новым id и `createdAt` чуть раньше двойника,
    /// чтобы стоять рядом с ним: лишнюю человек удалит сам, а потерянную не вернёт никто.
    static func mergeKeepingBoth(_ groups: [[TranscriptionItem]]) -> [TranscriptionItem] {
        var versions: [UUID: (first: TranscriptionItem, seen: Set<TranscriptionItem>)] = [:]
        var result: [TranscriptionItem] = []
        for item in groups.joined() {
            var normalized = item
            normalized.createdAt = nil
            guard var entry = versions[item.id] else {
                versions[item.id] = (item, [normalized])
                result.append(item)
                continue
            }
            guard entry.seen.insert(normalized).inserted else { continue }
            versions[item.id] = entry
            var copy = item
            copy.id = UUID()
            let step = Double(entry.seen.count - 1) * 1e-6
            copy.createdAt = entry.first.createdAt.map { $0.addingTimeInterval(-step) } ?? item.createdAt
            result.append(copy)
        }
        return HistoryVault.newestFirst(result)
    }

    // MARK: - Выключение

    /// Выключает замок. Звать с главного потока после подтверждения личности.
    /// `setFlag(false)` зовётся только после успеха всей миграции. `afterCopies` — для тестов.
    @MainActor
    static func disable(store: HistoryStore,
                        journal: TranscriptJournal,
                        vault: HistoryVault,
                        deactivate: (@MainActor () -> Void)? = nil,
                        reactivate: (@MainActor () -> Void)? = nil,
                        setFlag: @MainActor (Bool) -> Void,
                        afterCopies: (@MainActor () -> Void)? = nil) async throws {
        let layout = Layout(directory: vault.directory)
        guard store.lockState != .off else { throw HistoryMigrationError.wrongState }
        guard !layout.hasMarker else { throw HistoryMigrationError.interrupted }
        let run = DisableRun(layout: layout, vault: vault)
        var markerWritten = false

        do {
            var fingerprint = disableFingerprint(store: store, layout: layout)
            var committed = false
            for _ in 0..<attempts {
                try await offMain { try run.restoreCopies(pending: store.pendingNotes(), journal: journal) }
                afterCopies?()
                let current = disableFingerprint(store: store, layout: layout)
                guard current == fingerprint else {
                    fingerprint = current
                    continue
                }
                // Точка фиксации: открытая копия проверена. Метка раньше копии: без метки открытая история
                // рядом с конвертами осталась бы без хозяина. `history.json` встаёт на место до перехода,
                // потому что `off` читает его сразу.
                try writeMarker(.disable, in: layout.directory, digest: run.historyDigest)
                markerWritten = true
                try run.placeHistory()
                (deactivate ?? defaultDeactivation(store: store, journal: journal))()
                committed = true
                break
            }
            guard committed else { throw HistoryMigrationError.busy }
        } catch {
            await offMain { run.abort() }
            // До перехода ничего не переключено: копии убраны, конверты целы, метка не нужна.
            if markerWritten { removeMarker(in: layout.directory) }
            throw error
        }

        do {
            try await offMain {
                // Обход wav, поставленный до перехода, успевает закончиться раньше, чем появятся открытые wav.
                store.waitForIO()
                try run.openJournal(journal: journal)
            }
        } catch {
            // Журнал не открылся: замок возвращается, флаг не опускался. Конверты целы,
            // открытые копии этого выключения убираются по тем же правилам, что и на запуске.
            (reactivate ?? defaultActivation(store: store, journal: journal, vault: vault))()
            let digest = run.historyDigest
            _ = await offMain { () -> LaunchNotice? in
                store.waitForIO()
                return layout.rollbackDisable(digest: digest, key: vault.key, journal: journal)
            }
            removeMarker(in: layout.directory)
            throw error
        }

        await offMain { run.finishFiles() }
        setFlag(false)
        // Порченые конверты и прочие остатки метку не держат: все шаги пройдены.
        removeMarker(in: layout.directory)
    }

    /// Как выключение в `HistoryLockCoordinator`.
    @MainActor
    private static func defaultDeactivation(store: HistoryStore,
                                            journal: TranscriptJournal) -> @MainActor () -> Void {
        {
            journal.setSealing(.off)
            store.applyLockState(.off)
            store.attach(vault: nil)
        }
    }

    /// Снимок для сверки: файлы конвертов, ожидающие заметки и, если история открыта, заметки в памяти.
    @MainActor
    private static func disableFingerprint(store: HistoryStore, layout: Layout) -> Fingerprint {
        store.flush()
        let files = Array(layout.files(in: layout.notes, suffix: ".note").values)
            + Array(layout.files(in: layout.audio, suffix: ".wav.sealed").values)
            + Array(layout.files(in: layout.audio, suffix: ".segments.sealed").values)
        let pending = store.pendingNotes().sorted { $0.id.uuidString < $1.id.uuidString }
        let items = store.lockState == .unlocked ? store.items : []
        return Fingerprint(items: items, pending: pending, files: stamps(files))
    }

    // MARK: - Следующий запуск

    /// Зовётся при запуске до первого чтения истории.
    static func cleanupAtLaunch(directory: URL) {
        launchNotice = cleanupHalfDone(vault: HistoryVault(directory: directory, key: HistoryKeyFactory.make()),
                                       lockEnabled: AppPreferences.historyLockEnabled(in: AppEnvironment.defaults),
                                       setLockEnabled: { AppPreferences.shared.historyLockEnabled = $0 })
    }

    /// Доводит или откатывает прерванную миграцию. Диалогов нет: нужен только публичный ключ.
    ///
    /// - Метка `enable`: конверты проверены до метки. Убираются открытые файлы, у которых есть конверт,
    ///   `history.json` — только если каждая его заметка лежит конвертом. Журнал запечатывается
    ///   по публичному ключу; если не вышло, метка становится `enableJournal`. Флаг поднимается.
    /// - Метка `enableJournal`: только журнал. Метка уходит, когда он запечатан.
    /// - Метка `disable` и флаг выключен: флаг уже опущен, доделать уборку конвертов.
    /// - Метка `disable` и флаг включён: выключение не дошло до флага, откат, см. `rollbackDisable`.
    /// - Без метки и с выключенным флагом: включение упало до фиксации, исходники целы. Убираются конверты,
    ///   у которых есть открытый двойник. Конверт без двойника остаётся: это единственная копия.
    /// - Без метки и с включённым флагом: копии незафиксированного выключения убираются.
    ///   `history.json` не удаляется и не перезаписывается никогда. Замок выключается, только если
    ///   ключа нет, `Notes/` пуст и нет ни запечатанного аудио, ни запечатанных строк журнала:
    ///   тогда открытый файл — единственная копия истории. Иначе файл остаётся, и человеку говорят о нём.
    @discardableResult
    static func cleanupHalfDone(vault: HistoryVault, lockEnabled: Bool,
                                setLockEnabled: (Bool) -> Void) -> LaunchNotice? {
        let layout = Layout(directory: vault.directory)
        layout.removeJournalCopies()
        let marker = layout.marker
        switch marker?.direction {
        case .enable?:
            layout.finishEnable(audio: nil, timings: nil, notes: nil)
            setLockEnabled(true)
            finishJournalAtLaunch(layout: layout, key: vault.key)
            return layout.exists(layout.history) ? .leftoverPlainHistory : nil
        case .enableJournal?:
            setLockEnabled(true)
            finishJournalAtLaunch(layout: layout, key: vault.key)
            return nil
        case .disable? where !lockEnabled:
            layout.finishDisable()
            removeMarker(in: layout.directory)
            return nil
        case .disable?:
            let notice = layout.rollbackDisable(digest: marker?.digest, key: vault.key)
            removeMarker(in: layout.directory)
            return notice
        case nil where !lockEnabled:
            // Своя копия прогона без метки — это незафиксированное выключение: расшифрованное не остаётся.
            layout.remove(layout.historyCandidate)
            layout.removeEnvelopesWithPlainTwins()
            return nil
        case nil:
            // Своя копия прогона до метки: в ней расшифрованная история, а всё, что в ней есть, лежит
            // в конвертах, в открытых файлах или жило только в памяти и пропадает при сбое, как и раньше.
            layout.remove(layout.historyCandidate)
            layout.dropUncommittedRestores()
            guard layout.exists(layout.history) else { return nil }
            let onlyCopy = !vault.key.exists
                && layout.files(in: layout.notes, suffix: ".note").isEmpty
                && layout.files(in: layout.audio, suffix: ".wav.sealed").isEmpty
                && layout.files(in: layout.audio, suffix: ".segments.sealed").isEmpty
                && !layout.hasSealedJournal
            if onlyCopy {
                AppLogger.shared.warn("History", "Замок выключен: ключа и конвертов нет, открытая история на месте")
                setLockEnabled(false)
                return .lockTurnedOff
            }
            AppLogger.shared.warn("History", "Открытая история рядом с конвертами сохранена", details: "history.json")
            return .leftoverPlainHistory
        }
    }

    /// Журнал после зафиксированного включения: открытые строки запечатываются по публичному ключу,
    /// конверты остаются как есть, поэтому повтор безопасен. Удача снимает метку, неудача оставляет `enableJournal`.
    private static func finishJournalAtLaunch(layout: Layout, key: HistoryKeyProviding) {
        do {
            try layout.sealJournal(key: key)
            removeMarker(in: layout.directory)
        } catch {
            AppLogger.shared.error("History", "Журнал не запечатан при запуске", details: error.localizedDescription)
            try? writeMarker(.enableJournal, in: layout.directory)
        }
    }

    // MARK: - Метка

    struct Marker: Equatable {
        let direction: Direction
        /// SHA-256 проверенной открытой истории при выключении.
        let digest: String?
    }

    static func writeMarker(_ direction: Direction, in directory: URL, digest: String? = nil) throws {
        let text = [direction.rawValue, digest].compactMap { $0 }.joined(separator: "\n")
        try Data(text.utf8).write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    private static func removeMarker(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(markerName))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Общее

    private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    struct FileStamp: Equatable {
        let size: Int
        let modified: Date?
    }

    struct Fingerprint: Equatable {
        var items: [TranscriptionItem]
        var pending: [TranscriptionItem]
        var files: [String: FileStamp]
    }

    private static func stamps(_ urls: [URL]) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            result[url.lastPathComponent] = FileStamp(size: values?.fileSize ?? -1,
                                                      modified: values?.contentModificationDate)
        }
        return result
    }

    /// Строка журнала — конверт в base64, а не открытый JSON.
    static func isSealedLine(_ line: String) -> Bool {
        guard let data = Data(base64Encoded: line) else { return false }
        return (try? JSONDecoder().decode(SealedEnvelope.self, from: data)) != nil
    }

    /// Запечатывает строку журнала как есть. Нужен только публичный ключ.
    static func sealLine(_ line: String, key: HistoryKeyProviding) throws -> String {
        let envelope = try HistoryCrypto.seal(Data(line.utf8), purpose: .journal, publicKey: key.publicKey)
        return try JSONEncoder().encode(envelope).base64EncodedString()
    }

    /// Запечатывает строку журнала и сразу открывает обратно для сверки.
    static func sealVerified(_ line: String, key: HistoryKeyProviding) throws -> String {
        let sealed = try sealLine(line, key: key)
        guard try openLine(sealed, key: key) == line else { throw HistoryMigrationError.verificationFailed }
        return sealed
    }

    /// Открывает запечатанную строку журнала.
    static func openLine(_ line: String, key: HistoryKeyProviding) throws -> String {
        guard let data = Data(base64Encoded: line) else { throw HistoryMigrationError.verificationFailed }
        let envelope = try JSONDecoder().decode(SealedEnvelope.self, from: data)
        let plain = try HistoryCrypto.open(envelope, purpose: .journal, key: key)
        return String(decoding: plain, as: UTF8.self)
    }
}

// MARK: - Файлы истории

extension HistoryMigration {
    /// Имена файлов истории. Конверты — как в `HistoryVault`, открытые — как в `HistoryStore`.
    struct Layout {
        let directory: URL

        var history: URL { directory.appendingPathComponent("history.json") }
        /// Копия истории, оставшаяся от прошлого сбоя. Миграция её не перезаписывает.
        var historyRestore: URL { history.appendingPathExtension(restoreExtension) }
        /// Собственная копия прогона выключения. Встаёт на место `history.json` только после фиксации.
        var historyCandidate: URL { history.appendingPathExtension("restoring") }
        var notes: URL { directory.appendingPathComponent("Notes", isDirectory: true) }
        var audio: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
        var markerURL: URL { directory.appendingPathComponent(markerName) }

        func note(_ id: UUID) -> URL { notes.appendingPathComponent("\(id.uuidString).note") }
        func plainAudio(_ id: UUID) -> URL { audio.appendingPathComponent("\(id.uuidString).wav") }
        func plainTimings(_ id: UUID) -> URL { audio.appendingPathComponent("\(id.uuidString).segments.json") }
        func sealedAudio(_ id: UUID) -> URL { audio.appendingPathComponent("\(id.uuidString).wav.sealed") }
        func sealedTimings(_ id: UUID) -> URL { audio.appendingPathComponent("\(id.uuidString).segments.sealed") }
        func restore(_ url: URL) -> URL { url.appendingPathExtension(restoreExtension) }

        var hasMarker: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

        /// Метка, если она есть. Нечитаемая метка считается меткой выключения без отпечатка:
        /// откат по ней ничего непроверенного не удаляет.
        var marker: Marker? {
            guard let data = FileManager.default.contents(atPath: markerURL.path) else { return nil }
            let parts = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            guard let direction = parts.first.flatMap(Direction.init(rawValue:)) else {
                return Marker(direction: .disable, digest: nil)
            }
            return Marker(direction: direction, digest: parts.count > 1 ? parts[1] : nil)
        }

        var journalFiles: [URL] { TranscriptJournal.migrationFiles(in: directory) }

        var hasSealedJournal: Bool {
            TranscriptJournal.hasSealedLines(in: directory, isSealed: HistoryMigration.isSealedLine)
        }

        /// Открытые строки журнала — в конверты по публичному ключу, конверты — как есть. Повтор безопасен.
        /// Звать, пока журналом никто не пишет: на запуске или после ожидания очереди журнала.
        func sealJournal(key: HistoryKeyProviding) throws {
            try TranscriptJournal.rewrite(journalFiles) { line in
                HistoryMigration.isSealedLine(line) ? line : try HistoryMigration.sealLine(line, key: key)
            }
        }

        /// `<uuid><suffix>` в папке. Чужие имена не попадают.
        func files(in folder: URL, suffix: String) -> [UUID: URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var result: [UUID: URL] = [:]
            for name in names where name.hasSuffix(suffix) {
                let stem = String(name.dropLast(suffix.count))
                guard let id = UUID(uuidString: stem), id.uuidString == stem else { continue }
                result[id] = folder.appendingPathComponent(name)
            }
            return result
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        /// `nil`, если файла нет или он не читается.
        func plainHistory() -> [TranscriptionItem]? {
            guard let data = FileManager.default.contents(atPath: history.path) else { return nil }
            return try? JSONDecoder().decode([TranscriptionItem].self, from: data)
        }

        /// Удаляет файл. `true`, если его больше нет.
        @discardableResult
        func remove(_ url: URL) -> Bool {
            guard exists(url) else { return true }
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                AppLogger.shared.error("History", "Файл не удалён при миграции замка",
                                       details: "\(url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }

        /// Копии журнала живут только внутри одной операции в его очереди: оставшиеся — след сбоя.
        /// Исходники журнала при этом не тронуты.
        func removeJournalCopies() {
            for name in ["transcript_journal.jsonl", "transcript_journal.1.jsonl"] {
                remove(directory.appendingPathComponent(name).appendingPathExtension(TranscriptJournal.migrationSuffix))
            }
        }

        /// Довести включение. Открытый файл уходит, только если рядом лежит его конверт.
        /// `notes` — проверенные заметки этого прогона; `nil` на запуске, тогда хватает наличия конверта.
        /// `true`, если ничего открытого не осталось. Остаток пишется в лог именем файла.
        @discardableResult
        func finishEnable(audio verifiedAudio: Set<UUID>?, timings verifiedTimings: Set<UUID>?,
                          notes verified: Set<TranscriptionItem>?) -> Bool {
            var clean = true
            if exists(history) {
                if let plain = plainHistory(), plain.allSatisfy({ covers($0, verified: verified) }) {
                    clean = remove(history) && clean
                } else {
                    AppLogger.shared.warn("History", "Открытый файл оставлен: не каждая заметка лежит конвертом",
                                          details: history.lastPathComponent)
                    clean = false
                }
            }
            for (id, url) in files(in: audio, suffix: ".wav") where verifiedAudio?.contains(id) ?? true {
                if exists(sealedAudio(id)) { clean = remove(url) && clean }
            }
            for (id, url) in files(in: audio, suffix: ".segments.json") where verifiedTimings?.contains(id) ?? true {
                if exists(sealedTimings(id)) { clean = remove(url) && clean }
            }
            return clean
        }

        private func covers(_ item: TranscriptionItem, verified: Set<TranscriptionItem>?) -> Bool {
            guard exists(note(item.id)) else { return false }
            guard let verified else { return true }
            var normalized = item
            normalized.createdAt = nil
            return verified.contains(normalized)
        }

        /// Довести выключение после того, как флаг опущен или вот-вот опустится:
        /// копии на место, затем убрать конверты, у которых есть открытый двойник.
        func finishDisable() {
            let fm = FileManager.default
            if exists(historyCandidate), !exists(history) {
                Darwin.rename(historyCandidate.path, history.path)
            }
            if exists(historyRestore), !exists(history) {
                Darwin.rename(historyRestore.path, history.path)
            }
            removeLeftoverIfCovered()
            for suffix in [".wav", ".segments.json"] {
                for (id, copy) in files(in: audio, suffix: suffix + "." + restoreExtension) {
                    let plain = suffix == ".wav" ? plainAudio(id) : plainTimings(id)
                    if !exists(plain) {
                        Darwin.rename(copy.path, plain.path)
                    } else if fm.contentsEqual(atPath: copy.path, andPath: plain.path) {
                        remove(copy)
                    } else {
                        // Открытый файл новее копии: оба остаются, конверт не трогаем.
                        AppLogger.shared.warn("History", "Копия оставлена рядом с открытым файлом", details: copy.lastPathComponent)
                    }
                }
            }
            removeEnvelopesWithPlainTwins()
        }

        private static let blankID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        /// Каждая заметка `items` лежит в `plain` тем же содержимым. Id и `createdAt` не в счёт:
        /// слияние даёт другой версии новый id.
        func coveredByContent(_ items: [TranscriptionItem], in plain: [TranscriptionItem]) -> Bool {
            func content(_ item: TranscriptionItem) -> TranscriptionItem {
                var copy = item
                copy.id = Self.blankID
                copy.createdAt = nil
                return copy
            }
            let known = Set(plain.map(content))
            return items.allSatisfy { known.contains(content($0)) }
        }

        /// Оставшаяся копия уходит, только если всё её содержимое уже в `history.json`.
        func removeLeftoverIfCovered() {
            guard exists(historyRestore) else { return }
            guard let data = FileManager.default.contents(atPath: historyRestore.path),
                  let items = try? JSONDecoder().decode([TranscriptionItem].self, from: data),
                  let plain = plainHistory(), coveredByContent(items, in: plain) else {
                AppLogger.shared.warn("History", "Копия истории оставлена", details: historyRestore.lastPathComponent)
                return
            }
            remove(historyRestore)
        }

        /// Убирает конверты, у которых есть открытый двойник. Остальные остаются и пишутся в лог именем файла.
        /// `true`, если конвертов не осталось.
        @discardableResult
        func removeEnvelopesWithPlainTwins() -> Bool {
            var kept: [URL] = []
            let plainIDs = Set((plainHistory() ?? []).map(\.id))
            for (id, url) in files(in: notes, suffix: ".note") {
                if !plainIDs.contains(id) || !remove(url) { kept.append(url) }
            }
            for (id, url) in files(in: audio, suffix: ".wav.sealed") {
                if !exists(plainAudio(id)) || !remove(url) { kept.append(url) }
            }
            for (id, url) in files(in: audio, suffix: ".segments.sealed") {
                if !exists(plainTimings(id)) || !remove(url) { kept.append(url) }
            }
            for url in kept {
                AppLogger.shared.warn("History", "Конверт без открытого двойника оставлен", details: url.lastPathComponent)
            }
            return kept.isEmpty
        }

        /// Откат выключения, которое не дошло до флага. Замок остаётся, конверты главные и не трогаются.
        ///
        /// Удаляется только то, чьё содержимое целиком лежит в конвертах, а не только id:
        /// - отпечаток в метке есть, только если копия истории собрана из одних конвертов, без заметок,
        ///   ждавших конверта. Такая заметка — например, правка X' рядом со старым `X.note` — живёт
        ///   только в открытой копии, поэтому без отпечатка копия не удаляется никогда;
        /// - открытая история уходит, если её байты совпадают с отпечатком и у каждой её заметки есть конверт:
        ///   тогда каждая заметка расшифрована из своего конверта. Иначе в ней есть то, чего нет в конвертах,
        ///   — правка без конверта, правка после перехода, заметка без конверта, — и она остаётся;
        /// - непоставленная копия истории уходит по тому же правилу или если каждая её заметка такой же
        ///   лежит в `history.json`; иначе встаёт на место или вливается в `history.json` без потерь;
        /// - копии аудио и таймингов уходят, если конверт на месте, иначе становятся открытыми файлами;
        /// - открытые тайминги уходят, только если их байты равны расшифрованному двойнику. Расшифровка
        ///   возможна только в работающем приложении, на запуске диалога нет, и тайминги остаются;
        /// - открытые строки журнала снова запечатываются по публичному ключу.
        /// Возвращает `.leftoverPlainHistory`, если открытая история осталась.
        /// `journal` — живой журнал, если откат идёт в работающем приложении: тогда запечатка идёт в его очереди.
        func rollbackDisable(digest: String?, key: HistoryKeyProviding,
                             journal: TranscriptJournal? = nil) -> LaunchNotice? {
            let noteIDs = Set(files(in: notes, suffix: ".note").keys)
            // Своя копия прогона, если сбой пришёл между меткой и заменой. Оставшаяся от прошлых сбоев
            // копия разбирается ниже без отпечатка: из одних конвертов она не собиралась.
            settleHistoryCopy(historyCandidate, noteIDs: noteIDs, digest: digest)
            if exists(history) {
                let bytes = FileManager.default.contents(atPath: history.path)
                let placed = digest != nil && bytes.map { HistoryMigration.digest($0) == digest } == true
                let covered = plainHistory()?.allSatisfy { noteIDs.contains($0.id) } ?? false
                if placed && covered {
                    remove(history)
                } else {
                    AppLogger.shared.warn("History", "Открытая история оставлена при откате", details: history.lastPathComponent)
                }
            }
            dropUncommittedRestores()
            if journal != nil {
                let vault = HistoryVault(directory: directory, key: key)
                for (id, url) in files(in: audio, suffix: ".segments.json") where exists(sealedTimings(id)) {
                    let plain = FileManager.default.contents(atPath: url.path)
                    if let plain, (try? vault.readBlob(id: id, purpose: .timings)) == plain { remove(url) }
                }
            }
            do {
                if let journal {
                    try journal.rewriteForMigration(sealing: .sealed(key: key)) { line in
                        HistoryMigration.isSealedLine(line) ? line : try HistoryMigration.sealLine(line, key: key)
                    }
                } else {
                    try sealJournal(key: key)
                }
            } catch {
                AppLogger.shared.error("History", "Журнал не запечатан при откате", details: error.localizedDescription)
            }
            return exists(history) ? .leftoverPlainHistory : nil
        }

        /// Непоставленная копия истории: уходит, только если всё в ней есть в другом месте.
        /// По конвертам — только при отпечатке, совпавшем с байтами копии, см. `rollbackDisable`.
        private func settleHistoryCopy(_ historyRestore: URL, noteIDs: Set<UUID>, digest: String?) {
            guard exists(historyRestore) else { return }
            guard let data = FileManager.default.contents(atPath: historyRestore.path),
                  let copy = try? JSONDecoder().decode([TranscriptionItem].self, from: data) else {
                AppLogger.shared.warn("History", "Копия истории не читается и оставлена", details: historyRestore.lastPathComponent)
                return
            }
            let hasPlain = exists(history)
            guard let plain = hasPlain ? plainHistory() : [] else {
                AppLogger.shared.warn("History", "Копия истории оставлена", details: historyRestore.lastPathComponent)
                return
            }
            let plainSet = Set(plain)
            let fromEnvelopes = digest != nil && HistoryMigration.digest(data) == digest
            if copy.allSatisfy({ (fromEnvelopes && noteIDs.contains($0.id)) || plainSet.contains($0) }) {
                remove(historyRestore)
                return
            }
            guard hasPlain else {
                Darwin.rename(historyRestore.path, history.path)
                return
            }
            // Слияние без потерь: открытый файл первым, другая версия заметки из копии остаётся рядом.
            let merged = HistoryMigration.mergeKeepingBoth([plain, copy])
            guard let encoded = try? JSONEncoder().encode(merged),
                  (try? encoded.write(to: history, options: .atomic)) != nil,
                  plainHistory() == merged else {
                AppLogger.shared.warn("History", "Копия истории оставлена", details: historyRestore.lastPathComponent)
                return
            }
            remove(historyRestore)
        }

        /// Выключение не дошло до фиксации: конверты главные. Копия убирается, если конверт на месте,
        /// иначе встаёт открытым файлом, который хранилище запечатает.
        func dropUncommittedRestores() {
            settleHistoryCopy(historyRestore, noteIDs: Set(files(in: notes, suffix: ".note").keys), digest: nil)
            for (id, copy) in files(in: audio, suffix: ".wav." + restoreExtension) {
                if exists(sealedAudio(id)) || exists(plainAudio(id)) { remove(copy) } else { Darwin.rename(copy.path, plainAudio(id).path) }
            }
            for (id, copy) in files(in: audio, suffix: ".segments.json." + restoreExtension) {
                if exists(sealedTimings(id)) || exists(plainTimings(id)) { remove(copy) } else { Darwin.rename(copy.path, plainTimings(id).path) }
            }
        }
    }
}

// MARK: - Прогон включения

extension HistoryMigration {
    /// Состояние одного включения. Методы зовутся по очереди с фоновых потоков.
    final class EnableRun: @unchecked Sendable {
        let layout: Layout
        let vault: HistoryVault
        /// Всё, что записал этот прогон: при отмене удаляется только это.
        private(set) var written: [URL] = []
        private(set) var keyCreated = false
        private(set) var audio: Set<UUID> = []
        private(set) var timings: Set<UUID> = []
        /// Проверенные заметки без `createdAt`: им сверяется `history.json` перед удалением.
        private(set) var notes: Set<TranscriptionItem> = []
        /// Открытая строка журнала → проверенный конверт.
        private(set) var journalMap: [String: String] = [:]

        init(layout: Layout, vault: HistoryVault) {
            self.layout = layout
            self.vault = vault
        }

        /// При выключенном замке конверты — только следы сбоев. Двойники открытых файлов убираются.
        /// Существующий ключ не пересоздаётся никогда: `create()` начинает с `destroy()`, а ключ может
        /// держать запечатанные строки журнала или конверты прошлых включений. Ключ создаётся, только если его нет.
        func prepareKey() throws {
            layout.removeEnvelopesWithPlainTwins()
            if !vault.key.exists {
                try vault.key.create()
                keyCreated = true
            }
        }

        /// `sealCopies` с выходом из нечитаемого ключа. Ключ есть, но не работает — например, папка данных
        /// перенесена на другой Mac или файл публичного ключа испорчен. Если ключ ничего не держит —
        /// ни конверта заметки, аудио или таймингов, ни запечатанной строки журнала, — замена ничего
        /// не теряет: ключ создаётся заново один раз за прогон, и копии пишутся и сверяются ещё раз.
        /// Если держит хоть что-то, ключ не трогается и ошибка уходит наружу.
        func sealCopiesReplacingUnreadableKey(notes items: [TranscriptionItem], journal: TranscriptJournal) throws {
            do {
                try sealCopies(notes: items, journal: journal)
            } catch where !keyCreated && Self.isUnreadableKey(error) {
                removeWritten()
                guard !holdsKeyData else { throw error }
                AppLogger.shared.warn("History", "Нечитаемый ключ истории заменён: он ничего не держал")
                try vault.key.create()
                keyCreated = true
                try sealCopies(notes: items, journal: journal)
            }
        }

        /// Ключ не читается: его нет на этом Mac, файл публичного ключа испорчен,
        /// или пробная сверка на пустой истории не открылась.
        static func isUnreadableKey(_ error: Error) -> Bool {
            switch error {
            case HistoryKeyError.unavailable, HistoryCryptoError.unsupportedKey, HistoryMigrationError.keyProbeFailed:
                return true
            default:
                return false
            }
        }

        /// На диске есть то, что открывается только этим ключом.
        var holdsKeyData: Bool {
            !layout.files(in: layout.notes, suffix: ".note").isEmpty
                || !layout.files(in: layout.audio, suffix: ".wav.sealed").isEmpty
                || !layout.files(in: layout.audio, suffix: ".segments.sealed").isEmpty
                || layout.hasSealedJournal
        }

        /// Пишет конверты рядом с исходниками и читает каждый обратно. Ничего открытого не удаляет.
        /// Каждая попытка начинается с чистого листа: заметка, удалённая между попытками, не воскреснет.
        func sealCopies(notes items: [TranscriptionItem], journal: TranscriptJournal) throws {
            removeWritten()
            audio = []; timings = []; notes = []; journalMap = [:]

            for (item, original) in Self.uniqueIDs(items) {
                written.append(layout.note(item.id))
                try vault.writeNote(item)
                guard try vault.readNote(id: item.id) == item else { throw HistoryMigrationError.verificationFailed }
                var normalized = item
                normalized.createdAt = nil
                notes.insert(normalized)
                if let original {
                    normalized.id = original
                    notes.insert(normalized)
                }
            }
            for (id, url) in layout.files(in: layout.audio, suffix: ".wav") {
                try sealBlob(url, id: id, purpose: .audio, into: &audio)
            }
            for (id, url) in layout.files(in: layout.audio, suffix: ".segments.json") {
                try sealBlob(url, id: id, purpose: .timings, into: &timings)
            }
            for line in Set(journal.migrationLines()) where !isSealedLine(line) {
                journalMap[line] = try sealVerified(line, key: vault.key)
            }
            // Сверять было нечего: ключ всё равно проверяется, иначе нечитаемый ключ прошёл бы молча.
            if notes.isEmpty && audio.isEmpty && timings.isEmpty && journalMap.isEmpty {
                do {
                    _ = try sealVerified("", key: vault.key)
                } catch let error as HistoryKeyError {
                    throw error
                } catch HistoryCryptoError.unsupportedKey {
                    throw HistoryCryptoError.unsupportedKey
                } catch {
                    // Запечатано этим же ключом и не открылось: точка публичного ключа чужая.
                    throw HistoryMigrationError.keyProbeFailed
                }
            }
        }

        private func sealBlob(_ url: URL, id: UUID, purpose: HistoryCryptoPurpose, into set: inout Set<UUID>) throws {
            let data = try Data(contentsOf: url)
            written.append(try vault.blobURL(id, purpose))
            try vault.writeBlob(data, id: id, purpose: purpose)
            guard try vault.readBlob(id: id, purpose: purpose) == data else {
                throw HistoryMigrationError.verificationFailed
            }
            set.insert(id)
        }

        /// После фиксации: журнал заменяется проверенными конвертами, открытые файлы с конвертом уходят.
        /// Сбой журнала не страшен: открытые строки остаются, их запечатает следующий запуск.
        /// `true`, если журнал запечатан.
        func finish(journal: TranscriptJournal) -> Bool {
            var journalSealed = true
            do {
                let key = vault.key
                let map = journalMap
                try journal.rewriteForMigration(sealing: .sealed(key: key)) { line in
                    if let sealed = map[line] { return sealed }
                    // Строка дописана после копий: открытая — запечатать и сверить, конверт — как есть.
                    return HistoryMigration.isSealedLine(line) ? line : try HistoryMigration.sealVerified(line, key: key)
                }
            } catch {
                journalSealed = false
                AppLogger.shared.error("History", "Журнал не запечатан при включении замка",
                                       details: error.localizedDescription)
            }
            layout.finishEnable(audio: audio, timings: timings, notes: notes)
            return journalSealed
        }

        /// Отмена до фиксации. Удаляются только конверты этого прогона: исходники не тронуты.
        /// Ключ уходит, только если его создал этот прогон и на диске не осталось ничего, что он мог бы
        /// держать: ни одного конверта заметки, аудио или таймингов и ни одной запечатанной строки журнала.
        /// До фиксации проверенных конвертов нет, но любой оставшийся конверт держит ключ на всякий случай.
        func abort() {
            removeWritten()
            if keyCreated && !holdsKeyData { try? vault.key.destroy() }
        }

        private func removeWritten() {
            written = written.filter { !layout.remove($0) }
        }

        /// Повтор id в `history.json` — сбой прошлых версий. Одинаковые копии сливаются,
        /// разные получают новый id, чтобы ни один текст не пропал.
        static func uniqueIDs(_ items: [TranscriptionItem]) -> [(item: TranscriptionItem, original: UUID?)] {
            var seen: [UUID: TranscriptionItem] = [:]
            var result: [(item: TranscriptionItem, original: UUID?)] = []
            for item in items {
                if let first = seen[item.id] {
                    // `createdAt` мог проставиться по месту в массиве: сравниваем без него.
                    var left = first, right = item
                    left.createdAt = nil
                    right.createdAt = nil
                    guard left != right else { continue }
                    var copy = item
                    copy.id = UUID()
                    result.append((copy, item.id))
                } else {
                    seen[item.id] = item
                    result.append((item, nil))
                }
            }
            return result
        }
    }
}

// MARK: - Прогон выключения

extension HistoryMigration {
    /// Состояние одного выключения. Методы зовутся по очереди: копии в фоне, `placeHistory` на главном.
    final class DisableRun: @unchecked Sendable {
        let layout: Layout
        let vault: HistoryVault
        private(set) var written: [URL] = []
        /// Конверт журнала → открытая строка.
        private(set) var journalMap: [String: String] = [:]
        /// SHA-256 проверенной открытой истории: по нему откат узнаёт свою копию.
        private(set) var historyDigest: String?
        /// Копия истории, оставшаяся от прошлого сбоя. Читается один раз, вливается в каждую попытку.
        /// Сам файл прогон не перезаписывает: слияние идёт в свою копию `historyCandidate`,
        /// поэтому ни отмена, ни сбой не оставляют рядом с конвертами расшифрованное сверх прежнего.
        /// Файл уходит только после замены, когда всё его содержимое лежит в поставленной истории.
        private var leftoverRestore: [TranscriptionItem]?

        init(layout: Layout, vault: HistoryVault) {
            self.layout = layout
            self.vault = vault
        }

        /// Пишет открытые копии рядом с конвертами и сверяет их. Конверты не трогает.
        /// `history.json`, если он уже есть, не перезаписывается: его заметки вливаются в копию.
        func restoreCopies(pending: [TranscriptionItem], journal: TranscriptJournal) throws {
            removeWritten()
            journalMap = [:]

            let sealed = try vault.readNotes()
            if !vault.corruptedNoteFiles.isEmpty {
                AppLogger.shared.warn("History", "Нечитаемые конверты оставлены на месте",
                                      details: "\(vault.corruptedNoteFiles.count)")
            }
            var existing: [TranscriptionItem] = []
            if layout.exists(layout.history) {
                guard let plain = layout.plainHistory() else { throw HistoryMigrationError.unreadablePlainHistory }
                existing = plain
            }
            if leftoverRestore == nil {
                // Чужая копия не перезаписывается: её заметки вливаются в свою.
                if layout.exists(layout.historyRestore) {
                    guard let data = FileManager.default.contents(atPath: layout.historyRestore.path),
                          let items = try? JSONDecoder().decode([TranscriptionItem].self, from: data) else {
                        throw HistoryMigrationError.unreadablePlainHistory
                    }
                    leftoverRestore = items
                } else {
                    leftoverRestore = []
                }
            }
            let leftover = leftoverRestore ?? []
            // Ожидающая конверта правка — по построению новая версия своей заметки: её конверт не записался.
            // Она заменяет конверт с тем же id. Для открытых файлов против конвертов и прочих пар разные
            // версии остаются обе: остаток отката бывает новее своего конверта.
            let pendingIDs = Set(pending.map(\.id))
            let current = pending + sealed.filter { !pendingIDs.contains($0.id) }
            let merged = HistoryMigration.mergeKeepingBoth([current, existing, leftover])
            let data = try JSONEncoder().encode(merged)
            // Отпечаток только для копии из одних конвертов. Заметка, ждавшая конверта, или заметка
            // прежнего открытого файла есть лишь здесь: без отпечатка откат копию не удалит.
            historyDigest = pending.isEmpty && existing.isEmpty && leftover.isEmpty ? HistoryMigration.digest(data) : nil
            written.append(layout.historyCandidate)
            try data.write(to: layout.historyCandidate, options: .atomic)
            guard let back = try? JSONDecoder().decode([TranscriptionItem].self,
                                                       from: Data(contentsOf: layout.historyCandidate)),
                  back == merged else { throw HistoryMigrationError.verificationFailed }

            for (id, _) in layout.files(in: layout.audio, suffix: ".wav.sealed") where !layout.exists(layout.plainAudio(id)) {
                try restoreBlob(id: id, purpose: .audio, to: layout.restore(layout.plainAudio(id)))
            }
            for (id, _) in layout.files(in: layout.audio, suffix: ".segments.sealed") where !layout.exists(layout.plainTimings(id)) {
                try restoreBlob(id: id, purpose: .timings, to: layout.restore(layout.plainTimings(id)))
            }
            for line in Set(journal.migrationLines()) where isSealedLine(line) {
                do {
                    let plain = try openLine(line, key: vault.key)
                    if !plain.contains("\n") { journalMap[line] = plain }
                } catch let error as HistoryKeyError {
                    throw error
                } catch {
                    // Порченая строка остаётся конвертом.
                }
            }
        }

        /// Порченый конверт аудио не держит выключение: он остаётся на диске без открытой копии.
        private func restoreBlob(id: UUID, purpose: HistoryCryptoPurpose, to copy: URL) throws {
            let data: Data
            do {
                guard let opened = try vault.readBlob(id: id, purpose: purpose) else { return }
                data = opened
            } catch let error as HistoryKeyError {
                throw error
            } catch {
                AppLogger.shared.warn("History", "Нечитаемый конверт оставлен на месте", details: id.uuidString)
                return
            }
            written.append(copy)
            try data.write(to: copy, options: .atomic)
            guard (try? Data(contentsOf: copy)) == data else { throw HistoryMigrationError.verificationFailed }
        }

        /// На главном, в точке фиксации: проверенная копия встаёт на место `history.json` одной заменой.
        /// Оставшаяся от прошлого сбоя копия уходит, только если всё её содержимое теперь в `history.json`.
        func placeHistory() throws {
            guard Darwin.rename(layout.historyCandidate.path, layout.history.path) == 0 else {
                throw HistoryMigrationError.verificationFailed
            }
            written.removeAll { $0 == layout.historyCandidate }
            layout.removeLeftoverIfCovered()
        }

        /// После перехода, первым шагом: журнал открывается. Бросает при сбое, тогда выключение откатывается.
        func openJournal(journal: TranscriptJournal) throws {
            let key = vault.key
            let map = journalMap
            try journal.rewriteForMigration(sealing: .off) { line in
                if let plain = map[line] { return plain }
                guard HistoryMigration.isSealedLine(line) else { return line }
                do {
                    let plain = try HistoryMigration.openLine(line, key: key)
                    return plain.contains("\n") ? line : plain
                } catch let error as HistoryKeyError {
                    throw error
                } catch {
                    // Порченая строка остаётся конвертом.
                    return line
                }
            }
        }

        /// После журнала: копии встают на место, конверты с открытым двойником уходят.
        /// Ключ остаётся: строки и конверты, которые не удалось открыть, без него не прочесть никогда.
        func finishFiles() {
            layout.finishDisable()
        }

        /// Отмена до фиксации: убираются только открытые копии этого прогона, конверты не тронуты.
        func abort() {
            removeWritten()
        }

        private func removeWritten() {
            written = written.filter { !layout.remove($0) }
        }
    }
}
