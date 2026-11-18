import Testing
import Foundation
@testable import Tranq

/// Промпты уровней и сброс прежнего текста по умолчанию.
struct CleanupPromptTests {
    @Test func promptsCarryTermsRule() {
        for level in [CleanupLevel.clean, .rewrite(tone: "деловой"), .prompt] {
            #expect(ThoughtSynthesizer.getSystemPrompt(for: level).contains(ThoughtSynthesizer.termsRule))
        }
    }

    @Test func cleanPromptMentionsRepeatedThoughts() {
        #expect(ThoughtSynthesizer.getSystemPrompt(for: .clean).contains("самую полную"))
    }

    @Test func rewritePromptCarriesToneInsteadOfKeepingWords() {
        let prompt = ThoughtSynthesizer.getSystemPrompt(for: .rewrite(tone: "деловой"))
        #expect(prompt.contains("Перепиши в тоне: деловой"))
        #expect(!prompt.contains("не меняй тон"))
    }

    @Test func matStaysOutsideBusinessTone() {
        for level in [CleanupLevel.clean, .prompt, .rewrite(tone: RuleTone.casual.instruction)] {
            let prompt = ThoughtSynthesizer.getSystemPrompt(for: level)
            #expect(prompt.contains(ThoughtSynthesizer.profanityRule) || prompt.contains(RuleTone.keepProfanity))
            #expect(!prompt.contains(RuleTone.dropProfanity))
        }
    }

    @Test func businessToneDropsMat() {
        let prompt = ThoughtSynthesizer.getSystemPrompt(for: .rewrite(tone: RuleTone.business.instruction))
        #expect(prompt.contains(RuleTone.dropProfanity))
        #expect(!prompt.contains(ThoughtSynthesizer.profanityRule))
    }

    @Test func toneWithoutMatRuleKeepsMat() {
        let prompt = ThoughtSynthesizer.getSystemPrompt(for: .rewrite(tone: "деловой"))
        #expect(prompt.contains(ThoughtSynthesizer.profanityRule))
    }

    /// Отдельный набор настроек: тесты идут параллельно, общий набор делили бы с `resetToDefaults`.
    private func isolatedDefaults() -> UserDefaults {
        let name = "tranq.tests.prompt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func legacyDefaultPromptIsMigrated() {
        let defaults = isolatedDefaults()
        for legacy in VoiceIntelligenceSettings.legacyDefaultPrompts {
            defaults.set(legacy, forKey: "voice.customSystemPrompt")
            VoiceIntelligenceSettings.migrateLegacyPrompt(defaults)
            #expect(defaults.string(forKey: "voice.customSystemPrompt") == nil)
        }
        #expect(VoiceIntelligenceSettings.legacyDefaultPrompts.count == 3)
    }

    @Test func userEditedPromptSurvivesMigration() {
        let defaults = isolatedDefaults()
        defaults.set("мой промпт", forKey: "voice.customSystemPrompt")
        VoiceIntelligenceSettings.migrateLegacyPrompt(defaults)
        #expect(defaults.string(forKey: "voice.customSystemPrompt") == "мой промпт")
    }
}
