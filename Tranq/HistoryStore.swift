import Foundation

struct TranscriptionItem: Identifiable, Codable, Hashable {
    var id = UUID()
    let date: String
    let text: String
    let duration: String
    var speedup: Double?
    var isUnread: Bool? = false
    /// Сырая расшифровка до очистки; пусто у ручных заметок и у заметок прошлых версий.
    var spokenText: String?
    /// Момент создания: стабильный порядок заметок одной минуты. У заметок прошлых версий пусто.
    var createdAt: Date? = Date()

    /// Показывать ли переключатель «Итог / Сказано»: только если сказанное отличается от итога.
    var showsSpokenToggle: Bool {
        guard let spoken = spokenText?.trimmingCharacters(in: .whitespacesAndNewlines), !spoken.isEmpty else { return false }
        return spoken != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func withText(_ newText: String) -> TranscriptionItem {
        TranscriptionItem(id: id, date: date, text: newText, duration: duration, speedup: speedup, isUnread: isUnread, spokenText: spokenText, createdAt: createdAt)
    }

    static let dateFormat = "dd.MM.yyyy, HH:mm"

    static func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        return formatter.string(from: Date())
    }
}

/// Замок истории глазами хранилища.
enum HistoryLockState: Equatable {
    /// Замка нет: общий `history.json`, как раньше.
    case off
    /// `items` пуст, новые заметки пишутся конвертами.
    case locked
    /// Конверты прочитаны в `items`, каждая правка пишет файл своей заметки.
    case unlocked
    /// Конверты есть, но ключ на этом Mac не читается.
    case keyUnavailable
}

extension HistoryLockState {
    /// Заметки скрыты: на экране заглушка, списка и поиска нет.
    var hidesHistory: Bool { self == .locked || self == .keyUnavailable }
}

/// Аудио заметки недоступно: история заперта или ключ не читается.
enum HistoryAudioError: Error, Equatable {
    case locked
}

/// История заметок, их аудио и тайминги слов.
///
/// Мутации — с главного потока. Запись на диск откладывается на полсекунды и
/// выполняется в фоне, поэтому частые правки не кодируют весь JSON на главном потоке.
/// При включённом замке общий массив не пишется никогда: у каждой заметки свой конверт.
final class HistoryStore: ObservableObject {
    static let shared: HistoryStore = {
        // До первого чтения `history.json`: прерванная миграция замка доводится или убирается.
        if !AppEnvironment.isRunningTests { HistoryMigration.cleanupAtLaunch(directory: defaultDirectory) }
        // Включённый замок не читает открытый файл даже на миг до проводки.
        let locked = AppPreferences.historyLockEnabled(in: AppEnvironment.defaults)
        return HistoryStore(directory: defaultDirectory, lockState: locked ? .locked : .off)
    }()

    @Published var items: [TranscriptionItem] = [] {
        didSet {
            guard !isLoading, lockState == .off else { return }
            scheduleSave()
        }
    }

    @Published private(set) var lockState: HistoryLockState {
        didSet { updateReadAccess() }
    }
    /// Сколько заметок и аудио ждут записи конверта: хранилища нет или запись не удалась.
    @Published private(set) var sealFailureCount = 0

