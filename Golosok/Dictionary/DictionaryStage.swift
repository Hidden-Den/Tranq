import Foundation

/// Этап словаря в конвейере диктовки: точная замена и регистр до и после модели,
/// нечёткий поиск только в теневом режиме. Сбой словаря не ломает диктовку.
enum DictionaryStage {
    private static let logSource = "Dictionary"

    /// Заменяет варианты на написания, запоминает замены заметки и отмечает срабатывания.
    /// `fired` — сработавшие написания без повторов, в порядке появления. Можно вызывать с любого потока.
    static func apply(
        _ text: String,
        noteId: UUID,
        language: DictionaryLanguage,
        store: DictionaryStore = .shared
    ) -> (text: String, fired: [String]) {
        guard let index = store.index else {
            AppLogger.shared.warn(logSource, "Словарь ещё не готов, текст без замен")
            return (text, [])
        }
        let result = index.apply(to: text, language: language)
        guard !result.replacements.isEmpty else { return (text, []) }

        store.recordReplacements(result.replacements, noteId: noteId)
        store.registerHits(result.replacements)

        var seen = Set<String>()
        var fired: [String] = []
        for replacement in result.replacements {
            AppLogger.shared.info(
                logSource,
                "Словарь: «\(replacement.original)» → «\(replacement.replacement)», \(reasonTitle(replacement.reason)), \(sourceTitle(replacement.entryKey))"
            )
            if seen.insert(replacement.replacement).inserted { fired.append(replacement.replacement) }
        }
        return (result.text, fired)
    }

    /// Ищет похожие слова в фоне и только пишет в лог; текст не меняется.
    static func shadowFuzzy(_ text: String, language: DictionaryLanguage, store: DictionaryStore = .shared) {
        DispatchQueue.global(qos: .utility).async {
            _ = shadowHits(text, language: language, store: store)
        }
    }

    /// Синхронная часть теневого поиска: пишет в лог и возвращает находки.
    static func shadowHits(_ text: String, language: DictionaryLanguage, store: DictionaryStore = .shared) -> [FuzzyHit] {
        guard let index = store.index else { return [] }
        let hits = index.fuzzyHits(in: text, language: language)
        for hit in hits {
            AppLogger.shared.info(
                logSource,
                "Словарь: заменил бы «\(hit.token)» на «\(hit.spelling)», сходство \(String(format: "%.2f", hit.similarity))"
            )
        }
        return hits
    }

    private static func reasonTitle(_ reason: AppliedReplacement.Reason) -> String {
        switch reason {
        case .variant: return "вариант"
        case .caseFix: return "регистр"
        }
    }

    /// `user/<uuid>` — пользовательская запись, иначе `<packId>/<spelling>`.
    private static func sourceTitle(_ entryKey: String) -> String {
        if entryKey.hasPrefix("user/") { return "пользователь" }
        let packId = entryKey.split(separator: "/", maxSplits: 1).first.map(String.init) ?? entryKey
        return "набор \(packId)"
    }
}
