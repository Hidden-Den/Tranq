import Testing
import Foundation
@testable import Golosok

/// Проверки всех наборов из `Dictionaries` в бандле. Нарушения исправляются в данных, а не в тестах.
struct PackValidationTests {
    /// Наборы, файлы которых уже есть. Новый набор добавляется сюда вместе с файлом.
    static let implementedPackIds = ["it"]

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
                let chars = Array(word)
                let valid = chars.allSatisfy { $0.isLetter || $0.isNumber || "-./".contains($0) }
                    && (chars.first.map { $0.isLetter || $0.isNumber } ?? false)
                    && (chars.last.map { $0.isLetter || $0.isNumber } ?? false)
                #expect(valid, "\(item.pack)/\(item.spelling): вариант не сопоставится: \(item.variant)")
            }
            let script = item.language == .ru ? "кириллица" : "латиница"
            let letters = item.variant.filter(\.isLetter)
            let isCyrillic = letters.allSatisfy { $0.unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) } }
            let isLatin = letters.allSatisfy { $0.isASCII }
            #expect(item.language == .ru ? isCyrillic : isLatin, "\(item.pack)/\(item.spelling): \(item.variant) не \(script)")
        }
    }

    @Test func testNoVariantIsCommonWordInItsLanguage() {
        for item in allVariants {
            // Многословный вариант проверяется по словам: хватает одного словарного слова, чтобы он был опасен только целиком,
            // поэтому проверяется вся фраза, а для одного слова это то же самое.
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

    @Test func testCommonInIsUpToDate() {
        for pack in packs {
            for entry in pack.entries {
                let expected = DictionaryLanguage.allCases.filter { checker.isCommonWord(entry.spelling, language: $0) }
                #expect(Set(entry.commonIn) == Set(expected), "\(pack.id)/\(entry.spelling): commonIn устарел, \(Self.annotateHint)")
            }
        }
    }
}
