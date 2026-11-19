import Testing
@testable import Tranq

struct AutoOpenPolicyTests {
    @Test func switchesWhenWindowHidden() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: false) == true)
    }

    @Test func keepsScreenWhenWindowOpen() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: true) == false)
    }

    @Test func neverSwitchesWhenSettingOff() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: false, isWindowVisible: false) == false)
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: false, isWindowVisible: true) == false)
    }
}

/// Что считается «окно скрыто». Раньше признак гас только при закрытии окна: свёрнутое в Dock окно
/// и приложение, скрытое через ⌘H, считались видимыми, и после записи экран не переключался.
struct WindowPresenceTests {
    @Test func openWindowIsOnScreen() {
        #expect(WindowPresence.isOnScreen(isVisible: true, isMiniaturized: false, appIsHidden: false) == true)
    }

    @Test func closedWindowIsNotOnScreen() {
        #expect(WindowPresence.isOnScreen(isVisible: false, isMiniaturized: false, appIsHidden: false) == false)
    }

    @Test func minimizedWindowIsNotOnScreen() {
        #expect(WindowPresence.isOnScreen(isVisible: true, isMiniaturized: true, appIsHidden: false) == false)
    }

    @Test func hiddenAppIsNotOnScreen() {
        #expect(WindowPresence.isOnScreen(isVisible: true, isMiniaturized: false, appIsHidden: true) == false)
    }

    @Test func missingWindowIsNotOnScreen() {
        #expect(WindowPresence.isOnScreen(isVisible: nil, isMiniaturized: false, appIsHidden: false) == false)
    }
}

