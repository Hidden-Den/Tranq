//
//  CleanupLevelResolverTests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

/// Выбор уровня очистки по правилам приложений и сайтов.
struct CleanupLevelResolverTests {
    let gmailSite = DictationRule(id: UUID(), target: .site(domain: "company.ru"), displayName: "Почта", tone: .business, isEnabled: true)
    let chromeApp = DictationRule(id: UUID(), target: .app(bundleId: "com.google.Chrome"), displayName: "Chrome", tone: .casual, isEnabled: true)

    func ctx(_ b: String?, _ h: String?, prompt: Bool = false) -> DictationContext {
        .init(bundleId: b, host: h, promptRequested: prompt)
    }

    @Test func siteBeatsApp() {
        let r = CleanupLevelResolver.resolve(ctx("com.google.Chrome", "mail.company.ru"), rules: [chromeApp, gmailSite], mode: .smart, promptModeEnabled: false)
        #expect(r.level == .rewrite(tone: RuleTone.business.instruction))
        #expect(r.label == "Почта")
    }

    @Test func unknownSiteFallsBackToAppRule() {
        let r = CleanupLevelResolver.resolve(ctx("com.google.Chrome", "chatgpt.com"), rules: [chromeApp, gmailSite], mode: .smart, promptModeEnabled: false)
        #expect(r.ruleName == "Chrome")
    }

    @Test func noRuleGivesClean() {
        let r = CleanupLevelResolver.resolve(ctx("org.telegram.desktop", nil), rules: [], mode: .smart, promptModeEnabled: false)
        #expect(r.level == .clean)
        #expect(r.label == "Чисто")
        #expect(r.ruleName == nil)
    }

    @Test func disabledRuleIgnored() {
        var off = gmailSite
        off.isEnabled = false
        #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [off], mode: .smart, promptModeEnabled: false).level == .clean)
    }

    @Test func promptNeedsSettingAndShift() {
        #expect(CleanupLevelResolver.resolve(ctx(nil, nil, prompt: true), rules: [], mode: .smart, promptModeEnabled: false).level == .clean)
        let r = CleanupLevelResolver.resolve(ctx(nil, nil, prompt: true), rules: [], mode: .direct, promptModeEnabled: true)
        #expect(r.level == .prompt)
        #expect(r.label == "Промпт")
    }

    @Test func directModeIgnoresRules() {
        let r = CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [gmailSite], mode: .direct, promptModeEnabled: true)
        #expect(r.level == .verbatim)
        #expect(r.label == "Дословно")
    }

    @Test func longestDomainWins() {
        let inner = DictationRule(id: UUID(), target: .site(domain: "mail.company.ru"), displayName: "Внутр", tone: .casual, isEnabled: true)
        #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [gmailSite, inner], mode: .smart, promptModeEnabled: false).ruleName == "Внутр")
    }

    @Test func toneInstructionsAreExact() {
        #expect(RuleTone.business.instruction == "деловой: вежливо и по делу, полными предложениями, без разговорных слов")
        #expect(RuleTone.casual.instruction == "живой: коротко и просто, как в переписке с коллегой")
        #expect(RuleTone.custom("  пиши как поэт  ").instruction == "пиши как поэт")
    }

    @Test func domainNormalization() {
        #expect(DomainNormalizer.host(from: "https://WWW.Mail.Company.RU.:8443/inbox") == "mail.company.ru")
        #expect(DomainNormalizer.host(from: "https://mail.company.ru/inbox?x=1") == "mail.company.ru")
        #expect(DomainNormalizer.host(from: "company.ru") == "company.ru")
        #expect(DomainNormalizer.host(from: "*.company.ru") == "company.ru")
        #expect(DomainNormalizer.host(from: ".company.ru") == "company.ru")
        #expect(DomainNormalizer.host(from: "   ") == nil)
        #expect(DomainNormalizer.matches(host: "mail.company.ru", ruleDomain: "company.ru"))
        #expect(!DomainNormalizer.matches(host: "notcompany.ru", ruleDomain: "company.ru"))
    }
}
