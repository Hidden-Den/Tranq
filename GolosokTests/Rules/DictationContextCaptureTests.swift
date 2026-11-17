//
//  DictationContextCaptureTests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

/// Контекст диктовки снимается при начале записи и не меняется до её конца.
struct DictationContextCaptureTests {

    @Test func contextFrozenAtBegin() async {
        let fake = FakeURLSource(url: URL(string: "https://mail.company.ru")!)
        let capture = DictationContextCapture(source: fake)
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), promptRequested: true)
        // Ждём, пока адрес реально прочитан, а не фиксированное время: под нагрузкой чтение может задержаться
        let deadline = Date().addingTimeInterval(5)
        while fake.calls == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        fake.url = URL(string: "https://chatgpt.com")!
        let c = await capture.finish()
        #expect(c == DictationContext(bundleId: "com.google.Chrome", host: "mail.company.ru", promptRequested: true))
        #expect(fake.calls == 1)
    }

    @Test func noFrontAppGivesEmptyContext() async {
        let capture = DictationContextCapture(source: FakeURLSource(url: nil))
        capture.begin(app: nil, promptRequested: false)
        #expect(await capture.finish() == DictationContext(bundleId: nil, host: nil, promptRequested: false))
    }

    @Test func nonBrowserHasNoHost() async {
        let fake = FakeURLSource(url: URL(string: "https://x.ru")!)
        let capture = DictationContextCapture(source: fake)
        capture.begin(app: (pid: 1, bundleId: "org.telegram.desktop"), promptRequested: false)
        #expect(await capture.finish() == DictationContext(bundleId: "org.telegram.desktop", host: nil, promptRequested: false))
        #expect(fake.calls == 0)
    }

    @Test func frozenContextSurvivesNewBegin() async {
        let capture = DictationContextCapture(source: FakeURLSource(url: URL(string: "https://mail.company.ru")!))
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), promptRequested: true)
        let frozen = capture.freeze()
        capture.begin(app: (pid: 2, bundleId: "org.telegram.desktop"), promptRequested: false)
        #expect(await frozen.resolve() == DictationContext(bundleId: "com.google.Chrome", host: "mail.company.ru", promptRequested: true))
    }

    @Test func hostCallbackFiresOnceForCurrentRecording() async {
        let fake = FakeURLSource(url: URL(string: "https://mail.company.ru")!)
        let capture = DictationContextCapture(source: fake)
        let received = HostBox()
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), promptRequested: false, onHost: { received.append($0) })
        _ = await capture.finish()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.values == ["mail.company.ru"])
    }

    @Test func staleHostCallbackIsIgnored() async {
        let slow = FakeURLSource(url: URL(string: "https://mail.company.ru")!, delay: 0.15)
        let capture = DictationContextCapture(source: slow)
        let first = HostBox()
        capture.begin(app: (pid: 1, bundleId: "com.google.Chrome"), promptRequested: false, onHost: { first.append($0) })
        capture.begin(app: (pid: 2, bundleId: "org.telegram.desktop"), promptRequested: false)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(first.values.isEmpty)
    }

    @Test func overlayLabelOnlyForUnusualModes() {
        #expect(ResolvedLevel(level: .clean, label: "Чисто", ruleName: nil).overlayLabel == nil)
        #expect(ResolvedLevel(level: .verbatim, label: "Дословно", ruleName: nil).overlayLabel == nil)
        #expect(ResolvedLevel(level: .prompt, label: "Промпт", ruleName: nil).overlayLabel == "Промпт")
        #expect(ResolvedLevel(level: .rewrite(tone: "деловой"), label: "Почта", ruleName: "Почта").overlayLabel == "Почта")
    }

    @Test func promptModeIsOffByDefaultAndPersists() {
        let settings = VoiceIntelligenceSettings.shared
        let saved = settings.promptModeEnabled
        defer { settings.promptModeEnabled = saved }

        settings.promptModeEnabled = true
        #expect(AppEnvironment.defaults.bool(forKey: "voice.promptModeEnabled"))
        settings.resetToDefaults()
        #expect(settings.promptModeEnabled == false)
    }
}

private final class HostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []
    func append(_ value: String?) { lock.withLock { stored.append(value) } }
    var values: [String?] { lock.withLock { stored } }
}