    let directory: URL
    var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    private var isLoading = false
    private var pendingSave: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "tranq.history.io", qos: .utility)
    private let saveDelay: TimeInterval
    private var vault: HistoryVault?
    /// Растёт на каждом переходе: запоздавшее чтение конвертов не оживит `items` после запирания.
    private var generation = 0
    /// Заметки без записанного конверта. Только на `ioQueue`. Открытым файлом не подменяются никогда.
    private var pendingSeal: [UUID: TranscriptionItem] = [:]
    /// Аудио, чей открытый `.wav` ещё не запечатан. Только на `ioQueue`.
    private var pendingAudio: Set<UUID> = []
    /// Аудио, уже запечатанное и проверенное миграцией: обход открытых wav его не трогает. Только на `ioQueue`.
    private var sweepSkip: Set<UUID> = []
    /// Состояние и хранилище для чтения аудио с любого потока.
    private let accessLock = NSLock()
    private var readAccess: (state: HistoryLockState, vault: HistoryVault?) = (.off, nil)

    static var defaultDirectory: URL { AppEnvironment.dataDirectory }

    /// `directory` подменяется в тестах, чтобы не трогать настоящую историю пользователя.
    init(directory: URL, saveDelay: TimeInterval = 0.5, vault: HistoryVault? = nil,
         lockState: HistoryLockState = .off) {
        self.directory = directory
        self.saveDelay = saveDelay
        self.vault = vault
        self.lockState = .off
        updateReadAccess()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if lockState == .off { load() } else { applyLockState(lockState) }
    }

    // MARK: - Замок

    /// Подключает или снимает хранилище конвертов на живом сторе. Состояние меняет `applyLockState`.
    func attach(vault: HistoryVault?) {
        self.vault = vault
        updateReadAccess()
        retryPendingSeals()
    }

    private func updateReadAccess() {
        accessLock.lock()
        readAccess = (lockState, vault)
        accessLock.unlock()
    }

    /// Переход замка, с главного потока. `unlocked` читает конверты в фоне и публикует их на главном;
    /// отказ подтверждения оставляет `locked`, потерянный ключ даёт `keyUnavailable`.
    /// `locked` и `keyUnavailable` сразу очищают `items`. `off` перечитывает `history.json`.
    /// `completion` зовётся на главном потоке, когда переход и все записи до него закончены.
    func applyLockState(_ state: HistoryLockState, completion: (() -> Void)? = nil) {
        generation += 1
        let current = generation
        pendingSave?.cancel()
        pendingSave = nil
        lockState = state
        retryPendingSeals()
        switch state {
        case .off:
            // Заметки без конверта не запечатываются после выключения, а встают в открытую историю.
            let adopted = ioQueue.sync { () -> [TranscriptionItem] in
                defer { pendingSeal.removeAll(); pendingAudio.removeAll(); publishSealFailures() }
                return Array(pendingSeal.values)
            }
            load()
            adopt(adopted)
            finish(completion)
        case .locked, .keyUnavailable:
            setItemsQuietly([])
            finish(completion)
        case .unlocked:
            setItemsQuietly([])
            let vault = vault
            // Чтение на той же очереди, что и записи: заметки, записанные раньше, в него попадут.
            ioQueue.async { [weak self] in
                // Незапечатанные заметки видны из памяти.
                let pending = (self?.pendingSeal.values ?? [:].values).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                let result = vault.map { vault in Result { try vault.readNotes() } } ?? .success([])
                DispatchQueue.main.async { [weak self] in
                    defer { completion?() }
                    guard let self, self.generation == current else { return }
                    switch result {
                    case .success(let loaded):
                        // Вставленное за время чтения уже записано отдельно и стоит первым.
                        var seen = Set(self.items.map(\.id))
                        var merged = self.items
                        for item in pending + loaded where seen.insert(item.id).inserted { merged.append(item) }
                        self.setItemsQuietly(merged)
                    case .failure(HistoryKeyError.denied):
                        self.lockState = .locked
                        self.setItemsQuietly([])
                    case .failure:
                        self.lockState = .keyUnavailable
                        self.setItemsQuietly([])
                    }
                }
            }
        }
    }

    /// Заметки, не попавшие в загруженный `history.json`, встают в список новыми первыми и сохраняются.
    private func adopt(_ pending: [TranscriptionItem]) {
        let known = Set(items.map(\.id))
        let missing = pending.filter { !known.contains($0.id) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        guard !missing.isEmpty else { return }
        items.insert(contentsOf: missing, at: 0)
    }

    // MARK: - Для миграции замка

    /// Заметки, ждущие конверта. Можно звать с любого потока, кроме очереди хранилища.
    func pendingNotes() -> [TranscriptionItem] {
        ioQueue.sync { Array(pendingSeal.values) }
    }

    /// Ждёт все записи хранилища. Можно звать с любого потока, кроме очереди хранилища.
    func waitForIO() {
        ioQueue.sync {}
    }

    /// Эти wav уже лежат проверенными конвертами: обход при запирании не запечатывает их второй раз,
    /// открытые файлы удаляет миграция.
    func excludeFromAudioSweep(_ ids: Set<UUID>) {
        ioQueue.sync { sweepSkip.formUnion(ids) }
    }

    /// Ждёт записей, поставленных раньше, затем зовёт `completion` на главном.
    private func finish(_ completion: (() -> Void)?) {
        guard let completion else { return }
        ioQueue.async { DispatchQueue.main.async(execute: completion) }
    }

    private func setItemsQuietly(_ newItems: [TranscriptionItem]) {
        isLoading = true
        items = newItems
        isLoading = false
    }

    private var isSealed: Bool { lockState != .off }

    /// Пишет конверт одной заметки. Нужен только публичный ключ.
    /// Неудача оставляет заметку в `pendingSeal` до следующей попытки.
    private func seal(_ item: TranscriptionItem) {
        let vault = vault
        ioQueue.async { [self] in
            pendingSeal[item.id] = item
            drainPendingSeals(vault)
        }
    }

    private func retryPendingSeals() {
        let vault = vault
        let sealsAudio = isSealed
        ioQueue.async { [self] in
            // Без замка ожидающие заметки забирает переход в `off`, конвертом они не пишутся.
            guard sealsAudio else { return }
            drainPendingSeals(vault)
            // Открытые wav, оставшиеся с прошлого запуска, тоже запечатываются.
            pendingAudio.formUnion(plainAudioIDs().filter { !sweepSkip.contains($0) })
            drainPendingAudio(vault)
        }
    }

    /// Только на `ioQueue`. В лог идёт id заметки, текст — никогда.
    private func drainPendingSeals(_ vault: HistoryVault?) {
        if let vault {
            for (id, item) in pendingSeal {
                do {
                    try vault.writeNote(item)
                    pendingSeal[id] = nil
                } catch {
                    AppLogger.shared.error("History", "Конверт заметки не записан", details: "\(id.uuidString): \(error)")
                }
            }
        }
        publishSealFailures()
    }

    private func publishSealFailures() {
        let count = pendingSeal.count + pendingAudio.count
        DispatchQueue.main.async { [weak self] in
            if self?.sealFailureCount != count { self?.sealFailureCount = count }
        }
    }

    /// При запертой истории заметка уходит только в свой конверт, `items` не трогается.
    private var isHidden: Bool { lockState.hidesHistory }

    // MARK: - Операции с заметками

    @discardableResult
    func addNote(text: String) -> UUID {
        let item = TranscriptionItem(id: UUID(), date: TranscriptionItem.formattedNow(), text: text, duration: "—", speedup: nil, isUnread: false)
        insert(item)
        return item.id
    }

    func insert(_ item: TranscriptionItem) {
        if isSealed { seal(item) }
        if !isHidden { items.insert(item, at: 0) }
    }

    func markAsRead(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].isUnread == true else { return }
        items[idx].isUnread = false
        if isSealed { seal(items[idx]) }
    }

    func appendTextToNote(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let current = items[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = current.isEmpty ? text : current + "\n\n----------------\n\n" + text
        items[idx] = items[idx].withText(newText)
        if isSealed { seal(items[idx]) }
    }

    func replaceNoteText(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let oldText = items[idx].text
        guard oldText != text else { return }
        items[idx] = items[idx].withText(text)
        if isSealed { seal(items[idx]) }
        DictionaryLearning.shared.learn(original: oldText, edited: text, noteId: id)
    }

    func deleteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items.remove(at: index)
        deleteFiles(for: item.id)
    }

    /// При замке стирает все конверты заметок и аудио, даже непрочитанные, и все открытые `<uuid>.wav`.
    func clearAll() {
        let ids = items.map(\.id)
        let vault = isSealed ? vault : nil
        // Чтение конвертов в полёте не должно вернуть стёртое.
        generation += 1
        items.removeAll()
        ioQueue.async { [self] in
            ids.forEach(deleteFilesSync)
            vault?.deleteAll()
            pendingAudio.formUnion(plainAudioIDs())
            pendingAudio.forEach(deleteFilesSync)
            pendingSeal.removeAll()
            pendingAudio.removeAll()
            publishSealFailures()
        }
    }

    // MARK: - Аудио заметок

    func audioURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Файл таймингов старых заметок: новые не пишутся, но при удалении заметки он убирается.
    private func timingsURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).segments.json")
    }

    /// С главного потока. При замке аудио есть, если лежит конверт или ещё не запечатанный `.wav`.
    func hasAudio(for id: UUID) -> Bool {
        if FileManager.default.fileExists(atPath: audioURL(for: id).path) { return true }
        return isSealed && vault?.hasBlob(id: id, purpose: .audio) == true
    }

    /// Байты аудио заметки, `nil`, если аудио нет. Без замка читается открытый файл.
    /// Под замком только разлоченная история, иначе `HistoryAudioError.locked`.
    /// Расшифровка может показать диалог: с главного потока не звать, интерфейсу — `loadAudio`.
    /// Можно звать с любого потока.
    func audioData(for id: UUID) throws -> Data? {
        accessLock.lock()
        let (state, vault) = readAccess
        accessLock.unlock()
        let plain = audioURL(for: id)
        switch state {
        case .off:
            return try? Data(contentsOf: plain)
        case .locked, .keyUnavailable:
            throw HistoryAudioError.locked
        case .unlocked:
            if let data = try vault?.readBlob(id: id, purpose: .audio) { return data }
            // Конверт ещё не записан: открытый файл ждёт запечатки.
            if let data = try? Data(contentsOf: plain) { return data }
            // Запечатка могла закончиться между двумя проверками.
            return try vault?.readBlob(id: id, purpose: .audio)
        }
    }

    /// `audioData` в фоне, ответ на главном. Звать с главного потока.
    /// Если за время чтения замок сменился или история очищена, байты отбрасываются
    /// и приходит `HistoryAudioError.locked`.
    func loadAudio(for id: UUID, completion: @escaping (Result<Data?, Error>) -> Void) {
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try audioData(for: id) }
            DispatchQueue.main.async { [self] in
                completion(generation == current ? result : .failure(HistoryAudioError.locked))
            }
        }
    }

    /// Сохраняет аудио заметки. При `move` файл переносится, а не копируется.
    /// При замке открытый `.wav` живёт, пока фон не положит конверт, затем удаляется.
    /// Нужен только публичный ключ. Неудача оставляет открытый файл до следующего перехода замка.
    func storeAudio(for id: UUID, from source: URL, move: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let dest = audioURL(for: id)
        try? fm.removeItem(at: dest)
        if move {
            if (try? fm.moveItem(at: source, to: dest)) == nil { try? fm.copyItem(at: source, to: dest) }
        } else {
            try? fm.copyItem(at: source, to: dest)
        }
        if isSealed { sealAudio(id) }
    }

    private func sealAudio(_ id: UUID) {
        let vault = vault
        ioQueue.async { [self] in
            pendingAudio.insert(id)
            drainPendingAudio(vault)
        }
    }

    /// Id открытых `<uuid>.wav` в папке аудио. Чужие имена не трогаются.
    private func plainAudioIDs() -> [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "wav", let id = UUID(uuidString: name), id.uuidString == name else { return nil }
            return id
        }
    }

    /// Только на `ioQueue`. В лог идёт id заметки, звук — никогда.
    private func drainPendingAudio(_ vault: HistoryVault?) {
        defer { publishSealFailures() }
        guard let vault else { return }
        for id in pendingAudio {
            let url = audioURL(for: id)
            guard let data = try? Data(contentsOf: url) else {
                pendingAudio.remove(id)
                continue
            }
            do {
                try vault.writeBlob(data, id: id, purpose: .audio)
                try? FileManager.default.removeItem(at: url)
                pendingAudio.remove(id)
            } catch {
                AppLogger.shared.error("History", "Конверт аудио не записан", details: "\(id.uuidString): \(error)")
            }
        }
    }

    private func deleteFiles(for id: UUID) {
        let vault = isSealed ? vault : nil
        ioQueue.async { [self] in
            deleteFilesSync(id)
            pendingSeal[id] = nil
            pendingAudio.remove(id)
            publishSealFailures()
            vault?.deleteNote(id: id)
            vault?.deleteBlobs(id: id)
        }
    }

    private func deleteFilesSync(_ id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(for: id))
        try? FileManager.default.removeItem(at: timingsURL(for: id))
    }

    // MARK: - Сохранение

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = items
        let url = historyURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        pendingSave = work
        ioQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Немедленно записывает отложенные изменения, например при выходе из приложения.
    func flush() {
        pendingSave?.perform()
        pendingSave?.cancel()
        pendingSave = nil
        ioQueue.sync {}
    }

    private func load() {
        guard lockState == .off else { return }
        var loaded: [TranscriptionItem] = []
        var needsSave = false
        let fm = FileManager.default
        if !fm.fileExists(atPath: historyURL.path),
           directory == Self.defaultDirectory,
           let legacy = AppEnvironment.defaults.data(forKey: "transcription_history"),
           let decoded = try? JSONDecoder().decode([TranscriptionItem].self, from: legacy) {
            loaded = decoded
            AppEnvironment.defaults.removeObject(forKey: "transcription_history")
            needsSave = true
        } else if let data = try? Data(contentsOf: historyURL),
                  let decoded = try? JSONDecoder().decode([TranscriptionItem].self, from: data) {
            loaded = decoded
        }

        isLoading = true
        items = loaded.map { item in
            if !item.text.contains("\n\n") && item.text.count > 120 {
                needsSave = true
                return item.withText(TextFormatter.formatIntoParagraphs(item.text))
            }
            return item
        }
        isLoading = false
        if needsSave { scheduleSave() }
    }
}
