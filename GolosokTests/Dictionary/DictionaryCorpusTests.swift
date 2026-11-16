import XCTest
@testable import Golosok

/// Корпуса на реальных наборах: «не навреди» требует неизменного текста, «должно исправить» требует замен.
final class DictionaryCorpusTests: XCTestCase {
    private var index: DictionaryIndex!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("golosok-corpus-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "golosok.corpus.\(UUID().uuidString)")!
        let store = DictionaryStore(
            directory: directory, defaults: defaults, packsBundle: Bundle.main, checker: SpellCommonWordChecker.shared
        )
        store.waitForIndex()
        index = try XCTUnwrap(store.index)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Resources

    private func resourceURL(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "DictionaryCorpus") { return url }
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        throw XCTSkip("Нет ресурса \(name).\(ext)")
    }

    private func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: resourceURL(name, "txt"), encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func pairs(_ name: String) throws -> [(input: String, expected: String)] {
        let text = try String(contentsOf: resourceURL(name, "tsv"), encoding: .utf8)
        return text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Печатает итог и дублирует его именем действия, чтобы строка попала в отчёт xcresult.
    private func report(_ line: String) {
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }

    // MARK: - No harm

    private func assertNoHarm(_ name: String, _ language: DictionaryLanguage, minimum: Int) throws {
        let corpus = try lines(name)
        XCTAssertGreaterThanOrEqual(corpus.count, minimum, "Корпус слишком мал")
        var violations: [String] = []
        for line in corpus {
            let result = index.apply(to: line, language: language).text
            if result != line { violations.append("\(line)\n   -> \(result)") }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Изменено строк: \(violations.count) из \(corpus.count). Первые 20:\n" + violations.prefix(20).joined(separator: "\n")
        )
    }

    func testNoHarmRussianCorpusUnchanged() throws {
        try assertNoHarm("no_harm_ru", .ru, minimum: 2000)
    }

    func testNoHarmEnglishCorpusUnchanged() throws {
        try assertNoHarm("no_harm_en", .en, minimum: 2000)
    }

    // MARK: - Should fix

    private func assertShouldFix(_ name: String, _ language: DictionaryLanguage) throws {
        let corpus = try pairs(name)
        XCTAssertGreaterThanOrEqual(corpus.count, 150, "Корпус слишком мал")
        var failures: [String] = []
        for pair in corpus {
            let result = index.apply(to: pair.input, language: language).text
            if result != pair.expected { failures.append("\(pair.input)\n   ждали: \(pair.expected)\n   вышло: \(result)") }
        }
        let rate = Double(corpus.count - failures.count) / Double(max(corpus.count, 1))
        report("SHOULD-FIX \(name): \(corpus.count - failures.count)/\(corpus.count) = \(String(format: "%.1f", rate * 100))%")
        for failure in failures.prefix(20) { report("SHOULD-FIX miss: " + failure.replacingOccurrences(of: "\n", with: " | ")) }
        XCTAssertGreaterThanOrEqual(
            rate, 0.95,
            "Исправлено \(String(format: "%.1f", rate * 100))%. Первые 20 провалов:\n" + failures.prefix(20).joined(separator: "\n")
        )
    }

    func testShouldFixRussianAtLeast95Percent() throws {
        try assertShouldFix("should_fix_ru", .ru)
    }

    func testShouldFixEnglishAtLeast95Percent() throws {
        try assertShouldFix("should_fix_en", .en)
    }

    /// Не проверка: печатает долю строк, где нечёткий режим нашёл бы нужное написание, для решения о боевом режиме.
    /// Точная замена забирает все слова из корпуса, поэтому в каждой строке однословный вариант длиной от шести букв
    /// портится потерей одной буквы посередине, как при неточном распознавании, и проверяется `fuzzyHits`.
    func testFuzzyShadowReportOnShouldFix() throws {
        for (name, language) in [("should_fix_ru", DictionaryLanguage.ru), ("should_fix_en", .en)] {
            var tried = 0
            var found = 0
            for pair in try pairs(name) {
                guard let replacement = index.apply(to: pair.input, language: language).replacements
                    .first(where: { $0.reason == .variant && !$0.original.contains(" ") && $0.original.count >= 6 }) else { continue }
                var letters = Array(replacement.original)
                letters.remove(at: letters.count / 2)
                let garbled = pair.input.replacingOccurrences(of: replacement.original, with: String(letters))
                tried += 1
                if index.fuzzyHits(in: garbled, language: language).contains(where: { $0.spelling == replacement.replacement }) { found += 1 }
            }
            let percent = tried == 0 ? 0 : Double(found) / Double(tried) * 100
            report("FUZZY-SHADOW \(name): искажённых вариантов \(tried), найдено \(found) = \(String(format: "%.1f", percent))%")
        }
    }

    /// Не проверка: доля строк «не навреди», где нечёткий режим предложил бы замену, то есть ложные срабатывания.
    func testFuzzyShadowReportOnNoHarm() throws {
        for (name, language) in [("no_harm_ru", DictionaryLanguage.ru), ("no_harm_en", .en)] {
            let corpus = try lines(name)
            let hit = corpus.filter { !index.fuzzyHits(in: $0, language: language).isEmpty }.count
            report("FUZZY-SHADOW \(name): ложных строк \(hit)/\(corpus.count)")
        }
    }
}
