//
//  RuleEditorLogicTests.swift
//  GolosokTests
//

import Testing
import Foundation
import Carbon
@testable import Golosok

/// Проверка и сборка правила из черновика, подсказка про сочетание для промпта.
struct RuleEditorLogicTests {

    private func siteDraft(_ input: String, tone: RuleTone = .business, customText: String = "") -> RuleDraft {
        RuleDraft(kind: .site, bundleId: nil, appName: nil, domainInput: input, tone: tone, customText: customText)
    }

    @Test func siteDraftNormalizesPastedURL() throws {
        let rule = try RuleEditorLogic.makeRule(from: siteDraft("https://mail.company.ru/inbox?x=1"), existing: []).get()
        #expect(rule.target == .site(domain: "mail.company.ru"))
        #expect(rule.displayName == "mail.company.ru")
        #expect(rule.tone == .business)
        #expect(rule.isEnabled)
    }

    @Test func appDraftUsesAppName() throws {
        let draft = RuleDraft(kind: .app, bundleId: "com.microsoft.Outlook", appName: "Outlook", domainInput: "", tone: .casual, customText: "")
        let rule = try RuleEditorLogic.makeRule(from: draft, existing: []).get()
        #expect(rule.target == .app(bundleId: "com.microsoft.Outlook"))
        #expect(rule.displayName == "Outlook")
    }

    @Test func customToneTakesTextFromField() throws {
        let rule = try RuleEditorLogic.makeRule(from: siteDraft("x.ru", tone: .custom(""), customText: "  пиши как поэт  "), existing: []).get()
        #expect(rule.tone == .custom("пиши как поэт"))
    }

    @Test func editorErrors() {
        #expect(RuleEditorLogic.makeRule(from: siteDraft(""), existing: []) == .failure(.invalidDomain))
        #expect(RuleEditorLogic.makeRule(from: siteDraft("x.ru", tone: .custom("  ")), existing: []) == .failure(.emptyCustomTone))
        let app = RuleDraft(kind: .app, bundleId: nil, appName: nil, domainInput: "", tone: .casual, customText: "")
        #expect(RuleEditorLogic.makeRule(from: app, existing: []) == .failure(.emptyTarget))
    }

    @Test func duplicateTargetRejected() throws {
        let first = try RuleEditorLogic.makeRule(from: siteDraft("x.ru"), existing: []).get()
        #expect(RuleEditorLogic.makeRule(from: siteDraft("https://www.X.ru/path"), existing: [first]) == .failure(.duplicate))
    }

    @Test func runningAppsAreRegularUniqueAndSorted() {
        let apps = RuleEditorLogic.runningApps()
        let ids = apps.map(\.bundleId)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(Bundle.main.bundleIdentifier ?? "-"))
        let names = apps.map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func promptHintForEachTrigger() {
        #expect(PromptModeHint.make(for: .fnKey) == .available("⇧ + Fn"))
        #expect(PromptModeHint.make(for: .optionSpace) == .available("⌥⇧ + Space"))
        #expect(PromptModeHint.make(for: .singleModifier(.leftShift)) == .unavailableShift)
        #expect(PromptModeHint.make(for: .combination(keyCode: 49, modifiers: UInt32(optionKey | shiftKey))) == .unavailableShift)
        #expect(PromptModeHint.make(for: .none) == .noHotKey)
    }
}
