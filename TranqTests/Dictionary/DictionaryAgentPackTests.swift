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

    private func makeStore(
        packs: [DictionaryPack] = [], checker: CommonWordChecking = SetCommonWordChecker([:]),
        now: @escaping () -> Date = Date.init
    ) -> DictionaryStore {
        DictionaryStore(directory: directory, defaults: defaults, packsBundle: .main, checker: checker, packs: packs, now: now)
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
        // Починенный при загрузке файл не должен потерять наборы при записи.
        #expect(reload(store, packs: [medicine]).agentPacks.map(\.id) == ["agent-aaaaaaaa", "agent-bbbbbbbb"])
    }

    @Test func очисткаУстаревшихВыученныхСловПриЗагрузкеНеТеряетНаборы() throws {
        let old = Date().addingTimeInterval(-100 * 86_400)
        let first = makeStore(now: { old })
        first.addEntry(spelling: "устарело", variants: [.ru: ["устарелое"]], source: .learned)
        try create(first, "Музыка")
        first.flush()

        // Второй запуск удаляет выученное слово и сам планирует запись файла.
        let second = makeStore()
        #expect(second.userEntries.isEmpty)
        #expect(second.agentPacks.count == 1)
        let third = reload(second)
        #expect(third.agentPacks.map(\.title[.ru]) == ["Музыка"])
        #expect(third.userEntries.isEmpty)
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

    // MARK: - Слова в наборе

    private func word(_ spelling: String, _ ru: [String] = [], en: [String] = []) -> AgentWord {
        var variants: [DictionaryLanguage: [String]] = [:]
        if !ru.isEmpty { variants[.ru] = ru }
        if !en.isEmpty { variants[.en] = en }
        return AgentWord(spelling: spelling, variants: variants, forceCase: false)
    }

    private func entries(_ store: DictionaryStore, _ id: String) throws -> [PackEntry] {
        try store.agentPack(id: id).entries
    }

    @Test func словоЛожитсяВНаборАНеВМоиСлова() throws {
        let store = makeStore()
        let id = try create(store)
        let result = try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"])])

        #expect(result.added == ["Ableton"])
        #expect(result.skipped.isEmpty)
        let list = try entries(store, id)
        #expect(list.map(\.spelling) == ["Ableton"])
        #expect(list[0].variants[.ru] == ["эйблтон"])
        #expect(store.userEntries.isEmpty)
    }

    @Test func повторБезУчётаРегистраСливаетВариантыИНеДублирует() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"])])
        let result = try store.addToAgentPack(id: id, words: [word("ableton", ["эйблтон", "аблтон"])])

        let list = try entries(store, id)
        #expect(list.count == 1)
        #expect(list[0].spelling == "Ableton")
        #expect(list[0].variants[.ru] == ["эйблтон", "аблтон"])
        #expect(result.added == ["ableton"])
    }

    @Test func негодныйВариантОтбрасываетсяАСловоПроходит() throws {
        let store = makeStore()
        let id = try create(store)
        let result = try store.addToAgentPack(id: id, words: [word("Ableton", ["к", "ableton", "эйблтон"])])

        #expect(result.added == ["Ableton"])
        #expect(result.skipped["Ableton / к"]?.isEmpty == false)
        #expect(result.skipped["Ableton / ableton"]?.isEmpty == false)
        #expect(try entries(store, id)[0].variants[.ru] == ["эйблтон"])
    }

    @Test func пустоеНаписаниеИПовторВЗапросеПропускаются() throws {
        let store = makeStore()
        let id = try create(store)
        let result = try store.addToAgentPack(id: id, words: [word(""), word("Serum"), word("serum")])

        #expect(result.added == ["Serum"])
        #expect(result.skipped[""]?.isEmpty == false)
        #expect(result.skipped["serum"]?.isEmpty == false)
        #expect(try entries(store, id).map(\.spelling) == ["Serum"])
    }

    @Test func commonInСчитаетсяПравиломСкрипта() throws {
        let store = makeStore(checker: SetCommonWordChecker([.ru: ["кубик"], .en: ["reaper"]]))
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [
            word("Кубик"), word("Reaper"), word("Kubernetes"), word("n8n"), word("FL Studio"), word("Logic Pro"),
        ])
        let common = Dictionary(uniqueKeysWithValues: try entries(store, id).map { ($0.spelling, $0.commonIn) })
        #expect(common["Кубик"] == [.ru])
        #expect(common["Reaper"] == [.en])
        #expect(common["Kubernetes"] == [])
        #expect(common["n8n"] == [])
        #expect(common["FL Studio"] == [])
        #expect(common["Logic Pro"] == [])
    }

    @Test func предел500СловАтомарен() throws {
        let store = makeStore()
        let id = try create(store)
        let full = (0..<500).map { word("слово\($0)") }
        try store.addToAgentPack(id: id, words: full)
        #expect(try entries(store, id).count == 500)

        #expect(throws: AgentPackError.tooManyWords(limit: 500, free: 0)) {
            try store.addToAgentPack(id: id, words: [word("новое")])
        }
        #expect(try entries(store, id).count == 500)
        // Слова, которые лишь сливаются с существующими, предел не занимают.
        let merged = try store.addToAgentPack(id: id, words: [word("СЛОВО1", ["вариант один"])])
        #expect(merged.added == ["СЛОВО1"])

        try store.removeFromAgentPack(id: id, spellings: ["слово0"])
        #expect(throws: AgentPackError.tooManyWords(limit: 500, free: 1)) {
            try store.addToAgentPack(id: id, words: [word("новое один"), word("новое два")])
        }
        #expect(try entries(store, id).count == 499)
        #expect(try entries(store, id).contains { $0.spelling == "новое один" } == false)

        try store.addToAgentPack(id: id, words: [word("новое один"), word("слово2", ["ещё вариант"])])
        #expect(try entries(store, id).count == 500)
    }

    @Test func добавлениеВВстроенныйИНеизвестныйНабор() throws {
        let store = makeStore(packs: [medicine])
        #expect(throws: AgentPackError.builtInPack(id: "med")) { try store.addToAgentPack(id: "med", words: [word("Ибу")]) }
        #expect(throws: AgentPackError.noSuchPack(id: "agent-00000000")) {
            try store.addToAgentPack(id: "agent-00000000", words: [word("Ибу")])
        }
        #expect(store.packs.first?.entries == medicine.entries)
    }

    @Test func снятиеСловаБезУчётаРегистраИПричиныОтказов() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Ableton")])
        let result = try store.removeFromAgentPack(id: id, spellings: ["ABLETON", "нет", "ABLETON"])

        #expect(result.added == ["ABLETON"])
        #expect(result.skipped["нет"]?.isEmpty == false)
        #expect(result.skipped["ABLETON"]?.isEmpty == false)
        #expect(try entries(store, id).isEmpty)
        #expect(store.agentPacks.map(\.id) == [id])
    }

    @Test func снятиеСловаЧиститВыключенияЭтогоСлова() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"]), word("Serum")])
        store.setPackWord("\(id)/Ableton", enabled: false)
        store.removeVariant("эйблтон", language: .ru, fromEntryKey: "\(id)/Ableton")
        store.setPackWord("\(id)/Serum", enabled: false)

        try store.removeFromAgentPack(id: id, spellings: ["Ableton"])

        #expect(store.disabledPackWords == ["\(id)/Serum"])
        #expect(store.disabledPackVariants.isEmpty)
        #expect(stored("dictionary.disabledPackWords") == ["\(id)/Serum"])
        #expect(stored("dictionary.disabledPackVariants").isEmpty)
        try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"])])
        #expect(!store.disabledPackWords.contains("\(id)/Ableton"))
    }

    @Test func спискиНеПересекаются() throws {
        let store = makeStore()
        let id = try create(store)
        store.addEntry(spelling: "Serum", variants: [:], source: .manual)
        try store.addToAgentPack(id: id, words: [word("Serum")])

        try store.removeFromAgentPack(id: id, spellings: ["Serum"])
        #expect(store.userEntries.map(\.spelling) == ["Serum"])

        try store.addToAgentPack(id: id, words: [word("Serum")])
        store.removeFromAgent(spellings: ["Serum"], fullAccess: true)
        #expect(try entries(store, id).map(\.spelling) == ["Serum"])
    }

    @Test func словаНабораПереживаютПерезагрузку() throws {
        let store = makeStore(checker: SetCommonWordChecker([.ru: ["кубик"]]))
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Кубик", ["куб"], en: ["cube"]), word("Ableton", ["эйблтон"])])

        let loaded = reload(store)
        #expect(try entries(loaded, id) == entries(store, id))
        #expect(try entries(loaded, id)[0].commonIn == [.ru])
    }

    // MARK: - Откат и счётчик

    @Test func откатУдаляетНаборыСчитаетИхИЧиститВыключения() throws {
        let store = makeStore(packs: [medicine])
        store.addFromAgent([word("Serum")])
        let music = try create(store, "Музыка")
        let film = try create(store, "Кино")
        try store.addToAgentPack(id: music, words: [word("Ableton", ["эйблтон"])])
        try store.addToAgentPack(id: film, words: [word("Нолан")])
        store.setPack(film, enabled: false)
        store.setPackWord("\(music)/Ableton", enabled: false)
        store.removeVariant("эйблтон", language: .ru, fromEntryKey: "\(music)/Ableton")
        store.setPackWord("med/Аспирин", enabled: false)

        let result = store.revertAgentChanges()

        #expect(result.removedWords == 1)
        #expect(result.removedPacks == 2)
        #expect(store.agentPacks.isEmpty)
        #expect(store.packs.map(\.id) == ["med"])
        #expect(store.disabledPacks.isEmpty)
        #expect(store.disabledPackWords == ["med/Аспирин"])
        #expect(store.disabledPackVariants.isEmpty)
        #expect(stored("dictionary.disabledPackWords") == ["med/Аспирин"])
        #expect(stored("dictionary.disabledPackVariants").isEmpty)
        #expect(reload(store, packs: [medicine]).agentPacks.isEmpty)
    }

    @Test func откатТолькоИзНаборовБезСловАгентаВМоихСловах() throws {
        let store = makeStore()
        store.addEntry(spelling: "Tranq", variants: [:], source: .manual)
        try create(store, "Музыка")
        try create(store, "Кино")

        let result = store.revertAgentChanges()

        #expect(result.removedWords == 0)
        #expect(result.removedPacks == 2)
        #expect(store.agentPacks.isEmpty)
        let loaded = reload(store)
        #expect(loaded.agentPacks.isEmpty)
        #expect(loaded.userEntries.map(\.spelling) == ["Tranq"])
    }

    @Test func откатБезЧегоЛибоНичегоНеМеняетИДаётНули() {
        let store = makeStore()
        #expect(store.revertAgentChanges() == AgentRevertResult(removedWords: 0, removedVariants: 0))
        #expect(store.revertAgentChanges().removedPacks == 0)
    }

    @Test func счётчикАгентаВидитСловаНаборов() throws {
        let store = makeStore()
        let id = try create(store)
        #expect(store.agentWordCount == 0)
        try store.addToAgentPack(id: id, words: [word("Ableton"), word("Serum")])
        #expect(store.agentWordCount == 2)
        store.addFromAgent([word("Kontakt")])
        #expect(store.agentWordCount == 3)
        store.revertAgentChanges()
        #expect(store.agentWordCount == 0)
    }

    // MARK: - Замены

    private let kubernetes = DictionaryPack(
        id: "it", title: [.ru: "IT", .en: "IT"], version: 1,
        entries: [PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]])]
    )

    private func apply(_ store: DictionaryStore, _ text: String) -> String {
        store.waitForIndex()
        return store.index?.apply(to: text, language: .ru).text ?? text
    }

    @Test func индексЗаменяетВариантИзНабораАгента() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"])])
        #expect(apply(store, "открой эйблтон") == "открой Ableton")
    }

    @Test func встроенныйНаборВыигрываетПриСовпаденииВарианта() throws {
        let store = makeStore(packs: [kubernetes])
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Cooper", ["кубер"])])
        #expect(apply(store, "запусти кубер") == "запусти Kubernetes")
    }

    @Test func выключенныйНаборИВыключенноеСловоНеПрименяются() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"]), word("Serum", ["сирум"])])

        store.setPack(id, enabled: false)
        #expect(apply(store, "эйблтон и сирум") == "эйблтон и сирум")
        store.setPack(id, enabled: true)
        #expect(apply(store, "эйблтон и сирум") == "Ableton и Serum")

        store.setPackWord("\(id)/Ableton", enabled: false)
        #expect(apply(store, "эйблтон и сирум") == "эйблтон и Serum")
    }

    @Test func записьПользователяВажнееНабораАгента() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Cooper", ["кубер"])])
        store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
        #expect(apply(store, "запусти кубер") == "запусти Kubernetes")
    }

    @Test func удалённыйНаборПерестаётЗаменять() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("Ableton", ["эйблтон"])])
        try store.deleteAgentPack(id: id)
        #expect(apply(store, "открой эйблтон") == "открой эйблтон")
    }

    @Test func снятиеСловаНеВключаетДругоеСловоСКосойЧертойВНаписании() throws {
        let store = makeStore()
        let id = try create(store)
        try store.addToAgentPack(id: id, words: [word("CI", ["си ай"]), word("CI/CD", ["си ай си ди"])])
        store.setPackWord("\(id)/CI/CD", enabled: false)
        store.removeVariant("си ай си ди", language: .ru, fromEntryKey: "\(id)/CI/CD")

        try store.removeFromAgentPack(id: id, spellings: ["CI"])

        #expect(store.disabledPackWords == ["\(id)/CI/CD"])
        #expect(store.disabledPackVariants == ["\(id)/CI/CD/си ай си ди"])
    }

    @Test func наборБольшеПределаИзФайлаНеДаётОтрицательногоОстатка() throws {
        let entries = (0..<520).map { #"{"spelling":"слово\#($0)","variants":{}}"# }.joined(separator: ",")
        let json = #"{"schemaVersion":1,"entries":[],"agentPacks":[{"id":"agent-aaaaaaaa","title":{"ru":"Большой","en":"Большой"},"version":1,"entries":["#
            + entries + "]}]}"
        try Data(json.utf8).write(to: mainURL)
        let store = makeStore()

        #expect(throws: AgentPackError.tooManyWords(limit: 500, free: 0)) {
            try store.addToAgentPack(id: "agent-aaaaaaaa", words: [word("новое")])
        }
        // Слияние с существующим словом место не занимает и проходит.
        let merged = try store.addToAgentPack(id: "agent-aaaaaaaa", words: [word("слово1", ["вариант один"])])
        #expect(merged.added == ["слово1"])
    }
}
