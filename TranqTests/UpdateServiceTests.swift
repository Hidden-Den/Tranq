import Testing
import Foundation
@testable import Tranq

/// Проверка новых релизов: только разбор ответа GitHub, без скачивания.
struct UpdateServiceTests {
    private func release(tag: String, html: String? = "https://github.com/Nuteres/Tranq/releases/tag/v2.3.1") -> Data {
        var json: [String: Any] = ["tag_name": tag, "name": "Tranq \(tag)"]
        if let html { json["html_url"] = html }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func newerReleaseGivesInfoWithReleasePage() {
        let info = UpdateService.parseRelease(release(tag: "v2.3.1"), currentVersion: "2.3.0")
        #expect(info?.version == "v2.3.1")
        #expect(info?.url.absoluteString == "https://github.com/Nuteres/Tranq/releases/tag/v2.3.1")
    }

    @Test func sameOrOlderReleaseGivesNothing() {
        #expect(UpdateService.parseRelease(release(tag: "v2.3.0"), currentVersion: "2.3.0") == nil)
        #expect(UpdateService.parseRelease(release(tag: "v2.2.9"), currentVersion: "2.3.0") == nil)
    }

    @Test func missingPageFallsBackToReleasesList() {
        let info = UpdateService.parseRelease(release(tag: "v2.4.0", html: nil), currentVersion: "2.3.0")
        #expect(info?.url.absoluteString == "https://github.com/Nuteres/Tranq/releases")
    }

    @Test func updateURLsPointToTranq() {
        #expect(UpdateService.releasesAPIURL.absoluteString == "https://api.github.com/repos/Nuteres/Tranq/releases/latest")
        #expect(UpdateService.releasesPage.absoluteString == "https://github.com/Nuteres/Tranq/releases")
    }

    @Test func garbageGivesNothing() {
        #expect(UpdateService.parseRelease(Data("не json".utf8), currentVersion: "2.3.0") == nil)
    }
}
