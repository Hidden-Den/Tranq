//
//  BrowserURLReaderTests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

/// Чтение домена активной вкладки браузера.
struct BrowserURLReaderTests {

    @Test func nonBrowserSkipsSource() async {
        let fake = FakeURLSource(url: URL(string: "https://x.ru")!)
        #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "org.telegram.desktop", source: fake) == nil)
        #expect(fake.calls == 0)
    }

    @Test func missingBundleIdSkipsSource() async {
        let fake = FakeURLSource(url: URL(string: "https://x.ru")!)
        #expect(await BrowserURLReader.readHost(pid: 1, bundleId: nil, source: fake) == nil)
        #expect(fake.calls == 0)
    }

    @Test func browserReturnsNormalizedHost() async {
        let fake = FakeURLSource(url: URL(string: "https://www.Mail.Company.ru/inbox")!)
        #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "com.google.Chrome", source: fake) == "mail.company.ru")
    }

    @Test func browserWithoutURLGivesNil() async {
        let fake = FakeURLSource(url: nil)
        #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "com.apple.Safari", source: fake) == nil)
    }

    @Test func hangingBrowserGivesUpByDeadline() async {
        let fake = FakeURLSource(url: URL(string: "https://x.ru")!, delay: 2)
        let start = Date()
        #expect(await BrowserURLReader.readHost(pid: 1, bundleId: "com.apple.Safari", source: fake, deadline: 0.3) == nil)
        // Порог ниже задержки источника в 2 с: доказывает, что чтение не ждали, и не падает под нагрузкой
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func browserListCoversChromiumAndSafari() {
        #expect(BrowserURLReader.isBrowser("com.apple.Safari"))
        #expect(BrowserURLReader.isBrowser("ru.yandex.desktop.yandex-browser"))
        #expect(BrowserURLReader.isBrowser("org.mozilla.firefox"))
        #expect(!BrowserURLReader.isBrowser("com.apple.Notes"))
        #expect(BrowserURLReader.chromiumBundleIds.contains("company.thebrowser.Browser"))
        #expect(!BrowserURLReader.chromiumBundleIds.contains("com.apple.Safari"))
        #expect(!BrowserURLReader.chromiumBundleIds.contains("org.mozilla.firefox"))
    }
}
