import Foundation

enum DictionaryLanguage: String, Codable, CaseIterable, CodingKeyRepresentable {
    case ru, en

    /// Язык диктовки: `languageCode` активной модели, всё кроме `en` даёт `ru`.
    static var current: DictionaryLanguage {
        let store = ModelStore.shared
        let code = store.model(named: store.activeModelID)?.languageCode
        return code == "en" ? .en : .ru
    }

    var codingKey: any CodingKey { StringCodingKey(stringValue: rawValue) }

    init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

extension KeyedDecodingContainer {
    /// Словарь по языкам: неизвестные ключи, например `de`, отбрасываются, а не ломают весь файл.
    func decodeLanguageMap<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [DictionaryLanguage: T] {
        let raw = try decode([String: T].self, forKey: key)
        var result: [DictionaryLanguage: T] = [:]
        for (code, value) in raw {
            if let language = DictionaryLanguage(rawValue: code) { result[language] = value }
        }
        return result
    }

    /// Список языков без неизвестных значений.
    func decodeLanguageListIfPresent(forKey key: Key) throws -> [DictionaryLanguage]? {
        try decodeIfPresent([String].self, forKey: key)?.compactMap(DictionaryLanguage.init(rawValue:))
    }
}

private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct DictionaryEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case manual, learned, mcp }

    var id: UUID
    var spelling: String
    var variants: [DictionaryLanguage: [String]]
    var source: Source
    var forceCase: Bool
    var createdAt: Date
    var hits: Int
    var lastUsed: Date?
}

extension DictionaryEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            spelling: try c.decode(String.self, forKey: .spelling),
            variants: try c.decodeLanguageMap([String].self, forKey: .variants),
            // Неизвестный источник читается как ручной: одна запись не должна ронять весь словарь.
            source: Source(rawValue: try c.decode(String.self, forKey: .source)) ?? .manual,
            forceCase: try c.decode(Bool.self, forKey: .forceCase),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            hits: try c.decode(Int.self, forKey: .hits),
            lastUsed: try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        )
    }
}

struct PackEntry: Codable, Equatable {
    var spelling: String
    var variants: [DictionaryLanguage: [String]]
    var commonIn: [DictionaryLanguage]

    init(spelling: String, variants: [DictionaryLanguage: [String]], commonIn: [DictionaryLanguage] = []) {
        self.spelling = spelling
        self.variants = variants
        self.commonIn = commonIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spelling = try c.decode(String.self, forKey: .spelling)
        variants = try c.decodeLanguageMap([String].self, forKey: .variants)
        commonIn = try c.decodeLanguageListIfPresent(forKey: .commonIn) ?? []
    }
}

struct DictionaryPack: Codable, Identifiable {
    var id: String
    var title: [DictionaryLanguage: String]
    var version: Int
    var entries: [PackEntry]
}

extension DictionaryPack: Equatable {}

extension DictionaryPack {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decodeLanguageMap(String.self, forKey: .title),
            version: try c.decode(Int.self, forKey: .version),
            entries: try c.decode([PackEntry].self, forKey: .entries)
        )
    }
}

struct AppliedReplacement: Equatable {
    enum Reason { case variant, caseFix }

    var original: String
    var replacement: String
    /// `user/<uuid>` или `<packId>/<spelling>`.
    var entryKey: String
    var variant: String
    var reason: Reason
}
