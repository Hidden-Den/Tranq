//
//  DictationRuleStoreTests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

/// Хранение правил приложений и сайтов.
struct DictationRuleStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "golosok-rule-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func rule(_ name: String, domain: String) -> DictationRule {
        DictationRule(id: UUID(), target: .site(domain: domain), displayName: name, tone: .business, isEnabled: true)
    }

    @Test func rulesSurviveReload() {
        let defaults = makeDefaults()
        let first = DictationRuleStore(defaults: defaults)
        let added = rule("Почта", domain: "company.ru")
        first.add(added)

        let second = DictationRuleStore(defaults: defaults)
        #expect(second.rules == [added])
    }

    @Test func updateAndRemove() {
        let store = DictationRuleStore(defaults: makeDefaults())
        var item = rule("Почта", domain: "company.ru")
        store.add(item)
        item.isEnabled = false
        store.update(item)
        #expect(store.rules.first?.isEnabled == false)
        store.remove(id: item.id)
        #expect(store.rules.isEmpty)
    }

    private func encoded(_ rule: DictationRule) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))
    }

    @Test func oneBrokenRuleKeepsTheOthers() throws {
        let defaults = makeDefaults()
        let first = rule("Почта", domain: "company.ru")
        let second = rule("Чат", domain: "chat.ru")
        let raw = try JSONSerialization.data(withJSONObject: [try encoded(first), ["bogus": 1], try encoded(second)])
        defaults.set(raw, forKey: "dictation.rules")

        let store = DictationRuleStore(defaults: defaults)
        #expect(store.rules == [first, second])
        #expect(defaults.data(forKey: "dictation.rules.backup") == raw)
    }

    @Test func unknownToneOrTargetFromNewerVersionIsKeptInBackup() throws {
        let defaults = makeDefaults()
        let kept = rule("Почта", domain: "company.ru")
        var future = try encoded(rule("Будущее", domain: "future.ru")) as! [String: Any]
        future["tone"] = ["formalLetter": [String: String]()]
        let raw = try JSONSerialization.data(withJSONObject: [try encoded(kept), future])
        defaults.set(raw, forKey: "dictation.rules")

        let store = DictationRuleStore(defaults: defaults)
        #expect(store.rules == [kept])
        store.add(rule("Новое", domain: "new.ru"))
        #expect(defaults.data(forKey: "dictation.rules.backup") == raw)
    }

    @Test func unreadableDataIsBackedUpBeforeAnySave() {
        let defaults = makeDefaults()
        let garbage = Data("не json".utf8)
        defaults.set(garbage, forKey: "dictation.rules")

        let store = DictationRuleStore(defaults: defaults)
        #expect(store.rules.isEmpty)
        store.add(rule("Почта", domain: "company.ru"))
        #expect(defaults.data(forKey: "dictation.rules") != garbage)
        #expect(defaults.data(forKey: "dictation.rules.backup") == garbage)
    }

    @Test func cleanDataWritesNoBackup() {
        let defaults = makeDefaults()
        let first = DictationRuleStore(defaults: defaults)
        first.add(rule("Почта", domain: "company.ru"))
        _ = DictationRuleStore(defaults: defaults)
        #expect(defaults.data(forKey: "dictation.rules.backup") == nil)
    }

    @Test func garbageJSONGivesEmptyList() {
        let defaults = makeDefaults()
        defaults.set(Data("не json".utf8), forKey: "dictation.rules")
        let store = DictationRuleStore(defaults: defaults)
        #expect(store.rules.isEmpty)
    }
}
