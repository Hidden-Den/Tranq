import Testing
import Foundation
@testable import Tranq

extension SharedSettingsSuites {
    /// Каждый тест работает с отдельной временной папкой и своим доменом UserDefaults.
    @MainActor
    final class DictionaryLearningTests {
        private final class Clock {
            var date = Date(timeIntervalSince1970: 1_800_000_000)
        }

        private let directory: URL
        private let suiteName: String
        private let defaults: UserDefaults
        private let checker = SetCommonWordChecker([.ru: ["дом", "квартира", "кубик"], .en: ["slack"]])
        private let clock = Clock()
        private let store: DictionaryStore
        private let learning: DictionaryLearning

        init() {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictionary-learning-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suiteName = "dictionary-learning-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let clock = clock
            let store = DictionaryStore(
                directory: directory, defaults: defaults, packsBundle: .main,
                checker: checker, packs: [], now: { clock.date }
            )
            self.directory = directory
            self.suiteName = suiteName
            self.defaults = defaults
            self.store = store
            self.learning = DictionaryLearning(store: store, checker: checker, now: { clock.date })
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        private func learn(_ original: String, _ edited: String, noteId: UUID? = nil, language: DictionaryLanguage = .ru) {
            learning.learnSync(original: original, edited: edited, noteId: noteId, language: language)
        }

        // MARK: - extractDiffPairs

        @Test func extractDiffPairsSingleReplacement() {
            let diffs = DictionaryLearning.extractDiffPairs(
                original: "Мы развернули кубернетис на сервере", edited: "Мы развернули Kubernetes на сервере"
            )
            #expect(diffs.count == 1)
            #expect(diffs.first?.pattern == "кубернетис")
            #expect(diffs.first?.replacement == "Kubernetes")
        }

        @Test func extractDiffPairsPhraseReplacement() {
            let diffs = DictionaryLearning.extractDiffPairs(
                original: "Давай созвон в зуме завтра в полдень", edited: "Давай созвон в Zoom завтра в полдень"
            )
            #expect(diffs.count == 1)
            #expect(diffs.first?.pattern == "зуме")
            #expect(diffs.first?.replacement == "Zoom")
        }

        @Test func extractDiffPairsFillerDeletion() {
            let diffs = DictionaryLearning.extractDiffPairs(
                original: "Я в общем-то согласен с этим решением", edited: "Я согласен с этим решением"
            )
            #expect(diffs.count == 1)
            #expect(diffs.first?.pattern == "в общем-то")
            #expect(diffs.first?.replacement == "")
        }

        // MARK: - isLearnablePair

        @Test func learnablePairFilter() {
            #expect(DictionaryLearning.isLearnablePair(pattern: "кубернетис", replacement: "Kubernetes", language: .ru))
            #expect(DictionaryLearning.isLearnablePair(pattern: "визуал студио", replacement: "Visual Studio", language: .ru))
            #expect(DictionaryLearning.isLearnablePair(pattern: "хабер", replacement: "Хабр", language: .ru))
            #expect(!DictionaryLearning.isLearnablePair(pattern: "мфц", replacement: "МФЦ", language: .ru))
            #expect(DictionaryLearning.isLearnablePair(pattern: "slack", replacement: "Slack", language: .en))
            #expect(!DictionaryLearning.isLearnablePair(pattern: "slack", replacement: "Slack", language: .ru))
            #expect(!DictionaryLearning.isLearnablePair(pattern: "дом", replacement: "квартира", language: .ru))
            #expect(!DictionaryLearning.isLearnablePair(pattern: "в общем-то", replacement: "", language: .ru))
            #expect(!DictionaryLearning.isLearnablePair(pattern: "один два три", replacement: "Kubernetes", language: .ru))
            #expect(!DictionaryLearning.isLearnablePair(pattern: "завтра", replacement: "Kubernetes", language: .ru))
        }

        // MARK: - learn

        @Test func singlePairIsNotLearnedYet() {
            learn("Мы развернули кубернетис", "Мы развернули Kubernetes")
            #expect(store.userEntries.isEmpty)
        }

        @Test func secondIdenticalPairCreatesLearnedEntry() {
            learn("Мы развернули кубернетис", "Мы развернули Kubernetes")
            learn("Опять кубернетис упал", "Опять Kubernetes упал")

            #expect(store.userEntries.count == 1)
            let entry = store.userEntries[0]
            #expect(entry.spelling == "Kubernetes")
            #expect(entry.source == .learned)
            #expect(entry.variants[.ru] == ["кубернетис"])
            #expect(!entry.forceCase)
        }

        @Test func rephrasingIsNotLearned() {
            for _ in 0..<2 {
                learn("давай завтра созвонимся", "созвон перенесём на пятницу")
            }
            #expect(store.userEntries.isEmpty)
        }

        @Test func commonRussianWordEditNotLearned() {
            for _ in 0..<2 {
                learn("Купили дом в центре", "Купили квартира в центре")
            }
            #expect(store.userEntries.isEmpty)
        }

        @Test func commonWordPatternWithLatinReplacementIsLearned() {
            for _ in 0..<2 {
                learn("Купили кубик в центре", "Купили Kubik в центре")
            }
            #expect(store.userEntries.count == 1)
            #expect(store.userEntries[0].spelling == "Kubik")
            #expect(store.userEntries[0].variants[.ru] == ["кубик"])
        }

        @Test func commonWordGrammarFixIsNotLearned() {
            let checker = SetCommonWordChecker([.ru: ["давай"]])
            let local = DictionaryLearning(store: store, checker: checker, now: { [clock] in clock.date })
            for _ in 0..<2 {
                local.learnSync(original: "ну давай", edited: "ну Давайте", noteId: nil, language: .ru)
            }
            #expect(store.userEntries.isEmpty)
        }

        @Test func englishSentenceInitialCaseEditIsNotLearned() {
            for _ in 0..<2 {
                learn("the cat sat. the dog", "The cat sat. The dog", language: .en)
            }
            #expect(store.userEntries.isEmpty)
        }

        @Test func englishCaseOnlyEditLearnsForceCase() {
            learn("ping me on slack today", "ping me on Slack today", language: .en)
            #expect(store.userEntries.isEmpty)
            learn("on slack now", "on Slack now", language: .en)

            #expect(store.userEntries.count == 1)
            let entry = store.userEntries[0]
            #expect(entry.spelling == "Slack")
            #expect(entry.forceCase)
            #expect(entry.source == .learned)
            #expect((entry.variants[.en] ?? []).isEmpty)
        }

        @Test func caseOnlyEditIsIgnoredForRussian() {
            for _ in 0..<2 { learn("открой slack", "открой Slack", language: .ru) }
            #expect(store.userEntries.isEmpty)
        }

        @Test func reverseEditRemovesVariant() {
            let entry = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер", "кубернетес"]], source: .manual)
            let noteId = UUID()
            store.recordReplacements([
                AppliedReplacement(
                    original: "кубер", replacement: "Kubernetes",
                    entryKey: "user/\(entry.id.uuidString)", variant: "кубер", reason: .variant
                )
            ], noteId: noteId)

            learn("Мы используем Kubernetes", "Мы используем кубер", noteId: noteId)

            #expect(store.userEntries.first?.variants[.ru] == ["кубернетес"])
        }

        @Test func revertedReplacementIsConsumed() {
            let entry = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
            let noteId = UUID()
            store.recordReplacements([
                AppliedReplacement(
                    original: "кубер", replacement: "Kubernetes",
                    entryKey: "user/\(entry.id.uuidString)", variant: "кубер", reason: .variant
                )
            ], noteId: noteId)

            learn("Мы используем Kubernetes", "Мы используем кубер", noteId: noteId)
            #expect(store.replacements(for: noteId).isEmpty)

            // Вариант возвращён вручную: повторная правка не должна снять его снова.
            store.updateEntry({ var e = store.userEntries[0]; e.variants[.ru] = ["кубер"]; return e }())
            learn("Мы используем кубер", "Мы используем кубер тут", noteId: noteId)
            #expect(store.userEntries.first?.variants[.ru] == ["кубер"])
        }

        @Test func reverseEditIgnoredWhenReplacementStillPresent() {
            let entry = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
            let noteId = UUID()
            store.recordReplacements([
                AppliedReplacement(
                    original: "кубер", replacement: "Kubernetes",
                    entryKey: "user/\(entry.id.uuidString)", variant: "кубер", reason: .variant
                )
            ], noteId: noteId)

            learn("Kubernetes и кубер", "Kubernetes и кубер тут", noteId: noteId)

            #expect(store.userEntries.first?.variants[.ru] == ["кубер"])
        }

        @Test func reverseEditOfCaseFixDisablesPackVariant() {
            let noteId = UUID()
            store.recordReplacements([
                AppliedReplacement(
                    original: "github", replacement: "GitHub",
                    entryKey: "it/GitHub", variant: "github", reason: .caseFix
                )
            ], noteId: noteId)

            learn("Push to GitHub today", "Push to github today", noteId: noteId, language: .en)

            #expect(store.disabledPackVariants.contains("it/GitHub/github"))
        }

        @Test func dailyCapOfFive() {
            let pairs = [
                ("кубернетис", "Kubernetes"), ("гитхаб", "GitHub"), ("докер", "Docker"),
                ("слак", "Slack"), ("нотион", "Notion"), ("фигма", "Figma")
            ]
            for (wrong, right) in pairs {
                learn("Мы пишем в \(wrong)", "Мы пишем в \(right)")
                learn("Опять в \(wrong)", "Опять в \(right)")
            }
            #expect(store.userEntries.count == 5)

            clock.date = clock.date.addingTimeInterval(2 * 86_400)
            learn("Снова в фигма", "Снова в Figma")
            #expect(store.userEntries.count == 6)
        }

        @Test func learningDisabledDoesNothing() {
            store.learningEnabled = false
            learn("Мы развернули кубернетис", "Мы развернули Kubernetes")
            learn("Опять кубернетис упал", "Опять Kubernetes упал")
            store.learningEnabled = true
            learn("Снова кубернетис", "Снова Kubernetes")
            #expect(store.userEntries.isEmpty)
        }

        @Test func reinforcingExistingEntryRefreshesLastUsed() {
            store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .learned)
            clock.date = clock.date.addingTimeInterval(50 * 86_400)

            learn("Мы развернули кубернетис", "Мы развернули Kubernetes")
            learn("Опять кубернетис упал", "Опять Kubernetes упал")

            #expect(store.userEntries.count == 1)
            #expect(store.userEntries[0].variants[.ru] == ["кубер", "кубернетис"])
            #expect(store.userEntries[0].lastUsed == clock.date)
        }

        @Test func asyncLearnAppliesOnBackgroundQueue() async throws {
            learning.learn(original: "Мы развернули кубернетис", edited: "Мы развернули Kubernetes", noteId: nil, language: .ru)
            learning.learn(original: "Опять кубернетис упал", edited: "Опять Kubernetes упал", noteId: nil, language: .ru)
            for _ in 0..<100 where store.userEntries.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(store.userEntries.count == 1)
        }
    }
}
