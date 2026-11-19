import Testing
import Foundation
@testable import Tranq

/// Пометка на экране записи, когда вместо ответа модели вставлен текст без ИИ.
struct FallbackNoticeTests {
    @Test func corporateUnavailableMessage() {
        #expect(FallbackNotice.message(for: .providerUnavailable, providerID: "corporate", engine: .external)
                == String(localized: "Шлюз недоступен"))
    }

    @Test func otherMessages() {
        #expect(FallbackNotice.message(for: .providerUnavailable, providerID: "openai", engine: .external)
                == String(localized: "ИИ недоступен"))
        #expect(FallbackNotice.message(for: .timeout, providerID: "openai", engine: .external)
                == String(localized: "ИИ не ответил"))
        #expect(FallbackNotice.message(for: .notConfigured, providerID: "openai", engine: .external)
                == String(localized: "ИИ не настроен"))
    }

    @Test func providerErrorsAreNotReportedAsUnavailable() {
        #expect(FallbackNotice.message(for: .providerError(401), providerID: "corporate", engine: .external)
                == String(localized: "Ошибка шлюза"))
        #expect(FallbackNotice.message(for: .providerError(500), providerID: "openai", engine: .external)
                == String(localized: "Ошибка ИИ"))
    }

    @Test func silentReasonsShowNothing() {
        for reason: FallbackReason? in [nil, .shortPhrase, .hardware, .emptyResponse, .rejected("x")] {
            #expect(FallbackNotice.message(for: reason, providerID: "corporate", engine: .external) == nil)
        }
    }

    @Test func gatewayNameIsNotShownForLocalEngine() {
        #expect(FallbackNotice.message(for: .providerUnavailable, providerID: "corporate", engine: .airGapped)
                == String(localized: "ИИ недоступен"))
    }

    @Test func unresolvableHostFailsFast() async {
        let gateway = AIProviderConfig(baseURL: "https://tranq-no-such-host.invalid/v1", apiKey: "k", model: "m", providerID: "corporate")
        let input = "ну короче давай перенесём встречу на четверг"
        let started = Date()
        let result = await ThoughtSynthesizer.shared.clean(
            input, level: .clean, targetBundleId: nil, firedSpellings: [], language: .ru, backend: ExternalBackend(config: gateway)
        )
        #expect(result.fallback == .providerUnavailable)
        #expect(result.text == ThoughtSynthesizer.stageOne(input))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}

/// «ИИ не настроен» говорит об отсутствии настройки, а не о сбое: после первого раза за запуск
/// оно только мешало бы, например тем, кто раньше работал без ИИ. Настоящие сбои повторяются каждый раз.
struct FallbackNoticeThrottleTests {
    @Test func notConfiguredIsShownOncePerLaunch() {
        var throttle = FallbackNoticeThrottle()
        #expect(throttle.message(for: .notConfigured, providerID: "openai", engine: .external)
                == String(localized: "ИИ не настроен"))
        #expect(throttle.message(for: .notConfigured, providerID: "openai", engine: .external) == nil)
        #expect(throttle.message(for: .notConfigured, providerID: "openai", engine: .external) == nil)
    }

    @Test func realFailuresAreReportedEveryTime() {
        var throttle = FallbackNoticeThrottle()
        for _ in 0..<3 {
            #expect(throttle.message(for: .timeout, providerID: "openai", engine: .external)
                    == String(localized: "ИИ не ответил"))
            #expect(throttle.message(for: .providerError(500), providerID: "openai", engine: .external)
                    == String(localized: "Ошибка ИИ"))
        }
    }

    @Test func otherReasonsDoNotUseUpTheNotConfiguredNotice() {
        var throttle = FallbackNoticeThrottle()
        #expect(throttle.message(for: .timeout, providerID: "openai", engine: .external) != nil)
        #expect(throttle.message(for: .notConfigured, providerID: "openai", engine: .external)
                == String(localized: "ИИ не настроен"))
    }

    @Test func silentReasonsStayStillSilent() {
        var throttle = FallbackNoticeThrottle()
        #expect(throttle.message(for: nil, providerID: "openai", engine: .external) == nil)
        #expect(throttle.message(for: .shortPhrase, providerID: "openai", engine: .external) == nil)
    }
}
