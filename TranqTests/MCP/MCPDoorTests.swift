import Testing
import Foundation
@testable import Tranq

/// Команды двери: запрос и ответ по `mcp/PROTOCOL.md` поверх словаря, истории и шлюза доступа.
/// Тексты ошибок зависят от языка приложения, поэтому тесты проверяют `ok`, структуру и наличие текста,
/// а отказы шлюза сверяют с тем, что сказал сам `MCPAccess`.
@MainActor
final class MCPDoorTests {
    private let directory: URL
    private let historyDirectory: URL
    private let suiteName: String
    private let accessSuiteName: String
    private let defaults: UserDefaults
    private let accessDefaults: UserDefaults

    private let itPack = DictionaryPack(
        id: "it",
        title: [.ru: "Программирование", .en: "Programming"],
        version: 1,
        entries: [
            PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]]),
            PackEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]]),
            PackEntry(spelling: "Docker", variants: [.ru: ["докер"]]),
        ]
    )
    private let legalPack = DictionaryPack(
        id: "legal",
        title: [.ru: "Юриспруденция"],
        version: 1,
        entries: [PackEntry(spelling: "оферта", variants: [:])]
    )

    init() {
        let tag = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-door-dict-\(tag)", isDirectory: true)
        historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-door-history-\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "mcp-door-dict-\(tag)"
        accessSuiteName = "mcp-door-access-\(tag)"
        defaults = UserDefaults(suiteName: suiteName)!
        accessDefaults = UserDefaults(suiteName: accessSuiteName)!
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: historyDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        accessDefaults.removePersistentDomain(forName: accessSuiteName)
    }

    // MARK: - Сборка

    private struct Setup {
        let door: MCPDoor
        let dictionary: DictionaryStore
        let history: HistoryStore
        let access: MCPAccess
    }

    private func makeSetup(
        enabled: Bool = true, fullAccess: Bool = false, historyAccess: Bool = false,
        language: DictionaryLanguage = .ru
    ) -> Setup {
        let dictionary = DictionaryStore(
            directory: directory, defaults: defaults, packsBundle: .main,
            checker: SetCommonWordChecker([:]), packs: [itPack, legalPack]
        )
        let history = HistoryStore(directory: historyDirectory, saveDelay: 10)
        let access = MCPAccess(defaults: accessDefaults)
        access.enabled = enabled
        access.fullAccess = fullAccess
        access.historyAccess = historyAccess
        let door = MCPDoor(dictionary: dictionary, history: history, access: access, language: language)
        return Setup(door: door, dictionary: dictionary, history: history, access: access)
    }

    private func request(_ cmd: String, _ args: [String: Any]? = nil) -> String {
        var object: [String: Any] = ["cmd": cmd]
        if let args { object["args"] = args }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(_ answer: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any]) ?? [:]
    }

    private func isOK(_ answer: [String: Any]) -> Bool { answer["ok"] as? Bool == true }

    private func isRefusal(_ answer: [String: Any]) -> Bool {
        answer["ok"] as? Bool == false && (answer["error"] as? String)?.isEmpty == false
    }

    private func words(_ spellings: [String]) -> [[String: Any]] {
        spellings.map { ["spelling": $0] }
    }

    private func note(_ date: String, text: String, spoken: String?) -> TranscriptionItem {
        TranscriptionItem(date: date, text: text, duration: "0:05", spokenText: spoken)
    }

    /// Пишет в историю с самой старой записи, чтобы новейшая оказалась первой, как в приложении.
    private func fill(_ history: HistoryStore, count: Int) {
        for i in 0..<count {
            history.insert(note("дата \(i)", text: "итог \(i)", spoken: "сказано \(i)"))
        }
    }

    // MARK: - Разбор запроса

    @Test func битыйJSONДаётПонятнуюОшибку() {
        let setup = makeSetup()
        for line in ["{не json", "", "[1, 2]", "\"cmd\"", "{\"cmd\": \"packs\""] {
            let answer = parse(setup.door.handle(line: line))
            #expect(isRefusal(answer), "строка «\(line)» должна дать ok:false с текстом")
        }
    }

    @Test func неизвестнаяКомандаДаётПонятнуюОшибку() {
        let setup = makeSetup()
        let unknown = parse(setup.door.handle(line: request("drop_table")))
        #expect(isRefusal(unknown))

        let missing = parse(setup.door.handle(line: "{\"args\": {}}"))
        #expect(isRefusal(missing))

        let notString = parse(setup.door.handle(line: "{\"cmd\": 7}"))
        #expect(isRefusal(notString))
    }

    @Test func argsНеОбъектДаётОшибкуБезДействия() {
        let setup = makeSetup()
        let answer = parse(setup.door.handle(line: "{\"cmd\": \"add_words\", \"args\": [1, 2]}"))
        #expect(isRefusal(answer))
        #expect(setup.dictionary.userEntries.isEmpty)
    }

    @Test func ответНесётЯзыкПриложения() {
        for language in DictionaryLanguage.allCases {
            let setup = makeSetup(language: language)
            let ok = parse(setup.door.handle(line: request("packs")))
            #expect(isOK(ok))
            #expect(ok["language"] as? String == language.rawValue)

            let bad = parse(setup.door.handle(line: "не json"))
            #expect(bad["ok"] as? Bool == false)
            #expect(bad["language"] as? String == language.rawValue)

            let unknown = parse(setup.door.handle(line: request("nope")))
            #expect(unknown["language"] as? String == language.rawValue)

            let closed = makeSetup(enabled: false, language: language)
            let denied = parse(closed.door.handle(line: request("packs")))
            #expect(denied["ok"] as? Bool == false)
            #expect(denied["language"] as? String == language.rawValue)
        }
    }

    // MARK: - Доступ

    @Test func безДоступаКаждаяКомандаОтклоняетсяИНичегоНеМеняет() {
        let setup = makeSetup(enabled: false, fullAccess: true, historyAccess: true)
        setup.history.insert(note("д", text: "т", spoken: "с"))
        let manual = setup.dictionary.addEntry(spelling: "Redis", variants: [:], source: .manual)

        let arguments: [String: [String: Any]] = [
            "set_pack": ["id": "it", "enabled": false],
            "add_words": ["words": words(["Nginx"])],
            "remove_words": ["spellings": ["Redis"]],
            "dictations": ["limit": 5],
        ]
        for command in MCPCommandName.allCases {
            let answer = parse(setup.door.handle(line: request(command.rawValue, arguments[command.rawValue])))
            guard case .deny(let expected) = setup.access.verdict(for: command, disablingPack: false) else {
                Issue.record("шлюз должен отклонить \(command.rawValue)")
                continue
            }
            #expect(isRefusal(answer), "команда \(command.rawValue) должна быть отклонена")
            #expect(answer["error"] as? String == expected, "отказ приходит из шлюза, команда \(command.rawValue)")
        }
        #expect(setup.dictionary.userEntries.map(\.id) == [manual.id])
        #expect(setup.dictionary.disabledPacks.isEmpty)
    }

    @Test func шлюзСпрашиваетсяРаньшеЧемРазбираютсяАргументы() {
        let setup = makeSetup(enabled: false)
        let answer = parse(setup.door.handle(line: "{\"cmd\": \"add_words\", \"args\": 5}"))
        guard case .deny(let expected) = setup.access.verdict(for: .addWords, disablingPack: false) else {
            Issue.record("шлюз должен отклонить")
            return
        }
        #expect(answer["error"] as? String == expected)
    }

    @Test func dictationsБезРазрешенияОтклоняется() {
        let setup = makeSetup(enabled: true, fullAccess: true, historyAccess: false)
        fill(setup.history, count: 3)

        let answer = parse(setup.door.handle(line: request("dictations")))
        #expect(isRefusal(answer))
        #expect(answer["data"] == nil, "история не должна просочиться в отказ")

        setup.access.historyAccess = true
        let allowed = parse(setup.door.handle(line: request("dictations")))
        #expect(isOK(allowed))
        #expect((allowed["data"] as? [[String: Any]])?.count == 3)
    }

    // MARK: - packs и set_pack

    @Test func packsОтдаётНазванияНаЯзыкеПриложения() throws {
        let ru = makeSetup(language: .ru)
        let ruData = try #require(parse(ru.door.handle(line: request("packs")))["data"] as? [[String: Any]])
        #expect(ruData.map { $0["id"] as? String } == ["it", "legal"])
        #expect(ruData.map { $0["title"] as? String } == ["Программирование", "Юриспруденция"])
        #expect(ruData.map { $0["word_count"] as? Int } == [3, 1])
        #expect(ruData.map { $0["enabled"] as? Bool } == [true, true])

        let en = makeSetup(language: .en)
        let enData = try #require(parse(en.door.handle(line: request("packs")))["data"] as? [[String: Any]])
        #expect(enData.map { $0["title"] as? String } == ["Programming", "Юриспруденция"], "без английского названия берётся русское")
    }

    @Test func setPackМеняетEnabledВPacks() throws {
        let setup = makeSetup(fullAccess: true)
        func enabledFlags() throws -> [Bool?] {
            let data = try #require(parse(setup.door.handle(line: request("packs")))["data"] as? [[String: Any]])
            return data.map { $0["enabled"] as? Bool }
        }
        #expect(try enabledFlags() == [true, true])

        let off = parse(setup.door.handle(line: request("set_pack", ["id": "it", "enabled": false])))
        #expect(isOK(off))
        let offPack = try #require(off["data"] as? [String: Any])
        #expect(offPack["id"] as? String == "it")
        #expect(offPack["enabled"] as? Bool == false)
        #expect(offPack["word_count"] as? Int == 3)
        #expect(offPack["title"] as? String == "Программирование")
        #expect(setup.dictionary.disabledPacks == ["it"])
        #expect(try enabledFlags() == [false, true])

        let on = parse(setup.door.handle(line: request("set_pack", ["id": "it", "enabled": true])))
        #expect((on["data"] as? [String: Any])?["enabled"] as? Bool == true)
        #expect(try enabledFlags() == [true, true])
    }

    @Test func выключениеНабораТребуетПолногоДоступаАВключениеНет() {
        let setup = makeSetup(fullAccess: false)

        let refused = parse(setup.door.handle(line: request("set_pack", ["id": "it", "enabled": false])))
        #expect(isRefusal(refused))
        #expect(setup.dictionary.disabledPacks.isEmpty)

        setup.dictionary.setPack("legal", enabled: false)
        let enabling = parse(setup.door.handle(line: request("set_pack", ["id": "legal", "enabled": true])))
        #expect(isOK(enabling), "включать набор можно без полного доступа")
        #expect(setup.dictionary.disabledPacks.isEmpty)
    }

    @Test func setPackСПлохимиАргументамиНичегоНеМеняет() {
        let setup = makeSetup(fullAccess: true)
        let badLines = [
            request("set_pack"),
            request("set_pack", ["id": "it"]),
            request("set_pack", ["enabled": false]),
            request("set_pack", ["id": 5, "enabled": false]),
            request("set_pack", ["id": "it", "enabled": "false"]),
            request("set_pack", ["id": "it", "enabled": 0]),
            request("set_pack", ["id": "нет-такого", "enabled": false]),
        ]
        for line in badLines {
            #expect(isRefusal(parse(setup.door.handle(line: line))), "строка \(line) должна быть отклонена")
        }
        #expect(setup.dictionary.disabledPacks.isEmpty)
    }

    @Test func строкаFalseВEnabledНеОбходитПроверкуПолногоДоступа() {
        let setup = makeSetup(fullAccess: false)
        let answer = parse(setup.door.handle(line: request("set_pack", ["id": "it", "enabled": "false"])))
        #expect(isRefusal(answer))
        #expect(setup.dictionary.disabledPacks.isEmpty)
    }

    // MARK: - words

    @Test func wordsПоказываетИсточникИПоследнееИспользование() throws {
        let setup = makeSetup()
        setup.dictionary.addEntry(spelling: "Redis", variants: [.ru: ["редис"], .en: ["red is"]], source: .manual)
        let learned = setup.dictionary.addEntry(spelling: "Nginx", variants: [.ru: ["энжинкс"]], source: .learned)
        setup.dictionary.addFromAgent([AgentWord(spelling: "Terraform", variants: [:], forceCase: false)])
        setup.dictionary.registerHits([
            AppliedReplacement(original: "энжинкс", replacement: "Nginx", entryKey: "user/\(learned.id.uuidString)", variant: "энжинкс", reason: .variant),
        ])

        let answer = parse(setup.door.handle(line: request("words")))
        #expect(isOK(answer))
        let data = try #require(answer["data"] as? [[String: Any]])
        #expect(data.count == 3)

        let redis = try #require(data.first { $0["spelling"] as? String == "Redis" })
        #expect(redis["source"] as? String == "manual")
        #expect(redis["hits"] as? Int == 0)
        #expect(redis["last_used"] is NSNull, "ни разу не использованное слово даёт null")
        let redisVariants = try #require(redis["variants"] as? [String: [String]])
        #expect(redisVariants["ru"] == ["редис"])
        #expect(redisVariants["en"] == ["red is"])

        let terraform = try #require(data.first { $0["spelling"] as? String == "Terraform" })
        #expect(terraform["source"] as? String == "mcp")
        let terraformVariants = try #require(terraform["variants"] as? [String: [String]])
        #expect(terraformVariants["ru"]?.isEmpty == true && terraformVariants["en"]?.isEmpty == true, "оба языка есть всегда, пустые списки без слов")

        let nginx = try #require(data.first { $0["spelling"] as? String == "Nginx" })
        #expect(nginx["source"] as? String == "learned")
        #expect(nginx["hits"] as? Int == 1)
        let lastUsed = try #require(nginx["last_used"] as? String, "использованное слово отдаёт строку")
        #expect(ISO8601DateFormatter().date(from: lastUsed) != nil, "дата в ISO 8601: \(lastUsed)")
    }

    // MARK: - add_words

    @Test func addWordsБольшеПятидесятиОтклоняетсяЦеликом() {
        let setup = makeSetup()
        let tooMany = (0...MCPDoor.maxWordsPerRequest).map { "Слово\($0)" }
        #expect(tooMany.count == MCPDoor.maxWordsPerRequest + 1)

        let answer = parse(setup.door.handle(line: request("add_words", ["words": words(tooMany)])))
        #expect(isRefusal(answer))
        #expect(setup.dictionary.userEntries.isEmpty, "ни одно слово из отклонённой пачки не записывается")

        let exact = (0..<MCPDoor.maxWordsPerRequest).map { "Слово\($0)" }
        let accepted = parse(setup.door.handle(line: request("add_words", ["words": words(exact)])))
        #expect(isOK(accepted))
        #expect(setup.dictionary.userEntries.count == MCPDoor.maxWordsPerRequest)
    }

    @Test func addWordsСПустымСпискомОтклоняется() {
        let setup = makeSetup()
        #expect(MCPDoor.maxWordsPerRequest == 50)
        let answer = parse(setup.door.handle(line: request("add_words", ["words": []])))
        #expect(isRefusal(answer))
    }

    @Test func addWordsЗаписываетСловаСИсточникомMCPИОтдаётAddedИSkipped() throws {
        let setup = makeSetup()
        let answer = parse(setup.door.handle(line: request("add_words", [
            "words": [
                ["spelling": "Kubernetes", "variants": ["ru": ["кубер", "kubernetes", "к"], "en": ["cooper"]], "force_case": true],
                ["spelling": "  Docker  "],
                ["spelling": "docker"],
                ["spelling": "   "],
            ],
        ])))
        #expect(isOK(answer))
        let data = try #require(answer["data"] as? [String: Any])
        #expect(data["added"] as? [String] == ["Kubernetes", "Docker"])
        let skipped = try #require(data["skipped"] as? [String: String])
        // Ключи отказов приходят ровно такими, какими их выдал словарь.
        #expect(Set(skipped.keys) == ["Kubernetes / kubernetes", "Kubernetes / к", "docker", "   "])
        #expect(skipped.values.allSatisfy { !$0.isEmpty })

        let kubernetes = try #require(setup.dictionary.userEntries.first { $0.spelling == "Kubernetes" })
        #expect(kubernetes.source == .mcp)
        #expect(kubernetes.forceCase)
        #expect(kubernetes.variants[.ru] == ["кубер"])
        #expect(kubernetes.variants[.en] == ["cooper"])
        #expect(setup.dictionary.userEntries.first { $0.spelling == "Docker" }?.forceCase == false)
    }

    @Test func addWordsСПлохимиАргументамиОтклоняетсяЦеликом() {
        let setup = makeSetup()
        let badLines = [
            request("add_words"),
            request("add_words", ["words": "Kubernetes"]),
            request("add_words", ["words": ["Kubernetes"]]),
            request("add_words", ["words": [["variants": ["ru": ["кубер"]]]]]),
            request("add_words", ["words": [["spelling": 5]]]),
            request("add_words", ["words": [["spelling": "Redis"], ["spelling": "Kafka", "variants": "кафка"]]]),
            request("add_words", ["words": [["spelling": "Kafka", "variants": ["ru": "кафка"]]]]),
            request("add_words", ["words": [["spelling": "Kafka", "variants": ["ru": [5]]]]]),
            request("add_words", ["words": [["spelling": "Kafka", "variants": ["de": ["кафка"]]]]]),
            request("add_words", ["words": [["spelling": "Kafka", "force_case": "yes"]]]),
        ]
        for line in badLines {
            #expect(isRefusal(parse(setup.door.handle(line: line))), "строка \(line) должна быть отклонена")
        }
        #expect(setup.dictionary.userEntries.isEmpty, "из отклонённой пачки не записывается ничего")
    }

    // MARK: - remove_words

    @Test func removeWordsБезПолногоДоступаНеТрогаетРучноеСлово() throws {
        let setup = makeSetup(fullAccess: false)
        setup.dictionary.addEntry(spelling: "Redis", variants: [:], source: .manual)
        setup.dictionary.addFromAgent([AgentWord(spelling: "Kafka", variants: [:], forceCase: false)])

        let answer = parse(setup.door.handle(line: request("remove_words", ["spellings": ["Redis", "Kafka", "Нет такого"]])))
        #expect(isOK(answer), "частичный отказ не делает весь ответ ошибкой")
        let data = try #require(answer["data"] as? [String: Any])
        #expect(data["removed"] as? [String] == ["Kafka"])
        let skipped = try #require(data["skipped"] as? [String: String])
        #expect(Set(skipped.keys) == ["Redis", "Нет такого"])
        #expect(skipped["Redis"]?.isEmpty == false, "причина отказа для ручного слова есть")
        #expect(setup.dictionary.userEntries.map(\.spelling) == ["Redis"])
    }

    @Test func removeWordsСПолнымДоступомСнимаетИРучноеСлово() throws {
        let setup = makeSetup(fullAccess: true)
        setup.dictionary.addEntry(spelling: "Redis", variants: [:], source: .manual)

        let answer = parse(setup.door.handle(line: request("remove_words", ["spellings": ["redis"]])))
        let data = try #require(answer["data"] as? [String: Any])
        #expect(data["removed"] as? [String] == ["redis"])
        #expect((data["skipped"] as? [String: String])?.isEmpty == true)
        #expect(setup.dictionary.userEntries.isEmpty)
    }

    @Test func removeWordsСПлохимиАргументамиОтклоняется() {
        let setup = makeSetup(fullAccess: true)
        setup.dictionary.addEntry(spelling: "Redis", variants: [:], source: .manual)
        for line in [request("remove_words"), request("remove_words", ["spellings": "Redis"]), request("remove_words", ["spellings": ["Redis", 5]])] {
            #expect(isRefusal(parse(setup.door.handle(line: line))), "строка \(line) должна быть отклонена")
        }
        #expect(setup.dictionary.userEntries.count == 1)
    }

    // MARK: - revert_agent_words

    @Test func revertAgentWordsВозвращаетЧислаСнятого() throws {
        let setup = makeSetup()
        setup.dictionary.addEntry(spelling: "Redis", variants: [.ru: ["редис"]], source: .manual)
        setup.dictionary.addFromAgent([
            AgentWord(spelling: "Redis", variants: [.ru: ["ридис", "рэдис"]], forceCase: false),
            AgentWord(spelling: "Kafka", variants: [:], forceCase: false),
            AgentWord(spelling: "Nginx", variants: [:], forceCase: false),
        ])

        let answer = parse(setup.door.handle(line: request("revert_agent_words")))
        #expect(isOK(answer))
        let data = try #require(answer["data"] as? [String: Any])
        #expect(data["removed_words"] as? Int == 2)
        #expect(data["removed_variants"] as? Int == 2)
        #expect(Set(data.keys) == ["removed_words", "removed_variants"])
        #expect(setup.dictionary.userEntries.map(\.spelling) == ["Redis"])
        #expect(setup.dictionary.userEntries.first?.variants[.ru] == ["редис"])
    }

    // MARK: - dictations

    @Test func dictationsПропускаетЗаметкиБезСыройРасшифровки() throws {
        let setup = makeSetup(historyAccess: true)
        setup.history.insert(note("01.01.2026, 10:00", text: "первая итог", spoken: "первая сказано"))
        setup.history.insert(note("01.01.2026, 10:05", text: "ручная заметка", spoken: nil))
        setup.history.insert(note("01.01.2026, 10:10", text: "пустая расшифровка", spoken: ""))
        setup.history.insert(note("01.01.2026, 10:15", text: "пробелы", spoken: "  \n "))
        setup.history.insert(note("01.01.2026, 10:20", text: "вторая итог", spoken: "вторая сказано"))

        let answer = parse(setup.door.handle(line: request("dictations")))
        #expect(isOK(answer))
        let data = try #require(answer["data"] as? [[String: Any]])
        #expect(data.count == 2)
        // Новейшая запись идёт первой, дата отдаётся строкой как в истории.
        #expect(data[0]["date"] as? String == "01.01.2026, 10:20")
        #expect(data[0]["spoken"] as? String == "вторая сказано")
        #expect(data[0]["text"] as? String == "вторая итог")
        #expect(data[1]["date"] as? String == "01.01.2026, 10:00")
        #expect(data[1]["spoken"] as? String == "первая сказано")
        #expect(data[1]["text"] as? String == "первая итог")
        #expect(Set(data[0].keys) == ["date", "spoken", "text"])
    }

    @Test func dictationsЛимитУмолчаниеПотолокИНеправильныеЗначения() throws {
        let setup = makeSetup(historyAccess: true)
        fill(setup.history, count: 130)
        // Пропущенные заметки не должны съедать место в лимите: пустые лежат поверх всех.
        setup.history.insert(note("пусто", text: "ручная", spoken: nil))

        func count(_ args: [String: Any]?) throws -> Int {
            let answer = parse(setup.door.handle(line: request("dictations", args)))
            #expect(isOK(answer))
            return try #require(answer["data"] as? [[String: Any]]).count
        }

        #expect(try count(nil) == 20)
        #expect(try count([:]) == 20)
        #expect(try count(["limit": 20]) == 20)
        #expect(try count(["limit": 7]) == 7)
        #expect(try count(["limit": 100]) == 100)
        #expect(try count(["limit": 101]) == 100)
        #expect(try count(["limit": 5000]) == 100)
        #expect(try count(["limit": 1e30]) == 100)
        #expect(try count(["limit": 0]) == 20)
        #expect(try count(["limit": -3]) == 20)
        #expect(try count(["limit": NSNull()]) == 20)

        let newest = parse(setup.door.handle(line: request("dictations", ["limit": 2])))
        let data = try #require(newest["data"] as? [[String: Any]])
        #expect(data.map { $0["date"] as? String } == ["дата 129", "дата 128"])
    }

    @Test func dictationsСНеЧисловымЛимитомОтклоняется() {
        let setup = makeSetup(historyAccess: true)
        fill(setup.history, count: 3)
        let badLimits: [Any] = ["10", true, [5], ["n": 5]]
        for limit in badLimits {
            #expect(isRefusal(parse(setup.door.handle(line: request("dictations", ["limit": limit])))), "limit \(limit) должен быть отклонён")
        }
    }

    // MARK: - Форма ответа

    @Test func каждыйУспешныйОтветЭтоВалидныйJSONСОтсортированнымиКлючами() throws {
        let setup = makeSetup(fullAccess: true, historyAccess: true)
        fill(setup.history, count: 2)
        setup.dictionary.addEntry(spelling: "Redis", variants: [.ru: ["редис"]], source: .manual)

        let lines = [
            request("packs"),
            request("words"),
            request("set_pack", ["id": "it", "enabled": false]),
            request("add_words", ["words": [["spelling": "Kafka", "variants": ["ru": ["кафка", "к"]], "force_case": true]]]),
            request("remove_words", ["spellings": ["Kafka", "Нет такого"]]),
            request("revert_agent_words"),
            request("dictations"),
        ]
        for line in lines {
            let answer = setup.door.handle(line: line)
            #expect(!answer.contains("\n"), "ответ идёт одной строкой: \(line)")
            let object = try #require(try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any], "ответ не разобрался: \(answer)")
            #expect(isOK(object), "ответ на \(line) должен быть успешным: \(answer)")
            #expect(object["language"] as? String == "ru")
            let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(String(decoding: sorted, as: UTF8.self) == answer, "ключи в ответе на \(line) идут по алфавиту")
        }

        // Отказ собран так же: ключи по алфавиту, одна строка.
        let refusal = setup.door.handle(line: "не json")
        #expect(refusal.hasPrefix("{\"error\":"))
        #expect(refusal.hasSuffix(",\"language\":\"ru\",\"ok\":false}"))
    }

    // MARK: - Потоки

    @Test func вызовСФоновогоПотокаПереходитНаГлавныйИПишетТолькоТам() async throws {
        let setup = makeSetup(fullAccess: true, historyAccess: true)
        fill(setup.history, count: 4)
        var mutationThreads: [Bool] = []
        let token = setup.dictionary.objectWillChange.sink { mutationThreads.append(Thread.isMainThread) }
        defer { token.cancel() }

        let line = request("add_words", ["words": words(["Kafka"])])
        let door = setup.door
        let answers: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                let added = door.handle(line: line)
                let dictations = door.handle(line: "{\"cmd\": \"dictations\", \"args\": {\"limit\": 3}}")
                continuation.resume(returning: [added, dictations])
            }
        }

        let added = parse(answers[0])
        #expect(isOK(added))
        #expect((added["data"] as? [String: Any])?["added"] as? [String] == ["Kafka"])
        #expect(setup.dictionary.userEntries.map(\.spelling) == ["Kafka"])
        #expect(!mutationThreads.isEmpty)
        #expect(mutationThreads.allSatisfy { $0 }, "словарь меняется только на главном потоке")
        #expect((parse(answers[1])["data"] as? [[String: Any]])?.count == 3)
    }

    /// Результат фонового вызова: пишет фоновый поток, читает главный.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ text: String) { lock.lock(); stored = text; lock.unlock() }
    }

    @Test func фоновыйВызовЖдётГлавныйПотокПередЧтениемШлюзаИИстории() async throws {
        let setup = makeSetup(historyAccess: true)
        fill(setup.history, count: 2)
        let door = setup.door
        let box = Box()
        let started = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            started.signal()
            box.set(door.handle(line: "{\"cmd\": \"dictations\"}"))
        }
        started.wait()
        // Главный поток занят: дверь, которая читает шлюз и историю на месте, успела бы ответить за это время.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(box.value == nil, "ответ не должен прийти, пока главный поток занят")

        for _ in 0..<100 where box.value == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let answer = parse(try #require(box.value, "после освобождения главного потока ответ приходит"))
        #expect(isOK(answer))
        #expect((answer["data"] as? [[String: Any]])?.count == 2)
    }

    @Test func вызовСГлавногоПотокаНеЗависает() {
        let setup = makeSetup()
        #expect(Thread.isMainThread)
        #expect(isOK(parse(setup.door.handle(line: request("packs")))))
    }
}
