import XCTest
@testable import Golosok

final class PersonalizationEngineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PersonalizationEngine.shared.resetMemory()
        PersonalizationEngine.shared.isLearningEnabled = true
    }

    override func tearDown() {
        PersonalizationEngine.shared.resetMemory()
        super.tearDown()
    }

    func testExtractCandidateTerms() {
        let text = "Развернули наш сервис Golosok, настроили API и Kubernetes с базой PostgreSQL для МФЦ."
        let candidates = PersonalizationEngine.extractCandidateTerms(from: text)

        XCTAssertTrue(candidates.contains("Golosok"))
        XCTAssertTrue(candidates.contains("API"))
        XCTAssertTrue(candidates.contains("Kubernetes"))
        XCTAssertTrue(candidates.contains("PostgreSQL"))
        XCTAssertTrue(candidates.contains("МФЦ"))
    }

    func testExtractDiffPairsSingleReplacement() {
        let original = "Мы развернули кубернетис на сервере"
        let edited = "Мы развернули Kubernetes на сервере"

        let diffs = PersonalizationEngine.extractDiffPairs(original: original, edited: edited)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.pattern, "кубернетис")
        XCTAssertEqual(diffs.first?.replacement, "Kubernetes")
    }

    func testExtractDiffPairsPhraseReplacement() {
        let original = "Давай созвон в зуме завтра в полдень"
        let edited = "Давай созвон в Zoom завтра в полдень"

        let diffs = PersonalizationEngine.extractDiffPairs(original: original, edited: edited)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.pattern, "зуме")
        XCTAssertEqual(diffs.first?.replacement, "Zoom")
    }

    func testExtractDiffPairsFillerDeletion() {
        let original = "Я в общем-то согласен с этим решением"
        let edited = "Я согласен с этим решением"

        let diffs = PersonalizationEngine.extractDiffPairs(original: original, edited: edited)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs.first?.pattern, "в общем-то")
        XCTAssertEqual(diffs.first?.replacement, "")
    }

    func testLearnFromEditRegistersRuleAndTerm() {
        let engine = PersonalizationEngine.shared
        let original = "Сервис развернут в кубере"
        let edited = "Сервис развернут в Kubernetes"

        engine.learnFromEdit(original: original, edited: edited)

        // Ждем асинхронную обработку в очереди
        let expectation = XCTestExpectation(description: "Rule learned")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(engine.correctionRules.contains { $0.pattern == "кубере" && $0.replacement == "Kubernetes" })
            XCTAssertTrue(engine.learnedTerms.contains { $0.term == "Kubernetes" })
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testBuildPromptContextRetrievesMatchingRulesAndTermsSubMillisecond() {
        let engine = PersonalizationEngine.shared
        engine.learnFromEdit(original: "надо поднять кубер", edited: "надо поднять Kubernetes")

        let expectation = XCTestExpectation(description: "Wait for learning")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let start = CFAbsoluteTimeGetCurrent()
            let context = engine.buildPromptContext(for: "Завтра развернем наш кубер на продакшене")
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 // ms

            XCTAssertLessThan(elapsed, 5.0, "Генерация контекста должна занимать доли миллисекунды")
            XCTAssertTrue(context.contains("Kubernetes"))
            XCTAssertTrue(context.contains("кубер"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testAllApprovedTermsIncludesLearnedWordsForGroundingValidator() {
        let engine = PersonalizationEngine.shared
        engine.learnFromEdit(original: "отправь в зум", edited: "отправь в Zoom")

        let expectation = XCTestExpectation(description: "Wait for learning")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let terms = engine.allApprovedTerms(additionalTerms: ["Golosok"])
            XCTAssertTrue(terms.contains("Zoom"))
            XCTAssertTrue(terms.contains("Golosok"))

            // Проверка, что GroundingValidator пропускает такой термин
            let validation = GroundingValidator.validate(
                input: "отправь в зум",
                output: "Отправь в Zoom",
                style: .clean,
                customTerms: terms
            )
            XCTAssertEqual(validation, .valid(sanitizedText: "Отправь в Zoom"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testAddManualTermAndRule() {
        let engine = PersonalizationEngine.shared
        engine.addManualTerm("FastAPI")
        engine.addManualRule(pattern: "фастапи", replacement: "FastAPI")

        XCTAssertTrue(engine.learnedTerms.contains(where: { $0.term == "FastAPI" && $0.isManual }))
        XCTAssertTrue(engine.correctionRules.contains(where: { $0.pattern == "фастапи" && $0.replacement == "FastAPI" }))

        let approved = engine.allApprovedTerms()
        XCTAssertTrue(approved.contains("FastAPI"))

        engine.removeTerm("FastAPI")
        XCTAssertFalse(engine.learnedTerms.contains(where: { $0.term == "FastAPI" }))
    }

    func testResetMemoryClearsEverything() {
        let engine = PersonalizationEngine.shared
        engine.learnFromEdit(original: "тест 1", edited: "тест 2")

        let expectation = XCTestExpectation(description: "Wait and clear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(engine.correctionRules.isEmpty)
            engine.resetMemory()
            XCTAssertTrue(engine.correctionRules.isEmpty)
            XCTAssertTrue(engine.learnedTerms.isEmpty)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testApplyRulesDeterministicSubstitutions() {
        let engine = PersonalizationEngine.shared
        engine.resetMemory(restoreBuiltins: true)

        let input = "Нужно поднять кубернейтс и настроить no8m для интеграции."
        let output = engine.applyRules(to: input)

        XCTAssertTrue(output.contains("Kubernetes"))
        XCTAssertTrue(output.contains("n8n"))
        XCTAssertFalse(output.contains("кубернейтс"))
        XCTAssertFalse(output.contains("no8m"))
    }

    func testCapitalizedRussianSentenceWordsNotLearnedAsTerms() {
        let engine = PersonalizationEngine.shared
        engine.resetMemory()

        let original = "нужно сделать это"
        let edited = "Нужно сделать это"
        engine.learnFromEdit(original: original, edited: edited)

        let expectation = XCTestExpectation(description: "Wait learning")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(engine.learnedTerms.contains(where: { $0.term == "Нужно" }))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
