import XCTest
@testable import Golosok

/// Держит первую проверку слова, пока тест не откроет шлюз: индекс остаётся несобранным.
private final class GatedChecker: CommonWordChecking {
    let gate = DispatchSemaphore(value: 0)

    func isCommonWord(_ word: String, language: DictionaryLanguage) -> Bool {
        gate.wait()
        gate.signal()
        return false
    }
}

final class DictionaryStageTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let pack = DictionaryPack(
        id: "it",
        title: [.ru: "IT", .en: "IT"],
        version: 1,
        entries: [
            PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]]),
        ]
    )

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-stage-tests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "dictionary-stage-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(checker: CommonWordChecking = SetCommonWordChecker([:])) -> DictionaryStore {
        DictionaryStore(
            directory: directory, defaults: defaults, packsBundle: .main,
            checker: checker, packs: [pack], saveDelay: 60
        )
    }

    func testStageAppliesAndRecordsReplacementsForNote() {
        let store = makeStore()
        let grafana = store.addEntry(spelling: "Grafana", variants: [.ru: ["графана"]], source: .manual)
        store.waitForIndex()
        let noteId = UUID()

        let result = DictionaryStage.apply("подними кубер и графана, потом кубер", noteId: noteId, language: .ru, store: store)

        XCTAssertEqual(result.text, "подними Kubernetes и Grafana, потом Kubernetes")
        XCTAssertEqual(result.fired, ["Kubernetes", "Grafana"])
        XCTAssertEqual(store.replacements(for: noteId).map(\.replacement), ["Kubernetes", "Grafana"])
        XCTAssertTrue(store.replacements(for: UUID()).isEmpty)
        let updated = store.userEntries.first { $0.id == grafana.id }
        XCTAssertEqual(updated?.hits, 1)
        XCTAssertNotNil(updated?.lastUsed)
    }

    func testStageReturnsOriginalTextWhenIndexNotReady() {
        let checker = GatedChecker()
        let store = makeStore(checker: checker)
        defer {
            checker.gate.signal()
            store.waitForIndex()
        }
        XCTAssertNil(store.index)
        let noteId = UUID()

        let result = DictionaryStage.apply("подними кубер", noteId: noteId, language: .ru, store: store)

        XCTAssertEqual(result.text, "подними кубер")
        XCTAssertTrue(result.fired.isEmpty)
        XCTAssertTrue(store.replacements(for: noteId).isEmpty)
    }

    func testShadowFuzzyNeverChangesText() {
        let store = makeStore()
        let kubernetes = store.addEntry(spelling: "Kubernetes", variants: [:], source: .manual)
        store.waitForIndex()
        let text = "развернули кубернетас"

        let hits = DictionaryStage.shadowHits(text, language: .ru, store: store)
        XCTAssertEqual(hits.map(\.spelling), ["Kubernetes"])

        DictionaryStage.shadowFuzzy(text, language: .ru, store: store)
        let noteId = UUID()
        let applied = DictionaryStage.apply(text, noteId: noteId, language: .ru, store: store)

        XCTAssertEqual(applied.text, text)
        XCTAssertTrue(applied.fired.isEmpty)
        XCTAssertTrue(store.replacements(for: noteId).isEmpty)
        XCTAssertEqual(store.userEntries.first { $0.id == kubernetes.id }?.hits, 0)
    }
}
