import Foundation

/// Дверь приложения для нейронок: разбирает одну строку запроса, спрашивает шлюз доступа,
/// выполняет команду над словарём или историей и собирает одну строку ответа.
/// Формат запросов, имена команд и формы ответов описаны в `mcp/PROTOCOL.md`.
///
/// Дверь не знает про сокет: сокет читает строку, зовёт `handle(line:)` и пишет ответ.
/// Запрос и ответ разбираются и собираются через `JSONSerialization`, отдельные типы на каждую команду не нужны.
///
/// Дверь можно передавать между потоками: единственный вход, `handle(line:)`, сам уходит на главный.
struct MCPDoor: @unchecked Sendable {
    /// Больше слов в одном `add_words` не принимается: пачку отклоняют целиком и просят разбить.
    static let maxWordsPerRequest = 50
    /// Сколько диктовок отдаёт `dictations`, если `limit` не задан, равен нулю или отрицателен.
    static let defaultDictationLimit = 20
    /// Потолок `limit`: всё, что больше, обрезается до него.
    static let maxDictationLimit = 100

    private let dictionary: DictionaryStore
    private let history: HistoryStore
    private let access: MCPAccess
    /// Язык приложения: сокет берёт его для отказа, который собирает сам, без двери.
    let language: DictionaryLanguage

    /// `language` — язык приложения: на нём идут названия наборов и тексты ошибок, он же попадает в каждый ответ.
    init(dictionary: DictionaryStore, history: HistoryStore, access: MCPAccess, language: DictionaryLanguage) {
        self.dictionary = dictionary
        self.history = history
        self.access = access
        self.language = language
    }

    /// Принимает строку запроса без перевода строки и возвращает строку ответа без перевода строки.
    /// Хранилища меняются только на главном потоке, а сокет зовёт дверь с фоновой очереди:
    /// с другого потока вызов сам переходит на главный, с главного выполняется на месте.
    func handle(line: String) -> String {
        let work = { respond(to: line) }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    // MARK: - Запрос

    /// Отказ с текстом для человека: агент покажет его как есть.
    private struct Refusal: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private func respond(to line: String) -> String {
        do {
            return success(try run(line))
        } catch let refusal as Refusal {
            return failure(refusal.text)
        } catch {
            return failure(String(localized: "Не удалось выполнить команду."))
        }
    }

    private func run(_ line: String) throws -> Any {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            throw Refusal(String(localized: "Не удалось прочитать запрос. Нужна одна строка JSON с полем cmd."))
        }
        guard let name = request["cmd"] as? String, !name.isEmpty else {
            throw Refusal(String(localized: "В запросе нет команды. Нужно поле cmd со строкой."))
        }
        guard let command = MCPCommandName(rawValue: name) else {
            let known = MCPCommandName.allCases.map(\.rawValue).joined(separator: ", ")
            throw Refusal(String(localized: "Неизвестная команда \(name). Доступны: \(known)."))
        }

        // Выключение набора выводится из самого `enabled`: отдельного флага в запросе нет.
        // Строгое чтение булева значения общее с выполнением, поэтому строка "false" шлюз не обходит.
        let rawArgs = request["args"]
        var disablingPack = false
        if command == .setPack, let args = rawArgs as? [String: Any] {
            disablingPack = Self.boolean(args["enabled"]) == false
        }
        if case .deny(let text) = access.verdict(for: command, disablingPack: disablingPack) {
            throw Refusal(text)
        }

        let args: [String: Any]
        switch rawArgs {
        case nil, is NSNull: args = [:]
        case let object as [String: Any]: args = object
        default: throw Refusal(String(localized: "Поле args должно быть объектом."))
        }

        switch command {
        case .packs: return packs()
        case .words: return words()
        case .setPack: return try setPack(args)
        case .addWords: return try addWords(args)
        case .removeWords: return try removeWords(args)
        case .revertAgentWords: return revertAgentWords()
        case .dictations: return try dictations(args)
        case .createPack: return try createPack(args)
        case .deletePack: return try deletePack(args)
        case .packWords: return try packWords(args)
        }
    }

    // MARK: - Наборы и слова

    private func packs() -> Any {
        dictionary.packs.map(packObject)
    }

    private func packObject(_ pack: DictionaryPack) -> [String: Any] {
        [
            "id": pack.id,
            "title": DictionaryScreenLogic.packTitle(pack, uiLanguage: language),
            "word_count": pack.entries.count,
            "enabled": !dictionary.disabledPacks.contains(pack.id),
            "source": dictionary.agentPacks.contains { $0.id == pack.id } ? "agent" : "builtin",
        ]
    }

