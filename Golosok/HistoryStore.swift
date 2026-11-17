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

    /// Показывать ли переключатель «Итог / Сказано»: только если сказанное отличается от итога.
    var showsSpokenToggle: Bool {
        guard let spoken = spokenText?.trimmingCharacters(in: .whitespacesAndNewlines), !spoken.isEmpty else { return false }
        return spoken != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func withText(_ newText: String) -> TranscriptionItem {
        TranscriptionItem(id: id, date: date, text: newText, duration: duration, speedup: speedup, isUnread: isUnread, spokenText: spokenText)
    }

    static let dateFormat = "dd.MM.yyyy, HH:mm"

    static func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        return formatter.string(from: Date())
    }
}

/// История заметок, их аудио и тайминги слов.
///
/// Мутации — с главного потока. Запись на диск откладывается на полсекунды и
/// выполняется в фоне, поэтому частые правки не кодируют весь JSON на главном потоке.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(directory: HistoryStore.defaultDirectory)

    @Published var items: [TranscriptionItem] = [] {
        didSet {
            guard !isLoading else { return }
            scheduleSave()
        }
    }

    let directory: URL
    var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    private var isLoading = false
    private var pendingSave: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "golosok.history.io", qos: .utility)
    private let saveDelay: TimeInterval

    static var defaultDirectory: URL { AppEnvironment.dataDirectory }

    /// `directory` подменяется в тестах, чтобы не трогать настоящую историю пользователя.
    init(directory: URL, saveDelay: TimeInterval = 0.5) {
        self.directory = directory
        self.saveDelay = saveDelay
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Операции с заметками

    @discardableResult
    func addNote(text: String) -> UUID {
        let item = TranscriptionItem(id: UUID(), date: TranscriptionItem.formattedNow(), text: text, duration: "—", speedup: nil, isUnread: false)
        items.insert(item, at: 0)
        return item.id
    }

    func insert(_ item: TranscriptionItem) {
        items.insert(item, at: 0)
    }

    func markAsRead(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].isUnread == true else { return }
        items[idx].isUnread = false
    }

    func appendTextToNote(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let current = items[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = current.isEmpty ? text : current + "\n\n----------------\n\n" + text
        items[idx] = items[idx].withText(newText)
    }

    func replaceNoteText(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let oldText = items[idx].text
        guard oldText != text else { return }
        items[idx] = items[idx].withText(text)
        DictionaryLearning.shared.learn(original: oldText, edited: text, noteId: id)
    }

    func deleteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items.remove(at: index)
        deleteFiles(for: item.id)
    }

    func clearAll() {
        let ids = items.map(\.id)
        items.removeAll()
        ioQueue.async { [self] in ids.forEach(deleteFilesSync) }
    }

    // MARK: - Аудио заметок

    func audioURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Файл таймингов старых заметок: новые не пишутся, но при удалении заметки он убирается.
    private func timingsURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).segments.json")
    }

    func hasAudio(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: id).path)
    }

    /// Сохраняет аудио заметки. При `move` файл переносится, а не копируется.
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
    }

    private func deleteFiles(for id: UUID) {
        ioQueue.async { [self] in deleteFilesSync(id) }
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
