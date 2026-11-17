import Testing
import Foundation
@testable import Golosok

/// Одноразовая уборка данных удалённых функций.
struct LegacyCleanupTests {
    @Test func removesObsoleteFilesAndKeysOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["prompts.json", "ai_cache.json", "personalization.v1.json", "history.json", "dictionary.json"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }
        let suite = "golosok.tests.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["voice.style", "voice.openRouterModel", "voice.adaptiveAppProfiles", "voice.mode"] { defaults.set("x", forKey: key) }

        LegacyCleanup.run(directory: dir, defaults: defaults)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == ["history.json", "dictionary.json"])
        #expect(defaults.string(forKey: "voice.style") == nil)
        #expect(defaults.string(forKey: "voice.openRouterModel") == nil)
        #expect(defaults.string(forKey: "voice.adaptiveAppProfiles") == nil)
        #expect(defaults.string(forKey: "voice.mode") == "x")
    }

    @Test func runningTwiceIsHarmless() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "golosok.tests.legacy.\(UUID().uuidString)")!
        LegacyCleanup.run(directory: dir, defaults: defaults)
        LegacyCleanup.run(directory: dir, defaults: defaults)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