    private func words() -> Any {
        let formatter = ISO8601DateFormatter()
        return dictionary.userEntries.map { entry -> [String: Any] in
            [
                "spelling": entry.spelling,
                "variants": variantsObject(entry.variants),
                "source": entry.source.rawValue,
                "hits": entry.hits,
                "last_used": entry.lastUsed.map { formatter.string(from: $0) } ?? NSNull(),
            ]
        }
    }

    /// Оба языка есть всегда, чтобы читателю не гадать о форме.
    private func variantsObject(_ variants: [DictionaryLanguage: [String]]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: DictionaryLanguage.allCases.map { ($0.rawValue, variants[$0] ?? []) })
    }

    private func setPack(_ args: [String: Any]) throws -> Any {
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw Refusal(String(localized: "Для набора нужно поле id со строкой."))
        }
        guard let enabled = Self.boolean(args["enabled"]) else {
            throw Refusal(String(localized: "Для набора нужно поле enabled со значением true или false."))
        }
        guard let pack = dictionary.packs.first(where: { $0.id == id }) else {
            throw Refusal(String(localized: "Набора \(id) нет. Список наборов даёт команда packs."))
        }
        dictionary.setPack(id, enabled: enabled)
        return packObject(pack)
    }

    // MARK: - Запись слов

    private func addWords(_ args: [String: Any]) throws -> Any {
        guard let raw = args["words"] as? [Any] else {
            throw Refusal(String(localized: "Нужно поле words со списком слов."))
        }
        guard !raw.isEmpty else {
            throw Refusal(String(localized: "Список слов пуст. Передайте хотя бы одно слово."))
        }
        guard raw.count <= Self.maxWordsPerRequest else {
            throw Refusal(String(localized: "Слишком много слов за раз: не больше \(Self.maxWordsPerRequest). Разбейте список на части."))
        }
        let words = try raw.enumerated().map { try agentWord($1, number: $0 + 1) }
        let result: AgentWriteResult
        if let packID = try packID(args) {
            result = try packWork { try dictionary.addToAgentPack(id: packID, words: words) }
        } else {
            result = dictionary.addFromAgent(words)
        }
        return ["added": result.added, "skipped": result.skipped]
    }

    /// Одно слово из запроса. Любая неточность отклоняет всю пачку: полупринятый список агенту труднее разобрать.
    private func agentWord(_ raw: Any, number: Int) throws -> AgentWord {
        guard let object = raw as? [String: Any], let spelling = object["spelling"] as? String else {
            throw Refusal(String(localized: "Слово номер \(number): нужно поле spelling со строкой."))
        }

        var variants: [DictionaryLanguage: [String]] = [:]
        switch object["variants"] {
        case nil, is NSNull:
            break
        case let byLanguage as [String: Any]:
            for (code, value) in byLanguage {
                guard let language = DictionaryLanguage(rawValue: code) else { throw badVariants(number) }
                switch value {
                case is NSNull: continue
                case let list as [Any]:
                    let strings = list.compactMap { $0 as? String }
                    guard strings.count == list.count else { throw badVariants(number) }
                    variants[language] = strings
                default:
                    throw badVariants(number)
                }
            }
        default:
            throw badVariants(number)
        }

        var forceCase = false
        switch object["force_case"] {
        case nil, is NSNull:
            break
        case let value?:
            guard let flag = Self.boolean(value) else {
                throw Refusal(String(localized: "Слово номер \(number): force_case должен быть true или false."))
            }
            forceCase = flag
        }
        return AgentWord(spelling: spelling, variants: variants, forceCase: forceCase)
    }

    private func badVariants(_ number: Int) -> Refusal {
        Refusal(String(localized: "Слово номер \(number): variants должен быть объектом, где ключ язык ru или en, а значение список строк."))
    }

    private func removeWords(_ args: [String: Any]) throws -> Any {
        guard let raw = args["spellings"] as? [Any] else {
            throw Refusal(String(localized: "Нужно поле spellings со списком строк."))
        }
        let spellings = raw.compactMap { $0 as? String }
        guard spellings.count == raw.count else {
            throw Refusal(String(localized: "Нужно поле spellings со списком строк."))
        }
        let result: AgentWriteResult
        if let packID = try packID(args) {
            // Набор принадлежит агенту, полный доступ для его слов не нужен.
            result = try packWork { try dictionary.removeFromAgentPack(id: packID, spellings: spellings) }
        } else {
            // Слова, написанные человеком, защищает само хранилище: без полного доступа оно их не снимает.
            result = dictionary.removeFromAgent(spellings: spellings, fullAccess: access.fullAccess)
        }
        return ["removed": result.added, "skipped": result.skipped]
    }

    private func revertAgentWords() -> Any {
        let result = dictionary.revertAgentChanges()
        return [
            "removed_words": result.removedWords,
            "removed_variants": result.removedVariants,
            "removed_packs": result.removedPacks,
        ]
    }

    // MARK: - Наборы агента

    private func createPack(_ args: [String: Any]) throws -> Any {
        guard let title = args["title"] as? String else {
            throw Refusal(String(localized: "Для набора нужно поле title со строкой."))
        }
        let result = try packWork { try dictionary.createAgentPack(title: title) }
        return ["id": result.id, "title": result.title, "created": result.created]
    }

    private func deletePack(_ args: [String: Any]) throws -> Any {
        let id = try requiredPackID(args)
        let result = try packWork { try dictionary.deleteAgentPack(id: id) }
        return ["id": result.id, "title": result.title, "removed_words": result.removedWords]
    }

    private func packWords(_ args: [String: Any]) throws -> Any {
        let id = try requiredPackID(args)
        let pack = try packWork { try dictionary.agentPack(id: id) }
        return pack.entries.map { ["spelling": $0.spelling, "variants": variantsObject($0.variants)] as [String: Any] }
    }

    private func requiredPackID(_ args: [String: Any]) throws -> String {
        guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw Refusal(String(localized: "Для набора нужно поле id со строкой."))
        }
        return id
    }

    /// `pack_id` отсутствует или `null`: слова идут в «Мои слова». Любое другое значение, кроме непустой строки,
    /// отказ: пустая строка не должна молча попасть в личный список.
    private func packID(_ args: [String: Any]) throws -> String? {
        switch args["pack_id"] {
        case nil, is NSNull:
            return nil
        case let id as String where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            throw Refusal(String(localized: "Поле pack_id должно быть непустой строкой."))
        }
    }

    /// Отказы хранилища становятся отказами двери с текстом для человека.
    private func packWork<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AgentPackError {
            switch error {
            case .emptyTitle:
                throw Refusal(String(localized: "Название набора не может быть пустым."))
            case .titleTooLong(let limit):
                throw Refusal(String(localized: "Название набора длиннее \(limit) знаков."))
            case .titleTakenByBuiltIn:
                throw Refusal(String(localized: "Такое название у встроенного набора. Выберите другое."))
            case .tooManyPacks(let limit):
                throw Refusal(String(localized: "Наборов агента уже \(limit), это предел. Удалите ненужный набор."))
            case .builtInPack:
                throw Refusal(String(localized: "Это встроенный набор. Работать можно только с наборами агента."))
            case .noSuchPack(let id):
                throw Refusal(String(localized: "Набора \(id) нет. Список наборов даёт команда packs."))
            case .tooManyWords(let limit, let free):
                throw Refusal(String(localized: "В наборе не больше \(limit) слов, свободно \(free). Ничего не записано."))
            }
        }
    }

    // MARK: - История

    private func dictations(_ args: [String: Any]) throws -> Any {
        let limit = try dictationLimit(args["limit"])
        // Новейшие записи идут первыми. Заметки без сырой расшифровки пропускаются до подсчёта лимита.
        let items = history.items.lazy.compactMap { item -> [String: Any]? in
            guard let spoken = item.spokenText,
                  !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["date": item.date, "spoken": spoken, "text": item.text]
        }
        return Array(items.prefix(limit))
    }

    /// Без `limit`, а также при нуле и отрицательном значении, даёт 20; всё выше 100 даёт 100.
    private func dictationLimit(_ raw: Any?) throws -> Int {
        switch raw {
        case nil, is NSNull:
            return Self.defaultDictationLimit
        case let value?:
            guard let number = Self.number(value) else {
                throw Refusal(String(localized: "Поле limit должно быть числом."))
            }
            let limit = number.doubleValue
            // Сравнение с единицей отсекает ноль, отрицательные и дробные меньше единицы.
            guard limit >= 1 else { return Self.defaultDictationLimit }
            return Int(min(limit, Double(Self.maxDictationLimit)))
        }
    }

    // MARK: - Значения из JSON

    /// Только настоящие `true` и `false`: число 0, 1 или строка "false" булевым значением не считаются.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Число из JSON без булевых значений: `true` числом не считается.
    private static func number(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    // MARK: - Ответ

    private func success(_ data: Any) -> String {
        render(["ok": true, "data": data]) ?? failure(String(localized: "Не удалось собрать ответ."))
    }

    private func failure(_ text: String) -> String {
        // Из строки и двух простых значений собирается всегда, запасного пути у отказа нет.
        render(["ok": false, "error": text]) ?? "{\"ok\":false}"
    }

    /// Одна строка JSON с ключами по алфавиту, чтобы ответы можно было сравнивать как строки.
    private func render(_ body: [String: Any]) -> String? {
        var object = body
        object["language"] = language.rawValue
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
