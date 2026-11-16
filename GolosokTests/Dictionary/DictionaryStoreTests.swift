import Testing
import Foundation
@testable import Golosok

extension SharedSettingsSuites {
    /// Каждый тест работает с отдельной временной папкой и своим доменом UserDefaults.
    @MainActor
    final class DictionaryStoreTests {
        private let directory: URL
        private let suiteName: String
        private let defaults: UserDefaults
        private let checker = SetCommonWordChecker([.ru: ["кубик"], .en: ["slack"]])

        private let pack = DictionaryPack(
            id: "it",
            title: [.ru: "IT", .en: "IT"],
            version: 1,
            entries: [
                PackEntry(spelling: "Kubernetes", variants: [.ru: ["кубер", "кубернетес"]]),
                PackEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]]),
            ]
        )

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictionary-store-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suiteName = "dictionary-store-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        private var mainURL: URL { directory.appendingPathComponent("dictionary.json") }
        private var backupURL: URL { directory.appendingPathComponent("dictionary.backup.json") }

        private func makeStore(packs: [DictionaryPack] = [], now: @escaping () -> Date = Date.init) -> DictionaryStore {
            DictionaryStore(
                directory: directory, defaults: defaults, packsBundle: .main,
                checker: checker, packs: packs, now: now
            )
        }

        private func entry(_ spelling: String, ru: [String] = [], source: DictionaryEntry.Source = .manual,
                           createdAt: Date = Date(), lastUsed: Date? = nil) -> DictionaryEntry {
            DictionaryEntry(
                id: UUID(), spelling: spelling, variants: [.ru: ru], source: source,
                forceCase: false, createdAt: createdAt, hits: 0, lastUsed: lastUsed
            )
        }

        private func writeFile(_ entries: [DictionaryEntry], to url: URL) throws {
            struct File: Encodable { let schemaVersion: Int; let entries: [DictionaryEntry] }
            try JSONEncoder().encode(File(schemaVersion: 1, entries: entries)).write(to: url)
        }

        private func savedSpellings(_ url: URL) throws -> [String] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let entries = object?["entries"] as? [[String: Any]] ?? []
            return entries.compactMap { $0["spelling"] as? String }
        }

        // MARK: - Записи

        @Test func addingSameSpellingMergesVariants() {
            let store = makeStore()
            let first = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .learned)
            let merged = store.addEntry(
                spelling: "kubernetes", variants: [.ru: ["кубернетес", "Кубер"], .en: ["cooper netties"]], source: .manual
            )

            #expect(store.userEntries.count == 1)
            #expect(merged.id == first.id)
            #expect(merged.spelling == "Kubernetes")
            #expect(merged.variants[.ru] == ["кубер", "кубернетес"])
            #expect(merged.variants[.en] == ["cooper netties"])
            #expect(merged.source == .manual)
            #expect(store.userEntries.first == merged)
        }

        @Test func forgetReplacementsRemovesOnlyGivenOnes() {
            let store = makeStore()
            let noteId = UUID()
            let a = AppliedReplacement(original: "кубер", replacement: "Kubernetes", entryKey: "it/Kubernetes", variant: "кубер", reason: .variant)
            let b = AppliedReplacement(original: "гитхаб", replacement: "GitHub", entryKey: "it/GitHub", variant: "гитхаб", reason: .variant)
            store.recordReplacements([a, b], noteId: noteId)

            store.forgetReplacements([a], noteId: noteId)
            #expect(store.replacements(for: noteId) == [b])
            store.forgetReplacements([b], noteId: noteId)
            #expect(store.replacements(for: noteId).isEmpty)
        }

        @Test func touchRefreshesLastUsedInPlace() {
            let store = makeStore()
            let added = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .learned)
            store.touch(id: added.id)
            #expect(store.userEntries[0].lastUsed != nil)
            #expect(store.userEntries[0].variants == added.variants)
        }

        @Test func removeVariantFromLearnedDeletesEntryWhenLast() {
            let store = makeStore()
            let learned = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер", "кубернетис"]], source: .learned)
            let manual = store.addEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]], source: .manual)

            store.removeVariant("кубер", language: .ru, fromEntryKey: "user/\(learned.id.uuidString)")
            #expect(store.userEntries.first { $0.id == learned.id }?.variants[.ru] == ["кубернетис"])

            store.removeVariant("кубернетис", language: .ru, fromEntryKey: "user/\(learned.id.uuidString)")
            #expect(!store.userEntries.contains { $0.id == learned.id })

            store.removeVariant("гитхаб", language: .ru, fromEntryKey: "user/\(manual.id.uuidString)")
            #expect(store.userEntries.first { $0.id == manual.id }?.variants[.ru] == [])
        }

        @Test func removeVariantFromPackDisablesItOnly() {
            let store = makeStore(packs: [pack])
            store.removeVariant("кубер", language: .ru, fromEntryKey: "it/Kubernetes")
            store.waitForIndex()

            #expect(store.disabledPackVariants == ["it/Kubernetes/кубер"])
            #expect(store.disabledPacks.isEmpty)
            #expect(store.disabledPackWords.isEmpty)
            #expect(store.index?.apply(to: "кубер", language: .ru).text == "кубер")
            #expect(store.index?.apply(to: "кубернетес", language: .ru).text == "Kubernetes")
            #expect(store.index?.apply(to: "гитхаб", language: .ru).text == "GitHub")

            let reloaded = makeStore(packs: [pack])
            #expect(reloaded.disabledPackVariants == ["it/Kubernetes/кубер"])
        }

        @Test func packAndWordTogglesPersistAndRebuildIndex() {
            let store = makeStore(packs: [pack])
            store.setPackWord("it/GitHub", enabled: false)
            store.waitForIndex()
            #expect(store.index?.apply(to: "гитхаб", language: .ru).text == "гитхаб")
            #expect(store.index?.apply(to: "кубер", language: .ru).text == "Kubernetes")

            store.setPack("it", enabled: false)
            store.waitForIndex()
            #expect(store.index?.apply(to: "кубер", language: .ru).text == "кубер")

            store.learningEnabled = false
            let reloaded = makeStore(packs: [pack])
            #expect(reloaded.disabledPacks == ["it"])
            #expect(reloaded.disabledPackWords == ["it/GitHub"])
            #expect(reloaded.learningEnabled == false)

            reloaded.setPack("it", enabled: true)
            #expect(reloaded.disabledPacks.isEmpty)
        }

        @Test func learningIsEnabledByDefault() {
            #expect(makeStore().learningEnabled)
        }

        @Test func resetLearnedKeepsManualEntries() {
            let store = makeStore()
            store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .learned)
            store.addEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]], source: .manual)
            store.resetLearned()
            #expect(store.userEntries.map(\.spelling) == ["GitHub"])
        }

        // MARK: - Файлы

        @Test func corruptMainFileFallsBackToBackup() throws {
            try Data("{не json".utf8).write(to: mainURL)
            try writeFile([entry("Kubernetes", ru: ["кубер"])], to: backupURL)

            let store = makeStore()
            #expect(store.userEntries.map(\.spelling) == ["Kubernetes"])
        }

        @Test func corruptMainFileIsMovedAsideAndOverwritesPreviousCorruptCopy() throws {
            let corruptURL = directory.appendingPathComponent("dictionary.corrupt.json")
            try Data("старый мусор".utf8).write(to: corruptURL)
            try Data("{не json".utf8).write(to: mainURL)

            let store = makeStore()
            #expect(store.userEntries.isEmpty)
            #expect(try String(contentsOf: corruptURL, encoding: .utf8) == "{не json")
            #expect(!FileManager.default.fileExists(atPath: mainURL.path))

            store.addEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]], source: .manual)
            store.flush()
            #expect(try String(contentsOf: corruptURL, encoding: .utf8) == "{не json")
            #expect(try savedSpellings(mainURL) == ["GitHub"])
        }

        @Test func corruptBothFilesGivesEmptyButPacksWork() throws {
            try Data("мусор".utf8).write(to: mainURL)
            try Data("ещё мусор".utf8).write(to: backupURL)

            let store = makeStore(packs: [pack])
            store.waitForIndex()
            #expect(store.userEntries.isEmpty)
            #expect(store.index?.apply(to: "поднял кубер", language: .ru).text == "поднял Kubernetes")
        }

        @Test func savesSchemaVersionAndBackup() throws {
            let store = makeStore()
            store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
            store.flush()

            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: mainURL)) as? [String: Any]
            #expect(object?["schemaVersion"] as? Int == 1)
            #expect(try savedSpellings(mainURL) == ["Kubernetes"])
            #expect(!FileManager.default.fileExists(atPath: backupURL.path))

            store.addEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]], source: .manual)
            store.flush()
            #expect(try savedSpellings(mainURL) == ["Kubernetes", "GitHub"])
            #expect(try savedSpellings(backupURL) == ["Kubernetes"])

            #expect(makeStore().userEntries.map(\.spelling) == ["Kubernetes", "GitHub"])
        }

        @Test func corruptMainFileIsNotCopiedOverBackup() throws {
            try Data("{не json".utf8).write(to: mainURL)
            try writeFile([entry("Kubernetes", ru: ["кубер"])], to: backupURL)

            let store = makeStore()
            store.addEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]], source: .manual)
            store.flush()
            #expect(try savedSpellings(backupURL) == ["Kubernetes"])
            #expect(try savedSpellings(mainURL) == ["Kubernetes", "GitHub"])
        }

        @Test func learnedEntryUnusedFor60DaysIsPurgedOnLoad() throws {
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let day: TimeInterval = 86_400
            try writeFile([
                entry("Stale", ru: ["стейл"], source: .learned, createdAt: now - 61 * day),
                entry("Used", ru: ["юзд"], source: .learned, createdAt: now - 90 * day, lastUsed: now - 10 * day),
                entry("Fresh", ru: ["фреш"], source: .learned, createdAt: now - 59 * day),
                entry("Manual", ru: ["мануал"], source: .manual, createdAt: now - 400 * day),
            ], to: mainURL)

            let store = makeStore(now: { now })
            #expect(store.userEntries.map(\.spelling) == ["Used", "Fresh", "Manual"])
        }

        // MARK: - Подсказка модели

        @Test func promptHintCapsAtEightAndUsesLanguagePrefix() {
            let base = Date(timeIntervalSince1970: 1_000_000)
            #expect(makeStore().promptHint(firedSpellings: [], language: .ru) == "")

            let store = makeStore()
            for i in 0..<10 {
                var e = store.addEntry(spelling: "Word\(i)", variants: [:], source: .manual)
                e.createdAt = base + Double(i)
                store.updateEntry(e)
            }
            var recent = store.userEntries[0]
            recent.lastUsed = base + 100
            store.updateEntry(recent)

            let ru = store.promptHint(firedSpellings: ["Kubernetes", "Word9"], language: .ru)
            #expect(ru == "Словарь пользователя: Kubernetes, Word9, Word0, Word8, Word7, Word6, Word5, Word4")

            let en = store.promptHint(firedSpellings: [], language: .en)
            #expect(en == "User dictionary: Word0, Word9, Word8, Word7, Word6, Word5, Word4, Word3")
        }

        // MARK: - Замены по заметкам

        @Test func replacementsAreKeptForLastFiftyNotes() {
            let store = makeStore()
            let r = AppliedReplacement(original: "кубер", replacement: "Kubernetes", entryKey: "it/Kubernetes", variant: "кубер", reason: .variant)
            let notes = (0..<51).map { _ in UUID() }
            for note in notes { store.recordReplacements([r], noteId: note) }
            store.recordReplacements([r], noteId: notes[1])

            #expect(store.replacements(for: notes[0]).isEmpty)
            #expect(store.replacements(for: notes[1]) == [r])
            #expect(store.replacements(for: notes[50]) == [r])
        }

        @Test func registerHitsUpdatesUserEntries() {
            let now = Date(timeIntervalSince1970: 1_500_000_000)
            let store = makeStore(now: { now })
            let e = store.addEntry(spelling: "Golosok", variants: [.ru: ["голосог"]], source: .learned)
            let hit = AppliedReplacement(original: "голосог", replacement: "Golosok", entryKey: "user/\(e.id.uuidString)", variant: "голосог", reason: .variant)
            let packHit = AppliedReplacement(original: "кубер", replacement: "Kubernetes", entryKey: "it/Kubernetes", variant: "кубер", reason: .variant)

            store.registerHits([hit, hit, packHit])
            #expect(store.userEntries.first?.hits == 2)
            #expect(store.userEntries.first?.lastUsed == now)
        }

        @Test func indexAndReplacementsAreSafeFromBackgroundThreads() {
            nonisolated(unsafe) let store = makeStore(packs: [pack])
            store.waitForIndex()
            let note = UUID()
            DispatchQueue.concurrentPerform(iterations: 200) { i in
                let r = store.index?.apply(to: "кубер", language: .ru).replacements ?? []
                store.recordReplacements(r, noteId: i % 2 == 0 ? note : UUID())
                _ = store.replacements(for: note)
                _ = store.promptHint(firedSpellings: [], language: .ru)
            }
            #expect(store.replacements(for: note).count == 1)
        }

        @Test func backgroundCallersReachMainThreadState() async {
            nonisolated(unsafe) let store = makeStore()
            let entry = await Task.detached {
                store.addEntry(spelling: "Golosok", variants: [.ru: ["голосог"]], source: .manual)
            }.value
            #expect(store.userEntries.map(\.id) == [entry.id])

            let hit = AppliedReplacement(original: "голосог", replacement: "Golosok", entryKey: "user/\(entry.id.uuidString)", variant: "голосог", reason: .variant)
            await Task.detached { store.registerHits([hit]) }.value
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(store.userEntries.first?.hits == 1)
        }

        // MARK: - Наборы

        @Test
        func packsLoadUnderFiftyMilliseconds() {
            let start = Date()
            let packs = DictionaryStore.loadPacks(from: .main)
            let elapsed = Date().timeIntervalSince(start)
            #expect(packs.map(\.id) == DictionaryStore.packOrder.filter { PackValidationTests.implementedPackIds.contains($0) })
            #expect(elapsed < 0.05)
        }
    }
}
