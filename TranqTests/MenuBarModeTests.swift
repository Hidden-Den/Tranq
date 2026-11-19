import Testing
@testable import Tranq

@Suite(.serialized) @MainActor
struct MenuBarModeTests {
    @Test func modeOrderMatchesMenu() {
        #expect(HotKeyMode.allCases == [.toggle, .pushToTalk])
    }

    @Test func modeTitlesAreDistinctAndFilled() {
        #expect(HotKeyMode.toggle.title != HotKeyMode.pushToTalk.title)
        #expect(!HotKeyMode.toggle.title.isEmpty)
        #expect(!HotKeyMode.pushToTalk.title.isEmpty)
    }

    /// Смена режима во время записи не трогает текущую запись.
    @Test func switchingModeDuringRecordingKeepsRecording() {
        let settings = HotKeySettings.shared
        let before = settings.mode
        let other: HotKeyMode = before == .toggle ? .pushToTalk : .toggle
        AudioCapture.shared.isRecording = true
        defer {
            AudioCapture.shared.isRecording = false
            settings.mode = before
        }
        settings.mode = other
        settings.mode = before
        #expect(AudioCapture.shared.isRecording)
    }

    @Test func menuAndSettingsShareOneStore() {
        let settings = HotKeySettings.shared
        let before = settings.mode
        defer { settings.mode = before }
        settings.mode = .pushToTalk
        #expect(NativeHotKeyManager.shared.mode == .pushToTalk)
    }
}
