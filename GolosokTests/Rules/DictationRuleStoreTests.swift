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

    @Test func garbageJSONGivesEmptyList() {
        let defaults = makeDefaults()
        defaults.set(Data("не json".utf8), forKey: "dictation.rules")
        let store = DictationRuleStore(defaults: defaults)
        #expect(store.rules.isEmpty)
    }
}
