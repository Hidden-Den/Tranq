import AppKit
import Combine

/// Хранилище словаря: пользовательские записи, наборы из ресурсов, выключенные наборы, слова и варианты,
/// настройка обучения, индекс замен, подсказка модели и замены по заметкам.
///
/// Мутации выполняются на главном потоке и публикуются; вызов с другого потока переходит на главный.
/// Индекс пересобирается на фоновой очереди и подменяется целиком. `index`, `promptHint`,
/// `recordReplacements`, `replacements(for:)` и `registerHits` можно вызывать с любого потока.
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore(
        directory: AppEnvironment.dataDirectory,
        defaults: AppEnvironment.defaults,
        packsBundle: .main,
        checker: SpellCommonWordChecker.shared
    )

    /// Порядок наборов на экране и в индексе.
    static let packOrder = ["it", "ai", "apps", "management", "business", "hr", "finance", "marketing", "legal", "design"]

    static let schemaVersion = 1
    static let fileName = "dictionary.json"
    static let backupFileName = "dictionary.backup.json"

    private enum Keys {
        static let learningEnabled = "dictionary.learningEnabled"
        static let disabledPacks = "dictionary.disabledPacks"
        static let disabledPackWords = "dictionary.disabledPackWords"
        static let disabledPackVariants = "dictionary.disabledPackVariants"
    }

    private static let userKeyPrefix = "user/"
    private static let learnedLifetime: TimeInterval = 60 * 86_400
    private static let maxHintSpellings = 8
    private static let maxRecordedNotes = 50

    @Published private(set) var userEntries: [DictionaryEntry] = [] {
        didSet { withLock { entriesSnapshot = userEntries } }
    }
    @Published private(set) var packs: [DictionaryPack] = []
    @Published private(set) var disabledPacks: Set<String> = []
    @Published private(set) var disabledPackWords: Set<String> = []
    @Published private(set) var disabledPackVariants: Set<String> = []
    @Published var learningEnabled: Bool = true {
        didSet { defaults.set(learningEnabled, forKey: Keys.learningEnabled) }
    }

    private let directory: URL
    /// Общие настройки: обучение хранит в них счётчики пар и дневной лимит.
    let defaults: UserDefaults
    private let checker: CommonWordChecking
    private let now: () -> Date
    private let saveDelay: TimeInterval

    private var mainURL: URL { directory.appendingPathComponent(Self.fileName) }
    private var backupURL: URL { directory.appendingPathComponent(Self.backupFileName) }

    private let lock = NSLock()
    private var currentIndex: DictionaryIndex?
    private var indexGeneration = 0
    private var entriesSnapshot: [DictionaryEntry] = []
    private var noteReplacements: [UUID: [AppliedReplacement]] = [:]
    private var noteOrder: [UUID] = []
    private var pendingEntries: [DictionaryEntry]?
    private var pendingSave: DispatchWorkItem?

    private let indexQueue = DispatchQueue(label: "golosok.dictionary.index", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "golosok.dictionary.io", qos: .utility)
    private var terminationObserver: NSObjectProtocol?

    /// `packs` подменяет загрузку наборов из `packsBundle`, для тестов.
    init(
        directory: URL,
        defaults: UserDefaults,
        packsBundle: Bundle,
        checker: CommonWordChecking,
        packs: [DictionaryPack]? = nil,
        now: @escaping () -> Date = Date.init,
        saveDelay: TimeInterval = 1
    ) {
        self.directory = directory
        self.defaults = defaults
        self.checker = checker
        self.now = now
        self.saveDelay = saveDelay
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        learningEnabled = defaults.object(forKey: Keys.learningEnabled) as? Bool ?? true
        disabledPacks = Set(defaults.stringArray(forKey: Keys.disabledPacks) ?? [])
        disabledPackWords = Set(defaults.stringArray(forKey: Keys.disabledPackWords) ?? [])
        disabledPackVariants = Set(defaults.stringArray(forKey: Keys.disabledPackVariants) ?? [])
        self.packs = packs ?? Self.loadPacks(from: packsBundle)

        let loaded = Self.loadEntries(main: mainURL, backup: backupURL)
        let cutoff = now().addingTimeInterval(-Self.learnedLifetime)
        let kept = loaded.filter { $0.source != .learned || ($0.lastUsed ?? $0.createdAt) >= cutoff }
        userEntries = kept
        // Наблюдатели свойств в init не вызываются, поэтому снимок заполняется явно.
        entriesSnapshot = kept
        if kept.count != loaded.count {
            AppLogger.shared.info("Dictionary", "Удалены неиспользуемые выученные слова", details: "\(loaded.count - kept.count)")
            scheduleSave()
        }
        rebuildIndex()

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: - Записи

    /// Добавляет запись. Если написание уже есть без учёта регистра, варианты объединяются,
    /// а ручной источник или `forceCase` переносятся на существующую запись.
    @discardableResult
    func addEntry(
        spelling: String,
        variants: [DictionaryLanguage: [String]],
        source: DictionaryEntry.Source,
        forceCase: Bool = false
    ) -> DictionaryEntry {
        onMain {
            let spelling = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = spelling.lowercased()
            if let i = userEntries.firstIndex(where: { $0.spelling.lowercased() == key }) {
                var entry = userEntries[i]
                for (language, list) in variants {
                    entry.variants[language] = Self.mergedVariants(entry.variants[language] ?? [], list)
                }
                if source == .manual { entry.source = .manual }
                entry.forceCase = entry.forceCase || forceCase
                if entry != userEntries[i] {
                    userEntries[i] = entry
                    entriesChanged()
                }
                return entry
            }

            var cleaned: [DictionaryLanguage: [String]] = [:]
            for (language, list) in variants {
                let merged = Self.mergedVariants([], list)
                if !merged.isEmpty { cleaned[language] = merged }
            }
            let entry = DictionaryEntry(
                id: UUID(), spelling: spelling, variants: cleaned, source: source,
                forceCase: forceCase, createdAt: now(), hits: 0, lastUsed: nil
            )
            userEntries.append(entry)
            entriesChanged()
            return entry
        }
    }

    /// Есть ли пользовательская запись с таким написанием без учёта регистра. Можно вызывать с любого потока.
    func hasEntry(spelling: String) -> Bool {
        let key = spelling.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return withLock { entriesSnapshot.contains { $0.spelling.lowercased() == key } }
    }

    /// Обновляет `lastUsed` записи на месте, в одном блоке на главном потоке, не трогая остальные поля.
    func touch(id: UUID) {
        onMain {
            guard let i = userEntries.firstIndex(where: { $0.id == id }) else { return }
            userEntries[i].lastUsed = now()
            scheduleSave()
        }
    }

    func updateEntry(_ entry: DictionaryEntry) {
        onMain {
            guard let i = userEntries.firstIndex(where: { $0.id == entry.id }), userEntries[i] != entry else { return }
            userEntries[i] = entry
            entriesChanged()
        }
    }

    func removeEntry(id: UUID) {
        onMain {
            guard let i = userEntries.firstIndex(where: { $0.id == id }) else { return }
            userEntries.remove(at: i)
            entriesChanged()
        }
    }

    /// Убирает вариант по ключу записи из `AppliedReplacement.entryKey`.
    /// Пользовательская запись теряет вариант, а выученная без вариантов удаляется целиком.
    /// У набора вариант выключается ключом `<packId>/<spelling>/<variant>`; для исправления регистра
    /// вариантом служит написание в нижнем регистре.
    func removeVariant(_ variant: String, language: DictionaryLanguage, fromEntryKey entryKey: String) {
        onMain {
            if let id = Self.userEntryID(from: entryKey) {
                guard let i = userEntries.firstIndex(where: { $0.id == id }) else { return }
                var entry = userEntries[i]
                let lowered = variant.lowercased()
                entry.variants[language]?.removeAll { $0.lowercased() == lowered }
                if entry.source == .learned, entry.variants.values.allSatisfy(\.isEmpty) {
                    userEntries.remove(at: i)
                } else if entry != userEntries[i] {
                    userEntries[i] = entry
                } else {
                    return
                }
                entriesChanged()
            } else {
                guard disabledPackVariants.insert("\(entryKey)/\(variant)").inserted else { return }
                defaults.set(disabledPackVariants.sorted(), forKey: Keys.disabledPackVariants)
                rebuildIndex()
            }
        }
    }

    func setPack(_ id: String, enabled: Bool) {
        onMain {
            guard Self.toggle(&disabledPacks, id, enabled: enabled) else { return }
            defaults.set(disabledPacks.sorted(), forKey: Keys.disabledPacks)
            rebuildIndex()
        }
    }

    /// `key` — `<packId>/<spelling>`.
    func setPackWord(_ key: String, enabled: Bool) {
        onMain {
            guard Self.toggle(&disabledPackWords, key, enabled: enabled) else { return }
            defaults.set(disabledPackWords.sorted(), forKey: Keys.disabledPackWords)
            rebuildIndex()
        }
    }

    func resetLearned() {
        onMain {
            let kept = userEntries.filter { $0.source != .learned }
            guard kept.count != userEntries.count else { return }
            userEntries = kept
            entriesChanged()
        }
    }

    // MARK: - Чтение

    /// Последний собранный индекс; `nil` до первой сборки.
    var index: DictionaryIndex? {
        withLock { currentIndex }
    }

    /// Ждёт, пока соберётся последний запрошенный индекс.
    func waitForIndex() {
        indexQueue.sync {}
    }

    /// Сработавшие написания, затем пользовательские записи от недавних к старым, не больше восьми.
    func promptHint(firedSpellings: [String], language: DictionaryLanguage) -> String {
        let entries = withLock { entriesSnapshot }
        let recent = entries
            .sorted { ($0.lastUsed ?? $0.createdAt) > ($1.lastUsed ?? $1.createdAt) }
            .map(\.spelling)

        var seen = Set<String>()
        var spellings: [String] = []
        for spelling in firedSpellings + recent where spellings.count < Self.maxHintSpellings {
            guard !spelling.isEmpty, seen.insert(spelling.lowercased()).inserted else { continue }
            spellings.append(spelling)
        }
        guard !spellings.isEmpty else { return "" }

        let prefix = language == .ru ? "Словарь пользователя: " : "User dictionary: "
        return prefix + spellings.joined(separator: ", ")
    }

    // MARK: - Замены по заметкам

    func recordReplacements(_ replacements: [AppliedReplacement], noteId: UUID) {
        guard !replacements.isEmpty else { return }
        withLock {
            var list = noteReplacements[noteId] ?? []
            for replacement in replacements where !list.contains(replacement) {
                list.append(replacement)
            }
            noteReplacements[noteId] = list
            noteOrder.removeAll { $0 == noteId }
            noteOrder.append(noteId)
            while noteOrder.count > Self.maxRecordedNotes {
                noteReplacements[noteOrder.removeFirst()] = nil
            }
        }
    }

    /// Убирает учтённые замены заметки, например после того, как правка пользователя их отменила.
    func forgetReplacements(_ replacements: [AppliedReplacement], noteId: UUID) {
        guard !replacements.isEmpty else { return }
        withLock {
            guard var list = noteReplacements[noteId] else { return }
            list.removeAll { replacements.contains($0) }
            noteReplacements[noteId] = list.isEmpty ? nil : list
            if list.isEmpty { noteOrder.removeAll { $0 == noteId } }
        }
    }

    func replacements(for noteId: UUID) -> [AppliedReplacement] {
        withLock { noteReplacements[noteId] ?? [] }
    }

    /// Увеличивает `hits` и обновляет `lastUsed` у сработавших пользовательских записей.
    /// С фонового потока изменение уходит на главный без ожидания.
    func registerHits(_ replacements: [AppliedReplacement]) {
        let ids = replacements.compactMap { Self.userEntryID(from: $0.entryKey) }
        guard !ids.isEmpty else { return }
        let date = now()
        let apply = { [weak self] in
            guard let self else { return }
            var entries = self.userEntries
            var changed = false
            for id in ids {
                guard let i = entries.firstIndex(where: { $0.id == id }) else { continue }
                entries[i].hits += 1
                entries[i].lastUsed = date
                changed = true
            }
            guard changed else { return }
            self.userEntries = entries
            self.scheduleSave()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    // MARK: - Наборы

    /// Наборы `Dictionaries/*.json` из бандла в порядке `packOrder`; битые файлы пропускаются.
    static func loadPacks(from bundle: Bundle) -> [DictionaryPack] {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Dictionaries") ?? []
        let decoder = JSONDecoder()
        var packs: [DictionaryPack] = []
        var ids = Set<String>()
        for url in urls {
            do {
                let pack = try decoder.decode(DictionaryPack.self, from: Data(contentsOf: url))
                guard ids.insert(pack.id).inserted else {
                    AppLogger.shared.warn("Dictionary", "Повтор набора пропущен", details: url.lastPathComponent)
                    continue
                }
                packs.append(pack)
            } catch {
                AppLogger.shared.warn("Dictionary", "Набор не загружен", details: "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: packOrder.enumerated().map { ($1, $0) })
        return packs.sorted {
            let l = rank[$0.id] ?? Int.max, r = rank[$1.id] ?? Int.max
            return l != r ? l < r : $0.id < $1.id
        }
    }

    // MARK: - Индекс

    private func rebuildIndex() {
        let entries = userEntries
        let packs = packs
        let disabledPacks = disabledPacks
        let disabledWords = disabledPackWords
        let disabledVariants = disabledPackVariants
        let checker = checker
        let generation: Int = withLock {
            indexGeneration += 1
            return indexGeneration
        }
        indexQueue.async { [weak self] in
            guard let self, self.withLock({ self.indexGeneration == generation }) else { return }
            let built = DictionaryIndex(
                userEntries: entries, packs: packs, disabledPacks: disabledPacks,
                disabledPackWords: disabledWords, disabledPackVariants: disabledVariants, checker: checker
            )
            self.withLock {
                if self.indexGeneration == generation { self.currentIndex = built }
            }
        }
    }

    // MARK: - Сохранение

    private struct StoredFile: Codable {
        var schemaVersion: Int
        var entries: [DictionaryEntry]
    }

    private func entriesChanged() {
        scheduleSave()
        rebuildIndex()
    }

    /// Запись откладывается на `saveDelay`, каждое изменение переносит её заново.
    private func scheduleSave() {
        let entries = userEntries
        let work = DispatchWorkItem { [weak self] in self?.writePending() }
        let previous: DispatchWorkItem? = withLock {
            pendingEntries = entries
            defer { pendingSave = work }
            return pendingSave
        }
        previous?.cancel()
        ioQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Немедленно записывает отложенные изменения.
    func flush() {
        ioQueue.sync { writePending() }
    }

    private func writePending() {
        let entries: [DictionaryEntry]? = withLock {
            defer { pendingEntries = nil; pendingSave = nil }
            return pendingEntries
        }
        guard let entries else { return }
        Self.write(entries, main: mainURL, backup: backupURL)
    }

    /// Предыдущий файл копируется в резервную копию, только если он читается: иначе испорченный файл
    /// затёр бы рабочую копию, из которой словарь мог быть загружен.
    private static func write(_ entries: [DictionaryEntry], main: URL, backup: URL) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(StoredFile(schemaVersion: schemaVersion, entries: entries))
        } catch {
            AppLogger.shared.warn("Dictionary", "Словарь не сохранён", details: error.localizedDescription)
            return
        }

        if let previous = try? Data(contentsOf: main),
           (try? JSONDecoder().decode(StoredFile.self, from: previous)) != nil {
            do {
                try previous.write(to: backup, options: .atomic)
            } catch {
                AppLogger.shared.warn("Dictionary", "Резервная копия словаря не записана", details: error.localizedDescription)
            }
        }

        do {
            try data.write(to: main, options: .atomic)
        } catch {
            AppLogger.shared.warn("Dictionary", "Словарь не сохранён", details: error.localizedDescription)
        }
    }

    private static func loadEntries(main: URL, backup: URL) -> [DictionaryEntry] {
        if let entries = readEntries(at: main) { return entries }
        if let entries = readEntries(at: backup) {
            if FileManager.default.fileExists(atPath: main.path) {
                AppLogger.shared.warn("Dictionary", "Словарь загружен из резервной копии")
            }
            return entries
        }
        return []
    }

    /// `nil`, если файла нет или он не читается; во втором случае пишется `warn`.
    private static func readEntries(at url: URL) -> [DictionaryEntry]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(StoredFile.self, from: Data(contentsOf: url)).entries
        } catch {
            AppLogger.shared.warn("Dictionary", "Файл словаря не читается", details: "\(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Вспомогательное

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func userEntryID(from entryKey: String) -> UUID? {
        guard entryKey.hasPrefix(userKeyPrefix) else { return nil }
        return UUID(uuidString: String(entryKey.dropFirst(userKeyPrefix.count)))
    }

    /// Возвращает true, если множество изменилось.
    private static func toggle(_ set: inout Set<String>, _ key: String, enabled: Bool) -> Bool {
        enabled ? set.remove(key) != nil : set.insert(key).inserted
    }

    /// Варианты без пустых строк и повторов без учёта регистра, в порядке появления.
    private static func mergedVariants(_ existing: [String], _ added: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var result = existing
        for variant in added {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
