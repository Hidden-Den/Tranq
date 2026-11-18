import Testing
import Foundation
@testable import Tranq

/// Наборы агента: хранение в `dictionary.json`, создание, удаление, слова, откат и замены.
/// Каждый тест работает с отдельной временной папкой и своим доменом UserDefaults.
@MainActor
final class DictionaryAgentPackTests {
    private let directory: URL
    private let suiteName: String
    private let defaults: UserDefaults

    private let medicine = DictionaryPack(
        id: "med",
        title: [.ru: "Медицина", .en: "Medicine"],
        version: 1,
        entries: [
            PackEntry(spelling: "Аспирин", variants: [.ru: ["аспирин"]]),
            PackEntry(spelling: "Ибупрофен", variants: [.ru: ["ибупрофен"]]),
        ]
    )

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-agent-pack-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "dictionary-agent-pack-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var mainURL: URL { directory.appendingPathComponent("dictionary.json") }
    private var corruptURL: URL { directory.appendingPathComponent("dictionary.corrupt.json") }

    private func makeStore(packs: [DictionaryPack] = [], checker: CommonWordChecking = SetCommonWordChecker([:])) -> DictionaryStore {
        DictionaryStore(directory: directory, defaults: defaults, packsBundle: .main, checker: checker, packs: packs)
    }

    /// Сохраняет всё отложенное и поднимает второе хранилище на тех же файлах.
    private func reload(_ store: DictionaryStore, packs: [DictionaryPack] = []) -> DictionaryStore {
        store.flush()
        return makeStore(packs: packs)
    }

    @discardableResult
    private func create(_ store: DictionaryStore, _ title: String = "Музыка") throws -> String {
        try store.createAgentPack(title: title).id
    }

    private func stored(_ key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    // MARK: - Создание

    @Test func созданиеНабораДаётИдентификаторИНазваниеНаОбоихЯзыках() throws {
        let store = makeStore(packs: [medicine])
        let result = try store.createAgentPack(title: "Музыка")

        #expect(result.created == true)
        #expect(result.title == "Музыка")
        #expect(result.id.range(of: "^agent-[0-9a-f]{8}$", options: .regularExpression) != nil)
        let pack = try #require(store.agentPacks.first)
        #expect(pack.id == result.id)
        #expect(pack.title[.ru] == "Музыка")
        #expect(pack.title[.en] == "Музыка")
        #expect(pack.version == 1)
        #expect(pack.entries.isEmpty)
        #expect(store.packs.map(\.id) == ["med", result.id])
    }

    @Test func повторноеСозданиеСТемЖеНазваниемВозвращаетТотЖеНабор() throws {
        let store = makeStore()
        let first = try store.createAgentPack(title: "Музыка")
        for title in ["музыка ", "МУЗЫКА", "  Музыка"] {
            let again = try store.createAgentPack(title: title)
            #expect(again.id == first.id)
            #expect(again.created == false)
            #expect(again.title == "Музыка")
        }
        #expect(store.agentPacks.count == 1)
    }

    @Test func названиеВстроенногоНабораОтвергается() {
        let store = makeStore(packs: [medicine])
        for title in ["медицина", "MEDICINE", " Medicine "] {
            #expect(throws: AgentPackError.titleTakenByBuiltIn) { try store.createAgentPack(title: title) }
        }
        #expect(store.agentPacks.isEmpty)
    }

    @Test func пустоеИСлишкомДлинноеНазвание() throws {
        let store = makeStore()
        #expect(throws: AgentPackError.emptyTitle) { try store.createAgentPack(title: "   ") }
        #expect(throws: AgentPackError.titleTooLong(limit: 60)) {
            try store.createAgentPack(title: String(repeating: "я", count: 61))
        }
        _ = try store.createAgentPack(title: String(repeating: "я", count: 60))
        #expect(store.agentPacks.count == 1)
    }

    @Test func впределеДвадцатиНаборовНовыйОтвергаетсяАСуществующийВозвращается() throws {
        let store = makeStore()
        for i in 0..<20 { try create(store, "Набор \(i)") }
        #expect(throws: AgentPackError.tooManyPacks(limit: 20)) { try store.createAgentPack(title: "Лишний") }
        #expect(store.agentPacks.count == 20)
        let again = try store.createAgentPack(title: "набор 7")
        #expect(again.created == false)
        #expect(store.agentPacks.count == 20)
    }

    // MARK: - Сохранение

