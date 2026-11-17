import XCTest
@testable import Tranq

/// Корпуса на реальных наборах: «не навреди» требует неизменного текста, «должно исправить» требует замен.
final class DictionaryCorpusTests: XCTestCase {
    private var index: DictionaryIndex!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tranq-corpus-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "tranq.corpus.\(UUID().uuidString)")!
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

    /// Отсутствующий корпус обязан валить тест, а не пропускать его: иначе защита от порчи речи молча исчезает.
    private func resourceURL(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "DictionaryCorpus") { return url }
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        XCTFail("Нет ресурса \(name).\(ext) в тестовом бандле")
        throw CocoaError(.fileNoSuchFile)
    }

    private func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: resourceURL(name, "txt"), encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private struct Row {
        let input: String
        let expected: String
        /// Строка из блока после маркера `# independent`: написана без оглядки на списки вариантов.
        let independent: Bool
    }

    /// Строки `вход<TAB>ожидаемо`. Пустые строки пропускаются, `# independent` открывает независимый блок.
    /// Любая другая строка, где не ровно две непустые колонки, считается ошибкой корпуса.
    private func pairs(_ name: String) throws -> [Row] {
        let text = try String(contentsOf: resourceURL(name, "tsv"), encoding: .utf8)
        var independent = false
        var rows: [Row] = []
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line == "# independent" { independent = true; continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                XCTFail("\(name).tsv:\(number + 1): строка не из двух непустых колонок: \(line)")
                continue
            }
            rows.append(Row(input: parts[0], expected: parts[1], independent: independent))
        }
        return rows
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
        XCTAssertGreaterThanOrEqual(corpus.filter(\.independent).count, 40, "Независимых строк меньше 40")
        var failures: [String] = []
        var independentFailures = 0
        for row in corpus {
            let result = index.apply(to: row.input, language: language).text
            if result != row.expected {
                failures.append("\(row.independent ? "[independent] " : "")\(row.input)\n   ждали: \(row.expected)\n   вышло: \(result)")
                if row.independent { independentFailures += 1 }
            }
        }
        let rate = Double(corpus.count - failures.count) / Double(max(corpus.count, 1))
        let independentTotal = corpus.filter(\.independent).count
        func percent(_ ok: Int, _ total: Int) -> String { String(format: "%.1f", Double(ok) / Double(max(total, 1)) * 100) }
        report("SHOULD-FIX \(name): \(corpus.count - failures.count)/\(corpus.count) = \(percent(corpus.count - failures.count, corpus.count))%")
        report("SHOULD-FIX independent \(name): \(independentTotal - independentFailures)/\(independentTotal) = \(percent(independentTotal - independentFailures, independentTotal))%")
        for failure in failures.prefix(40) { report("SHOULD-FIX miss: " + failure.replacingOccurrences(of: "\n", with: " | ")) }
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
