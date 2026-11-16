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

private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct DictionaryEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case manual, learned }

    var id: UUID
    var spelling: String
    var variants: [DictionaryLanguage: [String]]
    var source: Source
    var forceCase: Bool
    var createdAt: Date
    var hits: Int
    var lastUsed: Date?
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
        variants = try c.decode([DictionaryLanguage: [String]].self, forKey: .variants)
        commonIn = try c.decodeIfPresent([DictionaryLanguage].self, forKey: .commonIn) ?? []
    }
}

struct DictionaryPack: Codable, Identifiable {
    var id: String
    var title: [DictionaryLanguage: String]
    var version: Int
    var entries: [PackEntry]
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