    @Test func наборыПереживаютПерезагрузку() throws {
        let store = makeStore(packs: [medicine])
        try create(store, "Музыка")
        try create(store, "Кино")

        let loaded = reload(store, packs: [medicine])
        #expect(loaded.agentPacks == store.agentPacks)
        #expect(loaded.packs.map(\.id) == store.packs.map(\.id))
    }

    @Test func старыйФайлБезНаборовЧитается() throws {
        try Data(#"{"schemaVersion":1,"entries":[]}"#.utf8).write(to: mainURL)
        let store = makeStore()
        #expect(store.agentPacks.isEmpty)
    }

    @Test func испорченныйФайлСНаборамиУходитВCorruptИВосстанавливаетсяИзКопии() throws {
        let store = makeStore()
        let music = try create(store, "Музыка")
        store.flush()
        try create(store, "Кино")
        store.flush()
        try Data(#"{"schemaVersion":1,"entries":[],"agentPacks":"oops"}"#.utf8).write(to: mainURL)

        let loaded = makeStore()
        #expect(loaded.agentPacks.map(\.id) == [music])
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test func загрузкаОтбрасываетПовторИдентификатораИСовпадениеСоВстроенным() throws {
        func pack(_ id: String, _ title: String) -> String {
            #"{"id":"\#(id)","title":{"ru":"\#(title)","en":"\#(title)"},"version":1,"entries":[]}"#
        }
        let json = #"{"schemaVersion":1,"entries":[],"agentPacks":["#
            + [pack("agent-aaaaaaaa", "Один"), pack("agent-aaaaaaaa", "Два"), pack("med", "Три"), pack("agent-bbbbbbbb", "Четыре")]
                .joined(separator: ",")
            + "]}"
        try Data(json.utf8).write(to: mainURL)

        let store = makeStore(packs: [medicine])
        #expect(store.agentPacks.map(\.id) == ["agent-aaaaaaaa", "agent-bbbbbbbb"])
        #expect(store.agentPacks.first?.title[.ru] == "Один")
        #expect(store.packs.map(\.id) == ["med", "agent-aaaaaaaa", "agent-bbbbbbbb"])
    }

    // MARK: - Удаление

    @Test func удалениеНабораЧиститВыключенияИТолькоЕго() throws {
        let store = makeStore(packs: [medicine])
        let id = try create(store)
        store.setPack(id, enabled: false)
        store.setPackWord("\(id)/Слово", enabled: false)
        store.removeVariant("вар", language: .ru, fromEntryKey: "\(id)/Слово")
        store.setPackWord("med/Аспирин", enabled: false)

        let result = try store.deleteAgentPack(id: id)

        #expect(result == AgentPackDeleteResult(id: id, title: "Музыка", removedWords: 0))
        #expect(store.agentPacks.isEmpty)
        for set in [store.disabledPacks, store.disabledPackWords, store.disabledPackVariants] {
            #expect(!set.contains { $0 == id || $0.hasPrefix("\(id)/") })
        }
        #expect(store.disabledPackWords == ["med/Аспирин"])
        for key in ["dictionary.disabledPacks", "dictionary.disabledPackWords", "dictionary.disabledPackVariants"] {
            #expect(!stored(key).contains { $0 == id || $0.hasPrefix("\(id)/") })
        }
        #expect(stored("dictionary.disabledPackWords") == ["med/Аспирин"])
    }

    @Test func наборСозданныйЗановоПослеУдаленияВключёнИИмеетНовыйИдентификатор() throws {
        let store = makeStore()
        let old = try create(store)
        store.setPack(old, enabled: false)
        try store.deleteAgentPack(id: old)

        let new = try create(store)
        #expect(new != old)
        #expect(!store.disabledPacks.contains(new))
        #expect(!store.disabledPacks.contains(old))
    }

    @Test func удалениеВстроенногоИНеизвестного() throws {
        let store = makeStore(packs: [medicine])
        let id = try create(store)

        #expect(throws: AgentPackError.builtInPack(id: "med")) { try store.deleteAgentPack(id: "med") }
        #expect(throws: AgentPackError.noSuchPack(id: "agent-00000000")) { try store.deleteAgentPack(id: "agent-00000000") }
        #expect(throws: AgentPackError.builtInPack(id: "med")) { try store.agentPack(id: "med") }
        #expect(throws: AgentPackError.noSuchPack(id: "agent-00000000")) { try store.agentPack(id: "agent-00000000") }
        #expect(try store.agentPack(id: id).id == id)
        #expect(store.packs.map(\.id) == ["med", id])
    }
}
