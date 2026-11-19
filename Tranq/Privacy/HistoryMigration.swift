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
        case enable, disable
    }

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
                try await offMain { try run.sealCopies(notes: notes, journal: journal) }
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

        let clean = await offMain { () -> Bool in
            store.waitForIO()
            return run.finish(journal: journal)
        }
        setFlag(true)
        // Метка снимается и при остатках: здесь сверено содержимое, а повтор на запуске сверил бы
        // только наличие конвертов. Остаток — открытый файл, а не потеря.
        if !clean { AppLogger.shared.warn("History", "После включения замка остались открытые файлы") }
        removeMarker(in: layout.directory)
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

    // MARK: - Выключение

    /// Выключает замок. Звать с главного потока после подтверждения личности.
    /// `setFlag(false)` зовётся только после успеха всей миграции. `afterCopies` — для тестов.
    @MainActor
    static func disable(store: HistoryStore,
                        journal: TranscriptJournal,
                        vault: HistoryVault,
                        deactivate: (@MainActor () -> Void)? = nil,
                        setFlag: @MainActor (Bool) -> Void,
                        afterCopies: (@MainActor () -> Void)? = nil) async throws {
        let layout = Layout(directory: vault.directory)
        guard store.lockState != .off else { throw HistoryMigrationError.wrongState }
        guard !layout.hasMarker else { throw HistoryMigrationError.interrupted }
        let run = DisableRun(layout: layout, vault: vault)

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
                // Точка фиксации: открытая копия проверена. `history.json` встаёт на место до перехода,
                // потому что `off` читает его сразу.
                try run.placeHistory()
                try writeMarker(.disable, in: layout.directory)
                (deactivate ?? defaultDeactivation(store: store, journal: journal))()
                committed = true
                break
            }
            guard committed else { throw HistoryMigrationError.busy }
        } catch {
            await offMain { run.abort() }
            throw error
        }

        let clean = await offMain { () -> Bool in
            // Обход wav, поставленный до перехода, успевает закончиться раньше, чем появятся открытые wav.
            store.waitForIO()
            return run.finish(journal: journal)
        }
        setFlag(false)
        if clean { removeMarker(in: layout.directory) }
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
        cleanupHalfDone(vault: HistoryVault(directory: directory, key: HistoryKeyFactory.make()),
                        lockEnabled: AppPreferences.historyLockEnabled(in: AppEnvironment.defaults),
                        setLockEnabled: { AppPreferences.shared.historyLockEnabled = $0 })
    }

    /// Доводит или убирает прерванную миграцию. Ключ не нужен, диалогов нет.
    ///
    /// - Метка `enable`: конверты проверены до метки. Убираются открытые файлы, у которых есть конверт,
    ///   `history.json` — только если каждая его заметка лежит конвертом. Флаг поднимается.
    /// - Метка `disable`: открытые копии проверены до метки. Копии встают на место, убираются конверты,
    ///   у которых есть открытый двойник. Флаг опускается.
    /// - Без метки и с выключенным флагом: включение упало до фиксации, исходники целы. Убираются конверты,
    ///   у которых есть открытый двойник: заметка из `history.json`, `.wav`, `.segments.json`.
    ///   Конверт без двойника остаётся: удалять его не за чем, это единственная копия.
    /// - Без метки и с включённым флагом: выключение упало до фиксации. Открытые копии убираются,
    ///   если конверт на месте, иначе копия становится открытым файлом и хранилище её запечатает.
    ///   Если рядом лежит `history.json`, он не удаляется и не перезаписывается. При пустой `Notes/`
    ///   он единственный источник: флаг опускается, и хранилище читает его как раньше.
    ///   При непустой `Notes/` конверты главные, а файл вольётся в историю при выключении замка.
    static func cleanupHalfDone(vault: HistoryVault, lockEnabled: Bool, setLockEnabled: (Bool) -> Void) {
        let layout = Layout(directory: vault.directory)
        layout.removeJournalCopies()
        switch layout.marker {
        case .enable?:
            let clean = layout.finishEnable(audio: nil, timings: nil, notes: nil)
            setLockEnabled(true)
            if clean { removeMarker(in: layout.directory) }
        case .disable?:
            let clean = layout.finishDisable()
            setLockEnabled(false)
            if clean { removeMarker(in: layout.directory) }
        case nil where !lockEnabled:
            layout.removeEnvelopesWithPlainTwins()
        case nil:
            layout.dropUncommittedRestores()
            if FileManager.default.fileExists(atPath: layout.history.path) {
                if layout.files(in: layout.notes, suffix: ".note").isEmpty {
                    AppLogger.shared.warn("History", "Замок выключен: конвертов нет, открытая история на месте")
                    setLockEnabled(false)
                } else {
                    AppLogger.shared.warn("History", "Открытая история рядом с конвертами сохранена")
                }
            }
        }
    }

    // MARK: - Метка

    static func writeMarker(_ direction: Direction, in directory: URL) throws {
        try Data(direction.rawValue.utf8).write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    private static func removeMarker(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(markerName))
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

    /// Запечатывает строку журнала как есть и сразу открывает обратно для сверки.
    static func sealVerified(_ line: String, key: HistoryKeyProviding) throws -> String {
        let plain = Data(line.utf8)
        let envelope = try HistoryCrypto.seal(plain, purpose: .journal, publicKey: key.publicKey)
        let sealed = try JSONEncoder().encode(envelope).base64EncodedString()
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
        var historyRestore: URL { history.appendingPathExtension(restoreExtension) }
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

        var marker: Direction? {
            guard let data = FileManager.default.contents(atPath: markerURL.path) else { return nil }
            return Direction(rawValue: String(decoding: data, as: UTF8.self))
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
        /// `true`, если ничего открытого не осталось.
        func finishEnable(audio verifiedAudio: Set<UUID>?, timings verifiedTimings: Set<UUID>?,
                          notes verified: Set<TranscriptionItem>?) -> Bool {
            var clean = true
            if exists(history) {
                if let plain = plainHistory(), plain.allSatisfy({ covers($0, verified: verified) }) {
                    clean = remove(history) && clean
                } else {
                    AppLogger.shared.warn("History", "history.json оставлен: не каждая заметка лежит конвертом")
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

        /// Довести выключение: копии на место, затем убрать конверты, у которых есть открытый двойник.
        func finishDisable() -> Bool {
            var clean = true
            let fm = FileManager.default
            if exists(historyRestore) {
                if Darwin.rename(historyRestore.path, history.path) != 0 { clean = false }
            }
            for suffix in [".wav", ".segments.json"] {
                for (id, copy) in files(in: audio, suffix: suffix + "." + restoreExtension) {
                    let plain = suffix == ".wav" ? plainAudio(id) : plainTimings(id)
                    if !exists(plain) {
                        if Darwin.rename(copy.path, plain.path) != 0 { clean = false }
                    } else if fm.contentsEqual(atPath: copy.path, andPath: plain.path) {
                        clean = remove(copy) && clean
                    } else {
                        // Открытый файл новее копии: оба остаются, конверт не трогаем.
                        clean = false
                    }
                }
            }
            return removeEnvelopesWithPlainTwins() && clean
        }

        /// Убирает конверты, у которых есть открытый двойник. `true`, если конвертов не осталось.
        @discardableResult
        func removeEnvelopesWithPlainTwins() -> Bool {
            var clean = true
            let plainIDs = Set((plainHistory() ?? []).map(\.id))
            for (id, url) in files(in: notes, suffix: ".note") {
                if plainIDs.contains(id) { clean = remove(url) && clean } else { clean = false }
            }
            for (id, url) in files(in: audio, suffix: ".wav.sealed") {
                if exists(plainAudio(id)) { clean = remove(url) && clean } else { clean = false }
            }
            for (id, url) in files(in: audio, suffix: ".segments.sealed") {
                if exists(plainTimings(id)) { clean = remove(url) && clean } else { clean = false }
            }
            return clean
        }

        /// Выключение не дошло до фиксации: конверты главные. Копия убирается, если конверт на месте,
        /// иначе встаёт открытым файлом, который хранилище запечатает.
        func dropUncommittedRestores() {
            remove(historyRestore)
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
        /// Ключ новый, если ему нечего держать. Если на диске остались конверты без двойника,
        /// прежний ключ держит их и не пересоздаётся.
        func prepareKey() throws {
            layout.removeEnvelopesWithPlainTwins()
            let orphans = !layout.files(in: layout.notes, suffix: ".note").isEmpty
                || !layout.files(in: layout.audio, suffix: ".wav.sealed").isEmpty
                || !layout.files(in: layout.audio, suffix: ".segments.sealed").isEmpty
            if !vault.key.exists || !orphans {
                try vault.key.create()
                keyCreated = true
            }
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
        /// Сбой журнала не страшен: открытые строки остаются, ничего не теряется.
        func finish(journal: TranscriptJournal) -> Bool {
            var clean = true
            do {
                let key = vault.key
                let map = journalMap
                try journal.rewriteForMigration(sealing: .sealed(key: key)) { line in
                    if let sealed = map[line] { return sealed }
                    // Строка дописана после копий: открытая — запечатать и сверить, конверт — как есть.
                    return HistoryMigration.isSealedLine(line) ? line : try HistoryMigration.sealVerified(line, key: key)
                }
            } catch {
                clean = false
                AppLogger.shared.error("History", "Журнал не запечатан при включении замка",
                                       details: error.localizedDescription)
            }
            return layout.finishEnable(audio: audio, timings: timings, notes: notes) && clean
        }

        /// Отмена до фиксации. Удаляются только конверты этого прогона: исходники не тронуты.
        /// Ключ уходит, только если его создал этот прогон и ни одного его конверта не осталось на диске:
        /// проверенных конвертов до фиксации нет, а следы чужих прогонов держат прежний ключ.
        func abort() {
            removeWritten()
            let leftovers = written.contains { layout.exists($0) }
            if keyCreated && !leftovers { try? vault.key.destroy() }
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
            // Ожидающая конверта правка новее файла, конверт новее старого открытого файла.
            var seen = Set<UUID>()
            let merged = HistoryVault.newestFirst((pending + sealed + existing).filter { seen.insert($0.id).inserted })
            let data = try JSONEncoder().encode(merged)
            written.append(layout.historyRestore)
            try data.write(to: layout.historyRestore, options: .atomic)
            guard let back = try? JSONDecoder().decode([TranscriptionItem].self,
                                                       from: Data(contentsOf: layout.historyRestore)),
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
        func placeHistory() throws {
            guard Darwin.rename(layout.historyRestore.path, layout.history.path) == 0 else {
                throw HistoryMigrationError.verificationFailed
            }
            written.removeAll { $0 == layout.historyRestore }
        }

        /// После фиксации: копии встают на место, журнал открывается, конверты с открытым двойником уходят.
        /// Ключ остаётся: строки, которые не удалось открыть, без него не прочесть никогда.
        func finish(journal: TranscriptJournal) -> Bool {
            var clean = true
            do {
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
                        return line
                    }
                }
            } catch {
                clean = false
                AppLogger.shared.error("History", "Журнал не открыт при выключении замка",
                                       details: error.localizedDescription)
            }
            return layout.finishDisable() && clean
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
