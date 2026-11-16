import Testing
import Foundation
@testable import Golosok

extension SharedSettingsSuites {
    @MainActor
    final class DictionaryMigrationTests {
        private let directory: URL
        private let suiteName: String
        private let defaults: UserDefaults

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictionary-migration-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suiteName = "dictionary-migration-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        private var legacyURL: URL { directory.appendingPathComponent("personalization.json") }
        private var migratedURL: URL { directory.appendingPathComponent("personalization.v1.json") }

        private func makeStore() -> DictionaryStore {
            DictionaryStore(
                directory: directory, defaults: defaults, packsBundle: .main,
                checker: SetCommonWordChecker([:]), packs: []
            )
        }

        private func rule(_ pattern: String, _ replacement: String, _ source: String) -> [String: Any] {
            ["id": UUID().uuidString, "pattern": pattern, "replacement": replacement, "count": 3,
             "lastUsed": 0, "source": source]
        }

        private func term(_ term: String, manual: Bool) -> [String: Any] {
            ["term": term, "count": 3, "lastUsed": 0, "isManual": manual]
        }

        private func writeLegacy(rules: [[String: Any]] = [], terms: [[String: Any]] = []) throws {
            let object: [String: Any] = ["isLearningEnabled": true, "rules": rules, "terms": terms]
            try JSONSerialization.data(withJSONObject: object).write(to: legacyURL)
        }

        private func migrate(_ store: DictionaryStore) {
            DictionaryMigration.runIfNeeded(store: store, directory: directory, defaults: defaults)
        }

        @Test func groupsRulesByReplacement() throws {
            try writeLegacy(rules: [rule("кубер", "K8s", "manual"), rule("кубернетис", "K8s", "manual")])
            let store = makeStore()
            migrate(store)

            #expect(store.userEntries.count == 1)
            #expect(store.userEntries[0].spelling == "K8s")
            #expect(store.userEntries[0].variants[.ru] == ["кубер", "кубернетис"])
            #expect(store.userEntries[0].source == .manual)
        }

        @Test func editOnlyGroupIsLearned() throws {
            try writeLegacy(rules: [rule("кубернетис", "Kubernetes", "edit")])
            let store = makeStore()
            migrate(store)

            #expect(store.userEntries.map(\.spelling) == ["Kubernetes"])
            #expect(store.userEntries[0].source == .learned)
        }

        @Test func editRuleFailingFilterIsDropped() throws {
            try writeLegacy(rules: [rule("дом", "квартира", "edit")])
            let store = makeStore()
            migrate(store)
            #expect(store.userEntries.isEmpty)
        }

        @Test func modifiedBuiltinBecomesManual() throws {
            try writeLegacy(rules: [rule("кубер", "K8s", "builtin")])
            let store = makeStore()
            migrate(store)

            #expect(store.userEntries.map(\.spelling) == ["K8s"])
            #expect(store.userEntries[0].variants[.ru] == ["кубер"])
            #expect(store.userEntries[0].source == .manual)
        }

        @Test func unmodifiedBuiltinAndAutoTermsDropped() throws {
            try writeLegacy(
                rules: [rule("кубер", "Kubernetes", "builtin"), rule("докер", "Docker", "builtin"), rule("пусто", "", "manual")],
                terms: [term("Kubernetes", manual: true), term("Redis", manual: true), term("Zabbix", manual: false)]
            )
            let store = makeStore()
            migrate(store)
            #expect(store.userEntries.isEmpty)
        }

        @Test func manualTermsBecomeEntriesWithoutVariants() throws {
            try writeLegacy(terms: [term("Zabbix", manual: true), term("Kubernetes", manual: true)])
            let store = makeStore()
            migrate(store)

            #expect(store.userEntries.map(\.spelling) == ["Zabbix"])
            #expect(store.userEntries[0].source == .manual)
            #expect(store.userEntries[0].variants.isEmpty)
        }

        @Test func legacyTermsMigratedAndKeyRemoved() throws {
            try writeLegacy()
            defaults.set(["Grafana", " Loki ", "grafana"], forKey: DictionaryMigration.legacyTermsKey)
            let store = makeStore()
            migrate(store)

            #expect(store.userEntries.map(\.spelling) == ["Grafana", "Loki"])
            #expect(defaults.object(forKey: DictionaryMigration.legacyTermsKey) == nil)
        }

        @Test func runsOnceAndRenamesFile() throws {
            try writeLegacy(rules: [rule("кубер", "K8s", "manual")])
            let store = makeStore()
            migrate(store)

            #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
            #expect(FileManager.default.fileExists(atPath: migratedURL.path))

            store.removeEntry(id: store.userEntries[0].id)
            try writeLegacy(rules: [rule("кубер", "K8s", "manual")])
            migrate(store)
            #expect(store.userEntries.isEmpty)
        }

        @Test func noLegacyFileAndNoUserTermsDoesNothing() {
            let store = makeStore()
            migrate(store)
            #expect(store.userEntries.isEmpty)
        }

        @Test func legacyTermsMigratedWithoutLegacyFile() {
            defaults.set(["Grafana", "Loki"], forKey: DictionaryMigration.legacyTermsKey)
            let store = makeStore()
            migrate(store)
            #expect(store.userEntries.map(\.spelling) == ["Grafana", "Loki"])
            #expect(store.userEntries.allSatisfy { $0.source == .manual && $0.variants.isEmpty })
            #expect(defaults.object(forKey: DictionaryMigration.legacyTermsKey) == nil)
        }

        @Test func rerunAfterPartialRunCreatesNoDuplicates() throws {
            try writeLegacy(rules: [rule("кубер", "K8s", "manual"), rule("кубернетис", "K8s", "manual")],
                            terms: [term("Zabbix", manual: true)])
            let store = makeStore()
            store.addEntry(spelling: "K8s", variants: [.ru: ["кубер"]], source: .manual)
            store.addEntry(spelling: "Zabbix", variants: [:], source: .manual)
            migrate(store)
            migrate(store)

            #expect(store.userEntries.map(\.spelling) == ["K8s", "Zabbix"])
            #expect(store.userEntries[0].variants[.ru] == ["кубер", "кубернетис"])
            #expect(FileManager.default.fileExists(atPath: migratedURL.path))
        }

        @Test func migratedEntriesArePersisted() throws {
            try writeLegacy(rules: [rule("кубер", "K8s", "manual")])
            migrate(makeStore())
            #expect(makeStore().userEntries.map(\.spelling) == ["K8s"])
        }
    }
}
