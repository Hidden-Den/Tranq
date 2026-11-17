import Testing
import Foundation
@testable import Golosok

/// Проверки всех наборов из `Dictionaries` в бандле. Нарушения исправляются в данных, а не в тестах.
struct PackValidationTests {
    /// Наборы, файлы которых уже есть. Новый набор добавляется сюда вместе с файлом.
    static let implementedPackIds = ["it", "ai", "apps", "management", "business", "hr", "finance", "marketing", "legal", "design"]

    static let loanwordBlocklist: Set<String> = [
        "спринт", "оффер", "деплой", "онбординг", "оффбординг", "бэклог", "ретро", "стендап", "дейли", "синк",
        "хотфикс", "фронтенд", "бэкенд", "тимлид", "продакт", "роадмап", "питчдек", "кастдев",
    ]

    static let annotateHint = "запустите scripts/annotate-dictionaries.swift"

    private let packs = DictionaryStore.loadPacks(from: .main)
    private let checker = SpellCommonWordChecker.shared

    /// Все варианты набора как `(набор, написание, язык, вариант)`.
    private var allVariants: [(pack: String, spelling: String, language: DictionaryLanguage, variant: String)] {
        packs.flatMap { pack in
            pack.entries.flatMap { entry in
                entry.variants.flatMap { language, variants in
                    variants.map { (pack.id, entry.spelling, language, $0) }
                }
            }
        }
    }

    @Test func testPackIdsMatchPackOrder() {
        let expected = DictionaryStore.packOrder.filter { Self.implementedPackIds.contains($0) }
        #expect(Self.implementedPackIds.allSatisfy { DictionaryStore.packOrder.contains($0) })
        #expect(packs.map(\.id) == expected)
    }

    @Test func testEveryPackFileDecodes() throws {
        // loadPacks молча пропускает битые файлы, поэтому число файлов сверяется отдельно.
        let urls = DictionaryStore.packFileURLs(in: .main)
        #expect(urls.count == packs.count, "Не все файлы наборов читаются")
    }

    @Test func testEveryPackHasBothTitles() {
        for pack in packs {
            for language in DictionaryLanguage.allCases {
                let title = pack.title[language]?.trimmingCharacters(in: .whitespaces) ?? ""
                #expect(!title.isEmpty, "Набор \(pack.id): нет названия \(language.rawValue)")
            }
        }
    }

    @Test func testVariantsAreMatchableTokens() {
        // Индекс режет варианты по пробелам и ищет слова из букв и цифр с внутренними - . /.
        for item in allVariants {
            let words = item.variant.split(whereSeparator: \.isWhitespace)
            #expect(!words.isEmpty, "\(item.pack)/\(item.spelling): пустой вариант")
            #expect(item.variant == item.variant.lowercased(), "\(item.pack)/\(item.spelling): вариант не в нижнем регистре: \(item.variant)")
            for word in words {
                #expect(VariantRules.isMatchableToken(String(word)), "\(item.pack)/\(item.spelling): вариант не сопоставится: \(item.variant)")
            }
            let script = item.language == .ru ? "кириллица" : "латиница"
            let scriptOK = item.language == .ru ? VariantRules.isCyrillic(item.variant) : VariantRules.isLatin(item.variant)
            #expect(scriptOK, "\(item.pack)/\(item.spelling): \(item.variant) не \(script)")
        }
    }

    @Test func testNoVariantIsCommonWordInItsLanguage() {
        for item in allVariants {
            // Multi-word variants exempt per product owner decision 2026-11-17; guarded by testNoDeniedVariants and the no-harm corpus.
            guard item.variant.split(whereSeparator: \.isWhitespace).count == 1 else { continue }
            let common = checker.isCommonWord(item.variant, language: item.language)
            #expect(!common, "\(item.pack)/\(item.spelling): «\(item.variant)» словарное слово \(item.language.rawValue)")
        }
    }

    @Test func testNoVariantMapsToTwoSpellings() {
        var owners: [String: String] = [:]
        for item in allVariants {
            let key = "\(item.language.rawValue)|\(item.variant.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " "))"
            if let owner = owners[key], owner != item.spelling {
                Issue.record("«\(item.variant)» (\(item.language.rawValue)) ведёт и в \(owner), и в \(item.spelling)")
            }
            owners[key] = item.spelling
        }
    }

