//
//  DictationContextCaptureTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Контекст диктовки снимается при начале записи и не меняется до её конца.
struct DictationContextCaptureTests {

    @Test func contextFrozenAtBegin() async {
        let fake = FakeURLSource(url: URL(string: "https://mail.company.ru")!)
        let capture = DictationContextCapture(source: fake, readDeadline: 5)
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"))
        // Ждём, пока адрес реально прочитан, а не фиксированное время: под нагрузкой чтение может задержаться
        let deadline = Date().addingTimeInterval(5)
        while fake.calls == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        fake.url = URL(string: "https://chatgpt.com")!
        let c = await capture.finish()
        #expect(c == DictationContext(bundleId: "com.google.Chrome", host: "mail.company.ru"))
        #expect(fake.calls == 1)
    }

    @Test func noFrontAppGivesEmptyContext() async {
        let capture = DictationContextCapture(source: FakeURLSource(url: nil))
        capture.begin(app: nil)
        #expect(await capture.finish() == DictationContext(bundleId: nil, host: nil))
    }

    @Test func browserHostIsNotReadWithoutSiteRules() async {
        let fake = FakeURLSource(url: URL(string: "https://mail.company.ru")!)
        let capture = DictationContextCapture(source: fake, readDeadline: 5)
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), readsHost: false)
        #expect(await capture.finish() == DictationContext(bundleId: "com.google.Chrome", host: nil))
        #expect(fake.calls == 0)
    }

    @Test func nonBrowserHasNoHost() async {
        let fake = FakeURLSource(url: URL(string: "https://x.ru")!)
        let capture = DictationContextCapture(source: fake, readDeadline: 5)
        capture.begin(app: (pid: 1, bundleId: "org.telegram.desktop"))
        #expect(await capture.finish() == DictationContext(bundleId: "org.telegram.desktop", host: nil))
        #expect(fake.calls == 0)
    }

    @Test func frozenContextSurvivesNewBegin() async {
        let capture = DictationContextCapture(source: FakeURLSource(url: URL(string: "https://mail.company.ru")!), readDeadline: 5)
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"))
        let frozen = capture.freeze()
        capture.begin(app: (pid: 2, bundleId: "org.telegram.desktop"))
        #expect(await frozen.resolve() == DictationContext(bundleId: "com.google.Chrome", host: "mail.company.ru"))
    }

    @Test func hostCallbackFiresOnceForCurrentRecording() async {
        let fake = FakeURLSource(url: URL(string: "https://mail.company.ru")!)
        let capture = DictationContextCapture(source: fake, readDeadline: 5)
        let received = HostBox()
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), onHost: { received.append($0) })
        _ = await capture.finish()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.values == ["mail.company.ru"])
    }

    @Test func staleHostCallbackIsIgnored() async {
        let capture = DictationContextCapture(source: FakeURLSource(url: URL(string: "https://mail.company.ru")!, delay: 0.05), readDeadline: 5)
        let first = HostBox()
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), onHost: { first.append($0) })
        let finishingFirst = capture.freeze()
        capture.begin(app: (pid: 2, bundleId: "org.telegram.desktop"))
        // Ждём конец первого чтения вместе с решением, вызывать ли колбэк: без пауз на удачу
        _ = await finishingFirst.resolve()
        #expect(first.values.isEmpty)
    }

    @Test func overlayLabelOnlyForUnusualModes() {
        #expect(ResolvedLevel(level: .clean, label: "Чисто", ruleName: nil).overlayLabel == nil)
        #expect(ResolvedLevel(level: .verbatim, label: "Дословно", ruleName: nil).overlayLabel == nil)
        #expect(ResolvedLevel(level: .rewrite(tone: "деловой"), label: "Почта", ruleName: "Почта").overlayLabel == "Почта")
    }
}

private final class HostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []
    func append(_ value: String?) { lock.withLock { stored.append(value) } }
    var values: [String?] { lock.withLock { stored } }
}
