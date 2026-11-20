//
//  CleanupLevelResolverTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Выбор уровня очистки по правилам приложений и сайтов.
struct CleanupLevelResolverTests {
    let gmailSite = DictationRule(id: UUID(), target: .site(domain: "company.ru"), displayName: "Почта", tone: .business, isEnabled: true)
    let chromeApp = DictationRule(id: UUID(), target: .app(bundleId: "com.google.Chrome"), displayName: "Chrome", tone: .casual, isEnabled: true)

    func ctx(_ b: String?, _ h: String?) -> DictationContext {
        .init(bundleId: b, host: h)
    }

    @Test func siteBeatsApp() {
        let r = CleanupLevelResolver.resolve(ctx("com.google.Chrome", "mail.company.ru"), rules: [chromeApp, gmailSite])
        #expect(r.level == .rewrite(tone: RuleTone.business.instruction))
        #expect(r.label == "Почта")
    }

    @Test func unknownSiteFallsBackToAppRule() {
        let r = CleanupLevelResolver.resolve(ctx("com.google.Chrome", "chatgpt.com"), rules: [chromeApp, gmailSite])
        #expect(r.ruleName == "Chrome")
    }

    @Test func noRuleGivesClean() {
        let r = CleanupLevelResolver.resolve(ctx("org.telegram.desktop", nil), rules: [])
        #expect(r.level == .clean)
        #expect(r.label == String(localized: "Чисто"))
        #expect(r.ruleName == nil)
    }

    @Test func disabledRuleIgnored() {
        var off = gmailSite
        off.isEnabled = false
        #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [off]).level == .clean)
    }

    @Test func resolveTakesContextAndRulesOnly() {
        let context = DictationContext(bundleId: nil, host: nil)
        #expect(CleanupLevelResolver.resolve(context, rules: []).level == .clean)
    }

    @Test func resolveWithoutRulesIsClean() {
        let r = CleanupLevelResolver.resolve(ctx("ru.keepcoder.Telegram", nil), rules: [])
        #expect(r.level == .clean)
    }

    /// Режим `direct`, сохранённый прежней версией, больше ни на что не влияет.
    @Test func legacyDirectModeIsIgnored() {
        let defaults = AppEnvironment.defaults
        defaults.set("direct", forKey: "voice.mode")
        defer { defaults.removeObject(forKey: "voice.mode") }
        let r = CleanupLevelResolver.resolve(ctx(nil, nil), rules: [])
        #expect(r.level == .clean)
        let ruled = CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [gmailSite])
        #expect(ruled.level == .rewrite(tone: RuleTone.business.instruction))
    }

    @Test func longestDomainWins() {
        let inner = DictationRule(id: UUID(), target: .site(domain: "mail.company.ru"), displayName: "Внутр", tone: .casual, isEnabled: true)
        #expect(CleanupLevelResolver.resolve(ctx(nil, "mail.company.ru"), rules: [gmailSite, inner]).ruleName == "Внутр")
    }

    @Test func toneInstructionsAreExact() {
        #expect(RuleTone.business.instruction == "деловой: вежливо и по делу, полными предложениями, без разговорных слов; резкость и недовольство передай твёрдыми деловыми словами, а не убирай; иронию передай по смыслу, а не дословно; не добавляй просьб и пожеланий, которых не было; \(RuleTone.dropProfanity)")
        #expect(RuleTone.casual.instruction == "живой: коротко и просто, как в переписке с коллегой; \(RuleTone.keepProfanity)")
        #expect(RuleTone.custom("  пиши как поэт  ").instruction == "пиши как поэт; \(RuleTone.keepProfanity)")
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