    @Test func testNoSpellingIsDuplicated() {
        var seen = Set<String>()
        for pack in packs {
            for entry in pack.entries {
                #expect(seen.insert(entry.spelling.lowercased()).inserted, "Написание повторяется: \(entry.spelling)")
            }
        }
    }

    @Test func testNoVariantEqualsAnotherSpelling() {
        var spellings = Set<String>()
        for pack in packs { for entry in pack.entries { spellings.insert(entry.spelling.lowercased()) } }
        for item in allVariants where item.variant.lowercased() != item.spelling.lowercased() {
            #expect(!spellings.contains(item.variant.lowercased()), "\(item.pack)/\(item.spelling): вариант «\(item.variant)» совпадает с написанием другой записи")
        }
    }

    @Test func testNoLoanwordsFromBlocklist() {
        for pack in packs {
            for entry in pack.entries {
                #expect(!Self.loanwordBlocklist.contains(entry.spelling.lowercased()), "Англицизм в написаниях: \(entry.spelling)")
            }
        }
        for item in allVariants {
            #expect(!Self.loanwordBlocklist.contains(item.variant.lowercased()), "Англицизм в вариантах: \(item.variant)")
        }
    }

    /// Те же правила, что в scripts/annotate-dictionaries.swift: кириллица только для ru, латиница только для en,
    /// написания с цифрами и символами словарными не бывают.
    static func candidateLanguages(for spelling: String) -> [DictionaryLanguage] {
        let letters = spelling.filter { !$0.isWhitespace }
        guard !letters.isEmpty, letters.allSatisfy(\.isLetter) else { return [] }
        if letters.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) } }) { return [.ru] }
        if letters.allSatisfy(\.isASCII) { return [.en] }
        return []
    }

    static let deniedVariants = VariantRules.denied

    @Test func testNoDeniedVariants() {
        for item in allVariants {
            #expect(!Self.deniedVariants.contains(item.variant.lowercased()), "\(item.pack)/\(item.spelling): запрещённый вариант «\(item.variant)»")
        }
    }

    /// Обычные русские слова, которые нельзя ставить последним словом варианта для написания из одного слова:
    /// замена проглотила бы слово, например «смарт цели» вместо «SMART цели». Явный список выбран вместо проверки
    /// по словарю: словарь помечает и законные части произношения вроде «дроп бокс» или «эс».
    static let ordinaryTrailingWords: Set<String> = [
        "цели", "менеджмент", "приоритизация", "план", "лицензии", "юзеры", "диаграмма", "ноутбук", "браузер",
        "мессенджер", "рекрутинг", "презентации", "оптимизация", "платежи", "трансфер", "реклама", "тест",
        "квалификация", "музыка", "диск", "лицензия", "методология", "фреймворк", "матрица",
    ]

    @Test func testNoMultiWordRuVariantEndsWithOrdinaryWord() {
        for pack in packs {
            for entry in pack.entries where entry.spelling.split(whereSeparator: \.isWhitespace).count == 1 {
                for variant in entry.variants[.ru] ?? [] {
                    let words = variant.split(whereSeparator: \.isWhitespace)
                    guard words.count > 1, let last = words.last else { continue }
                    #expect(!Self.ordinaryTrailingWords.contains(String(last)), "\(pack.id)/\(entry.spelling): «\(variant)» оканчивается обычным словом «\(last)»")
                }
            }
        }
    }

    /// Минимальные размеры наборов: не меньше 80 процентов от плана спеки.
    static let minimumPackSizes: [String: Int] = [
        "it": 100, "ai": 48, "apps": 64, "management": 40, "business": 48,
        "hr": 32, "finance": 48, "marketing": 48, "legal": 32, "design": 32,
    ]

    @Test func testPacksMeetMinimumSize() {
        for (id, minimum) in Self.minimumPackSizes {
            let count = packs.first { $0.id == id }?.entries.count ?? 0
            #expect(count >= minimum, "В наборе \(id) \(count) записей, нужно не меньше \(minimum)")
        }
    }

    @Test func testCommonInIsUpToDate() {
        for pack in packs {
            for entry in pack.entries {
                let expected = Self.candidateLanguages(for: entry.spelling).filter { checker.isCommonWord(entry.spelling, language: $0) }
                #expect(Set(entry.commonIn) == Set(expected), "\(pack.id)/\(entry.spelling): commonIn устарел, \(Self.annotateHint)")
            }
        }
    }
}
