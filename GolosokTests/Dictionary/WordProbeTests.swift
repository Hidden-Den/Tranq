import Testing
import Foundation
@testable import Golosok

struct WordProbeTests {
    @Test func testProbeOutcomes() {
        #expect(WordProbe.evaluate(recognized: "кубер", spelling: "Kubernetes", peakDb: -20, language: .ru) == .variant("кубер"))
        #expect(WordProbe.evaluate(recognized: "кубер", spelling: "Kubernetes", peakDb: -50, language: .ru) == .tooQuiet)
        #expect(WordProbe.evaluate(recognized: "ну это вот кубер да", spelling: "Kubernetes", peakDb: -20, language: .ru) == .tooManyWords)
        #expect(WordProbe.evaluate(recognized: "Kubernetes.", spelling: "Kubernetes", peakDb: -20, language: .ru) == .alreadyCorrect)
        #expect(WordProbe.evaluate(recognized: "э-э", spelling: "Kubernetes", peakDb: -20, language: .ru) == .noise)
        #expect(WordProbe.evaluate(recognized: " ... ", spelling: "Kubernetes", peakDb: -20, language: .ru) == .noise)
        #expect(WordProbe.evaluate(recognized: "Кубер, Нетес!", spelling: "Kubernetes", peakDb: -20, language: .ru) == .variant("кубер нетес"))
    }

    @Test func testSingleCharacterResultIsNoise() {
        #expect(WordProbe.evaluate(recognized: "Си.", spelling: "C#", peakDb: -20, language: .ru) == .variant("си"))
        #expect(WordProbe.evaluate(recognized: "c", spelling: "C#", peakDb: -20, language: .en) == .noise)
        #expect(WordProbe.evaluate(recognized: "С!", spelling: "C#", peakDb: -20, language: .ru) == .noise)
    }

    @Test func testShortVariantsAreRejected() {
        let none = SetCommonWordChecker([:])
        #expect(VariantRules.accepted("c", spelling: "C#", language: .en, checker: none) == nil)
        #expect(VariantRules.accepted(" С ", spelling: "C#", language: .ru, checker: none) == nil)
        #expect(VariantRules.accepted("си", spelling: "C#", language: .ru, checker: none) == "си")
    }

    // 11: одновременно пишет только одна запись.
    @Test func testClaimingInterruptsPreviousProbe() {
        let first = WordProbe()
        let second = WordProbe()
        var interrupted: [String] = []
        first.onInterrupted = { interrupted.append("first") }
        second.onInterrupted = { interrupted.append("second") }
        WordProbe.claim(first)
        WordProbe.claim(first)
        #expect(interrupted.isEmpty)
        WordProbe.claim(second)
        #expect(interrupted == ["first"])
        second.cancel()
        WordProbe.claim(first)
        #expect(interrupted == ["first"])
        first.cancel()
    }

    @Test func testShouldStopRules() {
        // Лимит 3 с.
        #expect(WordProbe.shouldStop(elapsed: 3.0, peakDb: -60, lastLoudAt: nil, now: 3.0))
        // Речи не было: не останавливаем раньше лимита.
        #expect(!WordProbe.shouldStop(elapsed: 2.0, peakDb: -60, lastLoudAt: nil, now: 2.0))
        // Речь была, тишина 0,6 с.
        #expect(WordProbe.shouldStop(elapsed: 1.5, peakDb: -20, lastLoudAt: 0.8, now: 1.5))
        // Речь только что звучала.
        #expect(!WordProbe.shouldStop(elapsed: 1.5, peakDb: -20, lastLoudAt: 1.2, now: 1.5))
    }

    @Test func testCancelIsSafeWithoutStart() {
        let probe = WordProbe()
        probe.cancel()
        probe.cancel()
        #expect(probe.level < -40)
    }
}
