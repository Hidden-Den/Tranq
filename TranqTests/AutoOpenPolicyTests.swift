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
