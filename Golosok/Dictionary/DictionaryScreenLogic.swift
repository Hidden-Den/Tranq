import Foundation

/// Чистая логика экрана словаря: поиск, строки вариантов, названия наборов, проверка введённых вариантов.
enum DictionaryScreenLogic {
    struct SearchResult: Identifiable, Equatable {
        enum Source: Equatable {
            case user(UUID)
            case pack(id: String)
        }

        var id: String { spelling.lowercased() }
        let spelling: String
        let variants: [DictionaryLanguage: [String]]
        let source: Source
    }

    /// Поиск по написанию и вариантам обоих языков без учёта регистра.
    /// Одна строка на написание: пользовательская запись важнее набора, ранний набор важнее позднего.
    static func search(_ query: String, userEntries: [DictionaryEntry], packs: [DictionaryPack]) -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        func matches(_ spelling: String, _ variants: [DictionaryLanguage: [String]]) -> Bool {
            spelling.localizedCaseInsensitiveContains(needle)
                || variants.values.contains { $0.contains { $0.localizedCaseInsensitiveContains(needle) } }
        }

        var seen = Set<String>()
        var results: [SearchResult] = []
        for entry in userEntries where matches(entry.spelling, entry.variants) {
            guard seen.insert(entry.spelling.lowercased()).inserted else { continue }
            results.append(SearchResult(spelling: entry.spelling, variants: entry.variants, source: .user(entry.id)))
        }
        for pack in packs {
            for entry in pack.entries where matches(entry.spelling, entry.variants) {
                guard seen.insert(entry.spelling.lowercased()).inserted else { continue }
                results.append(SearchResult(spelling: entry.spelling, variants: entry.variants, source: .pack(id: pack.id)))
            }
        }
        return results
    }

    static func variantLine(_ variants: [DictionaryLanguage: [String]], language: DictionaryLanguage) -> String {
        (variants[language] ?? []).joined(separator: " · ")
    }

    static func packWordKey(packId: String, spelling: String) -> String {
        "\(packId)/\(spelling)"
    }

    /// Варианты слова набора без выключенных пользователем.
    static func packVariants(_ entry: PackEntry, packId: String, language: DictionaryLanguage, disabled: Set<String>) -> [String] {
        let key = packWordKey(packId: packId, spelling: entry.spelling)
        return (entry.variants[language] ?? []).filter { !disabled.contains("\(key)/\($0)") }
    }

    /// Название набора на языке интерфейса, иначе на другом языке, иначе идентификатор.
    static func packTitle(_ pack: DictionaryPack, uiLanguage: DictionaryLanguage) -> String {
        let other: DictionaryLanguage = uiLanguage == .en ? .ru : .en
        return pack.title[uiLanguage] ?? pack.title[other] ?? pack.id
    }

    /// Язык интерфейса: английский только при английской локализации, иначе русский.
    static func uiLanguage(preferredLocalizations: [String]) -> DictionaryLanguage {
        preferredLocalizations.first?.lowercased().hasPrefix("en") == true ? .en : .ru
    }

    static var currentUILanguage: DictionaryLanguage {
        uiLanguage(preferredLocalizations: Bundle.main.preferredLocalizations)
    }

    enum ProbeResult: Equatable {
        case heard(String), notHeard, justTheWord, alreadyRecognized
    }

    /// Что показать после записи 🎙: тишина и шум дают «Не расслышал», вариант всегда подтверждает пользователь.
    static func probeResult(_ outcome: WordProbeOutcome) -> ProbeResult {
        switch outcome {
        case .tooQuiet, .noise: return .notHeard
        case .tooManyWords: return .justTheWord
        case .alreadyCorrect: return .alreadyRecognized
        case .variant(let text): return .heard(text)
        }
    }

    /// Удаление варианта удалит запись целиком: выученная запись теряет последний вариант.
    static func removalDeletesEntry(_ entry: DictionaryEntry, variant: String, language: DictionaryLanguage) -> Bool {
        guard entry.source == .learned else { return false }
        let lowered = variant.lowercased()
        return entry.variants.allSatisfy { lang, list in
            list.allSatisfy { lang == language && $0.lowercased() == lowered }
        }
    }

    /// Нормализованный вариант, введённый вручную, или nil: правила наборов, письменность языка, без повторов.
    static func typedVariant(
        _ raw: String, spelling: String, language: DictionaryLanguage, existing: [String], checker: CommonWordChecking
    ) -> String? {
        guard let variant = VariantRules.accepted(raw, spelling: spelling, language: language, checker: checker),
              !existing.contains(where: { $0.lowercased() == variant }) else { return nil }
        return variant
    }
}

/// Черновик окна добавления: подсказки автоподбора, записанные голосом варианты и удалённые пользователем.
struct AddWordDraft: Equatable {
    private var suggested: [DictionaryLanguage: [String]] = [:]
    private var recorded: [DictionaryLanguage: [String]] = [:]
    private var removed: Set<String> = []

    private static func key(_ variant: String, _ language: DictionaryLanguage) -> String {
        "\(language.rawValue)|\(variant.lowercased())"
    }

    /// Заменяет подсказки целиком: они относятся к текущему написанию.
    mutating func applySuggestions(_ suggestions: [DictionaryLanguage: [String]]) {
        suggested = suggestions
    }

    mutating func addRecorded(_ variant: String, language: DictionaryLanguage) {
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        removed.remove(Self.key(trimmed, language))
        guard !variants(for: language).contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        recorded[language, default: []].append(trimmed)
    }

    mutating func remove(_ variant: String, language: DictionaryLanguage) {
        removed.insert(Self.key(variant, language))
        recorded[language]?.removeAll { $0.lowercased() == variant.lowercased() }
    }

    /// Подсказки, затем записанные варианты, без удалённых и без повторов.
    func variants(for language: DictionaryLanguage) -> [String] {
        var seen = Set<String>()
        return ((suggested[language] ?? []) + (recorded[language] ?? [])).filter {
            !removed.contains(Self.key($0, language)) && seen.insert($0.lowercased()).inserted
        }
    }

    /// Сохраняется только то, что пользователь видел: варианты показанного языка.
    func variantsToSave(shown language: DictionaryLanguage) -> [DictionaryLanguage: [String]] {
        let list = variants(for: language)
        return list.isEmpty ? [:] : [language: list]
    }

    var allVariants: [DictionaryLanguage: [String]] {
        var result: [DictionaryLanguage: [String]] = [:]
        for language in DictionaryLanguage.allCases {
            let list = variants(for: language)
            if !list.isEmpty { result[language] = list }
        }
        return result
    }
}
